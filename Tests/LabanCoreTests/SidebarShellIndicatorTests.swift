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

  func testAtPromptShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .atPrompt, exit: 1)))
  }

  func testIdleShowsNothing() {
    XCTAssertNil(SidebarProducer.shellPhaseIndicatorColor(metadata(phase: .idle, exit: nil)))
  }
}
