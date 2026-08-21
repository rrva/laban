import AppKit
import LabanControl
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
  private(set) var transparencyCoordinator: TerminalWindowTransparencyCoordinator?
  var terminalBackgroundImageStore: TerminalBackgroundImageStore?
  var terminalBackgroundFixtureRootURL: URL?
  private(set) var terminalBackend: TerminalSessionBackend = .inProcess
  private(set) var terminalSessionClient: TerminalSessionClient?
  private(set) var sessionCoordinator: AppSessionCoordinator?
  /// Per-tab agent-session detector + JSONL mirror orchestrator. Kept
  /// alive on the window controller so the detector timers don't
  /// stop when AppDelegate's local refs go out of scope.
  private(set) var agentObserverHost: AgentObserverHost?
  /// Loopback HTTP control surface for diagnosing the overlay scroll-indicator
  /// bug on a live headful instance. Only created when `--scroll-debug` is set;
  /// strong ref so its accept thread outlives `makeAndShow`'s local scope. See
  /// `ScrollDebugServer`.
  private(set) var scrollDebugServer: ScrollDebugServer?
  /// The overlay scroll indicator (scrollback pill + thumb). Held so the pill's
  /// text source can be re-pointed at the vector glyph renderer when that
  /// renderer is selected, and reverted on a live switch back.
  private weak var scrollIndicator: TerminalScrollIndicatorView?
  /// Lazily-built vector text rasterizer shared by chrome that opts into
  /// vector-rendered glyphs (currently the scrollback pill). Nil if no Metal
  /// device is available; built once and reused.
  private lazy var vectorTextRasterizer: VectorTextRasterizer? = VectorTextRasterizer()
  /// Env-gated Phase 0 loopback control server for live GUI state/actions.
  private(set) var controlServer: LabanControlServer?
  private var windowScreenshotAuxiliaryWindowsProvider: () -> [NSWindow] = { [] }
  private(set) var controlSecurityCoordinator: ControlSecurityCoordinator?
  private(set) var controlSessionLaunchCoordinator = ControlSessionLaunchCoordinator()
  private var liveControlRouter: LiveIntentRouter?
  private var debugReduceTransparencyOverride: Bool?

  func accessibilityDebugState() -> [String: Any]? {
    terminalView?.debugAccessibilityState()
  }

  // MARK: Transparency control/debug adapter seam

  func terminalTransparencyStatus() -> TerminalWindowTransparencyStatus? {
    transparencyCoordinator?.status
  }

  func terminalTransparencyDiagnostics() -> TerminalTransparencyDiagnostics? {
    terminalView?.transparencyDiagnostics
  }

  func terminalTransparencyDebugResponse() -> TerminalTransparencyDebugResponse? {
    guard let status = terminalTransparencyStatus(),
      let diagnostics = terminalTransparencyDiagnostics(),
      let rendererStatus = terminalView?.transparencyRendererStatus
    else { return nil }
    let effectiveAppearance =
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? "darkAqua" : "aqua"
    return TerminalTransparencyDebugResponse(
      requestedOpacity: status.requested.backgroundOpacity,
      effectiveOpacity: status.effective.backgroundOpacity,
      requestedBlur: status.requested.backgroundBlur,
      effectiveBlur: status.effective.backgroundBlur,
      requestedBackdropStyle: status.requested.backdropStyle.rawValue,
      effectiveBackdropStyle: status.effective.backdropStyle.rawValue,
      backgroundImageScaling: status.requested.backgroundImageScaling.rawValue,
      backgroundImageState: status.backgroundImageAvailability.rawValue,
      backgroundImageIdentifier: status.backgroundImageIdentifier,
      backgroundImagePixelWidth: status.backgroundImagePixelWidth,
      backgroundImagePixelHeight: status.backgroundImagePixelHeight,
      backgroundImageContentDigest: status.backgroundImageContentDigest,
      backgroundImageImportCount: status.backgroundImageImportCount,
      backgroundImageDecodeCount: status.backgroundImageDecodeCount,
      backgroundImageFileReadCount: status.backgroundImageFileReadCount,
      backgroundImageApplyCount: status.backgroundImageApplyCount,
      backgroundImageRedrawCount: status.backgroundImageRedrawCount,
      applyToExplicitCellBackgrounds: status.requested.applyToExplicitCellBackgrounds,
      forceOpaqueReason: status.effective.forceOpaqueReason?.rawValue,
      surfaceOpaque: status.effective.isSurfaceOpaque,
      effectiveGlyphAntialiasing: rendererStatus.vectorSubpixelLayout ?? "rendererDefault",
      effectiveGlyphAntialiasingReason: rendererStatus.vectorSubpixelFallbackReason,
      snapshotExplicitBackgroundCapability: status.snapshotBackgroundCapability.rawValue,
      configuredRenderer: rendererStatus.configuredRenderer,
      effectiveRenderer: rendererStatus.effectiveRenderer,
      themeName: Theme.current.name,
      themeIsDark: Theme.current.isDark,
      effectiveAppearance: effectiveAppearance,
      backdropSubviewCount: status.backdropSubviewCount,
      backdropSubviewKind: status.backdropSubviewKind.rawValue,
      windowBlurAvailable: status.windowBlurAvailable,
      windowBlurRadius: status.windowBlurRadius,
      systemReduceTransparency:
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      reduceTransparencyOverride: debugReduceTransparencyOverride,
      effectiveReduceTransparency: status.reduceTransparency,
      nativeFullscreen: status.nativeFullscreen,
      accessibilityRefreshCount: diagnostics.accessibilityRefreshCount,
      effectiveTransparencyApplyCount: diagnostics.effectiveTransparencyApplyCount,
      transparencyRenderWakeCount: diagnostics.transparencyRenderWakeCount,
      rendererPresentCount: diagnostics.rendererPresentCount,
      presentIntervalDeadlineMisses: diagnostics.presentIntervalDeadlineMisses)
  }

  func setBackgroundTransparency(
    opacity: Double,
    blur: Double?,
    applyToExplicitCellBackgrounds: Bool,
    backdropStyle: TerminalBackdropStyle?
  ) {
    guard let transparencyCoordinator else { return }
    var requested = transparencyCoordinator.status.requested
    requested.backgroundOpacity = opacity
    if let blur {
      requested.backgroundBlur = blur
    }
    requested.applyToExplicitCellBackgrounds = applyToExplicitCellBackgrounds
    if let backdropStyle {
      requested.backdropStyle = backdropStyle
    }
    transparencyCoordinator.setRequestedConfiguration(requested)
  }

  func resetTransparencyDiagnostics() {
    terminalView?.resetTransparencyDiagnostics()
    transparencyCoordinator?.resetBackgroundImageDiagnostics()
  }

  func setBackgroundSource(_ source: TerminalBackdropStyle) {
    guard let transparencyCoordinator else { return }
    var requested = transparencyCoordinator.status.requested
    requested.backdropStyle = source
    transparencyCoordinator.setRequestedConfiguration(requested)
  }

  func setBackgroundImageScaling(_ scaling: TerminalBackgroundImageScaling) {
    guard let transparencyCoordinator else { return }
    var requested = transparencyCoordinator.status.requested
    requested.backgroundImageScaling = scaling
    transparencyCoordinator.setRequestedConfiguration(requested)
  }

  func importBackgroundImageFixture(
    relativePath: String,
    scaling: TerminalBackgroundImageScaling
  ) throws {
    guard let root = terminalBackgroundFixtureRootURL, let terminalBackgroundImageStore else {
      throw ControlledFixturePathError.escapedRoot
    }
    let sourceURL = try ControlledFixturePathResolver.resolve(relativePath, root: root)
    _ = try terminalBackgroundImageStore.importImage(from: sourceURL, scaling: scaling)
  }

  func removeBackgroundImage() {
    terminalBackgroundImageStore?.removeManagedImage()
  }

  func setReduceTransparencyOverride(_ enabled: Bool?) {
    debugReduceTransparencyOverride = enabled
    terminalView?.setReduceTransparencyOverride(enabled)
  }

  /// Starts the real AppKit transition; callers observe completion through
  /// `terminalTransparencyStatus().nativeFullscreen` rather than assuming the
  /// animation completed synchronously.
  func setNativeFullScreen(_ enabled: Bool) {
    guard let window else { return }
    let current =
      window.styleMask.contains(.fullScreen)
      || transparencyCoordinator?.status.nativeFullscreen == true
    guard current != enabled else { return }
    window.toggleFullScreen(nil)
  }

  /// GUI parity for the headless `/debug/terminal-modes` endpoint: the active
  /// session's effective DEC private mode state (grapheme cluster 2027 + sync
  /// output, focus, mouse), so the mode-2027 handshake is queryable from the
  /// headful path too.
  func terminalModesDebugState() -> [String: Any]? {
    terminalView?.debugTerminalModesState()
  }

  /// Select and raise the tab named by a native notification. A stale tab ID
  /// is a no-op so notification taps can safely fall back to activating the
  /// application without changing the user's current selection.
  @discardableResult
  func focusTabFromNotification(_ tabId: Tab.ID) -> Bool {
    guard terminalView?.selectTabFromExternalNavigation(tabId) == true else { return false }
    window?.deminiaturize(nil)
    window?.makeKeyAndOrderFront(nil)
    return true
  }

  static func makeAndShow(
    restoring restoredState: WorkspaceState? = nil,
    persistenceSyncEnabled: Bool = true,
    terminalBackendSelection: TerminalBackendLaunchConfiguration? = nil
  ) throws
    -> MainWindowController
  {
    let fontAtlas = FontAtlas(pointSize: FontAtlas.persistedTerminalPointSize)
    let sidebarFontAtlas = FontAtlas(pointSize: FontAtlas.persistedSidebarPointSize)
    let previewFontAtlas = FontAtlas(pointSize: FontAtlas.persistedPreviewPointSize)
    let cjkDiagnostics = fontAtlas.cjkFontDiagnostics
    AppLog.app.info(
      "CJK font preference=\(CJKFontSettings.currentDisplayName(baseFont: fontAtlas.font)), "
        + "selected=\(cjkDiagnostics.selectedFamilyName) (\(cjkDiagnostics.selectedSource)), "
        + "glyphAvailable=\(cjkDiagnostics.glyphAvailable), "
        + "advance=\(String(format: "%.2f", Double(cjkDiagnostics.glyphAdvance)))pt, "
        + "target=\(String(format: "%.2f", Double(cjkDiagnostics.targetCellWidth)))pt")
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
    // a passthrough launch, so the shell starts unchanged. The provider
    // re-validates the overlay's files at every spawn and reinstalls them
    // if an external cleanup deleted the per-process temp directory —
    // otherwise a stale ZDOTDIR would make zsh skip the user's .zshrc.
    // See `ShellIntegrationOverlay` and `docs/product/spec.md` §7.
    let shellIntegration = Self.makeShellIntegrationOverlayProvider()
    // Terminal identity is a live setting: resolve it per spawn so flipping
    // it in Settings reaches the next new tab without relaunching Laban.
    let spawnLaunch = {
      shellIntegration.currentLaunch().withTerminalIdentity(TerminalIdentitySettings.identity())
    }
    let backendSelection = try terminalBackendSelection ?? Self.configuredAppTerminalBackend()
    let terminalBackend = backendSelection.backend
    let restoredCwdByTabId = Self.restoredCwdByTabId(from: restoredState)
    let sessionCoordinator = try Self.makeSessionCoordinator(
      backend: terminalBackend,
      shellLaunchProvider: { shellIntegration.currentLaunch() },
      cwdByTabId: restoredCwdByTabId)

    let launchCoordinator = ControlSessionLaunchCoordinator()
    let liveRouter = LiveIntentRouter(
      model: nil,
      proposalPresenter: CommandProposalReviewPresenter.shared)
    var bootstrappedControl: (server: LabanControlServer, security: ControlSecurityCoordinator)?
    if Self.shouldMountControlServer() {
      bootstrappedControl = try Self.bootstrapControlServer(
        router: liveRouter,
        launchCoordinator: launchCoordinator)
    }

    let model = try AppModel(
      initialSize: size,
      sessionLaunchContextProvider: { tabId, isAgentAttached in
        launchCoordinator.prepareLaunch(tabID: tabId, isAgentAttached: isAgentAttached)
      },
      sessionFactory: { size, context in
        switch terminalBackend {
        case .inProcess:
          let launch = spawnLaunch()
          let env = Self.mergeLaunchEnvironment(launch.environmentOverrides, context: context)
          let session = try Session.realShell(
            size: size,
            environment: env,
            launchArgv: launch.argv,
            sessionID: context.sessionID)
          launchCoordinator.tryRegisterShellPID(sessionID: context.sessionID, session: session)
          return session
        case .laband:
          return try Session.fixture(size: size, sessionID: context.sessionID)
        case .labpty:
          return try Session.parserOnly(size: size, sessionID: context.sessionID)
        }
      }
    )
    liveRouter.bindModel(model)
    let controlLaunchCoordinator = launchCoordinator
    let sessionCoordForAttach = sessionCoordinator
    let priorTabCreated = model.onTabCreated
    model.onTabCreated = { tabId, session in
      priorTabCreated?(tabId, session)
      Self.registerAttachShell(
        tabId: tabId,
        session: session,
        launchCoordinator: controlLaunchCoordinator,
        sessionCoordinator: sessionCoordForAttach)
      Self.scheduleAttachShellRetries(
        tabId: tabId,
        launchCoordinator: controlLaunchCoordinator,
        sessionCoordinator: sessionCoordForAttach,
        model: model)
    }
    let priorTabClosedForControl = model.onTabClosed
    model.onTabClosed = { tabId in
      priorTabClosedForControl?(tabId)
      controlLaunchCoordinator.noteTabClosed(tabID: tabId)
    }
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
      let context = launchCoordinator.prepareLaunch(tabID: spec.tabId, isAgentAttached: false)
      let launch = spawnLaunch()
      let env = Self.mergeLaunchEnvironment(
        launch.environmentOverrides,
        context: context)
      let session = try Session.makeDeferred(
        size: spec.size,
        cwd: spec.cwd,
        environment: env,
        sessionID: context.sessionID)
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
      if let inj = injection, let execArgs = launch.resumeExecArgs {
        injection = RestoreShellInjection(
          command: inj.command, shellPath: inj.shellPath, execArgs: execArgs)
      }
      let rc = session.startSpawn(
        overrideCwd: spec.cwdFallbackApplied ? spec.cwd : nil,
        injection: injection,
        launchArgv: launch.argv)
      if rc != 0 {
        // Spawn failed — log and surface a banner. The session keeps
        // its VT parser so the tab body is renderable; the user sees
        // a banner where the shell prompt would have been.
        AppLog.app.error(
          "restored tab \(spec.tabId) failed to spawn shell (cwd=\(spec.cwd))")
        let warning = "\r\n[restore failed: shell did not start in \(spec.cwd)]\r\n"
        _ = session.feedOutput(Array(warning.utf8))
      }
      launchCoordinator.tryRegisterShellPID(sessionID: context.sessionID, session: session)
      return session
    }
    // Simple fallback for restored tabs that don't have a deferred
    // factory (used by headless tests that swap the factory out).
    model.restoredSessionFactory = { size, cwd, context in
      switch terminalBackend {
      case .laband, .labpty:
        return try Session.parserOnly(size: size, sessionID: context.sessionID)
      case .inProcess:
        let launch = spawnLaunch()
        let env = Self.mergeLaunchEnvironment(
          launch.environmentOverrides,
          context: context)
        let session = try Session.realShell(
          size: size,
          cwd: cwd,
          environment: env,
          launchArgv: launch.argv,
          sessionID: context.sessionID)
        launchCoordinator.tryRegisterShellPID(sessionID: context.sessionID, session: session)
        return session
      }
    }

    // New tabs (⌘T) open in the active tab's reported working directory — its
    // OSC 7 / metadata cwd, or its live process cwd — so a new tab lands where
    // you are instead of at the launcher's directory. Same spawn shape as the
    // restore factory; the cwd is meaningful only for the in-process backend.
    model.newTabSessionFactory = { size, cwd, context in
      switch terminalBackend {
      case .laband, .labpty:
        return try Session.parserOnly(size: size, sessionID: context.sessionID)
      case .inProcess:
        let launch = spawnLaunch()
        let env = Self.mergeLaunchEnvironment(
          launch.environmentOverrides,
          context: context)
        let session = try Session.realShell(
          size: size,
          cwd: cwd,
          environment: env,
          launchArgv: launch.argv,
          sessionID: context.sessionID)
        launchCoordinator.tryRegisterShellPID(sessionID: context.sessionID, session: session)
        return session
      }
    }

    // Command tabs (e.g. an ssh:// URL handler) run a caller-supplied argv
    // instead of the login shell. In-process spawns it directly; the daemon
    // backends use a parser-only local session and launch argv daemon-side —
    // the coordinator reads it via `argvProvider`, wired just below.
    model.commandSessionFactory = { size, cwd, argv, context in
      switch terminalBackend {
      case .laband, .labpty:
        return try Session.parserOnly(size: size, sessionID: context.sessionID)
      case .inProcess:
        let env = Self.mergeLaunchEnvironment(
          spawnLaunch().environmentOverrides,
          context: context)
        let session: Session
        if let cwd {
          session = try Session.realShell(
            size: size,
            cwd: cwd,
            environment: env,
            launchArgv: argv,
            sessionID: context.sessionID)
        } else {
          session = try Session.realShell(
            size: size,
            environment: env,
            launchArgv: argv,
            sessionID: context.sessionID)
        }
        launchCoordinator.tryRegisterShellPID(sessionID: context.sessionID, session: session)
        return session
      }
    }
    sessionCoordinator?.argvProvider = { [weak model] tabId in
      model?.launchArgv(forTab: tabId)
    }
    sessionCoordinator?.launchEnvironmentProvider = { [weak model] tabId in
      model?.launchEnvironmentOverrides(forTab: tabId) ?? [:]
    }
    sessionCoordinator?.onTabMetadataRefreshed = {
      [weak launchCoordinator, weak sessionCoordinator] model in
      guard let launchCoordinator else { return }
      launchCoordinator.retryPendingShellRegistrations(in: model) { tabId, session in
        Self.resolveAttachShellPID(
          tabId: tabId,
          session: session,
          sessionCoordinator: sessionCoordinator)
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
    if Self.shouldLaunchAgentAttachedSession(),
      restoredState == nil || restoredState?.windows.isEmpty == true,
      model.tabs.count == 1,
      let defaultTab = model.tabs.first
    {
      let defaultTabId = defaultTab.id
      _ = try? model.createAgentAttachedTab()
      try? model.closeTab(defaultTabId)
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

    // Reattach resolves each tab's daemon-derived metadata (foreground process,
    // cwd) lazily on the first *visible* render frame. But AppKit reports a
    // restored window's occlusionState late and the idle policy parks the link
    // until it does, so on a quiet reattach the sidebar subrows can stay empty
    // (titles only) until a keystroke generates output that re-drives a refresh.
    // Resolve once here — eagerly, before the terminal view is built, and ungated
    // by the visibility/throttle gates the per-frame path applies — so the first
    // frame paints real subrows instead of racing AppKit and the daemon.
    sessionCoordinator?.refreshTabMetadata(for: model.tabs, into: model, force: true)

    let termView = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      previewFontAtlas: previewFontAtlas,
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
    // Belt-and-suspenders alongside the AppDelegate-wide
    // `NSWindow.allowsAutomaticWindowTabbing = false`: setting it on the class
    // only stops new windows joining a tab group, not this window's own
    // participation in AppKit's native tab key-view machinery (Ctrl+Tab /
    // Ctrl+Shift+Tab), which otherwise swallows those chords before
    // `TerminalBitmapView.keyDown` ever sees them. Laban's tabs are the
    // sidebar's own concept, never native window tabs.
    window.tabbingMode = .disallowed
    // Transparent titlebar with the contentView extending behind it; the
    // sidebar and terminal-area background rects fill the reserved strip so
    // the chrome looks continuous with the terminal. Traffic lights stay
    // interactive because AppKit composites them over the contentView.
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    // Native full screen: lets the green button and View → Enter Full Screen
    // (⌃⌘F) take the terminal fullscreen, which a terminal is a prime
    // candidate for. Without fullScreenPrimary AppKit disables toggleFullScreen.
    window.collectionBehavior.insert(.fullScreenPrimary)
    // Container view hosts the terminal plus overlay views. The
    // terminal stays the full size; overlays float above it. Using siblings
    // instead of TerminalBitmapView subviews avoids z-order / hit-test issues
    // with the Metal-backed terminal layer.
    let containerView = NSView(frame: NSRect(x: 0, y: 0, width: viewW, height: viewH))
    containerView.autoresizesSubviews = true
    let backgroundEffectHost = TerminalBackgroundEffectHost(frame: .zero)
    backgroundEffectHost.install(
      in: containerView,
      terminalLeadingInset: SidebarLayout.defaultWidth)
    termView.autoresizingMask = [.width, .height]
    containerView.addSubview(termView)

    // Overlay scroll indicator: invisible when the viewport is at the live
    // bottom, fades in when the user scrolls back into history. Sibling of
    // termView (not a subview) so the Metal layer compositing stays untouched.
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
    let backgroundFixtureRootURL: URL?
    if Self.shouldEnableIsolatedGUIFixtureControl(),
      let controlDirectory = ProcessInfo.processInfo.environment["LABAN_CONTROL_DIR"]
    {
      backgroundFixtureRootURL = URL(
        fileURLWithPath: controlDirectory,
        isDirectory: true
      ).standardizedFileURL.resolvingSymlinksInPath()
    } else {
      backgroundFixtureRootURL = nil
    }
    let backgroundImageStore =
      backgroundFixtureRootURL.map {
        TerminalBackgroundImageStore(baseURL: $0)
      } ?? TerminalBackgroundImageStore()
    // Resolve and apply window/surface policy after the terminal-only material
    // host is installed but before the window is presented. This prevents
    // AppKit's default opaque background from flashing through a translucent
    // first frame or cold-launch backend swap.
    let transparencyCoordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: termView,
      reduceTransparency: termView.accessibilityDisplayOptionsForTesting.reduceTransparency,
      snapshotBackgroundCapability:
        sessionCoordinator?.terminalSnapshotBackgroundCapability ?? .inProcess,
      backgroundImageStore: backgroundImageStore,
      backgroundEffectHost: backgroundEffectHost)
    window.center()
    window.makeKeyAndOrderFront(nil)
    transparencyCoordinator.reapplyWindowEffects()

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
    controller.terminalBackgroundImageStore = backgroundImageStore
    controller.terminalBackgroundFixtureRootURL = backgroundFixtureRootURL
    controller.controlSessionLaunchCoordinator = launchCoordinator
    controller.liveControlRouter = liveRouter
    liveRouter.bindWindowScreenshotProvider {
      [weak controller] () -> Result<LabanWindowScreenshot, LabanWindowScreenshotFailure> in
      guard let window = controller?.window else { return .failure(.captureFailed) }
      return LabanWindowScreenshotCapture.capture(
        window: window,
        including: controller?.windowScreenshotAuxiliaryWindowsProvider() ?? [])
    }
    liveRouter.bindFixtureWindowFocusHandler { [weak controller] in
      guard let window = controller?.window else { return false }
      window.orderFrontRegardless()
      return true
    }
    liveRouter.bindTransparencyControl(
      state: { [weak controller] in
        controller?.terminalTransparencyDebugResponse()
      },
      setBackground: { [weak controller] opacity, blur, cells, backdropStyle in
        controller?.setBackgroundTransparency(
          opacity: opacity,
          blur: blur,
          applyToExplicitCellBackgrounds: cells,
          backdropStyle: backdropStyle)
      },
      resetDiagnostics: { [weak controller] in
        controller?.resetTransparencyDiagnostics()
      },
      setReduceTransparencyOverride: { [weak controller] enabled in
        controller?.setReduceTransparencyOverride(enabled)
      },
      setNativeFullScreen: { [weak controller] enabled in
        controller?.setNativeFullScreen(enabled)
      },
      setBackgroundSource: { [weak controller] source in
        controller?.setBackgroundSource(source)
      },
      setBackgroundImageScaling: { [weak controller] scaling in
        controller?.setBackgroundImageScaling(scaling)
      },
      importBackgroundImage: { [weak controller] path, scaling in
        guard let controller else { return }
        try controller.importBackgroundImageFixture(relativePath: path, scaling: scaling)
      },
      removeBackgroundImage: { [weak controller] in
        controller?.removeBackgroundImage()
      })
    if let bootstrappedControl {
      controller.controlServer = bootstrappedControl.server
      controller.controlSecurityCoordinator = ControlSecurityCoordinator(indicatorHost: termView)
      bootstrappedControl.server.setSecurityObserver(controller.controlSecurityCoordinator)
      bootstrappedControl.server.setApprovalDelegate(ControlAttachApprovalPresenter.shared)
    }
    controller.model = model
    controller.terminalView = termView
    controller.transparencyCoordinator = transparencyCoordinator
    controller.scrollIndicator = scrollIndicator
    controller.syncPillTextSourceToRenderer()
    controller.refreshLiveControlEnvironment()
    controller.terminalBackend = terminalBackend
    controller.terminalSessionClient =
      sessionCoordinator?.terminalClient
      ?? (terminalBackend == .inProcess ? InProcessTerminalSessionClient() : nil)
    controller.sessionCoordinator = sessionCoordinator

    // All tab-attention notification candidates flow through one policy point:
    // explicit OSC/BEL events and derived attention-state transitions share
    // settings, focus suppression, journal notes, debug decisions, and native
    // delivery.
    let agentNotificationPoster = AgentNotificationPoster(
      onNativeStateChanged: {
        NativeNotificationStateRefresher.shared.refresh()
      })
    liveRouter.bindNotificationStateRefresh {
      NativeNotificationStateRefresher.shared.refresh()
    }
    liveRouter.bindNotificationTestHandler { event, soundEnabled in
      agentNotificationPoster.post(event: event, soundEnabled: soundEnabled) { _ in }
    }
    let isTabFrontmost: (Tab.ID) -> Bool = { [weak model] tabId in
      guard NSApplication.shared.isActive, let model else { return false }
      return model.tabs.first(where: { $0.isActive })?.id == tabId
    }
    // The model uses the same attention check to skip raising the synthetic
    // awaiting-input badge on the tab the user is already watching.
    model.isTabFrontmost = isTabFrontmost
    let recordAttentionDecision: (AppModel, AttentionNotificationDecision) -> Void = {
      model, decision in
      model.recordAttentionNotificationDecision(decision)
      model.tabJournal.note(
        tabId: decision.event.tabId,
        note: decision.suppressionReason.map {
          TabStateJournal.bannerSuppressedNote(reason: $0)
        }
          ?? TabStateJournal.bannerPostedNote,
        text: decision.event.body)
    }
    model.onAttentionNotification = { [weak model] event in
      guard let model else { return }
      if let decision = AttentionNotificationPolicy.suppressedDecision(
        for: event,
        isTabFrontmost: isTabFrontmost,
        isCategoryEnabled: { AttentionNotificationSettings.isEnabled(for: $0) })
      {
        recordAttentionDecision(model, decision)
        return
      }
      agentNotificationPoster.post(
        event: event,
        soundEnabled: AttentionNotificationSettings.soundEnabled
      ) { [weak model] decision in
        guard let model else { return }
        recordAttentionDecision(model, decision)
      }
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
      let priorTabCreatedForObserver = model.onTabCreated
      model.onTabCreated = { [weak observerHost] tabId, session in
        priorTabCreatedForObserver?(tabId, session)
        observerHost?.attach(session: session, tabId: tabId)
      }
      let priorTabClosedForObserver = model.onTabClosed
      model.onTabClosed = { [weak observerHost] tabId in
        priorTabClosedForObserver?(tabId)
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

    // Live scroll-indicator diagnostics. Opt-in via `--scroll-debug[=port]`
    // (default port 8787). Arms the ScrollDiagnostics trace (in-memory ring +
    // JSONL under ~/Library/Logs/Laban/scroll-trace/) and starts a loopback HTTP
    // control surface so the bug can be driven and inspected on a real window:
    // feed a streaming program, read the viewport time-series, snap to bottom,
    // screenshot. Never started on a normal launch.
    if let config = ScrollDebugServer.Config.fromLaunchArguments() {
      let server = ScrollDebugServer(model: model, termView: termView, indicator: scrollIndicator)
      server.start(config: config)
      controller.scrollDebugServer = server
    }

    // Observe-on-by-default (2F): starts unless the Settings master toggle or
    // `LABAN_CONTROL_SERVER=0` force-disables it. Bound early so the first
    // session inherits `LABAN_CONTROL_URL` when the listener is up.
    if bootstrappedControl == nil, Self.shouldMountControlServer() {
      controller.startControlServer(model: model, router: liveRouter)
    }

    return controller
  }

  private static func mergeLaunchEnvironment(
    _ base: [String: String],
    context: SessionLaunchContext
  ) -> [String: String] {
    var env = base
    for (key, value) in context.environmentOverrides {
      env[key] = value
    }
    return env
  }

  static func bootstrapControlServer(
    router: IntentRouter,
    launchCoordinator: ControlSessionLaunchCoordinator
  ) throws -> (server: LabanControlServer, security: ControlSecurityCoordinator) {
    let security = ControlSecurityCoordinator(indicatorHost: nil)
    let server = LabanControlServer(
      router: router,
      surface: .gui,
      securityObserver: security)
    let info = try server.start(
      enableGUIFixtureControl: Self.shouldEnableIsolatedGUIFixtureControl())
    try ControlAdvertisement.write(
      url: info.socketPath,
      token: info.appObserveToken,
      pid: ProcessInfo.processInfo.processIdentifier,
      runId: ProcessInfo.processInfo.environment["LABAN_RUN_ID"]
        ?? "gui-\(ProcessInfo.processInfo.processIdentifier)",
      diagnosticControlToken: info.diagnosticControlToken,
      diagnosticSessionObserveToken: info.diagnosticSessionObserveToken)
    launchCoordinator.noteControlServerStarted(server, socketPath: info.socketPath)
    AppLog.app.info("control server: \(info.socketPath)")
    return (server, security)
  }

  /// True when the GUI control server should bind on this launch.
  static func shouldMountControlServer() -> Bool {
    guard ControlServerSettings.isEnabled else { return false }
    if ProcessInfo.processInfo.environment[ControlEnvironmentKeys.controlServerForceDisable] == "0"
    {
      return false
    }
    return true
  }

  /// Diagnostic fixture authority exists only in an explicitly isolated
  /// control directory. Requiring both inputs prevents an accidental
  /// `LABAN_GUI_FIXTURE_CONTROL=1` in a normal launch from placing a privileged
  /// token in the user's production advertisement.
  static func shouldEnableIsolatedGUIFixtureControl(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    guard environment[ControlEnvironmentKeys.guiFixtureControl] == "1" else {
      return false
    }
    guard let directory = environment["LABAN_CONTROL_DIR"], !directory.isEmpty else {
      return false
    }
    return true
  }

  /// C13: explicit production entry for an agent-attached first tab.
  static func shouldLaunchAgentAttachedSession(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = CommandLine.arguments,
    defaults: UserDefaults = .standard
  ) -> Bool {
    if environment[ControlEnvironmentKeys.agentAttachedSessionAtLaunch] == "1" {
      return true
    }
    if arguments.contains("--agent-attached-session") {
      return true
    }
    return AgentAttachedSessionSettings.isEnabled(defaults: defaults)
  }

  func startControlServer(model: AppModel?, router: LiveIntentRouter? = nil) {
    guard controlServer == nil else { return }
    guard Self.shouldMountControlServer() else { return }
    do {
      let security = ControlSecurityCoordinator(indicatorHost: terminalView)
      controlSecurityCoordinator = security
      let liveRouter =
        router ?? liveControlRouter
        ?? LiveIntentRouter(
          model: model,
          proposalPresenter: CommandProposalReviewPresenter.shared)
      if let model {
        liveRouter.bindModel(model)
      }
      self.liveControlRouter = liveRouter
      let server = LabanControlServer(
        router: liveRouter,
        surface: .gui,
        securityObserver: security)
      server.setApprovalDelegate(ControlAttachApprovalPresenter.shared)
      let info = try server.start(
        enableGUIFixtureControl: Self.shouldEnableIsolatedGUIFixtureControl())
      try ControlAdvertisement.write(
        url: info.socketPath,
        token: info.appObserveToken,
        pid: ProcessInfo.processInfo.processIdentifier,
        runId: ProcessInfo.processInfo.environment["LABAN_RUN_ID"]
          ?? "gui-\(ProcessInfo.processInfo.processIdentifier)",
        diagnosticControlToken: info.diagnosticControlToken,
        diagnosticSessionObserveToken: info.diagnosticSessionObserveToken)
      controlServer = server
      controlSessionLaunchCoordinator.noteControlServerStarted(server, socketPath: info.socketPath)
      AppLog.app.info("control server: \(info.socketPath)")
    } catch {
      controlSecurityCoordinator = nil
      AppLog.app.error("control server failed: \(String(describing: error))")
    }
  }

  func stopControlServer() {
    controlServer?.stop()
    controlServer = nil
    controlSecurityCoordinator = nil
    controlSessionLaunchCoordinator.noteControlServerStopped()
    ControlAdvertisement.remove()
    terminalView?.setAgentAttachedIndicatorActive(false)
  }

  /// Runtime disable: persist the master toggle off, tear down the listener,
  /// and remove the on-disk advertisement file.
  func disableControlServer() {
    ControlServerSettings.set(false)
    stopControlServer()
  }

  func refreshLiveControlEnvironment() {
    guard let model, let termView = terminalView else { return }
    controlSessionLaunchCoordinator.retryPendingShellRegistrations(in: model) {
      [weak self] tabId, session in
      Self.resolveAttachShellPID(
        tabId: tabId,
        session: session,
        sessionCoordinator: self?.sessionCoordinator)
    }
    let opts = termView.accessibilityDisplayOptionsForTesting
    liveControlRouter?.updateEnvironment(
      LiveControlEnvironment(
        cellWidth: termView.cellWidth,
        cellHeight: termView.cellHeight,
        sidebarWidth: Int(SidebarLayout.defaultWidth),
        frame: 0,
        windowWidth: max(1, Int(termView.bounds.width)),
        windowHeight: max(1, Int(termView.bounds.height)),
        transportMode: "inProcess",
        accessibilityDisplayFlags: AccessibilityDisplayFlagsResponse(
          increaseContrast: opts.increaseContrast,
          differentiateWithoutColor: opts.differentiateWithoutColor,
          reduceTransparency: opts.reduceTransparency,
          reduceMotion: opts.reduceMotion),
        selectionProvider: { sessionID in
          termView.terminalSelection(forSessionID: sessionID, model: model)
        },
        accessibilityValueProvider: { tab in
          guard let session = model.session(forTab: tab.id), let snap = session.snapshot() else {
            return ""
          }
          defer { laban_snapshot_destroy(snap) }
          return TerminalSnapshotText.visibleText(
            from: UnsafePointer(snap),
            mode: .trimmedNonEmptyRows)
        },
        sessionClientInfoById: [:],
        glyphEffectsStateProvider: { [weak termView] in termView?.glyphEffectsState },
        spinnerMotionStateProvider: { [weak termView] in termView?.spinnerMotionState },
        hoverPreviewStateProvider: { [weak termView] in termView?.hoverPreviewState }))
  }

  func applyControlServerEnabled(_ enabled: Bool) {
    ControlServerSettings.set(enabled)
    if enabled {
      if Self.shouldMountControlServer() {
        startControlServer(model: model, router: liveControlRouter)
      }
    } else {
      stopControlServer()
    }
  }

  /// Supplies explicitly approved auxiliary Laban windows for the exact
  /// whole-window screenshot route. The provider runs only on the main thread
  /// immediately before capture, so hidden windows are never retained or read.
  func setWindowScreenshotAuxiliaryWindowsProvider(_ provider: @escaping () -> [NSWindow]) {
    windowScreenshotAuxiliaryWindowsProvider = provider
  }

  var currentRendererSelection: RendererSelection {
    terminalView?.rendererSelection ?? RendererSelection.persisted()
  }

  func applyRendererSelection(_ selection: RendererSelection) {
    terminalView?.applyRendererSelection(selection)
    syncPillTextSourceToRenderer()
  }

  /// Point the scrollback pill's text at the vector glyph renderer when that
  /// renderer is the effective backend, otherwise restore its CoreText path.
  /// Idempotent: safe to call after any renderer change or at setup.
  func syncPillTextSourceToRenderer() {
    let useVector = terminalView?.rendererSelection == .vectorGlyph
    scrollIndicator?.setVectorTextRasterizer(useVector ? vectorTextRasterizer : nil)
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
      ? L10n.tr("A background terminal session has no tab")
      : String(format: L10n.tr("%lld background terminal sessions have no tabs"), unclaimed.count)
    alert.informativeText = L10n.tr(
      "Laban found live shell session(s) from a previous run that aren't open in this window. Adopt them to reopen them as tabs, or ignore to leave them running in the background."
    )
    alert.addButton(withTitle: L10n.tr("Adopt"))  // .alertFirstButtonReturn
    alert.addButton(withTitle: L10n.tr("Ignore"))  // .alertSecondButtonReturn
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

  /// Create the self-healing owner of the OSC 133 rc-overlay for the user's
  /// login shell. The overlay lives under a unique per-process temp
  /// directory (worktree-isolation forbids a global fixed path); the OS
  /// reclaims it eventually. The provider reinstalls it at spawn time if it
  /// disappeared, and degrades to `.passthrough` — shells launch unchanged
  /// with their own startup files — when installing fails.
  private static func makeShellIntegrationOverlayProvider() -> ShellIntegrationOverlayProvider {
    let shellPath = LoginShell.resolvePath()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-shell-integration-\(UUID().uuidString)", isDirectory: true)
    return ShellIntegrationOverlayProvider(
      shellPath: shellPath,
      baseDirectory: base,
      environment: ProcessInfo.processInfo.environment)
  }

  func detachTerminalSessions() {
    sessionCoordinator?.detach()
  }

  /// Open and select a new tab that runs `argv` (argv[0] is the executable)
  /// instead of the login shell — e.g. an `ssh://` URL handler. The daemon
  /// backends pick up the argv via `argvProvider`; in-process spawns it
  /// directly. Returns the created tab.
  @discardableResult
  func openTab(runningArgv argv: [String], cwd: String? = nil) throws -> Tab {
    guard let model else { throw AppError.tabNotFound }
    return try model.createTab(runningArgv: argv, cwd: cwd)
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
    shellLaunchProvider: @escaping () -> ShellIntegrationLaunch,
    cwdByTabId: [Tab.ID: String]
  ) throws -> AppSessionCoordinator? {
    switch backend {
    case .inProcess:
      return nil
    case .laband:
      let setup = try connectOrStartLaband()
      return AppSessionCoordinator(
        client: setup.client,
        shellLaunchProvider: shellLaunchProvider,
        cwdByTabId: cwdByTabId,
        labandProcess: setup.process
      )
    case .labpty:
      let setup = try connectOrStartLabpty()
      return AppSessionCoordinator(
        labptyClient: setup.client,
        shellLaunchProvider: shellLaunchProvider,
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

  private static func resolveAttachShellPID(
    tabId: Tab.ID,
    session: Session,
    sessionCoordinator: AppSessionCoordinator?
  ) -> pid_t? {
    if let childPid = session.processMetadata()?.childPid, childPid > 0 {
      return pid_t(childPid)
    }
    return sessionCoordinator?.attachShellPID(forTabId: tabId)
  }

  private static func registerAttachShell(
    tabId: Tab.ID,
    session: Session,
    launchCoordinator: ControlSessionLaunchCoordinator,
    sessionCoordinator: AppSessionCoordinator?
  ) {
    let shellPID = resolveAttachShellPID(
      tabId: tabId,
      session: session,
      sessionCoordinator: sessionCoordinator)
    launchCoordinator.tryRegisterShellPID(
      sessionID: session.id,
      session: session,
      shellPID: shellPID)
  }

  private static func scheduleAttachShellRetries(
    tabId: Tab.ID,
    launchCoordinator: ControlSessionLaunchCoordinator,
    sessionCoordinator: AppSessionCoordinator?,
    model: AppModel
  ) {
    for delay in [0.05, 0.25, 1.0, 2.0, 5.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak model] in
        guard let model, let session = model.session(forTab: tabId) else { return }
        registerAttachShell(
          tabId: tabId,
          session: session,
          launchCoordinator: launchCoordinator,
          sessionCoordinator: sessionCoordinator)
      }
    }
  }
}
