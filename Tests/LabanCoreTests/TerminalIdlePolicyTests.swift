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

  func testAttentionAnimationPrefersAnimationBudgetFrameRate() {
    // Milestone 4: a breathing sidebar dot does not justify 120 Hz frame
    // production — attention-only frames run at the 30 fps animation budget.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false),
      TerminalIdlePolicy.animationDisplayLinkFramesPerSecond)
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

  func testAttentionOnlyPrefersAnimationBudgetUnderFullParkPolicy() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false),
      TerminalIdlePolicy.animationDisplayLinkFramesPerSecond)
  }

  func testAttentionWithActiveOutputPrefersActiveFrameRate() {
    // Live output outranks the decorative budget: the stream keeps 120.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: true,
        cursorBlinkActive: false,
        idleFloorEnabled: false),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testAttentionWithScrollPrefersActiveFrameRate() {
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: true,
        attentionAnimating: true,
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

  // MARK: - Glyph-effect animation channel (per-glyph-animation-channel M0)

  func testGlyphEffectKeepsLinkRunningWhenFloorOff() {
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true))
  }

  func testGlyphEffectDoesNotRunWhenNotVisible() {
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: false,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true))
  }

  func testGlyphEffectOnlyPrefersActiveFrameRate() {
    // A ~130 ms keystroke-impulse spring at the 30 fps decorative budget
    // would get ~4 frames — the frame starvation that made the old ink-bloom
    // read as flicker. Live effects ride the active (panel) rate; they park
    // the moment they decay, so the energy cost stays bounded.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testGlyphEffectWithAttentionPrefersActiveFrameRate() {
    // Effect + attention pulse: the effect's panel-rate need outranks the
    // pulse's 30 fps decorative budget.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testAttentionOnlyStillPrefersAnimationBudgetFrameRate() {
    // The slow attention breath (1.5 s period) keeps the 30 fps budget.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: true,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: false),
      TerminalIdlePolicy.animationDisplayLinkFramesPerSecond)
  }

  func testGlyphEffectWithActiveOutputPrefersActiveFrameRate() {
    // Live output outranks the decorative budget: the stream keeps 120.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: true,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true),
      TerminalIdlePolicy.activeDisplayLinkFramesPerSecond)
  }

  func testGlyphEffectParkWhenDecayEnds() {
    // The live→settled edge: once the last effect decays, the link must park
    // (floor off, no other activity). Without this, a sticky
    // `glyphEffectAnimatingUntil` would keep the active frame rate alive.
    XCTAssertTrue(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: true))
    XCTAssertFalse(
      TerminalIdlePolicy.displayLinkShouldRun(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false,
        cursorBlinkActive: false,
        idleFloorEnabled: false,
        glyphEffectAnimating: false))
  }

  func testShimsKeepGlyphEffectOff() {
    // The compatibility shims model the pre-channel world: no glyph effects.
    XCTAssertEqual(
      TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
        windowVisibleToUser: true,
        scrollAnimating: false,
        attentionAnimating: false,
        terminalOutputActive: false),
      TerminalIdlePolicy.idleDisplayLinkFramesPerSecond)
  }
}
