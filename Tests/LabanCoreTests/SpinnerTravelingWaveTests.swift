import XCTest

@testable import LabanCore
@testable import LabanRenderer

/// Tests for the traveling-wave estimator inside `SpinnerMotionDetector`.
/// Synthetic single-row color fields mimic a sweep spinner: a cosine band
/// that translates one cell per step at ~75 ms cadence. Detection must be
/// semantic (translation consistency), never text- or process-based.
final class SpinnerTravelingWaveTests: XCTestCase {
  private var detector: SpinnerMotionDetector!

  override func setUp() {
    super.setUp()
    detector = SpinnerMotionDetector()
  }

  private func cell(row: Int, col: Int, foreground: UInt32) -> SpinnerMotionCellState {
    SpinnerMotionCellState(
      key: SpinnerMotionCellKey(row: row, col: col),
      text: "◆",
      displayWidth: 1,
      foreground: foreground,
      background: 0x0000_00FF,
      attributes: [],
      underlineStyle: .none,
      underlineColor: nil,
      hyperlink: nil,
      wide: 0)
  }

  private func observation(at timestamp: Double, cells: [SpinnerMotionCellState])
    -> SpinnerMotionObservation
  {
    var map: [SpinnerMotionCellKey: SpinnerMotionCellState] = [:]
    for c in cells { map[c.key] = c }
    return SpinnerMotionObservation(
      timestamp: timestamp, rows: 2, cols: 40, cells: map, mouseTracking: false)
  }

  private func gray(_ v: UInt32) -> UInt32 {
    (v << 24) | (v << 16) | (v << 8) | 0xFF
  }

  /// Cosine band like a typical sweep spinner: base 128, peak 242, half-width 5.
  private func bandGray(_ dist: Double) -> UInt32 {
    guard dist <= 5 else { return 128 }
    let t = 0.5 * (1 + cos(Double.pi * dist / 5))
    return UInt32((128.0 + (255 - 128) * 0.9 * t).rounded())
  }

  private func waveCells(pos: Double, cols: ClosedRange<Int>) -> [SpinnerMotionCellState] {
    cols.map { cell(row: 0, col: $0, foreground: gray(bandGray(abs(Double($0) - pos)))) }
  }

  private static let step = 0.075
  private static let velocity = 1.0 / step

  /// Feed `count` wave observations starting at t=0, pos=0, one cell per step.
  @discardableResult
  private func feedWave(
    count: Int, startTime: Double = 0, startPos: Double = 0, direction: Double = 1
  ) -> (time: Double, pos: Double) {
    var t = startTime
    var pos = startPos
    for _ in 0..<count {
      _ = detector.observe(observation(at: t, cells: waveCells(pos: pos, cols: 0...15)))
      t += Self.step
      pos += direction
    }
    return (t, pos)
  }

  func testTravelingWaveEngagesWithEstimatedVelocity() {
    feedWave(count: 8)
    let wave = detector.lastWave
    XCTAssertNotNil(wave)
    XCTAssertEqual(wave!.velocityCellsPerSecond, Self.velocity, accuracy: 0.01)
    XCTAssertEqual(wave!.row, 0)
    XCTAssertTrue(detector.diagnostics.waveActive)
    XCTAssertEqual(
      detector.diagnostics.waveVelocityCellsPerSecond ?? 0, Self.velocity, accuracy: 0.01)
    XCTAssertEqual(detector.diagnostics.waveConfidence ?? 0, 1.0, accuracy: 0.001)
  }

  func testReversedWaveHasNegativeVelocity() {
    feedWave(count: 8, startPos: 14, direction: -1)
    XCTAssertEqual(detector.lastWave?.velocityCellsPerSecond ?? 0, -Self.velocity, accuracy: 0.01)
  }

  func testUniformPulseDoesNotEngage() {
    // Every cell changes to the same color each step: motion without
    // translation must not read as a wave.
    var t = 0.0
    for level in stride(from: 128, through: 240, by: 16) {
      let cells = (0...15).map { cell(row: 0, col: $0, foreground: gray(UInt32(level))) }
      _ = detector.observe(observation(at: t, cells: cells))
      t += Self.step
    }
    XCTAssertNil(detector.lastWave)
    XCTAssertFalse(detector.diagnostics.waveActive)
  }

  func testUncorrelatedColorsDoNotEngage() {
    var t = 0.0
    var state: UInt32 = 0x1234_5678
    for _ in 0..<10 {
      let cells = (0...15).map { col -> SpinnerMotionCellState in
        state = state &* 1_664_525 &+ 1_013_904_223
        let level = 128 + (state >> 24) % 115
        return cell(row: 0, col: col, foreground: gray(level))
      }
      _ = detector.observe(observation(at: t, cells: cells))
      t += Self.step
    }
    XCTAssertNil(detector.lastWave)
  }

  func testWaveDisengagesAfterIdleGap() {
    var (t, pos) = feedWave(count: 8)
    XCTAssertNotNil(detector.lastWave)
    // A 1 s silence breaks the cadence; the wave must drop immediately on the
    // next observation instead of extrapolating a stale field.
    t += 1.0
    _ = detector.observe(observation(at: t, cells: waveCells(pos: pos, cols: 0...15)))
    XCTAssertNil(detector.lastWave)
    XCTAssertFalse(detector.diagnostics.waveActive)
  }

  func testForeignSingleCellRoundsDoNotDisengageWave() {
    var (t, pos) = feedWave(count: 6)
    XCTAssertNotNil(detector.lastWave)
    // A foreign cell near the region changes alone (region too narrow to feed
    // the estimator); the wave state must stay sticky.
    _ = detector.observe(
      observation(
        at: t,
        cells: waveCells(pos: pos, cols: 0...15) + [
          cell(row: 0, col: 14, foreground: gray(250))
        ]))
    XCTAssertNotNil(detector.lastWave)
    t += Self.step
    // The next wave observation still correlates; the velocity estimate
    // survives the skipped round.
    pos += 1
    _ = detector.observe(observation(at: t, cells: waveCells(pos: pos, cols: 0...15)))
    XCTAssertNotNil(detector.lastWave)
    XCTAssertEqual(detector.lastWave!.velocityCellsPerSecond, Self.velocity, accuracy: 0.01)
  }

  func testTwoCorruptedRoundsDisengageWave() {
    var (t, _) = feedWave(count: 6)
    XCTAssertNotNil(detector.lastWave)
    var state: UInt32 = 0xABCD_EF01
    for _ in 0..<2 {
      let cells = (0...15).map { col -> SpinnerMotionCellState in
        state = state &* 1_664_525 &+ 1_013_904_223
        let level = 128 + (state >> 24) % 115
        return cell(row: 0, col: col, foreground: gray(level))
      }
      _ = detector.observe(observation(at: t, cells: cells))
      t += Self.step
    }
    XCTAssertNil(detector.lastWave)
    XCTAssertFalse(detector.diagnostics.waveActive)
  }

  func testResetClearsWaveState() {
    feedWave(count: 6)
    XCTAssertNotNil(detector.lastWave)
    detector.reset()
    XCTAssertNil(detector.lastWave)
    XCTAssertFalse(detector.diagnostics.waveActive)
  }

  func testWaveSampleBilinearAndClamped() {
    // Field: linear ramp 0,1,2,3 in the red channel; rightward velocity
    // 10 cells/s anchored at t=1.0.
    let colors = (0..<4).map { SIMD4<Float>(Float($0), 0, 0, 1) }
    let wave = SpinnerWaveState(
      row: 0, minCol: 2, colors: colors, anchorTimestamp: 1.0,
      velocityCellsPerSecond: 10, confidence: 1)
    // At the anchor, samples equal the field.
    XCTAssertEqual(wave.sample(col: 3, at: 1.0).x, 1, accuracy: 1e-6)
    // Half a cell of travel: col 3 now shows the midpoint of field 0 and 1.
    XCTAssertEqual(wave.sample(col: 3, at: 1.05).x, 0.5, accuracy: 1e-6)
    // The same travel makes col 4 show the midpoint of field 1 and 2.
    XCTAssertEqual(wave.sample(col: 4, at: 1.05).x, 1.5, accuracy: 1e-6)
    // Beyond the field edges the sample clamps.
    XCTAssertEqual(wave.sample(col: 2, at: 2.0).x, 0, accuracy: 1e-6)
    XCTAssertEqual(wave.sample(col: 5, at: 0.0).x, 3, accuracy: 1e-6)
  }

  func testCapturedStyleStaircaseEngagesAndSamplesBetweenLevels() {
    // Genericized replay of a real sweep: the same 7-level staircase with the
    // irregular per-step intervals seen in captures (65-104 ms).
    let intervals = [0.065, 0.071, 0.096, 0.065, 0.104, 0.063, 0.066, 0.070, 0.071, 0.096]
    var t = 0.0
    var pos = 0.0
    for dt in intervals {
      _ = detector.observe(observation(at: t, cells: waveCells(pos: pos, cols: 0...15)))
      t += dt
      pos += 1
    }
    let wave = detector.lastWave
    XCTAssertNotNil(wave)
    // Velocity is the median of the last three per-vote samples; votes use
    // the intervals between successive observations (one fewer than steps).
    let expectedSamples = intervals.dropLast().suffix(3).map { 1.0 / $0 }.sorted()
    XCTAssertEqual(wave!.velocityCellsPerSecond, expectedSamples[1], accuracy: 0.01)
    // A mid-interval sample between two cells must lie strictly between the
    // two adjacent field levels (the sub-cell motion the source never emits).
    let anchorCol = wave!.minCol + 1
    let halfStep = 0.5 / wave!.velocityCellsPerSecond
    let mid = wave!.sample(col: anchorCol, at: wave!.anchorTimestamp + halfStep).x
    let lower = wave!.colors[anchorCol - wave!.minCol - 1].x
    let here = wave!.colors[anchorCol - wave!.minCol].x
    XCTAssertGreaterThan(mid, min(lower, here))
    XCTAssertLessThan(mid, max(lower, here))
  }
}
