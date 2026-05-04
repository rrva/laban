import CoreGraphics
import Darwin
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

// MARK: - Internal helpers

private struct DrawStats {
  var cells: Int = 0
  var glyphs: Int = 0
  var backgroundRects: Int = 0
  var images: Int = 0
  var cursor: Bool = false
}

private struct EventEntry {
  var seq: Int = 0
  var kind: String
  var tabId: String?
  var sessionId: String?
  var frame: Int?
  var width: Int?
  var height: Int?
  var text: String?
  var path: String?
  var action: String?
  var deltaRows: Int?
  var error: String?
}

private struct CellCoordinateReq: Decodable {
  var row: Int
  var col: Int
}

private struct ActionRequest: Decodable {
  var action: String
  var tabId: String?
  var width: Int?
  var height: Int?
  var text: String?
  var title: String?
  var frozen: Bool?
  var count: Int?
  var key: String?
  var type: String?
  var modifiers: [String]?
  var consumedModifiers: [String]?
  var unshifted: String?
  var x: Int?
  var y: Int?
  var deltaY: Double?
  var button: String?
  var sessionId: String?
  var deltaRows: Int?
  var anchor: CellCoordinateReq?
  var focus: CellCoordinateReq?
  var cwd: String?
  var repoName: String?
  var repoRoot: String?
  var worktreeName: String?
  var branch: String?
  var isDirty: Bool?
  var foregroundProcess: String?
  var foregroundCommand: String?
  var pid: Int?
  var agentName: String?
  var sessionName: String?
  var agentSessionId: String?
  var taskLabel: String?
  var model: String?
  var contextPercent: Int?
  var awaitingInput: Bool?
  var activityState: String?
  var unseenOutput: Bool?
  var exitStatus: Int?
}

private struct CaptureStartRequest: Decodable {
  var name: String? = nil
  var screenshots: String? = nil
}

private struct CaptureStatusResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String?
  var screenshots: String?
}

private struct CaptureStartResponse: Encodable {
  var active: Bool
  var alreadyActive: Bool
  var runId: String
  var directory: String
  var screenshots: String
}

private struct CaptureStopResponse: Encodable {
  var active: Bool
  var runId: String?
  var directory: String?
  var manifestPath: String
}

private struct WaitRequest: Decodable {
  var timeoutMs: Int
  var condition: WaitCondition
}

private struct WaitCondition: Decodable {
  var kind: String
  var frame: Int?
  var eventKind: String?
  var count: Int?
  var tabId: String?
  var sessionId: String?
  var status: String?
  var title: String?
  var text: String?
  var commandKind: String?
  var invariantKind: String?
  var level: String?
}

private struct RenderTraceRequest: Decodable {
  var frame: Int?
  var target: String?
  var include: [String]?
  var commandIds: [String]?
  var pixelProbes: [PixelProbeReq]?
  var limit: Int?
}

private struct PixelProbeReq: Decodable {
  var name: String?
  var x: Int
  var y: Int
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
  private let mode: String
  private let artifactsURL: URL
  private let deterministic: Bool

  private var model: AppModel
  private let fontAtlas: FontAtlas
  private let cellWidth: Int
  private let cellHeight: Int
  private let sidebarWidth: Int = 200
  private var windowWidth: Int
  private var windowHeight: Int
  private var surface: BitmapSurface
  private var renderer: SoftwareRenderer
  private var sidebarProducer: SidebarProducer
  private var frameProducer: FrameProducer

  private var currentFrame: Int = 0
  private var lastFrameCommands: [FrameCommand] = []
  private var lastDrawStats = DrawStats()
  private var debugClipboard: String = ""
  private var selectionBySession: [Session.ID: TerminalSelection] = [:]
  private var lastCopyText: String?
  private var lastPasteText: String?
  private var lastPasteUsedBracketedPaste: Bool?
  private var lastPasteIgnoredNonText: Bool?
  private var eventLog: [EventEntry] = []
  private var eventSeq: Int = 0
  private var inputLog: [InputEventEnvelope] = []
  private var inputLogSeq: Int = 0
  private var captureRecorder: CaptureRecorder?
  private var lastCaptureManifestPath: String?
  private var lastCaptureRunId: String?
  private var lastCaptureDirectory: String?

  // MARK: - Init

  public init(
    fixtureURL: URL?,
    artifactsURL: URL,
    tempURL: URL?,
    deterministic: Bool,
    runId: String,
    captureName: String? = nil,
    captureScreenshots: CaptureScreenshotPolicy = .marked
  ) throws {
    self.runId = runId
    self.artifactsURL = artifactsURL
    self.deterministic = deterministic
    self.mode = fixtureURL != nil ? "fixture" : "headless"

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
        let session = try Session.fixture(size: size)
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
    self.sidebarProducer = SidebarProducer(
      sidebarWidth: CGFloat(200),
      cellWidth: cs.width,
      cellHeight: cs.height
    )
    self.frameProducer = FrameProducer(
      cellWidth: Int(cs.width),
      cellHeight: Int(cs.height),
      originX: CGFloat(200),
      originY: 0
    )

    if let r = runner {
      try r.apply(to: model)
    }

    if initialRecorder != nil {
      model.recordExistingStateForCapture()
    }

    renderFrameUnlocked()
  }

  // MARK: - Server ready notification

  public func emitServerReady() {
    lock.lock()
    defer { lock.unlock() }
    appendEvent(EventEntry(kind: "server.ready"))
  }

  // MARK: - Render (always call under lock or from init)

  private func renderFrameUnlocked() {
    syncSessionMetadataUnlocked()
    let frame = currentFrame + 1
    captureRecorder?.record(CaptureTimelineEvent(kind: .frameBegin, frame: frame))

    guard let activeTab = model.activeTab else {
      renderCommandsUnlocked([], captureFrame: frame)
      return
    }

    var cmds = sidebarProducer.commands(
      tabs: model.tabs,
      activeTabId: activeTab.id,
      height: CGFloat(windowHeight)
    )

    if let session = model.session(forTab: activeTab.id) {
      session.setCaptureFrame(frame)
      session.poll()
      if let snap = session.snapshot() {
        defer { laban_snapshot_destroy(snap) }
        captureRecorder?.recordTerminalSnapshot(
          frame: frame,
          tabId: activeTab.id,
          sessionId: session.id,
          snapshot: UnsafePointer(snap)
        )
        let sel = selectionBySession[session.id]
        cmds += frameProducer.commands(from: UnsafePointer(snap), selection: sel)
      }
    }

    captureRecorder?.recordFrameCommands(
      frame: frame,
      commands: cmds,
      surfaceWidth: surface.width,
      surfaceHeight: surface.height,
      scale: Double(surface.scale)
    )
    renderCommandsUnlocked(cmds, captureFrame: frame)
  }

  private func renderCommandsUnlocked(_ cmds: [FrameCommand], captureFrame: Int? = nil) {
    renderer.render(cmds)
    lastFrameCommands = cmds
    lastDrawStats = countStats(cmds)
    currentFrame += 1
    let frame = captureFrame ?? currentFrame
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

  private func appendEvent(_ e: EventEntry) {
    var e = e
    e.seq = eventSeq
    eventSeq += 1
    eventLog.append(e)
    if eventLog.count > 2000 {
      eventLog.removeFirst(eventLog.count - 2000)
    }
  }

  private func appendInputEnvelope(_ e: InputEventEnvelope) {
    var e = e
    e.seq = inputLogSeq
    inputLogSeq += 1
    inputLog.append(e)
    captureRecorder?.recordInput(e)
    if inputLog.count > 512 {
      inputLog.removeFirst(inputLog.count - 512)
    }
  }

  // MARK: - Key action helpers

  private static func keyFromName(_ name: String) -> Key? {
    switch name.lowercased() {
    case "a": return .a
    case "b": return .b
    case "c": return .c
    case "d": return .d
    case "e": return .e
    case "f": return .f
    case "g": return .g
    case "h": return .h
    case "i": return .i
    case "j": return .j
    case "k": return .k
    case "l": return .l
    case "m": return .m
    case "n": return .n
    case "o": return .o
    case "p": return .p
    case "q": return .q
    case "r": return .r
    case "s": return .s
    case "t": return .t
    case "u": return .u
    case "v": return .v
    case "w": return .w
    case "x": return .x
    case "y": return .y
    case "z": return .z
    case "0": return .digit0
    case "1": return .digit1
    case "2": return .digit2
    case "3": return .digit3
    case "4": return .digit4
    case "5": return .digit5
    case "6": return .digit6
    case "7": return .digit7
    case "8": return .digit8
    case "9": return .digit9
    case "enter": return .enter
    case "backspace": return .backspace
    case "escape": return .escape
    case "tab": return .tab
    case "space": return .space
    case "delete": return .delete
    case "home": return .home
    case "end": return .end
    case "pageup": return .pageUp
    case "pagedown": return .pageDown
    case "insert": return .insert
    case "arrowup": return .arrowUp
    case "arrowdown": return .arrowDown
    case "arrowleft": return .arrowLeft
    case "arrowright": return .arrowRight
    case "f1": return .f1
    case "f2": return .f2
    case "f3": return .f3
    case "f4": return .f4
    case "f5": return .f5
    case "f6": return .f6
    case "f7": return .f7
    case "f8": return .f8
    case "f9": return .f9
    case "f10": return .f10
    case "f11": return .f11
    case "f12": return .f12
    case "f13": return .f13
    case "f14": return .f14
    case "f15": return .f15
    case "f16": return .f16
    case "f17": return .f17
    case "f18": return .f18
    case "f19": return .f19
    case "f20": return .f20
    case "f21": return .f21
    case "f22": return .f22
    case "f23": return .f23
    case "f24": return .f24
    default: return nil
    }
  }

  private static func modifiersFromStrings(_ strs: [String]?) -> KeyModifiers {
    var mods: KeyModifiers = []
    for s in strs ?? [] {
      switch s.lowercased() {
      case "shift": mods.insert(.shift)
      case "control": mods.insert(.control)
      case "alt", "option": mods.insert(.alt)
      case "command", "super": mods.insert(.command)
      default: break
      }
    }
    return mods
  }

  private static func keyActionFromType(_ type: String?) -> KeyAction {
    switch type?.lowercased() {
    case "release": return .release
    case "repeat": return .held
    default: return .press
    }
  }

  private func commandRouteForKey(_ key: Key) -> (route: String, command: String?) {
    switch key {
    case .t: return ("appCommand", "newTab")
    case .w: return ("appCommand", "closeTab")
    case .c: return ("appCommand", "copy")
    case .v: return ("appCommand", "paste")
    case .digit1, .digit2, .digit3, .digit4, .digit5,
      .digit6, .digit7, .digit8, .digit9:
      return ("appCommand", "selectTab")
    default: return ("ignored", nil)
    }
  }

  private func executeCommandKey(_ key: Key) {
    switch key {
    case .t:
      try? model.createTab()
      renderFrameUnlocked()
    case .w:
      if let tabId = model.activeTab?.id {
        try? model.closeTab(tabId)
        renderFrameUnlocked()
      }
    case .digit1, .digit2, .digit3, .digit4, .digit5,
      .digit6, .digit7, .digit8, .digit9:
      let idx: Int
      switch key {
      case .digit1: idx = 0
      case .digit2: idx = 1
      case .digit3: idx = 2
      case .digit4: idx = 3
      case .digit5: idx = 4
      case .digit6: idx = 5
      case .digit7: idx = 6
      case .digit8: idx = 7
      case .digit9: idx = 8
      default: return
      }
      guard idx < model.tabs.count else { return }
      model.selectTab(model.tabs[idx].id)
      renderFrameUnlocked()
    default:
      break
    }
  }

  // MARK: - Snapshot helpers

  private func snapshotStatus(_ snap: UnsafePointer<LabanSnapshot>) -> String {
    switch snap.pointee.status {
    case 0: return "running"
    case 1, 2: return "exited"
    default: return "failed"
    }
  }

  private func visibleText(from snap: UnsafePointer<LabanSnapshot>) -> String {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else { return "" }
    var lines: [String] = []
    for row in 0..<rows {
      var line = ""
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        guard cell.utf8_length > 0 else { continue }
        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        if let text = String(bytes: buf, encoding: .utf8) { line += text }
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { lines.append(trimmed) }
    }
    return lines.joined(separator: "\n")
  }

  private func rgbaArray(_ color: UInt32) -> [Int] {
    [
      Int((color >> 24) & 0xFF),
      Int((color >> 16) & 0xFF),
      Int((color >> 8) & 0xFF),
      Int(color & 0xFF),
    ]
  }

  private func rectResponse(_ r: CGRect) -> RectResponse {
    RectResponse(
      x: Int(r.origin.x), y: Int(r.origin.y),
      width: Int(r.size.width), height: Int(r.size.height)
    )
  }

  private func terminalMousePosition(x: Int, y: Int) -> (x: Float, y: Float) {
    DebugMouseInput.terminalSurfacePosition(
      windowX: x,
      windowY: y,
      windowHeight: windowHeight,
      sidebarWidth: sidebarWidth
    )
  }

  private var terminalSurfaceWidth: Int {
    DebugMouseInput.terminalSurfaceWidth(windowWidth: windowWidth, sidebarWidth: sidebarWidth)
  }

  // MARK: - Session metadata synchronization

  private func syncSessionMetadataUnlocked() {
    for tab in model.tabs {
      if let session = model.session(forTab: tab.id) {
        session.poll()
        if model.syncTitle(forTab: tab.id, from: session),
          let updated = model.tabs.first(where: { $0.id == tab.id })
        {
          var event = CaptureTimelineEvent(
            kind: .appState,
            tabId: updated.id,
            sessionId: updated.sessionId
          )
          event.title = updated.title
          captureRecorder?.record(event)
        }
        model.syncProcessMetadata(forTab: tab.id, from: session)
        model.syncExitState(forTab: tab.id, from: session)
      }
    }
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
    guard let recorder = captureRecorder else {
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

    let finalPNG: Data?
    if recorder.screenshots == .none {
      finalPNG = nil
    } else {
      finalPNG = surface.pngData
    }
    do {
      let manifest = try recorder.finish(
        interrupted: false,
        finalScreenshot: finalPNG,
        frame: currentFrame
      )
      captureRecorder = nil
      model.captureSink = nil
      lastCaptureManifestPath = manifest.path
      lastCaptureRunId = recorder.runId
      lastCaptureDirectory = recorder.directoryURL.path
      return jsonEncode(
        CaptureStopResponse(
          active: false,
          runId: recorder.runId,
          directory: recorder.directoryURL.path,
          manifestPath: manifest.path
        ))
    } catch {
      return jsonError("capture stop failed: \(error)", status: 500)
    }
  }

  public func captureSnapshot() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    guard let recorder = captureRecorder else {
      return jsonError("capture is not active", status: 400)
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let events = eventLog.map { e in
      EventResponse(
        seq: e.seq, kind: e.kind,
        tabId: e.tabId, sessionId: e.sessionId, frame: e.frame,
        width: e.width, height: e.height, text: e.text,
        path: e.path, action: e.action, deltaRows: e.deltaRows, error: e.error
      )
    }
    let frameCommandBody =
      FrameCommandsResponse(
        frame: currentFrame,
        backend: "software",
        commands: lastFrameCommands.enumerated().map {
          serializeCommandForList($0.element, index: $0.offset, includeText: true)
        },
        truncated: false
      )
    var files: [String: Data] = [
      "state.json": stateUnlocked().body,
      "events.json": (try? enc.encode(EventsResponse(events: events, next: eventSeq))) ?? Data(),
      "input-log.json": (try? enc.encode(InputLogResponse(events: inputLog, next: inputLogSeq)))
        ?? Data(),
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
    guard let pngData = surface.pngData else { throw DebugServerError.encodingFailed }
    return (pngData, currentFrame, surface.width, surface.height)
  }

  public func writeScreenshotArtifact() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    guard let pngData = surface.pngData else {
      return jsonError("PNG encoding failed", status: 500)
    }
    let ssDir = artifactsURL.appendingPathComponent("screenshots")
    do {
      try FileManager.default.createDirectory(at: ssDir, withIntermediateDirectories: true)
    } catch {
      return jsonError("failed to create screenshots dir: \(error)", status: 500)
    }
    let fname = String(format: "frame-%06d.png", currentFrame)
    let fileURL = ssDir.appendingPathComponent(fname)
    do {
      try pngData.write(to: fileURL)
    } catch {
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
    guard let req = try? JSONDecoder().decode(ActionRequest.self, from: data) else {
      return jsonError("invalid action request")
    }
    return applyActionUnlocked(req)
  }

  private func applyActionUnlocked(_ req: ActionRequest) -> DebugResponse {
    switch req.action {

    case "newTab":
      do { try model.createTab() } catch {
        return jsonError("createTab failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.created", tabId: model.activeTab?.id))
      return actionResult(ok: true)

    case "closeTab":
      guard let tabId = req.tabId else { return jsonError("closeTab requires tabId") }
      do { try model.closeTab(tabId) } catch {
        return jsonError("closeTab failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.closed", tabId: tabId))
      return actionResult(ok: true)

    case "selectTab":
      guard let tabId = req.tabId else { return jsonError("selectTab requires tabId") }
      model.selectTab(tabId)
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.selected", tabId: tabId))
      return actionResult(ok: true)

    case "setTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else { return jsonError("setTabTitle requires an active tab") }
      guard let title = req.title ?? req.text else {
        return jsonError("setTabTitle requires title")
      }
      do { try model.renameTab(tabId, title: title) } catch {
        return jsonError("setTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.set", tabId: tabId, text: title))
      return actionResult(ok: true)

    case "freezeTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("freezeTabTitle requires an active tab")
      }
      do { try model.freezeTitle(forTab: tabId, frozen: req.frozen ?? true) } catch {
        return jsonError("freezeTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.frozen", tabId: tabId))
      return actionResult(ok: true)

    case "clearTabTitle":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("clearTabTitle requires an active tab")
      }
      do { try model.clearUserTitle(forTab: tabId) } catch {
        return jsonError("clearTabTitle failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.title.cleared", tabId: tabId))
      return actionResult(ok: true)

    case "setTabMetadata":
      let targetTabId = req.tabId ?? model.activeTab?.id
      guard let tabId = targetTabId else {
        return jsonError("setTabMetadata requires an active tab")
      }
      let workspace =
        req.cwd != nil || req.repoName != nil || req.repoRoot != nil || req.worktreeName != nil
          || req.branch != nil || req.isDirty != nil
        ? TabWorkspaceMetadata(
          cwd: req.cwd,
          repoName: req.repoName,
          repoRoot: req.repoRoot,
          worktreeName: req.worktreeName,
          branch: req.branch,
          isDirty: req.isDirty ?? false
        )
        : nil
      let process =
        req.foregroundProcess != nil || req.foregroundCommand != nil || req.pid != nil
        ? TabProcessMetadata(
          foregroundProcess: req.foregroundProcess,
          foregroundCommand: req.foregroundCommand,
          pid: req.pid
        )
        : nil
      let agent =
        req.agentName != nil || req.sessionName != nil || req.agentSessionId != nil
          || req.taskLabel != nil || req.model != nil || req.contextPercent != nil
          || req.awaitingInput != nil
        ? TabAgentMetadata(
          agentName: req.agentName,
          sessionName: req.sessionName,
          sessionId: req.agentSessionId,
          taskLabel: req.taskLabel,
          model: req.model,
          contextPercent: req.contextPercent,
          awaitingInput: req.awaitingInput ?? false
        )
        : nil
      let activityState = req.activityState.flatMap(TabActivityState.init(rawValue:))
      do {
        try model.updateTitleMetadata(
          forTab: tabId,
          workspace: workspace,
          process: process,
          agent: agent,
          activityState: activityState,
          unseenOutput: req.unseenOutput,
          exitStatus: req.exitStatus
        )
      } catch {
        return jsonError("setTabMetadata failed: \(error)")
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "tab.metadata.set", tabId: tabId))
      return actionResult(ok: true)

    case "resizeWindow":
      guard let w = req.width, let h = req.height else {
        return jsonError("resizeWindow requires width and height")
      }
      windowWidth = max(w, sidebarWidth + 1)
      windowHeight = max(h, 1)
      surface = BitmapSurface(width: windowWidth, height: windowHeight)
      renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
      model.resize(
        viewportWidth: windowWidth - sidebarWidth,
        viewportHeight: windowHeight,
        cellWidth: cellWidth, cellHeight: cellHeight
      )
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "window.resized", width: windowWidth, height: windowHeight))
      return actionResult(ok: true)

    case "typeText":
      guard let text = req.text else { return jsonError("typeText requires text") }
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      let bytes = Array(text.utf8)
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        session.write(bytes)
        model.noteOutput(forTab: tab.id)
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "text",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id,
          sessionId: activeTab?.sessionId,
          text: text,
          encodedHex: bytes.map { String(format: "%02x", $0) }.joined(),
          encodedLength: bytes.count
        ))
      appendEvent(EventEntry(kind: "input.typed", text: text))
      return actionResult(ok: true)

    case "feedOutput":
      guard let text = req.text else { return jsonError("feedOutput requires text") }
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        session.feedOutput(Array(text.utf8))
        model.noteOutput(forTab: tab.id)
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "output.fed", text: text))
      return actionResult(ok: true)

    case "advanceFrames":
      let count = max(req.count ?? 1, 1)
      for _ in 0..<count {
        renderFrameUnlocked()
      }
      return actionResult(ok: true)

    case "setClipboardText":
      guard let text = req.text else { return jsonError("setClipboardText requires text") }
      debugClipboard = text
      appendEvent(EventEntry(kind: "clipboard.set", text: text))
      return actionResult(ok: true)

    case "setSelection":
      let frameBefore = currentFrame
      guard let anchorReq = req.anchor, let focusReq = req.focus else {
        return jsonError("setSelection requires anchor and focus")
      }
      let targetTab =
        req.sessionId.flatMap { sid in model.tabs.first(where: { $0.sessionId == sid }) }
        ?? model.activeTab
      guard let tab = targetTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no session for setSelection")
      }
      let sel = TerminalSelection(
        sessionId: session.id,
        anchor: TerminalCellCoordinate(row: anchorReq.row, col: anchorReq.col),
        focus: TerminalCellCoordinate(row: focusReq.row, col: focusReq.col)
      )
      selectionBySession[session.id] = sel
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "selection",
          route: "selection",
          frameBefore: frameBefore,
          tabId: tab.id,
          sessionId: session.id,
          command: "setSelection",
          anchorRow: anchorReq.row,
          anchorCol: anchorReq.col,
          focusRow: focusReq.row,
          focusCol: focusReq.col
        ))
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "selection.set", sessionId: tab.sessionId))
      return actionResult(ok: true)

    case "copy":
      let frameBefore = currentFrame
      let targetTab =
        req.sessionId.flatMap { sid in model.tabs.first(where: { $0.sessionId == sid }) }
        ?? model.activeTab
      guard let tab = targetTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no session for copy")
      }
      guard let sel = selectionBySession[session.id] else {
        lastCopyText = ""
        appendEvent(EventEntry(kind: "clipboard.copied", text: ""))
        return actionResult(ok: true)
      }
      let text: String
      if let snap = session.snapshot() {
        defer { laban_snapshot_destroy(snap) }
        text = sel.selectedText(from: snap.pointee)
      } else {
        text = ""
      }
      lastCopyText = text
      debugClipboard = text
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "copy",
          route: "appCommand",
          frameBefore: frameBefore,
          tabId: tab.id,
          sessionId: session.id,
          command: "copy"
        ))
      appendEvent(EventEntry(kind: "clipboard.copied", text: text))
      return actionResult(ok: true)

    case "paste":
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        let result = session.writePaste(debugClipboard)
        lastPasteText = debugClipboard
        lastPasteUsedBracketedPaste = result?.bracketed
        lastPasteIgnoredNonText = false
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "paste",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id,
          sessionId: activeTab?.sessionId,
          text: debugClipboard,
          command: "paste"
        ))
      appendEvent(EventEntry(kind: "clipboard.pasted", text: debugClipboard))
      return actionResult(ok: true)

    case "scrollViewport":
      let frameBefore = currentFrame
      let targetTab =
        req.sessionId.flatMap { sid in
          model.tabs.first(where: { $0.sessionId == sid })
        } ?? model.activeTab
      guard let t = targetTab, let session = model.session(forTab: t.id) else {
        return jsonError("no session for scrollViewport")
      }
      session.scrollViewport(deltaRows: req.deltaRows ?? 0)
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: UUID().uuidString,
          source: "debug",
          kind: "scroll",
          route: "terminal",
          frameBefore: frameBefore,
          tabId: t.id,
          sessionId: session.id,
          command: "scrollViewport",
          deltaRows: req.deltaRows ?? 0
        ))
      renderFrameUnlocked()
      appendEvent(
        EventEntry(kind: "viewport.scrolled", sessionId: t.sessionId, deltaRows: req.deltaRows))
      return actionResult(ok: true)

    case "mouseWheel":
      let frameBefore = currentFrame
      guard let x = req.x, let y = req.y, let deltaY = req.deltaY else {
        return jsonError("mouseWheel requires x, y, and deltaY")
      }
      // Sidebar hit test.
      if x < sidebarWidth {
        // Sidebar hits are consumed locally.
        appendEvent(EventEntry(kind: "mouse.sidebar", action: "mouseWheel"))
        return actionResult(ok: true)
      }
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no active session for mouseWheel")
      }
      let terminalPoint = terminalMousePosition(x: x, y: y)
      // Determine wheel direction: deltaY > 0 means scroll up (older history).
      let isUp = deltaY > 0

      if let vs = session.viewportState(), vs.mouseTracking {
        // Mouse tracking active: encode and send wheel event.
        let button: MouseButton = isUp ? .wheelUp : .wheelDown
        let me = MouseEvent(
          action: .press,
          button: button,
          x: terminalPoint.x,
          y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth,
          screenHeight: windowHeight,
          cellWidth: cellWidth,
          cellHeight: cellHeight
        )
        let result = session.sendMouse(me)
        appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "mouseWheel"))
        renderFrameUnlocked()
        return jsonEncode(
          MouseActionResult(
            ok: result == 0, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: true, sent: result == 0
          ))
      } else {
        // Normal mode: scroll viewport.
        let rows = isUp ? -1 : 1
        session.scrollViewport(deltaRows: rows)
        appendInputEnvelope(
          InputEventEnvelope(
            inputId: UUID().uuidString,
            source: "debug",
            kind: "mouse",
            route: "terminal",
            frameBefore: frameBefore,
            tabId: tab.id,
            sessionId: session.id,
            command: "mouseWheel",
            deltaRows: rows
          ))
        renderFrameUnlocked()
        appendEvent(
          EventEntry(
            kind: "viewport.scrolled", sessionId: tab.sessionId, action: "mouseWheel",
            deltaRows: rows))
        return actionResult(ok: true)
      }

    case "click":
      let frameBefore = currentFrame
      guard let x = req.x, let y = req.y, let button = req.button else {
        return jsonError("click requires x, y, and button")
      }
      // Sidebar hit test.
      if x < sidebarWidth {
        let sp = SidebarProducer(
          sidebarWidth: CGFloat(sidebarWidth),
          cellWidth: CGFloat(cellWidth),
          cellHeight: CGFloat(cellHeight)
        )
        let pt = CGPoint(x: CGFloat(x), y: CGFloat(y))
        switch sp.hitTest(at: pt, tabs: model.tabs, height: CGFloat(windowHeight)) {
        case .newTab:
          do { try model.createTab() } catch {
            return jsonError("createTab failed: \(error)")
          }
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.created", tabId: model.activeTab?.id))
        case .selectTab(let id):
          model.selectTab(id)
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.selected", tabId: id))
        case .closeTab(let id):
          do { try model.closeTab(id) } catch {
            return jsonError("closeTab failed: \(error)")
          }
          renderFrameUnlocked()
          appendEvent(EventEntry(kind: "tab.closed", tabId: id))
        case .none:
          break
        }
        appendEvent(EventEntry(kind: "mouse.sidebar", action: "click"))
        return actionResult(ok: true)
      }
      guard let tab = model.activeTab, let session = model.session(forTab: tab.id) else {
        return jsonError("no active session for click")
      }
      let terminalPoint = terminalMousePosition(x: x, y: y)

      if let vs = session.viewportState(), vs.mouseTracking {
        // Mouse tracking active: send press/release events.
        let btn: MouseButton
        switch button {
        case "middle": btn = .middle
        case "right": btn = .right
        default: btn = .left
        }
        let pressEvent = MouseEvent(
          action: .press, button: btn,
          x: terminalPoint.x, y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth, screenHeight: windowHeight,
          cellWidth: cellWidth, cellHeight: cellHeight
        )
        let releaseEvent = MouseEvent(
          action: .release, button: btn,
          x: terminalPoint.x, y: terminalPoint.y,
          screenWidth: terminalSurfaceWidth, screenHeight: windowHeight,
          cellWidth: cellWidth, cellHeight: cellHeight
        )
        session.sendMouse(pressEvent)
        session.sendMouse(releaseEvent)
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "mouse.sent", sessionId: tab.sessionId, action: "click"))
        return jsonEncode(
          MouseActionResult(
            ok: true, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: true, sent: true
          ))
      } else {
        // No mouse tracking: set a one-cell local selection at the clicked cell.
        let termX = Int(terminalPoint.x)
        let termY = Int(terminalPoint.y)
        let clickedRow = max(0, windowHeight - termY - 1) / max(cellHeight, 1)
        let clickedCol = max(0, termX) / max(cellWidth, 1)
        let coord = TerminalCellCoordinate(row: clickedRow, col: clickedCol)
        let sel = TerminalSelection(sessionId: session.id, anchor: coord, focus: coord)
        selectionBySession[session.id] = sel
        appendInputEnvelope(
          InputEventEnvelope(
            inputId: UUID().uuidString,
            source: "debug",
            kind: "selection",
            route: "selection",
            frameBefore: frameBefore,
            tabId: tab.id,
            sessionId: session.id,
            command: "click",
            anchorRow: coord.row,
            anchorCol: coord.col,
            focusRow: coord.row,
            focusCol: coord.col
          ))
        renderFrameUnlocked()
        appendEvent(EventEntry(kind: "selection.set", sessionId: tab.sessionId, action: "click"))
        return jsonEncode(
          MouseActionResult(
            ok: true, frame: currentFrame,
            activeTabId: tab.id, activeSessionId: tab.sessionId,
            mouseTracking: false, sent: false
          ))
      }

    case "key":
      guard let keyName = req.key,
        let key = HeadlessDebugRuntime.keyFromName(keyName)
      else {
        return jsonError("key action requires a valid key name")
      }
      let action = HeadlessDebugRuntime.keyActionFromType(req.type)
      let mods = HeadlessDebugRuntime.modifiersFromStrings(req.modifiers)
      let consumed = HeadlessDebugRuntime.modifiersFromStrings(req.consumedModifiers)
      let frameBefore = currentFrame
      let activeTab = model.activeTab
      let inputId = UUID().uuidString

      if mods.contains(.command) {
        let (route, commandStr) = commandRouteForKey(key)
        appendInputEnvelope(
          InputEventEnvelope(
            inputId: inputId, seq: 0,
            source: "debug", kind: "key", route: route,
            frameBefore: frameBefore,
            tabId: activeTab?.id, sessionId: activeTab?.sessionId,
            key: keyName, modifiers: req.modifiers, command: commandStr
          ))
        appendEvent(EventEntry(kind: "input.key", text: keyName, action: req.action))
        if route == "appCommand" {
          executeCommandKey(key)
        }
        return actionResult(ok: true)
      }

      var unshiftedCodepoint: UInt32 = 0
      if let u = req.unshifted, let scalar = u.unicodeScalars.first {
        unshiftedCodepoint = scalar.value
      }
      let keyEvent = KeyEvent(
        action: action,
        key: key,
        modifiers: mods,
        consumedModifiers: consumed,
        unshiftedCodepoint: unshiftedCodepoint,
        text: req.text
      )
      var encodedHex: String? = nil
      var encodedLength: Int? = nil
      if let tab = activeTab, let session = model.session(forTab: tab.id) {
        if let bytes = session.encodeKey(keyEvent), !bytes.isEmpty {
          encodedHex = bytes.map { String(format: "%02x", $0) }.joined()
          encodedLength = bytes.count
        }
        session.sendKey(keyEvent)
      }
      renderFrameUnlocked()
      appendInputEnvelope(
        InputEventEnvelope(
          inputId: inputId, seq: 0,
          source: "debug", kind: "key", route: "terminal",
          frameBefore: frameBefore,
          tabId: activeTab?.id, sessionId: activeTab?.sessionId,
          key: keyName, text: req.text,
          modifiers: req.modifiers, consumedModifiers: req.consumedModifiers,
          encodedHex: encodedHex, encodedLength: encodedLength
        ))
      appendEvent(EventEntry(kind: "input.key", text: keyName, action: req.action))
      return actionResult(ok: true)

    default:
      appendEvent(EventEntry(kind: "action.unsupported", action: req.action))
      let active = model.activeTab
      return jsonEncode(
        ActionResult(
          ok: false, frame: currentFrame,
          activeTabId: active?.id, activeSessionId: active?.sessionId,
          error: "debug action \(req.action) is not implemented yet"
        ))
    }
  }

  private func actionResult(ok: Bool) -> DebugResponse {
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

    let list = model.tabs.map { tab -> SessionResponse in
      let metadata = tab.titleMetadata
      var rows = 1
      var cols = 1
      var exitStatus: Int? = nil
      var mouseTracking = false
      var focusReporting = false
      var dirty = false

      if let session = model.session(forTab: tab.id),
        let snap = session.snapshot()
      {
        defer { laban_snapshot_destroy(snap) }
        rows = max(Int(snap.pointee.rows), 1)
        cols = max(Int(snap.pointee.cols), 1)
        if snap.pointee.status != 0 { exitStatus = Int(snap.pointee.exit_status) }
        mouseTracking = snap.pointee.mouse_tracking != 0
        focusReporting = snap.pointee.focus_reporting != 0
        dirty = snap.pointee.dirty != 0
      }
      if exitStatus == nil { exitStatus = metadata.exitStatus }

      let statusStr = model.session(forTab: tab.id) != nil ? tab.status.debugString : "failed"

      // Fetch real viewport state if available.
      var scrollbackLines = 0
      var viewportOffset = 0
      if let sessionObj = model.session(forTab: tab.id),
        let vs = sessionObj.viewportState()
      {
        scrollbackLines = vs.scrollbackRows
        viewportOffset = vs.viewportOffset
      }

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
        focusReporting: focusReporting, dirty: dirty
      )
    }

    return jsonEncode(SessionsResponse(sessions: list))
  }

  public func renderState() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    let tvW = max(windowWidth - sidebarWidth, 1)
    return jsonEncode(
      RenderResponse(
        frame: currentFrame, backend: "software",
        surface: SurfaceResponse(
          width: surface.width, height: surface.height, scale: Double(surface.scale)),
        terminalViewport: RectResponse(x: sidebarWidth, y: 0, width: tvW, height: windowHeight),
        cell: CellSizeResponse(width: cellWidth, height: cellHeight),
        damage: [RectResponse(x: 0, y: 0, width: surface.width, height: surface.height)],
        lastDraw: DrawStatsResponse(
          cells: lastDrawStats.cells, glyphs: lastDrawStats.glyphs,
          backgroundRects: lastDrawStats.backgroundRects,
          images: lastDrawStats.images, cursor: lastDrawStats.cursor
        )
      ))
  }

  public func frameCommands(query: [String: String]) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    let sourceFilter = query["source"] ?? "all"
    let limit = min(query["limit"].flatMap { Int($0) } ?? 500, 2000)
    let includeText = query["includeText"] != "false"

    var result: [FrameCommandResponse] = []
    var truncated = false

    for (idx, cmd) in lastFrameCommands.enumerated() {
      let r = serializeCommandForList(cmd, index: idx, includeText: includeText)
      if sourceFilter != "all" && r.source != sourceFilter { continue }
      if result.count >= limit {
        truncated = true
        break
      }
      result.append(r)
    }

    return jsonEncode(
      FrameCommandsResponse(
        frame: currentFrame, backend: "software",
        commands: result, truncated: truncated
      ))
  }

  private func serializeCommandForList(
    _ cmd: FrameCommand, index: Int, includeText: Bool
  ) -> FrameCommandResponse {
    let id = "cmd-\(index)"
    switch cmd {
    case .rect(let rect, let color, let src):
      return FrameCommandResponse(
        id: id, index: index, kind: "rect", source: src.rawValue,
        rect: rectResponse(rect), color: rgbaArray(color))
    case .glyphRun(let origin, let text, let fg, let bg, let src):
      let approxRect = CGRect(
        x: origin.x, y: origin.y,
        width: CGFloat(text.count * cellWidth), height: CGFloat(cellHeight)
      )
      return FrameCommandResponse(
        id: id, index: index, kind: "glyphRun", source: src.rawValue,
        rect: rectResponse(approxRect),
        foreground: rgbaArray(fg), background: rgbaArray(bg),
        text: includeText ? text : nil
      )
    case .cursor(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "cursor", source: "cursor",
        rect: rectResponse(rect), color: rgbaArray(color))
    case .selection(let rect, let color):
      return FrameCommandResponse(
        id: id, index: index, kind: "selection", source: "selection",
        rect: rectResponse(rect), color: rgbaArray(color))
    case .clip(let rect):
      return FrameCommandResponse(
        id: id, index: index, kind: "clip", source: "unknown",
        rect: rectResponse(rect))
    case .texturedQuad(let rect, let resId, let src):
      return FrameCommandResponse(
        id: id, index: index, kind: "texturedQuad", source: src.rawValue,
        rect: rectResponse(rect), resourceId: String(resId))
    }
  }

  // MARK: - Render trace

  public func renderTrace(_ data: Data) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    let body = data.isEmpty ? Data("{}".utf8) : data
    let req =
      (try? JSONDecoder().decode(RenderTraceRequest.self, from: body)) ?? RenderTraceRequest()
    let limit = min(req.limit ?? 500, 2000)
    let frame = currentFrame

    var sources: [TraceSourceResponse] = [
      TraceSourceResponse(id: "state-\(frame)", kind: "appState", revision: frame)
    ]

    var snapRows = 1
    var snapCols = 1
    if let tab = model.activeTab,
      let session = model.session(forTab: tab.id),
      let snap = session.snapshot()
    {
      defer { laban_snapshot_destroy(snap) }
      snapRows = Int(snap.pointee.rows)
      snapCols = Int(snap.pointee.cols)
      sources.append(
        TraceSourceResponse(
          id: "term-snap-\(frame)", kind: "terminalSnapshot",
          sessionId: tab.sessionId, rows: snapRows, cols: snapCols
        ))
    }

    let tvW = max(windowWidth - sidebarWidth, 1)
    let layout: [TraceLayoutItem] = [
      TraceLayoutItem(
        id: "layout-window", kind: "window",
        rect: RectResponse(x: 0, y: 0, width: windowWidth, height: windowHeight),
        sourceRefs: ["state-\(frame)"]),
      TraceLayoutItem(
        id: "layout-sidebar", kind: "sidebar",
        rect: RectResponse(x: 0, y: 0, width: sidebarWidth, height: windowHeight),
        sourceRefs: ["state-\(frame)"]),
      TraceLayoutItem(
        id: "layout-terminal", kind: "terminalViewport",
        rect: RectResponse(x: sidebarWidth, y: 0, width: tvW, height: windowHeight),
        sourceRefs: ["state-\(frame)"]),
    ]

    var termGlyphs = 0
    var termBgRects = 0
    var sidebarFirst: Int? = nil
    var sidebarLast: Int? = nil
    var termFirst: Int? = nil
    var termLast: Int? = nil
    for (i, cmd) in lastFrameCommands.enumerated() {
      switch cmd {
      case .rect(_, _, let src) where src == .sidebar:
        sidebarFirst = sidebarFirst ?? i
        sidebarLast = i
      case .rect(_, _, let src) where src == .terminal:
        termBgRects += 1
        termFirst = termFirst ?? i
        termLast = i
      case .glyphRun(_, _, _, _, let src) where src == .sidebar:
        sidebarFirst = sidebarFirst ?? i
        sidebarLast = i
      case .glyphRun(_, _, _, _, let src) where src == .terminal:
        termGlyphs += 1
        termFirst = termFirst ?? i
        termLast = i
      default: break
      }
    }

    let packets: [TracePacket] =
      model.activeTab != nil
      ? [
        TracePacket(
          id: "pkt-term-\(frame)", producer: "LabanTerminalCore",
          sourceRefs: ["term-snap-\(frame)"],
          dirtyRows: [], glyphRuns: termGlyphs, backgroundRuns: termBgRects)
      ]
      : []

    var commandRanges: [TraceCommandRange] = []
    if let f = sidebarFirst, let l = sidebarLast {
      commandRanges.append(
        TraceCommandRange(
          producer: "sidebar", inputRefs: ["state-\(frame)"],
          firstCommandId: "cmd-\(f)", lastCommandId: "cmd-\(l)"
        ))
    }
    if let f = termFirst, let l = termLast {
      commandRanges.append(
        TraceCommandRange(
          producer: "terminal", inputRefs: ["pkt-term-\(frame)"],
          firstCommandId: "cmd-\(f)", lastCommandId: "cmd-\(l)"
        ))
    }

    var traceCmds: [TraceCommand] = []
    var truncated = false
    for (i, cmd) in lastFrameCommands.enumerated() {
      if traceCmds.count >= limit {
        truncated = true
        break
      }
      traceCmds.append(serializeTraceCommand(cmd, index: i))
    }

    let resources: [TraceResource] = [
      TraceResource(id: "font-jetbrainsmono", kind: "font", status: "resident"),
      TraceResource(
        id: "surface-main", kind: "surface", status: "resident",
        width: surface.width, height: surface.height),
    ]

    let clipRect = RectResponse(x: 0, y: 0, width: windowWidth, height: windowHeight)
    let draws: [TraceDraw] =
      traceCmds.isEmpty
      ? []
      : [
        TraceDraw(
          id: "draw-main", kind: "batch",
          commandRefs: traceCmds.map { $0.id },
          clip: clipRect, drawRect: clipRect)
      ]
    let passes = [TraceRenderPass(id: "pass-main", target: "window", draws: draws)]

    var pixelProbes: [TracePixelProbe] = []
    for probe in req.pixelProbes ?? [] {
      let rgba: [Int]
      if let px = surface.pixel(x: probe.x, y: probe.y) {
        rgba = rgbaArray(px)
      } else {
        rgba = [0, 0, 0, 255]
      }
      pixelProbes.append(
        TracePixelProbe(
          name: probe.name, x: probe.x, y: probe.y, rgba: rgba,
          contributors: [
            TraceContributor(passId: "pass-main", drawId: "draw-main", commandId: "cmd-0")
          ]
        ))
    }

    let invariants = [
      TraceInvariant(
        level: "ok", kind: "renderer.software",
        message: "trace produced from software renderer")
    ]

    return jsonEncode(
      RenderTraceResponse(
        traceId: "frame-\(frame)", frame: frame, backend: "software",
        surface: SurfaceResponse(
          width: surface.width, height: surface.height, scale: Double(surface.scale)),
        sources: sources, layout: layout, packets: packets,
        commandRanges: commandRanges, commands: traceCmds,
        resources: resources, passes: passes,
        pixelProbes: pixelProbes, invariants: invariants,
        truncated: truncated
      ))
  }

  private func serializeTraceCommand(_ cmd: FrameCommand, index: Int) -> TraceCommand {
    let id = "cmd-\(index)"
    switch cmd {
    case .rect(let rect, _, let src):
      return TraceCommand(
        id: id, index: index, kind: "rect", source: src.rawValue, rect: rectResponse(rect))
    case .glyphRun(let origin, let text, _, _, let src):
      let approxRect = CGRect(
        x: origin.x, y: origin.y,
        width: CGFloat(text.count * cellWidth), height: CGFloat(cellHeight)
      )
      return TraceCommand(
        id: id, index: index, kind: "glyphRun", source: src.rawValue,
        rect: rectResponse(approxRect), text: text)
    case .cursor(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "cursor", source: "cursor", rect: rectResponse(rect))
    case .selection(let rect, _):
      return TraceCommand(
        id: id, index: index, kind: "selection", source: "selection", rect: rectResponse(rect))
    case .clip(let rect):
      return TraceCommand(
        id: id, index: index, kind: "clip", source: "unknown", rect: rectResponse(rect))
    case .texturedQuad(let rect, _, let src):
      return TraceCommand(
        id: id, index: index, kind: "texturedQuad", source: src.rawValue, rect: rectResponse(rect))
    }
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
      guard let tab = model.activeTab,
        let session = model.session(forTab: tab.id),
        let snap = session.snapshot()
      else { return false }
      defer { laban_snapshot_destroy(snap) }
      return visibleText(from: UnsafePointer(snap)).contains(cond.text ?? "")
    case "renderCommandSeen":
      guard let kind = cond.commandKind else { return false }
      return lastFrameCommands.contains { cmdKindString($0) == kind }
    case "eventSeen":
      guard let kind = cond.eventKind else { return false }
      return eventLog.contains { $0.kind == kind }
    case "renderTraceInvariant":
      return true
    default:
      return false
    }
  }

  private func cmdKindString(_ cmd: FrameCommand) -> String {
    switch cmd {
    case .rect: return "rect"
    case .glyphRun: return "glyphRun"
    case .cursor: return "cursor"
    case .selection: return "selection"
    case .clip: return "clip"
    case .texturedQuad: return "texturedQuad"
    }
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
        rects.append(rectResponse(r))
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
    let filtered = inputLog.filter { $0.seq >= since }
    return jsonEncode(InputLogResponse(events: filtered, next: inputLogSeq))
  }

  public func events(since: Int) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    let filtered = eventLog.filter { $0.seq >= since }.map { e in
      EventResponse(
        seq: e.seq, kind: e.kind,
        tabId: e.tabId, sessionId: e.sessionId, frame: e.frame,
        width: e.width, height: e.height, text: e.text,
        path: e.path, action: e.action, deltaRows: e.deltaRows, error: e.error
      )
    }
    return jsonEncode(EventsResponse(events: filtered, next: eventSeq))
  }
}
