import AppKit

enum MenuCommands {
  static func setupMenuBar(
    themeMenu: ThemeMenuController,
    restoreOnLaunchMenu: RestoreOnLaunchMenuController,
    terminalBackendMenu: TerminalBackendMenuController,
    rendererModeMenu: RendererModeMenuController
  ) {
    let mainMenu = NSMenu()

    // App menu (first slot, shown as app name)
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appItem.submenu = appMenu
    appMenu.addItem(
      withTitle: "About Laban",
      action: #selector(AppDelegate.showAbout(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(
      withTitle: "Check for Updates…",
      action: #selector(AppDelegate.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    // Checkmark is driven by AppDelegate.validateMenuItem.
    appMenu.addItem(
      withTitle: "Secure Keyboard Entry",
      action: #selector(AppDelegate.toggleSecureKeyboardEntry(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    // Quits LabanApp and relaunches the on-disk bundle. labpty runs in
    // its own process and is not a child of LabanApp, so it survives
    // the swap — the new instance reconnects to the existing socket.
    let restartItem = NSMenuItem(
      title: "Restart Laban",
      action: #selector(AppDelegate.restartApp(_:)),
      keyEquivalent: "r"
    )
    restartItem.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(restartItem)
    appMenu.addItem(
      withTitle: "Quit Laban",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    // File menu — tab lifecycle
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    mainMenu.addItem(fileItem)
    let fileMenu = NSMenu(title: "File")
    fileItem.submenu = fileMenu

    fileMenu.addItem(
      NSMenuItem(
        title: "New Tab",
        action: #selector(TerminalBitmapView.newTab(_:)),
        keyEquivalent: "t"
      ))
    fileMenu.addItem(
      NSMenuItem(
        title: "Close Tab",
        action: #selector(TerminalBitmapView.closeTab(_:)),
        keyEquivalent: "w"
      ))

    fileMenu.addItem(NSMenuItem.separator())

    // Export Recent: snapshot the active tab's recent-byte ring as an
    // asciinema v2 cast. Default Cmd-E exports the last 10 s; the
    // submenu offers other windows.
    let exportTen = NSMenuItem(
      title: "Export Last 10 s as Cast",
      action: #selector(TerminalBitmapView.exportLastTenSeconds(_:)),
      keyEquivalent: "e")
    fileMenu.addItem(exportTen)

    let exportRecent = NSMenuItem(
      title: "Export Recent…", action: nil, keyEquivalent: "")
    fileMenu.addItem(exportRecent)
    let exportSubmenu = NSMenu(title: "Export Recent")
    exportRecent.submenu = exportSubmenu
    exportSubmenu.addItem(
      NSMenuItem(
        title: "Last 5 s as Cast",
        action: #selector(TerminalBitmapView.exportLastFiveSeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: "Last 10 s as Cast",
        action: #selector(TerminalBitmapView.exportLastTenSeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: "Last 30 s as Cast",
        action: #selector(TerminalBitmapView.exportLastThirtySeconds(_:)),
        keyEquivalent: ""))
    exportSubmenu.addItem(
      NSMenuItem(
        title: "Last 60 s as Cast",
        action: #selector(TerminalBitmapView.exportLastSixtySeconds(_:)),
        keyEquivalent: ""))

    // Edit menu — clipboard
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editItem.submenu = editMenu

    editMenu.addItem(
      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(
      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(
      NSMenuItem(title: "Find…", action: #selector(TerminalBitmapView.find(_:)), keyEquivalent: "f")
    )

    // View menu — chrome + theme picker
    let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewItem.submenu = viewMenu

    let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
    viewMenu.addItem(themeItem)
    let themeSubmenu = NSMenu(title: "Theme")
    themeItem.submenu = themeSubmenu
    for entry in themeMenu.makeMenuItems() {
      themeSubmenu.addItem(entry)
    }
    viewMenu.addItem(
      NSMenuItem(
        title: "Font…",
        action: #selector(AppDelegate.showFontPicker(_:)),
        keyEquivalent: ""
      ))
    viewMenu.addItem(NSMenuItem.separator())
    viewMenu.addItem(rendererModeMenu.makeMenuItem())

    // Workspace menu — restore-on-launch toggle. Lives in its own
    // top-level submenu rather than under File or View so users have a
    // single, obvious place to find the persistence kill switch.
    let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
    mainMenu.addItem(workspaceItem)
    let workspaceMenu = NSMenu(title: "Workspace")
    workspaceItem.submenu = workspaceMenu
    workspaceMenu.addItem(restoreOnLaunchMenu.makeMenuItem())
    workspaceMenu.addItem(NSMenuItem.separator())
    workspaceMenu.addItem(terminalBackendMenu.makeMenuItem())

    // Tab-select menu — Cmd+1…9
    let tabItem = NSMenuItem(title: "Tab", action: nil, keyEquivalent: "")
    mainMenu.addItem(tabItem)
    let tabMenu = NSMenu(title: "Tab")
    tabItem.submenu = tabMenu

    let previousItem = NSMenuItem(
      title: "Previous Tab",
      action: #selector(TerminalBitmapView.selectPreviousTab(_:)),
      keyEquivalent: String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!)
    )
    previousItem.keyEquivalentModifierMask = [.command, .option]
    tabMenu.addItem(previousItem)

    let nextItem = NSMenuItem(
      title: "Next Tab",
      action: #selector(TerminalBitmapView.selectNextTab(_:)),
      keyEquivalent: String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!)
    )
    nextItem.keyEquivalentModifierMask = [.command, .option]
    tabMenu.addItem(nextItem)

    tabMenu.addItem(NSMenuItem.separator())

    for i in 1...8 {
      let item = NSMenuItem(
        title: "Select Tab \(i)",
        action: #selector(TerminalBitmapView.selectTabByIndex(_:)),
        keyEquivalent: "\(i)"
      )
      item.tag = i
      tabMenu.addItem(item)
    }

    tabMenu.addItem(
      NSMenuItem(
        title: "Select Last Tab",
        action: #selector(TerminalBitmapView.selectLastTab(_:)),
        keyEquivalent: "9"
      ))

    // Debug menu — capture mode for reproducing rendering bugs
    let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
    mainMenu.addItem(debugItem)
    let debugMenu = NSMenu(title: "Debug")
    debugItem.submenu = debugMenu

    // Single persistent item; TerminalBitmapView.validateMenuItem flips the
    // title between "Start"/"Stop PTY Capture" based on live capture state.
    let captureItem = NSMenuItem(
      title: "Start PTY Capture",
      action: #selector(TerminalBitmapView.toggleCapture(_:)),
      keyEquivalent: "r"
    )
    captureItem.keyEquivalentModifierMask = [.command, .shift]
    debugMenu.addItem(captureItem)

    let renderJournalItem = NSMenuItem(
      title: "Dump Render Journal",
      action: #selector(TerminalBitmapView.dumpRenderJournal(_:)),
      keyEquivalent: "j"
    )
    renderJournalItem.keyEquivalentModifierMask = [.command, .control, .option]
    debugMenu.addItem(renderJournalItem)

    debugMenu.addItem(NSMenuItem.separator())
    debugMenu.addItem(
      NSMenuItem(
        title: "Send Diagnostics…",
        action: #selector(AppDelegate.sendDiagnostics(_:)),
        keyEquivalent: ""
      ))

    // Window menu — standard window management. Setting NSApp.windowsMenu lets
    // AppKit append and check-mark the open-window list automatically.
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    mainMenu.addItem(windowItem)
    let windowMenu = NSMenu(title: "Window")
    windowItem.submenu = windowMenu
    windowMenu.addItem(
      NSMenuItem(
        title: "Minimize",
        action: #selector(NSWindow.performMiniaturize(_:)),
        keyEquivalent: "m"
      ))
    windowMenu.addItem(
      NSMenuItem(
        title: "Zoom",
        action: #selector(NSWindow.performZoom(_:)),
        keyEquivalent: ""
      ))
    windowMenu.addItem(NSMenuItem.separator())
    windowMenu.addItem(
      NSMenuItem(
        title: "Bring All to Front",
        action: #selector(NSApplication.arrangeInFront(_:)),
        keyEquivalent: ""
      ))
    NSApp.windowsMenu = windowMenu

    // Help menu — setting NSApp.helpMenu also enables the system Help search
    // field, which indexes every menu command.
    let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    mainMenu.addItem(helpItem)
    let helpMenu = NSMenu(title: "Help")
    helpItem.submenu = helpMenu
    helpMenu.addItem(
      NSMenuItem(
        title: "Reveal Log Folder in Finder",
        action: #selector(AppDelegate.revealLogFolder(_:)),
        keyEquivalent: ""
      ))
    NSApp.helpMenu = helpMenu

    NSApp.mainMenu = mainMenu
  }
}
