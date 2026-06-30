import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanApp

/// Gates for continuous pinch / Cmd+scroll zoom on the vector renderer.
///
/// The pure size-mapping math is backend-independent and tested directly. The
/// reflow-throttling gate drives the fractional apply path on the software
/// harness (no Metal needed in CI): the throttle logic — reflow only when the
/// integer `(cols, rows)` actually change — is backend-independent, so the
/// software backend exercises it faithfully.
final class ContinuousZoomTests: XCTestCase {

  // MARK: - M1: pure size-mapping function

  func testZoomPointSizeFractionalIsExactMultiplicative() {
    XCTAssertEqual(
      TerminalBitmapView.zoomPointSize(
        base: 14, accumulatedMagnification: 0.25, fractional: true),
      17.5, accuracy: 1e-9)
  }

  func testZoomPointSizeNonFractionalRoundsToLadder() {
    XCTAssertEqual(
      TerminalBitmapView.zoomPointSize(
        base: 14, accumulatedMagnification: 0.25, fractional: false),
      18.0, accuracy: 1e-9)
  }

  func testZoomPointSizeClampsBothEnds() {
    XCTAssertEqual(
      TerminalBitmapView.zoomPointSize(
        base: 14, accumulatedMagnification: 100, fractional: true),
      FontAtlas.zoomMaximumPointSize, accuracy: 1e-9)
    XCTAssertEqual(
      TerminalBitmapView.zoomPointSize(
        base: 14, accumulatedMagnification: -0.99, fractional: true),
      FontAtlas.zoomMinimumPointSize, accuracy: 1e-9)
  }

  func testZoomPointSizeFractionalRubberBandsNearMinimum() {
    let rawTarget: CGFloat = 8.5
    let size = TerminalBitmapView.zoomPointSize(
      base: 14,
      accumulatedMagnification: rawTarget / 14 - 1,
      fractional: true)
    XCTAssertGreaterThan(size, FontAtlas.zoomMinimumPointSize)
    XCTAssertLessThan(size, rawTarget)
  }

  func testZoomPointSizeFractionalRubberBandsNearMaximum() {
    let rawTarget: CGFloat = 39.5
    let size = TerminalBitmapView.zoomPointSize(
      base: 14,
      accumulatedMagnification: rawTarget / 14 - 1,
      fractional: true)
    XCTAssertLessThan(size, FontAtlas.zoomMaximumPointSize)
    XCTAssertLessThan(size, rawTarget)
  }

  func testZoomPointSizeRubberBandResistanceGrowsTowardMinimum() {
    func mapped(_ raw: CGFloat) -> CGFloat {
      TerminalBitmapView.zoomPointSize(
        base: 14,
        accumulatedMagnification: raw / 14 - 1,
        fractional: true)
    }
    let upperStep = mapped(9.5) - mapped(9.0)
    let lowerStep = mapped(9.0) - mapped(8.5)
    XCTAssertGreaterThan(upperStep, lowerStep)
  }

  func testZoomPointSizeIsMonotonicInAccumulator() {
    var previous = -Double.greatestFiniteMagnitude
    for hundredths in stride(from: -50, through: 200, by: 1) {
      let acc = CGFloat(hundredths) / 100
      let size = Double(
        TerminalBitmapView.zoomPointSize(
          base: 14, accumulatedMagnification: acc, fractional: true))
      XCTAssertGreaterThanOrEqual(size, previous)
      previous = size
    }
  }

  // MARK: - M1: gesture accumulation + persist-on-end

  func testPinchGesturePersistsOnlyOnEnd() throws {
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    let defaults = UserDefaults.standard
    let savedSize = defaults.object(forKey: FontAtlas.userFontSizeKey)
    defer {
      if let savedSize {
        defaults.set(savedSize, forKey: FontAtlas.userFontSizeKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontSizeKey)
      }
    }
    defaults.removeObject(forKey: FontAtlas.userFontSizeKey)

    harness.view.applyZoomMagnification(delta: 0, phase: .began)
    harness.view.applyZoomMagnification(delta: 0.1, phase: .changed)
    // Mid-gesture: the live atlas moved, but nothing was persisted yet.
    XCTAssertNil(
      defaults.object(forKey: FontAtlas.userFontSizeKey),
      "live gesture frames must not persist")

    harness.view.applyZoomMagnification(delta: 0.15, phase: .changed)
    harness.view.applyZoomMagnification(delta: 0, phase: .ended)

    // Software backend → quantized: base 14 * (1 + 0.25) = 17.5 → 18.
    let persisted = try XCTUnwrap(defaults.object(forKey: FontAtlas.userFontSizeKey) as? Double)
    XCTAssertEqual(persisted, 18.0, accuracy: 1e-9)
    let state = harness.view.debugZoomState()
    XCTAssertEqual(state["effectivePointSize"] as? Double, 18.0)
  }

  func testCmdScrollDrivesZoom() throws {
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    let defaults = UserDefaults.standard
    let savedSize = defaults.object(forKey: FontAtlas.userFontSizeKey)
    defer {
      if let savedSize {
        defaults.set(savedSize, forKey: FontAtlas.userFontSizeKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontSizeKey)
      }
    }

    let location = NSPoint(x: SidebarLayout.defaultWidth + 20, y: 5)
    harness.view.scrollWheel(
      with: TestScrollWheelEvent(
        locationInWindow: location, deltaY: 0, scrollingDeltaY: 60,
        hasPreciseScrollingDeltas: true, modifierFlags: .command, phase: .began))
    harness.view.scrollWheel(
      with: TestScrollWheelEvent(
        locationInWindow: location, deltaY: 0, scrollingDeltaY: 60,
        hasPreciseScrollingDeltas: true, modifierFlags: .command, phase: .ended))

    let size = try XCTUnwrap(harness.view.debugZoomState()["effectivePointSize"] as? Double)
    XCTAssertGreaterThan(size, 14.0, "Cmd+scroll up must zoom in past the base size")
  }

  /// The Cmd+scroll lock-up fix: a phase-less PRECISE scroll burst (dozens of
  /// events) must be coalesced into one gesture — zero per-event commits during
  /// the burst (each commit is a ~26 ms reconfigureFonts that floods the main
  /// thread) — and tracked continuously by the compositor scale instead.
  func testPhaselessPreciseCmdScrollCoalescesAndDoesNotCommitPerEvent() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    harness.view.applyRendererSelection(.vectorGlyph)
    guard harness.view.debugZoomState()["fractional"] as? Bool == true else {
      throw XCTSkip("vector backend not active (no GPU in this environment)")
    }

    let location = NSPoint(x: SidebarLayout.defaultWidth + 20, y: 5)
    for _ in 0..<40 {
      harness.view.scrollWheel(
        with: TestScrollWheelEvent(
          locationInWindow: location, deltaY: 0, scrollingDeltaY: 8,
          hasPreciseScrollingDeltas: true, modifierFlags: .command, phase: []))
    }

    // During the burst: one gesture is active, tracked by the compositor scale,
    // with NO per-event commits (the lock-up was 40 commits x ~26 ms here).
    let s = harness.view.debugZoomState()
    XCTAssertEqual(s["gestureActive"] as! Bool, true, "burst coalesces into one active gesture")
    XCTAssertEqual(
      harness.view.debugZoomGestureBakeCount, 0,
      "no per-event commit during the burst (commits=\(harness.view.debugZoomGestureBakeCount))")
    XCTAssertGreaterThan(
      s["visualPointSize"] as! Double, 14.0, "the burst still zooms via the compositor scale")
  }

  /// Regression for the review's finding #1: a precise scrolling device that
  /// streams `phase == []` (no began/ended envelope, e.g. some Magic Mouse
  /// configs) must still zoom AND eventually persist — coalesced into one
  /// gesture that commits once the stream goes quiet (not a perpetual `.changed`
  /// that never resets/persists, and not a per-event commit that locks up).
  func testCmdScrollWithoutPhaseEnvelopeZoomsAndPersistsOnSettle() throws {
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    let defaults = UserDefaults.standard
    let savedSize = defaults.object(forKey: FontAtlas.userFontSizeKey)
    defer {
      if let savedSize {
        defaults.set(savedSize, forKey: FontAtlas.userFontSizeKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontSizeKey)
      }
    }
    defaults.removeObject(forKey: FontAtlas.userFontSizeKey)

    let location = NSPoint(x: SidebarLayout.defaultWidth + 20, y: 5)
    // Precise deltas, Cmd held, but NO phase (phase: []), repeated.
    for _ in 0..<5 {
      harness.view.scrollWheel(
        with: TestScrollWheelEvent(
          locationInWindow: location, deltaY: 0, scrollingDeltaY: 40,
          hasPreciseScrollingDeltas: true, modifierFlags: .command, phase: []))
    }

    // The burst zooms immediately (visual size grew via the live path/scale).
    let size = try XCTUnwrap(harness.view.debugZoomState()["effectivePointSize"] as? Double)
    XCTAssertGreaterThan(size, 14.0, "phase-less Cmd+scroll must still zoom")

    // The single commit fires once the stream goes quiet (the coalesce timer);
    // spin the run loop past the quiet window, then it must have persisted.
    let deadline = Date().addingTimeInterval(0.6)
    while defaults.object(forKey: FontAtlas.userFontSizeKey) == nil, Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    let persisted = try XCTUnwrap(
      defaults.object(forKey: FontAtlas.userFontSizeKey) as? Double,
      "coalesced Cmd+scroll must persist its final size once the stream settles")
    XCTAssertGreaterThan(persisted, 14.0)
    XCTAssertEqual(
      harness.view.debugZoomState()["gestureActive"] as! Bool, false,
      "the gesture must end (and reset) after the stream settles")
  }

  // MARK: - M2: reflow throttling

  func testFractionalSweepReflowsOnlyOnGridBoundaryCrossings() throws {
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }

    // Seed the baseline from the live grid before the sweep: a reflow is a
    // *change* of (cols,rows), so the first step counts only if it crosses a
    // boundary, exactly as the throttle decides.
    let baseline = harness.view.debugZoomState()
    var lastPair = [baseline["cols"] as! Int, baseline["rows"] as! Int]
    var expectedReflows = 0
    var steps = 0
    for tenths in stride(from: 141, through: 240, by: 1) {
      steps += 1
      harness.view.applyFontSize(
        CGFloat(tenths) / 10, quantize: false, persist: false, throttleReflow: true)
      let state = harness.view.debugZoomState()
      let pair = [state["cols"] as! Int, state["rows"] as! Int]
      if lastPair != pair { expectedReflows += 1 }
      lastPair = pair
    }

    XCTAssertEqual(
      harness.view.debugGridReflowCount, expectedReflows,
      "reflow (SIGWINCH) must fire once per distinct (cols,rows) pair, not per frame")
    XCTAssertLessThan(
      expectedReflows, steps,
      "the sweep must cross fewer grid boundaries than it has frames (else nothing was throttled)")
  }

  // MARK: - M3: end-to-end gesture smoothness (zero rebakes during motion)

  /// The smoothness proof: a fine-grained pinch (many small magnification deltas,
  /// as a real trackpad delivers) must NOT re-rasterize or reflow the grid at all
  /// during the motion — every frame is a free compositor presentation-scale
  /// transform. The single rebake happens once, on gesture end. This is what
  /// makes the motion continuous instead of stalling/snapping at size steps.
  func testVectorGestureDoesNotRebakeDuringMotion() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    harness.view.applyRendererSelection(.vectorGlyph)
    guard harness.view.debugZoomState()["fractional"] as? Bool == true else {
      throw XCTSkip("vector backend not active (no GPU in this environment)")
    }

    // Drive a 14 -> ~26 pt slide in 120 tiny steps (a ~1 s gesture at 120 Hz).
    harness.view.applyZoomMagnification(delta: 0, phase: .began)
    let changedSteps = 120
    for _ in 0..<changedSteps {
      // ~0.6% per event compounds to ~2x over 120 steps.
      harness.view.applyZoomMagnification(delta: 0.006, phase: .changed)
    }
    let framesDuringMotion = harness.view.debugZoomGestureFrameCount
    let bakesDuringMotion = harness.view.debugZoomGestureBakeCount
    let reflowsDuringMotion = harness.view.debugGridReflowCount

    // began (delta 0) + 120 changed = 121 tracked gesture frames, all transforms.
    XCTAssertEqual(framesDuringMotion, changedSteps + 1, "every gesture event is a tracked frame")
    XCTAssertEqual(
      bakesDuringMotion, 0,
      "the gesture must not re-rasterize during motion (bakes=\(bakesDuringMotion))")
    XCTAssertEqual(
      reflowsDuringMotion, 0,
      "the gesture must not reflow the grid / send SIGWINCH during motion "
        + "(reflows=\(reflowsDuringMotion))")

    // Gesture end debounces the commit (so an in-out-in flurry coalesces); the
    // bake has not happened yet at this instant.
    harness.view.applyZoomMagnification(delta: 0, phase: .ended)
    XCTAssertEqual(
      harness.view.debugZoomGestureBakeCount, 0, "the commit is deferred, not baked inline")
    XCTAssertTrue(harness.view.debugZoomCommitPending, "a debounced commit is pending after .ended")
    // Flush the debounce (the quiet timer, run synchronously): exactly one rebake
    // + reflow lands the true size crisp.
    harness.view.debugFlushZoomCommit()
    XCTAssertEqual(
      harness.view.debugZoomGestureBakeCount, 1, "exactly one rebake commits on gesture settle")
    XCTAssertGreaterThan(
      harness.view.debugGridReflowCount, 0, "the grid reflows once at the settled size")
  }

  /// The freeze fix: a frantic in-out-in-out pinch is delivered by macOS as
  /// SEVERAL began/changed/ended bursts in quick succession. Each fractional
  /// `.ended` used to bake synchronously (~130 ms), stacking into a
  /// multi-hundred-ms freeze. With commit-coalescing, every `.ended` that is
  /// followed by more gesture activity within the quiet window is cancelled, so
  /// the whole flurry costs exactly ONE bake at the final size.
  func testRapidInOutPinchFlurryCoalescesToOneCommit() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    harness.view.applyRendererSelection(.vectorGlyph)
    guard harness.view.debugZoomState()["fractional"] as? Bool == true else {
      throw XCTSkip("vector backend not active (no GPU in this environment)")
    }

    // Five bursts: in, out, in, out, in — each a tiny began/changed/ended that
    // macOS would deliver as the user reverses direction without lifting cleanly.
    let bursts: [CGFloat] = [0.3, -0.2, 0.25, -0.15, 0.2]
    for delta in bursts {
      harness.view.applyZoomMagnification(delta: 0, phase: .began)
      harness.view.applyZoomMagnification(delta: delta, phase: .changed)
      harness.view.applyZoomMagnification(delta: 0, phase: .ended)
      // No flush between bursts: the next burst arrives within the quiet window
      // and must cancel the prior pending commit.
      XCTAssertTrue(
        harness.view.debugZoomCommitPending,
        "each .ended schedules a pending commit that the next burst cancels")
    }

    // Across five in/out bursts, not a single bake has happened yet.
    XCTAssertEqual(
      harness.view.debugZoomGestureBakeCount, 0,
      "no commit may bake while the flurry is still active "
        + "(got \(harness.view.debugZoomGestureBakeCount))")

    // The interaction settles: one flush, one bake — for the whole flurry.
    harness.view.debugFlushZoomCommit()
    XCTAssertEqual(
      harness.view.debugZoomGestureBakeCount, 1,
      "the entire in-out-in-out flurry must coalesce to exactly ONE bake")
    XCTAssertFalse(harness.view.debugZoomCommitPending, "no commit pending after settle")
  }

  /// The invariant the user asked for: at EVERY continuous zoom step the visual
  /// glyph size (`atlasPointSize * presentationScale`) must equal the gesture
  /// target and never exceed it — glyphs must not suddenly become bigger than
  /// the cells they sit in. Cmd+/- (discrete) always looks right; this proves
  /// the continuous path matches at every fractional step.
  func testContinuousZoomVisualSizeNeverExceedsTarget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    harness.view.applyRendererSelection(.vectorGlyph)
    guard harness.view.debugZoomState()["fractional"] as? Bool == true else {
      throw XCTSkip("vector backend not active (no GPU in this environment)")
    }

    func check(_ s: [String: Any], _ label: String) {
      let visual = s["visualPointSize"] as! Double
      let target = s["targetPointSize"] as! Double
      let atlas = s["atlasPointSize"] as! Double
      let scale = s["presentationScale"] as! Double
      // Visual must match the target within a hair (float), and crucially never
      // overshoot it (the "too big for the cell" symptom).
      XCTAssertEqual(
        visual, target, accuracy: 0.01,
        "\(label): visual \(visual) != target \(target) [atlas=\(atlas) scale=\(scale)]")
      XCTAssertLessThanOrEqual(
        visual, target + 0.01,
        "\(label): visual size \(visual) exceeds target \(target) — glyphs too big")
      XCTAssertLessThanOrEqual(
        visual, Double(FontAtlas.zoomMaximumPointSize) + 0.01,
        "\(label): visual size \(visual) above zoom max")
    }

    check(harness.view.debugApplyPinch(magnification: 0, phase: "began"), "began")
    // Sweep up to ~2x, then back down — both directions, fine steps.
    for _ in 0..<140 {
      check(harness.view.debugApplyPinch(magnification: 0.005, phase: "changed"), "up")
    }
    for _ in 0..<200 {
      check(harness.view.debugApplyPinch(magnification: -0.005, phase: "changed"), "down")
    }
    check(harness.view.debugApplyPinch(magnification: 0, phase: "ended"), "ended")
  }

  /// The lock-up / "weird state" report: after a gesture ends (or is cancelled),
  /// the presentation scale must return to exactly identity and no gesture may be
  /// left in flight. A stuck scale is the terminal frozen visually zoomed.
  func testGestureLeavesNoStuckScale() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    harness.view.applyRendererSelection(.vectorGlyph)
    guard harness.view.debugZoomState()["fractional"] as? Bool == true else {
      throw XCTSkip("vector backend not active (no GPU in this environment)")
    }

    func assertResting(_ label: String) {
      let s = harness.view.debugZoomState()
      XCTAssertEqual(
        s["presentationScale"] as! Double, 1.0, accuracy: 1e-6,
        "\(label): presentation scale must be identity at rest")
      XCTAssertEqual(s["gestureActive"] as! Bool, false, "\(label): no gesture in flight at rest")
    }

    // Normal gesture. `.ended` debounces the commit, so flush it before asserting
    // the scale has returned to identity (the commit resets it).
    harness.view.applyZoomMagnification(delta: 0, phase: .began)
    for _ in 0..<30 { harness.view.applyZoomMagnification(delta: 0.01, phase: .changed) }
    harness.view.applyZoomMagnification(delta: 0, phase: .ended)
    harness.view.debugFlushZoomCommit()
    assertResting("after ended")

    // Cancelled gesture must also reset.
    harness.view.applyZoomMagnification(delta: 0, phase: .began)
    for _ in 0..<30 { harness.view.applyZoomMagnification(delta: 0.01, phase: .changed) }
    harness.view.applyZoomMagnification(delta: 0, phase: .cancelled)
    assertResting("after cancelled")

    // Gesture interrupted by a renderer switch must not leave a stuck scale.
    harness.view.applyZoomMagnification(delta: 0, phase: .began)
    for _ in 0..<30 { harness.view.applyZoomMagnification(delta: 0.01, phase: .changed) }
    harness.view.applyRendererSelection(.classic)
    harness.view.applyRendererSelection(.vectorGlyph)
    assertResting("after renderer switch mid-gesture")

    // Stray events with no gesture in flight (momentum tail / post-ended
    // `.changed`, duplicate `.ended`) must be ignored — not start a phantom
    // gesture that leaves a stuck scale.
    harness.view.applyZoomMagnification(delta: 0.05, phase: .changed)
    harness.view.applyZoomMagnification(delta: 0.05, phase: .changed)
    harness.view.applyZoomMagnification(delta: 0, phase: .ended)
    assertResting("after stray changed/ended with no gesture")
  }

  func testSlugGestureUsesFractionalProjectionPath() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    let defaults = UserDefaults.standard
    let savedSize = defaults.object(forKey: FontAtlas.userFontSizeKey)
    defer {
      if let savedSize {
        defaults.set(savedSize, forKey: FontAtlas.userFontSizeKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontSizeKey)
      }
    }
    defaults.removeObject(forKey: FontAtlas.userFontSizeKey)

    harness.view.applyRendererSelection(.slugGlyph)
    let initial = harness.view.debugZoomState()
    guard initial["backend"] as? String == RendererSelection.slugGlyph.rawValue,
      initial["fractional"] as? Bool == true
    else {
      throw XCTSkip("slug backend not active (no GPU or pipeline unavailable)")
    }
    let reflowsBefore = harness.view.debugGridReflowCount

    _ = harness.view.debugApplyPinch(magnification: 0, phase: "began")
    let changed = harness.view.debugApplyPinch(magnification: 0.125, phase: "changed")
    let target = try XCTUnwrap(changed["targetPointSize"] as? Double)
    let atlasPointSize = try XCTUnwrap(changed["atlasPointSize"] as? Double)
    let visualPointSize = try XCTUnwrap(changed["visualPointSize"] as? Double)
    let presentationScale = try XCTUnwrap(changed["presentationScale"] as? Double)
    XCTAssertEqual(changed["backend"] as? String, RendererSelection.slugGlyph.rawValue)
    XCTAssertEqual(changed["fractional"] as? Bool, true)
    XCTAssertEqual(atlasPointSize, 14.0, accuracy: 1e-9)
    XCTAssertEqual(visualPointSize, target, accuracy: 0.01)
    XCTAssertEqual(presentationScale, target / 14.0, accuracy: 0.01)
    XCTAssertEqual(
      harness.view.debugGridReflowCount,
      reflowsBefore,
      "Slug continuous motion must not reflow the grid per event")

    _ = harness.view.debugApplyPinch(magnification: 0, phase: "ended")
    XCTAssertTrue(harness.view.debugZoomCommitPending)
    harness.view.debugFlushZoomCommit()

    let rested = harness.view.debugZoomState()
    let restedPresentationScale = try XCTUnwrap(rested["presentationScale"] as? Double)
    let restedAtlasPointSize = try XCTUnwrap(rested["atlasPointSize"] as? Double)
    let restedVisualPointSize = try XCTUnwrap(rested["visualPointSize"] as? Double)
    XCTAssertEqual(rested["backend"] as? String, RendererSelection.slugGlyph.rawValue)
    XCTAssertEqual(rested["fractional"] as? Bool, true)
    XCTAssertEqual(restedPresentationScale, 1.0, accuracy: 1e-9)
    XCTAssertEqual(rested["gestureActive"] as? Bool, false)
    XCTAssertEqual(restedAtlasPointSize, target, accuracy: 0.05)
    XCTAssertEqual(restedVisualPointSize, target, accuracy: 0.05)
  }

  func testSlugZoomDebugStateReportsNoGeometryUploadStormDuringSweep() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let harness = try makeHarness(rows: 24, cols: 80)
    defer { harness.restoreRenderer() }
    let defaults = UserDefaults.standard
    let savedSize = defaults.object(forKey: FontAtlas.userFontSizeKey)
    defer {
      if let savedSize {
        defaults.set(savedSize, forKey: FontAtlas.userFontSizeKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontSizeKey)
      }
    }
    defaults.removeObject(forKey: FontAtlas.userFontSizeKey)

    harness.view.applyRendererSelection(.slugGlyph)
    harness.write("Slug zoom debug glyphs 0123456789 abcdefghijklmnopqrstuvwxyz\r\n")
    let rendered = harness.view.debugZoomState()
    guard rendered["backend"] as? String == RendererSelection.slugGlyph.rawValue,
      rendered["fractional"] as? Bool == true
    else {
      throw XCTSkip("slug backend not active (no GPU or pipeline unavailable)")
    }
    let uploadsBefore = try XCTUnwrap(rendered["geometryBufferUploadCount"] as? Int)
    let buildsBefore = try XCTUnwrap(rendered["curveBufferBuildCount"] as? Int)
    XCTAssertGreaterThan(uploadsBefore, 0, "the setup frame must exercise Slug glyph geometry")
    XCTAssertGreaterThan(buildsBefore, 0, "the setup frame must build Slug glyph geometry")

    _ = harness.view.debugApplyPinch(magnification: 0, phase: "began")
    harness.view.advanceFrame()
    let start = ContinuousClock.now
    var lastState = harness.view.debugZoomState()
    for _ in 0..<30 {
      lastState = harness.view.debugApplyPinch(magnification: 0.006, phase: "changed")
      harness.view.advanceFrame()
      XCTAssertEqual(lastState["backend"] as? String, RendererSelection.slugGlyph.rawValue)
      XCTAssertEqual(lastState["fractional"] as? Bool, true)
      XCTAssertEqual(
        lastState["geometryBufferUploadCount"] as? Int,
        uploadsBefore,
        "Slug zoom frames must not upload per-size glyph geometry")
      XCTAssertEqual(
        lastState["curveBufferBuildCount"] as? Int,
        buildsBefore,
        "Slug zoom frames must not rebuild per-size glyph curves")
    }
    let elapsed = (ContinuousClock.now - start).components
    let elapsedMs = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    XCTAssertLessThan(elapsedMs, 500, "debug Slug sweep should not stall the test harness")
    XCTAssertEqual(lastState["gestureActive"] as? Bool, true)
    XCTAssertGreaterThan(try XCTUnwrap(lastState["visualPointSize"] as? Double), 14.0)
    let png = try XCTUnwrap(harness.view.debugFramePNG())
    XCTAssertEqual(
      Array(png.prefix(8)),
      [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a],
      "scroll-debug screenshot seam must return a PNG for Slug")
    try writeSlugZoomArtifactIfRequested(png: png, state: lastState)

    _ = harness.view.debugApplyPinch(magnification: 0, phase: "ended")
    harness.view.debugFlushZoomCommit()
  }

  // MARK: - Harness

  private struct Harness {
    var model: AppModel
    var session: Session
    var view: TerminalBitmapView
    var oldRenderer: String?

    func write(_ raw: String) {
      session.write(Array(raw.utf8))
      view.advanceFrame()
    }

    func restoreRenderer() {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }
  }

  private func makeHarness(rows: Int32, cols: Int32) throws -> Harness {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)

    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * CGFloat(cellWidth) + insets.right
    let viewHeight = insets.top + CGFloat(rows) * CGFloat(cellHeight) + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth,
      cellHeight: cellHeight)
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
    let activeTab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: activeTab.id))

    return Harness(model: model, session: session, view: view, oldRenderer: oldRenderer)
  }

  private func writeSlugZoomArtifactIfRequested(png: Data, state: [String: Any]) throws {
    guard let root = ProcessInfo.processInfo.environment["LABAN_SLUG_GLYPH_ARTIFACTS"],
      !root.isEmpty
    else { return }
    let rootURL = URL(fileURLWithPath: root, isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let pngURL = rootURL.appendingPathComponent("slug-glyph-m3-zoom-sweep.png")
    try png.write(to: pngURL, options: .atomic)
    let manifest = try JSONSerialization.data(
      withJSONObject: [
        "artifact": pngURL.path,
        "backend": state["backend"] ?? "",
        "fractional": state["fractional"] ?? false,
        "visualPointSize": state["visualPointSize"] ?? 0,
        "geometryBufferUploadCount": state["geometryBufferUploadCount"] ?? 0,
        "curveBufferBuildCount": state["curveBufferBuildCount"] ?? 0,
      ],
      options: [.prettyPrinted, .sortedKeys])
    try manifest.write(to: rootURL.appendingPathComponent("slug-glyph-m3-manifest.json"))
  }
}
