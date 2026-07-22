import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

private func waveFixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

/// Controller-level tests for the traveling-wave channel (M2 of
/// execplans/active/spinner-motion-traveling-wave.md): a cosine gray band
/// translating one cell per 75 ms step engages the wave estimator; the frame
/// then carries one `waveRegion` plus per-cell `foregroundWave` metadata,
/// and disengagement produces kind-3 teardown transitions from the
/// wave-displayed colors.
final class SpinnerMotionWaveControllerTests: XCTestCase {
  private var model: AppModel!
  private var session: Session!
  private var controller: TerminalSurfaceController!
  private var clock: Double = 0

  private static let step = 0.075
  private static let velocity = 1.0 / step

  override func setUpWithError() throws {
    try super.setUpWithError()
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    model = try AppModel(initialSize: size, sessionFactory: waveFixtureFactory)
    guard let tab = model.activeTab, let s = model.session(forTab: tab.id) else {
      XCTFail("missing fixture session")
      return
    }
    session = s
    controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 0)
    controller.outputStampClock = { self.clock }
    clock = 0
    writeBand(pos: 0)
    XCTAssertNotNil(makeFrame(), "seed frame must build")
  }

  /// Cosine band like a typical sweep spinner: base 128, peak 242,
  /// half-width 5 (mirrors SpinnerTravelingWaveTests).
  private func bandGray(_ dist: Double) -> Int {
    guard dist <= 5 else { return 128 }
    let t = 0.5 * (1 + cos(Double.pi * dist / 5))
    return Int((128.0 + (255 - 128) * 0.9 * t).rounded())
  }

  private func writeBand(pos: Double) {
    var sequence = "\u{1B}[1;1H"
    for col in 0...15 {
      let level = bandGray(abs(Double(col) - pos))
      sequence += "\u{1B}[38;2;\(level);\(level);\(level)m\u{25CF}"
    }
    session.write(Array(sequence.utf8))
  }

  private func makeFrame(spinnerEnabled: Bool = true) -> TerminalSurfaceFrame? {
    clock += Self.step
    return controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 160,
        viewportHeight: 64,
        reduceMotion: false,
        requireActiveSnapshot: true,
        forceFullDamage: true,
        surfaceWidth: 160,
        surfaceHeight: 64,
        surfaceScale: 1,
        spinnerMotionSmoothingEnabled: spinnerEnabled,
        effectiveRendererIsSlug: true))
  }

  /// Feed `steps` band generations (one-cell shift each) and return the last
  /// frame. Eight steps engage the estimator per SpinnerTravelingWaveTests.
  private func engageWave(steps: Int = 8) -> TerminalSurfaceFrame? {
    var frame: TerminalSurfaceFrame?
    for step in 1...steps {
      writeBand(pos: Double(step))
      frame = makeFrame()
    }
    return frame
  }

  private func waveRuns(
    in commands: [FrameCommand]
  ) -> [(col: Int, wave: GlyphForegroundWave)] {
    commands.compactMap { command in
      guard
        case .glyphRun(let origin, _, _, _, _, _, _, _, _, _, _, _, let wave) = command,
        let wave
      else { return nil }
      return (Int(origin.x / 8), wave)
    }
  }

  func testEngagedWavePublishesRegionAndPerCellMetadata() throws {
    let frame = try XCTUnwrap(engageWave())

    XCTAssertEqual(frame.spinnerMotionDiagnostics?.waveActive, true)
    let diagnostics = controller.spinnerMotionWaveDiagnostics()
    XCTAssertTrue(diagnostics.active)
    XCTAssertEqual(diagnostics.velocityCellsPerSecond ?? 0, Self.velocity, accuracy: 0.5)
    XCTAssertEqual(diagnostics.confidence ?? 0, 0.9, accuracy: 0.11)

    let regions = frame.commands.compactMap { command -> (Int, Double, Float)? in
      guard case .waveRegion(let colors, let anchor, let velocity) = command else { return nil }
      return (colors.count, anchor, velocity)
    }
    XCTAssertEqual(regions.count, 1, "exactly one wave region per frame")
    XCTAssertEqual(regions[0].2, Float(Self.velocity), accuracy: 0.5)

    // The region payload precedes every run that references it.
    let regionIndex = frame.commands.firstIndex(where: {
      if case .waveRegion = $0 { return true }
      return false
    })
    let firstWaveRunIndex = frame.commands.firstIndex(where: {
      if case .glyphRun(_, _, _, _, _, _, _, _, _, _, _, _, let wave) = $0 { return wave != nil }
      return false
    })
    XCTAssertNotNil(regionIndex)
    XCTAssertNotNil(firstWaveRunIndex)
    XCTAssertLessThan(regionIndex ?? 0, firstWaveRunIndex ?? 0)

    // One run per wave cell; cell indexes ascend with column. These runs
    // passed through stampFreshOutputTimestamps, which must preserve the
    // wave metadata.
    let runs = waveRuns(in: frame.commands).sorted { $0.col < $1.col }
    XCTAssertGreaterThanOrEqual(runs.count, 6)
    for (index, run) in runs.enumerated() {
      XCTAssertEqual(run.wave.regionIndex, 0)
      XCTAssertEqual(run.wave.cellIndexInRegion, UInt32(index))
      XCTAssertEqual(run.wave.durationSeconds, 2 * Self.step, accuracy: 0.02)
    }
  }

  func testWaveTimeoutPublishesTeardownTransitions() throws {
    _ = try XCTUnwrap(engageWave())
    // No new generation for longer than the detector timeout
    // (min(2 * 0.075, 0.8) = 0.15 s): the wave disengages and the previously
    // wave-sampled cells get ordinary transitions instead of popping.
    clock += 0.2
    let frame = try XCTUnwrap(makeFrame())

    for command in frame.commands {
      if case .waveRegion = command {
        XCTFail("timed-out wave must not publish a region")
      }
    }
    XCTAssertFalse(controller.spinnerMotionWaveDiagnostics().active)

    let transitions = frame.commands.compactMap { command -> GlyphForegroundTransition? in
      guard
        case .glyphRun(_, _, _, _, _, _, _, _, _, _, _, let transition, _) = command,
        let transition
      else { return nil }
      return transition
    }
    XCTAssertGreaterThanOrEqual(transitions.count, 6)
    for transition in transitions {
      XCTAssertEqual(transition.startTimestampSeconds, clock, accuracy: 1e-9)
      XCTAssertEqual(transition.durationSeconds, 2 * Self.step, accuracy: 0.02)
    }
  }

  func testEligibilityLossClearsWaveWithoutTeardown() throws {
    _ = try XCTUnwrap(engageWave())
    let frame = try XCTUnwrap(makeFrame(spinnerEnabled: false))
    for command in frame.commands {
      if case .waveRegion = command {
        XCTFail("ineligible frame must not publish a region")
      }
      if case .glyphRun(_, _, _, _, _, _, _, _, _, _, _, let transition, let wave) = command {
        XCTAssertNil(wave)
        XCTAssertNil(transition, "eligibility loss clears without teardown")
      }
    }
    XCTAssertFalse(controller.spinnerMotionWaveDiagnostics().active)
  }
}
