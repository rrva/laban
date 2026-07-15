import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class TransparencyDiagnosticsTests: XCTestCase {
  func testLiveRouterBindsAllTypedTransparencyHandlers() throws {
    let router = LiveIntentRouter(model: nil)
    var background: (Double, Bool)?
    var resetCount = 0
    var overrideValues: [Bool?] = []
    var fullscreenValues: [Bool] = []
    let state = sampleState()
    router.bindTransparencyControl(
      state: { state },
      setBackground: { background = ($0, $1) },
      resetDiagnostics: { resetCount += 1 },
      setReduceTransparencyOverride: { overrideValues.append($0) },
      setNativeFullScreen: { fullscreenValues.append($0) })

    XCTAssertEqual(
      router.route(action(#"{"action":"setBackgroundTransparency","opacity":2,"applyToExplicitCellBackgrounds":true}"#)).status,
      200)
    XCTAssertEqual(background?.0, 1)
    XCTAssertEqual(background?.1, true)
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
