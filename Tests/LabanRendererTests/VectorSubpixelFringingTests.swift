import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

/// M3 gate: subpixel layouts must stay low-fringing. OSOR's whole point is that
/// overlapping, pixel-bleeding subpixel sample areas reduce the colored edges
/// ("fringing") that non-overlapping thirds produce. We measure edge *chroma*
/// (max channel - min channel along glyph edges): grayscale must be ~0, and the
/// overlapping `calibratedRGB` default must fringe less than non-overlapping
/// `rgbStripe`.
final class VectorSubpixelFringingTests: XCTestCase {
  func testOverlapReducesFringingVersusStripe() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }

    let gray = try meanEdgeChroma(layout: .grayscale)
    let overlap = try meanEdgeChroma(layout: .calibratedRGB)
    let stripe = try meanEdgeChroma(layout: .rgbStripe)

    // Grayscale never fringes.
    XCTAssertLessThan(gray, 2.0, "grayscale should have ~no edge chroma")
    // Subpixel layouts inherently color edges, but overlap must reduce it.
    XCTAssertLessThan(overlap, stripe, "overlap (calibratedRGB) must fringe less than stripe")
    XCTAssertLessThan(
      overlap, stripe * 0.85,
      "overlap should be meaningfully less fringy than stripe "
        + "(overlap \(overlap), stripe \(stripe))")
  }

  private func meanEdgeChroma(layout: VectorSubpixelLayout) throws -> Double {
    let scale: CGFloat = 2
    let atlas = FontAtlas(pointSize: 28, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 600, pixelHeight: 160, scale: scale))
    renderer.setSubpixelLayout(layout)
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 300, height: 80), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 10, y: 10), text: "HHlll||MMNN",
        foreground: 0xFF_FF_FF_FF, background: 0x00_00_00_FF,
        attributes: [], source: .terminal),
    ]
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))

    var chromaTotal = 0.0
    var count = 0
    for i in stride(from: 0, to: image.bytes.count, by: 4) {
      let r = Int(image.bytes[i])
      let g = Int(image.bytes[i + 1])
      let b = Int(image.bytes[i + 2])
      let maxC = max(r, max(g, b))
      let minC = min(r, min(g, b))
      // Edge pixels: partially covered (not pure black bg, not pure white).
      guard maxC > 8, minC < 247 else { continue }
      chromaTotal += Double(maxC - minC)
      count += 1
    }
    return count == 0 ? 0 : chromaTotal / Double(count)
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw XCTSkip("decode failed") }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let ctx = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)
      else { return }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }
}
