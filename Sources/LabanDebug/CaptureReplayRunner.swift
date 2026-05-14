import CoreGraphics
import CryptoKit
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore

public enum CaptureReplayMode: String {
  case terminal
  case renderer
  case both
}

public struct CaptureReplayMismatch: Codable, Equatable, Sendable {
  public var kind: String
  public var frame: Int?
  public var expected: String?
  public var actual: String?
  public var path: String?
}

public struct CaptureReplayReport: Codable, Equatable, Sendable {
  public var schemaVersion = 1
  public var captureRunId: String
  public var terminalReplay: String
  public var rendererReplay: String
  public var framesCompared: Int
  public var mismatches: [CaptureReplayMismatch]
}

public enum CaptureReplayError: Error, Equatable, CustomStringConvertible, Sendable {
  case malformedTimelineLine(line: Int, message: String)
  case pathOutsideCaptureRoot(String)

  public var description: String {
    switch self {
    case .malformedTimelineLine(let line, let message):
      return "malformed timeline line \(line): \(message)"
    case .pathOutsideCaptureRoot(let path):
      return "timeline path escapes capture root: \(path)"
    }
  }
}

public final class CaptureReplayRunner {
  private let captureURL: URL
  private let mode: CaptureReplayMode
  private let fileManager = FileManager.default

  public init(captureURL: URL, mode: CaptureReplayMode = .both) {
    self.captureURL = captureURL
    self.mode = mode
  }

  @discardableResult
  public func run() throws -> CaptureReplayReport {
    let manifest = try loadManifest()
    let events = try loadTimeline()
    var mismatches: [CaptureReplayMismatch] = []
    var framesCompared = 0

    var terminalStatus = "skipped"
    var rendererStatus = "skipped"

    if mode == .terminal || mode == .both {
      let result = try runTerminalReplay(events: events)
      mismatches += result.mismatches
      framesCompared = max(framesCompared, result.framesCompared)
      terminalStatus = result.mismatches.isEmpty ? "passed" : "failed"
    }

    if mode == .renderer || mode == .both {
      let result = try runRendererReplay(events: events)
      mismatches += result.mismatches
      framesCompared = max(framesCompared, result.framesCompared)
      rendererStatus = result.mismatches.isEmpty ? "passed" : "failed"
    }

    let report = CaptureReplayReport(
      captureRunId: manifest.runId,
      terminalReplay: terminalStatus,
      rendererReplay: rendererStatus,
      framesCompared: framesCompared,
      mismatches: mismatches
    )
    try writeReport(report)
    return report
  }

  private func runTerminalReplay(events: [CaptureTimelineEvent]) throws -> (
    framesCompared: Int, mismatches: [CaptureReplayMismatch]
  ) {
    let firstSnapshot = events.first { $0.kind == CaptureEventKind.terminalSnapshot.rawValue }
    var size = LabanTerminalSize()
    size.rows = Int32(firstSnapshot?.rows ?? 24)
    size.cols = Int32(firstSnapshot?.cols ?? 80)
    let model = try AppModel(initialSize: size)
    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    var tabMap: [String: Tab.ID] = [:]
    var sessionMap: [String: Session.ID] = [:]
    var selectionBySession: [Session.ID: TerminalSelection] = [:]
    var pendingOutputByCapturedSession: [String: [[UInt8]]] = [:]
    var seenOutputByCapturedSession: Set<String> = []
    var outputSinceLastSnapshotByCapturedSession: Set<String> = []
    var seededCapturedSessions: Set<String> = []
    var framesCompared = 0
    var mismatches: [CaptureReplayMismatch] = []

    func activeSession() -> Session? {
      guard let tab = model.activeTab else { return nil }
      return model.session(forTab: tab.id)
    }

    func session(for capturedId: String?) -> Session? {
      guard let capturedId else { return activeSession() }
      if let replayId = sessionMap[capturedId],
        let tab = model.tabs.first(where: { $0.sessionId == replayId })
      {
        return model.session(forTab: tab.id)
      }
      return nil
    }

    for event in events {
      switch event.kind {
      case CaptureEventKind.sessionCreated.rawValue:
        if let capturedSession = event.sessionId, sessionMap[capturedSession] == nil {
          if sessionMap.isEmpty, let active = activeSession() {
            sessionMap[capturedSession] = active.id
            if let capturedTab = event.tabId, let tab = model.activeTab {
              tabMap[capturedTab] = tab.id
            }
          } else {
            let tab = try model.createTab()
            sessionMap[capturedSession] = tab.sessionId
            if let capturedTab = event.tabId {
              tabMap[capturedTab] = tab.id
            }
          }
          if let replaySession = session(for: capturedSession),
            let pending = pendingOutputByCapturedSession.removeValue(forKey: capturedSession)
          {
            for bytes in pending {
              _ = replaySession.replayPtyOutput(bytes)
            }
          }
        }

      case CaptureEventKind.tabSelected.rawValue:
        if let capturedTab = event.tabId, let replayTab = tabMap[capturedTab] {
          model.selectTab(replayTab)
        }

      case CaptureEventKind.tabClosed.rawValue:
        let replaySessionId = event.sessionId.flatMap { sessionMap[$0] }
        if let capturedTab = event.tabId, let replayTab = tabMap[capturedTab] {
          do {
            try model.closeTab(replayTab)
          } catch AppError.lastTabClosed {
            // A capture can end by closing the last tab. AppModel records that
            // as a sentinel error after applying the close, so replay treats it
            // as a successful state transition.
          } catch AppError.tabNotFound {
            // Duplicate or stale close events should not resurrect a mapping.
          } catch {
            throw error
          }
          tabMap.removeValue(forKey: capturedTab)
        }
        if let capturedSession = event.sessionId {
          sessionMap.removeValue(forKey: capturedSession)
        }
        if let replaySessionId {
          selectionBySession.removeValue(forKey: replaySessionId)
        }

      case CaptureEventKind.appState.rawValue:
        if let capturedTab = event.tabId, let replayTab = tabMap[capturedTab],
          let title = event.title
        {
          try? model.updateTitle(title, forTab: replayTab)
        }

      case CaptureEventKind.sessionResized.rawValue:
        if let pixelWidth = event.pixelWidth,
          let pixelHeight = event.pixelHeight,
          let eventCellWidth = event.cellWidth,
          let eventCellHeight = event.cellHeight
        {
          model.resize(
            viewportWidth: pixelWidth,
            viewportHeight: pixelHeight,
            cellWidth: eventCellWidth,
            cellHeight: eventCellHeight
          )
        } else {
          var newSize = LabanTerminalSize()
          newSize.rows = Int32(event.rows ?? 24)
          newSize.cols = Int32(event.cols ?? 80)
          newSize.pixel_width = Int32(event.pixelWidth ?? 0)
          newSize.pixel_height = Int32(event.pixelHeight ?? 0)
          newSize.cell_width = Int32(event.cellWidth ?? cellWidth)
          newSize.cell_height = Int32(event.cellHeight ?? cellHeight)
          for pair in model.allSessions() {
            _ = pair.session.resize(newSize)
          }
        }

      case CaptureEventKind.ptyOutput.rawValue:
        guard let stream = event.path, let offset = event.offset, let length = event.length else {
          break
        }
        let bytes = try readSidecarBytes(relativePath: stream, offset: offset, length: length)
        if let capturedSession = event.sessionId, sessionMap[capturedSession] == nil {
          pendingOutputByCapturedSession[capturedSession, default: []].append(bytes)
        } else {
          _ = session(for: event.sessionId)?.replayPtyOutput(bytes)
        }
        if let capturedSession = event.sessionId {
          seenOutputByCapturedSession.insert(capturedSession)
          outputSinceLastSnapshotByCapturedSession.insert(capturedSession)
        }

      case CaptureEventKind.inputEvent.rawValue:
        if let deltaRows = event.deltaRows {
          _ = session(for: event.sessionId)?.scrollViewport(deltaRows: deltaRows)
        }
        if event.command == "clearSelection",
          let replaySession = session(for: event.sessionId)
        {
          selectionBySession.removeValue(forKey: replaySession.id)
        }
        if let anchorRow = event.anchorRow,
          let anchorCol = event.anchorCol,
          let focusRow = event.focusRow,
          let focusCol = event.focusCol,
          let replaySession = session(for: event.sessionId)
        {
          selectionBySession[replaySession.id] = TerminalSelection(
            sessionId: replaySession.id,
            anchor: TerminalCellCoordinate(row: anchorRow, col: anchorCol),
            focus: TerminalCellCoordinate(row: focusRow, col: focusCol)
          )
        }
        if event.command == "find.start",
          let needle = event.text,
          let replaySession = session(for: event.sessionId)
        {
          _ = model.startFind(sessionID: replaySession.id, needle: needle)
        }
        if event.command == "find.step",
          let rawDirection = event.text,
          let direction = TerminalFindDirection(rawValue: rawDirection),
          let replaySession = session(for: event.sessionId)
        {
          _ = model.stepFind(sessionID: replaySession.id, direction: direction)
        }
        if event.command == "find.stop",
          let replaySession = session(for: event.sessionId)
        {
          _ = model.stopFind(sessionID: replaySession.id)
        }

      case CaptureEventKind.terminalSnapshot.rawValue:
        if let capturedSession = event.sessionId,
          !seededCapturedSessions.contains(capturedSession),
          !seenOutputByCapturedSession.contains(capturedSession),
          let replaySession = session(for: capturedSession),
          let snapshotPath = event.path
        {
          if let recordedSnapshot = try? loadTerminalSnapshot(relativePath: snapshotPath) {
            hydrate(replaySession, from: recordedSnapshot)
            seededCapturedSessions.insert(capturedSession)
          }
        }
        if let expected = event.visibleHash,
          let replaySession = session(for: event.sessionId),
          let snap = replaySession.snapshot()
        {
          defer { laban_snapshot_destroy(snap) }
          let visible = CaptureReplayRunner.visibleText(from: UnsafePointer(snap))
          var actual = CaptureHash.sha256(Data(visible.utf8))
          if expected != actual,
            let capturedSession = event.sessionId,
            !outputSinceLastSnapshotByCapturedSession.contains(capturedSession),
            inferViewportScroll(
              session: replaySession,
              expectedVisibleHash: expected
            )
          {
            if let inferredSnap = replaySession.snapshot() {
              defer { laban_snapshot_destroy(inferredSnap) }
              let inferredVisible = CaptureReplayRunner.visibleText(
                from: UnsafePointer(inferredSnap))
              actual = CaptureHash.sha256(Data(inferredVisible.utf8))
            }
          }
          if expected != actual {
            mismatches.append(
              CaptureReplayMismatch(
                kind: "terminalSnapshotHash",
                frame: event.frame,
                expected: expected,
                actual: actual,
                path: event.path
              ))
          }
        }
        if let capturedSession = event.sessionId {
          outputSinceLastSnapshotByCapturedSession.remove(capturedSession)
        }

      case CaptureEventKind.frameCommands.rawValue:
        guard let path = event.path else { break }
        let recorded = try loadFrameCommands(relativePath: path)
        guard let activeTab = model.activeTab,
          let session = model.session(forTab: activeTab.id),
          let snap = session.snapshot()
        else { break }
        defer { laban_snapshot_destroy(snap) }

        let layout = replayLayout(for: recorded)
        let sidebarCommands = replaySidebarCommands(
          from: recorded,
          layout: layout,
          model: model,
          activeTabId: activeTab.id,
          cellWidth: cellWidth,
          cellHeight: cellHeight
        )
        var commands = sidebarCommands
        if let terminalArea = layout.terminalArea {
          commands.append(
            .rect(
              terminalArea,
              color: snap.pointee.default_background_rgba,
              source: .terminal
            ))
        }
        let selection = selectionBySession[session.id]
        let findState = model.findState(forSession: session.id)
        let activeFindState = findState.isActive ? findState : nil
        let viewportRowOffset = session.viewportState()?.viewportOffset ?? 0
        let producer = FrameProducer(
          cellWidth: cellWidth,
          cellHeight: cellHeight,
          originX: layout.terminalOriginX,
          originY: layout.terminalOriginY
        )
        commands += producer.commands(
          from: UnsafePointer(snap),
          selection: selection,
          findState: activeFindState,
          viewportRowOffset: viewportRowOffset,
          cursorBlinkVisible: true
        )
        let payload = CapturedFrameCommands(
          frame: recorded.frame,
          backend: recorded.backend,
          surface: recorded.surface,
          commands: FrameCommandCaptureCodec.serialized(commands)
        )
        let data = try FrameCommandCaptureCodec.encoder.encode(payload)
        let actual = CaptureHash.sha256(data)
        framesCompared += 1
        if let expected = event.sha256, expected != actual {
          try writeReplayFrameCommands(data: data, frame: recorded.frame)
          mismatches.append(
            CaptureReplayMismatch(
              kind: "frameCommandsHash",
              frame: event.frame,
              expected: expected,
              actual: actual,
              path: path
            ))
        }

      default:
        break
      }
    }

    return (framesCompared, mismatches)
  }

  private func runRendererReplay(events: [CaptureTimelineEvent]) throws -> (
    framesCompared: Int, mismatches: [CaptureReplayMismatch]
  ) {
    var screenshotsByFrame: [Int: CaptureTimelineEvent] = [:]
    for event in events where event.kind == CaptureEventKind.screenshotCaptured.rawValue {
      if let frame = event.frame {
        screenshotsByFrame[frame] = event
      }
    }
    var framesCompared = 0
    var mismatches: [CaptureReplayMismatch] = []

    for event in events where event.kind == CaptureEventKind.frameCommands.rawValue {
      guard let path = event.path else { continue }
      let recorded = try loadFrameCommands(relativePath: path)
      let commands = FrameCommandCaptureCodec.commands(from: recorded.commands)
      let surface = BitmapSurface(
        width: max(recorded.surface.width, 1),
        height: max(recorded.surface.height, 1),
        scale: CGFloat(recorded.surface.scale)
      )
      let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
      renderer.render(commands)
      framesCompared += 1

      if let screenshotEvent = screenshotsByFrame[recorded.frame],
        let expected = screenshotEvent.sha256,
        let png = surface.pngData
      {
        let actual = CaptureHash.sha256(png)
        if expected != actual {
          mismatches.append(
            CaptureReplayMismatch(
              kind: "rendererScreenshotHash",
              frame: recorded.frame,
              expected: expected,
              actual: actual,
              path: path
            ))
          try writeReplayPNG(data: png, frame: recorded.frame)
        }
      }
    }

    return (framesCompared, mismatches)
  }

  private func hydrate(_ session: Session, from snapshot: ReplayTerminalSnapshot) {
    var size = LabanTerminalSize()
    size.rows = Int32(snapshot.rows)
    size.cols = Int32(snapshot.cols)
    _ = session.resize(size)
    _ = session.replayPtyOutput(Self.hydrationBytes(from: snapshot))
  }

  private func inferViewportScroll(session: Session, expectedVisibleHash: String) -> Bool {
    guard let original = session.viewportState() else { return false }
    let candidates = Self.viewportScrollCandidates(limit: 200)
    for deltaRows in candidates {
      _ = session.scrollViewport(deltaRows: deltaRows)
      if let actual = visibleHash(for: session), actual == expectedVisibleHash {
        return true
      }
      restoreViewport(session, toOffset: original.viewportOffset)
    }
    return false
  }

  private func visibleHash(for session: Session) -> String? {
    guard let snap = session.snapshot() else { return nil }
    defer { laban_snapshot_destroy(snap) }
    let visible = Self.visibleText(from: UnsafePointer(snap))
    return CaptureHash.sha256(Data(visible.utf8))
  }

  private func restoreViewport(_ session: Session, toOffset target: Int) {
    for _ in 0..<4 {
      guard let current = session.viewportState() else { return }
      if current.viewportOffset == target { return }
      _ = session.scrollViewport(deltaRows: target - current.viewportOffset)
    }
  }

  private func replaySidebarCommands(
    from recorded: CapturedFrameCommands,
    layout: ReplayFrameLayout,
    model: AppModel,
    activeTabId: Tab.ID,
    cellWidth: Int,
    cellHeight: Int
  ) -> [FrameCommand] {
    let capturedSidebar = recorded.commands
      .filter { $0.source == FrameSource.sidebar.rawValue }
      .sorted { $0.index < $1.index }

    if !capturedSidebar.isEmpty {
      return FrameCommandCaptureCodec.commands(from: capturedSidebar)
    }

    let sidebar = SidebarProducer(
      sidebarWidth: layout.sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight)
    )
    return sidebar.commands(
      tabs: model.tabs,
      activeTabId: activeTabId,
      height: layout.logicalHeight
    )
  }

  private func replayLayout(for recorded: CapturedFrameCommands) -> ReplayFrameLayout {
    let scale = recorded.surface.scale > 0 ? CGFloat(recorded.surface.scale) : 1
    let logicalWidth = CGFloat(recorded.surface.width) / scale
    let logicalHeight = CGFloat(recorded.surface.height) / scale

    let sidebarWidth =
      recorded.commands.first {
        $0.kind == "rect" && $0.source == FrameSource.sidebar.rawValue && $0.rect?.x == 0
      }?.rect?.cgRect.width ?? 200

    let terminalRects = recorded.commands
      .filter { $0.kind == "rect" && $0.source == FrameSource.terminal.rawValue && $0.rect != nil }
      .sorted { $0.index < $1.index }

    guard let firstTerminalRect = terminalRects.first?.rect?.cgRect else {
      return ReplayFrameLayout(
        sidebarWidth: sidebarWidth,
        logicalHeight: logicalHeight,
        terminalOriginX: sidebarWidth,
        terminalOriginY: 0,
        terminalArea: nil
      )
    }

    let firstLooksLikeAppKitTerminalArea =
      terminalRects.count > 1
      && abs(firstTerminalRect.minX - sidebarWidth) < 0.001
      && abs(firstTerminalRect.minY) < 0.001
      && firstTerminalRect.width >= max(0, logicalWidth - sidebarWidth - 1)
      && firstTerminalRect.height >= max(0, logicalHeight - 1)

    if firstLooksLikeAppKitTerminalArea,
      let producerRect = terminalRects.dropFirst().first?.rect?.cgRect
    {
      return ReplayFrameLayout(
        sidebarWidth: sidebarWidth,
        logicalHeight: logicalHeight,
        terminalOriginX: producerRect.minX,
        terminalOriginY: producerRect.minY,
        terminalArea: firstTerminalRect
      )
    }

    return ReplayFrameLayout(
      sidebarWidth: sidebarWidth,
      logicalHeight: logicalHeight,
      terminalOriginX: firstTerminalRect.minX,
      terminalOriginY: firstTerminalRect.minY,
      terminalArea: nil
    )
  }

  private func loadManifest() throws -> CaptureManifestSummary {
    let url = captureURL.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(CaptureManifestSummary.self, from: data)
  }

  private func loadTimeline() throws -> [CaptureTimelineEvent] {
    let url = captureURL.appendingPathComponent("timeline.ndjson")
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let decoder = JSONDecoder()
    var events: [CaptureTimelineEvent] = []
    var buffer = Data()
    var lineNumber = 0
    let newline = Data([0x0A])

    func decodeLine(_ data: Data, line: Int) throws {
      var lineData = data
      if lineData.last == 0x0D {
        lineData.removeLast()
      }
      guard !lineData.isEmpty else { return }
      do {
        events.append(try decoder.decode(CaptureTimelineEvent.self, from: lineData))
      } catch {
        throw CaptureReplayError.malformedTimelineLine(
          line: line, message: String(describing: error))
      }
    }

    while true {
      let chunk = handle.readData(ofLength: 64 * 1024)
      if chunk.isEmpty { break }
      buffer.append(chunk)
      while let range = buffer.range(of: newline) {
        lineNumber += 1
        try decodeLine(Data(buffer[..<range.lowerBound]), line: lineNumber)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
      }
    }

    if !buffer.isEmpty {
      lineNumber += 1
      try decodeLine(buffer, line: lineNumber)
    }

    return events
  }

  private func loadFrameCommands(relativePath: String) throws -> CapturedFrameCommands {
    let data = try Data(contentsOf: sidecarURL(relativePath: relativePath))
    return try JSONDecoder().decode(CapturedFrameCommands.self, from: data)
  }

  private func loadTerminalSnapshot(relativePath: String) throws -> ReplayTerminalSnapshot {
    let data = try Data(contentsOf: sidecarURL(relativePath: relativePath))
    return try JSONDecoder().decode(ReplayTerminalSnapshot.self, from: data)
  }

  private func readSidecarBytes(relativePath: String, offset: Int, length: Int) throws -> [UInt8] {
    let data = try Data(contentsOf: sidecarURL(relativePath: relativePath))
    guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
      return []
    }
    return Array(data[offset..<(offset + length)])
  }

  /// Resolve `relativePath` against the capture root and reject paths that
  /// escape it via `..` or symlink. The timeline's `path` field is otherwise
  /// trusted directly by `Data(contentsOf:)`, which would read any file the
  /// running user can read when given a tampered capture.
  private func sidecarURL(relativePath: String) throws -> URL {
    let root = captureURL.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = captureURL.appendingPathComponent(relativePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let rootPath = root.path
    let candidatePath = candidate.path
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    guard candidatePath == rootPath || candidatePath.hasPrefix(prefix) else {
      throw CaptureReplayError.pathOutsideCaptureRoot(relativePath)
    }
    return candidate
  }

  private func writeReport(_ report: CaptureReplayReport) throws {
    let replayDir = captureURL.appendingPathComponent("replay", isDirectory: true)
    try fileManager.createDirectory(at: replayDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try enc.encode(report)
    try data.write(to: replayDir.appendingPathComponent("report.json"), options: [.atomic])
  }

  private func writeReplayPNG(data: Data, frame: Int) throws {
    let replayDir = captureURL.appendingPathComponent("replay", isDirectory: true)
    try fileManager.createDirectory(at: replayDir, withIntermediateDirectories: true)
    let url = replayDir.appendingPathComponent(String(format: "frame-%06d.png", frame))
    try data.write(to: url, options: [.atomic])
  }

  private func writeReplayFrameCommands(data: Data, frame: Int) throws {
    let replayDir = captureURL.appendingPathComponent("replay", isDirectory: true)
    try fileManager.createDirectory(at: replayDir, withIntermediateDirectories: true)
    let url = replayDir.appendingPathComponent(
      String(format: "frame-%06d.actual.commands.json", frame))
    try data.write(to: url, options: [.atomic])
  }

  private static func visibleText(from snap: UnsafePointer<LabanSnapshot>) -> String {
    TerminalSnapshotText.visibleText(from: snap, mode: .fullGrid)
  }

  private static func hydrationBytes(from snapshot: ReplayTerminalSnapshot) -> [UInt8] {
    var text = "\u{1B}[0m\u{1B}[2J"
    let rows = snapshot.visibleText.components(separatedBy: "\n")
    for (rowIndex, rawLine) in rows.enumerated() where rowIndex < snapshot.rows {
      let line = Self.hydrationLine(rawLine, rowIndex: rowIndex, snapshot: snapshot)
      guard !line.isEmpty else { continue }
      text += "\u{1B}[\(rowIndex + 1);1H\(line)"
    }
    text += snapshot.cursorVisible ? "\u{1B}[?25h" : "\u{1B}[?25l"
    text += "\u{1B}[\(snapshot.cursorRow + 1);\(snapshot.cursorCol + 1)H"
    return Array(text.utf8)
  }

  private static func viewportScrollCandidates(limit: Int) -> [Int] {
    guard limit > 0 else { return [] }
    var candidates: [Int] = []
    candidates.reserveCapacity(limit * 2)
    for value in 1...limit {
      candidates.append(-value)
      candidates.append(value)
    }
    return candidates
  }

  private static func hydrationLine(
    _ rawLine: String,
    rowIndex: Int,
    snapshot: ReplayTerminalSnapshot
  ) -> String {
    let chars = Array(rawLine)
    var end = chars.endIndex
    while end > chars.startIndex, chars[end - 1] == " " {
      end -= 1
    }
    if rowIndex == snapshot.cursorRow {
      end = max(end, min(snapshot.cursorCol, chars.count))
    }
    guard end > chars.startIndex else { return "" }
    return String(chars[..<end])
  }
}

private struct CaptureManifestSummary: Decodable {
  var schemaVersion: Int
  var kind: String
  var runId: String
}

private struct ReplayTerminalSnapshot: Decodable {
  var frame: Int
  var sessionId: String?
  var rows: Int
  var cols: Int
  var cursorRow: Int
  var cursorCol: Int
  var cursorVisible: Bool
  var visibleText: String
  var visibleHash: String
}

private struct ReplayFrameLayout {
  var sidebarWidth: CGFloat
  var logicalHeight: CGFloat
  var terminalOriginX: CGFloat
  var terminalOriginY: CGFloat
  var terminalArea: CGRect?
}
