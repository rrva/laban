import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

private func makeModel(rows: Int32 = 4, cols: Int32 = 20) throws -> AppModel {
  var size = LabanTerminalSize()
  size.rows = rows
  size.cols = cols
  return try AppModel(initialSize: size, sessionFactory: fixtureFactory)
}

private func colorCode(for foreground: UInt32) -> String {
  switch foreground {
  case 0xFF00_00FF: return "31"
  case 0x0000_FFFF: return "34"
  case 0x00FF_00FF: return "32"
  case 0xFFFF_00FF: return "33"
  default: return "37"
  }
}

private func writeColoredDiamond(_ session: Session, foreground: UInt32, overwrite: Bool) {
  var sequence = ""
  if overwrite { sequence += "\r" }
  sequence += "\u{001B}[\(colorCode(for: foreground))m◆\u{001B}[0m"
  session.write(Array(sequence.utf8))
}

final class SpinnerMotionRendererGateTests: XCTestCase {
  private var model: AppModel!
  private var session: Session!
  private var controller: TerminalSurfaceController!
  private var clock: Double = 0

  override func setUpWithError() throws {
    try super.setUpWithError()
    model = try makeModel()
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
    // Seed the first generation with a red diamond, observed while eligible.
    clock = 0
    writeColoredDiamond(session, foreground: 0xFF00_00FF, overwrite: false)
    let seeded = makeFrame(spinnerEnabled: true, rendererIsSlug: true, reduceMotion: false)
    XCTAssertNotNil(seeded, "seed frame must build")
  }

  private func makeFrame(
    spinnerEnabled: Bool,
    rendererIsSlug: Bool,
    reduceMotion: Bool
  ) -> TerminalSurfaceFrame? {
    clock += 0.25
    return controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 160,
        viewportHeight: 64,
        reduceMotion: reduceMotion,
        requireActiveSnapshot: true,
        forceFullDamage: true,
        surfaceWidth: 160,
        surfaceHeight: 64,
        surfaceScale: 1,
        spinnerMotionSmoothingEnabled: spinnerEnabled,
        effectiveRendererIsSlug: rendererIsSlug))
  }

  private func runTransitions(spinnerEnabled: Bool, rendererIsSlug: Bool, reduceMotion: Bool)
    -> [GlyphForegroundTransition]
  {
    // Three color generations after the seed. The seed frame does not itself
    // qualify (the whole grid is newly visible), so it only sets the baseline.
    // Blue and green build the qualifying run; the third (yellow) creates the
    // first active transition.
    writeColoredDiamond(session, foreground: 0x0000_FFFF, overwrite: true)
    let frame2 = makeFrame(
      spinnerEnabled: spinnerEnabled, rendererIsSlug: rendererIsSlug, reduceMotion: reduceMotion)

    writeColoredDiamond(session, foreground: 0x00FF_00FF, overwrite: true)
    let frame3 = makeFrame(
      spinnerEnabled: spinnerEnabled, rendererIsSlug: rendererIsSlug, reduceMotion: reduceMotion)

    writeColoredDiamond(session, foreground: 0xFFFF_00FF, overwrite: true)
    let frame4 = makeFrame(
      spinnerEnabled: spinnerEnabled, rendererIsSlug: rendererIsSlug, reduceMotion: reduceMotion)

    XCTAssertNotNil(frame2, "frame 2 must build")
    XCTAssertNotNil(frame3, "frame 3 must build")
    XCTAssertNotNil(frame4, "frame 4 must build")
    let commands = frame4?.commands ?? []
    return commands.compactMap { command -> GlyphForegroundTransition? in
      if case .glyphRun(_, _, _, _, _, _, _, _, _, _, _, let transition, _) = command {
        return transition
      }
      return nil
    }
  }

  func testEligibleSlugEmitsForegroundTransition() {
    let transitions = runTransitions(
      spinnerEnabled: true, rendererIsSlug: true, reduceMotion: false)
    XCTAssertFalse(transitions.isEmpty, "Slug + enabled + no Reduce Motion must emit transitions")
    XCTAssertEqual(transitions.count, 1, "a single isolated spinner cell should produce one run")
  }

  func testNonSlugDropsTransitions() {
    let transitions = runTransitions(
      spinnerEnabled: true, rendererIsSlug: false, reduceMotion: false)
    XCTAssertTrue(transitions.isEmpty, "non-Slug renderer must not emit transitions")
  }

  func testReduceMotionDropsTransitions() {
    let transitions = runTransitions(spinnerEnabled: true, rendererIsSlug: true, reduceMotion: true)
    XCTAssertTrue(transitions.isEmpty, "Reduce Motion must disable spinner transitions")
  }

  func testDisabledSettingDropsTransitions() {
    let transitions = runTransitions(
      spinnerEnabled: false, rendererIsSlug: true, reduceMotion: false)
    XCTAssertTrue(transitions.isEmpty, "disabled setting must not emit transitions")
  }
}
