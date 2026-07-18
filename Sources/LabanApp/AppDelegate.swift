import AppKit
import Carbon
import CoreText
import LabanControl
import LabanCore
import LabanRenderer
import ProfileRecorder
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation,
  UNUserNotificationCenterDelegate
{
  private var windowController: MainWindowController?
  private var appearanceObservation: NSKeyValueObservation?
  private let themeMenuController = ThemeMenuController()
  private let frostedPresetThemeFollower = FrostedPresetThemeFollower()
  private let terminalBackendMenuController = TerminalBackendMenuController()
  private let notificationStateRefresher = NativeNotificationStateRefresher.shared
  private lazy var settingsNotificationPoster = AgentNotificationPoster(
    onNativeStateChanged: { [weak self] in
      self?.notificationStateRefresher.refresh()
    })
  private lazy var notificationResponseHandler = NativeNotificationResponseHandler(
    activateApplication: {
      NSApp.activate(ignoringOtherApps: true)
    },
    focusTab: { [weak self] tabId in
      self?.windowController?.focusTabFromNotification(tabId) ?? false
    })
  private lazy var rendererModeMenuController = RendererModeMenuController {
    [weak self] selection in
    self?.windowController?.applyRendererSelection(selection)
  }
  /// The Settings (⌘,) window, built lazily on first open and reused after.
  private lazy var settingsWindowController = SettingsWindowController(
    theme: themeMenuController,
    renderer: rendererModeMenuController,
    backend: terminalBackendMenuController,
    onChangeFont: { [weak self] in self?.showFontPicker(nil) },
    onChangeCJKFont: { [weak self] in self?.showCJKFontPicker(nil) },
    onTestNotification: { [weak self] in self?.postSettingsTestNotification() },
    focusStatusSnapshot: {
      NativeNotificationDiagnosticsStore.shared.focusSnapshot()
    },
    onCheckFocusStatus: { completion in
      NativeFocusStatusMonitor.shared.check { snapshot in
        NativeNotificationDiagnosticsStore.shared.updateFocusStatus(snapshot)
        completion(snapshot)
      }
    },
    onControlServerEnabledChanged: { [weak self] enabled in
      self?.windowController?.applyControlServerEnabled(enabled)
    },
    themeStore: themeMenuController.importedThemeStore
  )
  private var updateCheckInFlight = false
  private static let secureKeyboardEntryDefaultsKey = "LabanSecureKeyboardEntry"
  private enum FontPanelPurpose {
    case terminal
    case cjk
  }
  private var fontPanelPurpose: FontPanelPurpose = .terminal
  /// Whether `EnableSecureEventInput()` is currently in effect. The Enable/
  /// Disable calls are reference-counted and process-global, so we track
  /// engagement to keep them balanced and never strand the system in secure
  /// input after Laban deactivates or quits.
  private var secureInputEngaged = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    notificationStateRefresher.refresh()
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
    // Settle the Frosted canvas tint for the active theme before the first
    // window reads transparency settings; a no-op for opaque/custom state.
    frostedPresetThemeFollower.reconcileNow()
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
    MenuCommands.setupMenuBar()

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
      if terminalBackendSelection.backend != .inProcess,
        let fallback = recoverStartupBackendFailure(
          error,
          originalSelection: terminalBackendSelection,
          restoredState: restoredState,
          persistenceSyncEnabled: persistenceSyncEnabled)
      {
        windowController = fallback
      } else {
        showStartupFailure(error)
        return
      }
    }
    windowController?.setWindowScreenshotAuxiliaryWindowsProvider {
      NSApp.windows.filter {
        $0.identifier == SettingsWindowController.windowIdentifier && $0.isVisible
      }
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

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    var options: UNNotificationPresentationOptions = [.banner, .list]
    if notification.request.content.sound != nil {
      options.insert(.sound)
    }
    let optionNames = presentationOptionsDescription(options)
    let userInfo = notification.request.content.userInfo
    NativeNotificationDiagnosticsStore.shared.record(
      eventId: notification.request.identifier,
      tabId: userInfo["tabId"] as? String,
      source: userInfo["source"] as? String,
      category: userInfo["category"] as? String,
      stage: .willPresent,
      outcome: "presented",
      presentationOptions: optionNames)
    EventLog.shared.log(
      "attention.notification.willPresent",
      [
        "identifier": notification.request.identifier,
        "title": notification.request.content.title,
        "body": notification.request.content.body,
        "tabId": userInfo["tabId"] as? String ?? "",
        "source": userInfo["source"] as? String ?? "",
        "category": userInfo["category"] as? String ?? "",
        "options": optionNames,
      ])
    notificationStateRefresher.refresh()
    completionHandler(options)
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    notificationResponseHandler.handle(
      actionIdentifier: response.actionIdentifier,
      userInfo: response.notification.request.content.userInfo,
      completion: completionHandler)
  }

  private func presentationOptionsDescription(
    _ options: UNNotificationPresentationOptions
  ) -> [String] {
    var names: [String] = []
    if options.contains(.banner) { names.append("banner") }
    if options.contains(.list) { names.append("list") }
    if options.contains(.sound) { names.append("sound") }
    if options.contains(.badge) { names.append("badge") }
    return names
  }

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
    if item.action == #selector(captureProfile(_:)) {
      guard !ProfileSessionRecorder.shared.isRecording else { return false }
      let capturing = windowController?.terminalView?.isProfileCaptureActive == true
      return !capturing && ProfileRecorderSettings.findProfilerSocket() != nil
    }
    if item.action == #selector(toggleProfileSessionRecording(_:)) {
      let recording = ProfileSessionRecorder.shared.isRecording
      item.title = ProfileSessionRecorder.menuTitle(recording: recording)
      item.state = recording ? .on : .off
      let captureActive = windowController?.terminalView?.isProfileCaptureActive == true
      return recording
        || (ProfileRecorderSampler.isSupportedPlatform
          && ProfileRecorderSettings.resolve().pattern != nil && !captureActive)
    }
    if item.action == #selector(exportProfileSession(_:)) {
      return ProfileSessionRecorder.shared.hasExportableData
    }
    if item.action == #selector(disableAgentControlServer(_:)) {
      return windowController?.controlServer != nil
    }
    return true
  }

  /// Debug-menu toggle: accumulate CPU samples in the background with no pill.
  @objc func toggleProfileSessionRecording(_ sender: Any?) {
    if ProfileSessionRecorder.shared.isRecording {
      ProfileSessionRecorder.shared.stop()
      return
    }
    do {
      try ProfileSessionRecorder.shared.start()
    } catch {
      showProfileAlert(title: "Could not start CPU recording", message: error.localizedDescription)
    }
  }

  /// Debug-menu entry: export the accumulated session profile and offer viewers.
  @objc func exportProfileSession(_ sender: Any?) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result: Result<URL, Error>
      do {
        result = .success(try ProfileSessionRecorder.shared.exportSnapshot())
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let profileURL):
          self.offerProfileViewer(for: profileURL, title: "Profile exported")
        case .failure(let error):
          self.showProfileAlert(
            title: "Could not export CPU profile", message: error.localizedDescription)
        }
      }
    }
  }

  /// App-menu entry: open the native Settings (⌘,) window.
  @objc func showSettings(_ sender: Any?) {
    settingsWindowController.present()
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

  /// Debug-menu entry: sample the in-process profiler and open the result in a
  /// web flame-graph viewer.
  @objc func captureProfile(_ sender: Any?) {
    guard ProfileRecorderSettings.findProfilerSocket() != nil else {
      showProfileAlert(
        title: "Profiler not running",
        message: ProfileCaptureError.profilerNotRunning.localizedDescription)
      return
    }
    guard windowController?.terminalView?.isProfileCaptureActive != true else { return }

    windowController?.terminalView?.setProfileCaptureActive(true)
    AppLog.app.info("profile capture started")

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result: Result<URL, Error>
      do {
        result = .success(try ProfileCapture.capture())
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.windowController?.terminalView?.setProfileCaptureActive(false)
        switch result {
        case .success(let profileURL):
          AppLog.app.info("profile capture finished: \(profileURL.path)")
          self.offerProfileViewer(for: profileURL)
        case .failure(let error):
          self.showProfileAlert(
            title: "Profile capture failed",
            message: error.localizedDescription)
        }
      }
    }
  }

  private func offerProfileViewer(for profileURL: URL, title: String = "Profile captured") {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText =
      "\(profileURL.lastPathComponent)\n\n"
      + L10n.tr("Saved under ~/Library/Logs/Laban/profiles/. Where should it open?")
    alert.addButton(withTitle: "Speedscope")
    alert.addButton(withTitle: "Firefox Profiler")
    alert.addButton(withTitle: L10n.tr("Reveal in Finder"))
    alert.addButton(withTitle: L10n.tr("Done"))
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      openCapturedProfile(profileURL, viewer: .speedscope)
    case .alertSecondButtonReturn:
      openCapturedProfile(profileURL, viewer: .firefoxProfiler)
    case .alertThirdButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([profileURL])
    default:
      break
    }
  }

  private enum ProfileViewerChoice {
    case speedscope
    case firefoxProfiler
  }

  private func openCapturedProfile(_ profileURL: URL, viewer: ProfileViewerChoice) {
    do {
      switch viewer {
      case .speedscope:
        try ProfileCapture.openInSpeedscope(fileURL: profileURL)
      case .firefoxProfiler:
        try ProfileCapture.openInFirefoxProfiler(fileURL: profileURL)
      }
      AppLog.app.info("opened profile in \(viewer): \(profileURL.path)")
    } catch {
      showProfileAlert(
        title: "Could not open profile viewer",
        message: error.localizedDescription)
    }
  }

  private func showProfileAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L10n.tr("OK"))
    alert.runModal()
  }

  private func showStartupFailure(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = L10n.tr("Laban failed to start")
    alert.informativeText = "\(error)"
    alert.addButton(withTitle: L10n.tr("Quit"))
    alert.runModal()
    NSApp.terminate(nil)
  }

  private func recoverStartupBackendFailure(
    _ error: Error,
    originalSelection: TerminalBackendLaunchConfiguration,
    restoredState: WorkspaceState?,
    persistenceSyncEnabled: Bool
  ) -> MainWindowController? {
    AppLog.app.error(
      "terminal backend \(originalSelection.backend.rawValue) failed at startup: \(error)")
    let shouldFallback: Bool
    if originalSelection.source.isOverride {
      let alert = NSAlert()
      alert.messageText = L10n.tr("Background terminal sessions failed to start")
      alert.informativeText = "\(error)"
      alert.addButton(withTitle: L10n.tr("Use Local Sessions"))
      alert.addButton(withTitle: L10n.tr("Quit"))
      shouldFallback = alert.runModal() == .alertFirstButtonReturn
    } else {
      shouldFallback = true
    }
    guard shouldFallback else { return nil }
    let fallback = TerminalBackendLaunchConfiguration(backend: .inProcess, source: .automatic)
    do {
      terminalBackendMenuController.configure(activeBackend: .inProcess, launchSource: .automatic)
      return try MainWindowController.makeAndShow(
        restoring: restoredState,
        persistenceSyncEnabled: persistenceSyncEnabled,
        terminalBackendSelection: fallback)
    } catch {
      AppLog.app.error("local-session startup fallback failed: \(error)")
      return nil
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    ProfileSessionRecorder.shared.stop()
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
    // Idle-counter sidecar lines are batched in memory; flush so the last
    // ~30s of diagnostics survive quit. No-ops when the tool is disabled.
    IdleCounters.shared.flushPending()
    // M2: snapshot every tracked agent JSONL so a post-quit reboot
    // still has the conversation available even if the user's
    // ~/.claude or ~/.codex directory loses its sessions.
    if RestoreOnLaunchSettings.isEnabled {
      windowController?.agentObserverHost?.flushAll()
    }
    ControlAdvertisement.remove()
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

  @objc func disableAgentControlServer(_ sender: Any?) {
    windowController?.disableControlServer()
    EventLog.shared.log("control.server.disabled")
  }

  @objc func dumpTabJournal(_ sender: Any?) {
    guard let model = windowController?.model else { return }
    let root = RenderJournal.defaultDumpRoot()
      .deletingLastPathComponent()
      .appendingPathComponent("tab-journal")
    do {
      let url = try model.tabJournal.dump(to: root)
      AppLog.app.info("tab journal dumped \(url.path)")
      EventLog.shared.log("tab.journal.dumped", ["path": url.path])
    } catch {
      AppLog.app.error("tab journal dump failed: \(String(describing: error))")
      EventLog.shared.log("tab.journal.dump.failed", ["error": String(describing: error)])
    }
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
  /// persist the choice; size changes apply live through the zoom path,
  /// while family changes still require a restart.
  @objc func showFontPicker(_ sender: Any?) {
    fontPanelPurpose = .terminal
    let panel = NSFontPanel.shared
    let initialFont = Self.currentFontForFontPanel(
      activeFont: windowController?.terminalView?.terminalFontPanelFont,
      persistedName: UserDefaults.standard.string(forKey: FontAtlas.userFontKey),
      size: FontAtlas.persistedTerminalPointSize)
    panel.setPanelFont(initialFont, isMultiple: false)
    NSFontManager.shared.target = self
    NSFontManager.shared.action = #selector(changeFont(_:))
    panel.makeKeyAndOrderFront(self)
  }

  /// Open NSFontPanel for a custom CJK fallback font. Size follows the
  /// primary terminal font; picks are rejected when the font lacks a usable `中` glyph.
  @objc func showCJKFontPicker(_ sender: Any?) {
    fontPanelPurpose = .cjk
    let panel = NSFontPanel.shared
    panel.setPanelFont(Self.currentCJKFontForFontPanel(), isMultiple: false)
    NSFontManager.shared.target = self
    NSFontManager.shared.action = #selector(changeCJKFont(_:))
    panel.makeKeyAndOrderFront(self)
  }

  @objc func changeCJKFont(_ sender: Any?) {
    guard fontPanelPurpose == .cjk else { return }
    let pointSize = FontAtlas.persistedTerminalPointSize
    let current = Self.currentCJKFontForFontPanel()
    let selected = NSFontManager.shared.convert(current)
    let baseFont = CTFontCreateWithName(selected.fontName as CFString, pointSize, nil)
    guard TerminalCJKFontPolicy.isUsableForCJKFallback(baseFont) else {
      NSSound.beep()
      let alert = NSAlert()
      alert.messageText = L10n.tr("Font cannot render CJK text")
      alert.informativeText = String(
        format: L10n.tr(
          "%@ does not provide a usable Han glyph at the terminal size. Pick a font that includes simplified Chinese, traditional Chinese, Japanese, or Korean characters."
        ),
        selected.displayName ?? selected.fontName
      )
      alert.runModal()
      return
    }
    if let preset = Self.matchingPreset(forPostScriptName: selected.fontName) {
      CJKFontSettings.set(preset)
    } else {
      CJKFontSettings.setCustom(postScriptName: selected.fontName)
    }
    AppLog.app.info("CJK font picked: \(selected.fontName)")
    EventLog.shared.log("cjkFont.set", ["name": selected.fontName])
  }

  static func currentCJKFontForFontPanel() -> NSFont {
    let pointSize = FontAtlas.persistedTerminalPointSize
    if CJKFontSettings.current() == .custom,
      let postScriptName = CJKFontSettings.customPostScriptName(),
      let font = NSFont(name: postScriptName, size: pointSize)
    {
      return font
    }
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    if let resolved = TerminalCJKFontPolicy.resolvedPreferenceFont(baseFont: baseFont),
      let font = NSFont(
        name: CTFontCopyPostScriptName(resolved) as String,
        size: pointSize)
    {
      return font
    }
    return NSFont(name: "PingFangSC-Regular", size: pointSize)
      ?? NSFont.systemFont(ofSize: pointSize)
  }

  private static func matchingPreset(forPostScriptName name: String) -> CJKFontPreference? {
    let pointSize = FontAtlas.persistedTerminalPointSize
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    for preset in CJKFontPreference.presetCases {
      guard let resolved = TerminalCJKFontPolicy.resolvedPresetFont(preset, baseFont: baseFont)
      else { continue }
      if (CTFontCopyPostScriptName(resolved) as String) == name {
        return preset
      }
    }
    return nil
  }

  /// AppKit calls this on the font-manager target whenever the user
  /// picks a face or size in NSFontPanel. Persist both. A size-only
  /// change applies live (TerminalBitmapView observes the notification
  /// and re-runs the zoom path); a family change still asks for a
  /// relaunch — it invalidates fallback-font discovery in ways a size
  /// change does not.
  @objc func changeFont(_ sender: Any?) {
    guard fontPanelPurpose == .terminal else { return }
    let fm = NSFontManager.shared
    let current = Self.currentFontForFontPanel(
      activeFont: windowController?.terminalView?.terminalFontPanelFont,
      persistedName: UserDefaults.standard.string(forKey: FontAtlas.userFontKey),
      size: FontAtlas.persistedTerminalPointSize)
    let new = fm.convert(current)
    let activeFontName =
      windowController?.terminalView?.terminalFontPostScriptName ?? current.fontName
    let familyChanged = Self.fontFamilyChanged(
      activeFontPostScriptName: activeFontName,
      selectedFont: new)
    UserDefaults.standard.set(new.fontName, forKey: FontAtlas.userFontKey)
    UserDefaults.standard.set(Double(new.pointSize), forKey: FontAtlas.userFontSizeKey)
    AppLog.app.info("font picked: \(new.fontName) @ \(new.pointSize) pt")
    EventLog.shared.log(
      "font.set", ["name": new.fontName, "size": String(format: "%.1f", new.pointSize)])
    NotificationCenter.default.post(name: FontAtlas.didChangeNotification, object: nil)
    guard familyChanged else { return }
    let sizeText = String(format: "%.0f pt", new.pointSize)
    let alert = NSAlert()
    alert.messageText = String(
      format: L10n.tr("Font set to %@, %@"),
      new.displayName ?? new.fontName,
      sizeText
    )
    alert.informativeText = L10n.tr("Restart Laban to apply.")
    alert.addButton(withTitle: L10n.tr("Restart Now"))  // .firstButtonReturn
    alert.addButton(withTitle: L10n.tr("Later"))  // .secondButtonReturn
    if alert.runModal() == .alertFirstButtonReturn {
      Self.restartApp()
    }
  }

  static func currentFontForFontPanel(
    activeFont: NSFont?,
    persistedName: String?,
    size: CGFloat
  ) -> NSFont {
    if let activeFont {
      return activeFont
    }
    if let persistedName, !persistedName.isEmpty,
      let persisted = NSFont(name: persistedName, size: size)
    {
      return persisted
    }
    return NSFont(name: "Menlo", size: size) ?? NSFont.systemFont(ofSize: size)
  }

  static func fontFamilyChanged(
    activeFontPostScriptName: String,
    selectedFont: NSFont
  ) -> Bool {
    activeFontPostScriptName != selectedFont.fontName
  }

  /// Menu/selector entry for "Restart Laban". The relaunched LabanApp
  /// reconnects to the already-running labpty daemon (which is not a
  /// child of LabanApp), so sessions survive the restart.
  @objc func restartApp(_ sender: Any?) {
    Self.restartApp()
  }

  /// Relaunch our own .app and quit the current instance. The bundle sets
  /// `LSMultipleInstancesProhibited`, so the successor cannot overlap us:
  /// we delegate to a detached helper that waits for this process to exit
  /// and only then launches a fresh instance (see `relaunchCommand`).
  /// There is a brief gap where no window is visible, which is acceptable
  /// for an explicit user action.
  ///
  /// The original argv is forwarded so explicit launch modes such as
  /// `--scroll-debug`, `--terminal-backend`, or `--no-persistence` survive a menu
  /// restart. The restart shortcut is ⌘⌥R (no Shift), so forwarding argv cannot
  /// trip the Shift-to-skip-restore archive hatch.
  static func restartApp(
    launchArguments: [String] = Array(CommandLine.arguments.dropFirst())
  ) {
    let command = relaunchCommand(
      pid: ProcessInfo.processInfo.processIdentifier,
      bundlePath: Bundle.main.bundleURL.path,
      launchArguments: launchArguments
    )
    let task = Process()
    task.executableURL = URL(fileURLWithPath: command.executable)
    task.arguments = command.arguments
    do {
      try task.run()
      NSApp.terminate(nil)
    } catch {
      AppLog.app.error("restart failed: \(error)")
    }
  }

  /// Builds the detached relaunch command for `restartApp`.
  ///
  /// `open -n` is a no-op while we are alive because the bundle prohibits
  /// multiple instances: it re-activates the dying process, and once we
  /// terminate nothing relaunches (the app appears to merely quit). So the
  /// helper polls until our pid is gone, then launches a fresh instance
  /// when no instance is running and the launch is permitted. The wait is
  /// bounded (~10s) so a stuck termination cannot hang the relaunch.
  static func relaunchCommand(
    pid: Int32,
    bundlePath: String,
    launchArguments: [String] = []
  ) -> (executable: String, arguments: [String]) {
    let openArguments = launchArguments.isEmpty ? [] : ["--args"] + launchArguments
    let script =
      "old_pid=$1; app_path=$2; shift 2; "
      + "n=0; while /bin/kill -0 \"$old_pid\" 2>/dev/null && [ $n -lt 100 ]; do "
      + "/bin/sleep 0.1; n=$((n+1)); done; exec /usr/bin/open \"$app_path\" \"$@\""
    return ("/bin/sh", ["-c", script, "laban-relaunch", "\(pid)", bundlePath] + openArguments)
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
        title: L10n.tr("Update check failed"),
        message: error.localizedDescription
      )
    }
  }

  func showAvailableUpdate(_ manifest: UpdateManifest) {
    let alert = NSAlert()
    alert.messageText = String(format: L10n.tr("Laban %@ is available"), manifest.latest)
    var message = String(format: L10n.tr("You are running %@."), BuildInfo.version)
    if let notes = manifest.notes, !notes.isEmpty {
      message += "\n\n\(notes)"
    }
    alert.informativeText = message
    alert.addButton(withTitle: L10n.tr("Open Download"))
    alert.addButton(withTitle: L10n.tr("Not Now"))
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
    alert.addButton(withTitle: L10n.tr("OK"))
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

  private func postSettingsTestNotification() {
    let event = AttentionNotificationEvent(
      tabId: "settings",
      source: .osc,
      category: .needsAction,
      title: "Laban",
      body: "Native notification test",
      dedupeKey: "settings-test")
    settingsNotificationPoster.post(
      event: event,
      soundEnabled: AttentionNotificationSettings.soundEnabled
    ) { decision in
      EventLog.shared.log(
        "attention.notification.test",
        [
          "eventId": decision.event.id,
          "action": decision.action.rawValue,
          "reason": decision.suppressionReason?.rawValue ?? "",
        ])
    }
  }
}
