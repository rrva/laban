import Foundation
import LabanCore
import LabanRenderer
import XCTest

@testable import LabanDebug

final class TransparencyHeadlessTests: XCTestCase {
  func testInitialOpacityReachesFrameCommandsAndDebugProjection() throws {
    let runtime = try makeRuntime(opacity: 0.7, cells: false)
    let state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedOpacity, 0.7, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 0.7, accuracy: 0.0001)
    XCTAssertFalse(state.surfaceOpaque)
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.snapshotExplicitBackgroundCapability, "inProcess")
    XCTAssertEqual(state.backdropSubviewCount, 0)

    let (terminalAlpha, sidebarAlpha) = runtime.withRuntimeLock {
      let terminal = runtime.lastFrameCommands.compactMap { command -> UInt8? in
        guard case .rect(_, let color, .terminal, .replace) = command else { return nil }
        return UInt8(color & 0xFF)
      }.first
      let sidebar = runtime.lastFrameCommands.compactMap { command -> UInt8? in
        guard case .rect(_, let color, .sidebar, .replace) = command else { return nil }
        return UInt8(color & 0xFF)
      }.first
      return (terminal, sidebar)
    }
    XCTAssertEqual(terminalAlpha, 179)
    XCTAssertEqual(sidebarAlpha, 255)
  }

  func testTypedActionsPreserveRequestAcrossReduceTransparencyOverride() throws {
    let runtime = try makeRuntime(opacity: 1, cells: false)
    _ = runtime.applyAction(
      Data(#"{"action":"resetTransparencyDiagnostics"}"#.utf8))
    _ = runtime.applyAction(
      Data(
        #"{"action":"setBackgroundTransparency","opacity":0.55,"applyToExplicitCellBackgrounds":true,"backdropStyle":"systemBlur"}"#
          .utf8))
    var state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedOpacity, 0.55, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 0.55, accuracy: 0.0001)
    XCTAssertTrue(state.applyToExplicitCellBackgrounds)
    XCTAssertEqual(state.requestedBackdropStyle, "systemBlur")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backdropSubviewCount, 0)
    XCTAssertEqual(state.effectiveTransparencyApplyCount, 1)
    XCTAssertEqual(state.transparencyRenderWakeCount, 1)
    XCTAssertEqual(state.rendererPresentCount, 1)

    _ = runtime.applyAction(
      Data(#"{"action":"resetTransparencyDiagnostics"}"#.utf8))
    _ = runtime.applyAction(
      Data(#"{"action":"setReduceTransparencyOverride","enabled":true}"#.utf8))
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedOpacity, 0.55, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 1, accuracy: 0.0001)
    XCTAssertEqual(state.forceOpaqueReason, "reduceTransparency")
    XCTAssertEqual(state.accessibilityRefreshCount, 1)
    XCTAssertEqual(state.effectiveTransparencyApplyCount, 1)
    XCTAssertEqual(state.transparencyRenderWakeCount, 1)
    XCTAssertEqual(state.rendererPresentCount, 1)

    _ = runtime.applyAction(
      Data(#"{"action":"setReduceTransparencyOverride","enabled":null}"#.utf8))
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedOpacity, 0.55, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 0.55, accuracy: 0.0001)
    XCTAssertNil(state.reduceTransparencyOverride)
  }

  func testHeadlessPreservesRequestedBlurAndLegacyActionOmission() throws {
    let runtime = try makeRuntime(opacity: 0.7, cells: false, effect: .systemBlur)
    var state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "systemBlur")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backdropSubviewCount, 0)

    let legacyResponse = runtime.applyAction(
      Data(
        #"{"action":"setBackgroundTransparency","opacity":0.6,"applyToExplicitCellBackgrounds":true}"#
          .utf8))
    XCTAssertEqual(legacyResponse.status, 200)
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "systemBlur")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backdropSubviewCount, 0)

    let disableResponse = runtime.applyAction(
      Data(
        #"{"action":"setBackgroundTransparency","opacity":0.6,"applyToExplicitCellBackgrounds":true,"backdropStyle":"none"}"#
          .utf8))
    XCTAssertEqual(disableResponse.status, 200)
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "none")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backdropSubviewCount, 0)
  }

  private func makeRuntime(
    opacity: Double,
    cells: Bool,
    effect: TerminalBackdropStyle = .none
  ) throws -> HeadlessDebugRuntime {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-transparency-headless-\(UUID().uuidString)")
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: root,
      tempURL: nil,
      deterministic: true,
      runId: root.lastPathComponent,
      sessionMode: .fixture,
      rendererSelection: .software,
      backgroundOpacity: opacity,
      backgroundEffect: effect,
      applyTransparencyToExplicitCellBackgrounds: cells,
      restorePersistedState: false)
  }

  private func decode(_ response: DebugResponse) throws -> TerminalTransparencyDebugResponse {
    XCTAssertEqual(response.status, 200)
    return try JSONDecoder().decode(TerminalTransparencyDebugResponse.self, from: response.body)
  }
}
