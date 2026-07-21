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
    foreground: UInt32 = 0xFF00_00FF,
    background: UInt32 = 0x0000_00FF
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
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertTrue(detector.diagnostics.detectorActive)
    let transition = map[SpinnerMotionCellKey(row: 0, col: 0)]!
    XCTAssertEqual(transition.durationSeconds, 0.25, accuracy: 1e-9)
    XCTAssertEqual(transition.startTimestampSeconds, 0.50, accuracy: 1e-9)
    XCTAssertEqual(
      transition.startLinearRGBA, SRGBRenderTargetColor.linearizedStraightRGBA(b.foreground))
  }

  func testDifferentGlyphSnapsAndDoesNotCreateTransition() {
    let a = cell(row: 0, col: 0, text: "◆", foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, text: "●", foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, text: "✦", foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertTrue(map.isEmpty)
  }

  func testBackgroundChangeSnaps() {
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF, background: 0x0000_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF, background: 0x1111_11FF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF, background: 0x2222_22FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertTrue(map.isEmpty)
  }

  func testTooManyRowsDoesNotQualify() {
    let cells = [
      cell(row: 0, col: 0, foreground: 0xFF00_00FF),
      cell(row: 1, col: 0, foreground: 0x00FF_00FF),
      cell(row: 2, col: 0, foreground: 0x0000_FFFF),
    ]
    let generation2 = [
      cell(row: 0, col: 0, foreground: 0x1111_11FF),
      cell(row: 1, col: 0, foreground: 0x2222_22FF),
      cell(row: 2, col: 0, foreground: 0x3333_33FF),
    ]
    let generation3 = [
      cell(row: 0, col: 0, foreground: 0x4444_44FF),
      cell(row: 1, col: 0, foreground: 0x5555_55FF),
      cell(row: 2, col: 0, foreground: 0x6666_66FF),
    ]
    _ = detector.observe(observation(at: 0.00, cells: cells))
    _ = detector.observe(observation(at: 0.25, cells: generation2))
    let map = detector.observe(observation(at: 0.50, cells: generation3))
    XCTAssertTrue(map.isEmpty)
  }

  func testCadenceClampedToMaximum() {
    let cadence = SpinnerMotion.maxCadenceSeconds
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: cadence, cells: [b]))
    let map = detector.observe(observation(at: 2 * cadence, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertEqual(map.first!.value.durationSeconds, cadence)
  }

  func testMinimumCadenceEngagesFinelySampledBypass() {
    let cadence = SpinnerMotion.minCadenceSeconds
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: cadence, cells: [b]))
    let map = detector.observe(observation(at: 2 * cadence, cells: [c]))
    // A 40 ms source already emits finely sampled motion; it renders
    // authoritatively instead of being double-smoothed.
    XCTAssertTrue(map.isEmpty)
    XCTAssertTrue(detector.diagnostics.detectorActive)
    XCTAssertTrue(detector.diagnostics.finelySampledBypass)
  }

  func testTransitionSettlesAfterDuration() {
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    _ = detector.observe(observation(at: 0.50, cells: [c]))
    let settled = detector.activeTransitions(at: 0.50 + SpinnerMotion.maxCadenceSeconds + 0.01)
    XCTAssertTrue(settled.isEmpty)
  }

  func testRetargetFromCurrentDisplayedColor() {
    let colors: [UInt32] = [0xFF00_00FF, 0x0000_FFFF, 0x00FF_00FF, 0xFFFF_00FF]
    let cadence = 0.25
    _ = detector.observe(
      observation(at: 0.00, cells: [cell(row: 0, col: 0, foreground: colors[0])]))
    _ = detector.observe(
      observation(at: 0.25, cells: [cell(row: 0, col: 0, foreground: colors[1])]))
    _ = detector.observe(
      observation(at: 0.50, cells: [cell(row: 0, col: 0, foreground: colors[2])]))
    // Fourth observation arrives before the third transition settles, so the
    // new start color is sampled mid-interpolation, not equal to the previous
    // terminal endpoint.
    _ = detector.observe(
      observation(at: 0.60, cells: [cell(row: 0, col: 0, foreground: colors[3])]))
    let transition = detector.activeTransitions(at: 0.60)[SpinnerMotionCellKey(row: 0, col: 0)]!
    let previousSourceLinear = SRGBRenderTargetColor.linearizedStraightRGBA(colors[2])
    XCTAssertNotEqual(transition.startLinearRGBA, previousSourceLinear)
  }

  func testMouseTrackingRecordedButDoesNotPreventDetection() {
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a], mouseTracking: true))
    _ = detector.observe(observation(at: 0.25, cells: [b], mouseTracking: true))
    let map = detector.observe(observation(at: 0.50, cells: [c], mouseTracking: true))
    // The detector itself is renderer-agnostic; the caller gates eligibility.
    XCTAssertEqual(map.count, 1)
    XCTAssertTrue(detector.diagnostics.mouseTracking)
  }

  func testRetargetAfterResetStartsFromDisplayedColorNotStaleSettledTarget() {
    let colors: [UInt32] = [
      0xFF00_00FF, 0x0000_FFFF, 0x00FF_00FF, 0xFFFF_00FF, 0x00FF_FFFF, 0xFF00_FFFF,
    ]
    // Activate and create a transition targeting colors[2].
    _ = detector.observe(
      observation(at: 0.00, cells: [cell(row: 0, col: 0, foreground: colors[0])]))
    _ = detector.observe(
      observation(at: 0.25, cells: [cell(row: 0, col: 0, foreground: colors[1])]))
    _ = detector.observe(
      observation(at: 0.50, cells: [cell(row: 0, col: 0, foreground: colors[2])]))
    // A gap beyond the cadence range resets the run. While the detector is
    // inactive the cell snaps through two more colors with no transitions,
    // leaving the settled colors[2] transition stale in the map.
    _ = detector.observe(
      observation(at: 1.50, cells: [cell(row: 0, col: 0, foreground: colors[3])]))
    _ = detector.observe(
      observation(at: 1.75, cells: [cell(row: 0, col: 0, foreground: colors[4])]))
    // The third qualifying observation reactivates the detector and retargets.
    // The new transition must start from the displayed color (colors[4]), not
    // from the stale settled target (colors[2]).
    let map = detector.observe(
      observation(at: 2.00, cells: [cell(row: 0, col: 0, foreground: colors[5])]))
    let transition = map[SpinnerMotionCellKey(row: 0, col: 0)]!
    XCTAssertEqual(
      transition.startLinearRGBA, SRGBRenderTargetColor.linearizedStraightRGBA(colors[4]))
  }

  func testRetargetAfterResetSamplesLiveTransitionTowardCurrentColor() {
    let colors: [UInt32] = [
      0xFF00_00FF, 0x0000_FFFF, 0x00FF_00FF, 0xFFFF_00FF, 0x00FF_FFFF, 0xFF00_FFFF,
    ]
    _ = detector.observe(
      observation(at: 0.00, cells: [cell(row: 0, col: 0, foreground: colors[0])]))
    _ = detector.observe(
      observation(at: 0.60, cells: [cell(row: 0, col: 0, foreground: colors[1])]))
    _ = detector.observe(
      observation(at: 1.20, cells: [cell(row: 0, col: 0, foreground: colors[2])]))
    // A distant newly visible cell resets the run without touching col 0.
    _ = detector.observe(
      observation(
        at: 1.33,
        cells: [
          cell(row: 0, col: 0, foreground: colors[2]),
          cell(row: 0, col: 10, foreground: colors[0]),
        ]))
    // Region {0} is not near region {10}: a second reset. While inactive,
    // col 0 snaps onward; its transition toward colors[2] stays live but no
    // longer represents the displayed color.
    _ = detector.observe(
      observation(
        at: 1.46,
        cells: [
          cell(row: 0, col: 0, foreground: colors[3]),
          cell(row: 0, col: 10, foreground: colors[0]),
        ]))
    _ = detector.observe(
      observation(
        at: 1.59,
        cells: [
          cell(row: 0, col: 0, foreground: colors[4]),
          cell(row: 0, col: 10, foreground: colors[0]),
        ]))
    // Reactivation retargets at t=1.72, above the finely sampled bypass exit
    // threshold. The renderer has been blending the live transition toward
    // the current cell color (colors[4]), so the sampled start must mix
    // start -> colors[4], not start -> colors[2].
    let map = detector.observe(
      observation(
        at: 1.72,
        cells: [
          cell(row: 0, col: 0, foreground: colors[5]),
          cell(row: 0, col: 10, foreground: colors[0]),
        ]))
    let transition = map[SpinnerMotionCellKey(row: 0, col: 0)]!
    let u = 0.52 / 0.60
    let p = u * u * (3 - 2 * u)
    let start = SRGBRenderTargetColor.linearizedStraightRGBA(colors[1])
    let current = SRGBRenderTargetColor.linearizedStraightRGBA(colors[4])
    let expected = SIMD4<Float>(
      Float(Double(start.x) + (Double(current.x) - Double(start.x)) * p),
      Float(Double(start.y) + (Double(current.y) - Double(start.y)) * p),
      Float(Double(start.z) + (Double(current.z) - Double(start.z)) * p),
      Float(Double(start.w) + (Double(current.w) - Double(start.w)) * p))
    XCTAssertEqual(transition.startLinearRGBA.x, expected.x, accuracy: 1e-6)
    XCTAssertEqual(transition.startLinearRGBA.y, expected.y, accuracy: 1e-6)
    XCTAssertEqual(transition.startLinearRGBA.z, expected.z, accuracy: 1e-6)
    XCTAssertEqual(transition.startLinearRGBA.w, expected.w, accuracy: 1e-6)
  }

  private func gray(_ v: UInt32) -> UInt32 {
    (v << 24) | (v << 16) | (v << 8) | 0xFF
  }

  func testFinelySampledSourceIsRenderedAuthoritatively() {
    // Codex-shimmer-like input: small color steps at ~75 ms cadence.
    var timestamp = 0.0
    var map: [SpinnerMotionCellKey: GlyphForegroundTransition] = [:]
    for step in 0..<6 {
      let foreground = gray(UInt32(0x80 + step * 8))
      map = detector.observe(
        observation(at: timestamp, cells: [cell(row: 0, col: 0, foreground: foreground)]))
      timestamp += 0.075
    }
    XCTAssertTrue(map.isEmpty)
    XCTAssertTrue(detector.diagnostics.detectorActive)
    XCTAssertTrue(detector.diagnostics.finelySampledBypass)
  }

  func testSparseSourceDoesNotEngageFinelySampledBypass() {
    let a = cell(row: 0, col: 0, foreground: 0xFF00_00FF)
    let b = cell(row: 0, col: 0, foreground: 0x0000_FFFF)
    let c = cell(row: 0, col: 0, foreground: 0x00FF_00FF)
    _ = detector.observe(observation(at: 0.00, cells: [a]))
    _ = detector.observe(observation(at: 0.25, cells: [b]))
    let map = detector.observe(observation(at: 0.50, cells: [c]))
    XCTAssertEqual(map.count, 1)
    XCTAssertFalse(detector.diagnostics.finelySampledBypass)
  }

  func testFinelySampledBypassHysteresis() {
    var timestamp = 0.0
    func step(_ v: UInt32, advance: Double) -> [SpinnerMotionCellKey:
      GlyphForegroundTransition]
    {
      let map = detector.observe(
        observation(at: timestamp, cells: [cell(row: 0, col: 0, foreground: gray(v))]))
      timestamp += advance
      return map
    }
    // Engage the bypass at 75 ms cadence.
    var map = step(0x80, advance: 0.075)
    map = step(0x88, advance: 0.075)
    map = step(0x90, advance: 0.075)
    XCTAssertTrue(map.isEmpty)
    XCTAssertTrue(detector.diagnostics.finelySampledBypass)
    // 110 ms gaps sit between the enter/exit thresholds: the bypass holds.
    map = step(0x98, advance: 0.11)
    map = step(0xA0, advance: 0.11)
    map = step(0xA8, advance: 0.11)
    XCTAssertTrue(map.isEmpty)
    XCTAssertTrue(detector.diagnostics.finelySampledBypass)
    // 130 ms gaps cross the exit threshold: interpolation resumes.
    _ = step(0xB0, advance: 0.13)
    _ = step(0xB8, advance: 0.13)
    map = step(0xC0, advance: 0.13)
    XCTAssertFalse(detector.diagnostics.finelySampledBypass)
    XCTAssertEqual(map.count, 1)
  }
}
