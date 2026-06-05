import Foundation
import LabanCore
import LabanRenderer

final class RenderJournal {
  static let enabledDefaultKey = "LabanRenderJournalEnabled"
  static let enabledEnvironmentKey = "LABAN_RENDER_JOURNAL"
  static let gpuFreezeAutoDumpDefaultKey = "LabanGPUFreezeJournalAutoDumpEnabled"
  static let gpuFreezeAutoDumpEnvironmentKey = "LABAN_GPU_FREEZE_JOURNAL_AUTODUMP"

  enum Event: String, Codable, Sendable {
    case rendered
    case skipped
    case renderFailed
    case freezeDetected
    case dump
  }

  struct Entry: Codable, Equatable, Sendable {
    var timestamp: Date
    var event: Event
    var frame: Int
    var processID: Int?
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
    var freeze: FreezeSnapshot?
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
    /// Diagnostic: did `syncSessions` report `modelChanged` this frame (the
    /// `advanceFrame` path that re-asserts `renderInvalidated`)? Optional so old
    /// dumps still decode.
    var modelChanged: Bool?
    /// Diagnostic: compact active-tab metadata fingerprint (title/cwd/branch/
    /// agentStatus/shell/exit). Diff it across consecutive entries to see which
    /// field flips and keeps re-invalidating an otherwise idle frame.
    var metadataSignature: String?
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

  struct FreezeSnapshot: Codable, Equatable, Sendable {
    var reason: String
    var noProgressStreak: Int
    var terminalDirty: Bool
    var activeTerminalDirty: Bool
    var renderInvalidated: Bool
    var tabChanged: Bool
    var scrollAnimating: Bool
    var rendered: Bool
    var renderFailureReason: MetalRenderer.RenderFailureReason?
    var metalFrameCompletions: Int
    var lastAcceptedFrame: Int?
    var completionCountAtLastAcceptedFrame: Int?
  }

  struct DumpSummary: Codable, Equatable, Sendable {
    var generatedAt: Date
    var entryCount: Int
    var processID: Int?
    var firstFrame: Int?
    var lastFrame: Int?
    var pngFilename: String?
  }

  private let capacity: Int
  private let dumpRoot: URL
  private let clock: () -> Date
  private let processID: Int
  private var entries: [Entry?]
  private var nextIndex = 0
  private var count = 0

  init(
    capacity: Int = 720,
    dumpRoot: URL = RenderJournal.defaultDumpRoot(),
    clock: @escaping () -> Date = Date.init,
    processID: Int = Int(ProcessInfo.processInfo.processIdentifier)
  ) {
    self.capacity = max(1, capacity)
    self.dumpRoot = dumpRoot
    self.clock = clock
    self.processID = processID
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

  static func gpuFreezeAutoDumpEnabled(
    defaults: UserDefaults = .standard,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Bool {
    if let value = environment[gpuFreezeAutoDumpEnvironmentKey] {
      return isTruthy(value)
    }
    return defaults.bool(forKey: gpuFreezeAutoDumpDefaultKey)
  }

  static func enablementAdvice(
    bundleIdentifier: String? = Bundle.main.bundleIdentifier
  ) -> String {
    let defaultsDomain = bundleIdentifier ?? "com.laban.LabanApp"
    return """
      Render journaling is disabled, so the in-memory ring was not recording frames.

      Enable it for the current app defaults domain, relaunch Laban, reproduce the issue, then dump again:

      defaults write \(defaultsDomain) \(enabledDefaultKey) -bool YES

      For one launch from a shell, set \(enabledEnvironmentKey)=1 before starting LabanApp. Defaults written under a different bundle domain are ignored.
      """
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
    freeze: FreezeSnapshot? = nil,
    rendered: Bool? = nil
  ) -> Entry {
    Entry(
      timestamp: clock(),
      event: event,
      frame: frame,
      processID: processID,
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
      freeze: freeze,
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
      processID: processID,
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
      ["path": directory.path, "entries": entries.count, "processID": processID])
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

final class GPURenderFreezeDetector {
  enum Reason: String, Codable, Sendable {
    case gpuFrameCompletionStalled
    case gpuRenderNoProgress
  }

  struct Sample: Sendable {
    var frame: Int
    var tabId: String?
    var sessionId: String?
    var gpuDriven: Bool
    var terminalDirty: Bool
    var activeTerminalDirty: Bool
    var renderInvalidated: Bool
    var tabChanged: Bool
    var scrollAnimating: Bool
    var rendered: Bool
    var renderFailureReason: MetalRenderer.RenderFailureReason?
    var metalFrameCompletions: Int
    var now: Date

    var pendingVisibleWork: Bool {
      terminalDirty || activeTerminalDirty || renderInvalidated || tabChanged || scrollAnimating
    }
  }

  struct Detection: Sendable, Equatable {
    var freeze: RenderJournal.FreezeSnapshot
    var signature: String
  }

  private let noProgressThreshold: Int
  private let duplicateThrottleSeconds: TimeInterval
  private var noProgressStreak = 0
  private var lastAcceptedFrame: Int?
  private var completionCountAtLastAcceptedFrame: Int?
  private var latestCompletionCount = 0
  private var lastDumpAtBySignature: [String: Date] = [:]

  init(noProgressThreshold: Int = 12, duplicateThrottleSeconds: TimeInterval = 60) {
    self.noProgressThreshold = max(1, noProgressThreshold)
    self.duplicateThrottleSeconds = duplicateThrottleSeconds
  }

  func reset() {
    noProgressStreak = 0
    lastAcceptedFrame = nil
    completionCountAtLastAcceptedFrame = nil
    latestCompletionCount = 0
  }

  func noteMetalFrameCompleted(completionCount: Int) {
    guard completionCount > latestCompletionCount else { return }
    latestCompletionCount = completionCount
    if let acceptedCompletion = completionCountAtLastAcceptedFrame,
      completionCount > acceptedCompletion
    {
      noProgressStreak = 0
      lastAcceptedFrame = nil
      completionCountAtLastAcceptedFrame = nil
    }
  }

  func sample(_ sample: Sample) -> Detection? {
    noteMetalFrameCompleted(completionCount: sample.metalFrameCompletions)

    guard sample.gpuDriven else {
      reset()
      return nil
    }
    guard sample.pendingVisibleWork else {
      if sample.rendered {
        rememberAcceptedFrame(sample)
      } else {
        noProgressStreak = 0
      }
      return nil
    }
    if sample.rendered {
      rememberAcceptedFrame(sample)
      noProgressStreak = 0
      return nil
    }
    guard Self.isNoProgressFailure(sample.renderFailureReason) else {
      noProgressStreak = 0
      return nil
    }

    noProgressStreak += 1
    let reason = reason(for: sample)
    let freeze = RenderJournal.FreezeSnapshot(
      reason: reason.rawValue,
      noProgressStreak: noProgressStreak,
      terminalDirty: sample.terminalDirty,
      activeTerminalDirty: sample.activeTerminalDirty,
      renderInvalidated: sample.renderInvalidated,
      tabChanged: sample.tabChanged,
      scrollAnimating: sample.scrollAnimating,
      rendered: sample.rendered,
      renderFailureReason: sample.renderFailureReason,
      metalFrameCompletions: sample.metalFrameCompletions,
      lastAcceptedFrame: lastAcceptedFrame,
      completionCountAtLastAcceptedFrame: completionCountAtLastAcceptedFrame)
    guard noProgressStreak >= noProgressThreshold else { return nil }

    let signature = [
      sample.tabId ?? "nil",
      sample.sessionId ?? "nil",
      reason.rawValue,
      sample.renderFailureReason?.rawValue ?? "nil",
    ].joined(separator: "|")
    if let previous = lastDumpAtBySignature[signature],
      sample.now.timeIntervalSince(previous) < duplicateThrottleSeconds
    {
      return nil
    }
    lastDumpAtBySignature[signature] = sample.now
    return Detection(freeze: freeze, signature: signature)
  }

  private func rememberAcceptedFrame(_ sample: Sample) {
    lastAcceptedFrame = sample.frame
    completionCountAtLastAcceptedFrame = sample.metalFrameCompletions
  }

  private func reason(for sample: Sample) -> Reason {
    if lastAcceptedFrame != nil,
      let acceptedCompletion = completionCountAtLastAcceptedFrame,
      sample.metalFrameCompletions <= acceptedCompletion
    {
      return .gpuFrameCompletionStalled
    }
    return .gpuRenderNoProgress
  }

  private static func isNoProgressFailure(
    _ reason: MetalRenderer.RenderFailureReason?
  ) -> Bool {
    switch reason {
    case .previousFrameInFlight,
      .commandBufferUnavailable,
      .targetTextureUnavailable,
      .fullRedrawProducedNoContent,
      .drawableUnavailable:
      return true
    case .drawableSizeMismatch, .none:
      return false
    }
  }
}
