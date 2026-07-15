import Foundation
import ImageIO
import LabanCore
import LabanRenderer
import UniformTypeIdentifiers
import XCTest

@testable import LabanDebug

final class TransparencyHeadlessTests: XCTestCase {
  func testInitialOpacityReachesFrameCommandsAndDebugProjection() throws {
    let runtime = try makeRuntime(opacity: 0.7, cells: false)
    let response = runtime.transparencyState()
    let state = try decode(response)
    let json = try XCTUnwrap(
      JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    XCTAssertTrue(json["backgroundImageIdentifier"] is NSNull)
    XCTAssertTrue(json["backgroundImagePixelWidth"] is NSNull)
    XCTAssertTrue(json["backgroundImagePixelHeight"] is NSNull)
    XCTAssertTrue(json["backgroundImageContentDigest"] is NSNull)
    XCTAssertEqual(state.requestedOpacity, 0.7, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 0.7, accuracy: 0.0001)
    XCTAssertFalse(state.surfaceOpaque)
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.snapshotExplicitBackgroundCapability, "inProcess")
    XCTAssertEqual(state.backdropSubviewCount, 0)
    XCTAssertEqual(state.backdropSubviewKind, "none")

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

  func testHeadlessPreservesRequestedImageAndScalingWithoutNativeSource() throws {
    let runtime = try makeRuntime(
      opacity: 0.43,
      cells: true,
      effect: .image,
      scaling: .stretch)
    var state = try decode(runtime.transparencyState())

    XCTAssertEqual(state.requestedOpacity, 0.43, accuracy: 0.0001)
    XCTAssertEqual(state.effectiveOpacity, 0.43, accuracy: 0.0001)
    XCTAssertEqual(state.requestedBackdropStyle, "image")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backgroundImageScaling, "stretch")
    XCTAssertEqual(state.backgroundImageState, "headlessUnsupported")
    XCTAssertNil(state.forceOpaqueReason)
    XCTAssertFalse(state.surfaceOpaque)
    XCTAssertEqual(state.backdropSubviewCount, 0)

    let legacyResponse = runtime.applyAction(
      Data(
        #"{"action":"setBackgroundTransparency","opacity":0.5,"applyToExplicitCellBackgrounds":false}"#
          .utf8))
    XCTAssertEqual(legacyResponse.status, 200)
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "image")
    XCTAssertEqual(state.backgroundImageScaling, "stretch")
    XCTAssertEqual(state.backgroundImageState, "headlessUnsupported")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backdropSubviewCount, 0)
  }

  func testContainedImageActionsPreserveHeadlessParityAndURLFreeDiagnostics() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-transparency-image-actions-\(UUID().uuidString)")
    let fixtureRoot = root.appendingPathComponent("fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let sourceURL = fixtureRoot.appendingPathComponent("gradient.png")
    try writeImage(to: sourceURL)
    let runtime = try makeRuntime(
      opacity: 0.6,
      cells: false,
      fixtureRootURL: fixtureRoot,
      artifactsURL: root.appendingPathComponent("artifacts", isDirectory: true))

    XCTAssertEqual(
      runtime.applyAction(
        Data(
          #"{"action":"importBackgroundImage","path":"gradient.png","scaling":"fit"}"#.utf8)
      ).status,
      200)
    var state = try decode(runtime.transparencyState())
    let identifier = try XCTUnwrap(state.backgroundImageIdentifier)
    XCTAssertTrue(identifier.hasPrefix("image-"))
    XCTAssertFalse(identifier.contains("/"))
    XCTAssertEqual(state.backgroundImagePixelWidth, 4)
    XCTAssertEqual(state.backgroundImagePixelHeight, 2)
    XCTAssertEqual(state.backgroundImageContentDigest?.count, 64)
    XCTAssertEqual(state.backgroundImageImportCount, 1)
    XCTAssertEqual(state.backgroundImageDecodeCount, 1)
    XCTAssertEqual(state.backgroundImageFileReadCount, 1)
    XCTAssertEqual(state.backgroundImageApplyCount, 0)
    XCTAssertEqual(state.backgroundImageRedrawCount, 0)
    XCTAssertEqual(state.requestedBackdropStyle, "image")
    XCTAssertEqual(state.effectiveBackdropStyle, "none")
    XCTAssertEqual(state.backgroundImageState, "headlessUnsupported")
    XCTAssertEqual(state.backgroundImageScaling, "fit")
    XCTAssertFalse(
      String(data: runtime.transparencyState().body, encoding: .utf8)!.contains(root.path))

    let presentCount = state.rendererPresentCount
    XCTAssertEqual(
      runtime.applyAction(
        Data(#"{"action":"setBackgroundImageScaling","scaling":"stretch"}"#.utf8)
      ).status,
      200)
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.backgroundImageScaling, "stretch")
    XCTAssertEqual(state.rendererPresentCount, presentCount)
    XCTAssertEqual(state.backgroundImageDecodeCount, 1)
    XCTAssertEqual(state.backgroundImageFileReadCount, 1)

    _ = runtime.applyAction(
      Data(#"{"action":"setBackgroundSource","source":"none"}"#.utf8))
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "none")
    XCTAssertEqual(state.backgroundImageIdentifier, identifier)

    _ = runtime.applyAction(Data(#"{"action":"removeBackgroundImage"}"#.utf8))
    state = try decode(runtime.transparencyState())
    XCTAssertEqual(state.requestedBackdropStyle, "none")
    XCTAssertNil(state.backgroundImageIdentifier)
  }

  func testImageImportRejectsAbsoluteTraversalAndSymlinkFixturePaths() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-transparency-image-denial-\(UUID().uuidString)")
    let fixtureRoot = root.appendingPathComponent("fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.png")
    try writeImage(to: outside)
    let link = fixtureRoot.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let runtime = try makeRuntime(
      opacity: 0.6,
      cells: false,
      fixtureRootURL: fixtureRoot,
      artifactsURL: root.appendingPathComponent("artifacts", isDirectory: true))

    for path in [outside.path, "../outside.png", "link.png"] {
      let body = try JSONSerialization.data(withJSONObject: [
        "action": "importBackgroundImage",
        "path": path,
        "scaling": "fill",
      ])
      XCTAssertEqual(runtime.applyAction(body).status, 400, path)
    }
    let state = try decode(runtime.transparencyState())
    XCTAssertNil(state.backgroundImageIdentifier)
    XCTAssertEqual(state.backgroundImageImportCount, 0)
    XCTAssertEqual(state.backgroundImageDecodeCount, 0)
    XCTAssertEqual(state.backgroundImageFileReadCount, 0)
  }

  private func makeRuntime(
    opacity: Double,
    cells: Bool,
    effect: TerminalBackdropStyle = .none,
    scaling: TerminalBackgroundImageScaling = .default,
    fixtureRootURL: URL? = nil,
    artifactsURL: URL? = nil
  ) throws -> HeadlessDebugRuntime {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-transparency-headless-\(UUID().uuidString)")
    return try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifactsURL ?? root,
      tempURL: nil,
      deterministic: true,
      runId: root.lastPathComponent,
      fixtureRootURL: fixtureRootURL,
      sessionMode: .fixture,
      rendererSelection: .software,
      backgroundOpacity: opacity,
      backgroundEffect: effect,
      backgroundImageScaling: scaling,
      applyTransparencyToExplicitCellBackgrounds: cells,
      restorePersistedState: false)
  }

  private func writeImage(to url: URL) throws {
    let context = CGContext(
      data: nil,
      width: 4,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 16,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  private func decode(_ response: DebugResponse) throws -> TerminalTransparencyDebugResponse {
    XCTAssertEqual(response.status, 200)
    return try JSONDecoder().decode(TerminalTransparencyDebugResponse.self, from: response.body)
  }
}
