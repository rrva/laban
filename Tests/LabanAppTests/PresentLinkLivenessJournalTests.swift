import XCTest

@testable import LabanApp
@testable import LabanRenderer

/// The render journal's `displayLink` block describes the host's MAIN
/// `CADisplayLink` — the link that decides when to *produce* a frame. Laban's
/// GPU backends present through a second, renderer-owned `CAMetalDisplayLink`,
/// and its state never reached the journal. That blind spot made a whole class
/// of question unanswerable from a dump: a frame recorded as `rendered` is not
/// necessarily on screen, because the main link parks by design after a
/// one-shot content change such as a tab switch, and whether the pixels landed
/// depends entirely on the second link.
final class PresentLinkLivenessJournalTests: XCTestCase {

  private func journal() throws -> RenderJournal {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("present-link-\(UUID().uuidString)")
    return RenderJournal(capacity: 8, dumpRoot: root)
  }

  func testEntryCarriesPresentLinkLiveness() throws {
    let liveness = PresentLinkLiveness(
      paused: true, hostWantsRunning: false, pendingPresentBudget: 3,
      callbacks: 120, presented: 118, rebuilds: 1, stallRepairs: 1)
    let entry = try journal().makeEntry(
      event: .rendered, frame: 42, tabId: "tab", sessionId: "s", presentLink: liveness)
    let decoded = try JSONDecoder().decode(
      RenderJournal.Entry.self, from: JSONEncoder().encode(entry))
    XCTAssertEqual(decoded.presentLink, liveness)
  }

  /// Dumps written before the field existed must still decode, so old captures
  /// stay readable next to new ones.
  func testEntryWithoutPresentLinkStillDecodes() throws {
    let entry = try journal().makeEntry(
      event: .rendered, frame: 7, tabId: "tab", sessionId: "s")
    XCTAssertNil(entry.presentLink)
    let decoded = try JSONDecoder().decode(
      RenderJournal.Entry.self, from: JSONEncoder().encode(entry))
    XCTAssertNil(decoded.presentLink)
  }

  /// A refused frame must carry WHY it was refused. The field and its plumbing
  /// existed, but the value came from a cast chain naming only `MetalRenderer`
  /// and `SlugGlyphRenderer` — the third copy of that defect — so every vector
  /// refusal recorded a nil reason. That is the difference between "the GPU is
  /// busy, wait" and "something is wrong" when a refusal repeats for seconds.
  func testRefusedFrameCarriesItsFailureReason() throws {
    let entry = try journal().makeEntry(
      event: .renderFailed, frame: 9, tabId: "tab", sessionId: "s",
      reason: "backendRenderReturnedFalse",
      renderFailureReason: .previousFrameInFlight)
    let decoded = try JSONDecoder().decode(
      RenderJournal.Entry.self, from: JSONEncoder().encode(entry))
    XCTAssertEqual(decoded.renderFailureReason, .previousFrameInFlight)
    XCTAssertEqual(decoded.reason, "backendRenderReturnedFalse")
  }

  /// `previousFrameInFlight` says the one-frame-in-flight semaphore is held; it
  /// does not say whether the GPU is retiring work. Pairing the refusal with the
  /// completion count separates "the committed frame genuinely never completed"
  /// (count frozen across the run of refusals) from "the slot was leaked by a
  /// path that never signalled" (count advancing) — a distinction a dump could
  /// not make while a real tab switch sat refused for five seconds.
  func testRefusedFrameCarriesGPUCompletionCount() throws {
    let entry = try journal().makeEntry(
      event: .renderFailed, frame: 11, tabId: "tab", sessionId: "s",
      reason: "backendRenderReturnedFalse",
      renderFailureReason: .previousFrameInFlight,
      gpuFrameCompletions: 3606)
    let decoded = try JSONDecoder().decode(
      RenderJournal.Entry.self, from: JSONEncoder().encode(entry))
    XCTAssertEqual(decoded.gpuFrameCompletions, 3606)
    XCTAssertEqual(decoded.renderFailureReason, .previousFrameInFlight)
  }

  /// The two readings that matter when a frame renders but nothing appears:
  /// a frame is published and waiting (`pendingPresentBudget > 0`) while the
  /// link is parked, and the stall watchdog has had to rebuild a dead link.
  func testLivenessDistinguishesWaitingFrameFromHealthyPark() {
    let waiting = PresentLinkLiveness(
      paused: true, hostWantsRunning: false, pendingPresentBudget: 4,
      callbacks: 10, presented: 10, rebuilds: 0, stallRepairs: 0)
    let idle = PresentLinkLiveness(
      paused: true, hostWantsRunning: false, pendingPresentBudget: 0,
      callbacks: 10, presented: 10, rebuilds: 0, stallRepairs: 0)
    XCTAssertNotEqual(waiting, idle)
    XCTAssertGreaterThan(waiting.pendingPresentBudget, 0)
    XCTAssertEqual(idle.pendingPresentBudget, 0)
  }

  /// Liveness JSON written before `lastCallbackAgeSeconds` existed must still
  /// decode (as nil), so old dumps stay readable next to new ones.
  func testLivenessWithoutCallbackAgeStillDecodes() throws {
    let legacyJSON = """
      {"paused":false,"hostWantsRunning":true,"pendingPresentBudget":0,
       "callbacks":33435,"presented":10850,"rebuilds":733,"stallRepairs":716}
      """
    let decoded = try JSONDecoder().decode(
      PresentLinkLiveness.self, from: Data(legacyJSON.utf8))
    XCTAssertEqual(decoded.callbacks, 33435)
    XCTAssertEqual(decoded.stallRepairs, 716)
    XCTAssertNil(decoded.lastCallbackAgeSeconds)
  }
}
