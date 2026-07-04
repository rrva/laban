import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// Regression for the Metal backends' PNG/screenshot readback tagging.
///
/// Slug, Vector, and the classic MetalRenderer all composite into sRGB-encoded
/// textures (Slug/Vector via `bgra8Unorm_srgb` layers + linear-light blend;
/// classic via `bgra8Unorm` + encoded-sRGB-space blend, no linearization). The
/// readback `CGImage` must therefore be tagged sRGB so PNG consumers
/// (screenshots, capture/replay, parity tests) interpret the bytes correctly.
/// A deviceRGB tag mis-tags the sRGB bytes as display-native and oversaturates
/// them on wide-gamut (P3) panels — the same class of bug fixed on the software
/// renderer's `BitmapSurface`.
final class RendererReadbackColorSpaceTests: XCTestCase {

  private func skipIfNoMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
  }

  private func decodePNG(_ png: Data, _ label: String) throws -> CGImage {
    let src = try XCTUnwrap(
      CGImageSourceCreateWithData(png as CFData, nil), "\(label): CGImageSourceCreate failed")
    return try XCTUnwrap(
      CGImageSourceCreateImageAtIndex(src, 0, nil), "\(label): image decode failed")
  }

  private func assertSRGBTagged(_ png: Data, _ label: String) throws {
    let image = try decodePNG(png, label)
    let name = image.colorSpace?.name as String?
    XCTAssertEqual(
      name, CGColorSpace.sRGB as String,
      "\(label): readback PNG must be tagged sRGB, got \(name ?? "nil")")
  }

  private func solidCommands() -> [FrameCommand] {
    [
      .rect(CGRect(x: 0, y: 0, width: 40, height: 20), color: 0xF6EE_DBFF, source: .terminal),
      .rect(CGRect(x: 40, y: 0, width: 20, height: 20), color: 0x30A7_BEFF, source: .terminal),
    ]
  }

  func testSlugReadbackPNGIsTaggedSRGB() throws {
    try skipIfNoMetal()
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16), pixelWidth: 64, pixelHeight: 32, scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(.grayscale)
    XCTAssertTrue(renderer.render(solidCommands(), damage: .full))
    try assertSRGBTagged(try XCTUnwrap(renderer.pngData), "slug")
  }

  func testVectorReadbackPNGIsTaggedSRGB() throws {
    try skipIfNoMetal()
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 16), pixelWidth: 64, pixelHeight: 32, scale: 2))
    renderer.waitForFrameCompletion = true
    renderer.setSubpixelLayout(.grayscale)
    XCTAssertTrue(renderer.render(solidCommands(), damage: .full))
    try assertSRGBTagged(try XCTUnwrap(renderer.pngData), "vector")
  }

  func testClassicMetalReadbackPNGIsTaggedSRGB() throws {
    try skipIfNoMetal()
    let renderer = try XCTUnwrap(
      MetalRenderer(
        fontAtlas: FontAtlas(), sidebarFontAtlas: FontAtlas(), scale: 2, rendererMode: .classic))
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: 64, pixelHeight: 32, scale: 2)
    XCTAssertTrue(renderer.render(solidCommands(), damage: .full))
    renderer.waitForLastFrame()
    try assertSRGBTagged(try XCTUnwrap(renderer.pngData), "metal-classic")
  }
}
