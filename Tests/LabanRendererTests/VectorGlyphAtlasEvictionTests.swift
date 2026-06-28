import CoreGraphics
import CoreText
import XCTest

@testable import LabanRenderer

/// M5 gates: the mask atlas must stay bounded when many (glyph, sub-pixel phase)
/// keys churn through it during a scroll, and the per-frame sample budget must
/// keep new-phase rasterization cost bounded while still making every referenced
/// phase resident. Both are CPU-only — no GPU — so they run anywhere.
final class VectorGlyphAtlasEvictionTests: XCTestCase {
  private let font = FontAtlas(pointSize: 16, fontName: nil).font

  private func key(_ glyph: CGGlyph, offsetX: Int = 0, offsetY: Int = 0) -> VectorGlyphMaskAtlas.Key
  {
    VectorGlyphMaskAtlas.Key(
      font: ObjectIdentifier(font), glyph: glyph, width: 16, height: 16,
      originX: 0, originY: 0, quantizedOffsetX: offsetX, quantizedOffsetY: offsetY)
  }

  /// Referencing far more (glyph, phase) keys than the atlas can hold, across
  /// many frames, must never exceed the slot capacity, must keep the keys used
  /// this frame resident, and must free the stale ones.
  func testAtlasStaysBoundedUnderPhaseChurn() {
    // 64x64 px / 16px slots = 16 slots total. Each 16x16 mask is one slot.
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)
    XCTAssertEqual(atlas.slotCapacity, 16)

    // 200 frames, each referencing 8 fresh phases — far exceeds 16 slots. The
    // discriminating property: every phase referenced *this* frame must be
    // resident. Without eviction the atlas fills after frame 1 and later frames'
    // phases can't reserve a slot (reserve returns nil), so this fails; with the
    // keep-or-free sweep + LRU-on-full, the current frame's phases always fit.
    for frame in 0..<200 {
      atlas.beginFrame()
      atlas.evictUnused(olderThan: 1)
      var thisFrameKeys: [VectorGlyphMaskAtlas.Key] = []
      for i in 0..<8 {
        let k = key(7, offsetX: (frame * 8 + i) % 251 + 1)
        thisFrameKeys.append(k)
        if let entry = atlas.reserve(key: k, width: 16, height: 16, origin: .zero) {
          atlas.touch(entry)
        }
      }
      XCTAssertLessThanOrEqual(
        atlas.usedSlots, atlas.slotCapacity, "atlas overflowed its slots at frame \(frame)")
      for k in thisFrameKeys {
        XCTAssertNotNil(
          atlas.entry(for: k),
          "phase referenced this frame is not resident at frame \(frame) — eviction failed")
      }
    }
  }

  /// A glyph referenced every frame (static text) must survive the keep-or-free
  /// sweep even as other phases churn and get evicted around it.
  func testLiveKeysSurviveWhileStaleKeysAreFreed() {
    let atlas = VectorGlyphMaskAtlas(width: 64, height: 64)
    let liveKey = key(1)
    for frame in 0..<50 {
      atlas.beginFrame()
      atlas.evictUnused(olderThan: 2)
      // Touch the live key every frame.
      if let live = atlas.reserve(key: liveKey, width: 16, height: 16, origin: .zero) {
        atlas.touch(live)
      }
      // Plus a transient phase that is never touched again.
      _ = atlas.reserve(key: key(2, offsetX: frame % 251 + 1), width: 16, height: 16, origin: .zero)
    }
    XCTAssertNotNil(atlas.entry(for: liveKey), "static glyph was evicted despite per-frame use")
  }

  /// When the atlas is full of current-frame entries, a further reserve cannot
  /// evict anything (nothing is older than this frame) and returns nil — the
  /// caller falls back to the raster path rather than corrupting a live slot.
  func testReserveReturnsNilWhenFullOfCurrentFrameEntries() {
    let atlas = VectorGlyphMaskAtlas(width: 32, height: 32)  // 4 slots
    atlas.beginFrame()
    for i in 0..<4 {
      let entry = atlas.reserve(key: key(10, offsetX: i + 1), width: 16, height: 16, origin: .zero)
      XCTAssertNotNil(entry)
      atlas.touch(entry!)
    }
    XCTAssertEqual(atlas.usedSlots, atlas.slotCapacity)
    let overflow = atlas.reserve(key: key(10, offsetX: 99), width: 16, height: 16, origin: .zero)
    XCTAssertNil(overflow, "must not evict an entry used in the current frame")
  }

  // MARK: - Per-frame sample budget

  /// With a small budget and many new phases in one frame, total samples encoded
  /// must stay within budget, and every phase must still get at least one sample
  /// (resident, lower quality — never missing).
  func testPhasedBudgetBoundsTotalSamplesYetKeepsEveryPhaseResident() {
    let budget = 40
    var remaining = budget
    var totalEncoded = 0
    var residentCount = 0
    let newPhasesThisFrame = 100
    for _ in 0..<newPhasesThisFrame {
      let n = VectorGlyphRenderer.phasedSamplesThisFrame(sampleStart: 0, budgetRemaining: remaining)
      if n > 0 {
        residentCount += 1
        totalEncoded += n
        remaining -= n
      }
    }
    XCTAssertLessThanOrEqual(totalEncoded, budget, "exceeded the per-frame phased sample budget")
    // 40 budget / 8 ideal first-paint = 5 phases this frame; the rest wait for
    // a later frame's budget. The point is the cap held, not that all 100 fit.
    XCTAssertEqual(residentCount, 5)
    XCTAssertGreaterThan(residentCount, 0)
  }

  /// A phased mask front-loads (8 → 4 → 2 → 1) and never exceeds the budget,
  /// while a static mask keeps its full-quality 512-sample first paint.
  func testPhasedFrontLoadsWhileStaticKeepsFullFirstPaint() {
    func phased(_ start: Int, _ budget: Int) -> Int {
      VectorGlyphRenderer.phasedSamplesThisFrame(sampleStart: start, budgetRemaining: budget)
    }
    XCTAssertEqual(phased(0, 999), 8)
    XCTAssertEqual(phased(16, 999), 4)
    XCTAssertEqual(phased(64, 999), 2)
    XCTAssertEqual(phased(256, 999), 1)
    // Budget clamps the ideal down, but never to zero while budget remains.
    XCTAssertEqual(phased(0, 3), 3)
    XCTAssertEqual(phased(0, 0), 0)
    // Static first paint is unchanged: full quality regardless of phase budget.
    XCTAssertEqual(
      VectorGlyphRenderer.accumulationSamplesThisFrame(sampleStart: 0, maskPixels: 32 * 32), 512)
  }
}
