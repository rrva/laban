import AppKit
import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class AboutInfoTests: XCTestCase {
  func testDaemonsOfAnotherBinaryAreNotThisApps() {
    // Discovery lists every labpty of this user; none can be launched from a
    // path that does not exist.
    let missing = URL(fileURLWithPath: "/nonexistent/laban-\(UUID().uuidString)/labpty")
    let daemons = AboutInfo.sessionDaemons(labptyURL: missing)
    XCTAssertTrue(daemons.allSatisfy { !$0.isThisAppsBinary })
    XCTAssertTrue(daemons.allSatisfy { $0.runsDifferentBuild == nil }, "no installed hash to compare")
  }

  func testMappedExecutableMatchesTheFileOnDisk() throws {
    // This test process runs its own executable: the mapped file and the file
    // at that path are the same until something replaces the path.
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    XCTAssertGreaterThan(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)), 0)
    let path = String(cString: buffer)
    let mapped = try XCTUnwrap(AboutInfo.mappedExecutableIdentity(pid: getpid(), path: path))
    XCTAssertEqual(mapped, AboutInfo.fileIdentity(atPath: path))
    XCTAssertNil(AboutInfo.fileIdentity(atPath: "/nonexistent/binary"))
  }

  func testCodeSigningSummaries() {
    let team = AboutInfo.CodeSigning(
      kind: .certificate("Developer ID Application: Example (ABCDE12345)"),
      teamID: "ABCDE12345", hardenedRuntime: true, notarized: false)
    XCTAssertEqual(team.summary, "Developer ID Application: Example (ABCDE12345)")
    XCTAssertEqual(team.details, "team ABCDE12345, hardened runtime, not notarized")
    let adHoc = AboutInfo.CodeSigning(
      kind: .adHoc, teamID: nil, hardenedRuntime: false, notarized: false)
    XCTAssertEqual(adHoc.summary, "Ad-hoc signature (local build, no team identity)")
    let unsigned = AboutInfo.CodeSigning(
      kind: .unsigned, teamID: nil, hardenedRuntime: false, notarized: false)
    XCTAssertEqual(unsigned.summary, "Not signed")
  }

  func testSystemFontAndThemeRowsDescribeTheMachine() {
    let system = AboutInfo.systemSummary()
    XCTAssertTrue(system.hasPrefix("macOS "), system)
    XCTAssertTrue(system.contains("arm64") || system.contains("x86_64"), system)

    let defaults = UserDefaults(suiteName: "laban-about-font-\(getpid())")!
    defer { defaults.removePersistentDomain(forName: "laban-about-font-\(getpid())") }
    XCTAssertEqual(AboutInfo.fontSummary(defaults: defaults), "JetBrains Mono (bundled), 14 pt")
    defaults.set("Menlo", forKey: "LabanFontName")
    defaults.set(13.5, forKey: "LabanFontSize")
    XCTAssertEqual(AboutInfo.fontSummary(defaults: defaults), "Menlo, 13.5 pt")

    XCTAssertTrue(
      AboutInfo.themeSummary(appearance: NSAppearance(named: .darkAqua)!).contains("dark mode"))
  }

  func testSelfTestSummaryCountsTurnedOffSeparately() {
    typealias R = TerminalCapabilitySelfTest.Result
    func result(_ status: TerminalCapabilitySelfTest.Status) -> R {
      R(name: "n", purpose: "p", status: status, reply: "r")
    }
    XCTAssertEqual(
      AboutWindowController.selfTestSummary([result(.passed), result(.passed)]).text, "2 passed")
    let off = AboutWindowController.selfTestSummary([result(.passed), result(.disabled)])
    XCTAssertEqual(off.text, "1 passed, 1 turned off")
    XCTAssertTrue(off.allPassed)
    let failed = AboutWindowController.selfTestSummary([result(.failed), result(.disabled)])
    XCTAssertEqual(failed.text, "0 passed, 1 turned off, 1 failed")
    XCTAssertFalse(failed.allPassed)
  }

  func testReadsARealSignature() {
    // The test runner is ad-hoc signed by the toolchain; reading it must not
    // report a team identity it does not have.
    let signing = AboutInfo.codeSigning(bundleURL: Bundle(for: Self.self).bundleURL)
    XCTAssertNotEqual(signing.kind, .unsigned)
    if signing.kind == .adHoc { XCTAssertNil(signing.teamID) }
  }

  func testVTCoreSummary() {
    let core = AboutInfo.VTCore(
      commit: "7c40388b2c63b7dcc5d6c9b9804e40fb2574444f", patches: ["0001-a", "0002-b"])
    XCTAssertEqual(core.summary, "libghostty-vt 7c40388b2 (Ghostty), 2 local patches")
  }
}
