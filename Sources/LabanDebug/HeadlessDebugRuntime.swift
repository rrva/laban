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
  let artifactsURL: URL
  let fixtureRootURL: URL
  let deterministic: Bool

  var model: AppModel
  let fontAtlas: FontAtlas
  let cellWidth: Int
  let cellHeight: Int
  let sidebarWidth: Int = 200
  var windowWidth: Int
  var windowHeight: Int
  var surface: BitmapSurface
  var renderer: SoftwareRenderer
  var surfaceController: TerminalSurfaceController

  var currentFrame: Int = 0
  var lastFrameCommands: [FrameCommand] = []
  var lastDrawStats = DrawStats()
  var debugClipboard: String = ""
  var selectionBySession: [Session.ID: TerminalSelection] = [:]
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
  var captureRecorder: CaptureRecorder?
  var lastCaptureManifestPath: String?
  var lastCaptureRunId: String?
  var lastCaptureDirectory: String?

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

  // MARK: - Init

  public init(
    fixtureURL: URL?,
    artifactsURL: URL,
    tempURL: URL?,
    deterministic: Bool,
    runId: String,
    fixtureRootURL: URL? = nil,
    sessionMode: HeadlessSessionMode = .fixture,
    captureName: String? = nil,
    captureScreenshots: CaptureScreenshotPolicy = .marked,
    persistenceBaseURL: URL? = nil,
    restoreOnLaunchEnabled: @escaping () -> Bool = { true }
  ) throws {
    self.runId = runId
    self.artifactsURL = artifactsURL
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

    let fa = FontAtlas(pointSize: 14)
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

    self.model = try AppModel(
      initialSize: initSize,
      sessionFactory: { size in
        let session = try Self.makeSession(size: size, mode: initialSessionMode)
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
      self.model.restoredSessionFactory = { sz, _ in
        try Self.makeSession(size: sz, mode: initialSessionMode)
      }
      self.model.restoredDeferredSessionFactory = { spec in
        // fixture sessions don't really "spawn"; deferred mode is
        // only meaningful for real shells. For fixture/debug mode
        // we just make a fresh session and replay the transcript
        // into it before returning.
        let session: Session
        switch initialSessionMode {
        case .fixture:
          session = try Session.fixture(size: spec.size)
        case .realShell:
          session = try Session.makeDeferred(size: spec.size, cwd: spec.cwd)
        }
        if let url = spec.transcriptURL {
          TranscriptRenderer.render(
            fileURL: url,
            into: session,
            altBufferAtQuit: spec.altBufferAtQuit)
        }
        if case .realShell = initialSessionMode {
          _ = session.startSpawn(
            overrideCwd: spec.cwdFallbackApplied ? spec.cwd : nil)
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
      if let restored = coordinator.load() {
        model.replaceTabs(from: restored)
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
    self.surfaceController = TerminalSurfaceController(
      model: model,
      cellWidth: Int(cs.width),
      cellHeight: Int(cs.height),
      sidebarWidth: CGFloat(200),
      sidebarCellWidth: cs.width,
      sidebarCellHeight: cs.height,
      captureSink: initialRecorder
    )

    if let r = runner {
      try r.apply(to: model)
      self.fixtureURL = fixtureURL
      self.fixtureRunner = r
      self.fixtureStepIndex = r.fixture.steps.count
    }

    if initialRecorder != nil {
      model.recordExistingStateForCapture()
    }

    renderFrameUnlocked()
  }

  private static func makeSession(
    size: LabanTerminalSize,
    mode: HeadlessSessionMode
  ) throws -> Session {
    switch mode {
    case .fixture:
      return try Session.fixture(size: size)
    case .realShell:
      return try Session.debugShell(size: size)
    }
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
    let surfaceFrame = surfaceController.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: frame,
        viewportWidth: CGFloat(windowWidth),
        viewportHeight: CGFloat(windowHeight),
        cursorBlinkVisible: true,
        selection: activeSelection,
        includeTerminalAreaBackground: false,
        requireActiveSnapshot: false,
        forceFullDamage: true,
        surfaceWidth: surface.width,
        surfaceHeight: surface.height,
        surfaceScale: Double(surface.scale))
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
    renderer.render(cmds)
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
    captureRecorder?.recordRenderedFrame(frame: frame, surface: surface)
    appendEvent(EventEntry(kind: "frame.rendered", frame: currentFrame))
  }

  private func countStats(_ cmds: [FrameCommand]) -> DrawStats {
    var s = DrawStats()
    for cmd in cmds {
      switch cmd {
      case .rect(_, _, let src):
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
