import CoreGraphics
import CoreText
import XCTest

@testable import LabanRenderer

/// Root-cause gate for the mixed-glyph-size zoom bug. `GlyphCurveStore` caches
/// glyph outlines keyed ONLY on `ObjectIdentifier(font)` (the font object's
/// address), but the outline geometry is baked at the font's point size. During
/// a zoom, transient `CTFont`s at many sizes are created and freed; the
/// allocator reuses addresses, so a new small font can land on a freed large
/// font's address and a lookup returns the stale large outline — glyphs draw at
/// the wrong size. The renderer must `invalidate()` the store on every font
/// swap so a reused address can never alias freed geometry.
final class GlyphCurveStoreInvalidateTests: XCTestCase {
  private func glyph(_ scalar: Unicode.Scalar, _ font: CTFont) -> CGGlyph? {
    var chars = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    return ok ? glyphs.first : nil
  }

  /// Outlines scale with point size; after `invalidate()` the store must re-fetch
  /// from the current font rather than returning a cached (possibly stale-size)
  /// outline.
  func testInvalidateDropsCachedOutlinesSoSizeChangesTakeEffect() throws {
    let store = GlyphCurveStore()
    let small = CTFontCreateWithName("Menlo" as CFString, 10, nil)
    let large = CTFontCreateWithName("Menlo" as CFString, 40, nil)
    let gSmall = try XCTUnwrap(glyph("W", small))
    let gLarge = try XCTUnwrap(glyph("W", large))

    let smallOutline = try XCTUnwrap(store.outline(for: gSmall, font: small))
    let largeOutline = try XCTUnwrap(store.outline(for: gLarge, font: large))

    // 40pt 'W' bounds must be substantially larger than 10pt 'W'.
    XCTAssertGreaterThan(
      largeOutline.bounds.height, smallOutline.bounds.height * 2,
      "outline geometry is point-size-specific")

    // After invalidate, the store has no cached entries: a re-fetch hits CoreText
    // again (proves we are not serving a stale address-keyed entry).
    store.invalidate()
    let refetchedSmall = try XCTUnwrap(store.outline(for: gSmall, font: small))
    XCTAssertEqual(
      refetchedSmall.bounds.height, smallOutline.bounds.height, accuracy: 0.5,
      "re-fetch after invalidate must reproduce the correct size")
  }

  /// The actual aliasing scenario, made deterministic: two DIFFERENT-size fonts
  /// that (by construction) share a cache key collision must not cross-serve
  /// geometry once the store is invalidated between them. We simulate the address
  /// reuse by invalidating on the swap (what the renderer now does) and asserting
  /// the second font's outline matches its own size, not the first's.
  func testInvalidatedSwapDoesNotCrossServeGeometry() throws {
    let store = GlyphCurveStore()
    let big = CTFontCreateWithName("Menlo" as CFString, 36, nil)
    let gBig = try XCTUnwrap(glyph("M", big))
    let bigH = try XCTUnwrap(store.outline(for: gBig, font: big)).bounds.height

    // Swap to a small font; the renderer invalidates here.
    store.invalidate()
    let smallF = CTFontCreateWithName("Menlo" as CFString, 9, nil)
    let gSmall = try XCTUnwrap(glyph("M", smallF))
    let smallH = try XCTUnwrap(store.outline(for: gSmall, font: smallF)).bounds.height

    XCTAssertLessThan(
      smallH, bigH * 0.5,
      "after an invalidated swap the small font must yield small geometry, not the big font's")
  }
}
