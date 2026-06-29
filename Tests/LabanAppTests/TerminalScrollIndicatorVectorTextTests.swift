import AppKit
import LabanCore
import LabanRenderer
import Metal
import XCTest

@testable import LabanApp

/// The scrollback pill renders its text through the vector glyph renderer only
/// when that renderer supplies a rasterizer, and reverts to its CoreText path
/// otherwise. This keeps the overlay's glyphs matching the terminal grid under
/// the vector renderer without coupling the classic/software renderers to it.
final class TerminalScrollIndicatorVectorTextTests: XCTestCase {

  /// Scroll fully back into history so the pill is visible with text.
  private func scrollBack(_ view: TerminalScrollIndicatorView) {
    view.applyViewport(
      viewportOffset: 0, totalRows: 400, viewportRows: 40,
      isAltScreen: false, isMouseTracking: false)
  }

  private func makeRasterizer() throws -> VectorTextRasterizer {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    return try XCTUnwrap(VectorTextRasterizer(device: device))
  }

  func testPillUsesVectorImageWhenRasterizerIsSet() throws {
    let rasterizer = try makeRasterizer()
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()
    view.setVectorTextRasterizer(rasterizer)

    scrollBack(view)
    view.layoutSubtreeIfNeeded()

    XCTAssertTrue(view.debugVisibility().pillVisible, "scrolled back, the pill shows its position")
    XCTAssertEqual(
      view.pillTextSourceForTesting(), .vectorImage,
      "with a vector rasterizer set, the pill text comes from the vector pipeline")
  }

  func testPillRevertsToCoreTextWhenRasterizerCleared() throws {
    let rasterizer = try makeRasterizer()
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()
    view.setVectorTextRasterizer(rasterizer)
    scrollBack(view)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.pillTextSourceForTesting(), .vectorImage)

    // Switching away from the vector renderer (rasterizer nil) must restore the
    // CoreText/CATextLayer path live, without needing a new scroll sample.
    view.setVectorTextRasterizer(nil)
    XCTAssertEqual(
      view.pillTextSourceForTesting(), .coreTextLayer,
      "clearing the rasterizer reverts the pill to its CoreText text path")
  }

  func testPillUsesCoreTextByDefault() {
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()
    scrollBack(view)
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(
      view.pillTextSourceForTesting(), .coreTextLayer,
      "without a vector rasterizer the pill renders text via CoreText, as before")
  }
}
