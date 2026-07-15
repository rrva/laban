import XCTest

@testable import LabanCore

final class TerminalTransparencyPolicyTests: XCTestCase {
  func testConfigurationClampsOpacityAtInitializationAndMutation() {
    XCTAssertEqual(configuration(opacity: -0.25).backgroundOpacity, 0)
    XCTAssertEqual(configuration(opacity: 1.25).backgroundOpacity, 1)
    XCTAssertEqual(configuration(opacity: -.infinity).backgroundOpacity, 0)
    XCTAssertEqual(configuration(opacity: .infinity).backgroundOpacity, 1)
    XCTAssertEqual(configuration(opacity: .nan).backgroundOpacity, 1)

    var requested = configuration(opacity: 0.7)
    requested.backgroundOpacity = 2
    XCTAssertEqual(requested.backgroundOpacity, 1)
    requested.backgroundOpacity = -2
    XCTAssertEqual(requested.backgroundOpacity, 0)
  }

  func testDefaultOpaqueRequestResolvesToOpaqueSurface() {
    let effective = resolve(configuration(opacity: 1))

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertFalse(effective.applyToExplicitCellBackgrounds)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertNil(effective.forceOpaqueReason)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testDirectTransparencyPreservesOpacityAndExplicitCellChoice() {
    let effective = resolve(
      configuration(opacity: 0.7, applyToExplicitCellBackgrounds: true))

    XCTAssertEqual(effective.backgroundOpacity, 0.7)
    XCTAssertTrue(effective.applyToExplicitCellBackgrounds)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertNil(effective.forceOpaqueReason)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testSupportedSystemBlurRemainsEffectiveForTranslucentSurface() {
    let effective = resolve(
      configuration(opacity: 0.9, backdropStyle: .systemBlur),
      supportsBehindWindowBlur: true)

    XCTAssertEqual(effective.backgroundOpacity, 0.9)
    XCTAssertEqual(effective.backdropStyle, .systemBlur)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testUnavailableSystemBlurResolvesToNoneWithoutChangingRequest() {
    let requested = configuration(opacity: 0.9, backdropStyle: .systemBlur)
    let effective = resolve(requested, supportsBehindWindowBlur: false)

    XCTAssertEqual(requested.backdropStyle, .systemBlur)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.backgroundOpacity, 0.9)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testHeadlessSystemBlurResolvesToNoneEvenWhenSupported() {
    let requested = configuration(opacity: 0.9, backdropStyle: .systemBlur)
    let effective = resolve(
      requested,
      supportsBehindWindowBlur: true,
      headless: true)

    XCTAssertEqual(requested.backdropStyle, .systemBlur)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.backgroundOpacity, 0.9)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testExactlyOpaqueRequestSuppressesAvailableSystemBlur() {
    let effective = resolve(
      configuration(opacity: 1, backdropStyle: .systemBlur),
      supportsBehindWindowBlur: true)

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testReduceTransparencyForcesOpaqueAndPreservesRequestedCellChoice() {
    let effective = resolve(
      configuration(
        opacity: 0.7,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur),
      reduceTransparency: true,
      supportsBehindWindowBlur: true)

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertTrue(effective.applyToExplicitCellBackgrounds)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.forceOpaqueReason, .reduceTransparency)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testNativeFullscreenForcesOpaque() {
    let effective = resolve(
      configuration(opacity: 0.7),
      nativeFullscreen: true)

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.forceOpaqueReason, .nativeFullscreen)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testLegacySnapshotWriterForcesOpaque() {
    let effective = resolve(
      configuration(opacity: 0.7),
      snapshotBackgroundCapability: .legacy)

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertEqual(effective.forceOpaqueReason, .legacySnapshotWriter)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testInProcessAndSupportedSnapshotWritersAllowTransparency() {
    for capability in [
      TerminalSnapshotBackgroundCapability.inProcess,
      TerminalSnapshotBackgroundCapability.supported,
    ] {
      let effective = resolve(
        configuration(opacity: 0.7),
        snapshotBackgroundCapability: capability)

      XCTAssertEqual(effective.backgroundOpacity, 0.7)
      XCTAssertNil(effective.forceOpaqueReason)
      XCTAssertFalse(effective.isSurfaceOpaque)
    }
  }

  func testForceOpaqueReasonPriorityIsDeterministic() {
    let requested = configuration(opacity: 0.7)

    XCTAssertEqual(
      resolve(
        requested,
        reduceTransparency: true,
        nativeFullscreen: true,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .reduceTransparency)
    XCTAssertEqual(
      resolve(
        requested,
        nativeFullscreen: true,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .nativeFullscreen)
    XCTAssertEqual(
      resolve(
        requested,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .legacySnapshotWriter)
  }

  func testRemovingOneOverrideDoesNotRestoreWhileAnotherRemains() {
    let requested = configuration(opacity: 0.7)

    let both = resolve(
      requested,
      reduceTransparency: true,
      nativeFullscreen: true)
    let fullscreenOnly = resolve(requested, nativeFullscreen: true)

    XCTAssertEqual(both.forceOpaqueReason, .reduceTransparency)
    XCTAssertEqual(fullscreenOnly.forceOpaqueReason, .nativeFullscreen)
    XCTAssertEqual(fullscreenOnly.backgroundOpacity, 1)
    XCTAssertTrue(fullscreenOnly.isSurfaceOpaque)
  }

  func testRequestedConfigurationRestoresAfterTemporaryOverridesEnd() {
    let requested = configuration(
      opacity: 0.73,
      applyToExplicitCellBackgrounds: true,
      backdropStyle: .systemBlur)

    let forced = resolve(
      requested,
      reduceTransparency: true,
      supportsBehindWindowBlur: true)
    let restored = resolve(
      requested,
      supportsBehindWindowBlur: true)

    XCTAssertEqual(forced.backgroundOpacity, 1)
    XCTAssertEqual(forced.forceOpaqueReason, .reduceTransparency)
    XCTAssertEqual(restored.backgroundOpacity, 0.73)
    XCTAssertTrue(restored.applyToExplicitCellBackgrounds)
    XCTAssertEqual(restored.backdropStyle, .systemBlur)
    XCTAssertNil(restored.forceOpaqueReason)
    XCTAssertFalse(restored.isSurfaceOpaque)
  }

  func testLegacySessionRestoresRequestWhenCapabilityBecomesKnown() {
    let requested = configuration(opacity: 0.63, backdropStyle: .none)

    let legacy = resolve(
      requested,
      snapshotBackgroundCapability: .legacy)
    let supported = resolve(
      requested,
      snapshotBackgroundCapability: .supported)

    XCTAssertEqual(legacy.forceOpaqueReason, .legacySnapshotWriter)
    XCTAssertEqual(legacy.backgroundOpacity, 1)
    XCTAssertNil(supported.forceOpaqueReason)
    XCTAssertEqual(supported.backgroundOpacity, 0.63)
    XCTAssertFalse(supported.isSurfaceOpaque)
  }

  private func configuration(
    opacity: Double,
    applyToExplicitCellBackgrounds: Bool = false,
    backdropStyle: TerminalBackdropStyle = .none
  ) -> TerminalTransparencyConfiguration {
    TerminalTransparencyConfiguration(
      backgroundOpacity: opacity,
      applyToExplicitCellBackgrounds: applyToExplicitCellBackgrounds,
      backdropStyle: backdropStyle)
  }

  private func resolve(
    _ requested: TerminalTransparencyConfiguration,
    reduceTransparency: Bool = false,
    nativeFullscreen: Bool = false,
    supportsBehindWindowBlur: Bool = false,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability = .inProcess,
    headless: Bool = false
  ) -> EffectiveTerminalTransparency {
    TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: supportsBehindWindowBlur,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      headless: headless)
  }
}
