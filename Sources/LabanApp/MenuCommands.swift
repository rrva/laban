import AppKit

enum MenuCommands {
  static func setupMenuBar(
    themeMenu: ThemeMenuController,
    restoreOnLaunchMenu: RestoreOnLaunchMenuController
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

    // Workspace menu — restore-on-launch toggle. Lives in its own
    // top-level submenu rather than under File or View so users have a
    // single, obvious place to find the persistence kill switch.
    let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
    mainMenu.addItem(workspaceItem)
    let workspaceMenu = NSMenu(title: "Workspace")
    workspaceItem.submenu = workspaceMenu
    workspaceMenu.addItem(restoreOnLaunchMenu.makeMenuItem())

    // Tab-select menu — Cmd+1…9
    let tabItem = NSMenuItem(title: "Tab", action: nil, keyEquivalent: "")
    mainMenu.addItem(tabItem)
    let tabMenu = NSMenu(title: "Tab")
    tabItem.submenu = tabMenu

    for i in 1...9 {
      let item = NSMenuItem(
        title: "Select Tab \(i)",
        action: #selector(TerminalBitmapView.selectTabByIndex(_:)),
        keyEquivalent: "\(i)"
      )
      item.tag = i
      tabMenu.addItem(item)
    }

    // Debug menu — capture mode for reproducing rendering bugs
    let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
    mainMenu.addItem(debugItem)
    let debugMenu = NSMenu(title: "Debug")
    debugItem.submenu = debugMenu

    let captureItem = NSMenuItem(
      title: "Toggle PTY Capture",
      action: #selector(TerminalBitmapView.toggleCapture(_:)),
      keyEquivalent: "r"
    )
    captureItem.keyEquivalentModifierMask = [.command, .shift]
    debugMenu.addItem(captureItem)

    debugMenu.addItem(NSMenuItem.separator())
    debugMenu.addItem(
      NSMenuItem(
        title: "Send Diagnostics…",
        action: #selector(AppDelegate.sendDiagnostics(_:)),
        keyEquivalent: ""
      ))

    NSApp.mainMenu = mainMenu
  }
}
