import AppKit
import LabanCore
import XCTest

@testable import LabanApp

final class TerminalKeyInputTests: XCTestCase {

  func testCommandTRoutesToNewTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .t, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.newTab))
  }

  func testCommandKeyRoutesToNativeTextWhenMarkedTextExists() {
    let desc = TerminalKeyDescriptor(action: .press, key: .t, modifiers: .command)
    XCTAssertEqual(desc.route(hasMarkedText: true), .nativeText)
  }

  func testCommandWRoutesToCloseTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .w, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.closeTab))
  }

  func testCommandOneRoutesToSelectFirstTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .digit1, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.selectTab(index: 0)))
  }

  func testUnhandledCommandChordSwallows() {
    let desc = TerminalKeyDescriptor(action: .press, key: .x, modifiers: .command)
    XCTAssertEqual(desc.route(), .swallowCommand)
  }

  func testOptionProducedTextRoutesToNativeTextWithOptionConsumed() {
    // Option-4 on some layouts produces "$"; Option is consumed by native text input
    let desc = TerminalKeyDescriptor(
      action: .press,
      key: .digit4,
      modifiers: .alt,
      characters: "$",
      charactersIgnoringModifiers: "4"
    )
    XCTAssertEqual(desc.route(), .nativeText)

    let keyEvent = TerminalKeyDescriptor.buildTextKeyEvent(text: "$", descriptor: desc)
    XCTAssertNotNil(keyEvent)
    XCTAssertTrue(keyEvent!.consumedModifiers.contains(.alt))
    XCTAssertEqual(keyEvent!.text, "$")
  }

  func testPasteboardReadPreflightsDataSizeBeforeStringDecode() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.string], owner: nil)
    let oversized = Data(
      repeating: UInt8(ascii: "a"), count: TerminalBitmapView.pasteHardLimitBytes + 1)
    XCTAssertTrue(pasteboard.setData(oversized, forType: .string))

    XCTAssertEqual(
      TerminalBitmapView.readPasteboardString(pasteboard),
      .tooLarge(TerminalBitmapView.pasteHardLimitBytes + 1)
    )
  }

  func testControlCRoutesToEncodedKeyWithNoText() {
    let desc = TerminalKeyDescriptor(action: .press, key: .c, modifiers: .control)
    guard case .encodedKey(let ev) = desc.route() else {
      XCTFail("expected .encodedKey")
      return
    }
    XCTAssertEqual(ev.key, .c)
    XCTAssertEqual(ev.modifiers, .control)
    XCTAssertNil(ev.text)
  }

  func testShiftTabRoutesToEncodedTabWithShift() {
    let desc = TerminalKeyDescriptor(action: .press, key: .tab, modifiers: .shift)
    XCTAssertEqual(
      desc.route(),
      .encodedKey(KeyEvent(action: .press, key: .tab, modifiers: .shift))
    )
  }

  func testArrowPUAScalarsResolveToArrowKeys() {
    XCTAssertEqual(
      TerminalKeyDescriptor.keyFromPUA(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!),
      .arrowUp
    )
    XCTAssertEqual(
      TerminalKeyDescriptor.keyFromPUA(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),
      .arrowDown
    )
    XCTAssertEqual(
      TerminalKeyDescriptor.keyFromPUA(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!),
      .arrowLeft
    )
    XCTAssertEqual(
      TerminalKeyDescriptor.keyFromPUA(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),
      .arrowRight
    )
    // Arrow descriptor routes to encodedKey with modifiers preserved
    let desc = TerminalKeyDescriptor(
      action: .press, key: .arrowUp, modifiers: .shift)
    guard case .encodedKey(let ev) = desc.route() else {
      XCTFail("expected .encodedKey")
      return
    }
    XCTAssertEqual(ev.key, .arrowUp)
    XCTAssertTrue(ev.modifiers.contains(.shift))
  }

  func testSelectorKeyEventMappings() {
    let enter = TerminalKeyDescriptor.selectorKeyEvent(
      for: #selector(NSResponder.insertNewline(_:)))
    XCTAssertEqual(enter?.key, .enter)
    XCTAssertEqual(enter?.action, .press)

    let backspace = TerminalKeyDescriptor.selectorKeyEvent(
      for: #selector(NSResponder.deleteBackward(_:)))
    XCTAssertEqual(backspace?.key, .backspace)

    let escape = TerminalKeyDescriptor.selectorKeyEvent(
      for: #selector(NSResponder.cancelOperation(_:)))
    XCTAssertEqual(escape?.key, .escape)

    let tab = TerminalKeyDescriptor.selectorKeyEvent(
      for: #selector(NSResponder.insertTab(_:)))
    XCTAssertEqual(tab?.key, .tab)
    XCTAssertFalse(tab?.modifiers.contains(.shift) ?? true)

    let backtab = TerminalKeyDescriptor.selectorKeyEvent(
      for: #selector(NSResponder.insertBacktab(_:)))
    XCTAssertEqual(backtab?.key, .tab)
    XCTAssertTrue(backtab?.modifiers.contains(.shift) ?? false)
  }

  func testKeyUpCreatesReleaseEventWithNoText() {
    let desc = TerminalKeyDescriptor(action: .release, key: .a, modifiers: [])
    guard case .encodedKey(let ev) = desc.route() else {
      XCTFail("expected .encodedKey")
      return
    }
    XCTAssertEqual(ev.action, .release)
    XCTAssertEqual(ev.key, .a)
    XCTAssertNil(ev.text)
  }

  func testTextInputCursorRectUsesTopDownTerminalGrid() {
    let rect = TerminalBitmapView.cursorRectForTextInput(
      rows: 24,
      cursorRow: 2,
      cursorCol: 3,
      sidebarWidth: 200,
      cellWidth: 9,
      cellHeight: 18,
      insets: NSEdgeInsets(top: 36, left: 14, bottom: 8, right: 8)
    )

    XCTAssertEqual(rect.origin.x, 241)
    XCTAssertEqual(rect.origin.y, 386)
    XCTAssertEqual(rect.size.width, 9)
    XCTAssertEqual(rect.size.height, 18)
  }

  func testTextInputCursorRectClampsRowsAndCursor() {
    let rect = TerminalBitmapView.cursorRectForTextInput(
      rows: 0,
      cursorRow: 8,
      cursorCol: -2,
      sidebarWidth: 12,
      cellWidth: 10,
      cellHeight: 20,
      insets: NSEdgeInsets(top: 0, left: 3, bottom: 4, right: 0)
    )

    XCTAssertEqual(rect.origin.x, 15)
    XCTAssertEqual(rect.origin.y, 4)
    XCTAssertEqual(rect.size.width, 10)
    XCTAssertEqual(rect.size.height, 20)
  }
}
