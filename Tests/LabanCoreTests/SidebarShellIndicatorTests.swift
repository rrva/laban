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

  func testRunningShowsBlue() {
    let color = SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .running, exit: nil))
    XCTAssertEqual(color, Theme.current.blue)
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

  /// Re-running a command after a failure shows blue (running), not a stale
  /// red — the running check wins.
  func testRunningAfterFailureShowsBlue() {
    let color = SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .running, exit: 1))
    XCTAssertEqual(color, Theme.current.blue)
  }

  func testIdleShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .idle, exit: nil)))
  }
}
