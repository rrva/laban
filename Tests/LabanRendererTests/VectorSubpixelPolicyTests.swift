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

  func testSetDisplayDownsampledReportsEffectiveChange() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 64, pixelHeight: 64, scale: 2))

    renderer.setSubpixelLayout(.rgbStripe)
    // rgbStripe -> grayscale on downsample is an effective change (caller repaints).
    XCTAssertTrue(renderer.setDisplayDownsampled(true))
    // Same value again: no effective change.
    XCTAssertFalse(renderer.setDisplayDownsampled(true))
    XCTAssertTrue(renderer.setDisplayDownsampled(false))

    // With grayscale configured, downsample toggles never change the effective
    // layout (already grayscale), so the caller is told nothing changed.
    renderer.setSubpixelLayout(.grayscale)
    XCTAssertFalse(renderer.setDisplayDownsampled(true))
  }

  // MARK: - displayIsDownsampled core (the AppKit detector's decision)

  func testNativeFramebufferIsNotDownsampled() {
    // Current mode pixel size == native panel pixel size: 1:1, no resample.
    XCTAssertFalse(
      VectorSubpixelLayout.displayIsDownsampled(
        currentPixelWidth: 3024, currentPixelHeight: 1964,
        nativePixelWidth: 3024, nativePixelHeight: 1964))
  }

  func testScaledFramebufferIsDownsampled() {
    // "More Space": framebuffer rendered above native, then downscaled.
    XCTAssertTrue(
      VectorSubpixelLayout.displayIsDownsampled(
        currentPixelWidth: 3600, currentPixelHeight: 2338,
        nativePixelWidth: 3024, nativePixelHeight: 1964))
    // A "Larger Text" scaled mode renders below native and upscales.
    XCTAssertTrue(
      VectorSubpixelLayout.displayIsDownsampled(
        currentPixelWidth: 2560, currentPixelHeight: 1664,
        nativePixelWidth: 3024, nativePixelHeight: 1964))
  }

  func testUnknownModeSizeIsTreatedAsNotDownsampled() {
    // A detection gap (0 size) must not disable an opted-in subpixel layout.
    XCTAssertFalse(
      VectorSubpixelLayout.displayIsDownsampled(
        currentPixelWidth: 0, currentPixelHeight: 0,
        nativePixelWidth: 3024, nativePixelHeight: 1964))
    XCTAssertFalse(
      VectorSubpixelLayout.displayIsDownsampled(
        currentPixelWidth: 3024, currentPixelHeight: 1964,
        nativePixelWidth: 0, nativePixelHeight: 0))
  }
}
