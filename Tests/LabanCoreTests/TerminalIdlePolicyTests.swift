import XCTest

@testable import LabanCore

final class TerminalIdlePolicyTests: XCTestCase {
  func testRunsWhenVisible() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser: true, scrollAnimating: false))
  }

  func testPausesWhenNotVisibleAndIdle() {
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser: false, scrollAnimating: false))
  }

  func testKeepsRunningForInFlightScrollEvenWhenNotVisible() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser: false, scrollAnimating: true))
  }

  func testRunsWhenVisibleAndScrolling() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(windowVisibleToUser: true, scrollAnimating: true))
  }

  func testVisibleIdlePrefersIdleFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }

  func testScrollPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: true,
        attentionAnimating: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testAttentionAnimationPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }
}
