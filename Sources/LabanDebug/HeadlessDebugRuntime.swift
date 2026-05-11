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

  // MARK: - Endpoints

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

}
