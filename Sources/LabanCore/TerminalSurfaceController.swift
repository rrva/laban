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
  public var spinnerMotionSmoothingEnabled: Bool
  public var effectiveRendererIsSlug: Bool

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
    userCursorBlinkEnabled: Bool = false,
    spinnerMotionSmoothingEnabled: Bool = false,
    effectiveRendererIsSlug: Bool = false
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
    self.spinnerMotionSmoothingEnabled = spinnerMotionSmoothingEnabled
    self.effectiveRendererIsSlug = effectiveRendererIsSlug
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
  /// Ink-bloom stamp decision for this frame (render-journal `glyphEffect`).
  public var glyphEffectStamp: GlyphEffectStampDiagnostics?
  /// Spinner-motion detector diagnostics for this frame (render-journal). Optional.
  public var spinnerMotionDiagnostics: SpinnerMotionDiagnostics?

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
    diagnostics: TerminalSurfaceFrameDiagnostics? = nil,
    glyphEffectStamp: GlyphEffectStampDiagnostics? = nil,
    spinnerMotionDiagnostics: SpinnerMotionDiagnostics? = nil
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
    self.glyphEffectStamp = glyphEffectStamp
    self.spinnerMotionDiagnostics = spinnerMotionDiagnostics
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

/// How the ink-bloom stamp path chose freshness for a frame. Surfaced in
/// render-journal `glyphEffect.mode` so dumps can distinguish per-cell typing
/// blooms from whole-row re-blooms without a PTY capture.
public enum GlyphEffectStampMode: String, Codable, Equatable, Sendable {
  /// No stamp applied this frame.
  case none
  /// Cell-content diff produced an X strip of changed columns.
  case cellDiff
  /// Fallback: single cell (or previous whole row) at the cursor.
  case cursorCell
  /// Diff saw a bulk rewrite (multi-row or near-full row). Recorded for
  /// journal forensics only — stamping is suppressed (TUIs like btop).
  case wholeRun
  /// Mouse tracking is active (fullscreen TUI). Stamping suppressed — Claude
  /// Code / similar apps animate spinners via glyph + color churn that would
  /// otherwise classify as `cellDiff` and flicker.
  case suppressedTUI
  /// Same dirty generation still inside the freshness window; prior stamp
  /// re-applied for effectStart stability.
  case reapply
}

/// Freshness region for ink-bloom stamping: Y bands always, optional X strip
/// so only changed character cells bloom (settled prompt text stays put).
public struct GlyphEffectFreshness: Equatable, Sendable {
  public var bands: [DirtyYRange]
  /// When both are set, only the half-open strip `[xMin, xMax)` is fresh and
  /// intersecting glyph runs are split so settled prefix/suffix stay
  /// unstamped. When nil, every terminal glyph run intersecting `bands` is
  /// stamped as a whole (bulk multi-row output).
  public var xMin: CGFloat?
  public var xMax: CGFloat?
  public var mode: GlyphEffectStampMode
  public var dirtyRows: [Int]
  /// Inclusive column span of an X strip when `hasCellStrip`.
  public var stripColMin: Int?
  public var stripColMax: Int?
  public var changedCells: Int?

  public init(
    bands: [DirtyYRange],
    xMin: CGFloat? = nil,
    xMax: CGFloat? = nil,
    mode: GlyphEffectStampMode,
    dirtyRows: [Int] = [],
    stripColMin: Int? = nil,
    stripColMax: Int? = nil,
    changedCells: Int? = nil
  ) {
    self.bands = bands
    self.xMin = xMin
    self.xMax = xMax
    self.mode = mode
    self.dirtyRows = dirtyRows
    self.stripColMin = stripColMin
    self.stripColMax = stripColMax
    self.changedCells = changedCells
  }

  public var hasCellStrip: Bool {
    xMin != nil && xMax != nil
  }
}

/// Per-frame ink-bloom stamp decision for render-journal /debug dumps.
public struct GlyphEffectStampDiagnostics: Codable, Equatable, Sendable {
  public var mode: GlyphEffectStampMode
  public var dirtyRows: [Int]
  public var stripColMin: Int?
  public var stripColMax: Int?
  public var changedCells: Int?
  public var stampedRuns: Int
  public var stampedGlyphs: Int
  /// Age of the active stamp in milliseconds (`now - stamp`); 0 on a fresh
  /// stamp. Nil when `mode == .none`.
  public var stampAgeMs: Double?
  public var generation: UInt64?
  /// Filled by the AppKit layer from the Slug renderer after present.
  public var liveCount: Int?
  public var animatingRemainingMs: Double?

  public init(
    mode: GlyphEffectStampMode,
    dirtyRows: [Int] = [],
    stripColMin: Int? = nil,
    stripColMax: Int? = nil,
    changedCells: Int? = nil,
    stampedRuns: Int = 0,
    stampedGlyphs: Int = 0,
    stampAgeMs: Double? = nil,
    generation: UInt64? = nil,
    liveCount: Int? = nil,
    animatingRemainingMs: Double? = nil
  ) {
    self.mode = mode
    self.dirtyRows = dirtyRows
    self.stripColMin = stripColMin
    self.stripColMax = stripColMax
    self.changedCells = changedCells
    self.stampedRuns = stampedRuns
    self.stampedGlyphs = stampedGlyphs
    self.stampAgeMs = stampAgeMs
    self.generation = generation
    self.liveCount = liveCount
    self.animatingRemainingMs = animatingRemainingMs
  }

  public static let none = GlyphEffectStampDiagnostics(mode: .none)
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
  // itself, and the freshness region at that moment. The stamp is re-applied
  // to the same region while the freshness window
  // (`GlyphEffectTimeline.maxDecaySeconds`) is open so rebuilds keep an
  // identical effectStart; frames driven by scroll, selection, or blink leave
  // the generation unchanged and never create a new stamp. Pruned together
  // with lastSyncedGeneration.
  private struct OutputStampRecord {
    var generation: UInt64
    var stamp: Double
    var freshness: GlyphEffectFreshness
  }
  private var lastOutputStamp: [Session.ID: OutputStampRecord] = [:]
  /// Per-session per-row cell content fingerprints (viewport row → one hash
  /// per column). Diffed on each stamp so zsh/fish synchronized line redraws
  /// that mark the whole prompt row dirty only bloom cells that actually
  /// changed (approach 2).
  private var lastCellFingerprints: [Session.ID: [Int: [UInt64]]] = [:]
  /// Per-session spinner motion detector and the last observed cell metrics,
  /// used to detect eligibility changes and clear state when dimensions shift.
  private var spinnerMotionDetectors: [Session.ID: SpinnerMotionDetector] = [:]
  private var spinnerMotionCellMetrics: [Session.ID: (width: Int, height: Int)] = [:]
  private var spinnerMotionRemoteIncarnations: [Session.ID: String] = [:]
  private var spinnerMotionLastObservedGeneration: [Session.ID: UInt64] = [:]
  private var spinnerMotionLastRemoteDirty: [Session.ID: Bool] = [:]
  /// Last wave published per session, for disengagement teardown: when the
  /// detector's wave goes away, the affected cells get ordinary kind-3
  /// transitions starting from the wave-displayed color at that moment.
  private var spinnerMotionLastWaves: [Session.ID: SpinnerWaveState] = [:]
  /// Stamp decision from the most recent `stampFreshOutputTimestamps` call;
  /// copied onto `TerminalSurfaceFrame.glyphEffectStamp` for the journal.
  private var lastGlyphEffectStampDiagnostics = GlyphEffectStampDiagnostics.none

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
    lastCellFingerprints.removeAll()
    spinnerMotionDetectors.removeAll()
    spinnerMotionCellMetrics.removeAll()
    spinnerMotionRemoteIncarnations.removeAll()
    spinnerMotionLastObservedGeneration.removeAll()
    spinnerMotionLastRemoteDirty.removeAll()
    spinnerMotionLastWaves.removeAll()
  }

  /// Drops all spinner-motion detector state without disturbing the broader
  /// sync cache. Used by the `resetSpinnerMotionDiagnostics` debug action.
  public func resetSpinnerMotionDiagnostics() {
    spinnerMotionDetectors.removeAll()
    spinnerMotionCellMetrics.removeAll()
    spinnerMotionRemoteIncarnations.removeAll()
    spinnerMotionLastObservedGeneration.removeAll()
    spinnerMotionLastRemoteDirty.removeAll()
    spinnerMotionLastWaves.removeAll()
  }

  /// Total number of active spinner-motion transitions across all tracked
  /// sessions at the current clock. Excludes transitions that have already
  /// settled to their target color.
  public func spinnerMotionActiveTransitionCount() -> Int {
    let now = outputStampClock()
    return spinnerMotionDetectors.values.reduce(0) { $0 + $1.activeTransitions(at: now).count }
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

  /// Active spinner-motion metadata for `session` at the current moment,
  /// observing a new generation when one is available. Returns nil when the
  /// feature is disabled, the renderer is not Slug, or Reduce Motion is on.
  /// When the detector holds a confident traveling wave the result carries a
  /// wave publication; when a previously published wave disengages, the
  /// result carries teardown transitions from the wave-displayed colors.
  private func spinnerMotionTransitions(
    for sessionID: Session.ID,
    producer: FrameProducer,
    request: TerminalSurfaceFrameRequest,
    session: Session? = nil,
    snapshot: UnsafePointer<LabanSnapshot>? = nil,
    remoteSnapshot: LabandSnapshotResponse? = nil
  ) -> SpinnerMotionFrameMetadata? {
    let eligible =
      request.spinnerMotionSmoothingEnabled
      && request.effectiveRendererIsSlug
      && !request.reduceMotion
    guard eligible else {
      spinnerMotionDetectors.removeValue(forKey: sessionID)
      spinnerMotionCellMetrics.removeValue(forKey: sessionID)
      spinnerMotionRemoteIncarnations.removeValue(forKey: sessionID)
      spinnerMotionLastObservedGeneration.removeValue(forKey: sessionID)
      spinnerMotionLastRemoteDirty.removeValue(forKey: sessionID)
      spinnerMotionLastWaves.removeValue(forKey: sessionID)
      return nil
    }

    let metrics = (width: cellWidth, height: cellHeight)
    if spinnerMotionCellMetrics[sessionID].map({ $0 != metrics }) ?? true {
      spinnerMotionDetectors[sessionID]?.reset()
      spinnerMotionCellMetrics[sessionID] = metrics
      // A dimension change invalidates the old grid coordinates; drop the
      // last published wave without teardown.
      spinnerMotionLastWaves.removeValue(forKey: sessionID)
    }

    var detector = spinnerMotionDetectors[sessionID] ?? SpinnerMotionDetector()
    let now = outputStampClock()
    var map: [SpinnerMotionCellKey: GlyphForegroundTransition]

    if let snap = snapshot {
      let currentGen = session?.dirtyGeneration() ?? 0
      if currentGen != 0 && spinnerMotionLastObservedGeneration[sessionID] != currentGen {
        let cells = producer.spinnerCellStates(from: snap)
        let observation = SpinnerMotionObservation(
          timestamp: now,
          rows: Int(snap.pointee.rows),
          cols: Int(snap.pointee.cols),
          cells: cells,
          mouseTracking: snap.pointee.mouse_tracking != 0)
        map = detector.observe(observation)
        spinnerMotionLastObservedGeneration[sessionID] = currentGen
      } else {
        map = detector.activeTransitions(at: now)
      }
    } else if let remote = remoteSnapshot {
      if spinnerMotionRemoteIncarnations[sessionID] != remote.incarnationId {
        detector.reset()
        spinnerMotionRemoteIncarnations[sessionID] = remote.incarnationId
        // A new incarnation is a new terminal; drop the old wave without
        // teardown.
        spinnerMotionLastWaves.removeValue(forKey: sessionID)
      }
      let remoteDirty = remote.dirty
      if spinnerMotionLastRemoteDirty[sessionID] != remoteDirty {
        let cells = producer.spinnerCellStates(from: remote)
        let observation = SpinnerMotionObservation(
          timestamp: now,
          rows: remote.rows,
          cols: remote.cols,
          cells: cells,
          mouseTracking: remote.mouseTracking ?? false)
        map = detector.observe(observation)
        spinnerMotionLastRemoteDirty[sessionID] = remoteDirty
      } else {
        map = detector.activeTransitions(at: now)
      }
    } else {
      map = detector.activeTransitions(at: now)
    }

    // Wave channel (traveling-wave super-sampling). Publish while the
    // detector is confident and active; on disengagement (confidence lost,
    // observation timeout) synthesize kind-3 teardown transitions from the
    // wave-displayed color at `now` to each cell's authoritative color, so
    // the cells ease instead of popping. The horizon matches the detector's
    // own timeout, so the present link parks when generations stop.
    let horizon = min(2 * (detector.diagnostics.cadenceSeconds ?? 0.15), 0.8)
    let currentWave = detector.lastWave
    let waveLive = currentWave != nil && detector.isActive(at: now)
    var wave: SpinnerWavePublication?
    if let current = currentWave, waveLive {
      wave = SpinnerWavePublication(wave: current, durationSeconds: horizon)
      spinnerMotionLastWaves[sessionID] = current
    } else if let previous = spinnerMotionLastWaves.removeValue(forKey: sessionID) {
      for offset in previous.colors.indices {
        let col = previous.minCol + offset
        let key = SpinnerMotionCellKey(row: previous.row, col: col)
        guard map[key] == nil else { continue }
        map[key] = GlyphForegroundTransition(
          startLinearRGBA: previous.sample(col: col, at: now),
          startTimestampSeconds: now,
          durationSeconds: horizon)
      }
    }

    spinnerMotionDetectors[sessionID] = detector
    return SpinnerMotionFrameMetadata(
      transitions: map.isEmpty ? nil : map,
      wave: wave)
  }

  /// Aggregate traveling-wave diagnostics across tracked sessions for the
  /// debug endpoint: the first session with an active wave wins. A wave is
  /// reported only while the detector is live (`diagnostics.waveActive` is
  /// refreshed inside `observe` and would otherwise stay stale after an
  /// observation timeout).
  public func spinnerMotionWaveDiagnostics() -> (
    active: Bool, velocityCellsPerSecond: Double?, confidence: Double?
  ) {
    let now = outputStampClock()
    for detector in spinnerMotionDetectors.values {
      guard let wave = detector.lastWave, detector.isActive(at: now) else { continue }
      return (true, wave.velocityCellsPerSecond, wave.confidence)
    }
    return (false, nil, nil)
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

    let spinnerMotion =
      canSkipTerminalCommands
      ? nil
      : spinnerMotionTransitions(
        for: session.id,
        producer: producer,
        request: request,
        session: session,
        snapshot: UnsafePointer(snap))
    if !canSkipTerminalCommands {
      commands += producer.commands(
        from: UnsafePointer(snap),
        selection: request.selection,
        findState: findState,
        viewportRowOffset: viewportOffset,
        cursorBlinkVisible: request.cursorBlinkVisible,
        preedit: request.preedit,
        preeditCaretCells: request.preeditCaretCells,
        resolvedCursor: preResolvedCursor,
        foregroundTransitions: spinnerMotion?.transitions,
        foregroundWave: spinnerMotion?.wave)
    }
    commands = stampFreshOutputTimestamps(
      commands,
      session: session,
      snapshot: UnsafePointer(snap),
      originX: sidebarWidth + request.insets.left,
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
      diagnostics: diagnostics,
      glyphEffectStamp: lastGlyphEffectStampDiagnostics,
      spinnerMotionDiagnostics: spinnerMotionDetectors[session.id]?.diagnostics
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
    let spinnerMotion = spinnerMotionTransitions(
      for: sessionId,
      producer: producer,
      request: request,
      remoteSnapshot: snapshot)
    commands += producer.commands(
      from: snapshot,
      selection: request.selection,
      cursorBlinkVisible: request.cursorBlinkVisible,
      preedit: request.preedit,
      preeditCaretCells: request.preeditCaretCells,
      userCursorStyle: request.userCursorStyle,
      foregroundTransitions: spinnerMotion?.transitions,
      foregroundWave: spinnerMotion?.wave
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
      diagnostics: diagnostics,
      spinnerMotionDiagnostics: spinnerMotionDetectors[sessionId]?.diagnostics
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

  /// Dirty row indices from the snapshot bitmap; empty when unavailable.
  public static func dirtyRowIndices(
    snapshot snap: UnsafePointer<LabanSnapshot>
  ) -> [Int] {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    guard rows > 0, snapshot.dirty_row_count == rows, let dirty = snapshot.dirty_rows
    else {
      return []
    }
    var result: [Int] = []
    for row in 0..<rows where dirty[row] != 0 {
      result.append(row)
    }
    return result
  }

  /// Per-column content hashes for `rows` in the snapshot.
  public static func cellFingerprints(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    rows rowIndices: [Int]
  ) -> [Int: [UInt64]] {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cols > 0, let cells = snapshot.cells,
      snapshot.cell_count >= rows * cols
    else {
      return [:]
    }
    var result: [Int: [UInt64]] = [:]
    result.reserveCapacity(rowIndices.count)
    for row in rowIndices where row >= 0 && row < rows {
      var hashes = [UInt64](repeating: 0, count: cols)
      let base = row * cols
      for col in 0..<cols {
        hashes[col] = cellContentFingerprint(
          cell: cells[base + col],
          storage: snapshot.utf8_storage)
      }
      result[row] = hashes
    }
    return result
  }

  /// Stable hash of one grid cell's **glyph text** for bloom freshness.
  ///
  /// Style (fg/bg/flags/intensity) is intentionally omitted: TUIs often pulse
  /// spinner colors without changing the character, and blooming those made
  /// Claude Code look flickery. Wide/spacer identity stays so layout shifts
  /// still count.
  public static func cellContentFingerprint(
    cell: LabanCell,
    storage: UnsafePointer<CChar>?
  ) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(cell.wide)
    let length = Int(cell.utf8_length)
    hasher.combine(length)
    if length > 0, let storage {
      let start = Int(cell.utf8_offset)
      for offset in 0..<length {
        hasher.combine(UInt8(bitPattern: storage[start + offset]))
      }
    }
    return UInt64(bitPattern: Int64(hasher.finalize()))
  }

  /// Columns whose fingerprints differ from `previous` on `row`.
  public static func changedColumns(
    row: Int,
    current: [UInt64],
    previous: [Int: [UInt64]]
  ) -> [Int] {
    guard let prior = previous[row] else {
      // No baseline for this row yet — treat nothing as changed here; the
      // caller seeds fingerprints and uses a cursor-cell fallback instead of
      // blooming the entire first-seen row.
      return []
    }
    let cols = min(current.count, prior.count)
    var changed: [Int] = []
    for col in 0..<cols where current[col] != prior[col] {
      changed.append(col)
    }
    if current.count > prior.count {
      for col in prior.count..<current.count where current[col] != 0 {
        changed.append(col)
      }
    }
    return changed
  }

  /// Freshness from a cell-content diff on dirty rows (approach 2).
  ///
  /// Fingerprints are per-cell UTF-8 bytes + style (fg/bg/flags/…), not merely
  /// "row dirty". Diff result:
  /// - One dirty row with a small changed-column span → X strip (`cellDiff`).
  /// - Multi-row changes or a near-full-row rewrite → `wholeRun` (stamp path
  ///   suppresses bloom; journal still records the decision).
  /// - No baseline yet → `nil` so the caller can fall back to cursor-cell.
  public static func freshnessFromCellDiff(
    dirtyRows: [Int],
    currentFingerprints: [Int: [UInt64]],
    previousFingerprints: [Int: [UInt64]],
    cols: Int,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    originX: CGFloat,
    originY: CGFloat,
    totalRows: Int
  ) -> GlyphEffectFreshness? {
    guard !dirtyRows.isEmpty, cellWidth > 0, cellHeight > 0, totalRows > 0, cols > 0
    else {
      return nil
    }
    if previousFingerprints.isEmpty {
      return nil
    }

    var rowChanges: [(row: Int, columns: [Int])] = []
    for row in dirtyRows {
      guard let current = currentFingerprints[row] else { continue }
      let columns = changedColumns(row: row, current: current, previous: previousFingerprints)
      if !columns.isEmpty {
        rowChanges.append((row, columns))
      }
    }
    guard !rowChanges.isEmpty else { return nil }

    // Multi-row content change → whole-run bloom of those rows (app dump).
    if rowChanges.count > 1 {
      let bands = rowChanges.map { change -> DirtyYRange in
        let yBottom = originY + CGFloat(totalRows - 1 - change.row) * cellHeight
        return DirtyYRange(y: yBottom, height: cellHeight)
      }
      let changed = rowChanges.reduce(0) { $0 + $1.columns.count }
      return GlyphEffectFreshness(
        bands: bands,
        mode: .wholeRun,
        dirtyRows: rowChanges.map(\.row),
        changedCells: changed)
    }

    let change = rowChanges[0]
    let minCol = change.columns.first!
    let maxCol = change.columns.last!
    let span = maxCol - minCol + 1
    let yBottom = originY + CGFloat(totalRows - 1 - change.row) * cellHeight
    let band = DirtyYRange(y: yBottom, height: cellHeight)
    // Near-full-row rewrite (clear + redraw, or long dump on one line).
    if span >= max(8, cols / 2) || change.columns.count >= max(8, cols / 2) {
      return GlyphEffectFreshness(
        bands: [band],
        mode: .wholeRun,
        dirtyRows: [change.row],
        changedCells: change.columns.count)
    }
    let xMin = originX + CGFloat(minCol) * cellWidth
    let xMax = originX + CGFloat(maxCol + 1) * cellWidth
    return GlyphEffectFreshness(
      bands: [band],
      xMin: xMin,
      xMax: xMax,
      mode: .cellDiff,
      dirtyRows: [change.row],
      stripColMin: minCol,
      stripColMax: maxCol,
      changedCells: change.columns.count)
  }

  /// Freshness region for the glyph-effect stamp channel.
  ///
  /// Prefers cell-diff against `previousFingerprints` so synchronized prompt
  /// redraws that dirty a whole row only bloom changed cells. Falls back to
  /// cursor-cell (coarse / no baseline) or whole-run multi-row bands.
  public static func freshness(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    originX: CGFloat,
    originY: CGFloat,
    previousFingerprints: [Int: [UInt64]] = [:]
  ) -> GlyphEffectFreshness? {
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }
    let dirtyRows = dirtyRowIndices(snapshot: snap)
    guard !dirtyRows.isEmpty else { return nil }

    let current = cellFingerprints(snapshot: snap, rows: dirtyRows)
    if let diffed = freshnessFromCellDiff(
      dirtyRows: dirtyRows,
      currentFingerprints: current,
      previousFingerprints: previousFingerprints,
      cols: cols,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: originX,
      originY: originY,
      totalRows: rows)
    {
      return diffed
    }

    // No baseline or no cell content change: coarse all-bits → cursor cell;
    // precise multi-row without a diff → whole-run; single-row without a
    // diff → cursor cell when the cursor sits on that row.
    if dirtyRows.count >= rows {
      return cursorCellFreshness(
        cursorRow: Int(snapshot.cursor_row),
        cursorCol: Int(snapshot.cursor_col),
        rows: rows,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        originX: originX,
        originY: originY)
    }
    if dirtyRows.count == 1,
      dirtyRows[0] == Int(snapshot.cursor_row),
      snapshot.cursor_col > 0
    {
      return cursorCellFreshness(
        cursorRow: Int(snapshot.cursor_row),
        cursorCol: Int(snapshot.cursor_col),
        rows: rows,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        originX: originX,
        originY: originY)
    }
    var ranges: [DirtyYRange] = []
    var row = 0
    while row < dirtyRows.count {
      let start = dirtyRows[row]
      var end = start
      while row + 1 < dirtyRows.count, dirtyRows[row + 1] == end + 1 {
        row += 1
        end = dirtyRows[row]
      }
      let yBottom = originY + CGFloat(rows - 1 - end) * cellHeight
      let height = CGFloat(end - start + 1) * cellHeight
      ranges.append(DirtyYRange(y: yBottom, height: height))
      row += 1
    }
    return ranges.isEmpty
      ? nil
      : GlyphEffectFreshness(bands: ranges, mode: .wholeRun, dirtyRows: dirtyRows)
  }

  /// Y-only view of `freshness` for callers that do not need the X strip.
  public static func freshnessBands(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    cellHeight: CGFloat,
    originY: CGFloat,
    cellWidth: CGFloat = 1,
    originX: CGFloat = 0,
    previousFingerprints: [Int: [UInt64]] = [:]
  ) -> [DirtyYRange]? {
    freshness(
      snapshot: snap,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: originX,
      originY: originY,
      previousFingerprints: previousFingerprints)?.bands
  }

  /// Fallback freshness at the cursor when cell-diff has no baseline.
  ///
  /// - `cursor_col > 0`: the single cell before the cursor (insert echo).
  /// - `cursor_col == 0` and `cursor_row > 0`: the previous row as a whole-run
  ///   band (bulk line that ended in CR/LF).
  public static func cursorCellFreshness(
    cursorRow: Int,
    cursorCol: Int,
    rows: Int,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    originX: CGFloat,
    originY: CGFloat
  ) -> GlyphEffectFreshness? {
    guard rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }
    if cursorCol > 0 {
      let row = min(max(cursorRow, 0), rows - 1)
      let col = cursorCol - 1
      let yBottom = originY + CGFloat(rows - 1 - row) * cellHeight
      let xMin = originX + CGFloat(col) * cellWidth
      return GlyphEffectFreshness(
        bands: [DirtyYRange(y: yBottom, height: cellHeight)],
        xMin: xMin,
        xMax: xMin + cellWidth,
        mode: .cursorCell,
        dirtyRows: [row],
        stripColMin: col,
        stripColMax: col,
        changedCells: 1)
    }
    guard cursorRow > 0 else { return nil }
    let row = min(cursorRow - 1, rows - 1)
    let yBottom = originY + CGFloat(rows - 1 - row) * cellHeight
    return GlyphEffectFreshness(
      bands: [DirtyYRange(y: yBottom, height: cellHeight)],
      mode: .cursorCell,
      dirtyRows: [row])
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
  /// since the last frame built here, PTY output landed — stamp fresh
  /// terminal glyph content with the monotonic now. Freshness prefers a
  /// cell-content diff so synchronized prompt redraws that dirty a whole
  /// row only bloom the cells that actually changed; coalesced runs are
  /// split on an X strip. Multi-row dumps still whole-run stamp.
  ///
  /// Cell fingerprints are refreshed on every call so idle frames seed a
  /// baseline before the next keystroke. While the freshness window stays
  /// open the same stamp is re-applied to the same region; scroll /
  /// selection / blink frames leave the generation unchanged and keep nil.
  private func stampFreshOutputTimestamps(
    _ commands: [FrameCommand],
    session: Session,
    snapshot: UnsafePointer<LabanSnapshot>,
    originX: CGFloat,
    originY: CGFloat
  ) -> [FrameCommand] {
    let generation = session.dirtyGeneration()
    let dirtyRows = Self.dirtyRowIndices(snapshot: snapshot)
    let previousFingerprints = lastCellFingerprints[session.id] ?? [:]
    // Seed/refresh fingerprints so the next generation can cell-diff. Dirty
    // rows always refresh; clean frames still refresh the cursor row so a
    // settled prompt is the baseline before the next keystroke.
    let rowsToFingerprint: [Int] = {
      let totalRows = Int(snapshot.pointee.rows)
      guard totalRows > 0 else { return [] }
      if dirtyRows.isEmpty {
        let cursorRow = Int(snapshot.pointee.cursor_row)
        return (0..<totalRows).contains(cursorRow) ? [cursorRow] : []
      }
      if dirtyRows.count >= totalRows {
        return Array(0..<totalRows)
      }
      return dirtyRows
    }()
    var mergedFingerprints = previousFingerprints
    if !rowsToFingerprint.isEmpty {
      for (row, hashes) in Self.cellFingerprints(snapshot: snapshot, rows: rowsToFingerprint) {
        mergedFingerprints[row] = hashes
      }
    }
    // Write after freshness reads `previousFingerprints`.
    defer { lastCellFingerprints[session.id] = mergedFingerprints }

    func finishNone(mode: GlyphEffectStampMode = .none) -> [FrameCommand] {
      lastGlyphEffectStampDiagnostics = GlyphEffectStampDiagnostics(
        mode: mode,
        dirtyRows: dirtyRows,
        generation: generation == 0 ? nil : generation)
      return commands
    }

    // Fullscreen TUIs (Claude Code, btop, …) enable mouse tracking. Their
    // spinners rewrite glyphs/colors every tick; blooming that is pure flicker.
    if snapshot.pointee.mouse_tracking != 0 {
      lastOutputStamp.removeValue(forKey: session.id)
      return finishNone(mode: .suppressedTUI)
    }

    guard generation != 0 else { return finishNone() }
    let now = outputStampClock()
    let stamp: Double
    let freshness: GlyphEffectFreshness
    let modeOverride: GlyphEffectStampMode?
    if let record = lastOutputStamp[session.id], record.generation == generation {
      guard now - record.stamp < GlyphEffectTimeline.maxDecaySeconds
      else { return finishNone() }
      stamp = record.stamp
      freshness = record.freshness
      modeOverride = .reapply
    } else {
      guard
        let region = Self.freshness(
          snapshot: snapshot,
          cellWidth: CGFloat(cellWidth),
          cellHeight: CGFloat(cellHeight),
          originX: originX,
          originY: originY,
          previousFingerprints: previousFingerprints),
        !region.bands.isEmpty
      else { return finishNone() }
      // Bulk / multi-row / near-full-row rewrites: content diff still ran
      // (changedCells is real glyph+style churn), but blooming whole runs
      // makes TUIs like btop flicker — suppress the stamp entirely.
      if region.mode == .wholeRun {
        lastGlyphEffectStampDiagnostics = GlyphEffectStampDiagnostics(
          mode: .wholeRun,
          dirtyRows: region.dirtyRows.isEmpty ? dirtyRows : region.dirtyRows,
          changedCells: region.changedCells,
          stampedRuns: 0,
          stampedGlyphs: 0,
          generation: generation)
        return commands
      }
      stamp = now
      freshness = region
      modeOverride = nil
      lastOutputStamp[session.id] = OutputStampRecord(
        generation: generation, stamp: stamp, freshness: freshness)
    }
    let stamped: [FrameCommand]
    if let xMin = freshness.xMin, let xMax = freshness.xMax, freshness.hasCellStrip {
      stamped = Self.applyCellStripStamp(
        commands,
        bands: freshness.bands,
        xMin: xMin,
        xMax: xMax,
        cellWidth: CGFloat(cellWidth),
        cellHeight: CGFloat(cellHeight),
        gridOriginX: originX,
        stamp: stamp)
    } else {
      // Non-strip freshness that isn't `wholeRun` (e.g. cursorCell after CR
      // with a previous-row band): still stamp those runs.
      stamped = Self.applyWholeRunStamp(
        commands,
        bands: freshness.bands,
        cellHeight: CGFloat(cellHeight),
        stamp: stamp)
    }
    let counts = Self.stampedGlyphCounts(stamped)
    lastGlyphEffectStampDiagnostics = GlyphEffectStampDiagnostics(
      mode: modeOverride ?? freshness.mode,
      dirtyRows: freshness.dirtyRows.isEmpty ? dirtyRows : freshness.dirtyRows,
      stripColMin: freshness.stripColMin,
      stripColMax: freshness.stripColMax,
      changedCells: freshness.changedCells,
      stampedRuns: counts.runs,
      stampedGlyphs: counts.glyphs,
      stampAgeMs: max(0, (now - stamp) * 1000),
      generation: generation)
    return stamped
  }

  /// Count terminal glyph runs (and approximate glyph/cluster count) that
  /// carry a non-nil `outputTimestampSeconds`.
  static func stampedGlyphCounts(
    _ commands: [FrameCommand]
  ) -> (runs: Int, glyphs: Int) {
    var runs = 0
    var glyphs = 0
    for command in commands {
      guard
        case .glyphRun(
          _, let text, _, _, _, .terminal, _, _, _, let displayCellCount, let stamp, _, _) =
          command,
        stamp != nil
      else { continue }
      runs += 1
      glyphs += displayCellCount ?? max(1, text.count)
    }
    return (runs, glyphs)
  }

  /// Stamp every terminal glyph run whose exact cell Y extent intersects
  /// `bands` (precise dirty / bulk output).
  static func applyWholeRunStamp(
    _ commands: [FrameCommand],
    bands: [DirtyYRange],
    cellHeight: CGFloat,
    stamp: Double
  ) -> [FrameCommand] {
    var stamped = commands
    for index in stamped.indices {
      guard
        case .glyphRun(
          let origin, let text, let foreground, let background, let attributes, let source,
          let underlineStyle, let underlineColor, let hyperlink, let displayCellCount, _,
          let foregroundTransition, let foregroundWave
        ) = stamped[index],
        source == .terminal
      else { continue }
      let minY = origin.y
      let maxY = origin.y + cellHeight
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
        outputTimestampSeconds: stamp,
        foregroundTransition: foregroundTransition,
        foregroundWave: foregroundWave)
    }
    return stamped
  }

  /// Split terminal glyph runs so only the character cells overlapping
  /// `[xMin, xMax)` on a fresh Y band receive `stamp`.
  static func applyCellStripStamp(
    _ commands: [FrameCommand],
    bands: [DirtyYRange],
    xMin: CGFloat,
    xMax: CGFloat,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    gridOriginX: CGFloat,
    stamp: Double
  ) -> [FrameCommand] {
    guard cellWidth > 0, xMin < xMax else { return commands }
    var result: [FrameCommand] = []
    result.reserveCapacity(commands.count + 2)
    for command in commands {
      guard
        case .glyphRun(
          let origin, let text, let foreground, let background, let attributes, let source,
          let underlineStyle, let underlineColor, let hyperlink, let displayCellCount, _,
          let foregroundTransition, let foregroundWave
        ) = command,
        source == .terminal
      else {
        result.append(command)
        continue
      }
      let minY = origin.y
      let maxY = origin.y + cellHeight
      let yFresh = bands.contains { $0.y < maxY && minY < $0.y + $0.height }
      guard yFresh, !text.isEmpty else {
        result.append(command)
        continue
      }

      let pieces = splitGlyphRunText(
        text: text,
        origin: origin,
        cellWidth: cellWidth,
        gridOriginX: gridOriginX,
        freshXMin: xMin,
        freshXMax: xMax)
      if pieces.count == 1, pieces[0].stamped == false {
        result.append(command)
        continue
      }
      for piece in pieces {
        guard !piece.text.isEmpty else { continue }
        result.append(
          .glyphRun(
            origin: piece.origin,
            text: piece.text,
            foreground: foreground,
            background: background,
            attributes: attributes,
            source: source,
            underlineStyle: underlineStyle,
            underlineColor: underlineColor,
            hyperlink: hyperlink,
            displayCellCount: displayCellCount == nil
              ? nil : TerminalDisplayWidth.cells(of: piece.text),
            outputTimestampSeconds: piece.stamped ? stamp : nil,
            foregroundTransition: foregroundTransition,
            foregroundWave: foregroundWave))
      }
    }
    return result
  }

  /// Walk a coalesced run by `Character`, marking cells that overlap the
  /// fresh X strip. Adjacent same-stamp pieces are coalesced.
  static func splitGlyphRunText(
    text: String,
    origin: CGPoint,
    cellWidth: CGFloat,
    gridOriginX: CGFloat,
    freshXMin: CGFloat,
    freshXMax: CGFloat
  ) -> [(text: String, origin: CGPoint, stamped: Bool)] {
    var pieces: [(text: String, origin: CGPoint, stamped: Bool)] = []
    var col = Int(((origin.x - gridOriginX) / cellWidth).rounded())
    var pieceStart = text.startIndex
    var pieceOriginX = origin.x
    var pieceStamped: Bool?
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      let cluster = text[index..<next]
      let width = max(1, TerminalDisplayWidth.cells(of: String(cluster)))
      let cellMinX = gridOriginX + CGFloat(col) * cellWidth
      let cellMaxX = cellMinX + CGFloat(width) * cellWidth
      let stamped = cellMinX < freshXMax && freshXMin < cellMaxX
      if let current = pieceStamped, current != stamped {
        pieces.append(
          (
            text: String(text[pieceStart..<index]),
            origin: CGPoint(x: pieceOriginX, y: origin.y),
            stamped: current
          ))
        pieceStart = index
        pieceOriginX = cellMinX
        pieceStamped = stamped
      } else if pieceStamped == nil {
        pieceStamped = stamped
        pieceOriginX = cellMinX
        pieceStart = index
      }
      col += width
      index = next
    }
    if let current = pieceStamped, pieceStart < text.endIndex {
      pieces.append(
        (
          text: String(text[pieceStart..<text.endIndex]),
          origin: CGPoint(x: pieceOriginX, y: origin.y),
          stamped: current
        ))
    }
    return pieces
  }

  private static func elapsedMs(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
  }
}
