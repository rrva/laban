import CoreGraphics
import Darwin
import Dispatch
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

// MARK: - Internal helpers

struct DrawStats {
  var cells: Int = 0
  var glyphs: Int = 0
  var backgroundRects: Int = 0
  var images: Int = 0
  var cursor: Bool = false
}

struct RuntimeTiming {
  var lastFrameMs: Double = 0
  var terminalPollMs: Double = 0
  var snapshotMs: Double = 0
  var commandExtractionMs: Double = 0
  var renderMs: Double = 0
  var screenshotMs: Double = 0
}

enum DebugMouseInput {
  static func terminalSurfacePosition(
    windowX: Int,
    windowY: Int,
    windowHeight: Int,
    sidebarWidth: Int
  ) -> (x: Float, y: Float) {
    (
      Float(windowX - sidebarWidth),
      Float(windowHeight - windowY)
    )
  }

  static func terminalSurfaceWidth(windowWidth: Int, sidebarWidth: Int) -> Int {
    max(windowWidth - sidebarWidth, 1)
  }
}

// MARK: - Runtime

public final class HeadlessDebugRuntime {
  private let lock = NSLock()

  public let runId: String
  var mode: String
  var sessionMode: HeadlessSessionMode
  let terminalBackend: TerminalSessionBackend
  let artifactsURL: URL
  let fixtureRootURL: URL
  let backgroundImageStore: DebugBackgroundImageStore
  let deterministic: Bool

  var model: AppModel
  var fontAtlas: FontAtlas
  var cellWidth: Int
  var cellHeight: Int
  let sidebarWidth: Int = 200
  var windowWidth: Int
  var windowHeight: Int
  var surface: BitmapSurface
  var renderer: SoftwareRenderer
  var rendererSelection: RendererSelection
  var rendererBackend: RendererBackend
  var surfaceController: TerminalSurfaceController

  var currentFrame: Int = 0
  var lastFrameCommands: [FrameCommand] = []
  var lastDrawStats = DrawStats()
  var debugClipboard: String = ""
  var selectionBySession: [Session.ID: TerminalSelection] = [:]
  var preeditBySession: [Session.ID: (text: String, caretCells: Int)] = [:]
  var lastCopyText: String?
  var lastPasteText: String?
  var lastPasteUsedBracketedPaste: Bool?
  var lastPasteIgnoredNonText: Bool?
  var logs = DebugRuntimeLogStore()
  var timing = RuntimeTiming()
  let startedAt = DispatchTime.now()
  var screenshotCount: Int = 0
  var fixtureURL: URL?
  var fixtureRunner: FixtureRunner?
  var fixtureStepIndex: Int = 0
  var terminalSessionClient: TerminalSessionClient?
  var terminalClientSessionInfoById: [Session.ID: LabandSessionInfo] = [:]
  var pendingAgentRestoreCandidatesByTab: [String: AgentRestoreCandidate] = [:]
  var labandProcess: Process?
  var ownsLabandProcess: Bool = false
  var labandSocketPath: String?
  var captureRecorder: CaptureRecorder?
  var lastCaptureManifestPath: String?
  var lastCaptureRunId: String?
  var lastCaptureDirectory: String?
  private var cjkFontSettingsObserver: NSObjectProtocol?
  var accessibilityDisplayFlags = AccessibilityDisplayFlagsResponse(
    increaseContrast: false,
    differentiateWithoutColor: false,
    reduceTransparency: false)
  var requestedTransparency = TerminalTransparencyConfiguration(
    backgroundOpacity: 1,
    applyToExplicitCellBackgrounds: false,
    backdropStyle: .none)
  var effectiveTransparency = EffectiveTerminalTransparency(
    backgroundOpacity: 1,
    applyToExplicitCellBackgrounds: false,
    backdropStyle: .none,
    forceOpaqueReason: nil,
    isSurfaceOpaque: true)
  var reduceTransparencyOverride: Bool?
  var transparencyAccessibilityRefreshCount = 0
  var effectiveTransparencyApplyCount = 0
  var transparencyRenderWakeCount = 0
  var transparencyRendererPresentBaseline = 0

  /// Optional persistence wiring. When `--persistence-dir=<path>` is
  /// passed to the laban-agent CLI, the runtime mirrors what
  /// `MainWindowController` does in the real app: TranscriptHost
  /// captures PTY bytes, PersistenceCoordinator writes
  /// workspace.json on a debounce, AgentObserverHost watches for
  /// claude/codex descendants. Existing test/fixture runs leave
  /// these nil so the headless path stays self-contained when no
  /// directory is provided.
  public let persistenceBaseURL: URL?
  public let persistenceStore: PersistenceStore?
  public let transcriptHost: TranscriptHost?
  public let persistenceCoordinator: PersistenceCoordinator?
  public let agentObserverHost: AgentObserverHost?

  func withRuntimeLock<T>(_ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  func rebuildRendererBackendUnlocked() {
    rendererBackend = makeRendererBackend(
      selection: rendererSelection,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: fontAtlas,
      pixelWidth: max(windowWidth, 1),
      pixelHeight: max(windowHeight, 1),
      scale: 1)
    enableBackendReadbackIfNeededUnlocked()
    rendererBackend.setSurfaceTransparency(
      RendererSurfaceTransparency(isOpaque: effectiveTransparency.isSurfaceOpaque))
    syncSoftwareRendererIfNeededUnlocked()
  }

  func refreshCJKFontCascadeUnlocked() {
    (rendererBackend as? MetalRenderer)?.refreshCJKFontCascade()
    (rendererBackend as? VectorGlyphRenderer)?.refreshCJKFontCascade()
    (rendererBackend as? SlugGlyphRenderer)?.refreshCJKFontCascade()
  }

  func resizeRendererBackendUnlocked() {
    rendererBackend.resize(
      pixelWidth: max(windowWidth, 1),
      pixelHeight: max(windowHeight, 1),
      scale: 1)
    syncSoftwareRendererIfNeededUnlocked()
  }

  func syncSoftwareRendererIfNeededUnlocked() {
    if let software = rendererBackend as? SoftwareBackend {
      surface = software.surface
      renderer = software.renderer
    }
  }

  private func enableBackendReadbackIfNeededUnlocked() {
    (rendererBackend as? MetalRenderer)?.captureMode = true
  }

  // MARK: - Init

  public init(
    fixtureURL: URL?,
    artifactsURL: URL,
    tempURL: URL?,
    deterministic: Bool,
    runId: String,
    fixtureRootURL: URL? = nil,
    sessionMode: HeadlessSessionMode = .fixture,
    rendererSelection: RendererSelection = .software,
    captureName: String? = nil,
    captureScreenshots: CaptureScreenshotPolicy = .marked,
    persistenceBaseURL: URL? = nil,
    backgroundOpacity: Double = 1,
    backgroundBlur: Double = 0,
    backgroundEffect: TerminalBackdropStyle = .none,
    backgroundImageScaling: TerminalBackgroundImageScaling = .default,
    applyTransparencyToExplicitCellBackgrounds: Bool = false,
    restorePersistedState: Bool = true,
    restoreOnLaunchEnabled: @escaping () -> Bool = { true }
  ) throws {
    self.runId = runId
    self.artifactsURL = artifactsURL
    self.backgroundImageStore = DebugBackgroundImageStore(baseURL: artifactsURL)
    self.fixtureRootURL =
      (fixtureRootURL
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("fixtures", isDirectory: true))
      .standardizedFileURL
      .resolvingSymlinksInPath()
    self.deterministic = deterministic
    self.mode = fixtureURL != nil ? "fixture" : "headless"
    let initialSessionMode: HeadlessSessionMode = fixtureURL != nil ? .fixture : sessionMode
    self.sessionMode = initialSessionMode
    self.rendererSelection = rendererSelection
    self.requestedTransparency = TerminalTransparencyConfiguration(
      backgroundOpacity: backgroundOpacity,
      applyToExplicitCellBackgrounds: applyTransparencyToExplicitCellBackgrounds,
      backdropStyle: backgroundEffect,
      backgroundImageScaling: backgroundImageScaling,
      backgroundBlur: backgroundBlur)
    self.effectiveTransparency = TerminalTransparencyPolicy.resolve(
      requested: self.requestedTransparency,
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      backgroundImageAvailability:
        backgroundEffect == .image ? .headlessUnsupported : .none,
      snapshotBackgroundCapability: .inProcess,
      headless: true)
    let configuredBackend = try TerminalSessionBackend.configured()
    self.terminalBackend = fixtureURL == nil ? configuredBackend : .inProcess

    // Parity with MainWindowController: honor the persisted font size
    // (UserDefaults `LabanFontSize`) instead of hardcoding the default.
    let fa = FontAtlas(pointSize: FontAtlas.persistedTerminalPointSize)
    let cs = fa.cellSize
    self.fontAtlas = fa
    self.cellWidth = Int(cs.width)
    self.cellHeight = Int(cs.height)

    try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
    if let tempURL {
      try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    }

    var initialRows = 24
    var initialCols = 80

    var runner: FixtureRunner? = nil
    if let url = fixtureURL {
      let r = try FixtureRunner.load(from: url)
      initialRows = r.fixture.initialSize.rows
      initialCols = r.fixture.initialSize.cols
      runner = r
    }

    var initSize = LabanTerminalSize()
    initSize.rows = Int32(initialRows)
    initSize.cols = Int32(initialCols)

    let initialRecorder: CaptureRecorder?
    if let captureName {
      try CaptureRecorder.validateCaptureName(captureName)
      initialRecorder = try CaptureRecorder(
        artifactRoot: artifactsURL.appendingPathComponent("captures", isDirectory: true),
        name: captureName,
        screenshots: captureScreenshots,
        executable: "laban-agent"
      )
    } else {
      initialRecorder = nil
    }

    let shellLaunch = Self.installShellIntegrationOverlay()
    self.model = try AppModel(
      initialSize: initSize,
      sessionFactory: { size in
        let session = try Self.makeSession(
          size: size, mode: initialSessionMode, shellLaunch: shellLaunch)
        session.captureSink = initialRecorder
        return session
      })
    self.captureRecorder = initialRecorder
    self.model.captureSink = initialRecorder
    self.lastCaptureRunId = initialRecorder?.runId
    self.lastCaptureDirectory = initialRecorder?.directoryURL.path

    // Optional persistence wiring. Mirrors MainWindowController so
    // bugs in M0/M1/M2 paths can be reproduced inside the headless
    // debug harness against the actual PersistenceCoordinator /
    // TranscriptHost / AgentObserverHost objects, not a parallel
    // test rig that might silently diverge from production.
    self.persistenceBaseURL = persistenceBaseURL
    if let baseURL = persistenceBaseURL {
      let store = PersistenceStore(baseURL: baseURL)
      let transcripts = TranscriptHost(
        store: store, isEnabled: restoreOnLaunchEnabled)
      let mirror = AgentJSONLMirror(
        store: store, isEnabled: restoreOnLaunchEnabled)
      let observers = AgentObserverHost(
        appModel: model, mirror: mirror, isEnabled: restoreOnLaunchEnabled)
      let coordinator = PersistenceCoordinator(
        store: store,
        windowId: "headless-window",
        debounceInterval: .milliseconds(50),
        isEnabled: restoreOnLaunchEnabled)
      coordinator.transcriptHost = transcripts
      self.persistenceStore = store
      self.transcriptHost = transcripts
      self.persistenceCoordinator = coordinator
      self.agentObserverHost = observers

      self.model.transcriptDelegate = transcripts
      self.model.restoredSessionFactory = { sz, _, _ in
        try Self.makeSession(size: sz, mode: initialSessionMode, shellLaunch: shellLaunch)
      }
      let restoreViaLabandPicker = terminalBackend == .laband
      self.model.restoredDeferredSessionFactory = { spec in
        // fixture sessions don't really "spawn"; deferred mode is
        // only meaningful for real shells. Historical transcript
        // bytes remain available on disk for diagnostics but are not
        // replayed into automatic workspace restore.
        let session: Session
        switch initialSessionMode {
        case .fixture:
          session = try Session.fixture(size: spec.size)
        case .realShell:
          session = try Session.makeDeferred(size: spec.size, cwd: spec.cwd)
        }
        if case .realShell = initialSessionMode {
          // In laband mode, a lost daemon means the live PTY is gone.
          // Preserve the old semantic restore path as a picker instead of
          // auto-running a resume command in this local placeholder session.
          let injection =
            restoreViaLabandPicker
            ? nil
            : RestoreLaunchPlanner.instruction(
              for: spec,
              activityChecker: ProcessTreeRestoreSessionActivityChecker()
            ).spawnInjection
          _ = session.startSpawn(
            overrideCwd: spec.cwdFallbackApplied ? spec.cwd : nil,
            injection: injection)
        }
        return session
      }
      self.model.onTabCreated = { [weak observers] tabId, session in
        observers?.attach(session: session, tabId: tabId)
      }
      self.model.onTabClosed = { [weak observers] tabId in
        observers?.detach(tabId: tabId)
      }

      // Attach writer + detector to the initial default tab.
      for (tab, session) in model.allSessions() {
        transcripts.attachTranscriptWriter(to: session, tabId: tab.id)
        observers.attach(session: session, tabId: tab.id)
      }

      // Production parity: AppDelegate calls
      // `PersistenceCoordinator.load()` at launch BEFORE the user
      // can interact with the app, and pipes the loaded state into
      // `AppModel.replaceTabs(from:)`. The headless runtime now
      // does the same so launch-time bugs (corrupt-rename, restore
      // failures, missing transcripts) reproduce here.
      if restorePersistedState, let restored = coordinator.load() {
        if terminalBackend == .laband {
          pendingAgentRestoreCandidatesByTab = Dictionary(
            uniqueKeysWithValues: AgentRestorePicker.candidates(from: restored).map {
              ($0.tabId, $0)
            })
        } else {
          pendingAgentRestoreCandidatesByTab = [:]
        }
        model.replaceTabs(from: restored)
        if terminalBackend != .laband {
          Self.applyRestoreLaunchPlans(for: restored, model: model)
        }
      }
      // Production parity: if restore left zero tabs (empty window or
      // every restore spawn threw), fall back to a fresh default tab
      // — the same path the "+" button uses.
      if model.tabs.isEmpty {
        _ = try? model.createTab()
      }

      coordinator.attach(model)
      coordinator.scheduleSave()
    } else {
      self.persistenceStore = nil
      self.transcriptHost = nil
      self.persistenceCoordinator = nil
      self.agentObserverHost = nil
    }

    self.windowWidth = 200 + initialCols * Int(cs.width)
    self.windowHeight = initialRows * Int(cs.height)

    self.surface = BitmapSurface(
      width: max(windowWidth, 1),
      height: max(windowHeight, 1)
    )
    self.renderer = SoftwareRenderer(surface: surface, fontAtlas: fa)
    self.rendererBackend = makeRendererBackend(
      selection: rendererSelection,
      fontAtlas: fa,
      sidebarFontAtlas: fa,
      pixelWidth: max(windowWidth, 1),
      pixelHeight: max(windowHeight, 1),
      scale: 1)
    self.surfaceController = TerminalSurfaceController(
      model: model,
      cellWidth: Int(cs.width),
      cellHeight: Int(cs.height),
      sidebarWidth: CGFloat(200),
      sidebarCellWidth: cs.width,
      sidebarCellHeight: cs.height,
      captureSink: initialRecorder
    )
    self.enableBackendReadbackIfNeededUnlocked()
    self.rendererBackend.setSurfaceTransparency(
      RendererSurfaceTransparency(isOpaque: effectiveTransparency.isSurfaceOpaque))

    if terminalBackend == .laband {
      try configureLabandBackendUnlocked()
    }

    if let r = runner {
      try r.apply(to: model)
      self.fixtureURL = fixtureURL
      self.fixtureRunner = r
      self.fixtureStepIndex = r.fixture.steps.count
    }

    if initialRecorder != nil {
      model.recordExistingStateForCapture()
    }

    // Set after all stored properties are initialized so the self-capturing
    // closure is legal. The hook fires only when OSC 133 bytes arrive, which
    // cannot happen before init returns, so initial tabs are still covered.
    model.onShellIntegrationChange = { [weak self] tabId, state in
      self?.recordShellIntegrationEvent(tabId: tabId, state: state)
    }
    model.onAttentionNotification = { [weak self] event in
      guard let self else { return }
      if event.source == .osc {
        self.recordAgentNotificationEvent(tabId: event.tabId, text: event.body)
      }
      let decision: AttentionNotificationDecision =
        event.category == .needsAction
        ? AttentionNotificationDecision(event: event, action: .posted)
        : AttentionNotificationDecision(
          event: event, action: .suppressed, suppressionReason: .categoryDisabled)
      self.model.recordAttentionNotificationDecision(decision)
      guard decision.action == .posted else { return }
      // Headless parity with MainWindowController's banner journaling: no
      // banner is posted, but the policy decision is observable.
      self.model.tabJournal.note(
        tabId: event.tabId, note: TabStateJournal.bannerPostedNote, text: event.body)
    }
    // Headless has no user attention; never treat a tab as frontmost so the
    // synthetic awaiting-input badge always raises (tests rely on this).
    model.isTabFrontmost = { _ in false }
    // OSC 52 clipboard parity: a program copying via `ESC ] 52 ; c ; <base64>`
    // mirrors into the debug clipboard and the event stream (the headless
    // counterpart of MainWindowController's NSPasteboard write). The read
    // provider serves that same debug clipboard; read replies stay gated by
    // model.osc52ReadEnabled (off by default).
    model.onClipboardWrite = { [weak self] tabId, data in
      self?.recordClipboardOSC52Write(tabId: tabId, data: data)
    }
    model.clipboardReadProvider = { [weak self] in
      guard let self else { return nil }
      return self.withRuntimeLock { Data(self.debugClipboard.utf8) }
    }
    // OSC 7 cwd parity: surface a shell's working-directory report on the event
    // stream (the cwd itself is adopted by the shared metadata path).
    model.onWorkingDirectoryChange = { [weak self] tabId, cwd in
      self?.recordWorkingDirectoryEvent(tabId: tabId, cwd: cwd)
    }

    cjkFontSettingsObserver = NotificationCenter.default.addObserver(
      forName: CJKFontSettings.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.withRuntimeLock {
        self.refreshCJKFontCascadeUnlocked()
      }
    }

    renderFrameUnlocked()
  }

  deinit {
    if let cjkFontSettingsObserver {
      NotificationCenter.default.removeObserver(cjkFontSettingsObserver)
    }
    shutdown(interrupted: true)
  }

  private static func makeSession(
    size: LabanTerminalSize,
    mode: HeadlessSessionMode,
    shellLaunch: ShellIntegrationLaunch = .passthrough
  ) throws -> Session {
    switch mode {
    case .fixture:
      return try Session.fixture(size: size)
    case .realShell:
      // Parity with MainWindowController: thread the shell-integration
      // overlay env into the spawned shell. The headless harness runs
      // /bin/sh, which has no overlay, so this is `.passthrough` in
      // practice — but the subsystem is wired into both runtimes.
      // Identity is a live setting: resolve per spawn, matching
      // MainWindowController's spawn-time merge.
      return try Session.debugShell(
        size: size,
        extraEnvironment:
          shellLaunch.withTerminalIdentity(TerminalIdentitySettings.identity())
          .environmentOverrides)
    }
  }

  /// Install the OSC 133 overlay for the headless harness's shell, mirroring
  /// `MainWindowController.installShellIntegrationOverlay`. The harness uses
  /// `/bin/sh`, which has no overlay, so this returns `.passthrough`; the call
  /// exists for runtime parity and to exercise the install path headlessly.
  private static func installShellIntegrationOverlay() -> ShellIntegrationLaunch {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-headless-shell-integration-\(UUID().uuidString)")
    return
      (try? ShellIntegrationOverlay.install(
        shellPath: "/bin/sh", baseDirectory: base,
        environment: ProcessInfo.processInfo.environment)) ?? .passthrough
  }

  // MARK: - Terminal session client backend

  private func configureLabandBackendUnlocked() throws {
    let setup = try Self.connectOrStartLaband(runId: runId, artifactsURL: artifactsURL)
    terminalSessionClient = setup.client
    labandProcess = setup.process
    ownsLabandProcess = setup.ownsProcess
    labandSocketPath = setup.socketPath
    for tab in model.tabs {
      try ensureTerminalClientSessionUnlocked(for: tab)
    }
  }

  func prepareAgentRestorePickerUnlocked(for state: WorkspaceState?) {
    guard terminalBackend == .laband, let state else {
      pendingAgentRestoreCandidatesByTab = [:]
      return
    }
    pendingAgentRestoreCandidatesByTab = Dictionary(
      uniqueKeysWithValues: AgentRestorePicker.candidates(from: state).map { ($0.tabId, $0) })
  }

  private static func connectOrStartLaband(
    runId: String,
    artifactsURL: URL
  ) throws -> (
    client: LabandTerminalSessionClient, process: Process?, ownsProcess: Bool, socketPath: String
  ) {
    let env = ProcessInfo.processInfo.environment
    let socketPath = env["LABAN_LABAND_SOCKET"] ?? ".tmp/\(runId)/laband.sock"
    if let client = try? LabandTerminalSessionClient(socketPath: socketPath) {
      return (client, nil, false, socketPath)
    }

    let labandPath = env["LABAN_LABAND_BIN"] ?? ".build/debug/laband"
    let executableURL: URL
    if labandPath.hasPrefix("/") {
      executableURL = URL(fileURLWithPath: labandPath)
    } else {
      executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(labandPath)
    }
    let journalURL = artifactsURL.appendingPathComponent("laband", isDirectory: true)
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: journalURL,
      withIntermediateDirectories: true
    )

    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
      "--socket", socketPath,
      "--journal", journalURL.path,
    ]
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let stdoutURL = artifactsURL.appendingPathComponent("laband.stdout.log")
    let stderrURL = artifactsURL.appendingPathComponent("laband.stderr.log")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
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
        return (client, process, true, socketPath)
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    process.terminate()
    throw TerminalSessionClientError.protocolError(
      "timed out connecting to laband at \(socketPath): \(String(describing: lastError))")
  }

  func ensureTerminalClientSessionUnlocked(for tab: Tab) throws {
    guard let client = terminalSessionClient else { return }
    if terminalClientSessionInfoById[tab.sessionId] != nil { return }
    let remoteSessionId = terminalClientLogicalSessionId(for: tab)
    if let existing = try? client.attachSession(logicalSessionId: remoteSessionId),
      existing.lifecycleState == .running
    {
      terminalClientSessionInfoById[tab.sessionId] = existing
      pendingAgentRestoreCandidatesByTab.removeValue(forKey: tab.id)
      attachSnapshotRingIfAvailable(client: client, localSessionId: tab.sessionId)
      return
    }
    if pendingAgentRestoreCandidatesByTab[tab.id] != nil {
      appendEvent(EventEntry(kind: "agent.restore.picker.presented", tabId: tab.id))
      return
    }
    let size = model.terminalSize
    let launch = Self.labandLaunchRequest(
      size: size,
      logicalSessionId: remoteSessionId
    )
    let info = try client.createSession(
      launch)
    terminalClientSessionInfoById[tab.sessionId] = info
    attachSnapshotRingIfAvailable(client: client, localSessionId: tab.sessionId)
  }

  private static func labandLaunchRequest(
    size: LabanTerminalSize,
    logicalSessionId: String
  ) -> TerminalSessionLaunchRequest {
    let env = ProcessInfo.processInfo.environment
    if let command = env["LABAN_LABAND_SESSION_COMMAND"], !command.isEmpty {
      return TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-lc", command],
        cwd: FileManager.default.currentDirectoryPath,
        rows: Int(size.rows),
        cols: Int(size.cols),
        logicalSessionId: logicalSessionId
      )
    }
    return TerminalSessionLaunchRequest(
      executable: "/bin/cat",
      argv: ["/bin/cat"],
      cwd: FileManager.default.currentDirectoryPath,
      rows: Int(size.rows),
      cols: Int(size.cols),
      logicalSessionId: logicalSessionId
    )
  }

  func terminalClientRemoteSessionId(for localSessionId: Session.ID) -> String {
    terminalClientSessionInfoById[localSessionId]?.logicalSessionId ?? localSessionId
  }

  private func terminalClientLogicalSessionId(for tab: Tab) -> String {
    terminalBackend == .laband ? tab.id : tab.sessionId
  }

  func attachSnapshotRingIfAvailable(
    client: TerminalSessionClient,
    localSessionId: Session.ID
  ) {
    guard let laband = client as? LabandTerminalSessionClient else { return }
    let remoteSessionId = terminalClientRemoteSessionId(for: localSessionId)
    _ = try? laband.attachSnapshotRing(sessionId: remoteSessionId)
    if let refreshed = try? laband.attachSession(logicalSessionId: remoteSessionId) {
      terminalClientSessionInfoById[localSessionId] = refreshed
    }
  }

  func refreshTerminalClientSessionInfoUnlocked() {
    guard let client = terminalSessionClient else { return }
    do {
      let localSessionIdByLogicalId = Dictionary(
        uniqueKeysWithValues: model.tabs.map {
          (terminalClientLogicalSessionId(for: $0), $0.sessionId)
        })
      for info in try client.listSessions() {
        let localSessionId =
          localSessionIdByLogicalId[info.logicalSessionId] ?? info.logicalSessionId
        terminalClientSessionInfoById[localSessionId] = info
      }
    } catch {
      appendError(kind: "laband.listSessions.failed", message: String(describing: error))
    }
  }

  func terminalClientSnapshotUnlocked(sessionId: Session.ID) -> LabandSnapshotResponse? {
    guard let client = terminalSessionClient else { return nil }
    do {
      let snapshot = try client.snapshot(sessionId: terminalClientRemoteSessionId(for: sessionId))
      return snapshot
    } catch {
      appendError(
        kind: "laband.snapshot.failed",
        message: String(describing: error),
        sessionId: sessionId
      )
      return nil
    }
  }

  func terminateTerminalClientSessionUnlocked(sessionId: Session.ID) {
    guard let client = terminalSessionClient else { return }
    do {
      terminalClientSessionInfoById[sessionId] = try client.terminate(
        sessionId: terminalClientRemoteSessionId(for: sessionId))
    } catch {
      appendError(
        kind: "laband.terminate.failed",
        message: String(describing: error),
        sessionId: sessionId
      )
    }
  }

  func shutdownTerminalClientUnlocked(terminateRemoteSessions: Bool = false) {
    guard let client = terminalSessionClient else { return }
    var shouldStopOwnedLaband = false
    if let laband = client as? LabandTerminalSessionClient {
      if terminateRemoteSessions {
        for sessionId in Array(terminalClientSessionInfoById.keys) {
          if terminalClientSessionInfoById[sessionId]?.lifecycleState == .running {
            terminateTerminalClientSessionUnlocked(sessionId: sessionId)
          }
        }
      }
      let hasRunningSession = terminalClientSessionInfoById.values.contains {
        $0.lifecycleState == .running
      }
      shouldStopOwnedLaband = terminateRemoteSessions || !hasRunningSession
      if shouldStopOwnedLaband && ownsLabandProcess {
        try? laband.shutdownWhenIdle()
      }
      laband.close()
    } else {
      for sessionId in Array(terminalClientSessionInfoById.keys) {
        if terminalClientSessionInfoById[sessionId]?.lifecycleState == .running {
          terminateTerminalClientSessionUnlocked(sessionId: sessionId)
        }
      }
    }
    terminalSessionClient = nil
    if ownsLabandProcess, let process = labandProcess, process.isRunning {
      if shouldStopOwnedLaband {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
          usleep(50_000)
        }
        if process.isRunning {
          process.terminate()
          process.waitUntilExit()
        }
      }
    }
    labandProcess = nil
    ownsLabandProcess = false
  }

  // MARK: - Server ready notification

  public func emitServerReady() {
    lock.lock()
    defer { lock.unlock() }
    appendEvent(EventEntry(kind: "server.ready"))
  }

  // MARK: - Render (always call under lock or from init)

  func renderFrameUnlocked() {
    let frameStart = monotonicNow()
    var terminalPollMs = 0.0
    var snapshotMs = 0.0
    var commandExtractionMs = 0.0
    let frame = currentFrame + 1

    var timer = monotonicNow()
    _ = surfaceController.syncSessions(
      captureFrame: frame,
      polling: .pollAllSessions,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    terminalPollMs += elapsedMs(since: timer)

    captureRecorder?.record(CaptureTimelineEvent(kind: .frameBegin, frame: frame))

    timer = monotonicNow()
    let activeSelection = model.activeTab.flatMap { selectionBySession[$0.sessionId] }
    let activePreedit = model.activeTab.flatMap { preeditBySession[$0.sessionId] }
    let surfaceFrame = surfaceController.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: frame,
        viewportWidth: CGFloat(windowWidth),
        viewportHeight: CGFloat(windowHeight),
        cursorBlinkVisible: true,
        accessibilityVisualOptions: TerminalAccessibilityVisualOptions(
          increaseContrast: accessibilityDisplayFlags.increaseContrast,
          differentiateWithoutColor: accessibilityDisplayFlags.differentiateWithoutColor,
          reduceTransparency: accessibilityDisplayFlags.reduceTransparency),
        backgroundCompositingOptions: TerminalBackgroundCompositingOptions(
          opacity: UInt8((effectiveTransparency.backgroundOpacity * 255).rounded()),
          applyToExplicitCellBackgrounds:
            effectiveTransparency.applyToExplicitCellBackgrounds),
        snapshotBackgroundCapability: .inProcess,
        selection: activeSelection,
        // Headless PNGs are part of the transparency contract. Emit the same
        // resolved-alpha terminal canvas as the visible app so screenshots do
        // not leave the terminal region at transparent black.
        includeTerminalAreaBackground: true,
        requireActiveSnapshot: false,
        forceFullDamage: true,
        surfaceWidth: surface.width,
        surfaceHeight: surface.height,
        surfaceScale: Double(surface.scale),
        preedit: activePreedit?.text,
        preeditCaretCells: activePreedit?.caretCells ?? 0,
        userCursorStyle: CursorSettings.style,
        userCursorBlinkEnabled: CursorSettings.blinkEnabled)
    )
    let surfaceBuildMs = elapsedMs(since: timer)
    snapshotMs = surfaceFrame?.snapshotMs ?? 0
    commandExtractionMs += max(0, surfaceBuildMs - snapshotMs)
    renderCommandsUnlocked(
      surfaceFrame?.commands ?? [],
      captureFrame: frame,
      frameStart: frameStart,
      terminalPollMs: terminalPollMs,
      snapshotMs: snapshotMs,
      commandExtractionMs: commandExtractionMs
    )
  }

  private func renderCommandsUnlocked(
    _ cmds: [FrameCommand],
    captureFrame: Int? = nil,
    frameStart: DispatchTime? = nil,
    terminalPollMs: Double = 0,
    snapshotMs: Double = 0,
    commandExtractionMs: Double = 0
  ) {
    let renderStart = monotonicNow()
    rendererBackend.render(cmds)
    syncSoftwareRendererIfNeededUnlocked()
    let renderMs = elapsedMs(since: renderStart)
    lastFrameCommands = cmds
    lastDrawStats = countStats(cmds)
    currentFrame += 1
    let frame = captureFrame ?? currentFrame
    let totalMs = frameStart.map { elapsedMs(since: $0) } ?? renderMs
    timing = RuntimeTiming(
      lastFrameMs: totalMs,
      terminalPollMs: terminalPollMs,
      snapshotMs: snapshotMs,
      commandExtractionMs: commandExtractionMs,
      renderMs: renderMs,
      screenshotMs: timing.screenshotMs
    )
    if let pngData = rendererBackend.pngData {
      captureRecorder?.recordRenderedFrame(
        frame: frame,
        pngData: pngData,
        width: rendererBackend.surfaceWidth,
        height: rendererBackend.surfaceHeight,
        scale: Double(rendererBackend.surfaceScale),
        backend: rendererBackend.rendererStatus.effectiveRenderer)
    }
    appendEvent(EventEntry(kind: "frame.rendered", frame: currentFrame))
  }

  private func countStats(_ cmds: [FrameCommand]) -> DrawStats {
    var s = DrawStats()
    for cmd in cmds {
      switch cmd {
      case .rect(_, _, let src, _):
        s.backgroundRects += 1
        if src == .terminal { s.cells += 1 }
      case .glyphRun:
        s.glyphs += 1
      case .cursor:
        s.cursor = true
      case .texturedQuad:
        s.images += 1
      default:
        break
      }
    }
    return s
  }

  // MARK: - Events

  func monotonicNow() -> DispatchTime {
    DispatchTime.now()
  }

  func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
  }

  func appendEvent(_ e: EventEntry) {
    logs.appendEvent(e)
  }

  func appendTerminalLog(sessionId: String?, direction: String, bytes: [UInt8]) {
    logs.appendTerminalLog(
      sessionId: sessionId,
      direction: direction,
      bytes: bytes,
      frame: currentFrame
    )
  }

  func appendError(
    level: String = "error",
    kind: String,
    message: String,
    sessionId: String? = nil,
    tabId: String? = nil
  ) {
    logs.appendError(
      level: level,
      kind: kind,
      message: message,
      sessionId: sessionId,
      tabId: tabId
    )
  }

  func appendInputEnvelope(_ e: InputEventEnvelope) {
    let recorded = logs.appendInputEnvelope(e)
    captureRecorder?.recordInput(recorded)
  }

  // MARK: - Snapshot helpers

  func snapshotStatus(_ snap: UnsafePointer<LabanSnapshot>) -> String {
    switch snap.pointee.status {
    case 0: return "running"
    case 1, 2: return "exited"
    default: return "failed"
    }
  }

  func terminalMousePosition(x: Int, y: Int) -> (x: Float, y: Float) {
    DebugMouseInput.terminalSurfacePosition(
      windowX: x,
      windowY: y,
      windowHeight: windowHeight,
      sidebarWidth: sidebarWidth
    )
  }

  var terminalSurfaceWidth: Int {
    DebugMouseInput.terminalSurfaceWidth(windowWidth: windowWidth, sidebarWidth: sidebarWidth)
  }

}
