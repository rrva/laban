import Foundation
import LabanCore
import LabanRenderer

final class RenderJournal {
  static let enabledDefaultKey = "LabanRenderJournalEnabled"
  static let enabledEnvironmentKey = "LABAN_RENDER_JOURNAL"

  enum Event: String, Codable, Sendable {
    case rendered
    case skipped
    case renderFailed
    case dump
  }

  struct Entry: Codable, Equatable, Sendable {
    var timestamp: Date
    var event: Event
    var frame: Int
    var tabId: String?
    var sessionId: String?
    var reason: String?
    var transportMode: String?
    var renderer: RendererSnapshot?
    var surface: SurfaceSnapshot?
    var frameState: FrameStateSnapshot?
    var viewport: ViewportSnapshot?
    var scroll: ScrollSnapshot?
    var damage: DamageSnapshot?
    var commandCounts: CommandCounts?
    var payload: PayloadSnapshot?
    var diagnostics: TerminalSurfaceFrameDiagnostics?
    var metalInstances: MetalInstanceCounts?
    var gpuCellPayloadFailure: MetalRenderer.GPUCellPayloadBuildFailure?
    var renderFailureReason: MetalRenderer.RenderFailureReason?
    var rendered: Bool?
  }

  struct RendererSnapshot: Codable, Equatable, Sendable {
    var configured: String
    var effective: String
    var fallbackReason: String?

    init(_ status: RendererStatus) {
      self.configured = status.configuredRenderer
      self.effective = status.effectiveRenderer
      self.fallbackReason = status.fallbackReason
    }
  }

  struct SurfaceSnapshot: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var scale: Double
  }

  struct FrameStateSnapshot: Codable, Equatable, Sendable {
    var terminalDirty: Bool
    var activeTerminalDirty: Bool
    var renderInvalidated: Bool
    var tabChanged: Bool
    var cursorBlinkFrame: Bool
    var attentionAnimating: Bool
    var scrollAnimating: Bool
    var renderingResizeFrame: Bool
    var usingRemoteSnapshots: Bool
    var gpuCellRequested: Bool
    var cellPayloadRequested: Bool
    var gpuCellCommandFallbackPending: Bool
  }

  struct ViewportSnapshot: Codable, Equatable, Sendable {
    var offset: Int
    var totalRows: Int
    var viewportRows: Int
    var scrollbackRows: Int
    var altScreen: Bool
    var mouseTracking: Bool
    var linesBack: Int
  }

  struct ScrollSnapshot: Codable, Equatable, Sendable {
    var appliedRows: Int
    var displayedRows: Double
    var targetRows: Double
    var velocityRowsPerSecond: Double
    var contentYOffset: Double
  }

  struct DamageSnapshot: Codable, Equatable, Sendable {
    struct Range: Codable, Equatable, Sendable {
      var y: Double
      var height: Double
    }

    var kind: String
    var rangeCount: Int
    var ranges: [Range]
  }

  struct CommandCounts: Codable, Equatable, Sendable {
    var total: Int
    var overlay: Int
    var rects: Int
    var glyphRuns: Int
    var cursors: Int
    var selections: Int
    var findMatches: Int
    var clips: Int
    var texturedQuads: Int
  }

  struct PayloadSnapshot: Codable, Equatable, Sendable {
    var rows: Int
    var cols: Int
    var dirtyRows: Int
    var backgroundRuns: Int
    var glyphs: Int
    var proceduralCells: Int
    var cursorRects: Int
    var utf8Bytes: Int
    var fallbackReason: String?
  }

  struct MetalInstanceCounts: Codable, Equatable, Sendable {
    var solids: Int
    var glyphs: Int
    var sidebarGlyphs: Int
    var cellGlyphs: Int
    var cursors: Int

    init(_ counts: MetalRenderer.RenderInstanceCounts) {
      self.solids = counts.solids
      self.glyphs = counts.glyphs
      self.sidebarGlyphs = counts.sidebarGlyphs
      self.cellGlyphs = counts.cellGlyphs
      self.cursors = counts.cursors
    }
  }

  struct DumpSummary: Codable, Equatable, Sendable {
    var generatedAt: Date
    var entryCount: Int
    var firstFrame: Int?
    var lastFrame: Int?
    var pngFilename: String?
  }

  private let capacity: Int
  private let dumpRoot: URL
  private let clock: () -> Date
  private var entries: [Entry?]
  private var nextIndex = 0
  private var count = 0

  init(
    capacity: Int = 720,
    dumpRoot: URL = RenderJournal.defaultDumpRoot(),
    clock: @escaping () -> Date = Date.init
  ) {
    self.capacity = max(1, capacity)
    self.dumpRoot = dumpRoot
    self.clock = clock
    self.entries = Array(repeating: nil, count: max(1, capacity))
  }

  static func isEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if let value = environment[enabledEnvironmentKey] {
      return isTruthy(value)
    }
    return defaults.bool(forKey: enabledDefaultKey)
  }

  private static func isTruthy(_ value: String) -> Bool {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on", "enabled":
      return true
    default:
      return false
    }
  }

  func makeEntry(
    event: Event,
    frame: Int,
    tabId: String?,
    sessionId: String?,
    reason: String? = nil,
    transportMode: String? = nil,
    rendererStatus: RendererStatus? = nil,
    surface: SurfaceSnapshot? = nil,
    frameState: FrameStateSnapshot? = nil,
    viewport: ViewportSnapshot? = nil,
    scroll: ScrollSnapshot? = nil,
    damage: RenderDamage? = nil,
    commands: [FrameCommand]? = nil,
    overlayCommands: [FrameCommand] = [],
    payload: TerminalCellPayload? = nil,
    diagnostics: TerminalSurfaceFrameDiagnostics? = nil,
    metalInstances: MetalRenderer.RenderInstanceCounts? = nil,
    gpuCellPayloadFailure: MetalRenderer.GPUCellPayloadBuildFailure? = nil,
    renderFailureReason: MetalRenderer.RenderFailureReason? = nil,
    rendered: Bool? = nil
  ) -> Entry {
    Entry(
      timestamp: clock(),
      event: event,
      frame: frame,
      tabId: tabId,
      sessionId: sessionId,
      reason: reason,
      transportMode: transportMode,
      renderer: rendererStatus.map(RendererSnapshot.init),
      surface: surface,
      frameState: frameState,
      viewport: viewport,
      scroll: scroll,
      damage: damage.map(Self.damageSnapshot),
      commandCounts: commands.map {
        Self.commandCounts(commands: $0, overlayCommands: overlayCommands)
      },
      payload: payload.map(Self.payloadSnapshot),
      diagnostics: diagnostics,
      metalInstances: metalInstances.map(MetalInstanceCounts.init),
      gpuCellPayloadFailure: gpuCellPayloadFailure,
      renderFailureReason: renderFailureReason,
      rendered: rendered)
  }

  func record(_ entry: Entry) {
    entries[nextIndex] = entry
    nextIndex = (nextIndex + 1) % capacity
    count = min(capacity, count + 1)
  }

  func snapshot() -> [Entry] {
    guard count > 0 else { return [] }
    let start = count == capacity ? nextIndex : 0
    var result: [Entry] = []
    result.reserveCapacity(count)
    for offset in 0..<count {
      let index = (start + offset) % capacity
      if let entry = entries[index] {
        result.append(entry)
      }
    }
    return result
  }

  @discardableResult
  func dump(currentPNG: Data? = nil) throws -> URL {
    let entries = snapshot()
    let directory = dumpRoot.appendingPathComponent(Self.stamp(clock()), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var pngFilename: String?
    if let currentPNG {
      pngFilename = "current-frame.png"
      try currentPNG.write(to: directory.appendingPathComponent("current-frame.png"))
    }

    let summary = DumpSummary(
      generatedAt: clock(),
      entryCount: entries.count,
      firstFrame: entries.first?.frame,
      lastFrame: entries.last?.frame,
      pngFilename: pngFilename)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(summary).write(to: directory.appendingPathComponent("summary.json"))

    var jsonl = Data()
    let lineEncoder = JSONEncoder()
    lineEncoder.dateEncodingStrategy = .iso8601
    lineEncoder.outputFormatting = [.sortedKeys]
    for entry in entries {
      jsonl.append(try lineEncoder.encode(entry))
      jsonl.append(0x0A)
    }
    try jsonl.write(to: directory.appendingPathComponent("entries.jsonl"))

    let dumpEntry = makeEntry(
      event: .dump,
      frame: entries.last?.frame ?? 0,
      tabId: entries.last?.tabId,
      sessionId: entries.last?.sessionId,
      reason: directory.path)
    record(dumpEntry)
    EventLog.shared.log(
      "render.journal.dump",
      ["path": directory.path, "entries": entries.count])
    return directory
  }

  static func damageSnapshot(_ damage: RenderDamage) -> DamageSnapshot {
    switch damage {
    case .full:
      return DamageSnapshot(kind: "full", rangeCount: 0, ranges: [])
    case .partial(let yRanges):
      return DamageSnapshot(
        kind: "partial",
        rangeCount: yRanges.count,
        ranges: yRanges.map { .init(y: Double($0.y), height: Double($0.height)) })
    }
  }

  static func payloadSnapshot(_ payload: TerminalCellPayload) -> PayloadSnapshot {
    PayloadSnapshot(
      rows: payload.rows,
      cols: payload.cols,
      dirtyRows: payload.dirtyRows.count,
      backgroundRuns: payload.backgroundRuns.count,
      glyphs: payload.glyphs.count,
      proceduralCells: payload.proceduralCells.count,
      cursorRects: payload.cursorRects.count,
      utf8Bytes: payload.utf8Bytes.count,
      fallbackReason: payload.fallbackReason?.rawValue)
  }

  static func commandCounts(
    commands: [FrameCommand],
    overlayCommands: [FrameCommand]
  ) -> CommandCounts {
    var counts = CommandCounts(
      total: commands.count + overlayCommands.count,
      overlay: overlayCommands.count,
      rects: 0,
      glyphRuns: 0,
      cursors: 0,
      selections: 0,
      findMatches: 0,
      clips: 0,
      texturedQuads: 0)
    for command in commands {
      count(command, into: &counts)
    }
    for command in overlayCommands {
      count(command, into: &counts)
    }
    return counts
  }

  private static func count(_ command: FrameCommand, into counts: inout CommandCounts) {
    switch command {
    case .rect:
      counts.rects += 1
    case .glyphRun:
      counts.glyphRuns += 1
    case .cursor:
      counts.cursors += 1
    case .selection:
      counts.selections += 1
    case .findMatch, .findSelected:
      counts.findMatches += 1
    case .clip:
      counts.clips += 1
    case .texturedQuad:
      counts.texturedQuads += 1
    }
  }

  static func defaultDumpRoot() -> URL {
    let library =
      FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    return
      library
      .appendingPathComponent("Logs")
      .appendingPathComponent("Laban")
      .appendingPathComponent("render-journal")
  }

  private static func stamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
      .replacingOccurrences(of: ":", with: "")
      .replacingOccurrences(of: ".", with: "")
  }
}
