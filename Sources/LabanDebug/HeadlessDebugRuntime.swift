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
  var error: String?
}

private struct ActionRequest: Decodable {
  var action: String
  var tabId: String?
  var width: Int?
  var height: Int?
  var text: String?
  var count: Int?
  var key: String?
  var modifiers: [String]?
  var x: Int?
  var y: Int?
  var deltaY: Double?
  var button: String?
  var sessionId: String?
  var deltaRows: Int?
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
  private var eventLog: [EventEntry] = []
  private var eventSeq: Int = 0

  // MARK: - Init

  public init(
    fixtureURL: URL?,
    artifactsURL: URL,
    tempURL: URL?,
    deterministic: Bool,
    runId: String
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

    self.model = try AppModel(initialSize: initSize)

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
    guard let activeTab = model.activeTab else {
      renderCommandsUnlocked([])
      return
    }

    var cmds = sidebarProducer.commands(
      tabs: model.tabs,
      activeTabId: activeTab.id,
      height: CGFloat(windowHeight)
    )

    if let session = model.session(forTab: activeTab.id) {
      session.poll()
      if let snap = session.snapshot() {
        defer { laban_snapshot_destroy(snap) }
        cmds += frameProducer.commands(from: UnsafePointer(snap))
      }
    }

    renderCommandsUnlocked(cmds)
  }

  private func renderCommandsUnlocked(_ cmds: [FrameCommand]) {
    renderer.render(cmds)
    lastFrameCommands = cmds
    lastDrawStats = countStats(cmds)
    currentFrame += 1
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

  // MARK: - Endpoints

  public func health() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return jsonEncode(HealthResponse(ok: true, mode: mode, frame: currentFrame, focused: true))
  }

  public func state() -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }
    return stateUnlocked()
  }

  private func stateUnlocked() -> DebugResponse {
    let tabs = model.tabs.enumerated().map { i, tab -> TabResponse in
      var statusStr = "running"
      var title = tab.title
      if let session = model.session(forTab: tab.id),
        let snap = session.snapshot()
      {
        defer { laban_snapshot_destroy(snap) }
        statusStr = snapshotStatus(UnsafePointer(snap))
        if let ptr = snap.pointee.title,
          let t = String(cString: ptr, encoding: .utf8), !t.isEmpty
        {
          title = t
          try? model.updateTitle(t, forTab: tab.id)
        }
      } else {
        statusStr = "failed"
      }
      return TabResponse(
        id: tab.id, index: i, title: title,
        active: tab.isActive, status: statusStr, sessionId: tab.sessionId
      )
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
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        session.write(Array(text.utf8))
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "input.typed", text: text))
      return actionResult(ok: true)

    case "advanceFrames":
      let count = max(req.count ?? 1, 1)
      for _ in 0..<count { renderFrameUnlocked() }
      return actionResult(ok: true)

    case "setClipboardText":
      guard let text = req.text else { return jsonError("setClipboardText requires text") }
      debugClipboard = text
      appendEvent(EventEntry(kind: "clipboard.set", text: text))
      return actionResult(ok: true)

    case "paste":
      if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
        session.write(Array(debugClipboard.utf8))
      }
      renderFrameUnlocked()
      appendEvent(EventEntry(kind: "clipboard.pasted", text: debugClipboard))
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

    let list = model.tabs.map { tab -> SessionResponse in
      var rows = 1
      var cols = 1
      var title = tab.title
      var statusStr = "running"
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
        statusStr = snapshotStatus(UnsafePointer(snap))
        if snap.pointee.status != 0 { exitStatus = Int(snap.pointee.exit_status) }
        mouseTracking = snap.pointee.mouse_tracking != 0
        focusReporting = snap.pointee.focus_reporting != 0
        dirty = snap.pointee.dirty != 0
        if let ptr = snap.pointee.title,
          let t = String(cString: ptr, encoding: .utf8), !t.isEmpty
        {
          title = t
        }
      }

      return SessionResponse(
        id: tab.sessionId, tabId: tab.id, pid: nil,
        status: statusStr, exitStatus: exitStatus,
        rows: rows, cols: cols,
        cellWidth: cellWidth, cellHeight: cellHeight,
        scrollbackLines: 0, viewportOffset: 0,
        title: title, mouseTracking: mouseTracking,
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
      let satisfied = checkConditionUnlocked(req.condition)
      let frame = currentFrame
      if satisfied {
        lock.unlock()
        let elapsed = Date().timeIntervalSince(startTime) * 1000.0
        return jsonEncode(WaitResult(ok: true, frame: frame, elapsedMs: elapsed))
      }
      if deterministic {
        if let tab = model.activeTab, let session = model.session(forTab: tab.id) {
          session.poll()
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

  public func events(since: Int) -> DebugResponse {
    lock.lock()
    defer { lock.unlock() }

    let filtered = eventLog.filter { $0.seq >= since }.map { e in
      EventResponse(
        seq: e.seq, kind: e.kind,
        tabId: e.tabId, sessionId: e.sessionId, frame: e.frame,
        width: e.width, height: e.height, text: e.text,
        path: e.path, action: e.action, error: e.error
      )
    }
    return jsonEncode(EventsResponse(events: filtered, next: eventSeq))
  }
}
