import Foundation
import XCTest

@testable import LabanApp

final class AboutInfoTests: XCTestCase {
  func testDaemonStartedBeforeTheInstalledBinaryIsOlder() {
    let started = Date(timeIntervalSince1970: 1_000)
    let stale = AboutInfo.SessionDaemon(
      pid: 1, startedAt: started, binaryModifiedAt: started.addingTimeInterval(600))
    XCTAssertTrue(stale.isOlderThanInstalledBinary)
    let current = AboutInfo.SessionDaemon(
      pid: 1, startedAt: started, binaryModifiedAt: started.addingTimeInterval(-600))
    XCTAssertFalse(current.isOlderThanInstalledBinary)
    let unknown = AboutInfo.SessionDaemon(pid: 1, startedAt: started, binaryModifiedAt: nil)
    XCTAssertFalse(unknown.isOlderThanInstalledBinary)
  }

  func testNoDaemonsForABinaryNobodyRuns() {
    let missing = URL(fileURLWithPath: "/nonexistent/laban-\(UUID().uuidString)/labpty")
    XCTAssertEqual(AboutInfo.sessionDaemons(labptyURL: missing), [])
  }

  func testCodeSigningSummaries() {
    let team = AboutInfo.CodeSigning(
      kind: .certificate("Developer ID Application: Example (ABCDE12345)"),
      teamID: "ABCDE12345", hardenedRuntime: true, notarized: false)
    XCTAssertEqual(team.summary, "Developer ID Application: Example (ABCDE12345)")
    XCTAssertEqual(team.details, "team ABCDE12345, hardened runtime, not notarized")
    let adHoc = AboutInfo.CodeSigning(
      kind: .adHoc, teamID: nil, hardenedRuntime: false, notarized: false)
    XCTAssertEqual(adHoc.summary, "Ad-hoc (no team identity)")
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
