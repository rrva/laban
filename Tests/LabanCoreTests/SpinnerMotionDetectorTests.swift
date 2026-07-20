import XCTest
@testable import LabanCore
@testable import LabanRenderer

final class SpinnerMotionDetectorTests: XCTestCase {
  private var detector: SpinnerMotionDetector!

  override func setUp() {
    super.setUp()
    detector = SpinnerMotionDetector()
  }

  private func cell(
    row: Int,
    col: Int,
    text: String = "◆",
    foreground: UInt32 = 0xFF0000FF,
    background: UInt32 = 0x000000FF
  ) -> SpinnerMotionCellState {
    SpinnerMotionCellState(
      key: SpinnerMotionCellKey(row: row, col: col),
      text: text,
      displayWidth: 1,
      foreground: foreground,
      background: background,
      attributes: [],
      underlineStyle: .none,
      underlineColor: nil,
      hyperlink: nil,
      wide: 0)
  }

  private func observation(
    at timestamp: Double,
    cells: [SpinnerMotionCellState],
    mouseTracking: Bool = false,
    rows: Int = 2,
    cols: Int = 40
  ) -> SpinnerMotionObservation {
    var map: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
    for c in cells { map[c.key] = c }
    return SpinnerMotionObservation(
      timestamp: timestamp,
      rows: rows,
      cols: cols,
      cells: map,
      mouseTracking: mouseTracking)
  }

  func testFirstObservationProducesNoTransitions() {
    let map = detector.observe(observation(at: 0, cells: [cell(row: 0, col: 0)]))
    XCTAssertTrue(map.isEmpty)
    XCTAssertFalse(detector.diagnostics.detectorActive)
  }

  func testThirdQualifyingForegroundOnlyObservationCreatesTransition() {
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertTrue(detector.diagnostics.detectorActive)
    let transition = map[SpinnerMotionCellKey(row: 0, col: 0)]!
    XCTAssertEqual(transition.durationSeconds, 0.25, accuracy: 1e-9)
    XCTAssertEqual(transition.startTimestampSeconds, 0.50, accuracy: 1e-9)
    XCTAssertEqual(transition.startLinearRGBA, SRGBRenderTargetColor.linearizedStraightRGBA(b.foreground))
  }

  func testDifferentGlyphSnapsAndDoesNotCreateTransition() {
    let a = cell(row: 0, col: 0, text: "◆", foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, text: "●", foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, text: "✦", foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertTrue(map.isEmpty)
  }

  func testBackgroundChangeSnaps() {
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF, background: 0x000000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF, background: 0x111111FF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF, background: 0x222222FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertTrue(map.isEmpty)
  }

  func testTooManyRowsDoesNotQualify() {
    let cells = [
      cell(row: 0, col: 0, foreground: 0xFF0000FF),
      cell(row: 1, col: 0, foreground: 0x00FF00FF),
      cell(row: 2, col: 0, foreground: 0x0000FFFF),
    ]
    let generation2 = [
      cell(row: 0, col: 0, foreground: 0x111111FF),
      cell(row: 1, col: 0, foreground: 0x222222FF),
      cell(row: 2, col: 0, foreground: 0x333333FF),
    ]
    let generation3 = [
      cell(row: 0, col: 0, foreground: 0x444444FF),
      cell(row: 1, col: 0, foreground: 0x555555FF),
      cell(row: 2, col: 0, foreground: 0x666666FF),
    ]
    _ = detector.observe(observation(at: 0.00, cells: cells))
    _ = detector.observe(observation(at: 0.25, cells: generation2))
    let map = detector.observe(observation(at: 0.50, cells: generation3))
    XCTAssertTrue(map.isEmpty)
  }

  func testCadenceClampedToMaximum() {
    let cadence = SpinnerMotion.maxCadenceSeconds
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: cadence, cells: [b]))
    let map = detector.observe(observation(at: 2 * cadence, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertEqual(map.first!.value.durationSeconds, cadence)
  }

  func testCadenceClampedToMinimum() {
    let cadence = SpinnerMotion.minCadenceSeconds
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: cadence, cells: [b]))
    let map = detector.observe(observation(at: 2 * cadence, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertEqual(map.first!.value.durationSeconds, cadence)
  }

  func testTransitionSettlesAfterDuration() {
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    _ = detector.observe(observation(at: 0.50, cells: [c]))
    let settled = detector.activeTransitions(at: 0.50 + SpinnerMotion.maxCadenceSeconds + 0.01)
    XCTAssertTrue(settled.isEmpty)
  }

  func testRetargetFromCurrentDisplayedColor() {
    let colors: [UInt32] = [0xFF0000FF, 0x0000FFFF, 0x00FF00FF, 0xFFFF00FF]
    let cadence = 0.25
    _ = detector.observe(observation(at: 0.00, cells: [cell(row: 0, col: 0, foreground: colors[0])]))
    _ = detector.observe(observation(at: 0.25, cells: [cell(row: 0, col: 0, foreground: colors[1])]))
    _ = detector.observe(observation(at: 0.50, cells: [cell(row: 0, col: 0, foreground: colors[2])]))
    // Fourth observation arrives before the third transition settles, so the
    // new start color is sampled mid-interpolation, not equal to the previous
    // terminal endpoint.
    _ = detector.observe(observation(at: 0.60, cells: [cell(row: 0, col: 0, foreground: colors[3])]))
    let transition = detector.activeTransitions(at: 0.60)[SpinnerMotionCellKey(row: 0, col: 0)]!
    let previousSourceLinear = SRGBRenderTargetColor.linearizedStraightRGBA(colors[2])
    XCTAssertNotEqual(transition.startLinearRGBA, previousSourceLinear)
  }

  func testMouseTrackingRecordedButDoesNotPreventDetection() {
    let a = cell(row: 0, col: 0, foreground: 0xFF0000FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a], mouseTracking: true))
    _ = detector.observe(observation(at: 0.25, cells: [b], mouseTracking: true))
    let map = detector.observe(observation(at: 0.50, cells: [c], mouseTracking: true))
    // The detector itself is renderer-agnostic; the caller gates eligibility.
    XCTAssertEqual(map.count, 1)
    XCTAssertTrue(detector.diagnostics.mouseTracking)
  }
}
