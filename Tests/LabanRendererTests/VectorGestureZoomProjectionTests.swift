import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// The continuous-zoom gesture scales the whole vector canvas by applying a
/// factor in the renderer's vertex projection (NOT a CALayer transform, which
/// races the self-presenting render loop). This proves the projection zoom
/// actually scales rendered pixels: a centered rect covers ~zoom^2 more area at
/// zoom 2 than at zoom 1, and clears back to the original at zoom 1.
final class VectorGestureZoomProjectionTests: XCTestCase {
  private func makeRenderer(pw: Int, ph: Int) throws -> VectorGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    return try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas, pixelWidth: pw, pixelHeight: ph, scale: 1))
  }

  /// Count non-background (red) pixels in the rendered surface.
  private func filledPixelCount(_ renderer: VectorGlyphRenderer) throws -> Int {
    let png = try XCTUnwrap(renderer.pngData)
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw XCTSkip("failed to decode PNG") }
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
      else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var count = 0
    for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i] > 40 { count += 1 }
    return count
  }

  func testProjectionZoomScalesCanvasArea() throws {
    let pw = 400
    let ph = 400
    let renderer = try makeRenderer(pw: pw, ph: ph)

    // A red rect centered ON the surface centre (the zoom anchor) so a 2x zoom
    // grows it symmetrically (150..250 -> 100..300) and stays within bounds.
    // A black full-surface terminal background (so the frame clears to black via
    // fullRedrawClearColor — the FIRST terminal rect), then a centered red marker
    // rect whose covered area we measure as it scales.
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 400, height: 400), color: 0x00_00_00_FF, source: .terminal),
      .rect(
        CGRect(x: 150, y: 150, width: 100, height: 100), color: 0xFF_00_00_FF, source: .terminal),
    ]

    renderer.setGestureZoom(1, anchor: CGPoint(x: pw / 2, y: ph / 2))
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let base = try filledPixelCount(renderer)
    XCTAssertGreaterThan(base, 1000, "the rect must render at zoom 1")

    renderer.setGestureZoom(2, anchor: CGPoint(x: pw / 2, y: ph / 2))
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let zoomed = try filledPixelCount(renderer)

    // 2x linear → ~4x area. Allow generous tolerance for AA/clipping.
    let ratio = Double(zoomed) / Double(base)
    XCTAssertGreaterThan(
      ratio, 3.0, "2x projection zoom must ~quadruple covered area (got \(ratio))")
    XCTAssertLessThan(ratio, 5.0, "area must not balloon beyond ~4x (got \(ratio))")

    // Clearing back to 1 restores the original coverage (no stuck zoom).
    renderer.setGestureZoom(1, anchor: CGPoint(x: pw / 2, y: ph / 2))
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let cleared = try filledPixelCount(renderer)
    XCTAssertEqual(
      Double(cleared), Double(base), accuracy: Double(base) * 0.05,
      "zoom must clear back to identity coverage")
  }

  /// The zoom-out margin clear must match the terminal background under any
  /// theme. The vector target is sRGB, so the clear color must be linearized the
  /// same way the background rect's color is (via vectorColor/srgbToLinear) — a
  /// raw sRGB value double-encodes a light theme (e.g. selenized-light cream)
  /// toward white. Probe the actually-cleared corner pixel against the bg rect's
  /// own rendered color.
  func testZoomOutMarginMatchesThemeBackground() throws {
    let pw = 300
    let ph = 300
    let renderer = try makeRenderer(pw: pw, ph: ph)
    // selenized-light background: cream 0xFB_F3_DB.
    let bg: UInt32 = 0xFB_F3_DB_FF
    // Full-surface bg rect (covers everything at zoom 1) so a corner pixel is the
    // rendered background; the clear color must produce the SAME corner pixel.
    let full: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 300, height: 300), color: bg, source: .terminal)
    ]
    XCTAssertTrue(renderer.render(full, damage: .full))
    let rendered = try cornerPixel(renderer)

    // Now zoom out so the bg rect shrinks and the corner shows the CLEAR color.
    renderer.setGestureZoom(0.5, anchor: CGPoint(x: pw / 2, y: ph / 2))
    XCTAssertTrue(renderer.render(full, damage: .full))
    let cleared = try cornerPixel(renderer)

    // The clear margin must match the rendered background (the actual bug: a
    // double-encoded clear would NOT match the correctly-linearized rect). The
    // double-encode bug specifically crushes the blue channel toward 255 (cream
    // 0xFB_F3_DB has B=0xDB=219, well below 255); a raw-sRGB clear would push it
    // up. So assert per-channel equality AND that blue stays cream, not white.
    for (a, b) in zip(cleared, rendered) {
      XCTAssertEqual(Int(a), Int(b), accuracy: 4, "zoom-out margin must match theme background")
    }
    XCTAssertEqual(Int(cleared[2]), 0xDB, accuracy: 6, "cream blue channel must not blow to white")
  }

  /// Top-left corner pixel (R,G,B) of the rendered surface.
  private func cornerPixel(_ renderer: VectorGlyphRenderer) throws -> [UInt8] {
    let png = try XCTUnwrap(renderer.pngData)
    guard let src = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { throw XCTSkip("failed to decode PNG") }
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
      else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return [bytes[0], bytes[1], bytes[2]]
  }

  func testGestureZoomGuardsAgainstInvalidFactors() throws {
    let renderer = try makeRenderer(pw: 100, ph: 100)
    renderer.setGestureZoom(0, anchor: .zero)
    XCTAssertEqual(renderer.gestureZoom, 1, "zero factor must fall back to identity")
    renderer.setGestureZoom(-3, anchor: .zero)
    XCTAssertEqual(renderer.gestureZoom, 1, "negative factor must fall back to identity")
    renderer.setGestureZoom(.nan, anchor: .zero)
    XCTAssertEqual(renderer.gestureZoom, 1, "NaN factor must fall back to identity")
    renderer.setGestureZoom(1.7, anchor: CGPoint(x: 5, y: 5))
    XCTAssertEqual(renderer.gestureZoom, 1.7, accuracy: 1e-6)
  }
}
