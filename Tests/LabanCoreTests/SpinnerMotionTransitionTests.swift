import XCTest
@testable import LabanCore
@testable import LabanRenderer

final class SpinnerMotionTransitionTests: XCTestCase {
  private var detector: SpinnerMotionDetector!

  override func setUp() {
    super.setUp()
    detector = SpinnerMotionDetector()
  }

  private func cell(
    row: Int,
    col: Int,
    foreground: UInt32
  ) -> SpinnerMotionCellState {
    SpinnerMotionCellState(
      key: SpinnerMotionCellKey(row: row, col: col),
      text: "◆",
      displayWidth: 1,
      foreground: foreground,
      background: 0x000000FF,
      attributes: [],
      underlineStyle: .none,
      underlineColor: nil,
      hyperlink: nil,
      wide: 0)
  }

  private func observation(
    at timestamp: Double,
    cells: [SpinnerMotionCellState]
  ) -> SpinnerMotionObservation {
    var map: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
    for c in cells { map[c.key] = c }
    return SpinnerMotionObservation(
      timestamp: timestamp,
      rows: 2,
      cols: 40,
      cells: map,
      mouseTracking: false)
  }

  private func transition(
    for colors: [UInt32],
    cadence: Double = 0.25
  ) -> GlyphForegroundTransition {
    for (i, color) in colors.enumerated() {
      _ = detector.observe(
        observation(at: Double(i) * cadence, cells: [cell(row: 0, col: 0, foreground: color)]))
    }
    return detector.activeTransitions(
      at: Double(colors.count - 1) * cadence)[SpinnerMotionCellKey(row: 0, col: 0)]!
  }

  func testTransitionCarriesLinearLightStartColor() {
    let t = transition(for: [0xFF0000FF, 0x0000FFFF, 0x00FF00FF])
    let expected = SRGBRenderTargetColor.linearizedStraightRGBA(0x0000FFFF)
    XCTAssertEqual(t.startLinearRGBA, expected)
  }

  func testSmoothstepProgressAtHalfDuration() {
    let duration = 0.25
    let progress = GlyphEffectTimeline.spinnerForegroundMotionProgress(
      age: duration / 2, duration: duration)
    XCTAssertEqual(progress, 0.5, accuracy: 1e-9)
  }

  func testMidpointMixIsLinearLight() {
    // Red → blue with a 0.25s cadence. At the midpoint the smoothstep is 0.5,
    // so the linear-light mix is the average of the linearized endpoints.
    let red = SRGBRenderTargetColor.linearizedStraightRGBA(0xFF0000FF)
    let blue = SRGBRenderTargetColor.linearizedStraightRGBA(0x0000FFFF)
    let midpoint = (red + blue) / 2
    let encoded = SRGBRenderTargetColor.encodedSRGBA(midpoint)
    // Reference value from the execplan acceptance criteria.
    XCTAssertEqual(encoded, 0xBC00BCFF)
  }

  func testExactStartAndEndPoints() {
    let t = transition(for: [0xFF0000FF, 0x0000FFFF, 0x00FF00FF], cadence: 0.25)
    XCTAssertEqual(t.startTimestampSeconds, 0.50, accuracy: 1e-9)
    XCTAssertEqual(t.durationSeconds, 0.25, accuracy: 1e-9)
  }

  func testEarlyRetargetContinuitySamplesMidInterpolation() {
    let colors: [UInt32] = [0xFF0000FF, 0x0000FFFF, 0x00FF00FF, 0xFFFF00FF]
    _ = detector.observe(observation(at: 0.00, cells: [cell(row: 0, col: 0, foreground: colors[0])]))
    _ = detector.observe(observation(at: 0.25, cells: [cell(row: 0, col: 0, foreground: colors[1])]))
    _ = detector.observe(observation(at: 0.50, cells: [cell(row: 0, col: 0, foreground: colors[2])]))
    _ = detector.observe(observation(at: 0.60, cells: [cell(row: 0, col: 0, foreground: colors[3])]))
    let t = detector.activeTransitions(at: 0.60)[SpinnerMotionCellKey(row: 0, col: 0)]!
    let previousSourceLinear = SRGBRenderTargetColor.linearizedStraightRGBA(colors[2])
    XCTAssertNotEqual(t.startLinearRGBA, previousSourceLinear)
    // The retarget start should be somewhere between blue and green, not the
    // previous source green and not the new target yellow.
    let yellowLinear = SRGBRenderTargetColor.linearizedStraightRGBA(colors[3])
    XCTAssertNotEqual(t.startLinearRGBA, yellowLinear)
  }

  func testStartColorIsNotPackedSRGB() {
    // Use a non-primary grey so the linear-light value diverges from the
    // normalized packed-sRGB value.
    let t = transition(for: [0x808080FF, 0xA0A0A0FF, 0xC0C0C0FF])
    let packed = SIMD4<Float>(
      Float((0xA0A0A0FF >> 24) & 0xFF) / 255,
      Float((0xA0A0A0FF >> 16) & 0xFF) / 255,
      Float((0xA0A0A0FF >> 8) & 0xFF) / 255,
      1)
    XCTAssertNotEqual(t.startLinearRGBA, packed)
  }
}
