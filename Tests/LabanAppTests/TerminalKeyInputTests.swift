import AppKit
import Carbon.HIToolbox
import LabanCore
import LabanRenderer
import LabanTerminalCore
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

  func testCommandWClosesPaneOrTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .w, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.closePaneOrTab))
  }

  func testCommandOptionWClosesTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .w, modifiers: [.command, .alt])
    XCTAssertEqual(desc.route(), .appCommand(.closeTab))
  }

  func testCommandShiftDSplitsDown() {
    let down = TerminalKeyDescriptor(action: .press, key: .d, modifiers: [.command, .shift])
    XCTAssertEqual(down.route(), .appCommand(.splitPaneDown))
    let right = TerminalKeyDescriptor(action: .press, key: .d, modifiers: .command)
    XCTAssertEqual(right.route(), .appCommand(.splitPaneRight))
  }

  func testCommandControlEqualEqualizesNotZoom() {
    let equalize = TerminalKeyDescriptor(
      action: .press, key: .equal, modifiers: [.command, .control])
    XCTAssertEqual(equalize.route(), .appCommand(.equalizePanes))
    let bigger = TerminalKeyDescriptor(action: .press, key: .equal, modifiers: .command)
    XCTAssertEqual(bigger.route(), .appCommand(.increaseFontSize))
  }

  func testCommandShiftReturnTogglesPaneZoom() {
    let zoom = TerminalKeyDescriptor(action: .press, key: .enter, modifiers: [.command, .shift])
    XCTAssertEqual(zoom.route(), .appCommand(.togglePaneZoom))
    let plain = TerminalKeyDescriptor(action: .press, key: .enter, modifiers: .command)
    XCTAssertEqual(plain.route(), .swallowCommand)
  }

  func testCommandControlArrowsNudgeDividersInsteadOfEditingTheLine() {
    for (key, direction) in [
      (Key.arrowLeft, PaneDirection.left), (.arrowRight, .right), (.arrowUp, .up),
      (.arrowDown, .down),
    ] {
      let desc = TerminalKeyDescriptor(action: .press, key: key, modifiers: [.command, .control])
      XCTAssertEqual(desc.route(), .appCommand(.nudgeDivider(direction)))
    }
  }

  func testCommandOptionArrowNavigatesPanesOnlyWhenSplit() throws {
    for (key, direction) in [
      (Key.arrowLeft, PaneDirection.left), (.arrowRight, .right), (.arrowUp, .up),
      (.arrowDown, .down),
    ] {
      let desc = TerminalKeyDescriptor(action: .press, key: key, modifiers: [.command, .alt])
      XCTAssertEqual(desc.route(), .appCommand(.paneOrTabNavigation(direction)))
    }

    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }
    var size = LabanTerminalSize()
    size.rows = 30
    size.cols = 120
    let model = try AppModel(
      initialSize: size,
      sessionFactory: { size, context in
        try Session.fixture(size: size, sessionID: context.sessionID)
      })
    let fontAtlas = FontAtlas(pointSize: 14)
    let cellWidth = Int(fontAtlas.cellSize.width)
    let cellHeight = Int(fontAtlas.cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let view = TerminalBitmapView(
      model: model, fontAtlas: fontAtlas, sidebarFontAtlas: FontAtlas(pointSize: 11),
      cellWidth: cellWidth, cellHeight: cellHeight)
    view.frame = NSRect(
      x: 0, y: 0,
      width: SidebarLayout.defaultWidth + insets.left + CGFloat(120 * cellWidth) + insets.right,
      height: insets.top + CGFloat(30 * cellHeight) + insets.bottom)
    view.advanceFrame()
    let firstTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    model.selectTab(firstTab.id)

    // Unsplit: left/right still switch tabs, up/down do nothing.
    view.executeAppCommand(.paneOrTabNavigation(.down))
    XCTAssertEqual(model.activeTab?.id, firstTab.id)
    view.executeAppCommand(.paneOrTabNavigation(.right))
    XCTAssertNotEqual(model.activeTab?.id, firstTab.id)
    view.executeAppCommand(.paneOrTabNavigation(.left))
    XCTAssertEqual(model.activeTab?.id, firstTab.id)

    // Split: the chord moves pane focus and never falls through to tab switching.
    let left = firstTab.focusedSessionId
    view.splitPaneRight(nil)
    let right = try XCTUnwrap(model.activeTab?.focusedSessionId)
    view.executeAppCommand(.paneOrTabNavigation(.left))
    XCTAssertEqual(model.activeTab?.focusedSessionId, left)
    XCTAssertEqual(model.activeTab?.id, firstTab.id)
    view.executeAppCommand(.paneOrTabNavigation(.left))
    XCTAssertEqual(model.activeTab?.id, firstTab.id, "the layout edge does not switch tabs")
    XCTAssertEqual(model.activeTab?.focusedSessionId, left)
    view.executeAppCommand(.paneOrTabNavigation(.right))
    XCTAssertEqual(model.activeTab?.focusedSessionId, right)
    view.executeAppCommand(.paneOrTabNavigation(.up))
    XCTAssertEqual(model.activeTab?.focusedSessionId, right, "no pane above: nothing happens")

    // Cmd+W closes the focused pane of a split tab, then the tab.
    view.executeAppCommand(.closePaneOrTab)
    XCTAssertEqual(model.activeTab?.allSessionIds, [left])
    XCTAssertEqual(model.tabs.count, 2)
    view.executeAppCommand(.closePaneOrTab)
    XCTAssertEqual(model.tabs.count, 1)
  }

  func testCommandFRoutesToFind() {
    let desc = TerminalKeyDescriptor(action: .press, key: .f, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.find))
  }

  func testCommandControlOptionJRoutesToDumpRenderJournal() {
    let desc = TerminalKeyDescriptor(
      action: .press,
      key: .j,
      modifiers: [.command, .control, .alt])
    XCTAssertEqual(desc.route(), .appCommand(.dumpRenderJournal))
  }

  func testCommandOneRoutesToSelectFirstTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .digit1, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.selectTab(index: 0)))
  }

  func testCommandNineRoutesToSelectLastTab() {
    let desc = TerminalKeyDescriptor(action: .press, key: .digit9, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.selectLastTab))
  }

  func testCommandOptionLeftRightKeepSwitchingTabsInUnsplitTabs() {
    // The route is shared with pane navigation; `perform` decides by the active tab.
    let next = TerminalKeyDescriptor(
      action: .press, key: .arrowRight, modifiers: [.command, .alt])
    XCTAssertEqual(next.route(), .appCommand(.paneOrTabNavigation(.right)))

    let previous = TerminalKeyDescriptor(
      action: .press, key: .arrowLeft, modifiers: [.command, .alt])
    XCTAssertEqual(previous.route(), .appCommand(.paneOrTabNavigation(.left)))
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

  func testCommandMRoutesToMinimize() {
    let desc = TerminalKeyDescriptor(action: .press, key: .m, modifiers: .command)
    XCTAssertEqual(desc.route(), .appCommand(.minimize))
  }

  func testCommandZoomChordsRouteToFontSizeCommands() {
    let increase = TerminalKeyDescriptor(action: .press, key: .equal, modifiers: .command)
    XCTAssertEqual(increase.route(), .appCommand(.increaseFontSize))

    // Cmd+Shift+= is Cmd+plus on a US layout; same key, same command.
    let increaseShifted = TerminalKeyDescriptor(
      action: .press, key: .equal, modifiers: [.command, .shift])
    XCTAssertEqual(increaseShifted.route(), .appCommand(.increaseFontSize))

    let decrease = TerminalKeyDescriptor(action: .press, key: .minus, modifiers: .command)
    XCTAssertEqual(decrease.route(), .appCommand(.decreaseFontSize))

    let reset = TerminalKeyDescriptor(action: .press, key: .digit0, modifiers: .command)
    XCTAssertEqual(reset.route(), .appCommand(.resetFontSize))
  }

  func testCommandPlusEventRoutesToIncreaseByPrintedCharacter() throws {
    let plusOnMinusKey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "+",
        charactersIgnoringModifiers: "+",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_Minus)))

    let desc = TerminalKeyDescriptor(keyDown: plusOnMinusKey)
    XCTAssertEqual(desc.key, .equal)
    XCTAssertEqual(desc.route(), .appCommand(.increaseFontSize))
  }

  func testFontSizeMenuShortcutsMatchCommandRouter() throws {
    let app = NSApplication.shared
    let oldMainMenu = app.mainMenu
    let oldWindowsMenu = app.windowsMenu
    let oldHelpMenu = app.helpMenu
    defer {
      app.mainMenu = oldMainMenu
      app.windowsMenu = oldWindowsMenu
      app.helpMenu = oldHelpMenu
    }

    MenuCommands.setupMenuBar()

    let viewMenu = try XCTUnwrap(app.mainMenu?.item(withTitle: "View")?.submenu)
    let bigger = try XCTUnwrap(viewMenu.item(withTitle: "Bigger Text"))
    let smaller = try XCTUnwrap(viewMenu.item(withTitle: "Smaller Text"))
    let reset = try XCTUnwrap(viewMenu.item(withTitle: "Default Text Size"))

    XCTAssertEqual(bigger.action, #selector(TerminalBitmapView.increaseFontSize(_:)))
    XCTAssertEqual(bigger.keyEquivalent, "+")
    XCTAssertEqual(commandShortcutModifiers(for: bigger), .command)

    XCTAssertEqual(smaller.action, #selector(TerminalBitmapView.decreaseFontSize(_:)))
    XCTAssertEqual(smaller.keyEquivalent, "-")
    XCTAssertEqual(commandShortcutModifiers(for: smaller), .command)

    XCTAssertEqual(reset.action, #selector(TerminalBitmapView.resetFontSize(_:)))
    XCTAssertEqual(reset.keyEquivalent, "0")
    XCTAssertEqual(commandShortcutModifiers(for: reset), .command)
  }

  func testPaneMenuShortcutsMatchCommandRouter() throws {
    let app = NSApplication.shared
    let oldMainMenu = app.mainMenu
    let oldWindowsMenu = app.windowsMenu
    let oldHelpMenu = app.helpMenu
    defer {
      app.mainMenu = oldMainMenu
      app.windowsMenu = oldWindowsMenu
      app.helpMenu = oldHelpMenu
    }
    MenuCommands.setupMenuBar()

    let fileMenu = try XCTUnwrap(app.mainMenu?.item(withTitle: "File")?.submenu)
    let close = try XCTUnwrap(
      fileMenu.items.first { $0.action == #selector(TerminalBitmapView.closePaneOrTab(_:)) })
    XCTAssertEqual(close.keyEquivalent, "w")
    XCTAssertEqual(commandShortcutModifiers(for: close), .command)
    let closeTab = try XCTUnwrap(
      fileMenu.items.first { $0.action == #selector(TerminalBitmapView.closeTab(_:)) })
    XCTAssertEqual(closeTab.keyEquivalent, "w")
    XCTAssertEqual(commandShortcutModifiers(for: closeTab), [.command, .option])
    XCTAssertTrue(closeTab.isAlternate)
    let right = try XCTUnwrap(
      fileMenu.items.first { $0.action == #selector(TerminalBitmapView.splitPaneRight(_:)) })
    XCTAssertEqual(commandShortcutModifiers(for: right), .command)
    let down = try XCTUnwrap(
      fileMenu.items.first { $0.action == #selector(TerminalBitmapView.splitPaneDown(_:)) })
    XCTAssertEqual(down.keyEquivalent, "d")
    XCTAssertEqual(commandShortcutModifiers(for: down), [.command, .shift])
    XCTAssertNil(
      fileMenu.items.first { $0.action == #selector(TerminalBitmapView.closePane(_:)) },
      "Cmd+Shift+D no longer closes a pane")

    let viewMenu = try XCTUnwrap(app.mainMenu?.item(withTitle: "View")?.submenu)
    let paneMenu = try XCTUnwrap(viewMenu.item(withTitle: "Pane")?.submenu)
    let zoom = try XCTUnwrap(paneMenu.item(withTitle: "Zoom Pane"))
    XCTAssertEqual(zoom.keyEquivalent, "\r")
    XCTAssertEqual(commandShortcutModifiers(for: zoom), [.command, .shift])
    let equalize = try XCTUnwrap(paneMenu.item(withTitle: "Equalize Panes"))
    XCTAssertEqual(equalize.keyEquivalent, "=")
    XCTAssertEqual(commandShortcutModifiers(for: equalize), [.command, .control])
    // Cmd+Option+Left/Right stay the hold-to-peek tab chord, so no key equivalent.
    XCTAssertEqual(try XCTUnwrap(paneMenu.item(withTitle: "Select Pane Left")).keyEquivalent, "")
    XCTAssertEqual(try XCTUnwrap(paneMenu.item(withTitle: "Select Pane Right")).keyEquivalent, "")
    let above = try XCTUnwrap(paneMenu.item(withTitle: "Select Pane Above"))
    XCTAssertEqual(commandShortcutModifiers(for: above), [.command, .option])
    let resize = try XCTUnwrap(paneMenu.item(withTitle: "Resize Pane")?.submenu)
    XCTAssertEqual(resize.items.count, 4)
    for item in resize.items {
      XCTAssertEqual(commandShortcutModifiers(for: item), [.command, .control])
      XCTAssertEqual(item.action, #selector(TerminalBitmapView.moveDivider(_:)))
    }
  }

  private func commandShortcutModifiers(for item: NSMenuItem) -> NSEvent.ModifierFlags {
    item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
  }

  func testCommandArrowsRouteToReadlineC0Bytes() {
    let left = TerminalKeyDescriptor(action: .press, key: .arrowLeft, modifiers: .command)
    XCTAssertEqual(left.route(), .terminalBytes([0x01]))

    let right = TerminalKeyDescriptor(action: .press, key: .arrowRight, modifiers: .command)
    XCTAssertEqual(right.route(), .terminalBytes([0x05]))
  }

  func testCommandBackspaceRoutesToKillLineStartByte() {
    let desc = TerminalKeyDescriptor(action: .press, key: .backspace, modifiers: .command)
    XCTAssertEqual(desc.route(), .terminalBytes([0x15]))
  }

  func testCommandLineEditingReleaseIsSwallowed() {
    let release = TerminalKeyDescriptor(action: .release, key: .arrowLeft, modifiers: .command)
    XCTAssertEqual(release.route(), .swallowCommand)
  }

  func testCommandLineEditingWithMarkedTextRoutesToNativeText() {
    let desc = TerminalKeyDescriptor(action: .press, key: .arrowLeft, modifiers: .command)
    XCTAssertEqual(desc.route(hasMarkedText: true), .nativeText)
  }

  func testUnhandledCommandChordSwallows() {
    let desc = TerminalKeyDescriptor(action: .press, key: .x, modifiers: .command)
    XCTAssertEqual(desc.route(), .swallowCommand)
  }

  func testOptionProducedTextRoutesToNativeTextWithOptionConsumed() {
    OptionKeySettings.set(false)
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

  func testOptionAsMetaSettingEncodesAltChord() {
    OptionKeySettings.set(true)
    defer { OptionKeySettings.set(false) }
    let desc = TerminalKeyDescriptor(
      action: .press,
      key: .digit4,
      modifiers: .alt,
      characters: "$",
      charactersIgnoringModifiers: "4"
    )
    guard case .encodedKey(let keyEvent) = desc.route() else {
      XCTFail("expected .encodedKey when Option-as-Meta is enabled")
      return
    }
    XCTAssertEqual(keyEvent.key, .digit4)
    XCTAssertEqual(keyEvent.modifiers, .alt)
    XCTAssertEqual(keyEvent.optionAsMeta, true)
    XCTAssertFalse(keyEvent.consumedModifiers.contains(.alt))
  }

  func testDigitKeyDuringMarkedTextRoutesToNativeText() {
    OptionKeySettings.set(true)
    defer { OptionKeySettings.set(false) }
    let desc = TerminalKeyDescriptor(
      action: .press,
      key: .digit1,
      modifiers: .alt,
      characters: "!",
      charactersIgnoringModifiers: "1"
    )
    XCTAssertEqual(desc.route(hasMarkedText: true), .nativeText)
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
