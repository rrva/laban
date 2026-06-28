import Metal
import XCTest

@testable import LabanRenderer

/// M2 gate: the subpixel auto-policy must keep text fringe-free across displays.
/// Subpixel AA is only used when the framebuffer maps 1:1 to physical subpixels
/// (integer device scale, not resampled); otherwise it falls back to grayscale,
/// which is the safe default on every MacBook panel.
final class VectorSubpixelPolicyTests: XCTestCase {
  func testGrayscaleConfiguredStaysGrayscale() {
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .grayscale, scale: 2, downsampled: false),
      .grayscale)
  }

  func testIntegerScaleNotResampledKeepsConfiguredLayout() {
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .rgbStripe, scale: 2, downsampled: false),
      .rgbStripe)
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .rgbStripe, scale: 1, downsampled: false),
      .rgbStripe)
  }

  func testDownsampledFallsBackToGrayscale() {
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .rgbStripe, scale: 2, downsampled: true),
      .grayscale)
  }

  func testNonIntegerScaleFallsBackToGrayscale() {
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .rgbStripe, scale: 1.5, downsampled: false),
      .grayscale)
    XCTAssertEqual(
      VectorSubpixelLayout.effective(configured: .calibratedRGB, scale: 2.25, downsampled: false),
      .grayscale)
  }

  func testRendererReportsEffectiveLayout() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 64, pixelHeight: 64, scale: 2))

    renderer.setSubpixelLayout(.rgbStripe)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)
    XCTAssertEqual(renderer.rendererStatus.vectorSubpixelLayout, "rgbStripe")

    // A resampled (scaled) display must auto-disable subpixel AA.
    renderer.setDisplayDownsampled(true)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .grayscale)
    XCTAssertEqual(renderer.rendererStatus.vectorSubpixelLayout, "grayscale")

    renderer.setDisplayDownsampled(false)
    XCTAssertEqual(renderer.effectiveSubpixelLayout, .rgbStripe)
  }
}
