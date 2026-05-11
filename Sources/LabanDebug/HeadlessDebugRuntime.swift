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
  private static let discoveryEndpoints: [DebugDiscoveryEndpoint] = [
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug",
      category: "discovery",
      summary: "List the live debug endpoints, controls, and command examples.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/discovery.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/capabilities",
      category: "discovery",
      summary: "Alias for /debug for agents that look for a capabilities document.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/discovery.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/health",
      category: "readiness",
      summary: "Check whether the process is ready and report the current frame.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/state",
      category: "state",
      summary: "Return tabs, active session identity, window size, and focus state.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/state.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Return the current rendered surface as PNG bytes.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/screenshot",
      category: "artifacts",
      summary: "Write a screenshot PNG under the artifact directory.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/screenshot-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/actions",
      category: "control",
      summary: "Drive tabs, input, mouse, clipboard, selection, and frames.",
      queryParameters: [],
      requestSchema: "schemas/debug/action.schema.json",
      responseSchema: "schemas/debug/action-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/wait",
      category: "control",
      summary: "Block until a frame, state, text, event, or render condition is true.",
      queryParameters: [],
      requestSchema: "schemas/debug/wait.schema.json",
      responseSchema: "schemas/debug/wait-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/sessions",
      category: "state",
      summary: "Return terminal-session lifecycle and metadata for all tabs.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/sessions.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/sessions/<id>",
      category: "state",
      summary: "Return one terminal session, optionally with bounded visible-grid cells.",
      queryParameters: ["includeGrid"],
      requestSchema: nil,
      responseSchema: "schemas/debug/session.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/render",
      category: "rendering",
      summary: "Return surface, viewport, cell size, damage, and draw stats.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/render.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/frame-commands",
      category: "rendering",
      summary: "Return bounded frame commands, optionally filtered by source.",
      queryParameters: ["source", "limit"],
      requestSchema: nil,
      responseSchema: "schemas/debug/frame-commands.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/render-trace",
      category: "rendering",
      summary: "Return render contributors, resources, passes, probes, and invariants.",
      queryParameters: [],
      requestSchema: "schemas/debug/render-trace-request.schema.json",
      responseSchema: "schemas/debug/render-trace.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/pixel-probe",
      category: "exploration",
      summary: "Sample exact pixels and rectangular regions from the rendered surface.",
      queryParameters: [],
      requestSchema: "schemas/debug/pixel-probe.schema.json",
      responseSchema: "schemas/debug/pixel-probe-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/atlas",
      category: "rendering",
      summary: "Return font, cell, and glyph diagnostics for the active renderer.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/atlas.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/snapshot",
      category: "exploration",
      summary: "Write a one-shot diagnostic bundle with JSON state and a screenshot.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/snapshot-result.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/events",
      category: "logs",
      summary: "Return bounded app/debug events after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/events.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/input-log",
      category: "logs",
      summary: "Return keyboard/text routing diagnostics after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/input-log.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/terminal-log",
      category: "logs",
      summary: "Return bounded escaped terminal input/output byte-flow diagnostics.",
      queryParameters: ["sessionId", "since", "limit"],
      requestSchema: nil,
      responseSchema: "schemas/debug/terminal-log.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/timing",
      category: "logs",
      summary: "Return frame and endpoint timing fields for sluggishness diagnosis.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/timing.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/metrics",
      category: "logs",
      summary: "Return local counters for frames, input, terminal bytes, and draw work.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/metrics.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/errors",
      category: "logs",
      summary: "Return structured warnings and errors after a sequence number.",
      queryParameters: ["since"],
      requestSchema: nil,
      responseSchema: "schemas/debug/errors.schema.json"),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/fixture",
      category: "control",
      summary: "Load, restart, or step fixture sessions without restarting the server.",
      queryParameters: [],
      requestSchema: "schemas/debug/fixture-control.schema.json",
      responseSchema: "schemas/debug/fixture-control.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/capture/status",
      category: "capture",
      summary: "Return whether full capture recording is active.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/start",
      category: "capture",
      summary: "Start full capture recording under the artifact directory.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/stop",
      category: "capture",
      summary: "Stop full capture recording and return manifest metadata.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "POST",
      path: "/debug/capture/snapshot",
      category: "capture",
      summary: "Write a snapshot inside the active capture run.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: nil),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/selection",
      category: "state",
      summary: "Return the current terminal selection projection.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/selection.schema.json"),
    DebugDiscoveryEndpoint(
      method: "GET",
      path: "/debug/clipboard",
      category: "state",
      summary: "Return debug clipboard copy/paste diagnostics.",
      queryParameters: [],
      requestSchema: nil,
      responseSchema: "schemas/debug/clipboard.schema.json"),
  ]

  private static let discoveryActions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(name: "newTab", summary: "Create and select a new tab."),
    DebugDiscoveryControl(name: "closeTab", summary: "Close a tab by id or the active tab."),
    DebugDiscoveryControl(name: "selectTab", summary: "Select a tab by tabId."),
    DebugDiscoveryControl(name: "resizeWindow", summary: "Resize the headless window surface."),
    DebugDiscoveryControl(name: "typeText", summary: "Send text through terminal input."),
    DebugDiscoveryControl(name: "feedOutput", summary: "Inject fixture terminal output bytes."),
    DebugDiscoveryControl(name: "advanceFrames", summary: "Render one or more additional frames."),
    DebugDiscoveryControl(name: "key", summary: "Send a structured key event."),
    DebugDiscoveryControl(name: "mouseWheel", summary: "Send a mouse wheel event."),
    DebugDiscoveryControl(name: "click", summary: "Send a click to sidebar or terminal content."),
    DebugDiscoveryControl(name: "setClipboardText", summary: "Set the debug clipboard text."),
    DebugDiscoveryControl(name: "paste", summary: "Paste debug clipboard text into the terminal."),
    DebugDiscoveryControl(name: "copy", summary: "Copy the current terminal selection."),
    DebugDiscoveryControl(name: "setSelection", summary: "Set terminal selection cell anchors."),
    DebugDiscoveryControl(name: "scrollViewport", summary: "Move terminal scrollback viewport."),
    DebugDiscoveryControl(name: "setTabTitle", summary: "Set a manual tab title."),
    DebugDiscoveryControl(name: "freezeTabTitle", summary: "Freeze or unfreeze title updates."),
    DebugDiscoveryControl(name: "clearTabTitle", summary: "Clear the manual tab title."),
    DebugDiscoveryControl(
      name: "setTabMetadata", summary: "Set workspace, process, or agent metadata."),
  ]

  private static let discoveryWaitConditions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(name: "frameAtLeast", summary: "Wait until frame is at least a value."),
    DebugDiscoveryControl(name: "tabCount", summary: "Wait until a tab count is reached."),
    DebugDiscoveryControl(name: "activeTab", summary: "Wait until a tab is active."),
    DebugDiscoveryControl(name: "sessionStatus", summary: "Wait for a session status."),
    DebugDiscoveryControl(name: "titleEquals", summary: "Wait for the active title."),
    DebugDiscoveryControl(
      name: "textVisible", summary: "Wait until visible terminal text appears."),
    DebugDiscoveryControl(name: "renderCommandSeen", summary: "Wait for a render command kind."),
    DebugDiscoveryControl(name: "eventSeen", summary: "Wait for an event kind."),
    DebugDiscoveryControl(
      name: "renderTraceInvariant",
      summary: "Wait for a render-trace invariant level and kind."),
  ]

  private static let discoveryFixtureActions: [DebugDiscoveryControl] = [
    DebugDiscoveryControl(
      name: "load", summary: "Load a fixture JSON file by relative path under fixtureRoot."),
    DebugDiscoveryControl(name: "restart", summary: "Restart the current fixture from step zero."),
    DebugDiscoveryControl(name: "step", summary: "Apply one or more fixture steps."),
  ]

  private static let discoveryExamples: [DebugDiscoveryExample] = [
    DebugDiscoveryExample(
      title: "List capabilities",
      command: #"curl -H "Authorization: Bearer $DEBUG_TOKEN" "$DEBUG_URL/debug" | jq"#),
    DebugDiscoveryExample(
      title: "Type text",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/actions" -d @action.json"#
    ),
    DebugDiscoveryExample(
      title: "Wait for visible text",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/wait" -d @wait.json"#
    ),
    DebugDiscoveryExample(
      title: "Write a diagnostic bundle",
      command:
        #"curl -H "Authorization: Bearer $DEBUG_TOKEN" -X POST "$DEBUG_URL/debug/snapshot" -d '{}'"#
    ),
  ]

  private let lock = NSLock()

  public let runId: String
  private var mode: String
  private var sessionMode: HeadlessSessionMode
  let artifactsURL: URL
  private let fixtureRootURL: URL
  private let deterministic: Bool

  var model: AppModel
  let fontAtlas: FontAtlas
  let cellWidth: Int
  let cellHeight: Int
  let sidebarWidth: Int = 200
  var windowWidth: Int
  var windowHeight: Int
  var surface: BitmapSurface
  var renderer: SoftwareRenderer
  private var surfaceController: TerminalSurfaceController

  var currentFrame: Int = 0
  var lastFrameCommands: [FrameCommand] = []
  var lastDrawStats = DrawStats()
  var debugClipboard: String = ""
  var selectionBySession: [Session.ID: TerminalSelection] = [:]
  var lastCopyText: String?
  var lastPasteText: String?
  var lastPasteUsedBracketedPaste: Bool?
  var lastPasteIgnoredNonText: Bool?
  private var logs = DebugRuntimeLogStore()
  var timing = RuntimeTiming()
  private let startedAt = DispatchTime.now()
  var screenshotCount: Int = 0
  private var fixtureURL: URL?
  private var fixtureRunner: FixtureRunner?
  private var fixtureStepIndex: Int = 0
  private var captureRecorder: CaptureRecorder?
  private var lastCaptureManifestPath: String?
  private var lastCaptureRunId: String?
  private var lastCaptureDirectory: String?

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
    captureScreenshots: CaptureScreenshotPolicy = .marked
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

  private func monotonicNow() -> DispatchTime {
    DispatchTime.now()
  }

  private func elapsedMs(since start: DispatchTime) -> Double {
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

  private func snapshotStatus(_ snap: UnsafePointer<LabanSnapshot>) -> String {
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

  // MARK: - Session metadata synchronization

  private func syncSessionMetadataUnlocked() {
    _ = surfaceController.syncSessions(
      captureFrame: currentFrame + 1,
      polling: .pollAllSessions,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
  }

  private func tabResponse(for tab: Tab, index: Int) -> TabResponse {
    let metadata = tab.titleMetadata
    let statusStr = model.session(forTab: tab.id) != nil ? tab.status.debugString : "failed"
    return TabResponse(
      id: tab.id,
      index: index,
      title: metadata.displayTitle,
      displayTitle: metadata.displayTitle,
      titleSource: metadata.titleSource.rawValue,
      terminalTitle: metadata.terminalTitle,
      userTitle: metadata.userTitle,
      titleFrozen: metadata.titleFrozen,
      activityState: metadata.activityState.rawValue,
      lastActivityAt: metadata.lastActivityAt,
      lastOutputAt: metadata.lastOutputAt,
      unseenOutput: metadata.unseenOutput,
      exitStatus: metadata.exitStatus,
      workspace: metadata.workspace,
      process: metadata.process,
      agent: metadata.agent,
      active: tab.isActive,
      status: statusStr,
      sessionId: tab.sessionId
    )
  }

  private func sessionResponse(for tab: Tab, index _: Int, includeGrid: Bool) -> SessionResponse {
    let metadata = tab.titleMetadata
    let sessionObj = model.session(forTab: tab.id)
    var rows = 1
    var cols = 1
    var exitStatus: Int? = nil
    var mouseTracking = false
    var focusReporting = false
    var dirty = false
    var grid: SessionGridResponse? = nil

    if let session = sessionObj, let snap = session.snapshot() {
      defer { laban_snapshot_destroy(snap) }
      rows = max(Int(snap.pointee.rows), 1)
      cols = max(Int(snap.pointee.cols), 1)
      if snap.pointee.status != 0 { exitStatus = Int(snap.pointee.exit_status) }
      mouseTracking = snap.pointee.mouse_tracking != 0
      focusReporting = snap.pointee.focus_reporting != 0
      dirty = snap.pointee.dirty != 0
      if includeGrid {
        grid = sessionGridResponse(from: snap, maxCells: 2_000)
      }
    }
    if exitStatus == nil { exitStatus = metadata.exitStatus }

    var scrollbackLines = 0
    var viewportOffset = 0
    if let sessionObj, let vs = sessionObj.viewportState() {
      scrollbackLines = vs.scrollbackRows
      viewportOffset = vs.viewportOffset
    }

    let statusStr = sessionObj != nil ? tab.status.debugString : "failed"
    return SessionResponse(
      id: tab.sessionId, tabId: tab.id, pid: nil,
      status: statusStr, exitStatus: exitStatus,
      rows: rows, cols: cols,
      cellWidth: cellWidth, cellHeight: cellHeight,
      scrollbackLines: scrollbackLines, viewportOffset: viewportOffset,
      title: metadata.displayTitle,
      displayTitle: metadata.displayTitle,
      titleSource: metadata.titleSource.rawValue,
      terminalTitle: metadata.terminalTitle,
      userTitle: metadata.userTitle,
      titleFrozen: metadata.titleFrozen,
      activityState: metadata.activityState.rawValue,
      lastActivityAt: metadata.lastActivityAt,
      lastOutputAt: metadata.lastOutputAt,
      unseenOutput: metadata.unseenOutput,
      workspace: metadata.workspace,
      process: metadata.process,
      agent: metadata.agent,
      mouseTracking: mouseTracking,
      focusReporting: focusReporting,
      dirty: dirty,
      grid: grid
    )
  }

  private func sessionGridResponse(
    from snap: UnsafePointer<LabanSnapshot>,
    maxCells: Int
  ) -> SessionGridResponse {
    let snapshot = snap.pointee
    let rows = max(Int(snapshot.rows), 1)
    let cols = max(Int(snapshot.cols), 1)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      return SessionGridResponse(rows: rows, cols: cols, cells: [], truncated: false)
    }

    let links = snapshotHyperlinks(snapshot)
    var result: [SessionGridCellResponse] = []
    result.reserveCapacity(min(Int(snapshot.cell_count), maxCells))
    var truncated = false

    for row in 0..<rows {
      for col in 0..<cols {
        let idx = row * cols + col
        guard idx < Int(snapshot.cell_count) else { continue }
        let cell = cells[idx]
        guard cell.utf8_length > 0 else { continue }

        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        guard let text = String(bytes: buf, encoding: .utf8), !text.isEmpty else { continue }

        if result.count >= maxCells {
          truncated = true
          break
        }

        let hyperlink: String? = {
          let id = Int(cell.hyperlink_id)
          guard id > 0, id <= links.count else { return nil }
          return links[id - 1]
        }()

        result.append(
          SessionGridCellResponse(
            row: row,
            col: col,
            text: text,
            foreground: DebugFrameCommandSerializer.rgbaArray(cell.foreground_rgba),
            background: DebugFrameCommandSerializer.rgbaArray(cell.background_rgba),
            attributes: TextAttributes(rawValue: cell.flags).intersection(.renderableMask).names,
            wide: wideName(cell.wide),
            hyperlink: hyperlink
          ))
      }
      if truncated { break }
    }

    return SessionGridResponse(rows: rows, cols: cols, cells: result, truncated: truncated)
  }

  private func snapshotHyperlinks(_ snapshot: LabanSnapshot) -> [String] {
    let count = Int(snapshot.hyperlink_count)
    guard count > 0, let table = snapshot.hyperlink_uris else { return [] }
    var result: [String] = []
    result.reserveCapacity(count)
    for idx in 0..<count {
      result.append(table[idx].map { String(cString: $0) } ?? "")
    }
    return result
  }

  private func wideName(_ wide: UInt8) -> String {
    switch Int(wide) {
    case Int(LABAN_CELL_WIDE_WIDE): return "wide"
    case Int(LABAN_CELL_WIDE_SPACER_TAIL): return "spacerTail"
    case Int(LABAN_CELL_WIDE_SPACER_HEAD): return "spacerHead"
    default: return "narrow"
    }
  }

  // MARK: - Endpoints

  public func captureStatus() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    if let recorder = captureRecorder {
      return jsonEncode(
        CaptureStatusResponse(
          active: true,
          runId: recorder.runId,
          directory: recorder.directoryURL.path,
          manifestPath: nil,
          screenshots: recorder.screenshots.rawValue
        ))
    }
    return jsonEncode(
      CaptureStatusResponse(
        active: false,
        runId: lastCaptureRunId,
        directory: lastCaptureDirectory,
        manifestPath: lastCaptureManifestPath,
        screenshots: nil
      ))
  }

  public func startCapture(_ data: Data) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    if let recorder = captureRecorder {
      return jsonEncode(
        CaptureStartResponse(
          active: true,
          alreadyActive: true,
          runId: recorder.runId,
          directory: recorder.directoryURL.path,
          screenshots: recorder.screenshots.rawValue
        ),
        status: 409
      )
    }

    let body = data.isEmpty ? Data("{}".utf8) : data
    let req =
      (try? JSONDecoder().decode(CaptureStartRequest.self, from: body))
      ?? CaptureStartRequest()
    let policy = HeadlessDebugRuntime.capturePolicy(from: req.screenshots)
    let name = req.name ?? CaptureRecorder.makeRunId(name: nil)
    do {
      try CaptureRecorder.validateCaptureName(name)
      let recorder = try CaptureRecorder(
        artifactRoot: artifactsURL.appendingPathComponent("captures", isDirectory: true),
        name: name,
        screenshots: policy,
        executable: "laban-agent"
      )
      captureRecorder = recorder
      surfaceController.captureSink = recorder
      model.captureSink = recorder
      lastCaptureRunId = recorder.runId
      lastCaptureDirectory = recorder.directoryURL.path
      lastCaptureManifestPath = nil
      model.recordExistingStateForCapture()
      return jsonEncode(
        CaptureStartResponse(
          active: true,
          alreadyActive: false,
          runId: recorder.runId,
          directory: recorder.directoryURL.path,
          screenshots: recorder.screenshots.rawValue
        ))
    } catch {
      return jsonError("capture start failed: \(error)", status: 400)
    }
  }

  public func stopCapture() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    do {
      guard let result = try finishCaptureUnlocked(interrupted: false) else {
        if let manifest = lastCaptureManifestPath {
          return jsonEncode(
            CaptureStopResponse(
              active: false,
              runId: lastCaptureRunId,
              directory: lastCaptureDirectory,
              manifestPath: manifest
            ))
        }
        return jsonError("capture is not active", status: 400)
      }
      return jsonEncode(
        CaptureStopResponse(
          active: false,
          runId: result.runId,
          directory: result.directory,
          manifestPath: result.manifestPath
        ))
    } catch {
      return jsonError("capture stop failed: \(error)", status: 500)
    }
  }

  public func shutdown(interrupted: Bool = true) {
    lock.lock()
    defer { lock.unlock() }
    _ = try? finishCaptureUnlocked(interrupted: interrupted)
    model.closeAllSessions()
  }

  private func finishCaptureUnlocked(
    interrupted: Bool
  ) throws -> (runId: String, directory: String, manifestPath: String)? {
    guard let recorder = captureRecorder else {
      return nil
    }

    let finalPNG: Data?
    if recorder.screenshots == .none {
      finalPNG = nil
    } else {
      finalPNG = surface.pngData
    }
    let manifest = try recorder.finish(
      interrupted: interrupted,
      finalScreenshot: finalPNG,
      frame: currentFrame
    )
    captureRecorder = nil
    surfaceController.captureSink = nil
    model.captureSink = nil
    lastCaptureManifestPath = manifest.path
    lastCaptureRunId = recorder.runId
    lastCaptureDirectory = recorder.directoryURL.path
    return (recorder.runId, recorder.directoryURL.path, manifest.path)
  }

  public func captureSnapshot() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    guard let recorder = captureRecorder else {
      return jsonError("capture is not active", status: 400)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let serializer = DebugFrameCommandSerializer(cellWidth: cellWidth, cellHeight: cellHeight)
    let frameCommandBody =
      FrameCommandsResponse(
        frame: currentFrame,
        backend: "software",
        commands: lastFrameCommands.enumerated().map {
          serializer.listCommand($0.element, index: $0.offset, includeText: true)
        },
        truncated: false
      )
    var files: [String: Data] = [
      "state.json": stateUnlocked().body,
      "events.json": (try? enc.encode(logs.eventsResponse(since: 0))) ?? Data(),
      "input-log.json": (try? enc.encode(logs.inputLogResponse(since: 0))) ?? Data(),
      "frame-commands.json": (try? enc.encode(frameCommandBody)) ?? Data(),
    ]
    if let png = surface.pngData {
      files["screenshot.png"] = png
    }
    do {
      let rel = try recorder.writeSnapshotBundle(frame: currentFrame, files: files)
      return jsonEncode(["path": recorder.directoryURL.appendingPathComponent(rel).path])
    } catch {
      return jsonError("capture snapshot failed: \(error)", status: 500)
    }
  }

  public func health() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(HealthResponse(ok: true, mode: mode, frame: currentFrame, focused: true))
  }

  public func discovery() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    return jsonEncode(
      DebugDiscoveryResponse(
        name: "laban-debug",
        schema: "schemas/debug/discovery.schema.json",
        runId: runId,
        mode: mode,
        frame: currentFrame,
        artifactRoot: artifactsURL.path,
        fixtureRoot: fixtureRootURL.path,
        entrypoints: ["/debug", "/debug/capabilities"],
        endpoints: Self.discoveryEndpoints,
        actions: Self.discoveryActions,
        waitConditions: Self.discoveryWaitConditions,
        fixtureActions: Self.discoveryFixtureActions,
        examples: Self.discoveryExamples
      ))
  }

  private static func capturePolicy(from raw: String?) -> CaptureScreenshotPolicy {
    switch raw?.lowercased() {
    case "final": return .final
    case "all": return .all
    case "none": return .none
    default: return .marked
    }
  }

  public func state() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return stateUnlocked()
  }

  private func stateUnlocked() -> DebugResponse {
    syncSessionMetadataUnlocked()
    let tabs = model.tabs.enumerated().map { i, tab -> TabResponse in
      tabResponse(for: tab, index: i)
    }
    let activeTab = model.activeTab
    return jsonEncode(
      StateResponse(
        mode: mode,
        frame: currentFrame,
        window: WindowResponse(width: windowWidth, height: windowHeight, focused: true),
        tabs: tabs,
        activeTabId: activeTab?.id,
        activeSessionId: activeTab?.sessionId
      ))
  }

  public func screenshotBytes() throws -> (data: Data, frame: Int, width: Int, height: Int) {
    lock.lock()
    defer { lock.unlock() }
    let start = monotonicNow()
    guard let pngData = surface.pngData else { throw DebugServerError.encodingFailed }
    timing.screenshotMs = elapsedMs(since: start)
    screenshotCount += 1
    return (pngData, currentFrame, surface.width, surface.height)
  }

  public func writeScreenshotArtifact() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    let start = monotonicNow()
    guard let pngData = surface.pngData else {
      appendError(kind: "screenshot.encoding", message: "PNG encoding failed")
      return jsonError("PNG encoding failed", status: 500)
    }
    timing.screenshotMs = elapsedMs(since: start)
    screenshotCount += 1
    let ssDir = artifactsURL.appendingPathComponent("screenshots")
    do {
      try FileManager.default.createDirectory(at: ssDir, withIntermediateDirectories: true)
    } catch {
      appendError(
        kind: "screenshot.artifact",
        message: "failed to create screenshots dir: \(error)"
      )
      return jsonError("failed to create screenshots dir: \(error)", status: 500)
    }
    let fname = String(format: "frame-%06d.png", currentFrame)
    let fileURL = ssDir.appendingPathComponent(fname)
    do {
      try pngData.write(to: fileURL)
    } catch {
      appendError(kind: "screenshot.artifact", message: "failed to write screenshot: \(error)")
      return jsonError("failed to write screenshot: \(error)", status: 500)
    }
    appendEvent(EventEntry(kind: "screenshot.captured", frame: currentFrame, path: fileURL.path))
    captureRecorder?.recordScreenshot(frame: currentFrame, data: pngData)
    return jsonEncode(
      ScreenshotResult(
        path: fileURL.path,
        width: surface.width, height: surface.height,
        frame: currentFrame, target: "window"
      ))
  }

  public func applyAction(_ data: Data) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    guard let action = try? JSONDecoder().decode(DebugAction.self, from: data) else {
      appendError(kind: "action.invalid", message: "invalid action request")
      return jsonError("invalid action request")
    }
    return applyActionUnlocked(action)
  }

  func actionResult(ok: Bool) -> DebugResponse {
    let active = model.activeTab
    return jsonEncode(
      ActionResult(
        ok: ok, frame: currentFrame,
        activeTabId: active?.id, activeSessionId: active?.sessionId,
        error: nil
      ))
  }

  public func sessions() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    syncSessionMetadataUnlocked()

    let list = model.tabs.enumerated().map { idx, tab in
      sessionResponse(for: tab, index: idx, includeGrid: false)
    }

    return jsonEncode(SessionsResponse(sessions: list))
  }

  public func session(id: String, query: [String: String]) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    syncSessionMetadataUnlocked()

    guard let match = model.tabs.enumerated().first(where: { $0.element.sessionId == id }) else {
      return jsonError("session not found: \(id)", status: 404)
    }
    let includeGrid = query["includeGrid"] == "true"
    return jsonEncode(
      sessionResponse(for: match.element, index: match.offset, includeGrid: includeGrid))
  }

  // MARK: - Wait

  public func wait(_ data: Data) -> DebugResponse {
    guard let req = try? JSONDecoder().decode(WaitRequest.self, from: data) else {
      return jsonError("invalid wait request")
    }

    let startTime = Date()
    let timeoutSec = Double(req.timeoutMs) / 1000.0

    while true {
      lock.lock()
      syncSessionMetadataUnlocked()
      let satisfied = checkConditionUnlocked(req.condition)
      let frame = currentFrame
      if satisfied {
        lock.unlock()
        let elapsed = Date().timeIntervalSince(startTime) * 1000.0
        return jsonEncode(WaitResult(ok: true, frame: frame, elapsedMs: elapsed))
      }
      if deterministic {
        for tab in model.tabs {
          model.session(forTab: tab.id)?.poll()
        }
        renderFrameUnlocked()
      }
      lock.unlock()

      if Date().timeIntervalSince(startTime) >= timeoutSec { break }
      usleep(10_000)
      if Date().timeIntervalSince(startTime) >= timeoutSec { break }
    }

    lock.lock()
    let frame = currentFrame
    lock.unlock()
    let elapsed = Date().timeIntervalSince(startTime) * 1000.0
    return jsonEncode(
      WaitResult(
        ok: false, frame: frame, elapsedMs: elapsed,
        error: "timeout after \(req.timeoutMs)ms"))
  }

  private func checkConditionUnlocked(_ cond: WaitCondition) -> Bool {
    switch cond.kind {
    case "frameAtLeast":
      return currentFrame >= (cond.frame ?? 0)
    case "tabCount":
      return model.tabs.count == (cond.count ?? 0)
    case "activeTab":
      return model.activeTab?.id == cond.tabId
    case "sessionStatus":
      let tabId =
        cond.sessionId.flatMap { sid in
          model.tabs.first(where: { $0.sessionId == sid })?.id
        } ?? cond.tabId ?? model.activeTab?.id
      guard let tid = tabId, let session = model.session(forTab: tid),
        let snap = session.snapshot()
      else { return false }
      defer { laban_snapshot_destroy(snap) }
      return snapshotStatus(UnsafePointer(snap)) == cond.status
    case "titleEquals":
      let tab =
        cond.tabId.flatMap { id in model.tabs.first(where: { $0.id == id }) }
        ?? model.activeTab
      return tab?.title == cond.title
    case "textVisible":
      guard let tab = waitTargetTabUnlocked(cond),
        let session = model.session(forTab: tab.id),
        let snap = session.snapshot()
      else { return false }
      defer { laban_snapshot_destroy(snap) }
      return TerminalSnapshotText.visibleText(
        from: UnsafePointer(snap),
        mode: .trimmedNonEmptyRows
      ).contains(cond.text ?? "")
    case "renderCommandSeen":
      guard let kind = cond.commandKind else { return false }
      return lastFrameCommands.contains { DebugFrameCommandSerializer.kind($0) == kind }
    case "eventSeen":
      guard let kind = cond.eventKind else { return false }
      return logs.containsEvent(kind: kind)
    case "renderTraceInvariant":
      return true
    default:
      return false
    }
  }

  private func waitTargetTabUnlocked(_ cond: WaitCondition) -> Tab? {
    if let sessionId = cond.sessionId {
      return model.tabs.first { $0.sessionId == sessionId }
    }
    if let tabId = cond.tabId {
      return model.tabs.first { $0.id == tabId }
    }
    return model.activeTab
  }

  public func timingResponse() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(
      TimingResponse(
        frame: currentFrame,
        lastFrameMs: timing.lastFrameMs,
        terminalPollMs: timing.terminalPollMs,
        snapshotMs: timing.snapshotMs,
        commandExtractionMs: timing.commandExtractionMs,
        renderMs: timing.renderMs,
        screenshotMs: timing.screenshotMs
      ))
  }

  public func metricsResponse() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(
      MetricsResponse(
        runId: runId,
        mode: mode,
        frame: currentFrame,
        uptimeMs: elapsedMs(since: startedAt),
        counters: MetricsCountersResponse(
          framesRendered: currentFrame,
          events: logs.eventSeq,
          inputEvents: logs.inputLogSeq,
          terminalLogEvents: logs.terminalLogSeq,
          errors: logs.errorSeq,
          screenshots: screenshotCount,
          tabs: model.tabs.count,
          sessions: model.tabs.count
        ),
        terminalBytes: TerminalByteMetricsResponse(
          input: logs.terminalBytes.input,
          output: logs.terminalBytes.output,
          terminalResponse: logs.terminalBytes.terminalResponse
        ),
        lastFrame: LastFrameMetricsResponse(
          commands: lastFrameCommands.count,
          cells: lastDrawStats.cells,
          glyphs: lastDrawStats.glyphs,
          backgroundRects: lastDrawStats.backgroundRects,
          images: lastDrawStats.images,
          cursor: lastDrawStats.cursor,
          lastFrameMs: timing.lastFrameMs,
          terminalPollMs: timing.terminalPollMs,
          snapshotMs: timing.snapshotMs,
          commandExtractionMs: timing.commandExtractionMs,
          renderMs: timing.renderMs
        )
      ))
  }

  public func errors(since: Int) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(logs.errorsResponse(since: since))
  }

  public func terminalLogResponse(query: [String: String]) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(
      logs.terminalLogResponse(query: query, defaultSessionId: model.activeTab?.sessionId))
  }

  // MARK: - Fixture control

  public func fixtureControl(_ data: Data) -> DebugResponse {
    guard let req = try? JSONDecoder().decode(FixtureControlRequest.self, from: data) else {
      lock.lock()
      appendError(kind: "fixture.invalid", message: "invalid fixture control request")
      lock.unlock()
      return jsonError("invalid fixture control request")
    }

    lock.lock()
    defer { lock.unlock() }

    switch req.action {
    case "load":
      guard let rawPath = req.path else {
        appendError(kind: "fixture.load", message: "fixture load requires path")
        return fixtureResult(ok: false, action: req.action, error: "fixture load requires path")
      }
      let url: URL
      do {
        url = try resolveFixtureURL(rawPath)
      } catch {
        appendError(kind: "fixture.load", message: "rejected fixture path: \(error)")
        return fixtureResult(
          ok: false,
          action: req.action,
          error: "rejected fixture path: \(error)"
        )
      }
      do {
        let runner = try FixtureRunner.load(from: url)
        try resetFixtureModelUnlocked(runner: runner)
        fixtureURL = url
        fixtureRunner = runner
        fixtureStepIndex = 0
        mode = "fixture"
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "fixture.loaded", path: url.path))
        return fixtureResult(ok: true, action: req.action)
      } catch {
        appendError(kind: "fixture.load", message: "failed to load fixture: \(error)")
        return fixtureResult(
          ok: false,
          action: req.action,
          error: "failed to load fixture: \(error)"
        )
      }

    case "restart":
      guard let runner = fixtureRunner else {
        appendError(kind: "fixture.restart", message: "no fixture is loaded")
        return fixtureResult(ok: false, action: req.action, error: "no fixture is loaded")
      }
      do {
        try resetFixtureModelUnlocked(runner: runner)
        fixtureStepIndex = 0
        mode = "fixture"
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "fixture.restarted", path: fixtureURL?.path))
        return fixtureResult(ok: true, action: req.action)
      } catch {
        appendError(kind: "fixture.restart", message: "failed to restart fixture: \(error)")
        return fixtureResult(
          ok: false, action: req.action, error: "failed to restart fixture: \(error)")
      }

    case "step":
      guard fixtureRunner != nil else {
        appendError(kind: "fixture.step", message: "no fixture is loaded")
        return fixtureResult(ok: false, action: req.action, error: "no fixture is loaded")
      }
      let count = max(req.count ?? 1, 1)
      do {
        try applyFixtureStepsUnlocked(count: count)
        appendEvent(EventEntry(kind: "fixture.stepped", action: "step"))
        return fixtureResult(ok: true, action: req.action)
      } catch {
        appendError(kind: "fixture.step", message: "failed to step fixture: \(error)")
        return fixtureResult(
          ok: false,
          action: req.action,
          error: "failed to step fixture: \(error)"
        )
      }

    default:
      appendError(kind: "fixture.unsupported", message: "unsupported fixture action \(req.action)")
      return fixtureResult(
        ok: false, action: req.action, error: "unsupported fixture action \(req.action)")
    }
  }

  private func resolveFixtureURL(_ path: String) throws -> URL {
    try DebugFixtureResolver.resolve(path, root: fixtureRootURL)
  }

  private func resetFixtureModelUnlocked(runner: FixtureRunner) throws {
    model.closeAllSessions()
    sessionMode = .fixture

    var size = LabanTerminalSize()
    size.rows = Int32(runner.fixture.initialSize.rows)
    size.cols = Int32(runner.fixture.initialSize.cols)

    model = try AppModel(
      initialSize: size,
      sessionFactory: { [weak self] size in
        let session = try Session.fixture(size: size)
        session.captureSink = self?.captureRecorder
        return session
      })
    model.captureSink = captureRecorder
    surfaceController = TerminalSurfaceController(
      model: model,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarWidth: CGFloat(sidebarWidth),
      sidebarCellWidth: CGFloat(cellWidth),
      sidebarCellHeight: CGFloat(cellHeight),
      captureSink: captureRecorder)
    selectionBySession.removeAll()
    debugClipboard = ""
    lastCopyText = nil
    lastPasteText = nil
    lastPasteUsedBracketedPaste = nil
    lastPasteIgnoredNonText = nil

    windowWidth = sidebarWidth + runner.fixture.initialSize.cols * cellWidth
    windowHeight = runner.fixture.initialSize.rows * cellHeight
    surface = BitmapSurface(width: max(windowWidth, 1), height: max(windowHeight, 1))
    renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
  }

  private func applyFixtureStepsUnlocked(count: Int) throws {
    guard let runner = fixtureRunner, let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else { return }

    let steps = runner.fixture.steps
    guard fixtureStepIndex < steps.count else {
      renderFrameUnlocked()
      return
    }

    let end = min(fixtureStepIndex + count, steps.count)
    while fixtureStepIndex < end {
      let step = steps[fixtureStepIndex]
      fixtureStepIndex += 1
      switch step {
      case .setTitle(let title):
        let bytes = Array("\u{1B}]0;\(title)\u{07}".utf8)
        _ = session.write(bytes)
        _ = session.poll()
        appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
        renderFrameUnlocked()

      case .writeBytes(let encoding, let data):
        guard encoding == "utf8" else { throw FixtureError.unsupportedEncoding(encoding) }
        let bytes = Array(data.utf8)
        _ = session.write(bytes)
        _ = session.poll()
        appendTerminalLog(sessionId: session.id, direction: "output", bytes: bytes)
        renderFrameUnlocked()

      case .waitFrames(let frameCount):
        for _ in 0..<frameCount {
          _ = session.poll()
          renderFrameUnlocked()
        }
      }
    }
  }

  private func fixtureResult(ok: Bool, action: String, error: String? = nil) -> DebugResponse {
    let active = model.activeTab
    return jsonEncode(
      FixtureControlResponse(
        ok: ok,
        action: action,
        frame: currentFrame,
        fixtureName: fixtureRunner?.fixture.name,
        fixturePath: fixtureURL?.path,
        stepIndex: fixtureStepIndex,
        stepCount: fixtureRunner?.fixture.steps.count ?? 0,
        activeTabId: active?.id,
        activeSessionId: active?.sessionId,
        error: error
      ),
      status: ok ? 200 : 400
    )
  }

  // MARK: - Events endpoint

  // MARK: - Selection and clipboard endpoints

  public func selection() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
      return jsonEncode(
        SelectionResponse(
          active: false, sessionId: nil, anchor: nil, focus: nil, rects: [], text: ""))
    }

    guard let sel = selectionBySession[session.id] else {
      return jsonEncode(
        SelectionResponse(
          active: false, sessionId: tab.sessionId, anchor: nil, focus: nil, rects: [], text: ""))
    }

    var rects: [RectResponse] = []
    var text = ""

    if let snap = session.snapshot() {
      defer { laban_snapshot_destroy(snap) }
      let rows = Int(snap.pointee.rows)
      let cols = Int(snap.pointee.cols)
      for r in sel.cgRects(
        rows: rows, cols: cols,
        cellWidth: CGFloat(cellWidth), cellHeight: CGFloat(cellHeight),
        originX: CGFloat(sidebarWidth), originY: 0
      ) {
        rects.append(DebugFrameCommandSerializer.rectResponse(r))
      }
      text = sel.selectedText(from: snap.pointee)
    }

    return jsonEncode(
      SelectionResponse(
        active: true,
        sessionId: tab.sessionId,
        anchor: CellCoordResponse(row: sel.anchor.row, col: sel.anchor.col),
        focus: CellCoordResponse(row: sel.focus.row, col: sel.focus.col),
        rects: rects,
        text: text
      ))
  }

  public func clipboard() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(
      ClipboardResponse(
        lastCopyText: lastCopyText,
        lastPasteText: lastPasteText,
        lastPasteUsedBracketedPaste: lastPasteUsedBracketedPaste,
        lastPasteIgnoredNonText: lastPasteIgnoredNonText
      ))
  }

  public func inputLogResponse(since: Int) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(logs.inputLogResponse(since: since))
  }

  public func events(since: Int) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(logs.eventsResponse(since: since))
  }
}
