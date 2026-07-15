import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// M6 gate: smooth sub-pixel scroll. Setting a sub-cell scroll phase offset must
/// move rendered glyphs by a *sub-pixel* amount through the vector backend (via
/// the M4 per-phase masks) — not snap to whole rows and not fall back to the
/// raster path. The vertical ink centroid of the presented frame must shift
/// monotonically as the phase sweeps across one device pixel.
final class VectorSmoothScrollTests: XCTestCase {
  // MARK: - Pure phase quantization

  func testQuantizedPhaseMapsSignedRemainderWithoutWrapping() {
    // +0.25 px at scale 2 = +0.125 pt -> q = round(0.25*256) = 64.
    let pos = VectorGlyphRenderer.quantizedPhase(pointOffset: CGPoint(x: 0, y: 0.125), scale: 2)
    XCTAssertEqual(pos.qy, 64)
    XCTAssertEqual(pos.sampleOffset.y, -64.0 / 256.0, accuracy: 1e-9)  // Y negated (kernel Y-down)

    // A negative remainder must stay negative (NOT wrap to +0.75 px).
    let neg = VectorGlyphRenderer.quantizedPhase(pointOffset: CGPoint(x: 0, y: -0.125), scale: 2)
    XCTAssertEqual(neg.qy, -64)
    XCTAssertEqual(neg.sampleOffset.y, 64.0 / 256.0, accuracy: 1e-9)

    // Zero offset -> phase 0 (static text keeps its single phase-0 mask).
    let zero = VectorGlyphRenderer.quantizedPhase(pointOffset: .zero, scale: 2)
    XCTAssertEqual(zero.qx, 0)
    XCTAssertEqual(zero.qy, 0)
    XCTAssertEqual(zero.sampleOffset, .zero)
  }

  func testQuantizedPhaseClampsBeyondHalfPixel() {
    // Anything past the snap range clamps to ±0.5 px rather than aliasing.
    let big = VectorGlyphRenderer.quantizedPhase(pointOffset: CGPoint(x: 0, y: 9.0), scale: 2)
    XCTAssertEqual(big.qy, 128)  // +0.5 px
  }

  // MARK: - End-to-end sub-pixel motion through the live pipeline

  func testGlyphCentroidShiftsSubPixelAcrossPhases() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

    let scale: CGFloat = 2
    let width = 256
    let height = 120
    let atlas = FontAtlas(pointSize: 28, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: width, pixelHeight: height, scale: scale))

    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
        color: 0x00_00_00_FF, source: .terminal, compositing: .replace),
      // Full-height stems give a stable vertical centroid; thin horizontal
      // strokes wobble under AA redistribution and don't measure position well.
      .glyphRun(
        origin: CGPoint(x: 8, y: 30),
        text: "HHHHH",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]

    // Sweep a sub-cell phase across a full device pixel (-0.5 .. +0.5 px). A
    // positive phase shifts ink up the panel (smaller top-down centroid Y).
    let phaseDevicePixels: [CGFloat] = [-0.5, -0.25, 0.0, 0.25, 0.5]
    var centroids: [Double] = []
    for devpx in phaseDevicePixels {
      renderer.setScrollPhaseOffset(CGPoint(x: 0, y: devpx / scale))
      var png: Data?
      for _ in 0..<6 {
        XCTAssertTrue(renderer.render(commands, damage: .full))
        png = renderer.pngData
      }
      // The vector backend must stay effective — no raster fallback for plain
      // ASCII through the vector path.
      XCTAssertEqual(renderer.lastRasterFallbackGlyphs, 0, "vector backend fell back to raster")
      centroids.append(try inkCentroidY(png: XCTUnwrap(png)))
    }

    // Across a full device pixel of phase the centroid must move by ~1 px (clear
    // motion, but well under a row) — proof the glyphs glide rather than snap.
    let totalShift = abs(centroids.last! - centroids.first!)
    XCTAssertGreaterThan(totalShift, 0.5, "phase sweep produced too little motion: \(centroids)")
    XCTAssertLessThan(totalShift, 2.0, "phase sweep jumped more than a pixel — snapped, not smooth")
    // Monotonic in the expected direction (+phase -> up -> decreasing top-down Y),
    // with a small slack for AA centroid noise.
    for i in 1..<centroids.count {
      XCTAssertLessThanOrEqual(
        centroids[i] - centroids[i - 1], 0.06,
        "centroid moved the wrong way (non-monotonic): \(centroids)")
    }
    // Distinct phases must place ink at distinct positions.
    XCTAssertNotEqual(centroids.first!, centroids.last!)
  }

  func testGlyphCentroidShiftsSubPixelAcrossHorizontalPhases() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

    let scale: CGFloat = 2
    let width = 256
    let height = 120
    let atlas = FontAtlas(pointSize: 28, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: width, pixelHeight: height, scale: scale))

    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
        color: 0x00_00_00_FF, source: .terminal, compositing: .replace),
      .glyphRun(
        origin: CGPoint(x: 8, y: 30),
        text: "HHHHH",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]

    // Sweep a sub-cell horizontal phase across a full device pixel. The slide
    // offset is symmetric with the vertical axis (+phase adds +offset*scale), but
    // image X increases to the right while image Y increases downward. A positive
    // horizontal phase therefore moves the centroid toward larger coordinates.
    let phaseDevicePixels: [CGFloat] = [-0.5, -0.25, 0.0, 0.25, 0.5]
    var centroids: [Double] = []
    for devpx in phaseDevicePixels {
      renderer.setScrollPhaseOffset(CGPoint(x: devpx / scale, y: 0))
      var png: Data?
      for _ in 0..<6 {
        XCTAssertTrue(renderer.render(commands, damage: .full))
        png = renderer.pngData
      }
      XCTAssertEqual(renderer.lastRasterFallbackGlyphs, 0, "vector backend fell back to raster")
      centroids.append(try inkCentroidX(png: XCTUnwrap(png)))
    }

    let totalShift = abs(centroids.last! - centroids.first!)
    XCTAssertGreaterThan(totalShift, 0.5, "phase sweep produced too little motion: \(centroids)")
    XCTAssertLessThan(totalShift, 2.0, "phase sweep jumped more than a pixel — snapped, not smooth")
    // Monotonic in the expected direction (+phase -> increasing X). The vertical
    // assertion decreases because its point-space axis is inverted in the image.
    for i in 1..<centroids.count {
      XCTAssertGreaterThanOrEqual(
        centroids[i] - centroids[i - 1], -0.06,
        "centroid moved the wrong way (non-monotonic): \(centroids)")
    }
    XCTAssertNotEqual(centroids.first!, centroids.last!)
  }

  // MARK: - Helpers

  /// Horizontal centroid (in device pixels, left-to-right) of ink — luminance
  /// above the black background — in the presented frame.
  private func inkCentroidX(png: Data) throws -> Double {
    let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
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

    var weightedSum = 0.0
    var total = 0.0
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 4
        let luma = Double(px[i + 0]) * 0.299 + Double(px[i + 1]) * 0.587 + Double(px[i + 2]) * 0.114
        if luma > 8 {
          weightedSum += Double(x) * luma
          total += luma
        }
      }
    }
    XCTAssertGreaterThan(total, 0, "no ink found in rendered frame")
    return weightedSum / total
  }

  /// Vertical centroid (in device pixels, top-down) of ink — luminance above the
  /// black background — in the presented frame.
  private func inkCentroidY(png: Data) throws -> Double {
    let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
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

    var weightedSum = 0.0
    var total = 0.0
    for y in 0..<h {
      for x in 0..<w {
        let i = (y * w + x) * 4
        let luma = Double(px[i + 0]) * 0.299 + Double(px[i + 1]) * 0.587 + Double(px[i + 2]) * 0.114
        if luma > 8 {
          weightedSum += Double(y) * luma
          total += luma
        }
      }
    }
    XCTAssertGreaterThan(total, 0, "no ink found in rendered frame")
    return weightedSum / total
  }
}
