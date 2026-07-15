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

  func testOldWriterForcesOpaqueWithoutMutatingRequestedTransparency() {
    let requested = requestedTransparency(opacity: 0.63)
    let oldWriter = LabandHelloResponse(
      protocolVersion: LabandProtocolVersion.current,
      buildVersion: "old-helper",
      capabilities: ["snapshot-ring/v1"])

    let effective = resolve(requested, hello: oldWriter)

    XCTAssertEqual(requested.backgroundOpacity, 0.63)
    XCTAssertTrue(requested.applyToExplicitCellBackgrounds)
    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertTrue(effective.applyToExplicitCellBackgrounds)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.forceOpaqueReason, .legacySnapshotWriter)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testNewWriterRestoresUnchangedRequestedTransparencyAfterOldWriter() {
    let requested = requestedTransparency(opacity: 0.63)
    let oldWriter = LabandHelloResponse(
      protocolVersion: LabandProtocolVersion.current,
      buildVersion: "old-helper",
      capabilities: [])
    let newWriter = LabandHelloResponse(
      protocolVersion: LabandProtocolVersion.current,
      buildVersion: "new-helper",
      capabilities: [LabandCapabilities.snapshotCellExplicitBackgroundV1])

    let downgraded = resolve(requested, hello: oldWriter)
    let restored = resolve(requested, hello: newWriter)

    XCTAssertEqual(downgraded.forceOpaqueReason, .legacySnapshotWriter)
    XCTAssertEqual(downgraded.backgroundOpacity, 1)
    XCTAssertEqual(requested.backgroundOpacity, 0.63)
    XCTAssertNil(restored.forceOpaqueReason)
    XCTAssertEqual(restored.backgroundOpacity, 0.63)
    XCTAssertTrue(restored.applyToExplicitCellBackgrounds)
    XCTAssertFalse(restored.isSurfaceOpaque)
  }

  private func requestedTransparency(opacity: Double) -> TerminalTransparencyConfiguration {
    TerminalTransparencyConfiguration(
      backgroundOpacity: opacity,
      applyToExplicitCellBackgrounds: true,
      backdropStyle: .none)
  }

  private func resolve(
    _ requested: TerminalTransparencyConfiguration,
    hello: LabandHelloResponse
  ) -> EffectiveTerminalTransparency {
    TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: hello.snapshotBackgroundCapability,
      headless: false)
  }
}
