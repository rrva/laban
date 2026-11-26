import XCTest

@testable import LabanCore

/// OSC 7501 Program Status Protocol (spec revision 0.4): report validation
/// and the per-pane record store.
final class ProgramStatusTests: XCTestCase {
  private func parse(_ payload: String) -> ProgramStatusReport? {
    ProgramStatusReport.parse(Array(payload.utf8))
  }

  private func b64(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
  }

  // MARK: - Parsing

  func testSpecExampleParses() {
    // The spec's Terraform example.
    let report = parse(
      "state=blocked:kind=permission:app=terraform:"
        + "msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/")
    XCTAssertEqual(
      report,
      ProgramStatusReport(
        action: .set(.blocked), kind: .permission, app: "terraform",
        message: "Apply 3 to add, 1 to change, 0 to destroy?"))
  }

  func testStateIsRequiredAndMustBeKnown() {
    XCTAssertNil(parse("app=brew"))
    XCTAssertNil(parse("state=paused"), "an unknown state must not degrade to a known one")
    XCTAssertNil(parse("state=Working"), "values are case-sensitive")
    XCTAssertNil(parse(""))
    for state in ["idle", "working", "done", "blocked", "error"] {
      XCTAssertEqual(parse("state=\(state)")?.action, .set(ProgramStatusState(rawValue: state)!))
    }
    XCTAssertEqual(parse("state=clear:id=build")?.action, .clear)
  }

  func testMalformedPairsAndUnknownKeysAreSkippedAndLastValueWins() {
    let report = parse(
      "novalue:=x:STATE=idle:future=1:state=idle:bad=a b:state=working: app = brew ")
    XCTAssertEqual(report, ProgramStatusReport(action: .set(.working), app: "brew"))
  }

  func testOverlongKeyDiscardsReport() {
    XCTAssertNil(parse("state=working:" + String(repeating: "k", count: 17) + "=1"))
    XCTAssertNotNil(parse("state=working:" + String(repeating: "k", count: 16) + "=1"))
  }

  func testIdGrammarAndLimits() {
    XCTAssertEqual(parse("state=working:id=build/test.1+a-b_c")?.id, "build/test.1+a-b_c")
    XCTAssertNil(parse("state=working:id=build//test"), "empty segment")
    XCTAssertNil(parse("state=working:id=/build"))
    XCTAssertNil(parse("state=working:id=a,b"), "an invalid id never falls back to the root")
    XCTAssertNil(parse("state=working:id=" + String(repeating: "s", count: 33)))
    XCTAssertNotNil(parse("state=working:id=a/b/c/d/e/f/g/h"))
    XCTAssertNil(parse("state=working:id=a/b/c/d/e/f/g/h/i"), "nine levels deep")
    let long = Array(repeating: String(repeating: "s", count: 32), count: 4).joined(separator: "/")
    XCTAssertNil(parse("state=working:id=\(long)"), "131 bytes > 128")
  }

  func testKindProgressAndAppAreAbsentWhenInvalid() {
    XCTAssertEqual(parse("state=blocked:kind=auth")?.kind, .auth)
    XCTAssertNil(parse("state=blocked:kind=payment")?.kind)
    XCTAssertNil(parse("state=working:kind=auth")?.kind, "kind only means something when blocked")
    XCTAssertEqual(parse("state=working:progress=40")?.progress, 40)
    XCTAssertEqual(parse("state=blocked:progress=100")?.progress, 100)
    XCTAssertNil(parse("state=working:progress=101")?.progress)
    XCTAssertNil(parse("state=working:progress=+5")?.progress)
    XCTAssertNil(parse("state=working:progress=")?.progress)
    XCTAssertNil(parse("state=done:progress=40")?.progress)
    XCTAssertNotNil(parse("state=working:progress=101"), "the report itself still applies")
    XCTAssertNil(parse("state=idle:app=a/b")?.app)
    XCTAssertNil(parse("state=idle:app=" + String(repeating: "a", count: 33))?.app)
  }

  func testMessageBase64PaddingIsOptional() {
    XCTAssertEqual(parse("state=done:msg=aGk=")?.message, "hi")
    XCTAssertEqual(parse("state=done:msg=aGk")?.message, "hi")
    XCTAssertEqual(parse("state=done:title=\(b64("us-east"))")?.title, "us-east")
  }

  func testBadTextDiscardsWholeReport() {
    XCTAssertNil(parse("state=done:msg=a"), "not base64")
    XCTAssertNil(parse("state=done:msg=aG-_"), "URL-safe alphabet is not standard base64")
    XCTAssertNil(parse("state=done:msg=\(b64("line one\nline two"))"), "newline")
    XCTAssertNil(parse("state=done:msg=\(b64("tab\there"))"))
    XCTAssertNil(parse("state=done:msg=\(b64("esc\u{1b}[31m"))"), "escape sequence")
    XCTAssertNil(parse("state=done:msg=\(b64("c1\u{9b}"))"))
    XCTAssertNil(parse("state=done:msg=//79"), "not UTF-8")
    XCTAssertNil(parse("state=clear:msg=\(b64("a\nb"))"), "checked even on a clear")
  }

  func testTextLimits() {
    let fits = String(repeating: "a", count: 2048)
    XCTAssertEqual(parse("state=done:msg=\(b64(fits))")?.message, fits)
    XCTAssertNil(parse("state=done:msg=\(b64(fits + "a"))"))
    let title = String(repeating: "t", count: 192)
    XCTAssertEqual(parse("state=done:title=\(b64(title))")?.title, title)
    XCTAssertNil(parse("state=done:title=\(b64(title + "t"))"))
    XCTAssertNil(
      parse("state=idle:app=" + String(repeating: "a", count: 4096)), "whole-sequence cap")
  }

  func testInvisibleFormattingIsDisarmed() {
    // A right-to-left override would let "gpj.exe" read as "exe.jpg".
    let report = parse("state=blocked:msg=\(b64("open \u{202E}gpj.exe\u{2066}\u{200B}"))")
    XCTAssertEqual(report?.message, "open gpj.exe")
    XCTAssertEqual(
      parse("state=done:msg=\(b64("👨\u{200D}👩\u{200D}👧"))")?.message, "👨\u{200D}👩\u{200D}👧",
      "the zero-width joiner is kept so emoji sequences survive")
  }

  // MARK: - Sidebar line

  func testSidebarLine() {
    func line(_ payload: String, width: Int = 40) -> String? {
      SidebarProducer.programStatusDisplayLine(
        ProgramStatusRecords.summaryOf(parse(payload)!), maxScalars: width)?.0
    }
    XCTAssertNil(line("state=idle:msg=\(b64("resting"))"), "a program at rest earns no line")
    XCTAssertEqual(line("state=working"), "working…")
    XCTAssertEqual(line("state=working:progress=40"), "▰▰▱▱▱ 40%")
    XCTAssertEqual(line("state=working:progress=40:msg=\(b64("Pushing"))"), "▰▰▱▱▱ 40% Pushing")
    XCTAssertEqual(line("state=blocked:kind=auth"), "needs sign-in")
    XCTAssertEqual(line("state=blocked:msg=\(b64("Approve?"))"), "Approve?")
    XCTAssertEqual(line("state=done"), "done")
    XCTAssertEqual(line("state=error:msg=\(b64("rsync failed"))"), "✗ rsync failed")
    XCTAssertEqual(
      line("state=done:msg=\(b64("Upgraded 12 packages"))", width: 10), "✓ Upgrade…",
      "cut to the row width: an over-wide line is not drawn at all")
  }

  // MARK: - Records

  private func records(_ payloads: String...) -> ProgramStatusRecords {
    recordsOf(payloads)
  }

  private func recordsOf(_ payloads: [String]) -> ProgramStatusRecords {
    var records = ProgramStatusRecords()
    for payload in payloads {
      guard let report = parse(payload) else {
        XCTFail("payload must parse: \(payload)")
        continue
      }
      records.apply(report)
    }
    return records
  }

  func testReportReplacesItsRecordCompletely() {
    let r = records("state=working:app=brew:progress=10:msg=\(b64("Installing"))", "state=working")
    XCTAssertEqual(r.records, [ProgramStatusRecord(id: "", state: .working)])
  }

  func testDeployExampleFromSpec() {
    var r = records(
      "state=working:app=deploy:msg=\(b64("Deploying v2.4.1"))",
      "state=working:id=us-east:progress=40:msg=\(b64("Pushing image"))",
      "state=blocked:id=eu-west:kind=permission:msg=\(b64("Approve deploy to eu-west?"))")
    XCTAssertEqual(r.records.count, 3)
    XCTAssertEqual(r.summary?.id, "eu-west", "a blocked child outranks the working root")
    XCTAssertEqual(r.summary?.app, "deploy", "app is inherited from the root")

    r.apply(parse("state=done:id=us-east:msg=\(b64("Healthy"))")!)
    r.apply(parse("state=clear:id=us-east")!)
    r.apply(parse("state=clear:id=eu-west")!)
    XCTAssertEqual(r.records.map(\.id), [""])
    r.apply(parse("state=done:app=deploy:msg=\(b64("Deployed to 3 regions"))")!)
    XCTAssertEqual(r.summary?.state, .done)
    XCTAssertEqual(r.summary?.message, "Deployed to 3 regions")
  }

  func testClearRemovesSubtreeOnly() {
    var r = records(
      "state=working", "state=working:id=build", "state=working:id=build/test",
      "state=working:id=builder")
    XCTAssertTrue(r.apply(parse("state=clear:id=build")!))
    XCTAssertEqual(r.records.map(\.id), ["", "builder"], "builder is a sibling, not a child")
    XCTAssertFalse(r.apply(parse("state=clear:id=nothing")!), "clearing a missing id is a no-op")
    XCTAssertTrue(r.apply(parse("state=clear")!))
    XCTAssertTrue(r.isEmpty)
  }

  func testAppInheritsFromNearestAncestor() {
    let r = records(
      "state=working:app=root", "state=working:id=a:app=mid", "state=working:id=a/b/c",
      "state=working:id=z")
    XCTAssertEqual(r.effectiveApp(for: r.records[2]), "mid", "a/b is absent; a is nearest")
    XCTAssertEqual(r.effectiveApp(for: r.records[3]), "root")
  }

  func testSummaryPrefersUrgencyThenRecency() {
    XCTAssertNil(ProgramStatusRecords().summary)
    XCTAssertEqual(records("state=done:id=a", "state=idle").summary?.id, "a")
    XCTAssertEqual(
      records("state=working:id=a", "state=error:id=b", "state=done:id=c").summary?.id, "b")
    XCTAssertEqual(records("state=working:id=a", "state=working:id=b").summary?.id, "b")
    XCTAssertEqual(
      records("state=working:id=a", "state=working:id=b", "state=working:id=a").summary?.id, "a")
  }

  func testLifetimes() {
    var r = records(
      "state=idle", "state=working:id=w", "state=blocked:id=b", "state=done:id=d",
      "state=error:id=e")
    XCTAssertTrue(r.dropLiveRecords())
    XCTAssertEqual(r.records.map(\.id), ["d", "e"], "done and error survive exit and prompt")
    XCTAssertFalse(r.dropLiveRecords())
    XCTAssertTrue(r.dropSeenResults())
    XCTAssertTrue(r.isEmpty)
  }

  func testRecordCapEvictsLeastRecentlyUpdated() {
    var r = ProgramStatusRecords()
    for i in 0..<ProgramStatusRecords.maxRecords { r.apply(parse("state=working:id=r\(i)")!) }
    r.apply(parse("state=working:id=r0")!)  // refresh the oldest
    r.apply(parse("state=working:id=new")!)
    XCTAssertEqual(r.records.count, ProgramStatusRecords.maxRecords)
    XCTAssertFalse(r.records.contains { $0.id == "r1" }, "r1 was the least recently updated")
    XCTAssertTrue(r.records.contains { $0.id == "r0" })
  }
}

extension ProgramStatusRecords {
  /// The summary record a pane holding only `report` would show.
  fileprivate static func summaryOf(_ report: ProgramStatusReport) -> ProgramStatusRecord {
    var records = ProgramStatusRecords()
    records.apply(report)
    return records.summary!
  }
}
