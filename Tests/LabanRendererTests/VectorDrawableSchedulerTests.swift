import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// M7 gate: the vector backend acquires drawables through the shared
/// `MetalDrawableScheduler` (async, non-blocking) instead of a blocking
/// `layer.nextDrawable()`. The blocking call stalled the main thread (~p99
/// 10 ms / max 51 ms in a scroll trace) whenever a present fell behind, which
/// was the measured source of vector scroll jank.
///
/// The scheduler serializes frames to one in flight: the in-flight slot is
/// released by the GPU completion handler, so a *paced* caller (display link, or
/// a test that drains each frame) always finds capacity, while a no-wait burst
/// legitimately drops the surplus — that IS drop-don't-block. These tests pace
/// by draining each frame through `pngData` (which waits on the command buffer),
/// mirroring how the live display link spaces ticks ~8 ms apart.
///
/// The actual main-thread stall the old blocking acquire caused only reproduces
/// under real 120 Hz display pressure (measured on-device by
/// `scripts/profile-scroll-renderers`); what is mechanically checkable headless
/// is the contract that makes the fix possible.
final class VectorDrawableSchedulerTests: XCTestCase {
  private func makeRenderer() throws -> VectorGlyphRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    return try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 200, pixelHeight: 80, scale: 2))
  }

  private func commands() -> [FrameCommand] {
    [
      .rect(
        CGRect(x: 0, y: 0, width: 100, height: 40),
        color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 4, y: 12),
        text: "scheduler",
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]
  }

  /// Render one frame, then drain it (force GPU completion so the in-flight slot
  /// is released before the next call) — the pacing a live display link provides.
  @discardableResult
  private func renderDrained(
    _ renderer: VectorGlyphRenderer,
    drop: Bool = false,
    phasePoints: CGFloat = 0
  ) -> Bool {
    renderer.dropNextFrameWhenBusy = drop
    renderer.setScrollPhaseOffset(CGPoint(x: 0, y: phasePoints))
    let committed = renderer.render(commands(), damage: .full)
    _ = renderer.pngData  // waits on the command buffer → releases the in-flight slot
    return committed
  }

  /// Output-driven (non-scroll) frames must never be dropped when paced: the
  /// scheduler waits for pipeline capacity rather than skipping, so a full-damage
  /// repaint always lands. Typed output never silently vanishes.
  func testNonScrollFramesAlwaysCommitWhenPaced() throws {
    let renderer = try makeRenderer()
    for _ in 0..<30 {
      XCTAssertTrue(
        renderDrained(renderer),
        "an output-driven full-damage frame was dropped despite pacing")
    }
  }

  /// Scroll frames opt into drop-don't-block. Rapid-fire scroll rendering must
  /// keep producing valid frames without hanging or wedging the renderer, and
  /// never silently fall back to the raster path. Under a no-wait burst some
  /// ticks drop on the in-flight slot (expected) — the renderer must recover and
  /// keep presenting as capacity frees.
  func testScrollFramesDropDoNotWedge() throws {
    let renderer = try makeRenderer()
    let attempts = 120
    var committed = 0
    for i in 0..<attempts {
      renderer.dropNextFrameWhenBusy = true
      let phasePoints = (CGFloat(i % 8) / 8.0 - 0.5) / 2.0
      renderer.setScrollPhaseOffset(CGPoint(x: 0, y: phasePoints))
      if renderer.render(commands(), damage: .full) {
        committed += 1
      }
    }
    // Not permanently wedged: at least some frames present even under a no-wait
    // burst, and the renderer never throws or hangs.
    XCTAssertGreaterThan(committed, 0, "scroll rendering wedged — no frame ever committed")
    // Drop-mode scroll must not silently fall back to the raster path.
    XCTAssertEqual(renderer.lastRasterFallbackGlyphs, 0)
  }

  /// The drop flag is consumed each frame (one-shot), exactly like
  /// `MetalRenderer.dropNextFrameWhenBusy`: a single scroll frame must not leave
  /// the renderer in drop mode for subsequent output-driven frames.
  func testDropFlagIsOneShot() throws {
    let renderer = try makeRenderer()
    // A scroll frame opts into dropping...
    renderDrained(renderer, drop: true, phasePoints: 0.1)
    // ...but the flag is one-shot: the next output-driven frame (which did not
    // set it) takes the always-commit path.
    XCTAssertTrue(
      renderDrained(renderer),
      "drop flag leaked into the next output-driven frame")
  }

  /// Full-damage frames are correctness frames, even if a caller also carried a
  /// drop hint from scroll state. The scheduler must wait briefly for the
  /// in-flight slot instead of treating `dropIfBusy` as an unconditional
  /// zero-timeout.
  func testFullFrameDropHintWaitsForInFlightFrame() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
    let layer = CAMetalLayer()
    layer.device = device
    let scheduler = MetalDrawableScheduler(layer: layer)
    let held = try XCTUnwrap(scheduler.beginFrame(needsFullFrame: false))

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(5)) {
      held.finish()
    }

    let fullFrame = scheduler.beginFrame(needsFullFrame: true, dropIfBusy: true)
    XCTAssertNotNil(fullFrame, "full-damage frame should wait for the previous frame slot")
    fullFrame?.finish()
  }

  /// The miss-recovery wake (the escape from the half-rate basin) is wired
  /// through to the scheduler. Installing it must not crash and the renderer
  /// keeps rendering with it set or cleared.
  func testDrawableReadyWakeIsInstallable() throws {
    let renderer = try makeRenderer()
    renderer.onDrawableReadyAfterMiss = {}
    XCTAssertTrue(renderDrained(renderer))
    renderer.onDrawableReadyAfterMiss = nil
    XCTAssertTrue(renderDrained(renderer))
  }

  /// The per-frame mask-bake *dispatch* budget bounds the worst-case main-thread
  /// cost during a fast scroll: a frame that newly reveals far more glyphs than
  /// the budget must not bake them all at once (the dispatch burst that slipped
  /// the present and left the residual jank tail). Overflow glyphs render from the
  /// O(1) raster atlas this frame and bake to vector quality over later frames, so
  /// every glyph is always drawn (no blanks) and the screen fully converges.
  func testMaskBakeDispatchesAreBoundedPerScrollFrameYetAllConverge() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 1200, pixelHeight: 60, scale: 2))

    // A wide run of many distinct glyphs — far more than one frame's dispatch
    // budget — to emulate a whole new row entering at once during a fling.
    let wide = String((0..<140).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" }.joined())
    let line = String(wide.prefix(130))
    let cmds: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 600, height: 30), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 2, y: 8), text: line,
        foreground: 0xFF_FF_FF_FF, background: 0x00_00_00_FF,
        attributes: [], source: .terminal),
    ]

    // Scroll active (non-zero phase): each frame's NEW-entry bakes must be capped.
    var everResident = false
    for frame in 0..<40 {
      // Vary the phase a little so the scroll looks live, but keep it within the
      // settle window so motion is "active" (per-phase baking stays gated off).
      renderer.setScrollPhaseOffset(CGPoint(x: 0, y: (frame % 2 == 0 ? 0.12 : 0.13)))
      XCTAssertTrue(renderer.render(cmds, damage: .full))
      _ = renderer.pngData  // drain to free the in-flight slot for the next frame
      XCTAssertLessThanOrEqual(
        renderer.lastMaskBakeDispatchCount, 24,
        "frame \(frame) baked \(renderer.lastMaskBakeDispatchCount) new masks — dispatch budget breached"
      )
      if renderer.lastMaskBakeDispatchCount == 0 { everResident = true }
    }
    // Over many frames the whole line must converge to resident (a later frame
    // bakes nothing new) — the budget only defers, never drops, vector quality.
    XCTAssertTrue(everResident, "the line never fully converged to resident vector masks")
  }

  /// A glyph repeated across many cells must bake at most once per frame, not
  /// once per cell. The per-frame glyph memo collapses the residency/draw resolve
  /// from per-cell (~thousands on a full screen) to per distinct glyph (~tens) —
  /// the fix that pulled fluid's per-frame CPU back under the 8.33 ms budget and
  /// erased the ~17 ms p99 jank tail (verified on-device, not just here). Render a
  /// long run of ONE repeated character at a fresh phase and assert exactly one
  /// new-mask bake that frame.
  func testRepeatedGlyphBakesOncePerFrameNotPerCell() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    let atlas = FontAtlas(pointSize: 16, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas, sidebarFontAtlas: atlas,
        pixelWidth: 1200, pixelHeight: 60, scale: 2))
    let line = String(repeating: "W", count: 120)  // one distinct glyph, 120 cells
    let cmds: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 600, height: 30), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 2, y: 8), text: line,
        foreground: 0xFF_FF_FF_FF, background: 0x00_00_00_FF,
        attributes: [], source: .terminal),
    ]
    // First scroll frame: the single distinct glyph 'W' bakes exactly once,
    // despite filling 120 cells — proof the per-frame memo dedupes the resolve.
    renderer.setScrollPhaseOffset(CGPoint(x: 0, y: 0.12))
    XCTAssertTrue(renderer.render(cmds, damage: .full))
    _ = renderer.pngData
    XCTAssertEqual(
      renderer.lastMaskBakeDispatchCount, 1,
      "a glyph repeated across 120 cells baked \(renderer.lastMaskBakeDispatchCount) times — the per-frame memo is not deduping"
    )
    XCTAssertEqual(renderer.lastRasterFallbackGlyphs, 0)
  }
}
