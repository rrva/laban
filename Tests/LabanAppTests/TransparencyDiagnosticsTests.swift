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
    var sourceValues: [TerminalBackdropStyle] = []
    var scalingValues: [TerminalBackgroundImageScaling] = []
    var imports: [(String, TerminalBackgroundImageScaling)] = []
    var removalCount = 0
    let state = sampleState()
    router.bindTransparencyControl(
      state: { state },
      setBackground: { backgrounds.append(($0, $1, $2)) },
      resetDiagnostics: { resetCount += 1 },
      setReduceTransparencyOverride: { overrideValues.append($0) },
      setNativeFullScreen: { fullscreenValues.append($0) },
      setBackgroundSource: { sourceValues.append($0) },
      setBackgroundImageScaling: { scalingValues.append($0) },
      importBackgroundImage: { imports.append(($0, $1)) },
      removeBackgroundImage: { removalCount += 1 })

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
    XCTAssertEqual(
      router.route(action(#"{"action":"setBackgroundSource","source":"image"}"#)).status, 200)
    XCTAssertEqual(
      router.route(
        action(#"{"action":"setBackgroundImageScaling","scaling":"stretch"}"#)
      ).status,
      200)
    XCTAssertEqual(
      router.route(
        action(
          #"{"action":"importBackgroundImage","path":"images/backdrop.svg","scaling":"fit"}"#)
      ).status,
      200)
    XCTAssertEqual(
      router.route(action(#"{"action":"removeBackgroundImage"}"#)).status, 200)
    XCTAssertEqual(resetCount, 1)
    XCTAssertEqual(overrideValues.count, 1)
    XCTAssertNil(overrideValues[0])
    XCTAssertEqual(fullscreenValues, [true])
    XCTAssertEqual(sourceValues, [.image])
    XCTAssertEqual(scalingValues, [.stretch])
    XCTAssertEqual(imports.first?.0, "images/backdrop.svg")
    XCTAssertEqual(imports.first?.1, .fit)
    XCTAssertEqual(removalCount, 1)

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

  func testCorruptImageAvailabilityUsesExactDebugWireValue() throws {
    var state = sampleState()
    state.backgroundImageState = TerminalBackgroundImageAvailability.corrupt.rawValue

    let body = try JSONEncoder().encode(state)
    let projection = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(projection["backgroundImageState"] as? String, "corrupt")
  }

  func testLiveRouterProjectsResetReduceTransparencyOverrideAsJSONNull() throws {
    let router = LiveIntentRouter(model: nil)
    var state = sampleState()
    router.bindTransparencyControl(
      state: { state },
      setBackground: { _, _, _ in },
      resetDiagnostics: {},
      setReduceTransparencyOverride: { state.reduceTransparencyOverride = $0 },
      setNativeFullScreen: { _ in },
      setBackgroundSource: { _ in },
      setBackgroundImageScaling: { _ in },
      importBackgroundImage: { _, _ in },
      removeBackgroundImage: {})

    XCTAssertEqual(
      router.route(action(#"{"action":"setReduceTransparencyOverride","enabled":false}"#)).status,
      200)
    var response = router.query(LegacyDebugQueryInput(intentID: "transparency.state"))
    var projection = try XCTUnwrap(
      JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertEqual(projection["reduceTransparencyOverride"] as? Bool, false)

    XCTAssertEqual(
      router.route(action(#"{"action":"setReduceTransparencyOverride","enabled":null}"#)).status,
      200)
    response = router.query(LegacyDebugQueryInput(intentID: "transparency.state"))
    projection = try XCTUnwrap(
      JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertTrue(projection.keys.contains("reduceTransparencyOverride"))
    XCTAssertTrue(projection["reduceTransparencyOverride"] is NSNull)
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
      backdropSubviewKind: TerminalBackdropStyle.none.rawValue,
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
