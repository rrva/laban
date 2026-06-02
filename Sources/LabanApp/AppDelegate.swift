import AppKit
import Carbon
import LabanCore
import LabanRenderer

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var windowController: MainWindowController?
  private var appearanceObservation: NSKeyValueObservation?
  private let themeMenuController = ThemeMenuController()
  private let restoreOnLaunchMenuController = RestoreOnLaunchMenuController()
  private let terminalBackendMenuController = TerminalBackendMenuController()
  private lazy var rendererModeMenuController = RendererModeMenuController {
    [weak self] selection in
    self?.windowController?.applyRendererSelection(selection)
  }
  private var updateCheckInFlight = false
  private static let secureKeyboardEntryDefaultsKey = "LabanSecureKeyboardEntry"
  /// Whether `EnableSecureEventInput()` is currently in effect. The Enable/
  /// Disable calls are reference-counted and process-global, so we track
  /// engagement to keep them balanced and never strand the system in secure
  /// input after Laban deactivates or quits.
  private var secureInputEngaged = false

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
    let terminalBackendSelection: TerminalBackendLaunchConfiguration
    do {
      terminalBackendSelection = try MainWindowController.configuredAppTerminalBackend()
    } catch {
      showStartupFailure(error)
      return
    }
    terminalBackendMenuController.configure(
      activeBackend: terminalBackendSelection.backend,
      launchSource: terminalBackendSelection.source)
    MenuCommands.setupMenuBar(
      themeMenu: themeMenuController,
      restoreOnLaunchMenu: restoreOnLaunchMenuController,
      terminalBackendMenu: terminalBackendMenuController,
      rendererModeMenu: rendererModeMenuController
    )

    // Decide whether to restore on this launch:
    //   1. If the user disabled the "Restore on Launch" toggle, start
    //      fresh. On-disk state is left in place. (PersistenceCoordinator.load
    //      checks the same toggle, so this branch is for the ⇧ short-circuit
    //      and to keep the launch flow explicit.)
    //   2. Otherwise, if --no-persistence-restore or
    //      --no-persistence is present, start fresh without loading
    //      workspace.json. The on-disk state is not archived; this is
    //      a launch-time escape hatch.
    //   3. Otherwise, if Shift is held at launch, archive any prior
    //      `workspace.json` to `workspace.json.previous` and start fresh.
    //      The restart shortcut is ⌘⌥R (no Shift) precisely so a
    //      self-issued restart can never be mistaken for this manual
    //      Shift-to-skip-restore and silently wipe the workspace.
    //   4. Otherwise, load via `PersistenceCoordinator.load()` which
    //      enforces the same toggle gate as save and routes through
    //      `PersistenceStore`. A corrupt file is moved aside; nil means
    //      "nothing to restore" and we start fresh.
    let bootstrapCoordinator = PersistenceCoordinator()
    let persistenceSyncEnabled = !PersistenceRestoreLaunchFlag.disablesPersistenceSync()
    let restoredState: WorkspaceState?
    if !RestoreOnLaunchSettings.isEnabled {
      restoredState = nil
    } else if PersistenceRestoreLaunchFlag.disablesPersistenceRestore() {
      restoredState = nil
    } else if NSEvent.modifierFlags.contains(.shift) {
      try? bootstrapCoordinator.store.archiveCurrent()
      restoredState = nil
    } else {
      restoredState = bootstrapCoordinator.load()
    }

    do {
      windowController = try MainWindowController.makeAndShow(
        restoring: restoredState,
        persistenceSyncEnabled: persistenceSyncEnabled,
        terminalBackendSelection: terminalBackendSelection)
    } catch {
      showStartupFailure(error)
      return
    }
    NSApp.activate(ignoringOtherApps: true)

    // System appearance binding. The initial value was applied before window
    // creation; this observer handles later live system changes only.
    appearanceObservation = NSApp.observe(
      \.effectiveAppearance, options: [.new]
    ) { _, _ in
      Self.applyTheme(for: NSApp.effectiveAppearance)
    }

    // Re-engage secure keyboard entry if the user left it on last session.
    applySecureKeyboardEntry()
  }

  static func applyTheme(for appearance: NSAppearance) {
    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    Theme.applyForAppearance(isDark: isDark)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  /// Opt in to the macOS 14+ secure state-restoration contract. Without it
  /// AppKit logs a warning each launch and declines to restore window state.
  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  /// Handle `ssh://` and `telnet://` URLs opened via the system — a clicked
  /// link, `open ssh://host`, or Laban registered as the default handler. Each
  /// URL maps to an argv that runs in a fresh tab; unsupported or malformed
  /// URLs are logged and skipped.
  func application(_ application: NSApplication, open urls: [URL]) {
    var openedAny = false
    for url in urls {
      guard let argv = TerminalURLCommand.argv(for: url) else {
        AppLog.app.error("ignoring unsupported URL: \(url.absoluteString)")
        continue
      }
      do {
        _ = try windowController?.openTab(runningArgv: argv)
        EventLog.shared.log("url.open", ["scheme": url.scheme ?? "", "command": argv.first ?? ""])
        openedAny = true
      } catch {
        AppLog.app.error("failed to open \(url.absoluteString): \(String(describing: error))")
      }
    }
    if openedAny {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  // MARK: Secure Keyboard Entry

  /// Toggle "Secure Keyboard Entry", mirroring Terminal.app: a user-controlled
  /// switch that, while on, asks the system to route keystrokes away from the
  /// event taps other processes install (keyloggers, input monitors).
  @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
    UserDefaults.standard.set(
      !secureKeyboardEntryEnabled, forKey: Self.secureKeyboardEntryDefaultsKey)
    EventLog.shared.log(
      "secureinput.toggle", ["enabled": secureKeyboardEntryEnabled ? "1" : "0"])
    applySecureKeyboardEntry()
  }

  private var secureKeyboardEntryEnabled: Bool {
    UserDefaults.standard.bool(forKey: Self.secureKeyboardEntryDefaultsKey)
  }

  /// Engage secure input only while the toggle is on AND Laban is frontmost,
  /// so we never hold the global lock in the background.
  private func applySecureKeyboardEntry() {
    let shouldEngage = secureKeyboardEntryEnabled && NSApp.isActive
    if shouldEngage, !secureInputEngaged {
      EnableSecureEventInput()
      secureInputEngaged = true
    } else if !shouldEngage, secureInputEngaged {
      DisableSecureEventInput()
      secureInputEngaged = false
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    applySecureKeyboardEntry()
  }

  func applicationWillResignActive(_ notification: Notification) {
    if secureInputEngaged {
      DisableSecureEventInput()
      secureInputEngaged = false
    }
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(toggleSecureKeyboardEntry(_:)) {
      item.state = secureKeyboardEntryEnabled ? .on : .off
    }
    return true
  }

  /// Help-menu entry: reveal ~/Library/Logs/Laban, where captures, casts, and
  /// watchdog stacks are written (see AGENTS.md runtime artifacts).
  @objc func revealLogFolder(_ sender: Any?) {
    guard
      let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Logs/Laban", isDirectory: true)
    else { return }
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    NSWorkspace.shared.open(logs)
  }

  private func showStartupFailure(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Laban failed to start"
    alert.informativeText = "\(error)"
    alert.addButton(withTitle: "Quit")
    alert.runModal()
    NSApp.terminate(nil)
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Take one final synchronous detector sample before workspace
    // persistence writes. This closes the race where a short-lived
    // agent launcher creates a native session log but exits before the
    // periodic detector tick records it.
    if RestoreOnLaunchSettings.isEnabled {
      windowController?.agentObserverHost?.observeNowAll()
    }
    // Drain any pending debounced workspace save so quit does not
    // discard the last few hundred ms of state. `flushSync` no-ops when
    // the toggle is off, so disabled persistence costs nothing here.
    windowController?.persistenceCoordinator?.flushSync()
    // M2: snapshot every tracked agent JSONL so a post-quit reboot
    // still has the conversation available even if the user's
    // ~/.claude or ~/.codex directory loses its sessions.
    if RestoreOnLaunchSettings.isEnabled {
      windowController?.agentObserverHost?.flushAll()
    }
    windowController?.detachTerminalSessions()
    if secureInputEngaged {
      DisableSecureEventInput()
      secureInputEngaged = false
    }
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

  /// Menu/selector entry for "Restart Laban". The relaunched LabanApp
  /// reconnects to the already-running labpty daemon (which is not a
  /// child of LabanApp), so sessions survive the restart.
  @objc func restartApp(_ sender: Any?) {
    Self.restartApp()
  }

  /// Spawn a fresh instance of our own .app via `open -n` and quit the
  /// current one. `-n` forces a new instance because macOS otherwise
  /// just activates the existing one. There's a brief gap where the
  /// window isn't visible — acceptable for an explicit user action.
  ///
  /// No flags are forwarded: the restart shortcut is ⌘⌥R (no Shift), so
  /// the successor can never trip the Shift-to-skip-restore archive
  /// hatch and there is nothing to signal across the relaunch.
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

  func showAvailableUpdate(_ manifest: UpdateManifest) {
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
    // Compute the build age against the moment the panel opens so it reads
    // how stale the running binary is, not a frozen build-time string.
    let built =
      BuildInfo.ageDescription().map { "Built \(BuildInfo.date)\n\($0)" }
      ?? "Built \(BuildInfo.date)"
    let credits = NSAttributedString(
      string:
        "Build \(BuildInfo.commit)\n\(built)\n\nA terminal that aims to be quiet, fast, and honest.",
      attributes: [.foregroundColor: NSColor.labelColor])
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Laban",
      .applicationVersion: BuildInfo.version,
      .credits: credits,
    ])
  }
}
