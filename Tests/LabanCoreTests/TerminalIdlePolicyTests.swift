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
        attentionAnimating: false,
        terminalOutputActive: false),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }

  func testScrollPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: true,
        attentionAnimating: false,
        terminalOutputActive: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testAttentionAnimationPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testVisibleTerminalOutputPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testHiddenTerminalOutputKeepsIdlePreference() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: false,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }

  // MARK: - Full park (ADR 0018): the link stops on a quiescent focused window

  func testParksWhenVisibleQuiescentAndFloorOff() {
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false))
  }

  func testIdleFloorKeepsLinkRunningWhenVisibleAndQuiescent() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: true))
  }

  func testIdleFloorDoesNotRunWhenNotVisible() {
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: false,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: true))
  }

  func testCursorBlinkKeepsLinkRunningWhenVisible() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: true,
        idleFloorEnabled: false))
  }

  func testAttentionKeepsLinkRunningWhenFloorOff() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false))
  }

  func testOutputHoldKeepsLinkRunningWhenFloorOff() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true,
        cursorBlinkActive: false,
        idleFloorEnabled: false))
  }

  func testScrollOverridesParkEvenWhenNotVisible() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: false,
        scrollAnimating: true,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false))
  }

  func testHiddenWindowParksDespiteOutputAndBlink() {
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: false,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true,
        cursorBlinkActive: true,
        idleFloorEnabled: true))
  }

  // MARK: - Full-park rate ladder

  func testBlinkOnlyPrefersIdleFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: true,
        idleFloorEnabled: false),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }

  func testFloorOnlyPrefersIdleFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: true),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }

  func testOutputPrefersActiveFrameRateUnderFullParkPolicy() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true,
        cursorBlinkActive: false,
        idleFloorEnabled: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testScrollPrefersActiveFrameRateUnderFullParkPolicy() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: true,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testParkedStatePrefersIdleFrameRateAsDontCare() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }
}
