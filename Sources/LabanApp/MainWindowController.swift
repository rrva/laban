import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore

final class MainWindowController: NSWindowController {
  /// The persistence coordinator owns its weak ref to the AppModel and
  /// debounces saves on a background queue. Kept on the window
  /// controller so AppDelegate can call `flushSync()` in
  /// `applicationWillTerminate` without having to walk back to the
  /// model.
  private(set) var persistenceCoordinator: PersistenceCoordinator?
  private(set) var model: AppModel?
  private(set) var terminalView: TerminalBitmapView?
  private(set) var terminalBackend: TerminalSessionBackend = .inProcess
  private(set) var terminalSessionClient: TerminalSessionClient?
  private(set) var sessionCoordinator: AppSessionCoordinator?
  /// Per-tab agent-session detector + JSONL mirror orchestrator. Kept
  /// alive on the window controller so the detector timers don't
  /// stop when AppDelegate's local refs go out of scope.
  private(set) var agentObserverHost: AgentObserverHost?
  /// Auto-update checker. Strong ref so its timer + wake observers
  /// outlive `makeAndShow`'s local scope.
  private(set) var updateAutoChecker: UpdateAutoChecker?
  /// Loopback HTTP control surface for diagnosing the overlay scroll-indicator
  /// bug on a live headful instance. Only created when `--scroll-debug` /
  /// `LABAN_SCROLL_DEBUG` is set; strong ref so its accept thread outlives
  /// `makeAndShow`'s local scope. See `ScrollDebugServer`.
  private(set) var scrollDebugServer: ScrollDebugServer?

  static func makeAndShow(
    restoring restoredState: WorkspaceState? = nil,
    persistenceSyncEnabled: Bool = true,
    terminalBackendSelection: TerminalBackendLaunchConfiguration? = nil
  ) throws
    -> MainWindowController
  {
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellW = Int(cellSize.width)
    let cellH = Int(cellSize.height)

    let sidebarWidth = SidebarLayout.defaultWidth
    let insets = TerminalBitmapView.contentInsets
    let viewW: CGFloat = 1200
    // Bumped by `titlebarReservedHeight` so the terminal grid keeps roughly
    // the same default row count after the transparent-titlebar change ate
    // 28 pt of top padding.
    let viewH: CGFloat = 760 + TerminalBitmapView.titlebarReservedHeight

    let termW = max(1, Int(viewW - sidebarWidth - insets.left - insets.right))
    let termH = max(1, Int(viewH - insets.top - insets.bottom))
    var size = LabanTerminalSize()
    size.rows = Int32(termH / cellH)
    size.cols = Int32(termW / cellW)

    // Install the OSC 133 shell-integration overlay once per process and
    // thread it into every shell Laban spawns — new tabs and restored tabs
    // alike. Each shell needs a different launch shape: zsh/fish via env
    // overrides (ZDOTDIR / XDG_DATA_DIRS), bash via an explicit
    // `--rcfile` argv. A shell without an overlay or a failed install yields
    // a passthrough launch, so the shell starts unchanged.
    // See `ShellIntegrationOverlay` and `docs/product/spec.md` §7.
    let shellLaunch = Self.installShellIntegrationOverlay()
    let backendSelection = try terminalBackendSelection ?? Self.configuredAppTerminalBackend()
    let terminalBackend = backendSelection.backend
    let restoredCwdByTabId = Self.restoredCwdByTabId(from: restoredState)
    let sessionCoordinator = try Self.makeSessionCoordinator(
      backend: terminalBackend,
      shellLaunch: shellLaunch,
      cwdByTabId: restoredCwdByTabId)

    let model = try AppModel(
      initialSize: size,
      sessionFactory: {
        switch terminalBackend {
        case .inProcess:
          return try Session.realShell(
            size: $0,
            environment: shellLaunch.environmentOverrides,
            launchArgv: shellLaunch.argv)
        case .laband:
          return try Session.fixture(size: $0)
        case .labpty:
          return try Session.parserOnly(size: $0)
        }
      }
    )
    let isPersistenceEnabled = {
      persistenceSyncEnabled && RestoreOnLaunchSettings.isEnabled
    }

    // The transcript host owns one TranscriptWriter per tab. When
    // persistence sync is enabled, hook this up BEFORE any tab work
    // so the default tab created by AppModel.init gets a writer too.
    // With --no-persistence we leave the delegate nil, so no
    // workspace/transcript/agent persistence layer is wired.
    let transcriptHost: TranscriptHost?
    if persistenceSyncEnabled {
      let host = TranscriptHost(isEnabled: isPersistenceEnabled)
      model.transcriptDelegate = host
      transcriptHost = host
    } else {
      transcriptHost = nil
    }
    model.restoreFailureLogger = { tabId, error in
      AppLog.app.error("restored tab \(tabId) failed: \(String(describing: error))")
    }

    // Restore-time factory: build a deferred-spawn session in the
    // persisted cwd, then start a fresh shell. Historical transcript
    // bytes and persisted launch commands remain diagnostic/future
    // pivot data only; automatic restore must not paint old output
    // or replay generic terminal commands into a live terminal.
    model.restoredDeferredSessionFactory = { spec in
      if terminalBackend == .laband || terminalBackend == .labpty {
        return try Session.fixture(size: spec.size)
      }
      let session = try Session.makeDeferred(
        size: spec.size, cwd: spec.cwd, environment: shellLaunch.environmentOverrides)
      // Agent tabs that were running at quit launch the shell with the
      // resume command as its own argument (`$SHELL -l -i -c '<resume>;
      // exec $SHELL -l -i'`) instead of typing it into a live prompt. The
      // activity check runs against the persisted shellPid, so its
      // answer does not depend on the freshly spawned shell.
      var injection = RestoreLaunchPlanner.instruction(
        for: spec,
        activityChecker: ProcessTreeRestoreSessionActivityChecker()
      ).spawnInjection
      // Keep the resumed shell instrumented: bash carries its OSC 133
      // overlay in argv (`--rcfile`), so the trailing `exec` after the agent
      // exits must re-apply it. zsh/fish carry it in env (inherited by exec),
      // so resumeExecArgs is nil and the default `-l -i` stands.
      if let inj = injection, let execArgs = shellLaunch.resumeExecArgs {
        injection = RestoreShellInjection(
          command: inj.command, shellPath: inj.shellPath, execArgs: execArgs)
      }
      let rc = session.startSpawn(
        overrideCwd: spec.cwdFallbackApplied ? spec.cwd : nil,
        injection: injection,
        launchArgv: shellLaunch.argv)
      if rc != 0 {
        // Spawn failed — log and surface a banner. The session keeps
        // its VT parser so the tab body is renderable; the user sees
        // a banner where the shell prompt would have been.
        AppLog.app.error(
          "restored tab \(spec.tabId) failed to spawn shell (cwd=\(spec.cwd))")
        let warning = "\r\n[restore failed: shell did not start in \(spec.cwd)]\r\n"
        _ = session.feedOutput(Array(warning.utf8))
      }
      return session
    }
    // Simple fallback for restored tabs that don't have a deferred
    // factory (used by headless tests that swap the factory out).
    model.restoredSessionFactory = { size, cwd in
      switch terminalBackend {
      case .laband, .labpty:
        return try Session.parserOnly(size: size)
      case .inProcess:
        return try Session.realShell(
          size: size, cwd: cwd,
          environment: shellLaunch.environmentOverrides,
          launchArgv: shellLaunch.argv)
      }
    }

    // New tabs (⌘T) open in the active tab's reported working directory — its
    // OSC 7 / metadata cwd, or its live process cwd — so a new tab lands where
    // you are instead of at the launcher's directory. Same spawn shape as the
    // restore factory; the cwd is meaningful only for the in-process backend.
    model.newTabSessionFactory = { size, cwd in
      switch terminalBackend {
      case .laband, .labpty:
        return try Session.parserOnly(size: size)
      case .inProcess:
        return try Session.realShell(
          size: size, cwd: cwd,
          environment: shellLaunch.environmentOverrides,
          launchArgv: shellLaunch.argv)
      }
    }

    // The default tab created by AppModel.init() needs its writer
    // attached too — its session was constructed before the delegate
    // was assigned. Attach explicitly here.
    if let transcriptHost {
      for (tab, session) in model.allSessions() {
        transcriptHost.attachTranscriptWriter(to: session, tabId: tab.id)
      }
    }

    // Rebuild the tab list from `workspace.json` BEFORE creating the
    // terminal view so the user never sees a flash of the default tab.
    // `replaceTabs(from:)` closes the auto-created first session and
    // spawns one fresh shell per persisted tab in its prior cwd.
    if let restoredState, !restoredState.windows.isEmpty {
      model.replaceTabs(from: restoredState)
    }
    // Restore can leave zero tabs (window had no persisted tabs, or
    // every restore spawn threw). The app must always show at least
    // one tab, so fall back to a fresh default-shell tab — the same
    // path the "+" titlebar button uses.
    if model.tabs.isEmpty {
      _ = try? model.createTab()
    }
    sessionCoordinator?.onSessionDirty = { [weak model] sessionId in
      model?.onSessionDirty?(sessionId)
    }
    try sessionCoordinator?.ensureSessions(for: model.tabs, in: model, size: model.terminalSize)
    // After the legitimate tabs have attached or created their daemon
    // sessions, sweep anything else still in laband. With
    // Restore-on-Launch off the workspace forgets earlier tab ids, so
    // without this the daemon would accumulate live shells forever.
    sessionCoordinator?.sweepOrphanedSessions()

    // labpty is the upgrade-proof tier: a live session with no matching
    // tab is almost always this user's own shell from a launch whose
    // workspace.json was lost (a Shift-archive wipe, a crash before
    // save). Surface those rather than silently dropping them, and offer
    // to adopt them back as tabs. Done before the terminal view is built
    // so adopted tabs render in the first frame.
    if terminalBackend == .labpty {
      Self.promptToAdoptUnclaimedLabptySessions(coordinator: sessionCoordinator, model: model)
    }

    let termView = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellW,
      cellHeight: cellH,
      sessionCoordinator: sessionCoordinator
    )
    termView.frame = NSRect(x: 0, y: 0, width: viewW, height: viewH)

    let mask: NSWindow.StyleMask = [
      .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
    ]
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: viewW, height: viewH),
      styleMask: mask,
      backing: .buffered,
      defer: false
    )
    window.title = "Laban"
    // Transparent titlebar with the contentView extending behind it; the
    // sidebar and terminal-area background rects fill the reserved strip so
    // the chrome looks continuous with the terminal. Traffic lights stay
    // interactive because AppKit composites them over the contentView.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    // Container view hosts the terminal plus a small overlay badge. The
    // terminal stays the full size; the badge floats in the bottom-left,
    // sized to its content. Using a sibling instead of a TerminalBitmapView
    // subview avoids z-order / hit-test issues with the Metal-backed
    // terminal layer.
    let containerView = NSView(frame: NSRect(x: 0, y: 0, width: viewW, height: viewH))
    containerView.autoresizesSubviews = true
    termView.autoresizingMask = [.width, .height]
    containerView.addSubview(termView)
    let updateBadge = UpdateBadgeView(
      frame: NSRect(
        x: UpdateBadgeView.cornerInset,
        y: UpdateBadgeView.cornerInset,
        width: 64,
        height: UpdateBadgeView.preferredHeight))
    updateBadge.autoresizingMask = [.maxXMargin, .maxYMargin]
    containerView.addSubview(updateBadge)

    // Overlay scroll indicator: invisible when the viewport is at the live
    // bottom, fades in when the user scrolls back into history. Sibling of
    // termView (same z-order pattern as updateBadge) so the Metal layer
    // compositing stays untouched.
    let scrollIndicator = TerminalScrollIndicatorView(
      frame: NSRect(x: 0, y: 0, width: viewW, height: viewH))
    scrollIndicator.autoresizingMask = [.width, .height]
    containerView.addSubview(scrollIndicator)
    termView.onViewportChanged = {
      [weak scrollIndicator] offset, total, vp, altScreen, mouseTracking in
      scrollIndicator?.applyViewport(
        viewportOffset: offset, totalRows: total, viewportRows: vp,
        isAltScreen: altScreen, isMouseTracking: mouseTracking)
    }
    termView.onViewportUnavailable = { [weak scrollIndicator] in
      scrollIndicator?.reset()
    }
    // Drag-to-scrub: dragging the overlay thumb maps the pointer to an absolute
    // scroll offset (spec.md §scrollback). The indicator reports a history
    // fraction; the terminal owns the viewport and jumps there.
    scrollIndicator.onScrubToFraction = { [weak termView] fraction in
      termView?.scrubViewportToHistoryFraction(fraction)
    }
    termView.onActiveTabChanged = { [weak scrollIndicator] in
      scrollIndicator?.reset()
    }

    window.contentView = containerView
    window.center()
    window.makeKeyAndOrderFront(nil)

    // "+" new-tab button as a titlebar accessory next to the traffic
    // lights. Frees a full row from the sidebar without sacrificing
    // discoverability — the button is always visible at a fixed screen
    // position regardless of how many tabs are open.
    let plusButton = NSButton(
      title: "+",
      target: nil,
      action: #selector(TerminalBitmapView.newTab(_:))
    )
    plusButton.bezelStyle = .smallSquare
    plusButton.isBordered = false
    plusButton.font = NSFont.systemFont(ofSize: 16, weight: .light)
    plusButton.contentTintColor = .secondaryLabelColor
    plusButton.translatesAutoresizingMaskIntoConstraints = false
    let accessoryHost = NSView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    accessoryHost.addSubview(plusButton)
    NSLayoutConstraint.activate([
      plusButton.centerXAnchor.constraint(equalTo: accessoryHost.centerXAnchor),
      plusButton.centerYAnchor.constraint(equalTo: accessoryHost.centerYAnchor),
      plusButton.widthAnchor.constraint(equalToConstant: 24),
      plusButton.heightAnchor.constraint(equalToConstant: 24),
    ])
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = accessoryHost
    accessory.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(accessory)

    let controller = MainWindowController(window: window)
    controller.model = model
    controller.terminalView = termView
    controller.terminalBackend = terminalBackend
    controller.terminalSessionClient =
      sessionCoordinator?.terminalClient
      ?? (terminalBackend == .inProcess ? InProcessTerminalSessionClient() : nil)
    controller.sessionCoordinator = sessionCoordinator

    let autoChecker = UpdateAutoChecker(badge: updateBadge) { manifest in
      (NSApp.delegate as? AppDelegate)?.showAvailableUpdate(manifest)
    }
    autoChecker.start()
    controller.updateAutoChecker = autoChecker

    // OSC 9 desktop notifications (e.g. the Codex agent finishing a turn or
    // asking for approval) -> native macOS banner. AppModel fires
    // onAgentNotification on the main queue. The poster is retained by the
    // closure, which the model owns; suppress the banner for the tab already in
    // front of the user. Headless parity lives in HeadlessDebugRuntime, which
    // records the same notification as a debug event.
    let agentNotificationPoster = AgentNotificationPoster()
    agentNotificationPoster.isTabFrontmost = { [weak model] tabId in
      guard NSApplication.shared.isActive, let model else { return false }
      return model.tabs.first(where: { $0.isActive })?.id == tabId
    }
    model.onAgentNotification = { [weak model] tabId, text in
      let title = model?.tabs.first(where: { $0.id == tabId })?.title
      agentNotificationPoster.post(tabId: tabId, tabTitle: title, text: text)
    }
    // Returning to the app means the user is now looking at the active tab, so
    // clear its notification badge (peers clear on viewing the tab, not on
    // every window-focus change of background tabs).
    NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak model] _ in
      model?.markActiveTabNotificationSeen()
    }

    // OSC 52 clipboard bridge: a program copying via `ESC ] 52 ; c ; <base64>`
    // (e.g. a coding agent over SSH) lands on the macOS pasteboard. AppModel
    // fires onClipboardWrite on the main queue. Read replies are gated by
    // model.osc52ReadEnabled (off by default); the provider is wired so flipping
    // it on works without re-plumbing. Headless parity lives in
    // HeadlessDebugRuntime against its debug clipboard.
    model.onClipboardWrite = { _, data in
      TerminalClipboard.writeOSC52(data, to: .general)
    }
    model.clipboardReadProvider = {
      TerminalClipboard.osc52ReadData(.general)
    }

    if persistenceSyncEnabled {
      // Persistence is wired AFTER the optional restore so the initial
      // restored snapshot does not bounce back through the coordinator.
      // `attach(_:)` registers as the model's `onWorkspaceMutation`
      // subscriber; subsequent mutations debounce-save through
      // `PersistenceStore`. The toggle gate (`RestoreOnLaunchSettings`)
      // is checked inside the coordinator on every save and load attempt,
      // so flipping the menu item off makes both no-op silently.
      let coordinator = PersistenceCoordinator(isEnabled: isPersistenceEnabled)
      coordinator.transcriptHost = transcriptHost
      coordinator.attach(model)
      controller.persistenceCoordinator = coordinator

      // Agent autoresume: M2. Per-tab detector polls for claude/codex
      // descendants and captures the session id from the open .jsonl
      // file; mirror snapshots that file on lifecycle events and on a
      // 5-minute periodic timer while the agent is alive. Attached
      // here so the first default tab (and any restored ones) get a
      // detector right away. Note that detectors short-circuit when
      // the session has no real PID (fixture mode in tests), so this
      // is safe even when the productive app delegate is shimmed.
      let mirror = AgentJSONLMirror(isEnabled: isPersistenceEnabled)
      let observerHost = AgentObserverHost(
        appModel: model, mirror: mirror,
        isEnabled: isPersistenceEnabled)
      controller.agentObserverHost = observerHost
      model.onTabCreated = { [weak observerHost] tabId, session in
        observerHost?.attach(session: session, tabId: tabId)
      }
      model.onTabClosed = { [weak observerHost] tabId in
        observerHost?.detach(tabId: tabId)
      }
      for (tab, session) in model.allSessions() {
        observerHost.attach(session: session, tabId: tab.id)
      }
      if terminalBackend == .inProcess, let restoredState, !restoredState.windows.isEmpty {
        Self.applyRestoreLaunchPlans(
          for: restoredState, model: model)
      }

      // Schedule one save so the persisted state reflects the just-spawned
      // (or just-restored) tab list within the debounce window. Without
      // this, a user who quits before causing any further mutation would
      // leave `workspace.json` unchanged from its prior contents.
      coordinator.scheduleSave()
    }

    // Live scroll-indicator diagnostics. Opt-in via `--scroll-debug[=port]` or
    // `LABAN_SCROLL_DEBUG=1` (default port 8787). Arms the ScrollDiagnostics
    // trace (in-memory ring + JSONL under ~/Library/Logs/Laban/scroll-trace/)
    // and starts a loopback HTTP control surface so the bug can be driven and
    // inspected on a real window: feed a streaming program, read the viewport
    // time-series, snap to bottom, screenshot. Never started on a normal launch.
    if let config = ScrollDebugServer.Config.fromLaunchEnvironment() {
      let server = ScrollDebugServer(model: model, termView: termView, indicator: scrollIndicator)
      server.start(config: config)
      controller.scrollDebugServer = server
    }

    return controller
  }

  var currentRendererSelection: RendererSelection {
    terminalView?.rendererSelection ?? RendererSelection.persisted()
  }

  func applyRendererSelection(_ selection: RendererSelection) {
    terminalView?.applyRendererSelection(selection)
  }

  /// Launch-time recovery for the labpty tier. If the daemon is holding
  /// live sessions that no restored tab claims, ask the user whether to
  /// adopt them back as tabs. Adopt-only by design: there is no owner
  /// affinity in the labpty descriptor yet, so a concurrent second
  /// instance's sessions would also look unclaimed — adopting is
  /// non-destructive, terminating would not be. No-op when nothing is
  /// unclaimed (the normal reattach-by-id path leaves zero orphans).
  private static func promptToAdoptUnclaimedLabptySessions(
    coordinator: AppSessionCoordinator?,
    model: AppModel
  ) {
    guard let coordinator else { return }
    let unclaimed = coordinator.unclaimedLabptySessions(knownTabIds: Set(model.tabs.map(\.id)))
    guard !unclaimed.isEmpty else { return }

    AppLog.app.notice("labpty desync: \(unclaimed.count) unclaimed live session(s) at launch")
    let alert = NSAlert()
    alert.messageText =
      unclaimed.count == 1
      ? "A background terminal session has no tab"
      : "\(unclaimed.count) background terminal sessions have no tabs"
    alert.informativeText =
      "Laban found live shell session(s) from a previous run that aren't open in this "
      + "window. Adopt them to reopen them as tabs, or ignore to leave them running in "
      + "the background."
    alert.addButton(withTitle: "Adopt")  // .alertFirstButtonReturn
    alert.addButton(withTitle: "Ignore")  // .alertSecondButtonReturn
    guard alert.runModal() == .alertFirstButtonReturn else {
      AppLog.app.notice("labpty desync: ignored \(unclaimed.count) unclaimed session(s)")
      return
    }
    let adopted = coordinator.adoptLabptySessions(unclaimed, in: model, size: model.terminalSize)
    AppLog.app.notice("labpty desync: adopted \(adopted.count) session(s) as tabs")
  }

  /// Post-spawn restore step for the `.prefillPrompt` case only:
  ///   - `.executeNow` is handled at spawn — the shell is launched as
  ///     `$SHELL -l -i -c '<resume>; exec $SHELL -l -i'`, so the resume runs
  ///     as the shell's own argument with no typed echo. Nothing to do
  ///     here.
  ///   - `.prefillPrompt(cmd)` writes `cmd` without a newline; the user
  ///     sees the resume command at the prompt and presses ENTER to run
  ///     it. This still has to be typed into a live interactive shell
  ///     because `-c` would run it immediately rather than sit at the
  ///     prompt.
  ///   - `.noPrefill` is a no-op.
  ///
  /// Called once during restore, after `replaceTabs(from:)` has
  /// rebuilt the tab list and spawned each fresh shell.
  private static func applyRestoreLaunchPlans(
    for state: WorkspaceState, model: AppModel
  ) {
    guard let window = state.windows.first else { return }
    let activityChecker = ProcessTreeRestoreSessionActivityChecker()
    for tabState in window.tabs {
      let instruction = RestoreLaunchPlanner.instruction(
        for: tabState,
        activityChecker: activityChecker)
      guard case .prefillPrompt(let command) = instruction else { continue }
      guard let session = model.session(forTab: tabState.id) else { continue }
      _ = session.write(Array(command.utf8))
    }
  }

  /// Generate the OSC 133 rc-overlay for the user's login shell once per
  /// process and return the env overrides that activate it. The overlay
  /// lives under a unique per-process temp directory (worktree-isolation
  /// forbids a global fixed path); the OS reclaims it. Failures degrade to
  /// no overrides — the shell then launches without integration rather than
  /// failing to spawn.
  private static func installShellIntegrationOverlay() -> ShellIntegrationLaunch {
    let shellPath = LoginShell.resolvePath()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-shell-integration-\(UUID().uuidString)", isDirectory: true)
    do {
      return try ShellIntegrationOverlay.install(
        shellPath: shellPath,
        baseDirectory: base,
        environment: ProcessInfo.processInfo.environment)
    } catch {
      AppLog.app.error("shell integration overlay install failed: \(String(describing: error))")
      return .passthrough
    }
  }

  func detachTerminalSessions() {
    sessionCoordinator?.detach()
  }

  static func configuredAppTerminalBackend(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard
  ) throws -> TerminalBackendLaunchConfiguration {
    try TerminalBackendSettings.resolve(
      environment: environment,
      arguments: arguments,
      defaults: defaults,
      automaticBackend: automaticTerminalBackend())
  }

  private static func automaticTerminalBackend() -> TerminalSessionBackend {
    if labptyExecutableURL() != nil {
      return .labpty
    }
    if labandExecutableURL() != nil {
      return .laband
    }
    return .inProcess
  }

  private static func makeSessionCoordinator(
    backend: TerminalSessionBackend,
    shellLaunch: ShellIntegrationLaunch,
    cwdByTabId: [Tab.ID: String]
  ) throws -> AppSessionCoordinator? {
    switch backend {
    case .inProcess:
      return nil
    case .laband:
      let setup = try connectOrStartLaband()
      return AppSessionCoordinator(
        client: setup.client,
        shellLaunch: shellLaunch,
        cwdByTabId: cwdByTabId,
        labandProcess: setup.process
      )
    case .labpty:
      let setup = try connectOrStartLabpty()
      return AppSessionCoordinator(
        labptyClient: setup.client,
        shellLaunch: shellLaunch,
        cwdByTabId: cwdByTabId,
        labptyProcess: setup.process
      )
    }
  }

  private static func connectOrStartLabpty() throws -> (
    client: LabptyTerminalSessionClient, process: Process?
  ) {
    let environment = ProcessInfo.processInfo.environment
    let baseURL = PersistenceStore.defaultBaseURL().appendingPathComponent(
      "labpty", isDirectory: true)
    let logURL = baseURL.appendingPathComponent("logs", isDirectory: true)
    let shmURL =
      environment["LABAN_LABPTY_SHM_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? baseURL.appendingPathComponent("shm", isDirectory: true)
    let socketPath =
      environment["LABAN_LABPTY_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
      ?? baseURL.appendingPathComponent("labpty.sock").path

    // Spawn labpty on demand if it is not already listening, and hand the
    // long-lived client a hook that re-runs the same spawn if the connection
    // drops mid-session (a labpty crash). labpty keeps its session catalog in
    // memory only, so this brings up a fresh, empty daemon rather than
    // restoring sessions — the point is that the app keeps working instead of
    // wedging against a dead socket.
    let process = try ensureLabptyDaemonRunning(
      socketPath: socketPath, shmURL: shmURL, baseURL: baseURL, logURL: logURL)
    let client = try LabptyTerminalSessionClient(
      socketPath: socketPath,
      ensureDaemonRunning: {
        _ = try Self.ensureLabptyDaemonRunning(
          socketPath: socketPath, shmURL: shmURL, baseURL: baseURL, logURL: logURL)
      })
    _ = try client.hello()
    return (client, process)
  }

  /// Ensure a labpty daemon is listening at `socketPath`, spawning one if the
  /// socket is not currently reachable. Returns the spawned `Process`, or nil
  /// when an existing daemon already answered. Shared by first launch and the
  /// mid-session self-heal hook handed to `LabptyTerminalSessionClient`.
  @discardableResult
  private static func ensureLabptyDaemonRunning(
    socketPath: String,
    shmURL: URL,
    baseURL: URL,
    logURL: URL
  ) throws -> Process? {
    if labptyDaemonIsReachable(socketPath: socketPath) { return nil }

    guard let executableURL = labptyExecutableURL() else {
      throw TerminalSessionClientError.protocolError(
        "labpty backend requested but no labpty executable is available")
    }

    try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let stdoutURL = logURL.appendingPathComponent("stdout.log")
    let stderrURL = logURL.appendingPathComponent("stderr.log")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "--socket", socketPath,
      "--shm-dir", shmURL.path,
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
    process.standardError = try FileHandle(forWritingTo: stderrURL)
    try process.run()

    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if !process.isRunning {
        throw TerminalSessionClientError.protocolError(
          "labpty exited before socket was ready; see \(stderrURL.path)")
      }
      if labptyDaemonIsReachable(socketPath: socketPath) {
        return process
      }
      usleep(50_000)
    }

    process.terminate()
    throw TerminalSessionClientError.protocolError(
      "timed out waiting for labpty socket at \(socketPath)")
  }

  /// True when a labpty daemon currently accepts connections on `socketPath`.
  private static func labptyDaemonIsReachable(socketPath: String) -> Bool {
    (try? LabptyTerminalSessionClient(socketPath: socketPath)) != nil
  }

  private static func connectOrStartLaband() throws -> (
    client: LabandTerminalSessionClient, process: Process?
  ) {
    let environment = ProcessInfo.processInfo.environment
    let paths = LabandProductPaths.default()
    try paths.createDirectories()
    let socketPath =
      environment["LABAN_LABAND_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
      ?? paths.labandDirectoryURL.appendingPathComponent("laband.sock").path

    if let client = try? LabandTerminalSessionClient(socketPath: socketPath) {
      _ = try client.hello()
      return (client, nil)
    }

    guard let executableURL = labandExecutableURL() else {
      throw TerminalSessionClientError.protocolError(
        "laband backend requested but no laband executable is available")
    }

    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
      withIntermediateDirectories: true)

    let stdoutURL = paths.logDirectoryURL.appendingPathComponent("stdout.log")
    let stderrURL = paths.logDirectoryURL.appendingPathComponent("stderr.log")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "--socket", socketPath,
      "--journal", paths.journalDirectoryURL.path,
    ]
    process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
    process.standardError = try FileHandle(forWritingTo: stderrURL)
    try process.run()

    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if !process.isRunning {
        throw TerminalSessionClientError.protocolError(
          "laband exited before socket was ready; see \(stderrURL.path)")
      }
      do {
        let client = try LabandTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return (client, process)
      } catch {
        lastError = error
        usleep(50_000)
      }
    }

    process.terminate()
    throw TerminalSessionClientError.protocolError(
      "timed out connecting to laband at \(socketPath): \(String(describing: lastError))")
  }

  private static func labandExecutableURL() -> URL? {
    if let raw = ProcessInfo.processInfo.environment["LABAN_LABAND_BIN"], !raw.isEmpty {
      let url: URL
      if raw.hasPrefix("/") {
        url = URL(fileURLWithPath: raw)
      } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent(raw)
      }
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    if let bundled = bundledLabandExecutableURL() {
      return bundled
    }
    let devURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/laband")
    return FileManager.default.isExecutableFile(atPath: devURL.path) ? devURL : nil
  }

  private static func labptyExecutableURL() -> URL? {
    if let raw = ProcessInfo.processInfo.environment["LABAN_LABPTY_BIN"], !raw.isEmpty {
      let url: URL
      if raw.hasPrefix("/") {
        url = URL(fileURLWithPath: raw)
      } else {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .appendingPathComponent(raw)
      }
      return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    let bundled = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("labpty", isDirectory: false)
    if FileManager.default.isExecutableFile(atPath: bundled.path) {
      return bundled
    }
    let devURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent(".build/debug/labpty")
    return FileManager.default.isExecutableFile(atPath: devURL.path) ? devURL : nil
  }

  private static func bundledLabandExecutableURL() -> URL? {
    let url = Bundle.main.bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("MacOS", isDirectory: true)
      .appendingPathComponent("laband", isDirectory: false)
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  private static func restoredCwdByTabId(from state: WorkspaceState?) -> [Tab.ID: String] {
    guard let state, let window = state.windows.first else { return [:] }
    return Dictionary(uniqueKeysWithValues: window.tabs.map { ($0.id, $0.cwd) })
  }
}
