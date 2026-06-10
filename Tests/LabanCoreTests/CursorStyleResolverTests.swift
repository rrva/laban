import LabanTerminalCore
import XCTest

@testable import LabanCore

final class CursorStyleResolverTests: XCTestCase {

  // MARK: - Helpers

  private func resolve(
    userStyle: CursorSettings.Style = .block,
    userBlink: Bool = false,
    snapStyle: Int32 = 0,
    snapBlink: Bool = false,
    styleExplicit: Int32 = 0,
    blinkExplicit: Int32 = 0
  ) -> (style: Int32, blinking: Bool) {
    CursorStyleResolver.resolve(
      userStyle: userStyle,
      userBlinkEnabled: userBlink,
      snapshotStyle: snapStyle,
      snapshotBlinking: snapBlink,
      styleExplicit: styleExplicit,
      blinkExplicit: blinkExplicit
    )
  }

  // MARK: - User default applies when no override

  func testUserDefaultAppliesWhenNoOverride_StyleBlock() {
    let result = resolve(userStyle: .block, snapStyle: 1, styleExplicit: 0)
    XCTAssertEqual(
      result.style, CursorSettings.Style.block.labanStyleValue,
      "user block style wins when no DECSCUSR override is set")
  }

  func testUserDefaultAppliesWhenNoOverride_StyleBar() {
    let result = resolve(userStyle: .bar, snapStyle: 0, styleExplicit: 0)
    XCTAssertEqual(
      result.style, CursorSettings.Style.bar.labanStyleValue,
      "user bar style wins when no DECSCUSR override is set")
  }

  func testUserDefaultAppliesWhenNoOverride_StyleUnderline() {
    let result = resolve(userStyle: .underline, snapStyle: 0, styleExplicit: 0)
    XCTAssertEqual(
      result.style, CursorSettings.Style.underline.labanStyleValue,
      "user underline style wins when no DECSCUSR override is set")
  }

  func testUserDefaultAppliesWhenNoOverride_BlinkOff() {
    let result = resolve(userBlink: false, snapBlink: true, blinkExplicit: 0)
    XCTAssertFalse(
      result.blinking,
      "user blink-off wins when no DECSCUSR/mode-12 override is set")
  }

  func testUserDefaultAppliesWhenNoOverride_BlinkOn() {
    let result = resolve(userBlink: true, snapBlink: false, blinkExplicit: 0)
    XCTAssertTrue(
      result.blinking,
      "user blink-on wins when no DECSCUSR/mode-12 override is set")
  }

  // MARK: - Explicit override wins

  func testExplicitOverrideWins_StyleFromSnapshot() {
    // Program sent DECSCUSR 5 (blinking bar) -> snapshot reports bar
    let result = resolve(
      userStyle: .block,
      snapStyle: Int32(LABAN_CURSOR_STYLE_BAR),
      styleExplicit: 1
    )
    XCTAssertEqual(
      result.style, Int32(LABAN_CURSOR_STYLE_BAR),
      "snapshot bar style wins when styleExplicit is set")
  }

  func testExplicitOverrideWins_BlinkFromSnapshot() {
    let result = resolve(
      userBlink: false,
      snapBlink: true,
      blinkExplicit: 1
    )
    XCTAssertTrue(
      result.blinking,
      "snapshot blinking wins when blinkExplicit is set")
  }

  func testExplicitOverrideWins_StyleAndBlinkIndependently() {
    // styleExplicit = 1, blinkExplicit = 0: style from snapshot, blink from user
    let result = resolve(
      userStyle: .block,
      userBlink: false,
      snapStyle: Int32(LABAN_CURSOR_STYLE_UNDERLINE),
      snapBlink: true,
      styleExplicit: 1,
      blinkExplicit: 0
    )
    XCTAssertEqual(result.style, Int32(LABAN_CURSOR_STYLE_UNDERLINE))
    XCTAssertFalse(
      result.blinking,
      "when only styleExplicit is set, blink falls back to user setting")
  }

  func testExplicitOverrideWins_BlinkOnlyFromSnapshot() {
    // blinkExplicit = 1, styleExplicit = 0: blink from snapshot, style from user
    let result = resolve(
      userStyle: .underline,
      userBlink: false,
      snapStyle: Int32(LABAN_CURSOR_STYLE_BLOCK),
      snapBlink: true,
      styleExplicit: 0,
      blinkExplicit: 1
    )
    XCTAssertEqual(
      result.style, CursorSettings.Style.underline.labanStyleValue,
      "when only blinkExplicit is set, style falls back to user setting")
    XCTAssertTrue(
      result.blinking,
      "snapshot blink wins when blinkExplicit is set")
  }

  // MARK: - Both explicit flags set

  func testBothExplicitFlags_BothFromSnapshot() {
    let result = resolve(
      userStyle: .block,
      userBlink: false,
      snapStyle: Int32(LABAN_CURSOR_STYLE_BAR),
      snapBlink: true,
      styleExplicit: 1,
      blinkExplicit: 1
    )
    XCTAssertEqual(result.style, Int32(LABAN_CURSOR_STYLE_BAR))
    XCTAssertTrue(result.blinking)
  }

  // MARK: - DECSCUSR 0 / clear scenario

  func testAfterClear_BothFallBackToUser() {
    // After DECSCUSR 0: both explicit flags are cleared, user prefs apply
    let result = resolve(
      userStyle: .bar,
      userBlink: true,
      snapStyle: Int32(LABAN_CURSOR_STYLE_BLOCK),
      snapBlink: false,
      styleExplicit: 0,
      blinkExplicit: 0
    )
    XCTAssertEqual(result.style, CursorSettings.Style.bar.labanStyleValue)
    XCTAssertTrue(result.blinking)
  }
}
