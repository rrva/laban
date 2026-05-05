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
