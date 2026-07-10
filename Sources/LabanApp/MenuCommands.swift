import AppKit

enum MenuCommands {
  static func setupMenuBar() {
    let mainMenu = NSMenu()

    // App menu (first slot, shown as app name)
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: L10n.tr("About Laban"),
      action: #selector(AppDelegate.showAbout(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(
      withTitle: L10n.tr("Check for Updates…"),
      action: #selector(AppDelegate.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    // Settings (⌘,) — the native home for theme, font, renderer, session
    // backend, and restore-on-launch (previously scattered across the View
    // and Workspace menus).
    appMenu.addItem(
      withTitle: L10n.tr("Settings…"),
      action: #selector(AppDelegate.showSettings(_:)),
      keyEquivalent: ","
    )
    appMenu.addItem(NSMenuItem.separator())
    // Checkmark is driven by AppDelegate.validateMenuItem.
    appMenu.addItem(
      withTitle: L10n.tr("Secure Keyboard Entry"),
      action: #selector(AppDelegate.toggleSecureKeyboardEntry(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    // Standard Hide group. nil targets route up the responder chain to NSApp.
    appMenu.addItem(
      withTitle: L10n.tr("Hide Laban"),
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = NSMenuItem(
      title: L10n.tr("Hide Others"),
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(
      withTitle: L10n.tr("Show All"),
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    // Quits LabanApp and relaunches the on-disk bundle. labpty runs in
    // its own process and is not a child of LabanApp, so it survives
    // the swap — the new instance reconnects to the existing socket.
    let restartItem = NSMenuItem(
      title: L10n.tr("Restart Laban"),
      action: #selector(AppDelegate.restartApp(_:)),
      keyEquivalent: "r"
    )
    restartItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(restartItem)
    appMenu.addItem(
      withTitle: L10n.tr("Quit Laban"),
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    // File menu — tab lifecycle
    let fileItem = NSMenuItem(title: L10n.tr("File"), action: nil, keyEquivalent: "")
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: L10n.tr("File"))
    fileItem.submenu = fileMenu

    fileMenu.addItem(
      NSMenuItem(
        title: L10n.tr("New Tab"),
        action: #selector(TerminalBitmapView.newTab(_:)),
        keyEquivalent: "t"
      ))
    // Note: there is deliberately no "New Agent-Attached Session" menu item.
    // An already-running agent in any tab reaches the control plane through
    // lazy attach (a same-user descendant of the tab shell asks for one
    // approved read, see docs/process/controlling-agent-control-plane.md); a
    // deterministic no-dialog agent is launched with `laban agent run`. The
    // per-tab menu action added nothing over those two paths.
    fileMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Close Tab"),
        action: #selector(TerminalBitmapView.closeTab(_:)),
        keyEquivalent: "w"
      ))

    fileMenu.addItem(NSMenuItem.separator())

    // Export Recent: snapshot the active tab's recent-byte ring as an
    // asciinema v2 cast. Default Cmd-E exports the last 10 s; the
    // submenu offers other windows.
    let exportTen = NSMenuItem(
      title: L10n.tr("Export Last 10 s as Cast"),
      action: #selector(TerminalBitmapView.exportLastTenSeconds(_:)),
      keyEquivalent: "e")
    fileMenu.addItem(exportTen)

    let exportRecent = NSMenuItem(
      title: L10n.tr("Export Recent…"), action: nil, keyEquivalent: "")
    fileMenu.addItem(exportRecent)
    let exportSubmenu = NSMenu(title: L10n.tr("Export Recent…"))
    exportRecent.submenu = exportSubmenu
    exportSubmenu.addItem(
      NSMenuItem(
        title: L10n.tr("Last 5 s as Cast"),
        action: #selector(TerminalBitmapView.exportLastFiveSeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: L10n.tr("Last 10 s as Cast"),
        action: #selector(TerminalBitmapView.exportLastTenSeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: L10n.tr("Last 30 s as Cast"),
        action: #selector(TerminalBitmapView.exportLastThirtySeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: L10n.tr("Last 60 s as Cast"),
        action: #selector(TerminalBitmapView.exportLastSixtySeconds(_:)),
        keyEquivalent: ""))

    // Edit menu — clipboard + selection
    let editItem = NSMenuItem(title: L10n.tr("Edit"), action: nil, keyEquivalent: "")
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: L10n.tr("Edit"))
    editItem.submenu = editMenu

    editMenu.addItem(
      NSMenuItem(title: L10n.tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(
      NSMenuItem(title: L10n.tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    // Select All routes via the responder chain: the terminal view selects the
    // whole buffer; a focused find field selects its text.
    editMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    // Quick Look the selection if it names a file. The terminal can't use
    // Space (it types), so ⌘Y is the keyboard path; force-click / three-finger
    // tap on a word is the gesture path (TerminalBitmapView.quickLook(with:)).
    editMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Quick Look"),
        action: #selector(TerminalBitmapView.quickLookSelection(_:)),
        keyEquivalent: "y"))
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Find…"), action: #selector(TerminalBitmapView.find(_:)), keyEquivalent: "f")
    )

    // View menu — Enter Full Screen. AppKit renames this item to "Exit Full
    // Screen" automatically while the window is full screen.
    let viewItem = NSMenuItem(title: L10n.tr("View"), action: nil, keyEquivalent: "")
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: L10n.tr("View"))
    viewItem.submenu = viewMenu

    // Live font-size zoom — mirrors the Cmd++ / Cmd+- / Cmd+0 key chords
    // routed through TerminalKeyDescriptor.routeCommand().
    viewMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Bigger Text"),
        action: #selector(TerminalBitmapView.increaseFontSize(_:)),
        keyEquivalent: "+"
      ))
    viewMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Smaller Text"),
        action: #selector(TerminalBitmapView.decreaseFontSize(_:)),
        keyEquivalent: "-"
      ))
    viewMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Default Text Size"),
        action: #selector(TerminalBitmapView.resetFontSize(_:)),
        keyEquivalent: "0"
      ))
    viewMenu.addItem(NSMenuItem.separator())

    let fullScreenItem = NSMenuItem(
      title: L10n.tr("Enter Full Screen"),
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullScreenItem.keyEquivalentModifierMask = [.command, .control]
    viewMenu.addItem(fullScreenItem)

    // Tab-select menu — Cmd+1…9
    let tabItem = NSMenuItem(title: L10n.tr("Tab"), action: nil, keyEquivalent: "")
    mainMenu.addItem(tabItem)
    let tabMenu = NSMenu(title: L10n.tr("Tab"))
    tabItem.submenu = tabMenu

    let previousItem = NSMenuItem(
      title: L10n.tr("Previous Tab"),
      action: #selector(TerminalBitmapView.selectPreviousTab(_:)),
      keyEquivalent: UnicodeScalar(UInt32(NSLeftArrowFunctionKey)).map(String.init) ?? ""
    )
    previousItem.keyEquivalentModifierMask = [.command, .option]
    tabMenu.addItem(previousItem)

    let nextItem = NSMenuItem(
      title: L10n.tr("Next Tab"),
      action: #selector(TerminalBitmapView.selectNextTab(_:)),
      keyEquivalent: UnicodeScalar(UInt32(NSRightArrowFunctionKey)).map(String.init) ?? ""
    )
    nextItem.keyEquivalentModifierMask = [.command, .option]
    tabMenu.addItem(nextItem)

    tabMenu.addItem(NSMenuItem.separator())

    for i in 1...8 {
      let item = NSMenuItem(
        title: String(format: L10n.tr("Select Tab %lld"), i),
        action: #selector(TerminalBitmapView.selectTabByIndex(_:)),
        keyEquivalent: "\(i)"
      )
      item.tag = i
      tabMenu.addItem(item)
    }

    tabMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Select Last Tab"),
        action: #selector(TerminalBitmapView.selectLastTab(_:)),
        keyEquivalent: "9"
      ))

    // Debug menu — capture mode for reproducing rendering bugs
    let debugItem = NSMenuItem(title: L10n.tr("Debug"), action: nil, keyEquivalent: "")
    mainMenu.addItem(debugItem)
    let debugMenu = NSMenu(title: L10n.tr("Debug"))
    debugItem.submenu = debugMenu

    // Single persistent item; TerminalBitmapView.validateMenuItem flips the
    // title between "Start"/"Stop PTY Capture" based on live capture state.
    let captureItem = NSMenuItem(
      title: L10n.tr("Start PTY Capture"),
      action: #selector(TerminalBitmapView.toggleCapture(_:)),
      keyEquivalent: "r"
    )
    captureItem.keyEquivalentModifierMask = [.command, .shift]
    debugMenu.addItem(captureItem)

    let renderJournalItem = NSMenuItem(
      title: L10n.tr("Dump Render Journal"),
      action: #selector(TerminalBitmapView.dumpRenderJournal(_:)),
      keyEquivalent: "j"
    )
    renderJournalItem.keyEquivalentModifierMask = [.command, .control, .option]
    debugMenu.addItem(renderJournalItem)

    debugMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Dump Tab Journal"),
        action: #selector(AppDelegate.dumpTabJournal(_:)),
        keyEquivalent: ""
      ))

    debugMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Capture CPU Profile…"),
        action: #selector(AppDelegate.captureProfile(_:)),
        keyEquivalent: ""
      ))

    let profileSessionItem = NSMenuItem(
      title: L10n.tr("Start CPU Recording"),
      action: #selector(AppDelegate.toggleProfileSessionRecording(_:)),
      keyEquivalent: ""
    )
    debugMenu.addItem(profileSessionItem)

    debugMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Export CPU Profile…"),
        action: #selector(AppDelegate.exportProfileSession(_:)),
        keyEquivalent: ""
      ))

    debugMenu.addItem(NSMenuItem.separator())
    debugMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Disable Agent Control Server"),
        action: #selector(AppDelegate.disableAgentControlServer(_:)),
        keyEquivalent: ""
      ))
    debugMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Send Diagnostics…"),
        action: #selector(AppDelegate.sendDiagnostics(_:)),
        keyEquivalent: ""
      ))

    // Window menu — standard window management. Setting NSApp.windowsMenu lets
    // AppKit append and check-mark the open-window list automatically.
    let windowItem = NSMenuItem(title: L10n.tr("Window"), action: nil, keyEquivalent: "")
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: L10n.tr("Window"))
    windowItem.submenu = windowMenu
    windowMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Minimize"),
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
      ))
    windowMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Zoom"),
        action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""
      ))
    windowMenu.addItem(NSMenuItem.separator())
    windowMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Bring All to Front"),
        action: #selector(NSApplication.arrangeInFront(_:)),
        keyEquivalent: ""
      ))
    NSApp.windowsMenu = windowMenu

    // Help menu — setting NSApp.helpMenu also enables the system Help search
    // field, which indexes every menu command.
    let helpItem = NSMenuItem(title: L10n.tr("Help"), action: nil, keyEquivalent: "")
    mainMenu.addItem(helpItem)
    let helpMenu = NSMenu(title: L10n.tr("Help"))
    helpItem.submenu = helpMenu
    helpMenu.addItem(
      NSMenuItem(
        title: L10n.tr("Reveal Log Folder in Finder"),
        action: #selector(AppDelegate.revealLogFolder(_:)),
        keyEquivalent: ""
      ))
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
  }
}
