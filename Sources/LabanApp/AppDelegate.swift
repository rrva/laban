import AppKit
import LabanRenderer

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MainWindowController?
  private var appearanceObservation: NSKeyValueObservation?
  private let themeMenuController = ThemeMenuController()

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppLog.app.notice("launch \(BuildInfo.summary)")
    LogFile.shared.pruneOldFiles()
    EventLog.shared.pruneOldFiles()
    EventLog.shared.log(
      "app.start",
      ["build": BuildInfo.commit, "buildDate": BuildInfo.date])

    // Stall watchdog: detects main-thread freezes ≥200 ms and writes a
    // sample(1) capture to ~/laban-watchdog/. Cheap; safe to leave on.
    MainThreadWatchdog.shared.start()

    // Restore the user's last theme picks BEFORE the appearance KVO fires
    // its initial callback so the first frame already uses them.
    themeMenuController.loadPersistedChoices()
    MenuCommands.setupMenuBar(themeMenu: themeMenuController)
    do {
      windowController = try MainWindowController.makeAndShow()
    } catch {
      let alert = NSAlert()
      alert.messageText = "Laban failed to start"
      alert.informativeText = "\(error)"
      alert.addButton(withTitle: "Quit")
      alert.runModal()
      NSApp.terminate(nil)
    }
    NSApp.activate(ignoringOtherApps: true)

    // System appearance binding. KVO fires on main; .initial primes Theme so
    // the first frame already matches the system's dark/light setting rather
    // than flashing the compile-time default.
    appearanceObservation = NSApp.observe(
      \.effectiveAppearance, options: [.initial, .new]
    ) { _, _ in
      let isDark =
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      Theme.applyForAppearance(isDark: isDark)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    EventLog.shared.log("app.quit")
  }

  @objc func sendDiagnostics(_ sender: Any?) {
    SendDiagnostics.run()
  }

  /// Open NSFontPanel, primed with the current pick. The panel is
  /// non-modal — the user picks a font, AppKit fires `changeFont(_:)`
  /// on the responder chain (us, since we're the menu target). We
  /// persist the choice and ask the user to relaunch; live re-skinning
  /// the renderer would require recreating the Metal glyph atlases and
  /// resizing every session's grid, which isn't worth the complexity
  /// for a setting most users change once.
  @objc func showFontPicker(_ sender: Any?) {
    let panel = NSFontPanel.shared
    let currentName = UserDefaults.standard.string(forKey: "LabanFontName") ?? "JetBrains Mono"
    let initialFont = NSFont(name: currentName, size: 14)
      ?? NSFont(name: "Menlo", size: 14)
      ?? NSFont.systemFont(ofSize: 14)
    panel.setPanelFont(initialFont, isMultiple: false)
    NSFontManager.shared.target = self
    NSFontManager.shared.action = #selector(changeFont(_:))
    panel.makeKeyAndOrderFront(self)
  }

  /// AppKit calls this on the font-manager target whenever the user
  /// picks a face in NSFontPanel. We save the face name only — the
  /// pt-size is kept fixed (14 terminal / 11 sidebar) so the quad-
  /// height tab layout stays balanced regardless of font choice.
  @objc func changeFont(_ sender: Any?) {
    let fm = NSFontManager.shared
    let currentName = UserDefaults.standard.string(forKey: "LabanFontName") ?? "Menlo"
    let current = NSFont(name: currentName, size: 14) ?? NSFont.systemFont(ofSize: 14)
    let new = fm.convert(current)
    UserDefaults.standard.set(new.fontName, forKey: "LabanFontName")
    AppLog.app.info("font picked: \(new.fontName)")
    EventLog.shared.log("font.set", ["name": new.fontName])
    let alert = NSAlert()
    alert.messageText = "Font set to \(new.displayName ?? new.fontName)"
    alert.informativeText = "Quit and relaunch Laban to apply."
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  /// About panel populated from BuildInfo so the version is always live
  /// against what was actually built. Shown via the standard macOS
  /// "About Laban" item in the app menu.
  @objc func showAbout(_ sender: Any?) {
    let credits = NSAttributedString(
      string: "Built \(BuildInfo.date)\n\nA terminal that aims to be quiet, fast, and honest.",
      attributes: [.foregroundColor: NSColor.labelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Laban",
      .applicationVersion: BuildInfo.commit,
      .credits: credits,
    ])
  }
}
