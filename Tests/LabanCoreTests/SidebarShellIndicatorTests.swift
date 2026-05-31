import LabanRenderer
import XCTest

@testable import LabanCore

/// Milestone 4: the sidebar status indicator driven by OSC 133 phase.
final class SidebarShellIndicatorTests: XCTestCase {
  private func metadata(
    phase: ShellIntegrationPhase, exit: Int?
  ) -> TabTitleMetadata {
    TabTitleMetadata(
      displayTitle: "t", titleSource: .fallback, shellPhase: phase, lastCommandExitCode: exit)
  }

  func testFinishedNonZeroShowsRed() {
    let color = SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .finished, exit: 1))
    XCTAssertEqual(color, Theme.current.red)
  }

  /// A merely running command no longer shows a dot. OSC 133 pins `.running`
  /// for a foreground program's whole life, so a running indicator would light
  /// a permanent dot on every agent/REPL/editor tab — an always-on signal that
  /// carries no information.
  func testRunningShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .running, exit: nil)))
  }

  func testFinishedZeroShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .finished, exit: 0)))
  }

  /// The real settled state after a failed command: shells emit `D` then `A`
  /// in one precmd, so the phase is `.atPrompt` (not `.finished`) while the
  /// non-zero exit code lingers. The red dot must show here — this is the
  /// actual at-rest case the user sees.
  func testAtPromptWithFailedCommandShowsRed() {
    let color = SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .atPrompt, exit: 1))
    XCTAssertEqual(color, Theme.current.red)
  }

  func testAtPromptAfterSuccessShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .atPrompt, exit: 0)))
  }

  /// With no running-state indicator, a non-zero last exit still shows red
  /// even while a follow-up command runs — the exit code lingers until the
  /// next command finishes, and surfacing the last failure is the useful cue.
  func testRunningWithPriorFailedExitShowsRed() {
    let color = SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .running, exit: 1))
    XCTAssertEqual(color, Theme.current.red)
  }

  func testIdleShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .idle, exit: nil)))
  }
}
