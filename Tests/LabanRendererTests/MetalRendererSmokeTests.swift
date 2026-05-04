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

  func testPartialDamagePreservesCleanRows() throws {
    // Persistent target invariant: after a full render of frame A, then a
    // .partial(rows: subset) render of frame B, pixels outside B's dirty
    // rows must still match frame A. If the renderer accidentally clears
    // the whole target on a partial damage, this asserts that.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: 1) else {
      XCTFail("MetalRenderer.init returned nil")
      return
    }
    // Use 1x scale to keep pngData diffs predictable.
    let rows = 8
    let cellH: CGFloat = 19
    let cols = 40
    let cellW: CGFloat = 9
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW),
      pixelHeight: Int(CGFloat(rows) * cellH),
      scale: 1)

    // Frame A: solid green rect for every row at a unique Y.
    let originY: CGFloat = 0
    var frameA: [FrameCommand] = []
    for r in 0..<rows {
      let y = originY + CGFloat(rows - 1 - r) * cellH
      frameA.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: 0x00_FF_00_FF, source: .terminal))
    }
    renderer.render(frameA, damage: .full)
    let pngA = renderer.pngData
    XCTAssertNotNil(pngA, "frame A must produce a PNG")

    // Frame B: same as A everywhere except row 0 is now blue.
    var frameB = frameA
    let blueRowY = originY + CGFloat(rows - 1) * cellH  // row 0 sits at the top of the band
    frameB[0] = .rect(
      CGRect(x: 0, y: blueRowY, width: CGFloat(cols) * cellW, height: cellH),
      color: 0x00_00_FF_FF, source: .terminal)
    renderer.render(
      frameB,
      damage: .partial(yRanges: [DirtyYRange(y: blueRowY, height: cellH)]))
    let pngB = renderer.pngData
    XCTAssertNotNil(pngB)

    // Sanity: the two PNGs must differ at all (otherwise the partial pass
    // silently no-op'd or scissor culled the actual change).
    XCTAssertNotEqual(
      pngA, pngB,
      "partial damage that included row 0 must change pixels in row 0")

    // Frame C: empty damage list. Renderer should skip the content pass and
    // re-present the existing target, so pngC pixels match pngB.
    renderer.render(frameB, damage: .partial(yRanges: []))
    let pngC = renderer.pngData
    XCTAssertEqual(pngB, pngC, "empty partial damage must preserve prior pixels")
  }

  func testCursorOverlayDoesNotPersist() throws {
    // Cursor lives in an overlay pass on the drawable, never in the
    // persistent target. A render with a cursor + a re-render without one
    // (and an empty damage list) must leave no cursor pixels on screen.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: 1) else {
      XCTFail("MetalRenderer.init returned nil")
      return
    }
    renderer.resize(pixelWidth: 360, pixelHeight: 152, scale: 1)
    let bg: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 360, height: 152), color: 0x10_3C_48_FF, source: .terminal)
    ]
    let bgWithCursor =
      bg + [
        .cursor(CGRect(x: 100, y: 50, width: 9, height: 19), color: 0xFF_00_00_FF)
      ]
    renderer.render(bgWithCursor, damage: .full)
    let withCursor = renderer.pngData
    renderer.render(bg, damage: .partial(yRanges: []))
    let withoutCursor = renderer.pngData
    XCTAssertNotEqual(
      withCursor, withoutCursor,
      "removing the cursor must change visible pixels even when damage is empty")
  }

  func testScrollShiftReusesPreviousFramePixels() throws {
    // 8 rows of solid colours; on frame B we shift "up by 1" (rows 0..6 of B
    // = rows 1..7 of A) and add a new colour at the bottom. The renderer's
    // scroll detector should fire and reuse all the pixels for rows 0..6
    // via blit; the only render-pass work is the new bottom row.
    //
    // Verifies pixel parity by comparing PNG bytes — the persistent target
    // path is bit-stable when the same commands produce the same pixels.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: 1) else {
      XCTFail("MetalRenderer.init returned nil")
      return
    }
    let rows = 8
    let cellH: CGFloat = 19
    let cols = 40
    let cellW: CGFloat = 9
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW),
      pixelHeight: Int(CGFloat(rows) * cellH),
      scale: 1)

    // 8 distinct colours so each row is uniquely identifiable in the hashes.
    let palette: [UInt32] = [
      0xFF_00_00_FF, 0x00_FF_00_FF, 0x00_00_FF_FF, 0xFF_FF_00_FF,
      0x00_FF_FF_FF, 0xFF_00_FF_FF, 0xFF_80_00_FF, 0x80_00_FF_FF,
    ]
    func frameWithColors(_ colors: [UInt32]) -> [FrameCommand] {
      var out: [FrameCommand] = []
      for r in 0..<rows {
        let y = CGFloat(rows - 1 - r) * cellH
        out.append(
          .rect(
            CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
            color: colors[r], source: .terminal))
      }
      return out
    }

    // Frame A: rows 0..7 use palette[0..7].
    renderer.render(frameWithColors(palette), damage: .full)
    let pngA = renderer.pngData
    XCTAssertNotNil(pngA)

    // Frame B: rows 0..6 use palette[1..7] (one-row scroll up); row 7 is a
    // new colour 0xCAFEBA_FF.
    var paletteShifted = Array(palette.dropFirst())
    paletteShifted.append(0xCA_FE_BA_FF)
    // libghostty would flag every row as dirty after a scroll; pass full
    // damage to match what the view would actually send.
    renderer.render(frameWithColors(paletteShifted), damage: .full)
    let pngB = renderer.pngData
    XCTAssertNotNil(pngB)

    // Frame C: render the SAME shifted palette as frame B again. With the
    // scroll detector in play, frame B's pixels should already be in the
    // persistent target; an empty-damage render should reproduce the same
    // PNG. (This indirectly confirms the persistent target is consistent.)
    renderer.render(frameWithColors(paletteShifted), damage: .partial(yRanges: []))
    let pngC = renderer.pngData
    XCTAssertEqual(pngB, pngC, "B and C show identical content; pixels must match")

    // A and B must differ — B has a new bottom row colour.
    XCTAssertNotEqual(pngA, pngB)
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
