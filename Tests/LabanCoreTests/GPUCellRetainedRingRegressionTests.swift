import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanCore

final class GPUCellRetainedRingRegressionTests: XCTestCase {
  private let rows = 24
  private let cols = 67
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 1

  override func tearDown() {
    MetalRenderer.useGPUCellPath = false
    super.tearDown()
  }

  func testGPUCellRetainedLabptyClaudeUIRepaintsOnFirstSnapshotAfterCleanRenderState() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let bytes = try loadLabptyClaudeFixture()
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    XCTAssertEqual(session.feedOutput(bytes), 0)
    XCTAssertTrue(session.renderDirty(), "retained bytes must dirty the parser render state")
    XCTAssertEqual(session.markRendered(), 0)
    XCTAssertFalse(session.renderDirty(), "fixture models retained content after dirty rows were consumed")

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: Int(cellW),
      cellHeight: Int(cellH),
      sidebarWidth: 0)

    func makeFrame(_ frameNumber: Int, forceFullDamage: Bool) throws -> TerminalSurfaceFrame {
      try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: frameNumber,
            viewportWidth: CGFloat(cols) * cellW,
            viewportHeight: CGFloat(rows) * cellH,
            now: Date(timeIntervalSince1970: 1_234),
            reduceMotion: true,
            requireActiveSnapshot: true,
            forceFullDamage: forceFullDamage,
            surfaceWidth: Int(CGFloat(cols) * cellW * scale),
            surfaceHeight: Int(CGFloat(rows) * cellH * scale),
            surfaceScale: Double(scale),
            contentMode: .cellPayloadPreferred)))
    }

    let frame = try makeFrame(1, forceFullDamage: false)
    guard case .full = frame.damage else {
      XCTFail("first snapshot after retained replay must force full damage, got \(frame.damage)")
      return
    }
    let payload = try XCTUnwrap(
      frame.cellPayload,
      "gpu-driven local frames should use the cell payload path")
    XCTAssertFalse(
      payload.glyphs.isEmpty,
      "first retained repaint must include all visible glyphs even when renderDirty was already consumed")

    let commandFrame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 2,
          viewportWidth: CGFloat(cols) * cellW,
          viewportHeight: CGFloat(rows) * cellH,
          now: Date(timeIntervalSince1970: 1_234),
          reduceMotion: true,
          requireActiveSnapshot: true,
          forceFullDamage: true,
          surfaceWidth: Int(CGFloat(cols) * cellW * scale),
          surfaceHeight: Int(CGFloat(rows) * cellH * scale),
          surfaceScale: Double(scale),
          contentMode: .commands)))
    XCTAssertGreaterThan(
      commandFrame.commands.count,
      frame.commands.count,
      "the command-mode fallback frame should contain terminal glyph commands")

    MetalRenderer.useGPUCellPath = true
    let renderer = try makeRenderer(label: "retained-labpty-gpu-cell")
    guard renderer.effectiveRendererMode == .gpuDriven else {
      throw XCTSkip("gpu-driven renderer is unavailable on this OS")
    }
    let blankCommands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x00_00_00_FF,
        source: .terminal)
    ]
    XCTAssertTrue(renderer.render(blankCommands, damage: .full), "initial blank render failed")
    renderer.waitForLastFrame()
    let blankPNG = try XCTUnwrap(renderer.pngData)

    XCTAssertTrue(
      renderer.render(
        frame.commands + frame.overlayCommands,
        cellPayload: frame.cellPayload,
        damage: frame.damage,
        rendererFallbackReason: nil),
      "retained labpty gpu-cell render failed")
    renderer.waitForLastFrame()
    let retainedPNG = try XCTUnwrap(renderer.pngData)

    XCTAssertGreaterThan(
      renderer.lastInstanceCounts.cellGlyphs,
      0,
      "retained labpty repaint must build GPU cell glyph instances, not only repaint background")
    XCTAssertNotEqual(
      retainedPNG,
      blankPNG,
      "gpu-driven retained labpty frame must repaint nonblank Claude UI even when the snapshot is clean")
  }

  private func loadLabptyClaudeFixture() throws -> [UInt8] {
    let url = Bundle.module.url(
      forResource: "labpty-paste-rendering",
      withExtension: "bin")
    let path = url?.path ?? "Tests/LabanCoreTests/Fixtures/labpty-paste-rendering.bin"
    return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
  }

  private func makeRenderer(label: String) throws -> MetalRenderer {
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("\(label): MetalRenderer.init returned nil")
      throw TestFailure()
    }
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: scale)
    return renderer
  }

  private struct TestFailure: Error {}
}
