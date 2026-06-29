import CoreGraphics
import Foundation
import XCTest

@testable import LabanRenderer

final class VectorGlyphMaskAtlasTests: XCTestCase {
  func testTransposedMortonOrderStartsByWalkingTallGlyphFriendlySlots() {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)

    let prefix = atlas.transposedMortonSlotOrderPrefix(8)

    XCTAssertEqual(
      prefix.map { [$0.x, $0.y] },
      [
        [0, 0],
        [0, 1],
        [1, 0],
        [1, 1],
        [0, 2],
        [0, 3],
        [1, 2],
        [1, 3],
      ])
  }

  func testStoresAndReadsGlyphBytesFromResidentAtlas() throws {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)
    let key = VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(NSObject()),
      glyph: 42,
      width: 3,
      height: 2,
      originX: -1,
      originY: -2)
    let bytes: [UInt8] = [0, 64, 128, 192, 224, 255]

    let entry = try XCTUnwrap(
      atlas.store(
        key: key,
        width: 3,
        height: 2,
        origin: CGPoint(x: -1, y: -2),
        bytes: bytes))

    XCTAssertEqual(entry.x, 0)
    XCTAssertEqual(entry.y, 0)
    XCTAssertEqual(entry.width, 3)
    XCTAssertEqual(entry.height, 2)
    XCTAssertEqual(atlas.bytes(for: entry), bytes)
    XCTAssertEqual(atlas.entryCount, 1)
    XCTAssertEqual(atlas.store(key: key, width: 3, height: 2, origin: .zero, bytes: bytes), entry)
    XCTAssertEqual(atlas.entryCount, 1)
  }

  func testTallGlyphsPackIntoTransposedNeighborSlots() throws {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)
    let firstKey = VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(NSObject()),
      glyph: 1,
      width: 8,
      height: 24,
      originX: 0,
      originY: 0)
    let secondKey = VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(NSObject()),
      glyph: 2,
      width: 8,
      height: 24,
      originX: 0,
      originY: 0)
    let bytes = [UInt8](repeating: 255, count: 8 * 24)

    let first = try XCTUnwrap(
      atlas.store(key: firstKey, width: 8, height: 24, origin: .zero, bytes: bytes))
    let second = try XCTUnwrap(
      atlas.store(key: secondKey, width: 8, height: 24, origin: .zero, bytes: bytes))

    XCTAssertEqual(first.x, 0)
    XCTAssertEqual(first.y, 0)
    XCTAssertEqual(second.x, 16)
    XCTAssertEqual(second.y, 0)
  }

  /// A multi-slot-wide mask must be placeable at an unaligned but contiguous run
  /// of free slots. Here slots 1 and 2 are free (0 and 3 are pinned this frame),
  /// and a 32x16 (2-slot-wide) mask must land at pixel x=16 — not be rejected for
  /// failing to align its origin to its own width.
  func testWideMaskCanUseUnalignedContiguousFreeSlots() throws {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 16)  // 4 slots wide, 1 tall
    let font = ObjectIdentifier(NSObject())
    func slotKey(_ glyph: CGGlyph) -> VectorGlyphMaskAtlas.Key {
      VectorGlyphMaskAtlas.Key(font: font, glyph: glyph, width: 16, height: 16, originX: 0, originY: 0)
    }

    atlas.beginFrame()
    var entries: [VectorGlyphMaskAtlas.Entry] = []
    for i in 0..<4 {
      entries.append(
        try XCTUnwrap(atlas.reserve(key: slotKey(CGGlyph(i)), width: 16, height: 16, origin: .zero)))
    }

    // Free the middle two slots, then pin the outer two in the current frame so
    // eviction cannot reclaim them — the wide reserve must succeed purely by
    // finding the contiguous free run at slots 1..2.
    atlas.remove(entries[1])
    atlas.remove(entries[2])
    atlas.touch(entries[0])
    atlas.touch(entries[3])

    let wideKey = VectorGlyphMaskAtlas.Key(
      font: font, glyph: 42, width: 32, height: 16, originX: 0, originY: 0)
    let wide = try XCTUnwrap(
      atlas.reserve(key: wideKey, width: 32, height: 16, origin: .zero),
      "wide mask rejected despite a contiguous free run at unaligned slot x=1")
    XCTAssertEqual(wide.x, 16)
    XCTAssertEqual(wide.y, 0)
  }

  func testSyntheticItalicFlagKeepsVectorMasksDisjoint() throws {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)
    let font = ObjectIdentifier(NSObject())
    let regular = VectorGlyphMaskAtlas.Key(
      font: font,
      glyph: 42,
      width: 8,
      height: 8,
      originX: 0,
      originY: 0)
    let syntheticItalic = VectorGlyphMaskAtlas.Key(
      font: font,
      glyph: 42,
      width: 8,
      height: 8,
      originX: 0,
      originY: 0,
      syntheticItalic: true)
    let bytes = [UInt8](repeating: 255, count: 8 * 8)

    let regularEntry = try XCTUnwrap(
      atlas.store(key: regular, width: 8, height: 8, origin: .zero, bytes: bytes))
    let italicEntry = try XCTUnwrap(
      atlas.store(key: syntheticItalic, width: 8, height: 8, origin: .zero, bytes: bytes))

    XCTAssertNotEqual(regularEntry, italicEntry)
    XCTAssertEqual(atlas.entryCount, 2)
  }
}
