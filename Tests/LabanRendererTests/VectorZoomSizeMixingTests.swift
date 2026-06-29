import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

/// M0 gate for `execplans/active/vector-zoom-smoothness.md`.
///
/// The pinch-zoom "two glyph sizes in one frame" defect is a GPU race: a
/// self-presenting vector frame baked at the old size is still in flight when
/// the next `applyFontSize` resets the mask atlas and bakes at a new size into
/// the same shared target. `TerminalBitmapView.applyFontSize` is supposed to
/// prevent this by rendering one synchronous frame with `waitForFrameCompletion`
/// turned on — but it used to gate that on `backend as? MetalRenderer`, which is
/// nil for the vector backend, so the guarantee silently no-op'd there.
///
/// The fix makes `waitForFrameCompletion` a real, backend-agnostic property the
/// vector renderer stores and honors. These tests pin both halves:
///  - the flag round-trips on the vector renderer (before the fix it resolved to
///    the protocol's no-op default and always read back `false`), and
///  - setting it makes `render()` block until the frame has actually completed.
///
/// A raw pixel comparison would be flaky (it depends on winning/losing the race),
/// so the gate asserts the deterministic mechanism instead.
final class VectorZoomSizeMixingTests: XCTestCase {
  private func makeRenderer() throws -> VectorGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let atlas = FontAtlas(pointSize: 14, fontName: nil)
    return try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 480,
        pixelHeight: 256,
        scale: 2))
  }

  /// Deterministic fail-before/pass-after: before the fix the vector renderer
  /// inherited the protocol extension's no-op `waitForFrameCompletion`
  /// (get returns false, set discards), so the apply path could not engage the
  /// synchronous-frame guarantee on it. After the fix it stores the flag.
  func testVectorRendererParticipatesInFrameCompletionGuarantee() throws {
    let renderer = try makeRenderer()
    XCTAssertFalse(renderer.waitForFrameCompletion, "flag should default off")
    renderer.waitForFrameCompletion = true
    XCTAssertTrue(
      renderer.waitForFrameCompletion,
      "the vector backend must store waitForFrameCompletion, not fall through to the no-op default; "
        + "otherwise applyFontSize's no-mixed-frame guarantee skips the self-presenting backend")
  }

  /// Behavioral: with the flag set, `render()` does not return until the frame
  /// has completed on the GPU. We observe completion via `onFrameCompleted`,
  /// which Metal invokes before `waitUntilCompleted()` returns.
  func testWaitForFrameCompletionBlocksUntilFrameDone() throws {
    let renderer = try makeRenderer()
    var completedBeforeReturn = false
    renderer.onFrameCompleted = { completedBeforeReturn = true }
    renderer.waitForFrameCompletion = true

    let didRender = renderer.render(Self.fullScreenText(), damage: .full)
    XCTAssertTrue(didRender, "a full-damage frame must render")
    XCTAssertTrue(
      completedBeforeReturn,
      "render() must block until the frame completes when waitForFrameCompletion is set, "
        + "so the next atlas reset cannot race in-flight GPU work")
  }

  /// M1 gate: a continuous zoom must NOT rebuild the raster/color fallback
  /// atlases per gesture frame — that per-event texture reallocation is the
  /// jank this milestone removes. `applyLiveZoomFonts` (the live path) preserves
  /// them; only the once-on-end `reconcileFallbackAtlasesForSettledSize` and the
  /// full `reconfigureFonts` (font-family change) rebuild.
  func testLiveZoomSweepDoesNotRebuildFallbackAtlasesPerFrame() throws {
    let renderer = try makeRenderer()
    let baseCount = renderer.fallbackAtlasRebuildCount

    // Sweep 14 -> 28 pt in many small fractional steps, the live-zoom path.
    var size: CGFloat = 14
    var steps = 0
    while size < 28 {
      size += 0.37
      let atlas = FontAtlas(pointSize: size, fontName: nil)
      renderer.applyLiveZoomFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
      _ = renderer.render(Self.fullScreenText(), damage: .full)
      steps += 1
    }
    XCTAssertGreaterThan(steps, 20, "the sweep must take many small steps to be meaningful")
    XCTAssertEqual(
      renderer.fallbackAtlasRebuildCount, baseCount,
      "live-zoom frames must not rebuild the raster/color fallback atlases; "
        + "rebuilding per gesture frame is the per-event jank M1 removes")

    // The gesture-end reconcile rebuilds exactly once, to settle emoji/raster
    // fallback at the final size.
    renderer.reconcileFallbackAtlasesForSettledSize()
    XCTAssertEqual(
      renderer.fallbackAtlasRebuildCount, baseCount + 1,
      "gesture end must reconcile the fallback atlases exactly once")
  }

  /// M2 scroll-leak guard: the live-zoom size path must never run while a scroll
  /// phase is active, or it would defeat the bake-once-reuse model the scroll
  /// budget depends on. The renderer tracks any such violation in
  /// `liveZoomWhileScrollPhaseActiveCount`. This proves both directions: a normal
  /// live-zoom sweep (no scroll phase) leaves it at zero, and forcing a scroll
  /// phase active before a size apply makes the tripwire fire — so a future edit
  /// that lets zoom leak into the scroll steady-state is caught here.
  func testLiveZoomNeverRunsDuringScrollPhase() throws {
    let renderer = try makeRenderer()

    // Normal live-zoom: no scroll phase -> tripwire stays zero.
    var size: CGFloat = 14
    for _ in 0..<10 {
      size += 0.5
      let atlas = FontAtlas(pointSize: size, fontName: nil)
      renderer.applyLiveZoomFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
      _ = renderer.render(Self.fullScreenText(), damage: .full)
    }
    XCTAssertEqual(
      renderer.liveZoomWhileScrollPhaseActiveCount, 0,
      "live-zoom must never coincide with an active scroll phase in the real path")

    // Prove the tripwire bites: force a scroll phase active, then apply a size.
    // (This is the mis-wiring the guard exists to catch.)
    renderer.setScrollPhaseOffset(CGPoint(x: 0, y: 0.25))
    let atlas = FontAtlas(pointSize: 22, fontName: nil)
    renderer.applyLiveZoomFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
    XCTAssertEqual(
      renderer.liveZoomWhileScrollPhaseActiveCount, 1,
      "the tripwire must fire if the live-zoom path runs while a scroll phase is active")
  }

  /// Guards the contrast: the full font-family path still rebuilds (a family
  /// change genuinely needs new fallback-atlas geometry).
  func testReconfigureFontsRebuildsFallbackAtlases() throws {
    let renderer = try makeRenderer()
    let baseCount = renderer.fallbackAtlasRebuildCount
    let atlas = FontAtlas(pointSize: 20, fontName: nil)
    renderer.reconfigureFonts(fontAtlas: atlas, sidebarFontAtlas: atlas)
    XCTAssertEqual(renderer.fallbackAtlasRebuildCount, baseCount + 1)
  }

  // A full screen of varied ASCII so the frame does real bake + blit work.
  private static func fullScreenText() -> [FrameCommand] {
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let cols = 50
    let rows = 12
    var cmds: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_10_10_FF, source: .terminal)
    ]
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let doubled = ascii + ascii
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      let line = String(doubled[from...].prefix(cols))
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xEE_EE_EE_FF,
          background: 0x10_10_10_FF,
          attributes: [],
          source: .terminal))
    }
    return cmds
  }
}
