import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// Regression for the descriptor-cache scale bug: the vector renderer memoizes
/// pre-raster glyph geometry (width/height/origin/atlas key), which is
/// scale-dependent. If a scale change rebuilds the atlas but leaves that memo
/// stale, the next frame reserves wrong-sized atlas slots and bakes garbled
/// glyphs at the right positions (the "completely broken" full-window garble
/// seen when the window attached at backing scale 2 after an initial scale-1
/// render). This is exactly the class of bug a full-render before/after
/// comparison catches but a single-scale unit test misses.
final class VectorScaleChangeRegressionTests: XCTestCase {
  private let width = 320
  private let height = 96

  private func commands() -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: 160, height: 48),
        color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 6, y: 14),
        text: "Regression HHnnmmoo 123",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]
  }

  /// A renderer that rendered at scale 1 then resized to scale 2 must produce the
  /// same pixels as a renderer created fresh at scale 2. Before the fix the
  /// reused renderer keeps stale scale-1 descriptors and garbles every glyph.
  func testScaleChangeMatchesFreshRendererPixels() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 14)

    // Path A: born at scale 1, then resized up to scale 2.
    let reused = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: width / 2, pixelHeight: height / 2, scale: 1))
    for _ in 0..<3 { _ = reused.render(commands(), damage: .full) }
    _ = reused.resize(pixelWidth: width, pixelHeight: height, scale: 2)
    var reusedPNG: Data?
    for _ in 0..<6 {
      _ = reused.render(commands(), damage: .full)
      reusedPNG = reused.pngData
    }

    // Path B: born at scale 2.
    let fresh = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: width, pixelHeight: height, scale: 2))
    var freshPNG: Data?
    for _ in 0..<6 {
      _ = fresh.render(commands(), damage: .full)
      freshPNG = fresh.pngData
    }

    let a = try decode(XCTUnwrap(reusedPNG))
    let b = try decode(XCTUnwrap(freshPNG))
    XCTAssertEqual(a.w, b.w)
    XCTAssertEqual(a.h, b.h)

    // The two must be near-identical (jittered AA can differ by a few levels on
    // edge pixels, but a stale-cache garble disagrees grossly on many pixels).
    var grossPixels = 0
    let n = min(a.px.count, b.px.count)
    for i in stride(from: 0, to: n, by: 4) {
      let da = abs(Int(a.px[i]) - Int(b.px[i]))
      if da > 80 { grossPixels += 1 }
    }
    XCTAssertLessThan(
      grossPixels, max(20, (a.w * a.h) / 200),
      "resized-from-scale-1 render garbles vs fresh scale-2 (\(grossPixels) gross px)")
  }

  /// Direct invariant: an ink-bearing render after a scale change has substantial
  /// coverage (a garble that reserves 1x1 slots collapses ink toward nothing or
  /// scatters it). Cheap guard that also documents the contract.
  func testRenderAfterScaleChangeProducesInk() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 14)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: width / 2, pixelHeight: height / 2, scale: 1))
    for _ in 0..<3 { _ = renderer.render(commands(), damage: .full) }
    _ = renderer.resize(pixelWidth: width, pixelHeight: height, scale: 2)
    var png: Data?
    for _ in 0..<6 {
      _ = renderer.render(commands(), damage: .full)
      png = renderer.pngData
    }
    let img = try decode(XCTUnwrap(png))
    var ink = 0
    for i in stride(from: 0, to: img.px.count, by: 4) where img.px[i] > 40 { ink += 1 }
    XCTAssertGreaterThan(ink, 200, "no glyph ink after scale change (stale cache / wrong slots)")
  }

  private func decode(_ data: Data) throws -> (px: [UInt8], w: Int, h: Int) {
    let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    let w = image.width
    let h = image.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = try XCTUnwrap(
      CGContext(
        data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (px, w, h)
  }
}
