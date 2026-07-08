import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlProcessIdentityAndSigningTests: XCTestCase {

  func testCurrentProcessIdentityIsAvailable() {
    let inspector = ControlProcessTreeInspector()
    let pid = pid_t(ProcessInfo.processInfo.processIdentifier)

    let identity = inspector.identity(for: pid)
    XCTAssertNotNil(identity)
    XCTAssertEqual(identity?.pid, pid)
    XCTAssertEqual(identity?.uid, getuid())
    XCTAssertNotNil(identity?.startTime)
    XCTAssertNotNil(identity?.executablePath)
    XCTAssertFalse(identity?.executablePath?.isEmpty ?? true)

    let parentPID = inspector.parentPID(of: pid)
    XCTAssertNotNil(parentPID)
    XCTAssertGreaterThan(parentPID ?? 0, 0)
  }

  #if canImport(Security)
    func testCurrentProcessCodeSigningRoundTrip() throws {
      let signing = ControlCodeSigning()
      let inspector = ControlProcessTreeInspector()
      let pid = pid_t(ProcessInfo.processInfo.processIdentifier)

      let identity = try XCTUnwrap(inspector.identity(for: pid))
      let startTime = try XCTUnwrap(identity.startTime)

      let signingIdentity = signing.identity(forLivePID: pid, startTime: startTime)

      if let signingIdentity, let requirement = signingIdentity.designatedRequirement {
        XCTAssertTrue(
          signing.validateLivePID(pid, startTime: startTime, requirement: requirement))
        XCTAssertFalse(
          signing.validateLivePID(pid, startTime: startTime, requirement: "anchor bogus"))
      } else {
        throw XCTSkip("current process is not code-signed; cannot validate live identity")
      }
    }

    func testAuditTokenCodeSigningRejectsGarbageToken() {
      let signing = ControlCodeSigning()
      let bogusToken = Data(repeating: 0, count: 32)
      XCTAssertNil(signing.identity(forAuditToken: bogusToken))
      XCTAssertFalse(signing.validate(auditToken: bogusToken, requirement: "anchor apple"))
    }

    func testAuditTokenCodeSigningRejectsShortData() {
      let signing = ControlCodeSigning()
      let shortToken = Data(repeating: 0, count: 16)
      XCTAssertNil(signing.identity(forAuditToken: shortToken))
      XCTAssertFalse(signing.validate(auditToken: shortToken, requirement: "anchor apple"))
    }
  #endif

  #if canImport(Security)
    func testStartTimeMismatchFailsClosed() {
      let signing = ControlCodeSigning()
      let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
      let wrongStartTime = Date(timeIntervalSince1970: 0)

      XCTAssertNil(signing.identity(forLivePID: pid, startTime: wrongStartTime))
      XCTAssertFalse(
        signing.validateLivePID(pid, startTime: wrongStartTime, requirement: "anchor apple"))
    }

    func testInvalidPIDFailsClosed() {
      let signing = ControlCodeSigning()
      let invalidPID = pid_t(Int32.max)
      let startTime = Date()

      XCTAssertNil(signing.identity(forLivePID: invalidPID, startTime: startTime))
      XCTAssertFalse(
        signing.validateLivePID(invalidPID, startTime: startTime, requirement: "anchor apple"))
    }
  #endif
}
