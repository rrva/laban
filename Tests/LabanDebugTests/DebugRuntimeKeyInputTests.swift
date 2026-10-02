import LabanCore
import XCTest

@testable import LabanDebug

final class DebugRuntimeKeyInputTests: XCTestCase {
  func testKeyNamesMapToTerminalKeys() {
    XCTAssertEqual(DebugRuntimeKeyInput.key(fromName: "enter"), .enter)
    XCTAssertEqual(DebugRuntimeKeyInput.key(fromName: "ArrowLeft"), .arrowLeft)
    XCTAssertEqual(DebugRuntimeKeyInput.key(fromName: "]"), .bracketRight)
    XCTAssertEqual(DebugRuntimeKeyInput.key(fromName: "f12"), .f12)
    XCTAssertNil(DebugRuntimeKeyInput.key(fromName: "not-a-key"))
  }

  func testModifiersAcceptDebugAliases() {
    let modifiers = DebugRuntimeKeyInput.modifiers(from: ["shift", "option", "super", "ignored"])
    XCTAssertTrue(modifiers.contains(.shift))
    XCTAssertTrue(modifiers.contains(.alt))
    XCTAssertTrue(modifiers.contains(.command))
    XCTAssertFalse(modifiers.contains(.control))
  }

  func testCommandRoutesMatchAppShortcuts() {
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .m).command, "minimize")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .t).command, "newTab")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .w).command, "closePaneOrTab")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .c).command, "copy")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .v).command, "paste")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .f).command, "find")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .digit4).command, "selectTab")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .digit9).command, "selectLastTab")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .enter).route, "ignored")
  }

  func testModifiedTabCommandsMatchAppShortcuts() {
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .arrowRight, modifiers: [.command, .alt])
        .command,
      "paneOrTabNavigationRight")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .bracketLeft, modifiers: [.command, .shift])
        .command,
      "selectPreviousTab")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .tab, modifiers: .control).command,
      "selectNextTab")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .tab, modifiers: [.control, .shift])
        .command,
      "selectPreviousTab")
  }

  func testCommandShiftDSplitsDown() {
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .d).command, "splitPaneRight")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .d, modifiers: [.command, .shift]).command,
      "splitPaneDown")
  }

  func testCommandWClosesPaneOrTab() {
    let route = DebugRuntimeKeyInput.appCommandRoute(for: .w, modifiers: .command)
    XCTAssertEqual(route.route, "appCommand")
    XCTAssertEqual(route.command, "closePaneOrTab")
  }

  func testCommandOptionWClosesTab() {
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .w, modifiers: [.command, .alt]).command,
      "closeTab")
  }

  func testCommandOptionArrowNavigatesPanesOnlyWhenSplit() {
    for (key, name) in [
      (Key.arrowLeft, "Left"), (.arrowRight, "Right"), (.arrowUp, "Up"), (.arrowDown, "Down"),
    ] {
      XCTAssertEqual(
        DebugRuntimeKeyInput.appCommandRoute(for: key, modifiers: [.command, .alt]).command,
        "paneOrTabNavigation" + name)
      XCTAssertEqual(
        DebugRuntimeKeyInput.appCommandRoute(for: key, modifiers: [.command, .control]).command,
        "nudgeDivider" + name)
    }
  }

  func testCommandControlEqualEqualizesNotZoom() {
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .equal, modifiers: [.command, .control]).command,
      "equalizePanes")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .equal, modifiers: .command).command,
      "increaseFontSize")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .enter, modifiers: [.command, .shift]).command,
      "togglePaneZoom")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .arrowLeft, modifiers: [.command, .control]).route,
      "appCommand", "Cmd+Control+Arrow is a divider nudge, not a readline line-edit chord")
  }

  func testCommandLineEditingKeysRouteToTerminal() {
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .arrowLeft, modifiers: .command).route,
      "terminal")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .arrowRight, modifiers: .command).route,
      "terminal")
    XCTAssertEqual(
      DebugRuntimeKeyInput.appCommandRoute(for: .backspace, modifiers: .command).route,
      "terminal")
  }

  func testCommandLineEditingBytesMatchReadlineC0Sequences() {
    XCTAssertEqual(
      DebugRuntimeKeyInput.commandLineEditingBytes(for: .arrowLeft, modifiers: .command),
      [0x01])
    XCTAssertEqual(
      DebugRuntimeKeyInput.commandLineEditingBytes(for: .arrowRight, modifiers: .command),
      [0x05])
    XCTAssertEqual(
      DebugRuntimeKeyInput.commandLineEditingBytes(for: .backspace, modifiers: .command),
      [0x15])
    XCTAssertNil(
      DebugRuntimeKeyInput.commandLineEditingBytes(for: .arrowLeft, modifiers: [.command, .alt]))
  }

  func testCommandLineEditingReleaseIsIgnoredInDebugPath() {
    XCTAssertTrue(
      DebugRuntimeKeyInput.isCommandLineEditingRelease(
        .arrowLeft, modifiers: .command, action: .release))
    XCTAssertTrue(
      DebugRuntimeKeyInput.isCommandLineEditingRelease(
        .backspace, modifiers: .command, action: .release))
    XCTAssertFalse(
      DebugRuntimeKeyInput.isCommandLineEditingRelease(
        .arrowLeft, modifiers: .command, action: .press))
    XCTAssertFalse(
      DebugRuntimeKeyInput.isCommandLineEditingRelease(
        .arrowLeft, modifiers: [.command, .alt], action: .release))
  }

  func testTabIndexUsesOneBasedCommandNumberKeysBeforeLastTabShortcut() {
    XCTAssertEqual(DebugRuntimeKeyInput.tabIndex(for: .digit1), 0)
    XCTAssertEqual(DebugRuntimeKeyInput.tabIndex(for: .digit8), 7)
    XCTAssertNil(DebugRuntimeKeyInput.tabIndex(for: .digit9))
    XCTAssertNil(DebugRuntimeKeyInput.tabIndex(for: .digit0))
  }
}
