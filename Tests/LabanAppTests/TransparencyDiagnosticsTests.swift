import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class TransparencyDiagnosticsTests: XCTestCase {
  func testLiveRouterBindsAllTypedTransparencyHandlers() throws {
    let router = LiveIntentRouter(model: nil)
    var backgrounds: [(Double, Bool, TerminalBackdropStyle?)] = []
    var resetCount = 0
    var overrideValues: [Bool?] = []
    var fullscreenValues: [Bool] = []
    let state = sampleState()
    router.bindTransparencyControl(
      state: { state },
      setBackground: { backgrounds.append(($0, $1, $2)) },
      resetDiagnostics: { resetCount += 1 },
      setReduceTransparencyOverride: { overrideValues.append($0) },
      setNativeFullScreen: { fullscreenValues.append($0) })

    XCTAssertEqual(
      router.route(
        action(
          #"{"action":"setBackgroundTransparency","opacity":2,"applyToExplicitCellBackgrounds":true,"backdropStyle":"systemBlur"}"#
        )
      ).status,
      200)
    XCTAssertEqual(backgrounds[0].0, 1)
    XCTAssertEqual(backgrounds[0].1, true)
    XCTAssertEqual(backgrounds[0].2, .systemBlur)
    XCTAssertEqual(
      router.route(
        action(
          #"{"action":"setBackgroundTransparency","opacity":0.4,"applyToExplicitCellBackgrounds":false}"#
        )
      ).status,
      200)
    XCTAssertEqual(backgrounds[1].0, 0.4)
    XCTAssertEqual(backgrounds[1].1, false)
    XCTAssertNil(backgrounds[1].2)
    XCTAssertEqual(
      router.route(
        action(
          #"{"action":"setBackgroundTransparency","opacity":0.4,"applyToExplicitCellBackgrounds":false,"backdropStyle":"system-blur"}"#
        )
      ).status,
      400)
    XCTAssertEqual(backgrounds.count, 2)
    XCTAssertEqual(
      router.route(action(#"{"action":"resetTransparencyDiagnostics"}"#)).status, 200)
    XCTAssertEqual(
      router.route(action(#"{"action":"setReduceTransparencyOverride","enabled":null}"#)).status,
      200)
    XCTAssertEqual(
      router.route(action(#"{"action":"setNativeFullScreen","enabled":true}"#)).status, 200)
    XCTAssertEqual(resetCount, 1)
    XCTAssertEqual(overrideValues.count, 1)
    XCTAssertNil(overrideValues[0])
    XCTAssertEqual(fullscreenValues, [true])

    let projection = router.query(
      LegacyDebugQueryInput(intentID: "transparency.state"))
    XCTAssertEqual(projection.status, 200)
    XCTAssertEqual(
      try JSONDecoder().decode(TerminalTransparencyDebugResponse.self, from: projection.body),
      state)
  }

  func testGUIFixtureGateRequiresBothEnvironmentInputs() {
    XCTAssertFalse(MainWindowController.shouldEnableIsolatedGUIFixtureControl(environment: [:]))
    XCTAssertFalse(
      MainWindowController.shouldEnableIsolatedGUIFixtureControl(
        environment: [ControlEnvironmentKeys.guiFixtureControl: "1"]))
    XCTAssertFalse(
      MainWindowController.shouldEnableIsolatedGUIFixtureControl(
        environment: ["LABAN_CONTROL_DIR": "/tmp/isolated"]))
    XCTAssertTrue(
      MainWindowController.shouldEnableIsolatedGUIFixtureControl(
        environment: [
          ControlEnvironmentKeys.guiFixtureControl: "1",
          "LABAN_CONTROL_DIR": "/tmp/isolated",
        ]))
  }

  private func action(_ body: String) -> Intent {
    let envelope = try! JSONDecoder().decode(DebugActionEnvelope.self, from: Data(body.utf8))
    return .legacyDebugAction(
      LegacyDebugActionInput(
        intentID: DebugActionIntentID.intentID(forAction: envelope.action)!,
        action: envelope.action,
        body: Data(body.utf8)))
  }

  private func sampleState() -> TerminalTransparencyDebugResponse {
    TerminalTransparencyDebugResponse(
      requestedOpacity: 0.7,
      effectiveOpacity: 0.7,
      requestedBackdropStyle: "none",
      effectiveBackdropStyle: "none",
      backgroundImageScaling: "fill",
      backgroundImageState: "none",
      applyToExplicitCellBackgrounds: false,
      forceOpaqueReason: nil,
      surfaceOpaque: false,
      effectiveGlyphAntialiasing: "grayscale",
      effectiveGlyphAntialiasingReason: "transparentSurface",
      snapshotExplicitBackgroundCapability: "inProcess",
      configuredRenderer: "slugGlyph",
      effectiveRenderer: "slugGlyph",
      backdropSubviewCount: 0,
      systemReduceTransparency: false,
      reduceTransparencyOverride: nil,
      effectiveReduceTransparency: false,
      nativeFullscreen: false,
      accessibilityRefreshCount: 0,
      effectiveTransparencyApplyCount: 0,
      transparencyRenderWakeCount: 0,
      rendererPresentCount: 0,
      presentIntervalDeadlineMisses: 0)
  }
}
