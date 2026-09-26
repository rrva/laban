import XCTest

@testable import LabanRenderer

/// The display-unplug freeze: a `CAMetalDisplayLink` rebuilt while its display
/// is being torn down is itself dead, so the burst of display notifications can
/// end with every link dead and nothing left to request another rebuild. Seen
/// 2026-08-18 — seven rebuilds inside 150 ms, then a 15-minute frozen terminal.
/// `PresentStallDecision` is the retry that closes that gap. These gates pin its
/// logic (the link itself needs a GPU; the decision is pure).
final class PresentStallDecisionTests: XCTestCase {
  private func makeDecision(abandonAfterFailedRepairs: Int = .max) -> PresentStallDecision {
    PresentStallDecision(
      baseThreshold: 2, maxThreshold: 16, abandonAfterFailedRepairs: abandonAfterFailedRepairs)
  }

  /// The exact failure shape: the link is unpaused (a frame was published, so
  /// the deferred-park budget is armed) but no callback ever fires, so the
  /// budget never decrements and it never parks. Two stalled checks must ask
  /// for a rebuild.
  func testUnpausedLinkWithNoCallbacksIsRebuilt() {
    var d = makeDecision()
    XCTAssertEqual(
      d.check(paused: false, callbacks: 900), .healthy, "first check only establishes a baseline")
    XCTAssertEqual(
      d.check(paused: false, callbacks: 900), .healthy, "one stalled check is not yet a verdict")
    XCTAssertEqual(
      d.check(paused: false, callbacks: 900), .rebuild, "two stalled checks -> rebuild")
    XCTAssertEqual(d.repairs, 1)
  }

  /// The idle path must not be mistaken for the freeze: a parked link delivers
  /// zero callbacks by design (ADR 0018), and rebuilding it every second would
  /// undo the ~zero-CPU idle win of ADR 0026.
  func testParkedLinkIsNeverTreatedAsStalled() {
    var d = makeDecision()
    for _ in 0..<50 {
      XCTAssertEqual(
        d.check(paused: true, callbacks: 900), .healthy, "a parked link is idle, not stalled")
    }
    XCTAssertEqual(d.repairs, 0)
  }

  /// A link that is firing is healthy however slowly it fires.
  func testForwardProgressClearsTheStreak() {
    var d = makeDecision()
    _ = d.check(paused: false, callbacks: 900)
    XCTAssertEqual(d.check(paused: false, callbacks: 900), .healthy, "streak building")
    XCTAssertEqual(
      d.check(paused: false, callbacks: 901), .healthy, "one callback proves the link is alive")
    XCTAssertEqual(d.check(paused: false, callbacks: 901), .healthy, "streak restarts from zero")
    XCTAssertEqual(d.repairs, 0)
  }

  /// If rebuilding does not revive the link, the retries must back off rather
  /// than swapping a fresh link onto the run loop every second forever.
  func testRepairBackoffDoublesAndIsCapped() {
    var d = makeDecision()
    var repairChecks: [Int] = []
    var sinceRepair = 0
    // A permanently dead link: never paused, callbacks frozen.
    for _ in 0..<200 {
      sinceRepair += 1
      if d.check(paused: false, callbacks: 900) == .rebuild {
        repairChecks.append(sinceRepair)
        sinceRepair = 0
      }
    }
    // 3 covers the baseline check plus the 2 stalled ones; then 4, 8, 16 as the
    // threshold doubles, and 16 forever once it caps.
    XCTAssertEqual(Array(repairChecks.prefix(5)), [3, 4, 8, 16, 16], "double after each repair")
    XCTAssertTrue(repairChecks.dropFirst(5).allSatisfy { $0 == 16 }, "capped at maxThreshold")
  }

  /// Recovery: once the rebuilt link starts firing, the next stall is detected
  /// as promptly as the first — a long freeze must not leave the watchdog slow.
  func testBackoffResetsAfterRecovery() {
    var d = makeDecision()
    while d.check(paused: false, callbacks: 900) != .rebuild {}  // earn some backoff
    _ = d.check(paused: false, callbacks: 900)
    _ = d.check(paused: false, callbacks: 901)  // the rebuilt link fires again

    _ = d.check(paused: false, callbacks: 901)
    XCTAssertEqual(d.check(paused: false, callbacks: 901), .rebuild, "back to the base threshold")
  }

  /// 2026-08-27: after an external display was unplugged, 716 rebuilds over
  /// 12.5 h were every one dead on arrival — rebuilding a `CAMetalDisplayLink`
  /// on the same layer rebinds to the dead vsync source. Once a rebuilt link
  /// has stalled too, the watchdog must stop swapping links and abandon the
  /// display-link presenter so the renderer presents through `nextDrawable()`.
  func testAbandonsTheLinkOnceARebuildHasAlsoStalled() {
    var d = makeDecision(abandonAfterFailedRepairs: 1)
    var verdicts: [PresentStallDecision.Verdict] = []
    for _ in 0..<12 {
      let verdict = d.check(paused: false, callbacks: 900)
      if verdict != .healthy { verdicts.append(verdict) }
      if verdict == .abandon { break }
    }
    XCTAssertEqual(verdicts, [.rebuild, .abandon], "one rebuild, then give up on the link")
  }

  /// A rebuild that revives the link resets the failure count: a later,
  /// unrelated stall gets its own rebuild before any abandonment.
  func testRecoveredRebuildDoesNotCountTowardAbandonment() {
    var d = makeDecision(abandonAfterFailedRepairs: 1)
    while d.check(paused: false, callbacks: 900) != .rebuild {}
    XCTAssertEqual(d.check(paused: false, callbacks: 960), .healthy, "the rebuilt link fires")

    var next: PresentStallDecision.Verdict = .healthy
    while next == .healthy { next = d.check(paused: false, callbacks: 960) }
    XCTAssertEqual(next, .rebuild, "a fresh stall is repaired, not abandoned")
  }

  /// Abandonment is only ever about a dead link; a parked one never counts.
  func testParkedLinkNeverAbandoned() {
    var d = makeDecision(abandonAfterFailedRepairs: 1)
    for _ in 0..<50 {
      XCTAssertEqual(d.check(paused: true, callbacks: 900), .healthy)
    }
  }
}
