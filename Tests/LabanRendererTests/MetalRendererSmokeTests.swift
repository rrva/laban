import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

final class MetalRendererSmokeTests: XCTestCase {

  func testMetalRendererHandlesManyInstancesPerFrame() throws {
    // Regression: setVertexBytes is capped at 4 KB; a fully-populated 160×48
    // grid emits ~7700 glyph + ~7700 solid instances per frame, far past that
    // limit. Verifies the MTLBuffer-backed instance path stays alive.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: 2) else {
      XCTFail("MetalRenderer.init returned nil")
      return
    }
    renderer.resize(pixelWidth: 1640, pixelHeight: 912, scale: 2)

    var cmds: [FrameCommand] = []
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    for row in 0..<48 {
      for col in 0..<160 {
        let r = UInt32((row * 7 + col) & 0xFF)
        let g = UInt32((col * 5 + row * 3) & 0xFF)
        let b = UInt32((row * col) & 0xFF)
        let color = (r << 24) | (g << 16) | (b << 8) | 0xFF
        cmds.append(
          .rect(
            CGRect(
              x: CGFloat(col) * cellW, y: CGFloat(row) * cellH,
              width: cellW, height: cellH),
            color: color, source: .terminal))
      }
    }
    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    for row in 0..<48 {
      let line = String(asciiPrintable.prefix(160).suffix(160))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xADBC_BCFF,
          background: 0x103C_48FF,
          attributes: [],
          source: .terminal))
    }

    // Render many frames to also catch issues that show up only after the
    // instance buffers have been reused several times.
    for _ in 0..<8 {
      renderer.render(cmds)
    }
  }

  func testMetalRendererInitializesAndRendersOneFrame() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      // CI without a Metal-capable device — skip rather than fail.
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: 2) else {
      XCTFail("MetalRenderer.init returned nil — shaders or pipelines failed to build")
      return
    }
    renderer.resize(pixelWidth: 320, pixelHeight: 192, scale: 2)

    // A minimal frame: one fg-coloured rect plus a glyph run.
    let cmds: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 160, height: 96), color: 0x103C_48FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 8, y: 8),
        text: "hello mvp",
        foreground: 0xADBC_BCFF,
        background: 0x103C_48FF,
        attributes: [],
        source: .terminal),
      .cursor(CGRect(x: 8, y: 8, width: 9, height: 19), color: 0xADBC_BCFF),
    ]
    renderer.render(cmds)
    XCTAssertNotNil(renderer.presentationLayer, "Metal renderer must expose a CAMetalLayer")
    XCTAssertNil(
      renderer.presentationImage,
      "Metal renderer self-presents; presentationImage must be nil")
    // pngData rides on the readback texture filled during render.
    XCTAssertNotNil(renderer.pngData, "pngData should produce a PNG after the first render")
  }
}
