import CoreGraphics
import Dispatch
import Foundation
import LabanRenderer
import LabanTerminalCore

public protocol TerminalSurfaceCaptureSink: CaptureSink {
  @discardableResult
  func recordTerminalSnapshot(
    frame: Int,
    tabId: String?,
    sessionId: String?,
    snapshot: UnsafePointer<LabanSnapshot>
  ) -> String?

  @discardableResult
  func recordFrameCommands(
    frame: Int,
    commands: [FrameCommand],
    surfaceWidth: Int,
    surfaceHeight: Int,
    scale: Double,
    backend: String
  ) -> CaptureFrameRef?
}

public enum TerminalSurfaceSessionPolling: Sendable {
  case none
  case pollAllSessions
}

public struct TerminalSurfaceSessionSyncResult: Equatable, Sendable {
  public var activeTabId: Tab.ID?
  public var activeSessionId: Session.ID?
  public var activeTerminalDirty: Bool
  public var modelChanged: Bool
  public var dirtySessionIds: Set<Session.ID>

  public init(
    activeTabId: Tab.ID?,
    activeSessionId: Session.ID?,
    activeTerminalDirty: Bool,
    modelChanged: Bool,
    dirtySessionIds: Set<Session.ID>
  ) {
    self.activeTabId = activeTabId
    self.activeSessionId = activeSessionId
    self.activeTerminalDirty = activeTerminalDirty
    self.modelChanged = modelChanged
    self.dirtySessionIds = dirtySessionIds
  }
}

public struct TerminalSurfaceInsets: Equatable, Sendable {
  public var top: CGFloat
  public var left: CGFloat
  public var bottom: CGFloat
  public var right: CGFloat

  public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
    self.top = top
    self.left = left
    self.bottom = bottom
    self.right = right
  }

  public static let zero = TerminalSurfaceInsets()
}

public struct TerminalSurfaceFrameRequest {
  public var frame: Int
  public var viewportWidth: CGFloat
  public var viewportHeight: CGFloat
  public var insets: TerminalSurfaceInsets
  public var sidebarTopInset: CGFloat
  public var hoveredSidebarTabId: Tab.ID?
  public var contentYOffset: CGFloat
  public var cursorBlinkVisible: Bool
  public var selection: TerminalSelection?
  public var includeTerminalAreaBackground: Bool
  public var requireActiveSnapshot: Bool
  public var forceFullDamage: Bool
  public var surfaceWidth: Int
  public var surfaceHeight: Int
  public var surfaceScale: Double
  public var captureBackend: String

  public init(
    frame: Int,
    viewportWidth: CGFloat,
    viewportHeight: CGFloat,
    insets: TerminalSurfaceInsets = .zero,
    sidebarTopInset: CGFloat = 0,
    hoveredSidebarTabId: Tab.ID? = nil,
    contentYOffset: CGFloat = 0,
    cursorBlinkVisible: Bool = true,
    selection: TerminalSelection? = nil,
    includeTerminalAreaBackground: Bool = false,
    requireActiveSnapshot: Bool = false,
    forceFullDamage: Bool = true,
    surfaceWidth: Int,
    surfaceHeight: Int,
    surfaceScale: Double,
    captureBackend: String = "software"
  ) {
    self.frame = frame
    self.viewportWidth = viewportWidth
    self.viewportHeight = viewportHeight
    self.insets = insets
    self.sidebarTopInset = sidebarTopInset
    self.hoveredSidebarTabId = hoveredSidebarTabId
    self.contentYOffset = contentYOffset
    self.cursorBlinkVisible = cursorBlinkVisible
    self.selection = selection
    self.includeTerminalAreaBackground = includeTerminalAreaBackground
    self.requireActiveSnapshot = requireActiveSnapshot
    self.forceFullDamage = forceFullDamage
    self.surfaceWidth = surfaceWidth
    self.surfaceHeight = surfaceHeight
    self.surfaceScale = surfaceScale
    self.captureBackend = captureBackend
  }
}

public struct TerminalSurfaceFrame {
  public var frame: Int
  public var tabId: Tab.ID?
  public var sessionId: Session.ID?
  public var commands: [FrameCommand]
  public var rows: Int?
  public var cols: Int?
  public var cursorBlinking: Bool
  public var gridOriginY: CGFloat
  public var damage: RenderDamage
  public var snapshotMs: Double

  public init(
    frame: Int,
    tabId: Tab.ID?,
    sessionId: Session.ID?,
    commands: [FrameCommand],
    rows: Int?,
    cols: Int?,
    cursorBlinking: Bool,
    gridOriginY: CGFloat,
    damage: RenderDamage,
    snapshotMs: Double = 0
  ) {
    self.frame = frame
    self.tabId = tabId
    self.sessionId = sessionId
    self.commands = commands
    self.rows = rows
    self.cols = cols
    self.cursorBlinking = cursorBlinking
    self.gridOriginY = gridOriginY
    self.damage = damage
    self.snapshotMs = snapshotMs
  }
}

public enum TerminalSnapshotText {
  public enum Mode: Sendable {
    case trimmedNonEmptyRows
    case fullGrid
  }

  public static func visibleText(
    from snap: UnsafePointer<LabanSnapshot>,
    mode: Mode = .trimmedNonEmptyRows
  ) -> String {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0, let cells = snapshot.cells,
      let storage = snapshot.utf8_storage
    else { return "" }

    var lines: [String] = []
    lines.reserveCapacity(rows)

    for row in 0..<rows {
      var line = ""
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        guard cell.utf8_length > 0 else {
          if mode == .fullGrid { line += " " }
          continue
        }
        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length)
        )
        line += String(bytes: buf, encoding: .utf8) ?? (mode == .fullGrid ? " " : "")
      }

      switch mode {
      case .trimmedNonEmptyRows:
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
      case .fullGrid:
        lines.append(line)
      }
    }

    return lines.joined(separator: "\n")
  }
}

public final class TerminalSurfaceController {
  public typealias SnapshotCommandsHook = (
    _ snapshot: UnsafePointer<LabanSnapshot>,
    _ commands: [FrameCommand]
  ) -> Void

  public let model: AppModel
  public var captureSink: TerminalSurfaceCaptureSink?

  public var cellWidth: Int
  public var cellHeight: Int
  public var sidebarWidth: CGFloat
  public var sidebarCellWidth: CGFloat
  public var sidebarCellHeight: CGFloat

  public init(
    model: AppModel,
    cellWidth: Int,
    cellHeight: Int,
    sidebarWidth: CGFloat = 200,
    sidebarCellWidth: CGFloat? = nil,
    sidebarCellHeight: CGFloat? = nil,
    captureSink: TerminalSurfaceCaptureSink? = nil
  ) {
    self.model = model
    self.cellWidth = max(1, cellWidth)
    self.cellHeight = max(1, cellHeight)
    self.sidebarWidth = sidebarWidth
    self.sidebarCellWidth = sidebarCellWidth ?? CGFloat(max(1, cellWidth))
    self.sidebarCellHeight = sidebarCellHeight ?? CGFloat(max(1, cellHeight))
    self.captureSink = captureSink
  }

  @discardableResult
  public func syncSessions(
    captureFrame: Int,
    polling: TerminalSurfaceSessionPolling,
    markInactiveDirtyRendered: Bool,
    noteOutputOnDirty: Bool,
    recordTitleChanges: Bool = true,
    now: Date = Date()
  ) -> TerminalSurfaceSessionSyncResult {
    let snapshot = model.surfaceSessionSnapshot()
    let active = snapshot.activeTab
    let activeTabId = active?.id
    let activeSessionId = active?.sessionId
    var activeTerminalDirty = false
    var modelChanged = false
    var dirtySessionIds = Set<Session.ID>()

    for item in snapshot.tabSessions {
      let tab = item.tab
      let session = item.session
      session.setCaptureFrame(captureFrame)
      if polling == .pollAllSessions {
        _ = session.poll()
      }
      let metadataSync = model.syncSurfaceMetadata(
        forTab: tab.id,
        tabIndex: item.tabIndex,
        from: session,
        now: now,
        recordTitleChanges: recordTitleChanges
      )
      if metadataSync.modelChanged {
        modelChanged = true
      }
      if let event = metadataSync.titleChangeEvent {
        captureSink?.record(event)
      }

      guard session.renderDirty() else { continue }
      dirtySessionIds.insert(session.id)
      if noteOutputOnDirty,
        model.noteSurfaceOutput(
          forTab: tab.id,
          tabIndex: item.tabIndex,
          sessionId: session.id,
          at: now
        )
      {
        modelChanged = true
      }
      if tab.id == activeTabId {
        activeTerminalDirty = true
      } else if markInactiveDirtyRendered {
        _ = session.markRendered()
      }
    }

    return TerminalSurfaceSessionSyncResult(
      activeTabId: activeTabId,
      activeSessionId: activeSessionId,
      activeTerminalDirty: activeTerminalDirty,
      modelChanged: modelChanged,
      dirtySessionIds: dirtySessionIds
    )
  }

  public func makeFrame(
    _ request: TerminalSurfaceFrameRequest,
    snapshotCommandsHook: SnapshotCommandsHook? = nil
  ) -> TerminalSurfaceFrame? {
    guard let activeTab = model.activeTab else {
      if request.requireActiveSnapshot { return nil }
      return TerminalSurfaceFrame(
        frame: request.frame,
        tabId: nil,
        sessionId: nil,
        commands: [],
        rows: nil,
        cols: nil,
        cursorBlinking: false,
        gridOriginY: 0,
        damage: .full
      )
    }

    var commands = sidebarCommands(
      activeTabId: activeTab.id,
      viewportHeight: request.viewportHeight,
      topInset: request.sidebarTopInset,
      hoveredTabId: request.hoveredSidebarTabId
    )

    guard let session = model.session(forTab: activeTab.id) else {
      if request.requireActiveSnapshot { return nil }
      recordFrameCommands(request, commands: commands)
      return TerminalSurfaceFrame(
        frame: request.frame,
        tabId: activeTab.id,
        sessionId: activeTab.sessionId,
        commands: commands,
        rows: nil,
        cols: nil,
        cursorBlinking: false,
        gridOriginY: 0,
        damage: .full
      )
    }

    let snapshotStart = DispatchTime.now()
    guard let snap = session.snapshot() else {
      let snapshotMs = Self.elapsedMs(since: snapshotStart)
      if request.requireActiveSnapshot { return nil }
      recordFrameCommands(request, commands: commands)
      return TerminalSurfaceFrame(
        frame: request.frame,
        tabId: activeTab.id,
        sessionId: session.id,
        commands: commands,
        rows: nil,
        cols: nil,
        cursorBlinking: false,
        gridOriginY: 0,
        damage: .full,
        snapshotMs: snapshotMs
      )
    }
    let snapshotMs = Self.elapsedMs(since: snapshotStart)
    defer { laban_snapshot_destroy(snap) }

    captureSink?.recordTerminalSnapshot(
      frame: request.frame,
      tabId: activeTab.id,
      sessionId: session.id,
      snapshot: UnsafePointer(snap)
    )

    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    let viewportOffset = session.viewportState()?.viewportOffset ?? 0
    model.refreshFindVisible(
      sessionID: session.id,
      snapshot: UnsafePointer(snap),
      viewportOffset: viewportOffset
    )
    let findState = model.findState(forSession: session.id)
    let gridOriginY = Self.terminalGridOriginY(
      viewportHeight: request.viewportHeight,
      rows: rows,
      cellHeight: CGFloat(cellHeight),
      insets: request.insets)

    if request.includeTerminalAreaBackground {
      let terminalAreaWidth = max(0, request.viewportWidth - sidebarWidth)
      commands.append(
        .rect(
          CGRect(x: sidebarWidth, y: 0, width: terminalAreaWidth, height: request.viewportHeight),
          color: snapshot.default_background_rgba,
          source: .terminal
        ))
    }

    let producer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + request.insets.left,
      originY: gridOriginY,
      contentYOffset: request.contentYOffset
    )
    commands += producer.commands(
      from: UnsafePointer(snap),
      selection: request.selection,
      findState: findState,
      viewportRowOffset: viewportOffset,
      cursorBlinkVisible: request.cursorBlinkVisible)

    snapshotCommandsHook?(UnsafePointer(snap), commands)
    recordFrameCommands(request, commands: commands)

    let damage = Self.damage(
      snapshot: UnsafePointer(snap),
      forceFull: request.forceFullDamage,
      cellHeight: CGFloat(cellHeight),
      originY: gridOriginY)

    return TerminalSurfaceFrame(
      frame: request.frame,
      tabId: activeTab.id,
      sessionId: session.id,
      commands: commands,
      rows: rows,
      cols: cols,
      cursorBlinking: snapshot.cursor_blinking != 0,
      gridOriginY: gridOriginY,
      damage: damage,
      snapshotMs: snapshotMs
    )
  }

  public func makeFrame(
    _ request: TerminalSurfaceFrameRequest,
    remoteSnapshot snapshot: LabandSnapshotResponse,
    sessionId: Session.ID,
    dirtyRanges: [LabandSnapshotDirtyRange]? = nil
  ) -> TerminalSurfaceFrame? {
    guard let activeTab = model.activeTab else {
      if request.requireActiveSnapshot { return nil }
      return TerminalSurfaceFrame(
        frame: request.frame,
        tabId: nil,
        sessionId: nil,
        commands: [],
        rows: nil,
        cols: nil,
        cursorBlinking: false,
        gridOriginY: 0,
        damage: .full
      )
    }

    var commands = sidebarCommands(
      activeTabId: activeTab.id,
      viewportHeight: request.viewportHeight,
      topInset: request.sidebarTopInset,
      hoveredTabId: request.hoveredSidebarTabId
    )

    let rows = max(snapshot.rows, 1)
    let cols = max(snapshot.cols, 1)
    let gridOriginY = Self.terminalGridOriginY(
      viewportHeight: request.viewportHeight,
      rows: rows,
      cellHeight: CGFloat(cellHeight),
      insets: request.insets)
    // Prefer the daemon's libghostty-supplied default-background color.
    // Treat nil and 0 as "unknown" and fall back to the theme — `cells.first
    // ?.backgroundRGBA` can be 0 (transparent black) and would leak the
    // layer-backed view's underlying color through as a black border.
    let defaultBg: UInt32 = {
      if let supplied = snapshot.defaultBackgroundRGBA, supplied != 0 { return supplied }
      return Theme.current.bg0
    }()

    if request.includeTerminalAreaBackground {
      let terminalAreaWidth = max(0, request.viewportWidth - sidebarWidth)
      commands.append(
        .rect(
          CGRect(x: sidebarWidth, y: 0, width: terminalAreaWidth, height: request.viewportHeight),
          color: defaultBg,
          source: .terminal
        ))
    }

    let producer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + request.insets.left,
      originY: gridOriginY,
      contentYOffset: request.contentYOffset
    )
    commands += producer.commands(
      from: snapshot,
      selection: request.selection,
      cursorBlinkVisible: request.cursorBlinkVisible
    )
    recordFrameCommands(request, commands: commands)

    let damage = Self.damage(
      rows: rows,
      dirtyRanges: dirtyRanges,
      forceFull: request.forceFullDamage,
      cellHeight: CGFloat(cellHeight),
      originY: gridOriginY)

    return TerminalSurfaceFrame(
      frame: request.frame,
      tabId: activeTab.id,
      sessionId: sessionId,
      commands: commands,
      rows: rows,
      cols: cols,
      cursorBlinking: snapshot.cursorVisible,
      gridOriginY: gridOriginY,
      damage: damage,
      snapshotMs: 0
    )
  }

  public func sidebarCommands(
    activeTabId: Tab.ID?,
    viewportHeight: CGFloat,
    topInset: CGFloat = 0,
    hoveredTabId: Tab.ID? = nil
  ) -> [FrameCommand] {
    SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: sidebarCellWidth,
      cellHeight: sidebarCellHeight
    ).commands(
      tabs: model.tabs,
      activeTabId: activeTabId,
      height: viewportHeight,
      topInset: topInset,
      hoveredTabId: hoveredTabId)
  }

  public static func terminalGridOriginY(
    viewportHeight: CGFloat,
    rows: Int,
    cellHeight: CGFloat,
    insets: TerminalSurfaceInsets
  ) -> CGFloat {
    let gridHeight = CGFloat(max(rows, 1)) * cellHeight
    return max(insets.bottom, viewportHeight - insets.top - gridHeight)
  }

  public static func damage(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    forceFull: Bool,
    cellHeight: CGFloat,
    originY: CGFloat
  ) -> RenderDamage {
    if forceFull { return .full }
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    guard rows > 0, snapshot.dirty_row_count == rows, let dirty = snapshot.dirty_rows else {
      return .full
    }

    var ranges: [DirtyYRange] = []
    var row = 0
    while row < rows {
      if dirty[row] != 0 {
        var end = row
        while end < rows, dirty[end] != 0 { end += 1 }
        let yBottom = originY + CGFloat(rows - end) * cellHeight
        let height = CGFloat(end - row) * cellHeight
        ranges.append(DirtyYRange(y: yBottom, height: height))
        row = end
      } else {
        row += 1
      }
    }
    return .partial(yRanges: ranges)
  }

  public static func damage(
    rows: Int,
    dirtyRanges: [LabandSnapshotDirtyRange]?,
    forceFull: Bool,
    cellHeight: CGFloat,
    originY: CGFloat
  ) -> RenderDamage {
    if forceFull { return .full }
    guard rows > 0, let dirtyRanges, !dirtyRanges.isEmpty else { return .full }

    var ranges: [DirtyYRange] = []
    ranges.reserveCapacity(dirtyRanges.count)
    for dirtyRange in dirtyRanges {
      let start = max(0, min(rows, dirtyRange.startRow))
      let end = max(0, min(rows, dirtyRange.endRow))
      guard start < end else { continue }
      let yBottom = originY + CGFloat(rows - end) * cellHeight
      let height = CGFloat(end - start) * cellHeight
      ranges.append(DirtyYRange(y: yBottom, height: height))
    }
    return ranges.isEmpty ? .full : .partial(yRanges: ranges)
  }

  private func recordFrameCommands(
    _ request: TerminalSurfaceFrameRequest,
    commands: [FrameCommand]
  ) {
    captureSink?.recordFrameCommands(
      frame: request.frame,
      commands: commands,
      surfaceWidth: request.surfaceWidth,
      surfaceHeight: request.surfaceHeight,
      scale: request.surfaceScale,
      backend: request.captureBackend)
  }

  private static func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
  }
}
