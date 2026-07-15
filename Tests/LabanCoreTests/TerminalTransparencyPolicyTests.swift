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
    let requested = configuration(opacity: 1)
    let effective = resolve(requested)

    XCTAssertEqual(requested.backgroundImageScaling, .fill)
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

  func testAvailableImageBackdropPreservesRequestedScaling() {
    let requested = configuration(
      opacity: 0.64,
      backdropStyle: .image,
      backgroundImageScaling: .fit)
    let effective = resolve(requested, backgroundImageAvailability: .available)

    XCTAssertEqual(requested.backdropStyle, .image)
    XCTAssertEqual(requested.backgroundImageScaling, .fit)
    XCTAssertEqual(effective.backgroundOpacity, 0.64)
    XCTAssertEqual(effective.backdropStyle, .image)
    XCTAssertNil(effective.forceOpaqueReason)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testUnavailableImageBackdropFailsClosedForEveryVisibleUnavailableState() {
    let requested = configuration(
      opacity: 0.64,
      applyToExplicitCellBackgrounds: true,
      backdropStyle: .image,
      backgroundImageScaling: .stretch)

    for availability in [
      TerminalBackgroundImageAvailability.none,
      .missing,
      .corrupt,
      .headlessUnsupported,
    ] {
      let effective = resolve(
        requested,
        backgroundImageAvailability: availability)
      XCTAssertEqual(effective.backgroundOpacity, 1, availability.rawValue)
      XCTAssertTrue(effective.applyToExplicitCellBackgrounds, availability.rawValue)
      XCTAssertEqual(effective.backdropStyle, .none, availability.rawValue)
      XCTAssertEqual(
        effective.forceOpaqueReason, .backgroundImageUnavailable, availability.rawValue)
      XCTAssertTrue(effective.isSurfaceOpaque, availability.rawValue)
    }

    XCTAssertEqual(requested.backdropStyle, .image)
    XCTAssertEqual(requested.backgroundImageScaling, .stretch)
  }

  func testOpaqueImageRequestDoesNotReportUnavailableInvisibleBackdrop() {
    let effective = resolve(
      configuration(opacity: 1, backdropStyle: .image),
      backgroundImageAvailability: .missing)

    XCTAssertEqual(effective.backgroundOpacity, 1)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertNil(effective.forceOpaqueReason)
    XCTAssertTrue(effective.isSurfaceOpaque)
  }

  func testHeadlessImageRequestPreservesOpacityAndRequestWithoutNativeBackdrop() {
    let requested = configuration(
      opacity: 0.42,
      backdropStyle: .image,
      backgroundImageScaling: .stretch)
    let effective = resolve(
      requested,
      backgroundImageAvailability: .headlessUnsupported,
      headless: true)

    XCTAssertEqual(requested.backdropStyle, .image)
    XCTAssertEqual(requested.backgroundImageScaling, .stretch)
    XCTAssertEqual(effective.backgroundOpacity, 0.42)
    XCTAssertEqual(effective.backdropStyle, .none)
    XCTAssertNil(effective.forceOpaqueReason)
    XCTAssertFalse(effective.isSurfaceOpaque)
  }

  func testImageAvailabilityRestoresRequestedBackdrop() {
    let requested = configuration(
      opacity: 0.58,
      backdropStyle: .image,
      backgroundImageScaling: .fit)
    let missing = resolve(requested, backgroundImageAvailability: .missing)
    let restored = resolve(requested, backgroundImageAvailability: .available)

    XCTAssertEqual(missing.forceOpaqueReason, .backgroundImageUnavailable)
    XCTAssertEqual(missing.backgroundOpacity, 1)
    XCTAssertNil(restored.forceOpaqueReason)
    XCTAssertEqual(restored.backgroundOpacity, 0.58)
    XCTAssertEqual(restored.backdropStyle, .image)
    XCTAssertEqual(requested.backgroundImageScaling, .fit)
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
    let requested = configuration(opacity: 0.7, backdropStyle: .image)

    XCTAssertEqual(
      resolve(
        requested,
        reduceTransparency: true,
        nativeFullscreen: true,
        backgroundImageAvailability: .missing,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .reduceTransparency)
    XCTAssertEqual(
      resolve(
        requested,
        nativeFullscreen: true,
        backgroundImageAvailability: .missing,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .nativeFullscreen)
    XCTAssertEqual(
      resolve(
        requested,
        backgroundImageAvailability: .missing,
        snapshotBackgroundCapability: .legacy
      ).forceOpaqueReason,
      .legacySnapshotWriter)
    XCTAssertEqual(
      resolve(
        requested,
        backgroundImageAvailability: .missing
      ).forceOpaqueReason,
      .backgroundImageUnavailable)
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
    backdropStyle: TerminalBackdropStyle = .none,
    backgroundImageScaling: TerminalBackgroundImageScaling = .default
  ) -> TerminalTransparencyConfiguration {
    TerminalTransparencyConfiguration(
      backgroundOpacity: opacity,
      applyToExplicitCellBackgrounds: applyToExplicitCellBackgrounds,
      backdropStyle: backdropStyle,
      backgroundImageScaling: backgroundImageScaling)
  }

  private func resolve(
    _ requested: TerminalTransparencyConfiguration,
    reduceTransparency: Bool = false,
    nativeFullscreen: Bool = false,
    supportsBehindWindowBlur: Bool = false,
    backgroundImageAvailability: TerminalBackgroundImageAvailability = .none,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability = .inProcess,
    headless: Bool = false
  ) -> EffectiveTerminalTransparency {
    TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: reduceTransparency,
      nativeFullscreen: nativeFullscreen,
      supportsBehindWindowBlur: supportsBehindWindowBlur,
      backgroundImageAvailability: backgroundImageAvailability,
      snapshotBackgroundCapability: snapshotBackgroundCapability,
      headless: headless)
  }
}
