import LabanRenderer
import XCTest

/// Guards the POD shrink of `TerminalCellPayload.Glyph`
/// (`execplans/active/payload-glyph-pod-shrink.md`): the per-cell payload
/// element must stay pointer-free (no ARC on copy/destroy) and cache-line
/// sized, or full-grid payload frames regress.
final class PayloadGlyphLayoutTests: XCTestCase {
  func testGlyphIsPODAndCompact() {
    XCTAssertTrue(_isPOD(TerminalCellPayload.Glyph.self))
    XCTAssertLessThanOrEqual(MemoryLayout<TerminalCellPayload.Glyph>.stride, 56)
  }
}
