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

public enum TerminalSurfaceFrameContentMode: Equatable, Sendable {
  /// Build the shared `[FrameCommand]` stream. Used by software, headless,
  /// capture/replay, frame probes, and any path that needs command fallback.
  case commands
  /// Build a local terminal cell payload and skip terminal command coalescing
  /// only when the payload is representable by the current GPU-cell milestone.
  case cellPayloadPreferred
}

public struct TerminalSurfaceFrameRequest {
  public var frame: Int
  public var viewportWidth: CGFloat
  public var viewportHeight: CGFloat
  public var insets: TerminalSurfaceInsets
  public var sidebarTopInset: CGFloat
  public var sidebarScrollOffset: CGFloat
  public var hoveredSidebarTabId: Tab.ID?
  public var sidebarDragIndicator: SidebarProducer.DragIndicator?
  public var contentYOffset: CGFloat
  public var cursorBlinkVisible: Bool
  /// Wall-clock time for time-based sidebar animation (the needsAction pulse).
  public var now: Date
  /// System Reduce Motion setting; freezes the needsAction pulse when true.
  public var reduceMotion: Bool
  /// System display-accessibility settings that affect terminal visuals.
  public var accessibilityVisualOptions: TerminalAccessibilityVisualOptions
  /// Effective, already-resolved alpha policy for this frame. Producers consume
  /// this value directly and never read settings or window state.
  public var backgroundCompositingOptions: TerminalBackgroundCompositingOptions
  /// Capability of the snapshot writer selected for this frame. Keeping it on
  /// the request prevents local, remote, prewarm, and replay seams from losing
  /// the policy input before the first frame is built.
  public var snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability
  public var selection: TerminalSelection?
  public var includeTerminalAreaBackground: Bool
  public var requireActiveSnapshot: Bool
  public var forceFullDamage: Bool
  public var surfaceWidth: Int
  public var surfaceHeight: Int
  public var surfaceScale: Double
  public var captureBackend: String
  public var contentMode: TerminalSurfaceFrameContentMode
  /// Live IME/dictation composition (marked/preedit) text to draw at the
  /// cursor, or nil when there is no in-flight composition. The producer emits
  /// it as an underlined run so it reads as pending until the program commits.
  public var preedit: String?
  /// Caret position within the composition, in cells (grapheme clusters from
  /// its start), so the cursor can sit at the IME's insertion point inside the
  /// marked text rather than always at its end.
  public var preeditCaretCells: Int
  /// User-configured cursor style (from `CursorSettings`). Overridden per frame
  /// by the snapshot's DECSCUSR-reported style when `cursor_style_explicit != 0`.
  public var userCursorStyle: CursorSettings.Style
  /// User-configured blink preference (from `CursorSettings`). Overridden per
  /// frame by the snapshot's blink flag when `cursor_blink_explicit != 0`.
  public var userCursorBlinkEnabled: Bool

  public init(
    frame: Int,
    viewportWidth: CGFloat,
    viewportHeight: CGFloat,
    insets: TerminalSurfaceInsets = .zero,
    sidebarTopInset: CGFloat = 0,
    sidebarScrollOffset: CGFloat = 0,
    hoveredSidebarTabId: Tab.ID? = nil,
    sidebarDragIndicator: SidebarProducer.DragIndicator? = nil,
    contentYOffset: CGFloat = 0,
    cursorBlinkVisible: Bool = true,
    now: Date = Date(),
    reduceMotion: Bool = false,
    accessibilityVisualOptions: TerminalAccessibilityVisualOptions = .standard,
    backgroundCompositingOptions: TerminalBackgroundCompositingOptions = .opaque,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability = .inProcess,
    selection: TerminalSelection? = nil,
    includeTerminalAreaBackground: Bool = false,
    requireActiveSnapshot: Bool = false,
    forceFullDamage: Bool = true,
    surfaceWidth: Int,
    surfaceHeight: Int,
    surfaceScale: Double,
    captureBackend: String = "software",
    contentMode: TerminalSurfaceFrameContentMode = .commands,
    preedit: String? = nil,
    preeditCaretCells: Int = 0,
    userCursorStyle: CursorSettings.Style = .block,
    userCursorBlinkEnabled: Bool = false
  ) {
    self.frame = frame
    self.viewportWidth = viewportWidth
    self.viewportHeight = viewportHeight
    self.insets = insets
    self.sidebarTopInset = sidebarTopInset
    self.sidebarScrollOffset = sidebarScrollOffset
    self.hoveredSidebarTabId = hoveredSidebarTabId
    self.sidebarDragIndicator = sidebarDragIndicator
    self.contentYOffset = contentYOffset
    self.cursorBlinkVisible = cursorBlinkVisible
    self.now = now
    self.reduceMotion = reduceMotion
    self.accessibilityVisualOptions = accessibilityVisualOptions
    self.backgroundCompositingOptions = backgroundCompositingOptions
    self.snapshotBackgroundCapability = snapshotBackgroundCapability
    self.selection = selection
    self.includeTerminalAreaBackground = includeTerminalAreaBackground
    self.requireActiveSnapshot = requireActiveSnapshot
    self.forceFullDamage = forceFullDamage
    self.surfaceWidth = surfaceWidth
    self.surfaceHeight = surfaceHeight
    self.surfaceScale = surfaceScale
    self.captureBackend = captureBackend
    self.contentMode = contentMode
    self.preedit = preedit
    self.preeditCaretCells = preeditCaretCells
    self.userCursorStyle = userCursorStyle
    self.userCursorBlinkEnabled = userCursorBlinkEnabled
  }
}

public struct TerminalSurfaceFrameDiagnostics: Codable, Equatable, Sendable {
  public struct DirtyRowRange: Codable, Equatable, Sendable {
    public var startRow: Int
    public var endRow: Int

    public init(startRow: Int, endRow: Int) {
      self.startRow = startRow
      self.endRow = endRow
    }
  }

  public var snapshotDirty: Bool?
  public var dirtyRowCount: Int?
  public var dirtyRowsSetCount: Int?
  public var dirtyRowRanges: [DirtyRowRange]
  public var visibleCellCount: Int
  public var nonBlankRowCount: Int
  public var visibleTextHash: UInt64
  public var ambiguousDirtyNoRows: Bool

  public init(
    snapshotDirty: Bool?,
    dirtyRowCount: Int?,
    dirtyRowsSetCount: Int?,
    dirtyRowRanges: [DirtyRowRange],
    visibleCellCount: Int,
    nonBlankRowCount: Int,
    visibleTextHash: UInt64,
    ambiguousDirtyNoRows: Bool
  ) {
    self.snapshotDirty = snapshotDirty
    self.dirtyRowCount = dirtyRowCount
    self.dirtyRowsSetCount = dirtyRowsSetCount
    self.dirtyRowRanges = dirtyRowRanges
    self.visibleCellCount = visibleCellCount
    self.nonBlankRowCount = nonBlankRowCount
    self.visibleTextHash = visibleTextHash
    self.ambiguousDirtyNoRows = ambiguousDirtyNoRows
  }
}

public struct TerminalSurfaceFrame {
  public var frame: Int
  public var tabId: Tab.ID?
  public var sessionId: Session.ID?
  public var commands: [FrameCommand]
  public var overlayCommands: [FrameCommand]
  public var rows: Int?
  public var cols: Int?
  /// Resolved blink flag: true when blink is active for this frame (accounts for
  /// both the user setting and any program DECSCUSR / mode-12 override).
  public var cursorBlinking: Bool
  /// Whether the cursor is visible in this frame (cursor_visible from the snapshot,
  /// or false when there is no session). Used by the blink timer gate.
  public var cursorVisible: Bool
  public var gridOriginY: CGFloat
  public var damage: RenderDamage
  public var snapshotMs: Double
  public var cellPayload: TerminalCellPayload?
  public var diagnostics: TerminalSurfaceFrameDiagnostics?

  public init(
    frame: Int,
    tabId: Tab.ID?,
    sessionId: Session.ID?,
    commands: [FrameCommand],
    overlayCommands: [FrameCommand] = [],
    rows: Int?,
    cols: Int?,
    cursorBlinking: Bool,
    cursorVisible: Bool = false,
    gridOriginY: CGFloat,
    damage: RenderDamage,
    snapshotMs: Double = 0,
    cellPayload: TerminalCellPayload? = nil,
    diagnostics: TerminalSurfaceFrameDiagnostics? = nil
  ) {
    self.frame = frame
    self.tabId = tabId
    self.sessionId = sessionId
    self.commands = commands
    self.overlayCommands = overlayCommands
    self.rows = rows
    self.cols = cols
    self.cursorBlinking = cursorBlinking
    self.cursorVisible = cursorVisible
    self.gridOriginY = gridOriginY
    self.damage = damage
    self.snapshotMs = snapshotMs
    self.cellPayload = cellPayload
    self.diagnostics = diagnostics
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

/// Value snapshot of every input the sidebar command list depends on, except
/// `now` (whose only effect is the attention pulse, handled separately). Equal
/// signatures ⇒ identical sidebar commands, so the memo can skip the rebuild.
/// Embedding the whole `TabTitleMetadata` makes every per-tab rendering input
/// part of the key automatically, so a new metadata field cannot silently go
/// stale.
private struct SidebarCacheSignature: Equatable {
  struct Entry: Equatable {
    var id: Tab.ID
    var position: Int
    var status: TabStatus
    var isActive: Bool
    var metadata: TabTitleMetadata
  }
  var tabs: [Entry]
  var activeTabId: Tab.ID?
  var viewportHeight: CGFloat
  var topInset: CGFloat
  var scrollOffset: CGFloat
  var hoveredTabId: Tab.ID?
  var dragIndicator: SidebarProducer.DragIndicator?
  var reduceMotion: Bool
  var sidebarWidth: CGFloat
  var cellWidth: CGFloat
  var cellHeight: CGFloat
  var theme: ThemeData
}

public final class TerminalSurfaceController {
  public typealias SnapshotCommandsHook = (
    _ snapshot: UnsafePointer<LabanSnapshot>,
    _ commands: [FrameCommand]
  ) -> Void

  public let model: AppModel
  public var captureSink: TerminalSurfaceCaptureSink?
  private var reusableCellPayload = TerminalCellPayload(
    rows: 0,
    cols: 0,
    origin: .zero,
    cellSize: .zero,
    contentYOffset: 0,
    defaultBackground: 0)
  private var reusablePayloadRows: [Int] = []

  // Memo for the sidebar command list. The sidebar is a pure function of its
  // inputs except for the attention pulse on a `needsAction` tab (which reads
  // `now`). When nothing is pulsing we skip the rebuild on frames where no
  // input changed. `nil` signature means "recompute, do not cache".
  private var sidebarCacheSignature: SidebarCacheSignature?
  private var sidebarCacheOutput = SidebarProducer.Output(commands: [], pulseMarkers: [])
  // Increments on every actual SidebarProducer build; lets tests assert cache
  // hits without exposing the cached buffer.
  private(set) var sidebarRebuildCountForTesting = 0

  // When each tab entered needsAction, so the announce-once marker timeline
  // (entrance bloom → static rest → re-ping) is computable per frame without
  // storing animation state in the model. Maintained on every sidebar build
  // request; entries vanish the moment a tab stops needing the user.
  private var attentionEntryTimes: [Tab.ID: Date] = [:]

  // Generation-gating: stores the dirty_generation value at the point each
  // session last had its metadata sync and renderDirty work run. When a tab's
  // generation is unchanged (and polling has already had a chance to drain the
  // PTY and advance it), the per-tab work cluster is skipped. Pruned on
  // invalidateSessionSyncCache() (tab open/close/restore).
  private var lastSyncedGeneration: [Session.ID: UInt64] = [:]

  // Glyph-effect channel (execplans/active/per-glyph-animation-channel.md):
  // remembers, per session, the dirty_generation at which terminal glyph runs
  // were last stamped with `outputTimestampSeconds`, the monotonic stamp
  // itself, and the damage bands that were fresh at that moment. The stamp is
  // re-applied to the same bands while the freshness window
  // (`GlyphEffectTimeline.maxDecaySeconds`) is open so rebuilds of a run keep
  // an identical effectStart; frames driven by scroll, selection, or blink
  // leave the generation unchanged and never create a new stamp, so their
  // re-emitted runs keep nil and effects never restart. Pruned together with
  // lastSyncedGeneration.
  private struct OutputStampRecord {
    var generation: UInt64
    var stamp: Double
    /// Fresh bands (CG-point y-up) at stamp time. Always non-empty when a
    /// record exists: unknown/ambiguous dirty state must not invent
    /// whole-grid freshness (that was the ink-bloom flicker — blooming every
    /// scrollback glyph for one frame whenever `damage()` collapsed to
    /// `.full`).
    var bands: [DirtyYRange]
  }
  private var lastOutputStamp: [Session.ID: OutputStampRecord] = [:]

  /// Clock for glyph-effect output stamps (monotonic seconds). Defaults to
  /// the shared `MonotonicClock`; headless deterministic runs substitute a
  /// virtual clock so effect ages are exactly controlled.
  public var outputStampClock: () -> Double = MonotonicClock.seconds

  // Counts per-tab metadata sync runs; lets tests assert gating correctness
  // without relying on side effects visible only via model state.
  private(set) var metadataSyncCountForTesting = 0

  public var cellWidth: Int
  public var cellHeight: Int
  public var sidebarWidth: CGFloat
  public var sidebarCellWidth: CGFloat
  public var sidebarCellHeight: CGFloat

  var cellPayloadCapacitySnapshotForTesting: TerminalCellPayload.CapacitySnapshot {
    reusableCellPayload.capacitySnapshot
  }

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

  /// Adopt new cell geometry after a live font-size change. Per-frame
  /// `FrameProducer`/`SidebarProducer` instances are constructed from these
  /// values, so frames built after this call use the new metrics. The sidebar
  /// memo includes cell metrics in its signature and self-invalidates.
  public func updateCellMetrics(
    cellWidth: Int,
    cellHeight: Int,
    sidebarCellWidth: CGFloat,
    sidebarCellHeight: CGFloat
  ) {
    self.cellWidth = max(1, cellWidth)
    self.cellHeight = max(1, cellHeight)
    self.sidebarCellWidth = max(1, sidebarCellWidth)
    self.sidebarCellHeight = max(1, sidebarCellHeight)
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
    let activeTabId = snapshot.activeTabId
    let activeSessionId = snapshot.activeSessionId
    var activeTerminalDirty = false
    var modelChanged = false
    var dirtySessionIds = Set<Session.ID>()

    for item in snapshot.tabSessions {
      let tabId = item.tabId
      let session = item.session
      session.setCaptureFrame(captureFrame)
      // Poll first: draining the PTY may advance the dirty generation so the
      // generation check below sees an up-to-date value.
      if polling == .pollAllSessions {
        _ = session.poll()
      }

      // Generation gating: read the current generation *after* any poll, then
      // compare against the last value at which we ran per-tab sync work. If
      // the generation is unchanged the session content cannot have changed, so
      // skip the metadata-sync/renderDirty cluster entirely. The stored value is
      // updated whenever we do run sync work so the next tick re-evaluates.
      // `polling == .pollAllSessions` bypasses gating (used by the headless
      // harness which drives frames on demand and must always reflect current
      // state regardless of generation).
      let currentGen = session.dirtyGeneration()
      let lastGen = lastSyncedGeneration[session.id]
      let generationUnchanged =
        polling != .pollAllSessions && currentGen != 0 && lastGen == currentGen

      if generationUnchanged {
        // Nothing has changed for this session; skip all per-tab work.
        continue
      }

      // Run the per-tab metadata sync and render-dirty cluster.
      lastSyncedGeneration[session.id] = currentGen
      metadataSyncCountForTesting += 1

      let metadataSync = model.syncSurfaceMetadata(
        forTab: tabId,
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
          forTab: tabId,
          tabIndex: item.tabIndex,
          sessionId: session.id,
          at: now
        )
      {
        modelChanged = true
      }
      if tabId == activeTabId {
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

  /// Clears the per-session generation cache. Must be called on tab
  /// open/close/restore so a recycled Session.ID cannot alias a stale
  /// generation and cause sync work to be incorrectly skipped.
  public func invalidateSessionSyncCache() {
    lastSyncedGeneration.removeAll()
    lastOutputStamp.removeAll()
  }

  /// Returns true if any tracked session has a dirty generation that
  /// differs from the last synced generation. Used by the safety-net poll
  /// (Milestone 3) to detect missed wakes without taking a full snapshot.
  public func hasUnseenSessionActivity() -> Bool {
    let snapshot = model.surfaceSessionSnapshot()
    for item in snapshot.tabSessions {
      let current = item.session.dirtyGeneration()
      if current == 0 { continue }  // unknown; treat as not unseen
      let last = lastSyncedGeneration[item.session.id]
      if last != current { return true }
    }
    return false
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
      scrollOffset: request.sidebarScrollOffset,
      hoveredTabId: request.hoveredSidebarTabId,
      dragIndicator: request.sidebarDragIndicator,
      now: request.now,
      reduceMotion: request.reduceMotion
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
    let diagnostics = Self.diagnostics(snapshot: UnsafePointer(snap))
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
          color: request.accessibilityVisualOptions.terminalBackgroundColor(
            Self.withAlpha(
              snapshot.default_background_rgba,
              request.backgroundCompositingOptions.opacity)),
          source: .terminal,
          compositing: .replace
        ))
    }

    let producer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + request.insets.left,
      originY: gridOriginY,
      contentYOffset: request.contentYOffset,
      accessibilityVisualOptions: request.accessibilityVisualOptions,
      backgroundCompositingOptions: request.backgroundCompositingOptions
    )
    // Natural (unforced) damage feeds glyph-effect stamping so freshly
    // output rows are identified precisely even on force-full frames;
    // `damage` itself keeps the pre-change forced semantics.
    let naturalDamage = Self.damage(
      snapshot: UnsafePointer(snap),
      forceFull: false,
      cellHeight: CGFloat(cellHeight),
      originY: gridOriginY)
    let damage =
      request.forceFullDamage
      ? RenderDamage.full
      : naturalDamage
    // Pre-resolve cursor for use in both cell-payload and overlay paths below.
    let preResolvedCursor = CursorStyleResolver.resolve(
      userStyle: request.userCursorStyle,
      userBlinkEnabled: request.userCursorBlinkEnabled,
      snapshotStyle: snapshot.cursor_style,
      snapshotBlinking: snapshot.cursor_blinking != 0,
      styleExplicit: snapshot.cursor_style_explicit,
      blinkExplicit: snapshot.cursor_blink_explicit
    )

    let cellPayload: TerminalCellPayload?
    let overlayCommands: [FrameCommand]
    if request.contentMode == .cellPayloadPreferred {
      Self.fillPayloadRows(
        snapshot: UnsafePointer(snap),
        damage: damage,
        into: &reusablePayloadRows)
      producer.fillTerminalCellPayload(
        into: &reusableCellPayload,
        from: UnsafePointer(snap),
        includedRows: reusablePayloadRows,
        selection: request.selection,
        findState: findState,
        viewportRowOffset: viewportOffset,
        cursorBlinkVisible: request.cursorBlinkVisible,
        includeCursor: false,
        resolvedCursor: preResolvedCursor)
      cellPayload = reusableCellPayload
      overlayCommands = producer.overlayCommands(
        from: UnsafePointer(snap),
        selection: request.selection,
        findState: findState,
        viewportRowOffset: viewportOffset,
        cursorBlinkVisible: request.cursorBlinkVisible,
        preedit: request.preedit,
        preeditCaretCells: request.preeditCaretCells,
        resolvedCursor: preResolvedCursor)
    } else {
      cellPayload = nil
      overlayCommands = []
    }
    let canSkipTerminalCommands =
      request.contentMode == .cellPayloadPreferred
      && EmojiRenderingSettings.current() == .monochrome
      && cellPayload?.isGPUCellCompatible == true
      && snapshotCommandsHook == nil
      && captureSink == nil

    if !canSkipTerminalCommands {
      commands += producer.commands(
        from: UnsafePointer(snap),
        selection: request.selection,
        findState: findState,
        viewportRowOffset: viewportOffset,
        cursorBlinkVisible: request.cursorBlinkVisible,
        preedit: request.preedit,
        preeditCaretCells: request.preeditCaretCells,
        resolvedCursor: preResolvedCursor)
    }
    commands = stampFreshOutputTimestamps(
      commands,
      session: session,
      snapshot: UnsafePointer(snap),
      originY: gridOriginY)

    snapshotCommandsHook?(UnsafePointer(snap), commands)
    recordFrameCommands(request, commands: commands)

    return TerminalSurfaceFrame(
      frame: request.frame,
      tabId: activeTab.id,
      sessionId: session.id,
      commands: commands,
      overlayCommands: canSkipTerminalCommands ? overlayCommands : [],
      rows: rows,
      cols: cols,
      cursorBlinking: preResolvedCursor.blinking,
      cursorVisible: snapshot.cursor_visible != 0,
      gridOriginY: gridOriginY,
      damage: damage,
      snapshotMs: snapshotMs,
      cellPayload: canSkipTerminalCommands ? cellPayload : nil,
      diagnostics: diagnostics
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
      scrollOffset: request.sidebarScrollOffset,
      hoveredTabId: request.hoveredSidebarTabId,
      dragIndicator: request.sidebarDragIndicator,
      now: request.now,
      reduceMotion: request.reduceMotion
    )

    let rows = max(snapshot.rows, 1)
    let cols = max(snapshot.cols, 1)
    let diagnostics = Self.diagnostics(remoteSnapshot: snapshot, dirtyRanges: dirtyRanges)
    let gridOriginY = Self.terminalGridOriginY(
      viewportHeight: request.viewportHeight,
      rows: rows,
      cellHeight: CGFloat(cellHeight),
      insets: request.insets)
    // Prefer the daemon's libghostty-supplied default-background color.
    // Treat nil and 0 as "unknown" and fall back to the theme — `cells.first
    // ?.backgroundRGBA` can be 0 (transparent black) and would leak the
    // layer-backed view's underlying color through as a black border.
    let rawDefaultBg: UInt32 = {
      if let supplied = snapshot.defaultBackgroundRGBA, supplied != 0 { return supplied }
      return Theme.current.bg0
    }()

    if request.includeTerminalAreaBackground {
      let terminalAreaWidth = max(0, request.viewportWidth - sidebarWidth)
      commands.append(
        .rect(
          CGRect(x: sidebarWidth, y: 0, width: terminalAreaWidth, height: request.viewportHeight),
          color: request.accessibilityVisualOptions.terminalBackgroundColor(
            Self.withAlpha(rawDefaultBg, request.backgroundCompositingOptions.opacity)),
          source: .terminal,
          compositing: .replace
        ))
    }

    let producer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + request.insets.left,
      originY: gridOriginY,
      contentYOffset: request.contentYOffset,
      accessibilityVisualOptions: request.accessibilityVisualOptions,
      backgroundCompositingOptions: request.backgroundCompositingOptions
    )
    commands += producer.commands(
      from: snapshot,
      selection: request.selection,
      cursorBlinkVisible: request.cursorBlinkVisible,
      preedit: request.preedit,
      preeditCaretCells: request.preeditCaretCells,
      userCursorStyle: request.userCursorStyle
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
      snapshotMs: 0,
      diagnostics: diagnostics
    )
  }

  public func sidebarCommands(
    activeTabId: Tab.ID?,
    viewportHeight: CGFloat,
    topInset: CGFloat = 0,
    scrollOffset: CGFloat = 0,
    hoveredTabId: Tab.ID? = nil,
    dragIndicator: SidebarProducer.DragIndicator? = nil,
    now: Date = Date(),
    reduceMotion: Bool = false
  ) -> [FrameCommand] {
    let tabs = model.tabs
    let producer = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: sidebarCellWidth,
      cellHeight: sidebarCellHeight)
    func build() -> SidebarProducer.Output {
      sidebarRebuildCountForTesting += 1
      return producer.output(
        tabs: tabs,
        activeTabId: activeTabId,
        height: viewportHeight,
        topInset: topInset,
        hoveredTabId: hoveredTabId,
        dragIndicator: dragIndicator,
        scrollOffset: scrollOffset)
    }

    // The producer's output is independent of `now` — needsAction pulse
    // markers are emitted at full opacity with their indices recorded — so
    // the memo holds even while a marker breathes. The pulse animates by
    // re-tinting the cached marker entries below; rebuilding the sidebar
    // (and re-resolving every tab title) at the display rate to animate one
    // dot is what saturated the main thread under streaming load.
    let signature = SidebarCacheSignature(
      tabs: tabs.map {
        SidebarCacheSignature.Entry(
          id: $0.id,
          position: $0.position,
          status: $0.status,
          isActive: $0.id == activeTabId,
          metadata: $0.titleMetadata)
      },
      activeTabId: activeTabId,
      viewportHeight: viewportHeight,
      topInset: topInset,
      scrollOffset: scrollOffset,
      hoveredTabId: hoveredTabId,
      dragIndicator: dragIndicator,
      reduceMotion: reduceMotion,
      sidebarWidth: sidebarWidth,
      cellWidth: sidebarCellWidth,
      cellHeight: sidebarCellHeight,
      theme: Theme.current)
    let output: SidebarProducer.Output
    if sidebarCacheSignature == signature {
      output = sidebarCacheOutput
    } else {
      output = build()
      sidebarCacheSignature = signature
      sidebarCacheOutput = output
    }
    // Track per-tab needsAction entry times for the announce-once timeline.
    var live: Set<Tab.ID> = []
    for tab in tabs
    where TabAttentionClassifier.classify(tab.titleMetadata, isActive: tab.id == activeTabId)
      == .needsAction
    {
      live.insert(tab.id)
      if attentionEntryTimes[tab.id] == nil { attentionEntryTimes[tab.id] = now }
    }
    if !attentionEntryTimes.isEmpty {
      attentionEntryTimes = attentionEntryTimes.filter { live.contains($0.key) }
    }

    // Animate the markers on the memoized commands. No-op when nothing needs
    // action; Reduce Motion shows the full-opacity base form unmodified.
    return reduceMotion
      ? output.commands
      : SidebarProducer.retintPulseMarkers(
        output, at: now,
        entryTimes: attentionEntryTimes,
        cellWidth: sidebarCellWidth,
        cellHeight: sidebarCellHeight,
        maxX: sidebarWidth)
  }

  private static func withAlpha(_ color: UInt32, _ alpha: UInt8) -> UInt32 {
    (color & 0xFFFF_FF00) | UInt32(alpha)
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
    var dirtyRowCount = 0
    var row = 0
    while row < rows {
      if dirty[row] != 0 {
        var end = row
        while end < rows, dirty[end] != 0 { end += 1 }
        dirtyRowCount += end - row
        let yBottom = originY + CGFloat(rows - end) * cellHeight
        let height = CGFloat(end - row) * cellHeight
        ranges.append(DirtyYRange(y: yBottom, height: height))
        row = end
      } else {
        row += 1
      }
    }
    if dirtyRowCount == 0, snapshot.dirty != 0 {
      return .full
    }
    if dirtyRowCount >= rows { return .full }
    return .partial(yRanges: ranges)
  }

  /// Row-local freshness bands for the glyph-effect stamp channel.
  ///
  /// Unlike `damage(snapshot:forceFull:...)`, this never collapses ambiguous
  /// dirty state into "the whole grid is fresh". A globally-dirty snapshot
  /// with no row bits (or a missing dirty-row bitmap) returns `nil` — the
  /// stamp path must skip rather than bloom every scrollback glyph. When
  /// every row bit is set, the returned bands cover the full grid so a
  /// true full-grid rewrite still blooms once.
  public static func freshnessBands(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    cellHeight: CGFloat,
    originY: CGFloat
  ) -> [DirtyYRange]? {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    guard rows > 0, snapshot.dirty_row_count == rows, let dirty = snapshot.dirty_rows else {
      return nil
    }

    var ranges: [DirtyYRange] = []
    var dirtyRowCount = 0
    var row = 0
    while row < rows {
      if dirty[row] != 0 {
        var end = row
        while end < rows, dirty[end] != 0 { end += 1 }
        dirtyRowCount += end - row
        let yBottom = originY + CGFloat(rows - end) * cellHeight
        let height = CGFloat(end - row) * cellHeight
        ranges.append(DirtyYRange(y: yBottom, height: height))
        row = end
      } else {
        row += 1
      }
    }
    // No row-local bits: either the snapshot is clean, or it is only
    // globally dirty. Neither case is a precise freshness signal.
    guard dirtyRowCount > 0 else { return nil }
    return ranges
  }

  public static func payloadRows(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    damage: RenderDamage
  ) -> [Int] {
    var rows: [Int] = []
    fillPayloadRows(snapshot: snap, damage: damage, into: &rows)
    return rows
  }

  public static func fillPayloadRows(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    damage: RenderDamage,
    into result: inout [Int]
  ) {
    result.removeAll(keepingCapacity: true)
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    guard rows > 0 else { return }
    switch damage {
    case .full:
      result.reserveCapacity(rows)
      for row in 0..<rows {
        result.append(row)
      }
    case .partial:
      guard snapshot.dirty_row_count == rows, let dirty = snapshot.dirty_rows else {
        result.reserveCapacity(rows)
        for row in 0..<rows {
          result.append(row)
        }
        return
      }
      result.reserveCapacity(rows)
      for row in 0..<rows where dirty[row] != 0 {
        result.append(row)
      }
    }
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
    var dirtyRowCount = 0
    for dirtyRange in dirtyRanges {
      let start = max(0, min(rows, dirtyRange.startRow))
      let end = max(0, min(rows, dirtyRange.endRow))
      guard start < end else { continue }
      dirtyRowCount += end - start
      let yBottom = originY + CGFloat(rows - end) * cellHeight
      let height = CGFloat(end - start) * cellHeight
      ranges.append(DirtyYRange(y: yBottom, height: height))
    }
    if dirtyRowCount >= rows { return .full }
    return ranges.isEmpty ? .full : .partial(yRanges: ranges)
  }

  public static func diagnostics(
    snapshot snap: UnsafePointer<LabanSnapshot>
  ) -> TerminalSurfaceFrameDiagnostics {
    let snapshot = snap.pointee
    let rows = max(0, Int(snapshot.rows))
    let cols = max(0, Int(snapshot.cols))
    let visibleCellCount = rows * cols
    var nonBlankRowCount = 0
    var hash = FNV1a64()

    if let cells = snapshot.cells {
      for row in 0..<rows {
        var rowHasText = false
        for col in 0..<cols {
          let cell = cells[row * cols + col]
          guard cell.utf8_length > 0 || cell.codepoint != 0 else { continue }
          rowHasText = true
          hash.combine(UInt64(row))
          hash.combine(UInt64(col))
          if let storage = snapshot.utf8_storage, cell.utf8_length > 0 {
            let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
            let bytes = UnsafeBufferPointer<UInt8>(
              start: ptr.assumingMemoryBound(to: UInt8.self),
              count: Int(cell.utf8_length)
            )
            hash.combine(bytes)
          } else {
            hash.combine(UInt64(cell.codepoint))
          }
        }
        if rowHasText {
          nonBlankRowCount += 1
        }
      }
    }

    let dirtyRowCount = Int(snapshot.dirty_row_count)
    let dirtySummary = dirtyRowsSummary(rows: rows, dirtyRows: snapshot.dirty_rows)
    return TerminalSurfaceFrameDiagnostics(
      snapshotDirty: snapshot.dirty != 0,
      dirtyRowCount: dirtyRowCount,
      dirtyRowsSetCount: dirtySummary.setCount,
      dirtyRowRanges: dirtySummary.ranges,
      visibleCellCount: visibleCellCount,
      nonBlankRowCount: nonBlankRowCount,
      visibleTextHash: hash.value,
      ambiguousDirtyNoRows: snapshot.dirty != 0 && dirtyRowCount == rows
        && dirtySummary.setCount == 0
    )
  }

  public static func diagnostics(
    remoteSnapshot snapshot: LabandSnapshotResponse,
    dirtyRanges: [LabandSnapshotDirtyRange]?
  ) -> TerminalSurfaceFrameDiagnostics {
    var nonBlankRows = Set<Int>()
    var hash = FNV1a64()
    for cell in snapshot.cells {
      guard !cell.text.isEmpty else { continue }
      nonBlankRows.insert(cell.row)
      hash.combine(UInt64(max(0, cell.row)))
      hash.combine(UInt64(max(0, cell.col)))
      hash.combine(cell.text.utf8)
    }

    let ranges = (dirtyRanges ?? []).map {
      TerminalSurfaceFrameDiagnostics.DirtyRowRange(
        startRow: $0.startRow,
        endRow: $0.endRow)
    }
    let setCount = dirtyRanges?.reduce(0) { partial, range in
      partial + max(0, range.endRow - range.startRow)
    }
    return TerminalSurfaceFrameDiagnostics(
      snapshotDirty: snapshot.dirty,
      dirtyRowCount: nil,
      dirtyRowsSetCount: setCount,
      dirtyRowRanges: ranges,
      visibleCellCount: max(0, snapshot.rows) * max(0, snapshot.cols),
      nonBlankRowCount: nonBlankRows.count,
      visibleTextHash: hash.value,
      ambiguousDirtyNoRows: snapshot.dirty && (dirtyRanges?.isEmpty ?? true)
    )
  }

  private static func dirtyRowsSummary(
    rows: Int,
    dirtyRows dirty: UnsafePointer<UInt8>?
  ) -> (setCount: Int, ranges: [TerminalSurfaceFrameDiagnostics.DirtyRowRange]) {
    guard rows > 0, let dirty else { return (0, []) }
    var ranges: [TerminalSurfaceFrameDiagnostics.DirtyRowRange] = []
    var setCount = 0
    var row = 0
    while row < rows {
      if dirty[row] != 0 {
        var end = row
        while end < rows, dirty[end] != 0 { end += 1 }
        setCount += end - row
        ranges.append(.init(startRow: row, endRow: end))
        row = end
      } else {
        row += 1
      }
    }
    return (setCount, ranges)
  }

  private struct FNV1a64 {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ byte: UInt8) {
      value ^= UInt64(byte)
      value = value &* 0x100_0000_01b3
    }

    mutating func combine(_ value: UInt64) {
      var raw = value.littleEndian
      for _ in 0..<8 {
        combine(UInt8(truncatingIfNeeded: raw))
        raw >>= 8
      }
    }

    mutating func combine<C: Collection>(_ bytes: C) where C.Element == UInt8 {
      for byte in bytes {
        combine(byte)
      }
    }
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

  /// Glyph-effect channel: when the session's dirty generation advanced
  /// since the last frame built here, PTY output landed — stamp the
  /// terminal-source glyph runs intersecting the fresh damage bands with the
  /// monotonic now so the renderer can treat them as freshly output. While
  /// the freshness window stays open the same stamp is re-applied to the same
  /// bands, so a run rebuilt across animation frames keeps an identical
  /// effectStart; frames driven by scroll, selection, or blink leave the
  /// generation unchanged and their re-emitted runs keep a nil timestamp, so
  /// effects never restart.
  ///
  /// Freshness comes from `freshnessBands` (row-local dirty bits), never from
  /// `RenderDamage.full`. Collapsing ambiguous dirty state into stamp-all was
  /// the grid-wide ink-bloom flicker: one keystroke bloomed every scrollback
  /// glyph for a frame whenever libghostty reported global dirty without
  /// row bits (or every row was marked dirty via the damage full-collapse).
  private func stampFreshOutputTimestamps(
    _ commands: [FrameCommand],
    session: Session,
    snapshot: UnsafePointer<LabanSnapshot>,
    originY: CGFloat
  ) -> [FrameCommand] {
    let generation = session.dirtyGeneration()
    guard generation != 0 else { return commands }
    let now = outputStampClock()
    let stamp: Double
    let bands: [DirtyYRange]
    if let record = lastOutputStamp[session.id], record.generation == generation {
      guard now - record.stamp < GlyphEffectTimeline.maxDecaySeconds
      else { return commands }
      stamp = record.stamp
      bands = record.bands
    } else {
      guard
        let freshBands = Self.freshnessBands(
          snapshot: snapshot,
          cellHeight: CGFloat(cellHeight),
          originY: originY),
        !freshBands.isEmpty
      else { return commands }
      stamp = now
      bands = freshBands
      lastOutputStamp[session.id] = OutputStampRecord(
        generation: generation, stamp: stamp, bands: bands)
    }
    let ch = CGFloat(cellHeight)
    var stamped = commands
    for index in stamped.indices {
      guard
        case .glyphRun(
          let origin, let text, let foreground, let background, let attributes, let source,
          let underlineStyle, let underlineColor, let hyperlink, let displayCellCount, _
        ) = stamped[index],
        source == .terminal
      else { continue }
      // Exact cell extent (NOT the renderer damage filter's ±1 cell
      // expansion): bands and runs are both row-aligned, and expanding here
      // would falsely stamp the clean row above/below a dirty one.
      let minY = origin.y
      let maxY = origin.y + ch
      let fresh = bands.contains { $0.y < maxY && minY < $0.y + $0.height }
      guard fresh else { continue }
      stamped[index] = .glyphRun(
        origin: origin,
        text: text,
        foreground: foreground,
        background: background,
        attributes: attributes,
        source: source,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor,
        hyperlink: hyperlink,
        displayCellCount: displayCellCount,
        outputTimestampSeconds: stamp)
    }
    return stamped
  }

  private static func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
  }
}
