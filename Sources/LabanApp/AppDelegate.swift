import AppKit
import LabanRenderer

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MainWindowController?
  private var appearanceObservation: NSKeyValueObservation?
  private let themeMenuController = ThemeMenuController()

  func applicationDidFinishLaunching(_ notification: Notification) {
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
}
