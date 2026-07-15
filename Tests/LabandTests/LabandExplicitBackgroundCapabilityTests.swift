import LabanCore
import XCTest

final class LabandExplicitBackgroundCapabilityTests: XCTestCase {
  func testNewHelloClassifiesExplicitBackgroundWriterAsSupported() {
    let hello = LabandHelloResponse(
      protocolVersion: LabandProtocolVersion.current,
      buildVersion: "new-helper",
      capabilities: [LabandCapabilities.snapshotCellExplicitBackgroundV1])

    XCTAssertEqual(hello.snapshotBackgroundCapability, .supported)
  }

  func testOldHelloWithoutCapabilityClassifiesWriterAsLegacy() {
    let hello = LabandHelloResponse(
      protocolVersion: LabandProtocolVersion.current,
      buildVersion: "old-helper",
      capabilities: ["snapshot-ring/v1"])

    XCTAssertEqual(hello.snapshotBackgroundCapability, .legacy)
  }

  func testLifecycleConnectDecisionCarriesTypedCapabilityClassification() {
    let policy = LabandLifecyclePolicy()
    let supported = policy.decision(
      hello: LabandHelloResponse(
        protocolVersion: LabandProtocolVersion.current,
        buildVersion: "new-helper",
        capabilities: [LabandCapabilities.snapshotCellExplicitBackgroundV1]),
      liveSessions: [])
    let legacy = policy.decision(
      hello: LabandHelloResponse(
        protocolVersion: LabandProtocolVersion.current,
        buildVersion: "old-helper",
        capabilities: []),
      liveSessions: [])

    XCTAssertEqual(supported.snapshotBackgroundCapability, .supported)
    XCTAssertEqual(legacy.snapshotBackgroundCapability, .legacy)
  }

  func testInProcessClassificationIsDistinctFromNegotiatedRemoteSupport() {
    XCTAssertNotEqual(
      TerminalSnapshotBackgroundCapability.inProcess,
      TerminalSnapshotBackgroundCapability.supported)
  }
}
