import Foundation
import XCTest

@testable import LabanCore

final class LabanDiagnosticsTests: XCTestCase {
  func testDaemonsOfAnotherBinaryAreNotThisApps() {
    // Discovery lists every labpty of this user; none can be launched from a
    // path that does not exist.
    let missing = URL(fileURLWithPath: "/nonexistent/laban-\(UUID().uuidString)/labpty")
    let daemons = LabanDiagnostics.sessionDaemons(labptyURL: missing)
    XCTAssertTrue(daemons.allSatisfy { !$0.isThisAppsBinary })
    XCTAssertTrue(daemons.allSatisfy { $0.runsDifferentBuild == nil }, "no installed hash to compare")
  }

  func testMappedExecutableMatchesTheFileOnDisk() throws {
    // This test process runs its own executable: the mapped file and the file
    // at that path are the same until something replaces the path.
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    XCTAssertGreaterThan(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)), 0)
    let path = String(cString: buffer)
    let mapped = try XCTUnwrap(LabanDiagnostics.mappedExecutableIdentity(pid: getpid(), path: path))
    XCTAssertEqual(mapped, LabanDiagnostics.fileIdentity(atPath: path))
    XCTAssertNil(LabanDiagnostics.fileIdentity(atPath: "/nonexistent/binary"))
  }

  func testCodeSigningSummaries() {
    let team = LabanDiagnostics.CodeSigning(
      kind: .certificate("Developer ID Application: Example (ABCDE12345)"),
      teamID: "ABCDE12345", hardenedRuntime: true, notarized: false)
    XCTAssertEqual(team.summary, "Developer ID Application: Example (ABCDE12345)")
    XCTAssertEqual(team.details, "team ABCDE12345, hardened runtime, not notarized")
    let adHoc = LabanDiagnostics.CodeSigning(
      kind: .adHoc, teamID: nil, hardenedRuntime: false, notarized: false)
    XCTAssertEqual(adHoc.summary, "Ad-hoc signature (local build, no team identity)")
    let unsigned = LabanDiagnostics.CodeSigning(
      kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    XCTAssertEqual(unsigned.summary, "Not signed")
  }

  func testSystemAndFontRowsDescribeTheMachine() {
    let system = LabanDiagnostics.systemSummary()
    XCTAssertTrue(system.hasPrefix("macOS "), system)
    XCTAssertTrue(system.contains("arm64") || system.contains("x86_64"), system)

    let defaults = UserDefaults(suiteName: "laban-about-font-\(getpid())")!
    defer { defaults.removePersistentDomain(forName: "laban-about-font-\(getpid())") }
    XCTAssertEqual(LabanDiagnostics.fontSummary(defaults: defaults), "JetBrains Mono (bundled), 14 pt")
    defaults.set("Menlo", forKey: "LabanFontName")
    defaults.set(13.5, forKey: "LabanFontSize")
    XCTAssertEqual(LabanDiagnostics.fontSummary(defaults: defaults), "Menlo, 13.5 pt")

  }

  func testSelfTestSummaryCountsTurnedOffSeparately() {
    typealias R = TerminalCapabilitySelfTest.Result
    func result(_ status: TerminalCapabilitySelfTest.Status) -> R {
      R(name: "n", purpose: "p", status: status, reply: "r")
    }
    XCTAssertEqual(
      LabanDiagnostics.selfTestSummary([result(.passed), result(.passed)]).text, "2 passed")
    let off = LabanDiagnostics.selfTestSummary([result(.passed), result(.disabled)])
    XCTAssertEqual(off.text, "1 passed, 1 turned off")
    XCTAssertTrue(off.allPassed)
    let failed = LabanDiagnostics.selfTestSummary([result(.failed), result(.disabled)])
    XCTAssertEqual(failed.text, "0 passed, 1 turned off, 1 failed")
    XCTAssertFalse(failed.allPassed)
  }

  func testReadsARealSignature() {
    // The test runner is ad-hoc signed by the toolchain; reading it must not
    // report a team identity it does not have.
    let signing = LabanDiagnostics.codeSigning(bundleURL: Bundle(for: Self.self).bundleURL)
    XCTAssertNotEqual(signing.kind, .unsigned)
    if signing.kind == .adHoc { XCTAssertNil(signing.teamID) }
  }

  func testVTCoreSummary() {
    let core = LabanDiagnostics.VTCore(
      commit: "7c40388b2c63b7dcc5d6c9b9804e40fb2574444f", patches: ["0001-a", "0002-b"])
    XCTAssertEqual(core.summary, "libghostty-vt 7c40388b2 (Ghostty), 2 local patches")
  }

  func testSectionsCarryAppFactsOnlyWhenGiven() {
    let cli = LabanDiagnostics.sections()
    XCTAssertEqual(cli.map(\.title), ["Build", "Components", "What programs see"])
    let cliLabels = Set(cli.flatMap { $0.rows.map(\.label) })
    XCTAssertFalse(cliLabels.contains("Renderer"), "the CLI cannot know the renderer")
    XCTAssertTrue(cliLabels.isSuperset(of: ["Version", "Signed by", "Terminal engine", "TERM"]))

    let app = LabanDiagnostics.sections(
      app: .init(
        updates: "u", renderer: "slugGlyph", theme: "t", display: "d", kittyImagesInUse: 2))
    let appRows = app.flatMap(\.rows)
    XCTAssertTrue(appRows.contains(LabanDiagnostics.Row("Renderer", "slugGlyph")))
    XCTAssertTrue(appRows.contains(LabanDiagnostics.Row("Updates", "u")))
  }

  func testTextAlignsRowsAndIndentsContinuationLines() {
    let text = LabanDiagnostics.text(sections: [
      .init(title: "S", rows: [.init("A", "one"), .init("Long", "two\nthree")])
    ])
    XCTAssertEqual(text, "S\n  A     one\n  Long  two\n        three\n")
  }
}
