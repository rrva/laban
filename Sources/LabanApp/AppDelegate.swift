import AppKit
import LabanRenderer

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windowController: MainWindowController?
  private var appearanceObservation: NSKeyValueObservation?
  private let themeMenuController = ThemeMenuController()
  private var updateCheckInFlight = false

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

    // Restore the user's last theme picks and settle the initial appearance
    // before creating the first terminal session. Shell startup files may set
    // the terminal palette via OSC 4/10/11; a late initial theme notification
    // would overwrite that user-provided palette shortly after zsh starts.
    themeMenuController.loadPersistedChoices()
    Self.applyTheme(for: NSApp.effectiveAppearance)
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

    // System appearance binding. The initial value was applied before window
    // creation; this observer handles later live system changes only.
    appearanceObservation = NSApp.observe(
      \.effectiveAppearance, options: [.new]
    ) { _, _ in
      Self.applyTheme(for: NSApp.effectiveAppearance)
    }
  }

  static func applyTheme(for appearance: NSAppearance) {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    Theme.applyForAppearance(isDark: isDark)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) {
    EventLog.shared.log("app.quit")
  }

  @objc func sendDiagnostics(_ sender: Any?) {
    SendDiagnostics.run()
  }

  @objc func checkForUpdates(_ sender: Any?) {
    guard !updateCheckInFlight else { return }
    guard let manifestURL = UpdateChecker.configuredManifestURL() else {
      showUpdateAlert(
        title: "Update checks are not configured",
        message:
          "Set \(UpdateChecker.manifestURLBundleKey) in the app bundle or \(UpdateChecker.manifestURLDefaultsKey) in user defaults."
      )
      return
    }

    updateCheckInFlight = true
    AppLog.app.info("update check started: \(manifestURL.absoluteString)")
    EventLog.shared.log("update.check.start", ["url": manifestURL.absoluteString])
    UpdateChecker.check(manifestURL: manifestURL, currentVersion: BuildInfo.version) {
      [weak self] result in
      DispatchQueue.main.async {
        self?.updateCheckInFlight = false
        self?.handleUpdateCheck(result)
      }
    }
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
    let initialFont =
      NSFont(name: currentName, size: 14)
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
    alert.informativeText = "Restart Laban to apply."
    alert.addButton(withTitle: "Restart Now")  // .firstButtonReturn
    alert.addButton(withTitle: "Later")  // .secondButtonReturn
    if alert.runModal() == .alertFirstButtonReturn {
      Self.restartApp()
    }
  }

  /// Spawn a fresh instance of our own .app via `open -n` and quit the
  /// current one. `-n` forces a new instance because macOS otherwise
  /// just activates the existing one. There's a brief gap where the
  /// window isn't visible — acceptable for an explicit user action.
  static func restartApp() {
    let bundleURL = Bundle.main.bundleURL
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", bundleURL.path]
    do {
      try task.run()
      NSApp.terminate(nil)
    } catch {
      AppLog.app.error("restart failed: \(error)")
    }
  }

  private func handleUpdateCheck(_ result: Result<UpdateCheckResult, Error>) {
    switch result {
    case .success(.available(let manifest)):
      AppLog.app.info("update available: \(manifest.latest)")
      EventLog.shared.log(
        "update.check.available",
        ["latest": manifest.latest, "current": BuildInfo.version])
      showAvailableUpdate(manifest)
    case .success(.upToDate(let manifest)):
      AppLog.app.info("no update available: latest \(manifest.latest)")
      EventLog.shared.log(
        "update.check.current",
        ["latest": manifest.latest, "current": BuildInfo.version])
      showUpdateAlert(
        title: "Laban is up to date",
        message: "You are running \(BuildInfo.version)."
      )
    case .failure(let error):
      AppLog.app.error("update check failed: \(error.localizedDescription)")
      EventLog.shared.log("update.check.failed", ["error": error.localizedDescription])
      showUpdateAlert(
        title: "Update check failed",
        message: error.localizedDescription
      )
    }
  }

  private func showAvailableUpdate(_ manifest: UpdateManifest) {
    let alert = NSAlert()
    alert.messageText = "Laban \(manifest.latest) is available"
    var message = "You are running \(BuildInfo.version)."
    if let notes = manifest.notes, !notes.isEmpty {
      message += "\n\n\(notes)"
    }
    alert.informativeText = message
    alert.addButton(withTitle: "Open Download")
    alert.addButton(withTitle: "Not Now")
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(manifest.downloadURL)
      EventLog.shared.log(
        "update.download.open",
        ["latest": manifest.latest, "url": manifest.downloadURL.absoluteString])
    }
  }

  private func showUpdateAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  /// About panel populated from BuildInfo so the version is always live
  /// against what was actually built. Shown via the standard macOS
  /// "About Laban" item in the app menu.
  @objc func showAbout(_ sender: Any?) {
    let credits = NSAttributedString(
      string:
        "Build \(BuildInfo.commit)\nBuilt \(BuildInfo.date)\n\nA terminal that aims to be quiet, fast, and honest.",
      attributes: [.foregroundColor: NSColor.labelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Laban",
      .applicationVersion: BuildInfo.version,
      .credits: credits,
    ])
  }
}
