import Darwin
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
    /// Which wake source triggered the `advanceFrame` that produced this
    /// entry (`FrameWakeSource.rawValue`). Optional so old dumps still decode;
    /// the primary forensic field for full-park missed-wake hunts.
    var wakeSource: String?
    var transportMode: String?
    var renderer: RendererSnapshot?
    var surface: SurfaceSnapshot?
    var window: WindowSnapshot?
    var displayLink: DisplayLinkSnapshot?
    var frameState: FrameStateSnapshot?
    var viewport: ViewportSnapshot?
    var scroll: ScrollSnapshot?
    var damage: DamageSnapshot?
    var commandCounts: CommandCounts?
    var payload: PayloadSnapshot?
    var diagnostics: TerminalSurfaceFrameDiagnostics?
    /// Ink-bloom stamp decision for this frame. Optional so older journal
    /// dumps still decode.
    var glyphEffect: GlyphEffectStampDiagnostics?
    var metalInstances: MetalInstanceCounts?
    var drawableAcquire: MetalDrawableAcquireDiagnostic?
    var gpuCellPayloadFailure: MetalRenderer.GPUCellPayloadBuildFailure?
    var renderFailureReason: RenderFailureReason?
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

  struct WindowSnapshot: Codable, Equatable, Sendable {
    var isVisible: Bool
    var isKeyWindow: Bool
    var isMainWindow: Bool
    var isMiniaturized: Bool
    var occlusionVisible: Bool
    var visibleToUser: Bool
    var backingScaleFactor: Double
    var screenName: String?
  }

  struct DisplayLinkSnapshot: Codable, Equatable, Sendable {
    var kind: String
    var paused: Bool?
    var preferredFramesPerSecond: Int?
    var minimumFramesPerSecond: Int?
    var maximumFramesPerSecond: Int?
    var reason: String
    var terminalOutputActive: Bool
    var attentionAnimating: Bool
    var scrollAnimating: Bool
    /// Whether a per-glyph effect was animating (the `"glyphEffect"` reason
    /// rung). Optional so old journal dumps still decode.
    var glyphEffectAnimating: Bool? = nil
    var lastTickIntervalMs: Double?
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
    /// Diagnostic: whether the cursor-blink `DispatchSourceTimer` is running
    /// this frame. Optional so old journal dumps still decode.
    var cursorBlinkTimerActive: Bool?
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
    var renderFailureReason: RenderFailureReason?
    var metalFrameCompletions: Int
    var lastAcceptedFrame: Int?
    var completionCountAtLastAcceptedFrame: Int?
  }

  struct DumpSummary: Codable, Equatable, Sendable {
    var generatedAt: Date
    var entryCount: Int
    var processID: Int?
    var process: ProcessSnapshot?
    var firstFrame: Int?
    var lastFrame: Int?
    var pngFilename: String?
  }

  struct ProcessSnapshot: Codable, Equatable, Sendable {
    var processID: Int
    var processStartedAt: Date?
    var executablePath: String?
    var executableDevice: UInt64?
    var executableInode: UInt64?
    var buildCommit: String?

    init(
      processID: Int,
      processStartedAt: Date? = nil,
      executablePath: String? = nil,
      executableDevice: UInt64? = nil,
      executableInode: UInt64? = nil,
      buildCommit: String? = nil
    ) {
      self.processID = processID
      self.processStartedAt = processStartedAt
      self.executablePath = executablePath
      self.executableDevice = executableDevice
      self.executableInode = executableInode
      self.buildCommit = buildCommit
    }

    static func current(
      processID: Int = Int(ProcessInfo.processInfo.processIdentifier)
    ) -> ProcessSnapshot {
      let executablePath =
        Bundle.main.executableURL?.path
        ?? ProcessInfo.processInfo.arguments.first
      let executableIdentity = executablePath.flatMap(fileIdentity)
      return ProcessSnapshot(
        processID: processID,
        processStartedAt: processStartedAt(pid: pid_t(processID)),
        executablePath: executablePath,
        executableDevice: executableIdentity?.device,
        executableInode: executableIdentity?.inode,
        buildCommit: Bundle.main.object(forInfoDictionaryKey: "LABANBuildCommit") as? String)
    }

    private static func processStartedAt(pid: pid_t) -> Date? {
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
      var info = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
      guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
      let seconds = info.kp_proc.p_starttime.tv_sec
      guard seconds > 0 else { return nil }
      let usec = info.kp_proc.p_starttime.tv_usec
      return Date(timeIntervalSince1970: Double(seconds) + Double(usec) / 1_000_000.0)
    }

    private static func fileIdentity(_ path: String) -> (device: UInt64, inode: UInt64)? {
      var st = stat()
      guard stat(path, &st) == 0 else { return nil }
      return (UInt64(st.st_dev), UInt64(st.st_ino))
    }
  }

  private let capacity: Int
  private let dumpRoot: URL
  private let clock: () -> Date
  private let processID: Int
  private let process: ProcessSnapshot
  private var entries: [Entry?]
  private var nextIndex = 0
  private var count = 0

  init(
    capacity: Int = 720,
    dumpRoot: URL = RenderJournal.defaultDumpRoot(),
    clock: @escaping () -> Date = Date.init,
    processID: Int = Int(ProcessInfo.processInfo.processIdentifier),
    process: ProcessSnapshot? = nil
  ) {
    self.capacity = max(1, capacity)
    self.dumpRoot = dumpRoot
    self.clock = clock
    self.processID = processID
    self.process = process ?? .current(processID: processID)
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
    wakeSource: String? = nil,
    transportMode: String? = nil,
    rendererStatus: RendererStatus? = nil,
    surface: SurfaceSnapshot? = nil,
    window: WindowSnapshot? = nil,
    displayLink: DisplayLinkSnapshot? = nil,
    frameState: FrameStateSnapshot? = nil,
    viewport: ViewportSnapshot? = nil,
    scroll: ScrollSnapshot? = nil,
    damage: RenderDamage? = nil,
    commands: [FrameCommand]? = nil,
    overlayCommands: [FrameCommand] = [],
    payload: TerminalCellPayload? = nil,
    diagnostics: TerminalSurfaceFrameDiagnostics? = nil,
    glyphEffect: GlyphEffectStampDiagnostics? = nil,
    metalInstances: MetalRenderer.RenderInstanceCounts? = nil,
    drawableAcquire: MetalDrawableAcquireDiagnostic? = nil,
    gpuCellPayloadFailure: MetalRenderer.GPUCellPayloadBuildFailure? = nil,
    renderFailureReason: RenderFailureReason? = nil,
    freeze: FreezeSnapshot? = nil,
    rendered: Bool? = nil
  ) -> Entry {
    // A drawable is only acquired on a frame that reached `render()`. The
    // renderer resets `lastDrawableAcquireDiagnostic` at render entry and sets
    // it after the acquire, so it survives across skipped frames describing an
    // earlier rendered frame. A skipped/dump entry never acquired a drawable,
    // so drop the carried diagnostic rather than misattribute it.
    let drawableAcquireForEvent: MetalDrawableAcquireDiagnostic?
    switch event {
    case .rendered, .renderFailed, .freezeDetected:
      drawableAcquireForEvent = drawableAcquire
    case .skipped, .dump:
      drawableAcquireForEvent = nil
    }
    return Entry(
      timestamp: clock(),
      event: event,
      frame: frame,
      processID: processID,
      tabId: tabId,
      sessionId: sessionId,
      reason: reason,
      wakeSource: wakeSource,
      transportMode: transportMode,
      renderer: rendererStatus.map(RendererSnapshot.init),
      surface: surface,
      window: window,
      displayLink: displayLink,
      frameState: frameState,
      viewport: viewport,
      scroll: scroll,
      damage: damage.map(Self.damageSnapshot),
      commandCounts: commands.map {
        Self.commandCounts(commands: $0, overlayCommands: overlayCommands)
      },
      payload: payload.map(Self.payloadSnapshot),
      diagnostics: diagnostics,
      glyphEffect: glyphEffect,
      metalInstances: metalInstances.map(MetalInstanceCounts.init),
      drawableAcquire: drawableAcquireForEvent,
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
      process: process,
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
    var renderFailureReason: RenderFailureReason?
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
    _ reason: RenderFailureReason?
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
