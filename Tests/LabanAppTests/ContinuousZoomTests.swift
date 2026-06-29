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

  // MARK: - M3: gesture size bucketing (smoothness lever)

  func testZoomBucketSnapsToGrid() {
    // 0.5 pt grid: 17.3 -> 17.5, 17.24 -> 17.0, 21.74 -> 21.5.
    XCTAssertEqual(TerminalBitmapView.zoomBucketPointSize(17.3, bucket: 0.5), 17.5, accuracy: 1e-9)
    XCTAssertEqual(TerminalBitmapView.zoomBucketPointSize(17.24, bucket: 0.5), 17.0, accuracy: 1e-9)
    XCTAssertEqual(TerminalBitmapView.zoomBucketPointSize(21.74, bucket: 0.5), 21.5, accuracy: 1e-9)
  }

  func testZoomBucketIsStableWithinABucket() {
    // The smoothness lever: many distinct fractional sizes inside one bucket all
    // snap to the SAME value, so the gesture re-applies fonts (and re-bakes) only
    // on bucket crossings, not every frame.
    // Round-to-nearest 0.5: [17.25, 17.75) all snap to 17.5.
    let a = TerminalBitmapView.zoomBucketPointSize(17.26, bucket: 0.5)
    let b = TerminalBitmapView.zoomBucketPointSize(17.49, bucket: 0.5)
    let c = TerminalBitmapView.zoomBucketPointSize(17.80, bucket: 0.5)
    XCTAssertEqual(a, 17.5, accuracy: 1e-9)
    XCTAssertEqual(a, b, accuracy: 1e-9)
    XCTAssertNotEqual(b, c)  // 17.80 crosses into the next bucket (18.0)
  }

  func testZoomBucketClampsIntoZoomRange() {
    XCTAssertEqual(
      TerminalBitmapView.zoomBucketPointSize(1000, bucket: 0.5),
      FontAtlas.zoomMaximumPointSize, accuracy: 1e-9)
    XCTAssertEqual(
      TerminalBitmapView.zoomBucketPointSize(0.1, bucket: 0.5),
      FontAtlas.zoomMinimumPointSize, accuracy: 1e-9)
  }

  func testZoomBucketCountAcrossSweepIsBounded() {
    // A 14->28 pt sweep at 0.5 pt buckets crosses ~28 distinct buckets, far
    // fewer than the number of gesture frames — that ratio is the re-bake saving.
    var buckets = Set<Double>()
    for hundredths in stride(from: 1400, through: 2800, by: 1) {
      let size = CGFloat(hundredths) / 100
      buckets.insert(Double(TerminalBitmapView.zoomBucketPointSize(size, bucket: 0.5)))
    }
    // 1400 frames, ~29 buckets.
    XCTAssertLessThanOrEqual(buckets.count, 30)
    XCTAssertGreaterThanOrEqual(buckets.count, 27)
  }

  // MARK: - M3: end-to-end gesture smoothness (bakes << frames)

  /// The smoothness proof: a fine-grained pinch (many small magnification deltas,
  /// as a real trackpad delivers) must re-rasterize only on bucket crossings,
  /// while every frame still tracks the finger via the free presentation-scale
  /// transform. So `bakeCount` must be a small fraction of `frameCount`.
  func testVectorGestureRebakesOncePerBucketNotPerFrame() throws {
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
    let frames = harness.view.debugZoomGestureFrameCount
    let bakes = harness.view.debugZoomGestureBakeCount
    harness.view.applyZoomMagnification(delta: 0, phase: .ended)

    // began (delta 0) + 120 changed = 121 tracked gesture frames.
    XCTAssertEqual(frames, changedSteps + 1, "every gesture event is a tracked frame")
    // 14->~26 pt at 0.5 pt buckets crosses ~24 buckets; allow slack but require
    // bakes to be well under a third of frames (the smoothness win).
    let ratioMessage =
      "gesture must re-bake ~once per 0.5pt bucket, not per frame "
      + "(bakes=\(bakes) frames=\(frames))"
    XCTAssertLessThan(bakes, frames / 3, ratioMessage)
    XCTAssertGreaterThan(bakes, 0, "a 2x slide must cross several buckets")
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

  // MARK: - Harness

  private struct Harness {
    var model: AppModel
    var view: TerminalBitmapView
    var oldRenderer: String?

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

    return Harness(model: model, view: view, oldRenderer: oldRenderer)
  }
}
