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

  func testCommandFRoutesToFind() {
    let desc = TerminalKeyDescriptor(action: .press, key: .f, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.find))
  }

  func testCommandOneRoutesToSelectFirstTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .digit1, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.selectTab(index: 0)))
  }

  func testCommandNineRoutesToSelectLastTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .digit9, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.selectLastTab))
  }

  func testCommandOptionArrowsRouteToAdjacentTabs() {
    let next = TerminalKeyDescriptor(
      action: .press, key: .arrowRight, modifiers: [.command, .alt])
    XCTAssertEqual(next.route(), .appCommand(.selectNextTab))

    let previous = TerminalKeyDescriptor(
      action: .press, key: .arrowLeft, modifiers: [.command, .alt])
    XCTAssertEqual(previous.route(), .appCommand(.selectPreviousTab))
  }

  func testCommandShiftBracketsRouteToAdjacentTabs() {
    let next = TerminalKeyDescriptor(
      action: .press, key: .bracketRight, modifiers: [.command, .shift])
    XCTAssertEqual(next.route(), .appCommand(.selectNextTab))

    let previous = TerminalKeyDescriptor(
      action: .press, key: .bracketLeft, modifiers: [.command, .shift])
    XCTAssertEqual(previous.route(), .appCommand(.selectPreviousTab))
  }

  func testControlTabRoutesToAdjacentTabs() {
    let next = TerminalKeyDescriptor(action: .press, key: .tab, modifiers: .control)
    XCTAssertEqual(next.route(), .appCommand(.selectNextTab))

    let previous = TerminalKeyDescriptor(
      action: .press, key: .tab, modifiers: [.control, .shift])
    XCTAssertEqual(previous.route(), .appCommand(.selectPreviousTab))
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

  func testControlVRoutesToEncodedKeyWithNoText() {
    let desc = TerminalKeyDescriptor(action: .press, key: .v, modifiers: .control)
    guard case .encodedKey(let ev) = desc.route() else {
      XCTFail("expected .encodedKey")
      return
    }
    XCTAssertEqual(ev.key, .v)
    XCTAssertEqual(ev.modifiers, .control)
    XCTAssertNil(ev.text)
  }

  func testControlZRoutesToEncodedKeyWithNoText() {
    let desc = TerminalKeyDescriptor(action: .press, key: .z, modifiers: .control)
    guard case .encodedKey(let ev) = desc.route() else {
      XCTFail("expected .encodedKey")
      return
    }
    XCTAssertEqual(ev.key, .z)
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

  func testControlTabReleaseIsSwallowedNotEncoded() {
    // M-2: the Ctrl+Tab press is consumed as a tab switch, so its matching
    // release must NOT be encoded to the active session — after the switch
    // that is a different session that never saw the press.
    let press = TerminalKeyDescriptor(action: .press, key: .tab, modifiers: .control)
    XCTAssertEqual(press.route(), .appCommand(.selectNextTab))
    let release = TerminalKeyDescriptor(action: .release, key: .tab, modifiers: .control)
    XCTAssertEqual(release.route(), .swallowCommand)
  }

  func testAppCommandChordReleaseIsSwallowed() {
    // M-2: a Command chord whose press is an app command emits no release.
    let release = TerminalKeyDescriptor(action: .release, key: .t, modifiers: .command)
    XCTAssertEqual(release.route(), .swallowCommand)
  }

  func testTextInputCursorRectUsesTopDownTerminalGrid() {
    let rect = TerminalTextInputGeometry.cursorRect(
      rows: 24,
      cursorRow: 2,
      cursorCol: 3,
      sidebarWidth: 200,
      cellWidth: 9,
      cellHeight: 18,
      boundsHeight: 476,
      insets: NSEdgeInsets(top: 36, left: 14, bottom: 8, right: 8)
    )

    XCTAssertEqual(rect.origin.x, 241)
    XCTAssertEqual(rect.origin.y, 386)
    XCTAssertEqual(rect.size.width, 9)
    XCTAssertEqual(rect.size.height, 18)
  }

  func testTextInputCursorRectClampsRowsAndCursor() {
    let rect = TerminalTextInputGeometry.cursorRect(
      rows: 0,
      cursorRow: 8,
      cursorCol: -2,
      sidebarWidth: 12,
      cellWidth: 10,
      cellHeight: 20,
      boundsHeight: 24,
      insets: NSEdgeInsets(top: 0, left: 3, bottom: 4, right: 0)
    )

    XCTAssertEqual(rect.origin.x, 15)
    XCTAssertEqual(rect.origin.y, 4)
    XCTAssertEqual(rect.size.width, 10)
    XCTAssertEqual(rect.size.height, 20)
  }

  func testTextInputCursorRectKeepsTopRowAnchoredWithExtraHeight() {
    let insets = NSEdgeInsets(top: 36, left: 14, bottom: 8, right: 8)
    let exactHeight = insets.top + 24 * CGFloat(18) + insets.bottom
    let rect = TerminalTextInputGeometry.cursorRect(
      rows: 24,
      cursorRow: 0,
      cursorCol: 0,
      sidebarWidth: 200,
      cellWidth: 9,
      cellHeight: 18,
      boundsHeight: exactHeight + 11,
      insets: insets
    )

    XCTAssertEqual((exactHeight + 11) - (rect.origin.y + rect.height), insets.top)
  }
}
