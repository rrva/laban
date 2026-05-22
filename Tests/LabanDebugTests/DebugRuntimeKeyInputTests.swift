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
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .t).command, "newTab")
    XCTAssertEqual(DebugRuntimeKeyInput.commandRoute(for: .w).command, "closeTab")
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
      "selectNextTab")
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

  func testTabIndexUsesOneBasedCommandNumberKeysBeforeLastTabShortcut() {
    XCTAssertEqual(DebugRuntimeKeyInput.tabIndex(for: .digit1), 0)
    XCTAssertEqual(DebugRuntimeKeyInput.tabIndex(for: .digit8), 7)
    XCTAssertNil(DebugRuntimeKeyInput.tabIndex(for: .digit9))
    XCTAssertNil(DebugRuntimeKeyInput.tabIndex(for: .digit0))
  }
}
