import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Milestone 1 of the OSC 133 shell-integration ExecPlan
/// (`execplans/active/osc133-shell-integration.md`): the C scanner in
/// `Sources/LabanTerminalCore/osc133.c` turns raw OSC 133 bytes into a
/// `ShellIntegrationState` phase + exit code, observable through a fixture
/// session with no real shell.
final class ShellIntegrationTests: XCTestCase {
  private var size: LabanTerminalSize {
    var s = LabanTerminalSize()
    s.rows = 24
    s.cols = 80
    return s
  }

  // MARK: - Reducer (pure, no session)

  func testReducerFullCommandCycle() {
    var state = ShellIntegrationState()
    XCTAssertEqual(state.phase, .idle)
    state.apply(.promptStart)
    XCTAssertEqual(state.phase, .atPrompt)
    state.apply(.promptEnd)
    XCTAssertEqual(state.phase, .atPrompt)
    state.apply(.commandStart)
    XCTAssertEqual(state.phase, .running)
    state.apply(.commandEnd(exitCode: 0))
    XCTAssertEqual(state.phase, .finished)
    XCTAssertEqual(state.lastExitCode, 0)
  }

  func testReducerNonZeroExit() {
    var state = ShellIntegrationState()
    state.apply(.commandEnd(exitCode: 1))
    XCTAssertEqual(state.lastExitCode, 1)
  }

  func testReducerMissingExitCodePreservesPrior() {
    var state = ShellIntegrationState()
    state.apply(.commandEnd(exitCode: 42))
    state.apply(.commandStart)
    state.apply(.commandEnd(exitCode: nil))
    XCTAssertEqual(state.phase, .finished)
    // A 'D' with no numeric arg means "finished, status unknown" and must
    // not clobber the last real code.
    XCTAssertEqual(state.lastExitCode, 42)
  }

  // MARK: - Scanner (bytes through a fixture session)

  func testScannerFullCycleEndsFinishedExitZero() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    session.feedOutput(Array("prompt$ ".utf8))
    session.feedOutput(Array("\u{1B}]133;B\u{07}".utf8))
    session.feedOutput(Array("ls".utf8))
    session.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    session.feedOutput(Array("output\n".utf8))
    session.feedOutput(Array("\u{1B}]133;D;0\u{07}".utf8))
    let state = session.shellIntegrationState()
    XCTAssertEqual(state.phase, .finished)
    XCTAssertEqual(state.lastExitCode, 0)
  }

  func testScannerNonZeroExit() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;D;1\u{07}".utf8))
    XCTAssertEqual(session.shellIntegrationState().lastExitCode, 1)
  }

  func testScannerMarkerSplitAcrossReads() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // The PTY delivers bytes in arbitrary chunks; a marker may straddle two
    // scanner calls. The scanner must buffer partial state across calls.
    session.feedOutput(Array("\u{1B}]13".utf8))
    session.feedOutput(Array("3;C".utf8))
    session.feedOutput(Array("\u{07}".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .running)
  }

  func testScannerStringTerminatorVariant() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // ST = ESC \ instead of BEL.
    session.feedOutput(Array("\u{1B}]133;A\u{1B}\\".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .atPrompt)
  }

  func testUnrelatedOSCDoesNotChangePhase() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // A window-title set (OSC 0) must leave the shell phase at idle.
    session.feedOutput(Array("\u{1B}]0;hello\u{07}".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .idle)
    XCTAssertNil(session.shellIntegrationState().lastExitCode)
  }

  func testMarkerInsideDCSStringIsIgnored() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // A DCS string (ESC P ... ST) whose payload literally contains a 133;C
    // byte run must NOT be parsed as a real marker.
    session.feedOutput(Array("\u{1B}P\u{1B}]133;C\u{07}data\u{1B}\\".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .idle)
  }

  func testBackToBackOSCAfterBareEscStillParses() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // A 133;A whose terminator is a bare ESC starting a new OSC (no ST):
    // the new OSC's own ESC must not be swallowed. The trailing well-formed
    // 133;C must still be recognized.
    session.feedOutput(Array("\u{1B}]133;A\u{1B}]133;C\u{07}".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .running)
  }

  func testHugeExitCodeDoesNotOverflow() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.feedOutput(Array("\u{1B}]133;D;999999999999999\u{07}".utf8))
    // No crash/UB; an exit code is recorded (clamped) and phase advances.
    XCTAssertEqual(session.shellIntegrationState().phase, .finished)
    XCTAssertNotNil(session.shellIntegrationState().lastExitCode)
  }

  func testUnknownActionIgnored() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // 'L' (fresh line) is a valid OSC 133 action Laban does not consume; it
    // must not move the phase off idle.
    session.feedOutput(Array("\u{1B}]133;L\u{07}".utf8))
    XCTAssertEqual(session.shellIntegrationState().phase, .idle)
  }

  /// Regression for the indicator-never-shows-red bug: real shells emit
  /// `D;<exit>` immediately followed by `A` in one precmd, so the *settled*
  /// phase after a failed command is `.atPrompt`, not `.finished`, while the
  /// exit code lingers. Feed that exact stream and confirm the state the UI
  /// reads at rest still drives a red indicator.
  func testFailedCommandLeavesRedIndicatorAtPrompt() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    // prompt, run, fail, next prompt — as the zsh/bash/fish hooks emit it.
    session.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;D;1\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))

    let state = session.shellIntegrationState()
    XCTAssertEqual(state.phase, .atPrompt, "settled phase is atPrompt, not finished")
    XCTAssertEqual(state.lastExitCode, 1)

    // The indicator must be red for this at-rest state.
    let meta = TabTitleMetadata(
      displayTitle: "t", titleSource: .fallback,
      shellPhase: state.phase, lastCommandExitCode: state.lastExitCode)
    XCTAssertEqual(SidebarProducer.shellPhaseIndicatorColor(meta), Theme.current.red)
  }

  func testObserverHandlerReceivesReducedState() throws {
    let session = try Session.fixture(size: size)
    defer { session.close() }
    var observed: [ShellIntegrationPhase] = []
    session.onShellIntegration = { observed.append($0.phase) }
    session.feedOutput(Array("\u{1B}]133;A\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;C\u{07}".utf8))
    session.feedOutput(Array("\u{1B}]133;D;0\u{07}".utf8))
    XCTAssertEqual(observed, [.atPrompt, .running, .finished])
  }
}
