import AppKit
import CoreGraphics
import CoreText
import CoreVideo
import LabanCore
import LabanDebug
import LabanRenderer
import LabanTerminalCore
import Metal
import Quartz
import QuartzCore
import UserNotifications

struct GPUCellPayloadFailureNotificationPolicy {
  struct Request: Equatable {
    var identifier: String
    var title: String
    var subtitle: String?
    var body: String
    var playsSound: Bool
  }

  static let identifier = "gpu-cell-payload-failure"
  static let notificationsDisabledDefaultsKey = "LabanDisableGPUFailureNotifications"
  static let defaultRateLimit: TimeInterval = 5 * 60

  /// Monotonic "now" in nanoseconds. Wall-clock is deliberately avoided: a
  /// backward system-clock jump (NTP/manual/DST) must never suppress a real
  /// failure notification, so the throttle reads an uptime-based clock instead.
  static func monotonicNowNanoseconds() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private let defaults: UserDefaults
  private let rateLimit: TimeInterval
  private let monotonicNow: () -> UInt64

  /// Throttle anchor, in monotonic nanoseconds. In-memory and per-process: it
  /// resets every launch, so the first failure after a relaunch is always
  /// surfaced even if a prior session posted moments earlier.
  private var lastNotificationUptimeNanoseconds: UInt64?

  init(
    defaults: UserDefaults = .standard,
    rateLimit: TimeInterval = Self.defaultRateLimit,
    monotonicNow: @escaping () -> UInt64 = GPUCellPayloadFailureNotificationPolicy
      .monotonicNowNanoseconds
  ) {
    self.defaults = defaults
    self.rateLimit = rateLimit
    self.monotonicNow = monotonicNow
  }

  mutating func notificationRequest(
    for failure: MetalRenderer.GPUCellPayloadBuildFailure,
    dumpPath: String?
  ) -> Request? {
    guard !defaults.bool(forKey: Self.notificationsDisabledDefaultsKey) else {
      return nil
    }
    let now = monotonicNow()
    if let last = lastNotificationUptimeNanoseconds,
      rateLimit > 0,
      now >= last,
      Double(now - last) / 1_000_000_000 < rateLimit
    {
      return nil
    }

    lastNotificationUptimeNanoseconds = now
    return Request(
      identifier: Self.identifier,
      title: "Laban GPU renderer fallback",
      subtitle: dumpPath == nil ? nil : "Render journal dumped",
      body:
        "Payload build failed: \(failure.reason) at row \(failure.row), col \(failure.col).",
      playsSound: true)
  }
}

final class TerminalBitmapView: NSView, NSTextInputClient, NSMenuItemValidation,
  QLPreviewPanelDataSource, QLPreviewPanelDelegate
{
  struct AccessibilityDisplayOptions: Equatable {
    var reduceMotion: Bool
    var increaseContrast: Bool
    var differentiateWithoutColor: Bool
    var reduceTransparency: Bool
  }

  /// Reserved strip at the top of the contentView that sits behind the
  /// transparent full-size titlebar. Picked to clear the standard window
  /// traffic-light cluster (~22 pt visually + breathing room).
  static let titlebarReservedHeight: CGFloat = 28
  static let contentInsets = NSEdgeInsets(
    top: 8 + titlebarReservedHeight, left: 14, bottom: 8, right: 8)
  static var accessibilityDisplayOptionsProviderForTests: (() -> AccessibilityDisplayOptions)?

  private static func currentAccessibilityDisplayOptions() -> AccessibilityDisplayOptions {
    if let provider = accessibilityDisplayOptionsProviderForTests {
      return provider()
    }
    let workspace = NSWorkspace.shared
    return AccessibilityDisplayOptions(
      reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
      increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
      differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
      reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
  }

  private let model: AppModel
  private let urlOpener: any ExternalURLOpening
  private(set) var fontAtlas: FontAtlas
  /// Either a SoftwareBackend (legacy path: blits a CGImage in `draw(_:)`)
  /// or a MetalRenderer (self-presents into its own CAMetalLayer). The menu
  /// can swap this live; LABAN_RENDERER=software/cpu still forces the initial
  /// backend for debug recovery.
  private var backend: RendererBackend
  /// True when `backend` self-presents — TerminalBitmapView skips its own
  /// draw() blit and lets the layer composite directly.
  private var backendSelfPresents: Bool
  private(set) var cellWidth: Int
  private(set) var cellHeight: Int
  private let sidebarWidth: CGFloat = SidebarLayout.defaultWidth
  private let surfaceController: TerminalSurfaceController
  private let sessionCoordinator: AppSessionCoordinator?
  // Vsync-aligned tick.
  // - macOS 14+: CADisplayLink with a `preferredFrameRateRange` so a
  //   ProMotion panel can drop to a low rate when the terminal is idle and
  //   ramp up under load. Real VRR.
  // - macOS 13: CVDisplayLink as fallback. Vsync-aligned, no VRR throttle —
  //   always fires at the panel's max refresh.
  private var caDisplayLink: AnyObject?
  private var cvDisplayLink: CVDisplayLink?

  // Last known terminal grid size (updated each frame). Seeded from the model
  // so hit-testing is correct even before the first settled render.
  private var lastRows: Int
  private var testPasteboardEnabled = false
  private var testPasteboardString: String?
  var pasteboardStringForTesting: String? {
    get { testPasteboardString }
    set {
      testPasteboardEnabled = true
      testPasteboardString = newValue
    }
  }

  private var selectionAnchor: TerminalSelectionPoint?
  private var selectionFocus: TerminalSelectionPoint?

  /// Grain of the active selection. Set on mouseDown by the click count;
  /// drives whether mouseDragged extends by character (`.char`), by word
  /// boundary (`.word`), or by full line (`.line`). Without this, even
  /// 1-pixel jitter during a double-click would fire mouseDragged and
  /// collapse the just-selected word back to a single character.
  private var selectionMode: TerminalSelectionMode = .char
  /// The cell the user originally clicked when starting a word- or
  /// line-grain selection. Drag extension recomputes the selection union
  /// from this origin to the current drag cell, in the chosen grain —
  /// without remembering the origin we'd lose it the moment a drag fires.
  private var selectionOriginCell: TerminalSelectionPoint?
  private struct PendingHyperlinkClick {
    var uri: String
    var downPoint: NSPoint
  }
  private var pendingHyperlinkClick: PendingHyperlinkClick?
  private static let hyperlinkClickDragTolerance: CGFloat = 3
  /// True while the current mouseDown→mouseUp pair was consumed by
  /// window chrome (sidebar tab actions or the reserved titlebar strip).
  /// Without this, the paired mouseUp would treat the just-restored or
  /// pre-existing selection as an in-progress drag and extend its focus
  /// to the chrome click point.
  private var mouseDownConsumedByChrome = false
  /// True while the current mouse gesture is being forced into local
  /// terminal selection even though the terminal application has mouse
  /// tracking enabled. This is the standard terminal Shift override.
  private var localSelectionMouseGestureActive = false
  /// Per-tab saved selection state. Without this, switching tabs leaves
  /// the previous tab's selection rectangle painted across the new tab's
  /// grid (the renderer reads view-level state, not session-level). On
  /// tab switch we save the outgoing tab's pair into this dict and
  /// restore the incoming tab's pair from it.
  private var selectionsByTab:
    [Tab.ID: (anchor: TerminalSelectionPoint, focus: TerminalSelectionPoint?)] = [:]
  private var activeSelectionTabId: Tab.ID?
  private var trackedMouseButton: MouseButton = .none
  /// Last terminal cell a no-button hover motion was forwarded for, so a
  /// mouse-tracking app sees one report per cell entered instead of one per
  /// pixel of pointer travel.
  private var lastHoverMotionCell: (tab: Tab.ID, col: Int, row: Int)?
  /// Most recent encoded hover report, observable by tests (fixture sessions
  /// have no PTY whose input side a test could read).
  private var lastForwardedHoverReport: [UInt8]?
  var lastForwardedHoverReportForTests: [UInt8]? {
    get { lastForwardedHoverReport }
    set { lastForwardedHoverReport = newValue }
  }

  /// Active drag-edge auto-scroll. `direction` matches
  /// `Session.scrollViewport(deltaRows:)`: negative rows scroll back toward
  /// older content, positive rows scroll forward toward the active bottom.
  /// the timer fires every ~50 ms and scrolls one row in that direction
  /// until the drag returns to inside the viewport or mouseUp fires.
  private var dragAutoscrollDirection: Int = 0
  private var dragAutoscrollTimer: Timer?
  private var lastDragPoint: NSPoint?

  /// Tab currently under the mouse cursor in the sidebar. Drives hover-
  /// only affordances (close glyph). Updated from mouseMoved /
  /// mouseExited; nil when the cursor isn't inside any sidebar tab row.
  private var hoveredSidebarTabId: Tab.ID?
  private var sidebarScrollResidualPx: CGFloat = 0
  private var targetSidebarScrollOffset: Double = 0
  private var displayedSidebarScrollOffset: Double = 0
  private var sidebarScrollVelocityPointsPerSec: Double = 0
  private var lastSidebarScrollTickAt: ContinuousClock.Instant?
  private var sidebarScrollAnimating: Bool = false
  private static let sidebarScrollOmega: Double = 55.0

  /// In-progress sidebar drag-reorder. Armed in `mouseDown` when the
  /// hit lands on `.selectTab`; promoted to `activated = true` once the
  /// cursor moves past `sidebarDragActivationDistance` from `origin`.
  /// While activated, `currentSlot` carries the drop target so the
  /// renderer can paint a placeholder bar and `mouseUp` can commit the
  /// reorder. Cleared in `mouseUp` and on tab teardown.
  private struct SidebarDragState {
    let tabId: Tab.ID
    let origin: NSPoint
    var activated: Bool
    var currentSlot: Int?
  }
  private var sidebarDragState: SidebarDragState?
  private static let sidebarDragActivationDistance: CGFloat = 4
  private var hoverCursorStyle: TerminalHoverCursorStyle?
  private var findChip: TerminalFindChipView?
  private var lastFindNeedle: String = ""
  private var pendingFindSearchWorkItem: DispatchWorkItem?
  private var pendingFindSearchGeneration: UInt64 = 0
  private var pendingFindSearchSessionID: Session.ID?
  private var pendingFindSearchNeedle: String = ""
  private static let findTypingSearchDelay: TimeInterval = 0.25

  // Damage-driven render budget state
  private var renderInvalidated = true {
    didSet {
      if !renderInvalidated || !settingRenderInvalidatedFromGPUBackpressure {
        renderInvalidatedFromGPUBackpressureOnly = false
      }
    }
  }
  private var renderInvalidatedFromGPUBackpressureOnly = false
  private var settingRenderInvalidatedFromGPUBackpressure = false
  private let gpuFreezeAutoDumpEnabled: Bool
  private let renderJournalEnabled: Bool
  private lazy var renderJournal = RenderJournal()
  private var gpuFreezeDetector = GPURenderFreezeDetector()
  private var gpuFrameCompletionCount = 0
  /// Set when a GPU-cell payload render fails after terminal commands were
  /// intentionally skipped. The next retry builds command content once so the
  /// renderer has a safe fallback instead of clearing to a terminal background.
  private var gpuCellCommandFallbackPending = false
  private var lastAutoDumpedGPUCellPayloadFailureSignature: String?
  private var lastGPUCellPayloadFailureAutoDumpAt: Date?
  private var gpuCellPayloadFailureNotificationPolicy =
    GPUCellPayloadFailureNotificationPolicy()
  private var themeChangeObserver: NSObjectProtocol?
  private var reduceMotionObserver: NSObjectProtocol?
  private var cursorSettingsObserver: NSObjectProtocol?
  private var emojiRenderingObserver: NSObjectProtocol?
  private var vectorSubpixelLayoutObserver: NSObjectProtocol?
  private var vectorTextWeightObserver: NSObjectProtocol?
  private var vectorSmoothScrollObserver: NSObjectProtocol?
  private var screenParametersObserver: NSObjectProtocol?
  private var fontChangeObserver: NSObjectProtocol?
  /// Persisted font name as of the last time this view reconciled with
  /// UserDefaults. The Settings live-apply path compares against it: an
  /// unchanged name means only the size moved (safe to apply live); a changed
  /// name means a family change, which still requires a restart.
  private var lastObservedPersistedFontName: String? =
    UserDefaults.standard.string(forKey: FontAtlas.userFontKey)
  /// Cached system accessibility display settings, refreshed via NSWorkspace
  /// notifications. Reduce Motion freezes the sidebar needsAction pulse; the
  /// additional flags are exposed through debug state so low-vision display
  /// changes are observable while renderer-specific adaptations remain bounded.
  private var accessibilityDisplayOptions =
    TerminalBitmapView.currentAccessibilityDisplayOptions()
  private var reduceMotion: Bool { accessibilityDisplayOptions.reduceMotion }
  var accessibilityDisplayOptionsForTesting: AccessibilityDisplayOptions {
    accessibilityDisplayOptions
  }
  private var terminalOutputActiveUntil = Date.distantPast
  /// While a precise scroll stream is flowing, the display link paces
  /// rendering at the panel rate instead of a synchronous render per wheel
  /// event: per-event full-damage renders saturate the main loop at larger
  /// window sizes, which coalesces a 120 Hz event stream (and the frames
  /// with it) down to ~60 fps. Stamped forward by every precise event;
  /// expiry parks the link via the normal policy reconcile once the settle
  /// finishes.
  private var preciseScrollStreamActiveUntil = Date.distantPast
  private static let preciseScrollStreamLinkHoldSeconds: TimeInterval = 0.25
  private var lastDisplayLinkTickAt: Date?
  private var lastDisplayLinkTickIntervalMs: Double?
  private var lastRenderedActiveTabId: Tab.ID?
  private var remoteSnapshotRenderTracker = RemoteSnapshotRenderTracker()
  private var remoteMouseEncodingByTab: [Tab.ID: (trackingMode: Int, format: Int)] = [:]
  private var scrollResidualPx: CGFloat = 0

  /// Last cols value applied to libghostty. Used to detect when a reflow
  /// invalidates the selection's grid coordinates so we can drop it.
  private var lastAppliedCols: Int = 0
  private var lastAppliedRows: Int = 0

  // Smooth-scroll animation state. Wheel input adds to `targetScrollRows`
  // (cumulative target). A critically-damped PD controller advances
  // `displayedScrollRows` toward the target each frame, applying the
  // integer delta to libghostty's viewport and the sub-cell remainder as
  // a vertical pixel shift in the renderer. Precise (trackpad) input in
  // pixel-smooth mode tracks the finger 1:1 with fractional rows and only
  // quantizes at rest: a settle work item rounds the target onto a whole
  // row once input goes quiet. In line-quantized mode precise input snaps
  // whole rows per event (macOS already smoothed it). Reset on tab switch.
  //
  // Algorithm matches Neovide's PD scroll controller (proven well-tuned
  // for text-grid UIs). omega = 25 rad/s gives a critically-damped
  // settling time of ~160 ms for a one-row spin.
  private var targetScrollRows: Double = 0
  private var displayedScrollRows: Double = 0
  private var scrollVelocityRowsPerSec: Double = 0
  private var appliedScrollRows: Int = 0
  private var lastScrollTickAt: ContinuousClock.Instant?
  // Snappier settle: ~80 ms instead of ~160 ms. In a terminal you scroll
  // back to *read* the content as it passes; less time at peak velocity =
  // less unreadable middle of the animation.
  private static let scrollOmega: Double = 50.0  // rad/s
  private static let terminalOutputDisplayLinkHoldSeconds: TimeInterval = 0.150
  // Wheel deltas at or below this magnitude snap directly when nothing's
  // already animating. Single click-and-read scrollback navigation feels
  // crisp; only fast continuous spins go through the controller.
  private static let scrollSmoothingThreshold: Int = 3
  /// How close to the live bottom a downward scroll must land before it is
  /// treated as a return-to-follow when a streaming app moved the bottom past
  /// the step. A non-alt-screen app (Codex) streaming ~1 row/frame matches each
  /// 1-row down-nudge, so a bounded scroll stalls a few rows short forever and
  /// the overlay indicator never clears; within this band we pin to the active
  /// bottom instead. Bounded small so a down-scroll deep in history (navigation,
  /// not a return to the bottom) is never yanked to the live bottom.
  private static let scrollFollowReengageRows: Int = 6
  /// Set true by the per-frame PD controller while it's still moving
  /// `displayedScrollRows` toward `targetScrollRows`. The render path
  /// reads it to (1) compute the sub-cell `contentYOffset` and (2) force
  /// damage = .full so the persistent target is fully repainted at the
  /// new fractional position.
  private var scrollAnimating: Bool = false

  /// Pending settle-to-whole-row for precise pixel-smooth scrolling. Re-armed
  /// by every precise event, so it fires only after real input quiet. The
  /// work item is the explicit future wake ADR 0018 requires — a static
  /// fraction changes no pixels, so no frames run until the settle retargets.
  private var preciseScrollSettleWork: DispatchWorkItem?
  private static let preciseScrollSettleQuiescenceSeconds: TimeInterval = 0.15
  /// Input-speed estimate (rows/sec, EMA) for the precise-input resampler's
  /// adaptive stiffness. Reset by stream gaps; never used for positions.
  private var preciseInputRowsPerSec: Double = 0
  private var lastPreciseInputEventAt: ContinuousClock.Instant?
  /// Renderer instance whose drawable catch-up wake has been installed, so
  /// backend swaps re-install onto the new renderer.
  private weak var drawableWakeInstalledRenderer: MetalRenderer?

  /// Whether the previous frame animated the attention marker. The animation
  /// never touches terminal damage: it repaints via the renderer's dedicated
  /// sidebar-strip pass (`repaintSidebarStrip`). One trailing strip frame
  /// after an animation window closes parks the marker's final state on
  /// glass — gone, or resting at full opacity — instead of freezing mid-step.
  private var attentionWasAnimating = false

  /// When each tab entered needsAction, driving the announce-once timeline
  /// for frame pacing. The controller keeps its own equivalent map for
  /// rendering; the two are rebuilt from the same classifier on the same
  /// frames, so they agree to within a frame.
  private var attentionEntryTimes: [Tab.ID: Date] = [:]
  private var attentionPingWakeScheduled = false

  /// Scroll-position signature of the most recently journaled idle park, so a
  /// sustained off-bottom park logs one `noFrameNeeded` entry instead of one
  /// per vsync. Reset to `nil` whenever the viewport sits at the live bottom.
  private var lastParkSignature: String?

  /// Per-frame diagnostics captured at the top of `advanceFrame` so every
  /// journal entry in the frame can report whether `syncSessions` re-asserted
  /// `renderInvalidated` and what the active tab's metadata looked like. Used
  /// to pin which metadata field keeps an otherwise idle terminal redrawing.
  private var frameModelChanged = false
  private var frameMetadataSignature: String?

  // IME composition buffer
  private var markedText: NSAttributedString = .init(string: "")
  // Caret position within `markedText`, in cells (grapheme clusters from the
  // start), derived from the IME's selectedRange so the on-screen caret sits at
  // the composition's insertion point rather than always at its end.
  private var markedTextCaretCells: Int = 0
  var markedTextCaretCellsForTesting: Int { markedTextCaretCells }

  // Active key descriptor during interpretKeyEvents dispatch
  private var currentKeyDescriptor: TerminalKeyDescriptor?

  // Tracks last surface dimensions to avoid redundant reallocations
  private var lastPixelWidth: Int = 0
  private var lastPixelHeight: Int = 0
  private var lastSurfaceScale: CGFloat = 0
  private var captureRecorder: CaptureRecorder?
  /// On-surface "● REC" pill, shown only while a capture is active. Created
  /// lazily on first capture start, mirroring the find-chip subview pattern.
  private var captureIndicatorView: TerminalCaptureIndicatorView?
  private struct ClosedTabUndoPayload {
    var argv: [String]?
    var cwd: String
  }
  private var frameProbe: AppKitFrameProbe?
  private var resizeProbe: AppKitResizeProbe?
  private var resizeAutomationScheduled = false
  var undoManagerForTesting: UndoManager?
  private var renderingResizeFrame = false
  private var renderRetryScheduled = false
  private var resizeBackgroundReset: DispatchWorkItem?
  private weak var resizeBackgroundView: NSView?
  private var normalResizeBackgroundColor: CGColor?
  private var normalResizeBackgroundWantsLayer: Bool?

  /// Hook for the overlay scroll indicator (sibling view in the window
  /// containerView). Called every frame from `advanceFrame` with the active
  /// session's viewport state, or `nil` when there is no active tab.
  var onViewportChanged:
    (
      (
        _ viewportOffset: Int, _ totalRows: Int, _ viewportRows: Int,
        _ isAltScreen: Bool, _ isMouseTracking: Bool
      ) -> Void
    )?
  var onViewportUnavailable: (() -> Void)?
  /// Fired when the active tab changes, before the new tab's first viewport
  /// sample. The overlay scroll indicator is a single sibling view shared by
  /// every tab, so it must drop the outgoing tab's visible state here or it
  /// flashes the previous tab's thumb for a beat when a new tab is selected.
  var onActiveTabChanged: (() -> Void)?
  private var renderedFrameCount: Int = 0
  var renderedFrameCountForTests: Int { renderedFrameCount }

  private var windowFocusObservers: [NSObjectProtocol] = []
  private var lastReportedFocusBySession: [Session.ID: Bool] = [:]
  private var lastAppliedWindowTitle: String?

  private var synchronizedOutputHold: TerminalRenderGate.SynchronizedOutputHold?
  var synchronizedOutputHoldForTests: TerminalRenderGate.SynchronizedOutputHold? {
    get { synchronizedOutputHold }
    set { synchronizedOutputHold = newValue }
  }

  private var outputSettleHold: TerminalRenderGate.OutputSettleHold?
  private var outputSettleWakeScheduled = false
  private var synchronizedOutputWakeScheduled = false
  var outputSettleHoldForTests: TerminalRenderGate.OutputSettleHold? {
    get { outputSettleHold }
    set { outputSettleHold = newValue }
  }
  private var trackedMouseDragFrameTimer: Timer?
  private enum TrackedMouseDragVerticalEdge {
    case top
    case bottom
  }
  private var trackedMouseDragEdge: TrackedMouseDragVerticalEdge?
  private var trackedMouseDragEdgeX: Float?
  private let trackedMouseDragEdgeXJitterToleranceCells = 8
  var trackedMouseDragFrameTimerActiveForTests: Bool {
    trackedMouseDragFrameTimer?.isValid == true
  }

  private let blinkDriver = CursorBlinkDriver()
  private var lastRenderedCursorBlinking = false

  /// Coalesces wake-ups from per-session reader threads. Set to true
  /// when a background drain has fired but no main-thread advanceFrame
  /// is yet in flight; cleared when the main-thread block runs. Lives
  /// behind an unfair lock so the comparison/swap is atomic across
  /// the reader threads and the main thread.
  private let displayKickCoalescer = TerminalDisplayKickCoalescer()

  /// Wake source of the in-flight `advanceFrame(wake:)` call; stamped at the
  /// top of every frame so each render-journal entry the frame records can
  /// carry it.
  private var lastWakeSource: FrameWakeSource = .other
  /// Counts every `advanceFrame(wake:)` entry. Lets wake tests assert that an
  /// input handler actually kicked the frame loop, synchronously, without
  /// depending on render side effects.
  private(set) var advanceFrameCallCountForTesting = 0

  /// Rollout parachute for the full-park display link (ADR 0018): when the
  /// `LabanDisplayLinkIdleFloor` user default is true, the pre-park 8 Hz
  /// visible-idle floor is restored — an instant, no-rebuild rollback for the
  /// frozen-frame risk class. Read once at view init; relaunch applies a
  /// change. This is the single UserDefaults read for the flag.
  private let displayLinkIdleFloorEnabled =
    UserDefaults.standard.bool(forKey: "LabanDisplayLinkIdleFloor")

  /// TEMPORARY missed-wake safety net (full-park Milestone 3): a 30 s
  /// main-queue timer armed only while the link is parked. If a session's
  /// dirty generation advanced past its last-synced generation with no frame
  /// produced, the net repairs the screen and logs
  /// `render.displayLink.safetyNetRepair` — every such event is a missed wake
  /// to root-cause. Removed by a follow-up commit once the Milestone-5 soak
  /// criteria are met.
  private var safetyNetTimer: DispatchSourceTimer?
  private static let safetyNetIntervalSeconds: TimeInterval = 30

  // Input-to-photon latency tracking. Stamped on keyDown; closed out by the
  // renderer's onFrameCompleted callback. Bounded ring buffer.
  private var pendingInputAt: ContinuousClock.Instant?
  private var inputLatencyMs: [Double] = []
  private static let inputLatencyCap = 240
  private var lastLatencyLogAt: Date = Date.distantPast

  /// Smaller font for sidebar chrome — different visual weight from the
  /// terminal content (matches what every modern editor + terminal does)
  /// and fits ~25 % more chars per line so worktree paths stop truncating.
  private(set) var sidebarFontAtlas: FontAtlas
  private(set) var sidebarCellWidth: Int
  private(set) var sidebarCellHeight: Int

  /// Prebuilt per-size atlas ladder so a zoom step swaps pointers instead of
  /// rasterizing. Created after the first frame (`ensureAtlasLadder`),
  /// discarded and rebuilt on backing-scale change. Nil (or still warming)
  /// means `applyFontSize` builds atlases synchronously — the ladder is an
  /// accelerator, never a correctness dependency.
  private(set) var atlasLadder: GlyphAtlasLadder?

  init(
    model: AppModel,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas,
    cellWidth: Int,
    cellHeight: Int,
    urlOpener: any ExternalURLOpening = NSWorkspace.shared,
    sessionCoordinator: AppSessionCoordinator? = nil
  ) {
    self.model = model
    self.urlOpener = urlOpener
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.sessionCoordinator = sessionCoordinator
    self.sidebarCellWidth = Int(sidebarFontAtlas.cellSize.width)
    self.sidebarCellHeight = Int(sidebarFontAtlas.cellSize.height)
    self.lastRows = max(1, Int(model.terminalSize.rows))
    let gpuFreezeAutoDumpEnabled = RenderJournal.gpuFreezeAutoDumpEnabled()
    self.gpuFreezeAutoDumpEnabled = gpuFreezeAutoDumpEnabled
    self.renderJournalEnabled = RenderJournal.isEnabled() || gpuFreezeAutoDumpEnabled
    self.surfaceController = TerminalSurfaceController(
      model: model,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarWidth: SidebarLayout.defaultWidth,
      sidebarCellWidth: sidebarFontAtlas.cellSize.width,
      sidebarCellHeight: sidebarFontAtlas.cellSize.height
    )

    let selection =
      Self.launchForcesSoftwareRenderer ? .software : RendererSelection.persisted()
    self.backend = Self.makeBackend(
      selection: selection,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas)
    self.backendSelfPresents = backend.presentationLayer != nil
    super.init(frame: .zero)
    registerForDraggedTypes(TerminalDrop.acceptedTypes)
    // The terminal is the window's primary surface and effectively always the
    // first responder; a system focus ring renders as a persistent blue border
    // around the whole pane. VoiceOver reads the surface through the
    // accessibility tree below, not this ring, so suppress it.
    focusRingType = .none
    configurePresentationForCurrentBackend()

    // Install the per-frame completion hook so we can close out
    // input-to-photon latency samples on the GPU completion handler. The
    // callback fires on a Metal-internal queue; bounce to main before
    // touching shared state.
    installFrameCompletionHook()

    // When the blink driver fires a phase flip it calls advanceFrame()
    // directly so the cursor toggles immediately instead of waiting up to
    // 125 ms for the next 8 Hz display-link tick.
    blinkDriver.onPhaseFlip = { [weak self] in
      self?.advanceFrame(wake: .blinkTimer)
    }

    // Force a full redraw on every theme swap so chrome (sidebar bg, cursor,
    // selection) re-reads `Theme.current`. AppModel re-injects the OSC
    // palette into running sessions in its own observer; this one is just
    // about getting the next frame onto screen with the new chrome colors.
    themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      (self.backend as? MetalRenderer)?.invalidateContentForThemeChange()
      self.renderInvalidated = true
      // The display link parks when Settings (or another window) is key, so
      // invalidation alone is not enough — kick the frame loop the same way a
      // renderer switch does.
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    // Re-sync the blink driver and repaint whenever the user changes cursor
    // settings so the new style and blink state take effect immediately.
    cursorSettingsObserver = NotificationCenter.default.addObserver(
      forName: CursorSettings.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.renderInvalidated = true
      self.syncBlinkDriverFromWindowState()
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    emojiRenderingObserver = NotificationCenter.default.addObserver(
      forName: EmojiRenderingSettings.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      (self.backend as? MetalRenderer)?.invalidateContentForThemeChange()
      (self.backend as? VectorGlyphRenderer)?.refreshEmojiRenderingMode()
      self.renderInvalidated = true
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    vectorSubpixelLayoutObserver = NotificationCenter.default.addObserver(
      forName: VectorSubpixelLayout.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let vector = self.backend as? VectorGlyphRenderer else { return }
      vector.setSubpixelLayout(VectorSubpixelLayout.persisted())
      // Confirm the live change landed: log the configured choice and the layout
      // actually rendered (the auto-policy may force grayscale). The visual delta
      // is sub-perceptual at small sizes on a 2x Retina panel, so this is the
      // reliable way to see the setting took effect.
      AppLog.render.info(
        "vector subpixel layout configured=\(vector.subpixelLayout.name) "
          + "effective=\(vector.rendererStatus.vectorSubpixelLayout ?? "?")")
      self.renderInvalidated = true
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    vectorTextWeightObserver = NotificationCenter.default.addObserver(
      forName: VectorTextWeightSettings.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let vector = self.backend as? VectorGlyphRenderer else { return }
      vector.refreshTextWeight()
      self.renderInvalidated = true
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    vectorSmoothScrollObserver = NotificationCenter.default.addObserver(
      forName: VectorSmoothScrollSettings.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self, let vector = self.backend as? VectorGlyphRenderer else { return }
      vector.refreshSmoothScrollMode()
      self.renderInvalidated = true
      if self.window != nil {
        self.scheduleRenderRetry()
      }
    }

    // A display-mode change (Default <-> More Space) or moving the window to a
    // different screen changes whether the framebuffer is downsampled, which the
    // vector subpixel auto-policy depends on. Re-evaluate and repaint.
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if self.updateDisplayDownsampledState() {
        self.renderInvalidated = true
        if self.window != nil {
          self.scheduleRenderRetry()
        }
      }
    }

    // Settings font panel live-apply: a size-only change applies immediately
    // through the zoom path (applyFontSize no-ops when it posted this
    // notification itself — the clamped size already matches). A family
    // change is recorded but not applied; restart remains the contract.
    fontChangeObserver = NotificationCenter.default.addObserver(
      forName: FontAtlas.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      let persistedName = UserDefaults.standard.string(forKey: FontAtlas.userFontKey)
      if self.persistedFontNameMatchesActive(persistedName) {
        self.applyFontSize(FontAtlas.persistedTerminalPointSize)
      } else {
        self.lastObservedPersistedFontName = persistedName
      }
    }

    // Track the system accessibility display settings so visual preferences
    // take effect mid-session, and force a frame so the change is immediate.
    // The wake matters: with a parked display link the invalidation alone
    // would sit unpainted until some other source produced a frame.
    reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.accessibilityDisplayOptions = Self.currentAccessibilityDisplayOptions()
      self?.invalidateRenderAndWake()
    }

    // The per-session reader thread fires this callback whenever it drained
    // bytes. We coalesce them into a single main-thread advanceFrame so a chatty
    // child does not pile up advanceFrame tasks behind a long render. The
    // display link still ticks on its own clock -- this hop only matters when
    // VRR has throttled the link to a low rate and we need to bypass that
    // throttle.
    let displayKickCoalescer = displayKickCoalescer
    model.onSessionDirty = { [weak self, displayKickCoalescer] _ in
      displayKickCoalescer.requestFrameAdvance {
        guard let self else { return }
        self.advanceFrame(wake: .sessionDirty)
        NSAccessibility.post(element: self, notification: .valueChanged)
      }
    }

    // Model mutations that change pixels without terminal bytes (tab
    // select/open/close/reorder, resolved git branches, daemon surface
    // signals, agent status) wake the frame loop here. Same coalescer as
    // onSessionDirty so a burst of mutations folds into one frame. The policy
    // and gating live in LabanCore and are shared with HeadlessDebugRuntime;
    // this hook is AppKit-only plumbing (headless frames are endpoint-driven
    // and leave it unset).
    //
    // The invalidation is load-bearing (M2-5 review finding F1): these
    // mutations bump no dirty generation, so the woken frame's gated
    // syncSessions reports the tab unchanged and the render guard would
    // early-return — a wake without `renderInvalidated` paints nothing and
    // the change stays frozen on a parked window. This is
    // `invalidateRenderAndWake()` semantics routed through the coalescer.
    model.onSurfaceStateChanged = { [weak self, displayKickCoalescer] in
      displayKickCoalescer.requestFrameAdvance {
        guard let self else { return }
        self.renderInvalidated = true
        self.advanceFrame(wake: .modelMutation)
      }
    }

    configureFrameProbeIfRequested()
    configureResizeProbeIfRequested()
    scheduleAutomationIfRequested()
  }

  private func configureFrameProbeIfRequested() {
    guard let raw = ProcessInfo.processInfo.environment["LABAN_FRAME_PROBE_DIR"],
      !raw.isEmpty
    else { return }
    do {
      frameProbe = try AppKitFrameProbe(directory: URL(fileURLWithPath: raw, isDirectory: true))
      AppLog.capture.info("frame probe started \(raw)")
    } catch {
      AppLog.capture.error("frame probe failed: \(error)")
    }
  }

  private func configureResizeProbeIfRequested() {
    guard let raw = ProcessInfo.processInfo.environment["LABAN_RESIZE_PROBE_DIR"],
      !raw.isEmpty
    else { return }
    do {
      resizeProbe = try AppKitResizeProbe(directory: URL(fileURLWithPath: raw, isDirectory: true))
      AppLog.capture.info("resize probe started \(raw)")
    } catch {
      AppLog.capture.error("resize probe failed: \(error)")
    }
  }

  private func scheduleAutomationIfRequested() {
    let env = ProcessInfo.processInfo.environment
    if env["LABAN_AUTOSTART_CAPTURE"] == "1" {
      DispatchQueue.main.async { [weak self] in
        self?.toggleCapture(nil)
      }
    }

    guard let rawSeconds = env["LABAN_AUTO_QUIT_AFTER_SECONDS"],
      let seconds = Double(rawSeconds),
      seconds > 0
    else { return }
    postAutomationAutoQuitNotice(
      "Automation will quit Laban in \(Self.formatAutomationSeconds(seconds)).")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      if let self, self.captureRecorder != nil {
        self.toggleCapture(nil)
      }
      NSApp.terminate(nil)
    }
  }

  private func scheduleResizeAutomationIfRequested() {
    guard !resizeAutomationScheduled,
      window != nil,
      let config = TerminalResizeAutomation.configuration(
        environment: ProcessInfo.processInfo.environment)
    else { return }
    resizeAutomationScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + config.startDelaySeconds) { [weak self] in
      self?.runResizeAutomation(config: config)
    }
  }

  private func runResizeAutomation(config: TerminalResizeAutomation.Configuration) {
    guard let window else { return }
    let steps = config.steps
    let settleDelay = config.settleDelaySeconds
    resizeProbe?.record(
      label: "initial", window: window, view: self, backend: backend,
      renderedFrame: renderedFrameCount)

    func applyStep(_ index: Int) {
      guard index < steps.count else {
        resizeProbe?.record(
          label: "final", window: window, view: self, backend: backend,
          renderedFrame: renderedFrameCount)
        if config.autoQuit {
          postAutomationAutoQuitNotice("Resize automation will quit Laban after the final step.")
          NSApp.terminate(nil)
        }
        return
      }
      let size = steps[index]
      applyTransientResizeBackground()
      window.setContentSize(size)
      resizeProbe?.record(
        label: "step-\(index)-immediate", window: window, view: self, backend: backend,
        renderedFrame: renderedFrameCount)
      DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
        self.resizeProbe?.record(
          label: "step-\(index)-settled", window: window, view: self, backend: self.backend,
          renderedFrame: self.renderedFrameCount)
        applyStep(index + 1)
      }
    }

    applyStep(0)
  }

  /// Pop the pending input timestamp (if any) and record the elapsed time.
  /// Called from the renderer's GPU completion handler each frame.
  private func recordInputLatencyIfPending() {
    guard let stamp = pendingInputAt else { return }
    pendingInputAt = nil
    let dt = ContinuousClock.now - stamp
    let ms = Double(dt.components.attoseconds) / 1e15
    inputLatencyMs.append(ms)
    if inputLatencyMs.count > Self.inputLatencyCap {
      inputLatencyMs.removeFirst(inputLatencyMs.count - Self.inputLatencyCap)
    }
    // Log a summary every ~5 s so you see numbers without an HTTP server.
    let now = Date()
    if now.timeIntervalSince(lastLatencyLogAt) >= 5,
      inputLatencyMs.count >= 4
    {
      lastLatencyLogAt = now
      let sorted = inputLatencyMs.sorted()
      let p50 = sorted[sorted.count / 2]
      let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
      let mean = inputLatencyMs.reduce(0, +) / Double(inputLatencyMs.count)
      let metalTimings: String
      if let metal = backend as? MetalRenderer {
        let t = metal.recentFrameTimings()
        var line = String(
          format: "  frame cpu p50/p99=%.2f/%.2f ms  gpu p50/p99=%.2f/%.2f ms",
          t.cpuP50Ms, t.cpuP99Ms, t.gpuP50Ms, t.gpuP99Ms)
        if t.perPassAvailable {
          line += String(
            format: "  [content=%.2f present=%.2f cursor=%.2f readback=%.2f ms mean]",
            t.contentMeanMs, t.presentBlitMeanMs,
            t.cursorOverlayMeanMs, t.readbackBlitMeanMs)
        }
        metalTimings = line
      } else {
        metalTimings = ""
      }
      AppLog.render.info(
        "input→commit n=\(inputLatencyMs.count) mean=\(String(format: "%.2f", mean))ms p50=\(String(format: "%.2f", p50))ms p99=\(String(format: "%.2f", p99))ms\(metalTimings)"
      )
    }
  }

  required init?(coder: NSCoder) { nil }

  private static var launchForcesSoftwareRenderer: Bool {
    let preference = ProcessInfo.processInfo.environment["LABAN_RENDERER"]?.lowercased()
    return preference == "software" || preference == "cpu"
  }

  private static func makeBackend(
    selection: RendererSelection,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas
  ) -> RendererBackend {
    makeRendererBackend(
      selection: selection,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas)
  }

  private func configurePresentationForCurrentBackend() {
    backendSelfPresents = backend.presentationLayer != nil
    if let layer = backend.presentationLayer {
      self.layer = layer
      wantsLayer = true
      // Metal layers must opt in to backing scale changes via the view.
      layerContentsRedrawPolicy = .duringViewResize
    } else {
      self.layer = nil
      wantsLayer = false
    }
  }

  private func installFrameCompletionHook() {
    guard backend.rendererStatus.effectiveRenderer != RendererSelection.software.rawValue else {
      return
    }
    backend.onFrameCompleted = { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.gpuFrameCompletionCount += 1
        self.gpuFreezeDetector.noteMetalFrameCompleted(
          completionCount: self.gpuFrameCompletionCount)
        self.recordInputLatencyIfPending()
      }
    }
  }

  var rendererMode: RendererMode {
    backend.rendererStatus.configuredRenderer == RendererMode.gpuDriven.rawValue
      ? .gpuDriven : .classic
  }

  var rendererSelection: RendererSelection {
    RendererSelection(rawValue: backend.rendererStatus.configuredRenderer) ?? .software
  }

  var usesMetalBackend: Bool {
    backend is MetalRenderer
  }

  var terminalFontPostScriptName: String {
    fontAtlas.fontPostScriptName
  }

  var terminalFontPanelFont: NSFont? {
    let descriptor = CTFontCopyFontDescriptor(fontAtlas.font) as NSFontDescriptor
    return NSFont(descriptor: descriptor, size: fontAtlas.pointSize)
  }

  func applyRendererMode(_ mode: RendererMode) {
    applyRendererSelection(RendererSelection(metalMode: mode))
  }

  func applyRendererSelection(_ selection: RendererSelection) {
    let resolved = selection.isAvailableOnCurrentOS ? selection : .classic
    RendererSelection.set(resolved)
    if rendererSelection == resolved { return }

    gpuFreezeDetector.reset()
    gpuFrameCompletionCount = 0

    if let metalMode = resolved.metalMode,
      let metal = backend as? MetalRenderer
    {
      metal.clearRendererStatusOverride()
      guard metal.configuredRendererMode != metalMode else { return }
      metal.configuredRendererMode = metalMode
      metal.clearRendererStatusOverride()
      renderInvalidated = true
      if window != nil {
        scheduleRenderRetry()
      }
      return
    }

    backend.onFrameCompleted = nil
    backend = Self.makeBackend(
      selection: resolved,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas)
    configurePresentationForCurrentBackend()
    installFrameCompletionHook()
    lastPixelWidth = 0
    lastPixelHeight = 0
    lastSurfaceScale = 0
    _ = recreateSurface()
    renderInvalidated = true
    if window != nil {
      scheduleRenderRetry()
    }
    if !backendSelfPresents {
      needsDisplay = true
    }
  }

  func snapshotCommandsHook(captureFrame: Int) -> TerminalSurfaceController.SnapshotCommandsHook? {
    guard let frameProbe else { return nil }
    return { [weak self, frameProbe] snapshot, commands in
      guard let self else { return }
      frameProbe.record(
        frame: captureFrame,
        snapshot: snapshot.pointee,
        commands: commands,
        surfaceWidth: self.backend.surfaceWidth,
        surfaceHeight: self.backend.surfaceHeight,
        surfaceScale: Double(self.backend.surfaceScale))
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    lastAppliedWindowTitle = nil
    removeWindowFocusObservers()
    guard window != nil else {
      syncActiveSessionFocus(windowFocused: false)
      stopDisplayLink()
      sessionCoordinator?.stopSnapshotGenerationMonitor()
      resizeBackgroundReset?.cancel()
      resizeBackgroundReset = nil
      resizeBackgroundView = nil
      normalResizeBackgroundColor = nil
      normalResizeBackgroundWantsLayer = nil
      return
    }
    if let window {
      installWindowFocusObservers(for: window)
    }
    // Prevent duplicate links when view transitions between windows.
    if caDisplayLink == nil && cvDisplayLink == nil {
      recreateSurface()
      startDisplayLink()
    } else {
      recreateSurface()
    }
    invalidateRenderAndWake()
    window?.makeFirstResponder(self)
    syncActiveSessionFocus(windowFocused: window?.isKeyWindow == true)
    startLabandSnapshotGenerationMonitor()
    scheduleResizeAutomationIfRequested()
    // Defer ladder prebuild past the first frame so startup latency never
    // pays for it; until it lands, zoom uses the synchronous fallback.
    DispatchQueue.main.async { [weak self] in
      self?.ensureAtlasLadder()
    }
  }

  /// Create (or recreate after a backing-scale change) the prebuilt atlas
  /// ladder and kick off its background prebuild. On the software backend the
  /// ladder still serves `FontAtlas` metrics; its GPU atlases are simply
  /// unused.
  private func ensureAtlasLadder() {
    guard let window else { return }
    let scale = window.backingScaleFactor
    if let ladder = atlasLadder, abs(ladder.scale - scale) < 0.0001 { return }
    let device = (backend as? MetalRenderer)?.device ?? MTLCreateSystemDefaultDevice()
    guard let device else {
      atlasLadder = nil
      return
    }
    let ladder = GlyphAtlasLadder(
      device: device,
      scale: scale,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas)
    atlasLadder = ladder
    ladder.beginPrebuild(excluding: Int(FontAtlas.clampedZoomPointSize(fontAtlas.pointSize)))
  }

  private func persistedFontNameMatchesActive(_ persistedName: String?) -> Bool {
    guard let persistedName, !persistedName.isEmpty else {
      return lastObservedPersistedFontName == nil
    }
    return fontAtlas.matches(fontName: persistedName)
  }

  private func startLabandSnapshotGenerationMonitor() {
    sessionCoordinator?.startSnapshotGenerationMonitor {
      [weak self, displayKickCoalescer] _, now in
      displayKickCoalescer.requestFrameAdvance(now: now) {
        self?.advanceFrame(wake: .labandGeneration)
      }
    }
  }

  private func installWindowFocusObservers(for window: NSWindow) {
    let center = NotificationCenter.default
    windowFocusObservers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.syncActiveSessionFocus(windowFocused: true)
        // Wake the (possibly parked) display link and repaint on refocus.
        self?.advanceFrame(wake: .focus)
      })
    windowFocusObservers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.syncActiveSessionFocus(windowFocused: false)
        self?.updateDisplayLinkRunState()
        // Window no longer visible to user: stop the blink timer immediately
        // so the cursor freezes solid rather than blinking behind a covered window.
        self?.syncBlinkDriverFromWindowState()
        // A precise gesture interrupted by an app switch must not freeze the
        // grid on a fractional row.
        self?.settlePreciseScrollToWholeRow()
      })
    // Occlusion changes don't fire key notifications, so observe them too:
    // becoming un-occluded must wake the parked link; becoming occluded parks
    // it. advanceFrame's defer reconciles the run state in either direction.
    windowFocusObservers.append(
      center.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.advanceFrame(wake: .occlusion)
      })
  }

  private func removeWindowFocusObservers() {
    let center = NotificationCenter.default
    for observer in windowFocusObservers {
      center.removeObserver(observer)
    }
    windowFocusObservers.removeAll()
  }

  private func syncActiveSessionFocus(windowFocused: Bool) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    reportFocus(to: session, tab: activeTab, focused: windowFocused)
  }

  private func reportFocus(to session: Session, tab: Tab, focused: Bool) {
    guard session.focusReportingEnabled else {
      lastReportedFocusBySession.removeValue(forKey: session.id)
      return
    }
    guard lastReportedFocusBySession[session.id] != focused else { return }
    let delivered: Bool
    if let sessionCoordinator, sessionCoordinator.terminalClient != nil {
      // Remote tier: the local Session is fixture-mode, so `sendFocus` only
      // encodes and drops the bytes (same trap as paste/mouse). Encode the
      // CSI I / CSI O and forward to the daemon's PTY so the app sees focus.
      if let bytes = session.encodeFocus(focused: focused), !bytes.isEmpty {
        delivered =
          (try? sessionCoordinator.write(
            bytes, to: tab, session: session, size: model.terminalSize)) != nil
      } else {
        delivered = false
      }
    } else {
      delivered = session.sendFocus(focused: focused) == 0
    }
    if delivered {
      lastReportedFocusBySession[session.id] = focused
    }
  }

  private func startDisplayLink() {
    if #available(macOS 14.0, *) {
      // A low preferred rate keeps visible-idle terminals cold; output latency
      // is still covered by the onSessionDirty push path, which bypasses the
      // link throttle. updateDisplayLinkRunState raises preferred while smooth
      // scroll or attention animation is active.
      let link = displayLink(target: self, selector: #selector(displayLinkTick))
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: Float(TerminalIdlePolicy.idleDisplayLinkFramesPerSecond),
        maximum: Float(TerminalIdlePolicy.activeDisplayLinkFramesPerSecond),
        preferred: Float(TerminalIdlePolicy.idleDisplayLinkFramesPerSecond))
      link.add(to: .main, forMode: .common)
      caDisplayLink = link
      return
    }
    var link: CVDisplayLink?
    let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard createResult == kCVReturnSuccess, let link else { return }

    // The previous implementation passed `Unmanaged.passUnretained(self)`
    // straight to the CVDisplayLink. That left the view's lifetime racing the
    // display-link thread: `CVDisplayLinkStop` is documented as *not*
    // synchronous against an in-flight output callback, so a callback already
    // past `takeUnretainedValue` on a now-deallocated view would crash.
    // Indirect through a small proxy with a weak ref instead; the proxy is
    // retained for the lifetime of the link's userInfo and the weak ref
    // nils out cleanly when the view deinits.
    let proxy = CVDisplayLinkProxy(self)
    let opaqueProxy = Unmanaged.passRetained(proxy).toOpaque()
    let setCallbackResult = CVDisplayLinkSetOutputCallback(
      link,
      { (_, _, _, _, _, userInfo) -> CVReturn in
        guard let userInfo else { return kCVReturnSuccess }
        let proxy = Unmanaged<CVDisplayLinkProxy>.fromOpaque(userInfo)
          .takeUnretainedValue()
        guard let view = proxy.view else { return kCVReturnSuccess }
        // Vsync callback runs on a dedicated high-priority thread; bounce to
        // main where AppKit, the model, and the renderer must be touched.
        DispatchQueue.main.async {
          view.noteDisplayLinkTick()
          view.advanceFrame(wake: .displayLink)
        }
        return kCVReturnSuccess
      },
      opaqueProxy
    )
    guard setCallbackResult == kCVReturnSuccess else {
      Unmanaged<CVDisplayLinkProxy>.fromOpaque(opaqueProxy).release()
      return
    }

    // The retain on `proxy` is intentionally not balanced: there is no
    // public API to wait for an in-flight CVDisplayLink callback to drain,
    // so any release would race UAF on the proxy itself. The proxy is a
    // ~24-byte object; leaking one per display-link start (typically
    // once per view per window attach) is the documented trade.
    cvDisplayLink = link
    CVDisplayLinkStart(link)
  }

  /// CADisplayLink target/selector. Already on main, so no dispatch hop.
  @objc private func displayLinkTick(_ link: AnyObject) {
    noteDisplayLinkTick()
    advanceFrame(wake: .displayLink)
  }

  private func noteDisplayLinkTick(now: Date = Date()) {
    IdleCounters.shared.noteDisplayLinkTick()
    if let lastDisplayLinkTickAt {
      lastDisplayLinkTickIntervalMs = now.timeIntervalSince(lastDisplayLinkTickAt) * 1000.0
    }
    lastDisplayLinkTickAt = now
  }

  /// Called from a per-session reader thread (off main) when the
  /// reader has drained bytes through the VT parser. Coalesces wake-
  /// ups via `pendingDisplayKick`: only the first dirty drain since
  /// the last main-thread tick posts to main, the rest are folded
  /// into that pending tick. Bypasses the CADisplayLink VRR throttle
  /// so a top(1) refresh that lands during an "idle" window is not
  /// stuck waiting up to 41 ms for the link to ramp back up.
  private func scheduleOutputSettleWake(after delay: TimeInterval) {
    guard !outputSettleWakeScheduled else { return }
    outputSettleWakeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.outputSettleWakeScheduled = false
      self.advanceFrame(wake: .settleWake)
    }
  }

  /// Wake the frame loop when the next attention re-ping window opens. While
  /// a needsAction marker rests (static, no frames) the display link parks,
  /// so without an explicit wake the re-ping would wait on unrelated
  /// activity. Same shape as the output-settle wake above.
  private func scheduleAttentionPingWake(after delay: TimeInterval) {
    guard !attentionPingWakeScheduled else { return }
    attentionPingWakeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.attentionPingWakeScheduled = false
      self.advanceFrame(wake: .settleWake)
    }
  }

  /// Re-evaluate a frame held by DEC synchronized output after a bounded delay,
  /// independent of the display link. A synchronized-output defer presents the
  /// last completed frame; the only timer that resolves the gate on its own is
  /// the one-second watchdog. The display link normally re-ticks during the hold
  /// (the terminal-output hold re-arms it), but if it has parked — window blur,
  /// occlusion, or a tick where terminalDirty momentarily cleared — nothing else
  /// drives the watchdog and the held frame freezes until the user scrolls. This
  /// guarantees the gate is re-evaluated, so the reset (or a now-clean render) is
  /// reached within the watchdog window regardless of link state.
  private func scheduleSynchronizedOutputWake(after delay: TimeInterval) {
    guard !synchronizedOutputWakeScheduled else { return }
    synchronizedOutputWakeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.synchronizedOutputWakeScheduled = false
      self.advanceFrame(wake: .synchronizedOutputWake)
    }
  }

  private func scheduleRenderRetry() {
    guard !renderRetryScheduled else { return }
    renderRetryScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.renderRetryScheduled = false
      self.advanceFrame(wake: .renderRetry)
    }
  }

  /// Invalidate the current frame AND kick the frame loop. With a fully
  /// parked display link, a bare `renderInvalidated = true` is a frozen-frame
  /// bug waiting to happen: nothing repaints until some unrelated wake fires.
  /// Every invalidation site outside `advanceFrame`'s own flow must use this
  /// (or be directly followed by its own wake) so future sites cannot regress
  /// silently. The retry is coalesced — a handler that invalidates several
  /// times still produces one frame.
  private func invalidateRenderAndWake() {
    renderInvalidated = true
    scheduleRenderRetry()
  }

  private func scrollViewport(
    deltaRows: Int,
    tab: Tab,
    session: Session,
    desiredAppliedRows: Int? = nil,
    resetOnClamp: Bool = false
  ) {
    if let sessionCoordinator, sessionCoordinator.usesRemoteSnapshots {
      var didScroll = false
      do {
        didScroll = try sessionCoordinator.scrollViewport(
          tab: tab,
          size: model.terminalSize,
          deltaRows: deltaRows
        )
        if didScroll {
          appliedScrollRows = desiredAppliedRows ?? (appliedScrollRows + deltaRows)
        }
      } catch {
        AppLog.app.error("laband scrollback failed: \(String(describing: error))")
      }
      if didScroll { return }
    }

    session.scrollViewport(deltaRows: deltaRows)
    if let desiredAppliedRows {
      syncSmoothScrollState(
        session: session,
        desiredAppliedRows: desiredAppliedRows,
        resetOnClamp: resetOnClamp
      )
    }
  }

  private func applyTransientResizeBackground() {
    guard let view = window?.contentView?.superview else { return }
    if resizeBackgroundView !== view {
      normalResizeBackgroundColor = nil
      normalResizeBackgroundWantsLayer = nil
      resizeBackgroundView = view
    }
    if normalResizeBackgroundWantsLayer == nil {
      normalResizeBackgroundWantsLayer = view.wantsLayer
      normalResizeBackgroundColor = view.layer?.backgroundColor
    }
    view.wantsLayer = true
    view.layer?.backgroundColor = cgColorFrom(Theme.current.bg0)

    resizeBackgroundReset?.cancel()
    let reset = DispatchWorkItem { [weak self, weak view] in
      guard let self, let view, view === self.resizeBackgroundView else { return }
      if let originalWantsLayer = self.normalResizeBackgroundWantsLayer {
        view.layer?.backgroundColor = self.normalResizeBackgroundColor
        view.wantsLayer = originalWantsLayer
      }
      self.resizeBackgroundView = nil
      self.normalResizeBackgroundColor = nil
      self.normalResizeBackgroundWantsLayer = nil
      self.resizeBackgroundReset = nil
    }
    resizeBackgroundReset = reset
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: reset)
  }

  private func stopDisplayLink() {
    if #available(macOS 14.0, *) {
      if let link = caDisplayLink as? CADisplayLink {
        link.invalidate()
      }
      caDisplayLink = nil
    }
    if let link = cvDisplayLink {
      CVDisplayLinkStop(link)
    }
    cvDisplayLink = nil
    // No link means nothing to repair into; the net re-arms on the next
    // parked transition after a link exists again.
    safetyNetTimer?.cancel()
    safetyNetTimer = nil
  }

  /// Park the per-frame display link whenever nothing on screen can change —
  /// including a focused, visible, quiescent window (full park, ADR 0018). The
  /// link is a transient animation timer (smooth scroll, attention pulse,
  /// post-output hold, the legacy blink/idle floors); everything else is
  /// event-driven through the wake sources tagged in `FrameWakeSource`.
  /// Terminal output is painted through the `onSessionDirty` push, so a parked
  /// link never delays output. Only the macOS-14 CADisplayLink supports cheap
  /// pausing; the CVDisplayLink fallback (pre-macOS-14) is left running and
  /// keeps the pre-park behavior. While parked, the temporary safety-net timer
  /// watches for missed wakes.
  /// Whether the CADisplayLink exists and is actively ticking. False on the
  /// macOS 13 CVDisplayLink fallback (which cannot pause, so per-event scroll
  /// wakes remain the pacing mechanism there).
  private var displayLinkIsTicking: Bool {
    guard #available(macOS 14.0, *), let link = caDisplayLink as? CADisplayLink else {
      return false
    }
    return !link.isPaused
  }

  private func updateDisplayLinkRunState() {
    guard #available(macOS 14.0, *), let link = caDisplayLink as? CADisplayLink else { return }
    let policy = displayLinkPolicyState()
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: Float(TerminalIdlePolicy.idleDisplayLinkFramesPerSecond),
      maximum: Float(TerminalIdlePolicy.activeDisplayLinkFramesPerSecond),
      preferred: Float(policy.preferredFramesPerSecond))
    link.isPaused = !policy.shouldRun
    setSafetyNetArmed(!policy.shouldRun)
  }

  /// Arm (parked) or cancel (running) the temporary missed-wake safety net.
  /// Idempotent; transitions only. See `safetyNetTimer`.
  private func setSafetyNetArmed(_ armed: Bool) {
    if armed {
      guard safetyNetTimer == nil else { return }
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.schedule(
        deadline: .now() + Self.safetyNetIntervalSeconds,
        repeating: Self.safetyNetIntervalSeconds,
        leeway: .seconds(5))
      timer.setEventHandler { [weak self] in
        self?.safetyNetTimerFired()
      }
      timer.resume()
      safetyNetTimer = timer
    } else if let timer = safetyNetTimer {
      timer.cancel()
      safetyNetTimer = nil
    }
  }

  /// Safety-net check: with the link parked, did any session's dirty
  /// generation advance without a frame syncing it? If yes, every wake source
  /// failed — repair the screen and leave a bug signal naming the miss. A
  /// clean check does zero render work.
  private func safetyNetTimerFired() {
    guard surfaceController.hasUnseenSessionActivity() else { return }
    EventLog.shared.log(
      "render.displayLink.safetyNetRepair",
      [
        "intervalSeconds": Self.safetyNetIntervalSeconds,
        "lastWakeSource": lastWakeSource.rawValue,
      ])
    AppLog.render.error(
      "display-link safety net repaired a missed wake (lastWakeSource=\(self.lastWakeSource.rawValue))"
    )
    // The frame this produces journals with wakeSource "safetyNet", which is
    // the render-journal half of the bug signal.
    advanceFrame(wake: .safetyNet)
  }

  /// Synchronise the blink driver with the current window-visibility state,
  /// without requiring a full rendered frame. Called from resign-key and
  /// occlusion observers so the timer stops promptly when the window hides.
  private func syncBlinkDriverFromWindowState() {
    let windowVisibleToUser =
      (window?.isKeyWindow == true)
      && (window?.occlusionState.contains(.visible) ?? false)
    blinkDriver.sync(
      blinkActive: lastRenderedCursorBlinking,
      windowVisibleToUser: windowVisibleToUser,
      cursorVisible: true)  // conservative: cursor treated as visible when we lack a fresh snapshot
  }

  private struct DisplayLinkPolicyState {
    var windowVisibleToUser: Bool
    var terminalOutputActive: Bool
    var attentionAnimating: Bool
    var scrollAnimating: Bool
    var cursorBlinkActive: Bool
    var idleFloorEnabled: Bool
    var shouldRun: Bool
    var preferredFramesPerSecond: Int
    var reason: String
  }

  private func displayLinkPolicyState(now: Date = Date()) -> DisplayLinkPolicyState {
    let windowVisibleToUser =
      (window?.isKeyWindow == true)
      && (window?.occlusionState.contains(.visible) ?? false)
    let terminalOutputActive = windowVisibleToUser && terminalOutputActiveUntil > now
    let attentionAnimating =
      windowVisibleToUser && !reduceMotion
      && TabAttentionClassifier.anyNeedsAction(tabs: model.tabs, activeTabId: model.activeTab?.id)
    // The owned blink timer (Stage 1) runs only while blink is enabled in
    // Settings AND the window is visible AND the cursor is visible — exactly
    // the legacy-blink condition the policy's blink floor carries. Blink off
    // (the default) feeds false, so a quiescent focused terminal parks.
    let cursorBlinkActive = blinkDriver.timerRunning
    // An active precise scroll stream keeps the link at the panel rate so
    // the link, not per-event synchronous renders, paces frames (see
    // `preciseScrollStreamActiveUntil`). Same policy lever as a settling
    // scroll animation.
    let preciseScrollStreamActive =
      windowVisibleToUser && preciseScrollStreamActiveUntil > now
    let scrollLinkActive = scrollAnimating || sidebarScrollAnimating || preciseScrollStreamActive
    let shouldRun = TerminalIdlePolicy.displayLinkShouldRun(
      windowVisibleToUser: windowVisibleToUser,
      scrollAnimating: scrollLinkActive,
      attentionAnimating: attentionAnimating,
      terminalOutputActive: terminalOutputActive,
      cursorBlinkActive: cursorBlinkActive,
      idleFloorEnabled: displayLinkIdleFloorEnabled)
    let preferred = TerminalIdlePolicy.preferredDisplayLinkFramesPerSecond(
      windowVisibleToUser: windowVisibleToUser,
      scrollAnimating: scrollLinkActive,
      attentionAnimating: attentionAnimating,
      terminalOutputActive: terminalOutputActive,
      cursorBlinkActive: cursorBlinkActive,
      idleFloorEnabled: displayLinkIdleFloorEnabled)
    let reason: String
    if scrollAnimating {
      reason = "scroll"
    } else if sidebarScrollAnimating {
      reason = "sidebarScroll"
    } else if preciseScrollStreamActive {
      reason = "preciseScroll"
    } else if attentionAnimating {
      reason = "attention"
    } else if terminalOutputActive {
      reason = "terminalOutputActive"
    } else if !windowVisibleToUser {
      reason = "notVisible"
    } else if cursorBlinkActive {
      reason = "cursorBlink"
    } else if displayLinkIdleFloorEnabled {
      reason = "idle"
    } else {
      reason = "parked"
    }
    return DisplayLinkPolicyState(
      windowVisibleToUser: windowVisibleToUser,
      terminalOutputActive: terminalOutputActive,
      attentionAnimating: attentionAnimating,
      scrollAnimating: scrollAnimating,
      cursorBlinkActive: cursorBlinkActive,
      idleFloorEnabled: displayLinkIdleFloorEnabled,
      shouldRun: shouldRun,
      preferredFramesPerSecond: preferred,
      reason: reason)
  }

  deinit {
    stopDisplayLink()
    stopTrackedMouseDragFramePump()
    sessionCoordinator?.stopSnapshotGenerationMonitor()
    removeWindowFocusObservers()
    preciseScrollSettleWork?.cancel()
    resizeBackgroundReset?.cancel()
    if let view = resizeBackgroundView,
      let originalWantsLayer = normalResizeBackgroundWantsLayer
    {
      view.layer?.backgroundColor = normalResizeBackgroundColor
      view.wantsLayer = originalWantsLayer
    }
    frameProbe?.close()
    resizeProbe?.close()
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
    }
    if let reduceMotionObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
    }
    if let cursorSettingsObserver {
      NotificationCenter.default.removeObserver(cursorSettingsObserver)
    }
    if let emojiRenderingObserver {
      NotificationCenter.default.removeObserver(emojiRenderingObserver)
    }
    if let vectorTextWeightObserver {
      NotificationCenter.default.removeObserver(vectorTextWeightObserver)
    }
    if let vectorSmoothScrollObserver {
      NotificationCenter.default.removeObserver(vectorSmoothScrollObserver)
    }
    if let screenParametersObserver {
      NotificationCenter.default.removeObserver(screenParametersObserver)
    }
    if let vectorSubpixelLayoutObserver {
      NotificationCenter.default.removeObserver(vectorSubpixelLayoutObserver)
    }
    if let fontChangeObserver {
      NotificationCenter.default.removeObserver(fontChangeObserver)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if recreateSurface() {
      invalidateRenderAndWake()
    }
  }

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    applyTransientResizeBackground()
  }

  /// Returns true if the surface was actually recreated.
  @discardableResult
  private func recreateSurface() -> Bool {
    let scale = window?.backingScaleFactor ?? 1.0
    let pixW = max(1, Int(ceil(bounds.width * scale)))
    let pixH = max(1, Int(ceil(bounds.height * scale)))
    guard pixW != lastPixelWidth || pixH != lastPixelHeight || scale != lastSurfaceScale else {
      return false
    }
    lastPixelWidth = pixW
    lastPixelHeight = pixH
    lastSurfaceScale = scale
    backend.resize(pixelWidth: pixW, pixelHeight: pixH, scale: scale)
    // Re-evaluate downsample state on every surface change: a backing-scale or
    // screen change can flip whether the framebuffer maps 1:1 onto the panel.
    _ = updateDisplayDownsampledState()
    // Ladder textures were rasterized for the old backing scale; discard and
    // rebuild for the new one (the renderer's own scale-change branch already
    // rebuilt the active size synchronously above).
    if let ladder = atlasLadder, abs(ladder.scale - scale) > 0.0001 {
      atlasLadder = nil
      DispatchQueue.main.async { [weak self] in
        self?.ensureAtlasLadder()
      }
    }
    return true
  }

  /// Detect whether the window's display is in a scaled (downsampled) mode and
  /// push it to the vector backend, whose subpixel auto-policy falls back to
  /// grayscale when downsampled. Returns whether the backend's effective layout
  /// changed (the backend no-ops an unchanged value). Non-vector backends ignore
  /// this — they have no subpixel path.
  @discardableResult
  private func updateDisplayDownsampledState() -> Bool {
    guard let vector = backend as? VectorGlyphRenderer else { return false }
    let downsampled = DisplayDownsampleDetector.isDownsampled(for: window)
    let changed = vector.setDisplayDownsampled(downsampled)
    if changed {
      AppLog.render.info(
        "vector subpixel layout -> \(vector.rendererStatus.vectorSubpixelLayout ?? "?") "
          + "(displayDownsampled=\(downsampled))")
    }
    return changed
  }

  private func carryRenderInvalidationForGPUBackpressure() {
    settingRenderInvalidatedFromGPUBackpressure = true
    defer { settingRenderInvalidatedFromGPUBackpressure = false }
    renderInvalidated = true
    renderInvalidatedFromGPUBackpressureOnly = true
  }

  static func terminalGridOriginY(
    boundsHeight: CGFloat,
    rows: Int,
    cellHeight: CGFloat,
    insets: NSEdgeInsets
  ) -> CGFloat {
    TerminalSurfaceController.terminalGridOriginY(
      viewportHeight: boundsHeight,
      rows: rows,
      cellHeight: cellHeight,
      insets: TerminalSurfaceInsets(
        top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right)
    )
  }

  /// Whether a frame must repaint the whole terminal rather than only its dirty
  /// rows. The attention pulse is deliberately NOT an input: pulse frames
  /// repaint via the renderer's dedicated sidebar-strip pass
  /// (`repaintSidebarStrip`), so a breathing marker costs a ~200 pt strip, not
  /// full-surface repaints at the 120 Hz output link rate — the structural fix
  /// for "typing is molasses whenever a tab needs me". Hover and drag already
  /// set `renderInvalidated`, so they need no entry here.
  nonisolated static func shouldForceFullDamage(
    renderInvalidated: Bool,
    tabChanged: Bool,
    scrollAnimating: Bool,
    fractionalScrollOffset: Bool
  ) -> Bool {
    // fractionalScrollOffset: while rows sit at a sub-cell offset, a
    // partial-damage frame (output, blink, attention) would composite its
    // damaged rows against stale pixels at every undamaged row — the offset
    // shifts everything, so any repaint must be a full repaint.
    renderInvalidated || tabChanged || scrollAnimating
      || fractionalScrollOffset
  }

  // MARK: - Frame loop

  /// Every code path that can wake the frame loop, so the render journal can
  /// attribute each frame to the state change that asked for it. With a fully
  /// parked display link this is the wake-source audit's runtime evidence: a
  /// frozen frame plus a missing expected tag names the broken wake.
  enum FrameWakeSource: String {
    case displayLink
    case sessionDirty
    case labandGeneration
    case keyboard
    case scrollWheel
    case scrollSettle
    case modelMutation
    case focus
    case occlusion
    case settleWake
    case synchronizedOutputWake
    case renderRetry
    case blinkTimer
    case safetyNet
    case other
  }

  /// Compatibility shim for selector-based and untagged callers; counts as a
  /// generic wake. Tagged paths call `advanceFrame(wake:)` directly.
  @objc func advanceFrame() {
    advanceFrame(wake: .other)
  }

  func advanceFrame(wake: FrameWakeSource) {
    advanceFrameCallCountForTesting += 1
    lastWakeSource = wake
    IdleCounters.shared.noteAdvanceFrame()
    // Heartbeat the stall watchdog at the top of every tick. If
    // advanceFrame stops returning (or takes very long), the background
    // watchdog will spot the gap and snapshot our threads via sample(1).
    MainThreadWatchdog.shared.heartbeat()

    // Reconcile the display-link run state on every frame, on all exit paths
    // (including the idle early-return below). A window that is no longer
    // visible to the user parks the link — background output still reaches the
    // screen through the onSessionDirty push — so a backgrounded terminal stops
    // waking the CPU at refresh cadence. Waking again is driven by the key and
    // occlusion observers in installWindowFocusObservers.
    defer { updateDisplayLinkRunState() }

    let captureFrame = renderedFrameCount + 1
    let sync = surfaceController.syncSessions(
      captureFrame: captureFrame,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true)
    frameModelChanged = sync.modelChanged
    if sync.modelChanged {
      renderInvalidated = true
    }
    let usingRemoteSessions = sessionCoordinator?.usesRemoteSnapshots == true
    var activeTerminalDirty = usingRemoteSessions ? false : sync.activeTerminalDirty

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else {
      onViewportUnavailable?()
      return
    }
    // Only worth building when the journal can record it: the interpolation
    // otherwise burns CPU on every display-link tick of an idle terminal.
    frameMetadataSignature =
      renderJournalEnabled ? renderJournalMetadataSignature(for: activeTab) : nil

    let windowTitle =
      model.windowTitle + TerminalCaptureIndicator.windowTitleSuffix(active: isCaptureActive)
    if windowTitle != lastAppliedWindowTitle {
      window?.title = windowTitle
      lastAppliedWindowTitle = windowTitle
    }
    updateCaptureIndicator()

    let tabChanged = lastRenderedActiveTabId != activeTab.id
    if tabChanged,
      let outgoing = lastRenderedActiveTabId,
      let outgoingTab = model.tabs.first(where: { $0.id == outgoing }),
      let outgoingSession = model.session(forTab: outgoing)
    {
      reportFocus(to: outgoingSession, tab: outgoingTab, focused: false)
    }
    syncActiveSessionFocus(windowFocused: window?.isKeyWindow == true)

    let windowVisibleToUser =
      (window?.isKeyWindow == true)
      && (window?.occlusionState.contains(.visible) ?? false)
    // cursorBlinkFrame is true when the driver fired a phase flip since the
    // last advanceFrame call. The driver's onPhaseFlip closure also calls
    // advanceFrame() directly so a flip always paints immediately rather than
    // waiting up to 125 ms for the next 8 Hz display-link tick. Here we only
    // consume the pending-flip flag to record it in the journal and allow the
    // guard below to proceed even when the display link is parked.
    let cursorBlinkFrame = blinkDriver.consumePendingFlip()

    // Tab change interrupts any in-flight scroll animation: snap the
    // displayed position to whatever the new session is showing so the PD
    // controller doesn't keep ticking against the wrong viewport.
    if tabChanged {
      resetSmoothScrollState(to: authoritativeAppliedRows(for: session) ?? 0)
      ensureSidebarTabVisible(activeTab.id, animated: true)
      lastParkSignature = nil
      syncSelectionStateToActiveTab()
      // Drop the shared overlay indicator's outgoing-tab state before the new
      // tab's first viewport sample so it can't flash the previous thumb.
      onActiveTabChanged?()
    }

    // Critically-damped PD controller. Drives `displayedScrollRows` toward
    // `targetScrollRows`. Each frame we:
    //   - integrate the controller with the real wall-clock dt (so the
    //     animation lands at the same wall-clock duration whether the
    //     display ticks at 60 or 120 Hz)
    //   - apply the integer change to libghostty's viewport
    //   - leave the fractional remainder for the renderer's contentYOffset
    var scrollAnimating = false
    let scrollError = targetScrollRows - displayedScrollRows
    if abs(scrollError) > 0.001 || abs(scrollVelocityRowsPerSec) > 0.001 {
      let now = ContinuousClock.now
      let dt: Double
      if let last = lastScrollTickAt {
        let dur = now - last
        // No lower clamp: every advanceFrame call is a controller tick, and
        // wakes from other subsystems (PTY feeds, blink flips) can land
        // sub-millisecond after a link tick. Inflating those gaps to a fake
        // minimum advances simulated time faster than wall time and wobbles
        // the chase velocity; the closed-form update is exact at any dt, so
        // a near-zero gap simply advances the position by near-zero.
        dt = max(0, min(1.0 / 30.0, Double(dur.components.attoseconds) / 1e18))
      } else {
        dt = 1.0 / 120.0
      }
      lastScrollTickAt = now

      // Stiffness: the precise-input resampler scales ω with input speed
      // (slow input gets smoothed past macOS's whole-point delta quantum,
      // fast input stays glued to the finger); everything else keeps the
      // fixed glide tuning.
      let omega =
        preciseScrollStreamActiveUntil > Date()
        ? TerminalScrollInput.adaptiveScrollOmega(
          inputRowsPerSec: preciseInputRowsPerSec, baseOmega: Self.scrollOmega)
        : Self.scrollOmega
      // Closed-form critically-damped update (exact, unconditionally stable
      // for any ω·dt — explicit Euler diverges past ω·dt ≈ 2, which the
      // speed-adaptive stiffness can exceed at clamped dt):
      //   err(t) = (e0 + (v0 + ω·e0)·t)·e^(−ω·t),  err = displayed − target
      let e0 = -scrollError
      let c2 = scrollVelocityRowsPerSec + omega * e0
      let decay = exp(-omega * dt)
      displayedScrollRows = targetScrollRows + (e0 + c2 * dt) * decay
      scrollVelocityRowsPerSec = (c2 - omega * (e0 + c2 * dt)) * decay

      // Snap once we're close enough that further integration is noise.
      if abs(targetScrollRows - displayedScrollRows) < 0.01,
        abs(scrollVelocityRowsPerSec) < 0.1
      {
        displayedScrollRows = targetScrollRows
        scrollVelocityRowsPerSec = 0
      }

      // gestureDesiredAppliedRows holds the applied rows at ≤ -1 while the
      // target is in history: rounding a sub-half-row displayed position to
      // 0 would route through the active-bottom snap, whose state reset
      // kills the animation (and, mid-gesture, the accumulated input).
      let desiredApplied = TerminalScrollInput.gestureDesiredAppliedRows(
        displayedRows: displayedScrollRows, targetRows: targetScrollRows)
      let appliedBefore = appliedScrollRows
      applyScrollStep(
        toDesiredApplied: desiredApplied,
        tab: activeTab,
        session: session,
        resetOnClamp: false)

      renderInvalidated = true
      // The grid content only changes when the integer viewport moved;
      // fraction-only ticks repaint the cached grid at a new sub-cell
      // offset. Marking the terminal dirty on every tick forces the full
      // snapshot/production path ~120 times a second for the whole length
      // of a gesture, which costs enough per frame to halve the render
      // cadence on a 120 Hz panel.
      if appliedScrollRows != appliedBefore {
        activeTerminalDirty = true
      }
      scrollAnimating = true
    } else {
      lastScrollTickAt = nil
    }
    self.scrollAnimating = scrollAnimating

    var remoteFrame: LabandSnapshotFrame?
    if let sessionCoordinator, sessionCoordinator.usesRemoteSnapshots {
      do {
        let remoteGeneration = try sessionCoordinator.snapshotGeneration(
          for: activeTab,
          size: model.terminalSize)
        activeTerminalDirty =
          activeTerminalDirty
          || remoteSnapshotRenderTracker.terminalDirty(
            tabId: activeTab.id,
            generation: remoteGeneration,
            fallbackDirty: true)
        if activeTerminalDirty {
          remoteFrame = try sessionCoordinator.snapshotFrame(
            for: activeTab,
            size: model.terminalSize)
          activeTerminalDirty =
            activeTerminalDirty
            || remoteSnapshotRenderTracker.terminalDirty(
              tabId: activeTab.id,
              generation: remoteFrame?.generation,
              fallbackDirty: remoteFrame?.snapshot.dirty ?? false)
        }
      } catch {
        remoteFrame = nil
        remoteMouseEncodingByTab.removeValue(forKey: activeTab.id)
        AppLog.app.error("laband snapshot failed: \(String(describing: error))")
      }
    } else {
      remoteFrame = nil
      remoteMouseEncodingByTab.removeAll()
    }
    if let remoteFrame {
      cacheRemoteMouseEncoding(remoteFrame.snapshot, for: activeTab.id)
    }

    let terminalDirty = activeTerminalDirty || (!usingRemoteSessions && session.renderDirty())

    let gateNow = Date()
    if terminalDirty {
      terminalOutputActiveUntil = gateNow.addingTimeInterval(
        Self.terminalOutputDisplayLinkHoldSeconds)
    }
    // On the daemon (laband) tier the local Session is fixture-mode and never
    // sees the program's BSU/ESU, so synchronized-output state must come from the
    // published snapshot's flag — otherwise the gate is inert and clients show
    // half-drawn frames. In-process keeps reading the live VT.
    let synchronizedOutputActive: Bool
    if let remoteFrame {
      synchronizedOutputActive = remoteFrame.snapshot.synchronizedOutput ?? false
    } else {
      synchronizedOutputActive = session.synchronizedOutputActive
    }
    let syncGate = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: terminalDirty,
      synchronizedOutputActive: synchronizedOutputActive,
      sessionId: session.id,
      now: gateNow,
      hold: synchronizedOutputHold)
    synchronizedOutputHold = syncGate.hold
    if syncGate.shouldResetMode {
      _ = session.resetSynchronizedOutput()
    }
    if syncGate.shouldDefer {
      // Hold the previous completed frame during DEC synchronized output. Laban
      // uses libghostty-vt without Ghostty's termio timer, so this mirrors
      // Ghostty's one-second watchdog before rendering anyway. Schedule a re-wake
      // so the watchdog is reached even if the display link parks mid-hold.
      scheduleSynchronizedOutputWake(
        after: syncGate.wakeAfter ?? TerminalRenderGate.synchronizedOutputMaxHoldSeconds)
      recordRenderJournal(
        event: .skipped,
        frame: captureFrame,
        tab: activeTab,
        session: session,
        reason: "synchronizedOutputDefer",
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: false,
        scrollAnimating: scrollAnimating,
        usingRemoteSnapshots: usingRemoteSessions,
        cellPayloadRequested: false,
        contentYOffset: 0)
      return
    }

    // PTY output often arrives as related fragments that together form one
    // visual update. Rendering between fragments can expose transient parser
    // states, so wait for a short quiet window while bounding the hold for
    // continuous output.
    if !tabChanged && !scrollAnimating && !renderingResizeFrame {
      let settleGate = TerminalRenderGate.outputSettleDecision(
        terminalDirty: terminalDirty,
        sessionId: session.id,
        lastDirtyAt: remoteFrame?.snapshotPublishedAt(now: gateNow)
          ?? displayKickCoalescer.latestDirtyAt(),
        now: gateNow,
        hold: outputSettleHold,
        quiet: TerminalRenderGate.settleQuietSeconds(
          remoteDirtyRanges: remoteFrame?.dirtyRanges))
      outputSettleHold = settleGate.hold
      if settleGate.shouldDefer {
        scheduleOutputSettleWake(
          after: settleGate.wakeAfter ?? TerminalRenderGate.outputSettleQuietSeconds)
        recordRenderJournal(
          event: .skipped,
          frame: captureFrame,
          tab: activeTab,
          session: session,
          reason: "outputSettleDefer",
          terminalDirty: terminalDirty,
          activeTerminalDirty: activeTerminalDirty,
          renderInvalidated: renderInvalidated,
          tabChanged: tabChanged,
          cursorBlinkFrame: cursorBlinkFrame,
          attentionAnimating: false,
          scrollAnimating: scrollAnimating,
          usingRemoteSnapshots: usingRemoteSessions,
          cellPayloadRequested: false,
          contentYOffset: 0)
        return
      }
    } else {
      outputSettleHold = nil
    }

    // Track when each tab entered needsAction. The announce-once timeline
    // (entrance bloom → static rest → gentle re-ping) animates only inside
    // its windows, so the link parks for the long rests between pings instead
    // of ticking the whole time a tab waits. Cheap: field-only classification.
    let attentionNow = Date()
    var attentionLive: Set<Tab.ID> = []
    for tab in model.tabs
    where TabAttentionClassifier.classify(tab.titleMetadata, isActive: tab.id == activeTab.id)
      == .needsAction
    {
      attentionLive.insert(tab.id)
      if attentionEntryTimes[tab.id] == nil { attentionEntryTimes[tab.id] = attentionNow }
    }
    if !attentionEntryTimes.isEmpty {
      attentionEntryTimes = attentionEntryTimes.filter { attentionLive.contains($0.key) }
    }
    let attentionAnimating =
      windowVisibleToUser && !reduceMotion
      && attentionEntryTimes.values.contains {
        AttentionPulse.isAnimating(elapsed: attentionNow.timeIntervalSince($0))
      }
    // A resting marker needs no frames, but the next re-ping must still
    // arrive after the link parks: schedule a one-shot wake for the earliest
    // upcoming animation window.
    if !attentionEntryTimes.isEmpty, !attentionAnimating, windowVisibleToUser, !reduceMotion {
      let delay =
        attentionEntryTimes.values
        .map { AttentionPulse.delayToNextAnimation(elapsed: attentionNow.timeIntervalSince($0)) }
        .min() ?? 0
      scheduleAttentionPingWake(after: delay + 0.02)
    }
    // Animation frames plus one trailing frame after the window closes, so
    // the marker's final state lands on glass instead of freezing mid-step.
    let attentionStripFrame = attentionAnimating || attentionWasAnimating
    attentionWasAnimating = attentionAnimating

    // Return early when nothing changed
    guard
      terminalDirty || renderInvalidated || tabChanged || cursorBlinkFrame
        || attentionStripFrame || sidebarScrollAnimating
    else {
      recordParkedFrameIfInteresting(
        frame: captureFrame,
        tab: activeTab,
        session: session,
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: attentionAnimating,
        scrollAnimating: scrollAnimating,
        usingRemoteSnapshots: usingRemoteSessions)
      return
    }

    captureRecorder?.record(CaptureTimelineEvent(kind: .frameBegin, frame: captureFrame))

    let h = bounds.height

    let insets = Self.contentInsets
    let metalRenderer = backend as? MetalRenderer
    let surfaceScale = max(1, CGFloat(backend.surfaceScale))
    let sidebarScrollFrame = advanceSidebarScrollFrame(surfaceScale: surfaceScale)

    // Sub-cell pixel offset for smooth scroll. Fractional remainder of the
    // PD-controlled displayed position is rendered as a vertical pixel
    // shift on the terminal cells. Sign: FrameProducer's cell coordinates
    // are Y-up (`cellY = originY + (rows-1-row)*ch + offset`), and the
    // continuity requirement fixes the sign — rendering the same `displayed`
    // position through adjacent applied/fraction splits must place the same
    // content line at the same screen Y, which holds only for
    // `+subCellRows * cellHeight`. The previous negative sign made the glass
    // creep half a row backward through each fraction sweep and leap two
    // rows at every applied step (invisible at ≥1 row/frame, a sawtooth at
    // slow momentum tails). Zero when no scroll is in flight.
    let subCellRows = displayedScrollRows - Double(appliedScrollRows)
    // Snapped to whole device pixels so glyphs never rasterize at subpixel
    // positions while content is in motion (text stays sharp mid-scroll).
    let scrollContentYDevicePixels = CGFloat(subCellRows) * CGFloat(cellHeight) * surfaceScale
    let scrollContentYDeviceSnapped = scrollContentYDevicePixels.rounded()
    let scrollContentYOffset = scrollContentYDeviceSnapped / surfaceScale
    // The signed sub-pixel remainder that snapping discards (∈ [-0.5, 0.5] device
    // px). The vector backend bakes this into its per-phase glyph masks (M4) so
    // smooth scroll glides sub-pixel while the snapped quad stays pixel-crisp;
    // the classic path ignores it and renders the snapped offset only.
    let scrollSubpixelRemainderPoints =
      (scrollContentYDevicePixels - scrollContentYDeviceSnapped) / surfaceScale
    (backend as? VectorGlyphRenderer)?.setScrollPhaseOffset(
      CGPoint(x: 0, y: scrollSubpixelRemainderPoints))
    // Resampled scroll frames are drop-don't-block: when the present
    // pipeline is at capacity, skipping this tick costs nothing (the next
    // tick repaints from newer state) while blocking on it delays the next
    // tick and halves the cadence. Only scroll animation frames opt in —
    // output-driven frames keep the blocking guarantees.
    metalRenderer?.dropNextFrameWhenBusy =
      scrollAnimating || subCellRows != 0 || sidebarScrollFrame.animating
    // Attention pulse frames repaint the sidebar in the renderer's dedicated
    // scissored strip pass instead of forcing full-damage terminal repaints.
    // (The software backend ignores damage and repaints every command, so it
    // needs no flag — reaching the render call below is enough.)
    let sidebarStripFrame = attentionStripFrame || sidebarScrollFrame.animating
    metalRenderer?.repaintSidebarStrip = sidebarStripFrame
    if let metalRenderer, drawableWakeInstalledRenderer !== metalRenderer {
      drawableWakeInstalledRenderer = metalRenderer
      metalRenderer.onDrawableReadyAfterMiss = { [weak self] in
        DispatchQueue.main.async {
          self?.advanceFrame(wake: .renderRetry)
        }
      }
    }
    let gpuCellRequested = metalRenderer?.requestedRendererMode == .gpuDriven
    let rendererFallbackReason =
      usingRemoteSessions && gpuCellRequested ? "remoteSnapshotPayloadIncomplete" : nil
    let canRequestCellPayload =
      !usingRemoteSessions
      && captureRecorder == nil
      && frameProbe == nil
      && metalRenderer?.effectiveRendererMode == .gpuDriven
      && !gpuCellCommandFallbackPending
    let request = TerminalSurfaceFrameRequest(
      frame: captureFrame,
      viewportWidth: bounds.width,
      viewportHeight: h,
      insets: TerminalSurfaceInsets(
        top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right),
      sidebarTopInset: Self.titlebarReservedHeight,
      sidebarScrollOffset: sidebarScrollFrame.offset,
      hoveredSidebarTabId: hoveredSidebarTabId,
      sidebarDragIndicator: sidebarDragIndicator,
      contentYOffset: scrollContentYOffset,
      cursorBlinkVisible: blinkDriver.phaseVisible,
      now: Date(),
      reduceMotion: reduceMotion,
      accessibilityVisualOptions: TerminalAccessibilityVisualOptions(
        increaseContrast: accessibilityDisplayOptions.increaseContrast,
        differentiateWithoutColor: accessibilityDisplayOptions.differentiateWithoutColor,
        reduceTransparency: accessibilityDisplayOptions.reduceTransparency),
      selection: currentTerminalSelection(sessionId: session.id),
      includeTerminalAreaBackground: true,
      requireActiveSnapshot: true,
      forceFullDamage: Self.shouldForceFullDamage(
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        scrollAnimating: scrollAnimating,
        fractionalScrollOffset: subCellRows != 0),
      surfaceWidth: backend.surfaceWidth,
      surfaceHeight: backend.surfaceHeight,
      surfaceScale: Double(backend.surfaceScale),
      contentMode: canRequestCellPayload ? .cellPayloadPreferred : .commands,
      preedit: hasMarkedText() ? markedText.string : nil,
      preeditCaretCells: hasMarkedText() ? markedTextCaretCells : 0,
      userCursorStyle: CursorSettings.style,
      userCursorBlinkEnabled: CursorSettings.blinkEnabled
    )
    if remoteFrame == nil, let sessionCoordinator, sessionCoordinator.usesRemoteSnapshots {
      do {
        remoteFrame = try sessionCoordinator.snapshotFrame(for: activeTab, size: model.terminalSize)
        if let snapshot = remoteFrame?.snapshot {
          cacheRemoteMouseEncoding(snapshot, for: activeTab.id)
        }
      } catch {
        remoteMouseEncodingByTab.removeValue(forKey: activeTab.id)
        AppLog.app.error("laband snapshot failed: \(String(describing: error))")
        return
      }
    }
    // Pull title + foreground-process metadata back from the daemon so the
    // sidebar shows real per-tab info ("claude", "vim", repo cwd, ...) in
    // background-session mode. Throttled inside the coordinator (~4 Hz), but
    // skipped entirely while the window is not visible to the user: it only
    // feeds the sidebar/title (which nobody can see when covered or
    // tabbed-away), and the libproc argv+environment read it performs is a
    // measurable idle cost. A fresh refresh runs on the next frame after the
    // window becomes visible again — the key/occlusion observers wake us, and
    // the coordinator's throttle is stale by then so it is not skipped. The
    // separate AgentSessionDetector keeps running so a backgrounded agent
    // session is still attributed for restore.
    if windowVisibleToUser {
      sessionCoordinator?.refreshTabMetadata(for: model.tabs, into: model)
    }
    let surfaceFrame: TerminalSurfaceFrame?
    if let remoteFrame {
      surfaceFrame = surfaceController.makeFrame(
        request,
        remoteSnapshot: remoteFrame.snapshot,
        sessionId: session.id,
        dirtyRanges: remoteFrame.dirtyRanges)
    } else {
      surfaceFrame = surfaceController.makeFrame(
        request,
        snapshotCommandsHook: snapshotCommandsHook(captureFrame: captureFrame))
    }
    guard let surfaceFrame else {
      recordRenderJournal(
        event: .skipped,
        frame: captureFrame,
        tab: activeTab,
        session: session,
        reason: "surfaceFrameUnavailable",
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: attentionAnimating,
        scrollAnimating: scrollAnimating,
        usingRemoteSnapshots: usingRemoteSessions,
        cellPayloadRequested: canRequestCellPayload,
        contentYOffset: scrollContentYOffset)
      return
    }

    lastRows = surfaceFrame.rows ?? lastRows
    let snapshotCursorBlinking = surfaceFrame.cursorBlinking
    lastRenderedCursorBlinking = snapshotCursorBlinking
    blinkDriver.sync(
      blinkActive: snapshotCursorBlinking,
      windowVisibleToUser: windowVisibleToUser,
      cursorVisible: surfaceFrame.cursorVisible)
    let cmds = surfaceFrame.commands + surfaceFrame.overlayCommands
    // Compute damage hint from libghostty's per-row dirty bits. Tab changes
    // and renderInvalidated force .full because we may be drawing different
    // content into the persistent target. Otherwise translate dirty rows
    // into CG-point Y bands matching the FrameProducer's row→y mapping
    // (originY + (rows-1-row) * cellHeight, height = cellHeight).
    //
    // Smooth-scroll forces .full while animating: the persistent target
    // holds last frame's pixels at the previous fractional position, so
    // partial damage would leave stale pixels at the new sub-cell offset.
    guard
      backend.render(
        cmds,
        cellPayload: surfaceFrame.cellPayload,
        damage: surfaceFrame.damage,
        rendererFallbackReason: rendererFallbackReason)
    else {
      recordRenderJournal(
        event: .renderFailed,
        frame: captureFrame,
        tab: activeTab,
        session: session,
        reason: "backendRenderReturnedFalse",
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: attentionAnimating,
        scrollAnimating: scrollAnimating,
        usingRemoteSnapshots: usingRemoteSessions,
        cellPayloadRequested: canRequestCellPayload,
        contentYOffset: scrollContentYOffset,
        surfaceFrame: surfaceFrame,
        commands: cmds,
        rendered: false)
      sampleGPUFreezeDetector(
        frame: captureFrame,
        tab: activeTab,
        session: session,
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: attentionAnimating,
        scrollAnimating: scrollAnimating,
        usingRemoteSnapshots: usingRemoteSessions,
        cellPayloadRequested: canRequestCellPayload,
        contentYOffset: scrollContentYOffset,
        surfaceFrame: surfaceFrame,
        commands: cmds,
        rendered: false)
      if let payloadFailure = (backend as? MetalRenderer)?.lastGPUCellPayloadBuildFailure {
        autoDumpGPUCellPayloadFailure(payloadFailure)
      }
      let failureReason = (backend as? MetalRenderer)?.lastRenderFailureReason
      // GPU/compositor backpressure gets one display-link-paced retry. If that
      // retry finds no work except the carried invalidation, park instead of
      // sustaining a no-progress render loop.
      if failureReason?.isGPUBackpressure == true {
        let decision = TerminalRenderGate.backpressureInvalidationDecision(
          renderInvalidated: renderInvalidated,
          renderInvalidatedFromGPUBackpressureOnly: renderInvalidatedFromGPUBackpressureOnly,
          terminalDirty: terminalDirty,
          activeTerminalDirty: activeTerminalDirty,
          tabChanged: tabChanged,
          cursorBlinkFrame: cursorBlinkFrame,
          attentionAnimating: attentionAnimating,
          scrollAnimating: scrollAnimating,
          renderingResizeFrame: renderingResizeFrame,
          gpuCellCommandFallbackPending: gpuCellCommandFallbackPending)
        if decision.shouldPark {
          renderInvalidated = false
        } else {
          carryRenderInvalidationForGPUBackpressure()
          // The "display-link-paced retry" above only exists while the link
          // runs. A tabChanged-only or fallback-pending-only failure on an
          // otherwise-quiescent window parks the link (the policy does not
          // consider renderInvalidated), stranding the carried invalidation
          // until an unrelated wake — M2-5 review finding F2. Schedule the
          // one-shot retry ourselves exactly in that case; while the link
          // keeps running we stay link-paced, preserving the anti-amplification
          // behavior the GPU-freeze plan introduced (an unconditional
          // immediate retry is what turned one slow drawable into bursts).
          if !displayLinkPolicyState().shouldRun {
            scheduleRenderRetry()
          }
        }
      } else {
        renderInvalidated = true
        if surfaceFrame.cellPayload != nil,
          failureReason == .fullRedrawProducedNoContent
        {
          gpuCellCommandFallbackPending = true
        }
        scheduleRenderRetry()
      }
      return
    }
    recordRenderJournal(
      event: .rendered,
      frame: captureFrame,
      tab: activeTab,
      session: session,
      reason: nil,
      terminalDirty: terminalDirty,
      activeTerminalDirty: activeTerminalDirty,
      renderInvalidated: renderInvalidated,
      tabChanged: tabChanged,
      cursorBlinkFrame: cursorBlinkFrame,
      attentionAnimating: attentionAnimating,
      scrollAnimating: scrollAnimating,
      usingRemoteSnapshots: usingRemoteSessions,
      cellPayloadRequested: canRequestCellPayload,
      contentYOffset: scrollContentYOffset,
      surfaceFrame: surfaceFrame,
      commands: cmds,
      rendered: true)
    sampleGPUFreezeDetector(
      frame: captureFrame,
      tab: activeTab,
      session: session,
      terminalDirty: terminalDirty,
      activeTerminalDirty: activeTerminalDirty,
      renderInvalidated: renderInvalidated,
      tabChanged: tabChanged,
      cursorBlinkFrame: cursorBlinkFrame,
      attentionAnimating: attentionAnimating,
      scrollAnimating: scrollAnimating,
      usingRemoteSnapshots: usingRemoteSessions,
      cellPayloadRequested: canRequestCellPayload,
      contentYOffset: scrollContentYOffset,
      surfaceFrame: surfaceFrame,
      commands: cmds,
      rendered: true)
    renderedFrameCount = captureFrame
    if let recorder = captureRecorder {
      // Both software and Metal flow through the same recorder entry now.
      // Pulling pngData triggers a CGImage realisation on software and a
      // blit-readback on Metal — equivalent capture sidecars either way.
      recorder.recordRenderedFrame(
        frame: captureFrame,
        pngData: backend.pngData,
        width: backend.surfaceWidth,
        height: backend.surfaceHeight,
        scale: Double(backend.surfaceScale),
        backend: backend.rendererStatus.effectiveRenderer)
    }
    if !backendSelfPresents {
      needsDisplay = true
    }

    if let sessionCoordinator, sessionCoordinator.usesRemoteSnapshots {
      sessionCoordinator.markRendered(tab: activeTab)
      remoteSnapshotRenderTracker.markRendered(
        tabId: activeTab.id,
        generation: remoteFrame?.generation)
      session.markRendered()
    } else {
      session.markRendered()
    }
    gpuCellCommandFallbackPending = false
    renderInvalidated = false
    lastRenderedActiveTabId = activeTab.id
    syncFindChip()

    if let vs = session.viewportState() {
      let reportedMouseTracking = mouseTrackingActive(for: activeTab, session: session)
      onViewportChanged?(
        vs.viewportOffset, vs.totalRows, vs.viewportRows, vs.altScreen, reportedMouseTracking)
      if ScrollDiagnostics.shared.isEnabled {
        // The exact numbers the overlay indicator decides on, paired with the
        // view's own scroll belief and window focus. If `linesBack > 0` here
        // while `applied == 0` and the window is focused, the view thinks it is
        // pinned to the bottom but libghostty disagrees — the labpty drift.
        ScrollDiagnostics.shared.sample(
          kind: "sample",
          off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows,
          sb: vs.scrollbackRows, alt: vs.altScreen, mouse: vs.mouseTracking,
          focused: window?.isKeyWindow == true,
          applied: appliedScrollRows,
          displayed: displayedScrollRows,
          target: targetScrollRows,
          animating: scrollAnimating)
      }
    } else {
      onViewportUnavailable?()
    }
  }

  /// Compact fingerprint of the active tab's surface metadata. Each component is
  /// a source that can flip `syncSessions`' `modelChanged` (and thus re-assert
  /// `renderInvalidated`); diffing the fingerprint across consecutive journal
  /// entries shows which one keeps an idle terminal redrawing. A stable
  /// fingerprint while `modelChanged` stays true points at process-metadata
  /// churn that does not surface in `titleMetadata`.
  private func renderJournalMetadataSignature(for tab: Tab) -> String {
    let m = tab.titleMetadata
    let agent = m.agentStatus
    return [
      "title=\(m.terminalTitle ?? "")",
      "cwd=\(m.workspace.cwd ?? "")",
      "branch=\(m.workspace.branch ?? "")",
      "agent=\(agent.indicatorColor ?? "")/\(agent.statusText ?? "")",
      "shell=\(m.shellPhase.rawValue)",
      "exit=\(m.lastCommandExitCode.map(String.init) ?? "")",
    ].joined(separator: " ")
  }

  /// Journal the idle early-return in `advanceFrame`, but only when the park is
  /// diagnostically interesting: the viewport is off the live bottom (the
  /// "scrolled down but the final frame never landed" signature) and we have not
  /// already logged this scroll position. The entry carries the full
  /// scroll/viewport snapshot and the `renderInvalidated` flag (always false
  /// here, since the loop only parks when nothing asked to draw), so a dropped
  /// scroll-to-bottom trigger shows up as a `noFrameNeeded` park at a negative
  /// applied-rows position rather than a `rendered` entry at the bottom.
  private func recordParkedFrameIfInteresting(
    frame: Int,
    tab: Tab,
    session: Session,
    terminalDirty: Bool,
    activeTerminalDirty: Bool,
    tabChanged: Bool,
    cursorBlinkFrame: Bool,
    attentionAnimating: Bool,
    scrollAnimating: Bool,
    usingRemoteSnapshots: Bool
  ) {
    guard renderJournalEnabled else { return }
    let decision = TerminalRenderGate.parkedFrameDecision(
      appliedScrollRows: appliedScrollRows,
      lastParkSignature: lastParkSignature)
    lastParkSignature = decision.signature
    guard decision.shouldRecord else { return }
    recordRenderJournal(
      event: .skipped,
      frame: frame,
      tab: tab,
      session: session,
      reason: "noFrameNeeded",
      terminalDirty: terminalDirty,
      activeTerminalDirty: activeTerminalDirty,
      renderInvalidated: renderInvalidated,
      tabChanged: tabChanged,
      cursorBlinkFrame: cursorBlinkFrame,
      attentionAnimating: attentionAnimating,
      scrollAnimating: scrollAnimating,
      usingRemoteSnapshots: usingRemoteSnapshots,
      cellPayloadRequested: false,
      contentYOffset: 0)
  }

  private func recordRenderJournal(
    event: RenderJournal.Event,
    frame: Int,
    tab: Tab,
    session: Session,
    reason: String?,
    terminalDirty: Bool,
    activeTerminalDirty: Bool,
    renderInvalidated: Bool,
    tabChanged: Bool,
    cursorBlinkFrame: Bool,
    attentionAnimating: Bool,
    scrollAnimating: Bool,
    usingRemoteSnapshots: Bool,
    cellPayloadRequested: Bool,
    contentYOffset: CGFloat,
    surfaceFrame: TerminalSurfaceFrame? = nil,
    commands: [FrameCommand]? = nil,
    freeze: RenderJournal.FreezeSnapshot? = nil,
    rendered: Bool? = nil
  ) {
    guard renderJournalEnabled else { return }
    let metalRenderer = backend as? MetalRenderer
    let includesMetalFailureDetails = event == .renderFailed || event == .freezeDetected
    let gpuCellPayloadFailure =
      includesMetalFailureDetails ? metalRenderer?.lastGPUCellPayloadBuildFailure : nil
    let renderFailureReason =
      includesMetalFailureDetails ? metalRenderer?.lastRenderFailureReason : nil
    let commandList = surfaceFrame?.commands ?? commands
    let overlayCommands = surfaceFrame?.overlayCommands ?? []
    let entry = renderJournal.makeEntry(
      event: event,
      frame: frame,
      tabId: tab.id,
      sessionId: session.id,
      reason: reason,
      wakeSource: lastWakeSource.rawValue,
      transportMode: sessionCoordinator?.transportMode ?? "in-process",
      rendererStatus: backend.rendererStatus,
      surface: renderJournalSurfaceSnapshot(),
      window: renderJournalWindowSnapshot(),
      displayLink: renderJournalDisplayLinkSnapshot(),
      frameState: RenderJournal.FrameStateSnapshot(
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        cursorBlinkFrame: cursorBlinkFrame,
        attentionAnimating: attentionAnimating,
        scrollAnimating: scrollAnimating,
        renderingResizeFrame: renderingResizeFrame,
        usingRemoteSnapshots: usingRemoteSnapshots,
        gpuCellRequested: metalRenderer?.requestedRendererMode == .gpuDriven,
        cellPayloadRequested: cellPayloadRequested,
        gpuCellCommandFallbackPending: gpuCellCommandFallbackPending,
        modelChanged: frameModelChanged,
        metadataSignature: frameMetadataSignature,
        cursorBlinkTimerActive: blinkDriver.timerRunning),
      viewport: renderJournalViewportSnapshot(for: session),
      scroll: renderJournalScrollSnapshot(contentYOffset: contentYOffset),
      damage: surfaceFrame?.damage,
      commands: commandList,
      overlayCommands: overlayCommands,
      payload: surfaceFrame?.cellPayload,
      diagnostics: surfaceFrame?.diagnostics,
      metalInstances: metalRenderer?.lastInstanceCounts,
      drawableAcquire: metalRenderer?.lastDrawableAcquireDiagnostic,
      gpuCellPayloadFailure: gpuCellPayloadFailure,
      renderFailureReason: renderFailureReason,
      freeze: freeze,
      rendered: rendered)
    renderJournal.record(entry)
  }

  private func sampleGPUFreezeDetector(
    frame: Int,
    tab: Tab,
    session: Session,
    terminalDirty: Bool,
    activeTerminalDirty: Bool,
    renderInvalidated: Bool,
    tabChanged: Bool,
    cursorBlinkFrame: Bool,
    attentionAnimating: Bool,
    scrollAnimating: Bool,
    usingRemoteSnapshots: Bool,
    cellPayloadRequested: Bool,
    contentYOffset: CGFloat,
    surfaceFrame: TerminalSurfaceFrame?,
    commands: [FrameCommand]?,
    rendered: Bool
  ) {
    guard gpuFreezeAutoDumpEnabled else { return }
    let rendererStatus = backend.rendererStatus
    let gpuDriven = rendererStatus.effectiveRenderer == RendererMode.gpuDriven.rawValue
    let detection = gpuFreezeDetector.sample(
      GPURenderFreezeDetector.Sample(
        frame: frame,
        tabId: tab.id,
        sessionId: session.id,
        gpuDriven: gpuDriven,
        terminalDirty: terminalDirty,
        activeTerminalDirty: activeTerminalDirty,
        renderInvalidated: renderInvalidated,
        tabChanged: tabChanged,
        scrollAnimating: scrollAnimating,
        rendered: rendered,
        renderFailureReason: (backend as? MetalRenderer)?.lastRenderFailureReason,
        metalFrameCompletions: gpuFrameCompletionCount,
        now: Date()))
    guard let detection else { return }

    recordRenderJournal(
      event: .freezeDetected,
      frame: frame,
      tab: tab,
      session: session,
      reason: detection.freeze.reason,
      terminalDirty: terminalDirty,
      activeTerminalDirty: activeTerminalDirty,
      renderInvalidated: renderInvalidated,
      tabChanged: tabChanged,
      cursorBlinkFrame: cursorBlinkFrame,
      attentionAnimating: attentionAnimating,
      scrollAnimating: scrollAnimating,
      usingRemoteSnapshots: usingRemoteSnapshots,
      cellPayloadRequested: cellPayloadRequested,
      contentYOffset: contentYOffset,
      surfaceFrame: surfaceFrame,
      commands: commands,
      freeze: detection.freeze,
      rendered: rendered)
    autoDumpGPUFreeze(detection)
  }

  private func autoDumpGPUFreeze(_ detection: GPURenderFreezeDetector.Detection) {
    guard renderJournalEnabled else { return }
    var payload: [String: Any] = [
      "reason": detection.freeze.reason,
      "streak": detection.freeze.noProgressStreak,
      "metalFrameCompletions": detection.freeze.metalFrameCompletions,
    ]
    if let failure = detection.freeze.renderFailureReason {
      payload["renderFailureReason"] = failure.rawValue
    }
    if let lastAcceptedFrame = detection.freeze.lastAcceptedFrame {
      payload["lastAcceptedFrame"] = lastAcceptedFrame
    }
    do {
      let url = try renderJournal.dump(currentPNG: backend.pngData)
      payload["dumpPath"] = url.path
      EventLog.shared.log("render.gpuFreeze.autoDump", payload)
      AppLog.render.error(
        "gpu render freeze suspected: \(detection.freeze.reason) streak=\(detection.freeze.noProgressStreak) dump=\(url.path)"
      )
    } catch {
      AppLog.render.error("gpu render freeze auto-dump failed: \(error)")
      EventLog.shared.log(
        "render.gpuFreeze.autoDump.failed",
        ["error": String(describing: error)])
    }
  }

  private func autoDumpGPUCellPayloadFailure(
    _ failure: MetalRenderer.GPUCellPayloadBuildFailure
  ) {
    let now = Date()
    let signature = gpuCellPayloadFailureSignature(failure)
    if signature == lastAutoDumpedGPUCellPayloadFailureSignature,
      let previous = lastGPUCellPayloadFailureAutoDumpAt,
      now.timeIntervalSince(previous) < 60
    {
      return
    }
    lastAutoDumpedGPUCellPayloadFailureSignature = signature
    lastGPUCellPayloadFailureAutoDumpAt = now

    var payload = gpuCellPayloadFailureEventPayload(failure)
    EventLog.shared.log("render.gpuCellPayload.failure", payload)
    guard renderJournalEnabled else { return }

    var dumpPath: String?
    do {
      let url = try renderJournal.dump(currentPNG: backend.pngData)
      dumpPath = url.path
      AppLog.render.error(
        "gpu cell payload build failed: \(failure.reason) row=\(failure.row) col=\(failure.col) dump=\(url.path)"
      )
    } catch {
      AppLog.render.error("gpu cell payload failure auto-dump failed: \(error)")
      EventLog.shared.log(
        "render.gpuCellPayload.autoDump.failed",
        ["error": String(describing: error)])
    }

    if let dumpPath {
      payload["dumpPath"] = dumpPath
      EventLog.shared.log("render.gpuCellPayload.failureDump", payload)
    }
    postGPUCellPayloadFailureNotification(failure, dumpPath: dumpPath)
  }

  private func gpuCellPayloadFailureEventPayload(
    _ failure: MetalRenderer.GPUCellPayloadBuildFailure
  ) -> [String: Any] {
    var payload: [String: Any] = [
      "reason": failure.reason,
      "row": failure.row,
      "col": failure.col,
      "utf8ByteCount": failure.utf8ByteCount,
      "wide": failure.wide,
      "attributesRawValue": failure.attributesRawValue,
    ]
    if let scalarValue = failure.scalarValue {
      payload["scalarValue"] = scalarValue
    }
    if let textPreview = failure.textPreview {
      payload["textPreview"] = textPreview
    }
    if let lowerBound = failure.utf8RangeLowerBound {
      payload["utf8RangeLowerBound"] = lowerBound
    }
    if let upperBound = failure.utf8RangeUpperBound {
      payload["utf8RangeUpperBound"] = upperBound
    }
    if let logicalWidth = failure.logicalWidth {
      payload["logicalWidth"] = logicalWidth
    }
    if let maxLogicalWidth = failure.maxLogicalWidth {
      payload["maxLogicalWidth"] = maxLogicalWidth
    }
    return payload
  }

  private func gpuCellPayloadFailureSignature(
    _ failure: MetalRenderer.GPUCellPayloadBuildFailure
  ) -> String {
    let scalarValue = failure.scalarValue.map { String($0) } ?? "nil"
    let textPreview = failure.textPreview ?? "nil"
    let logicalWidth = failure.logicalWidth.map { String($0) } ?? "nil"
    let maxLogicalWidth = failure.maxLogicalWidth.map { String($0) } ?? "nil"
    let parts: [String] = [
      failure.reason,
      scalarValue,
      textPreview,
      String(failure.wide),
      String(failure.attributesRawValue),
      logicalWidth,
      maxLogicalWidth,
    ]
    return parts.joined(separator: "|")
  }

  private func postGPUCellPayloadFailureNotification(
    _ failure: MetalRenderer.GPUCellPayloadBuildFailure,
    dumpPath: String?
  ) {
    guard
      let notification = gpuCellPayloadFailureNotificationPolicy.notificationRequest(
        for: failure,
        dumpPath: dumpPath)
    else { return }

    NSSound.beep()
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    if let subtitle = notification.subtitle {
      content.subtitle = subtitle
    }
    if notification.playsSound {
      content.sound = .default
    }
    let request = UNNotificationRequest(
      identifier: notification.identifier,
      content: content,
      trigger: nil)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      center.add(request, withCompletionHandler: nil)
    }
  }

  private func renderJournalSurfaceSnapshot() -> RenderJournal.SurfaceSnapshot {
    RenderJournal.SurfaceSnapshot(
      width: backend.surfaceWidth,
      height: backend.surfaceHeight,
      scale: Double(backend.surfaceScale))
  }

  private func renderJournalWindowSnapshot() -> RenderJournal.WindowSnapshot {
    let isKey = window?.isKeyWindow == true
    let occlusionVisible = window?.occlusionState.contains(.visible) ?? false
    return RenderJournal.WindowSnapshot(
      isVisible: window?.isVisible ?? false,
      isKeyWindow: isKey,
      isMainWindow: window?.isMainWindow ?? false,
      isMiniaturized: window?.isMiniaturized ?? false,
      occlusionVisible: occlusionVisible,
      visibleToUser: isKey && occlusionVisible,
      backingScaleFactor: Double(window?.backingScaleFactor ?? backend.surfaceScale),
      screenName: window?.screen?.localizedName)
  }

  private func renderJournalDisplayLinkSnapshot() -> RenderJournal.DisplayLinkSnapshot {
    let policy = displayLinkPolicyState()
    if #available(macOS 14.0, *), let link = caDisplayLink as? CADisplayLink {
      let range = link.preferredFrameRateRange
      return RenderJournal.DisplayLinkSnapshot(
        kind: "caDisplayLink",
        paused: link.isPaused,
        preferredFramesPerSecond: policy.preferredFramesPerSecond,
        minimumFramesPerSecond: Int(range.minimum.rounded()),
        maximumFramesPerSecond: Int(range.maximum.rounded()),
        reason: policy.reason,
        terminalOutputActive: policy.terminalOutputActive,
        attentionAnimating: policy.attentionAnimating,
        scrollAnimating: policy.scrollAnimating,
        lastTickIntervalMs: lastDisplayLinkTickIntervalMs)
    }
    return RenderJournal.DisplayLinkSnapshot(
      kind: cvDisplayLink == nil ? "none" : "cvDisplayLink",
      paused: nil,
      preferredFramesPerSecond: policy.preferredFramesPerSecond,
      minimumFramesPerSecond: nil,
      maximumFramesPerSecond: nil,
      reason: policy.reason,
      terminalOutputActive: policy.terminalOutputActive,
      attentionAnimating: policy.attentionAnimating,
      scrollAnimating: policy.scrollAnimating,
      lastTickIntervalMs: lastDisplayLinkTickIntervalMs)
  }

  private func renderJournalViewportSnapshot(for session: Session) -> RenderJournal
    .ViewportSnapshot?
  {
    guard let viewport = session.viewportState() else { return nil }
    return RenderJournal.ViewportSnapshot(
      offset: viewport.viewportOffset,
      totalRows: viewport.totalRows,
      viewportRows: viewport.viewportRows,
      scrollbackRows: viewport.scrollbackRows,
      altScreen: viewport.altScreen,
      mouseTracking: viewport.mouseTracking,
      linesBack: ViewportState.scrollDeltaToActiveBottom(
        viewportOffset: viewport.viewportOffset,
        totalRows: viewport.totalRows,
        viewportRows: viewport.viewportRows))
  }

  private func renderJournalScrollSnapshot(contentYOffset: CGFloat) -> RenderJournal.ScrollSnapshot
  {
    RenderJournal.ScrollSnapshot(
      appliedRows: appliedScrollRows,
      displayedRows: displayedScrollRows,
      targetRows: targetScrollRows,
      velocityRowsPerSecond: scrollVelocityRowsPerSec,
      contentYOffset: Double(contentYOffset))
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    // Metal path self-presents through CAMetalLayer; nothing to do here.
    if backendSelfPresents { return }
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    guard let cgImg = backend.presentationImage else {
      ctx.setFillColor(cgColorFrom(Theme.current.bg0))
      ctx.fill(bounds)
      return
    }
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(cgImg, in: bounds)
    ctx.restoreGState()
  }

  // MARK: - Resize

  /// Install/refresh the tracking area on every layout change so
  /// mouseMoved / mouseExited deliveries cover the full visible bounds.
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
  }

  override func mouseMoved(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    updateHoveredSidebarTab(at: pt)
    updateHoverCursor(at: pt, modifierFlags: event.modifierFlags)
    forwardHoverMotion(at: pt, modifiers: event.labanModifiers)
  }

  /// Forward a no-button pointer motion to a mouse-tracking app as an SGR
  /// mouse report (button code 35). The libghostty mouse encoder owns the
  /// per-mode rules — normal tracking (1000) drops motion, button tracking
  /// (1002) requires a held button, any-motion tracking (1003) reports hover —
  /// so this only gates on tracking being active and dedups per cell so an
  /// app sees one report per cell entered, not one per pixel.
  private func forwardHoverMotion(at pt: NSPoint, modifiers: Int) {
    guard trackedMouseButton == .none, !localSelectionMouseGestureActive,
      let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session),
      pt.x >= sidebarWidth
    else { return }

    let geom = terminalMouseGeometry(at: pt)
    let col = cellWidth > 0 ? Int(geom.x) / cellWidth : 0
    let row = cellHeight > 0 ? Int(geom.y) / cellHeight : 0
    if let last = lastHoverMotionCell,
      last.tab == activeTab.id, last.col == col, last.row == row
    {
      return
    }
    lastHoverMotionCell = (tab: activeTab.id, col: col, row: row)

    let mouseEncoding = remoteMouseEncoding(for: activeTab)
    let motionEvent = MouseEvent(
      action: .motion,
      button: .none,
      x: geom.x, y: geom.y,
      screenWidth: geom.screenWidth,
      screenHeight: geom.screenHeight,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      modifiers: modifiers,
      trackingMode: mouseEncoding?.trackingMode ?? 0,
      format: mouseEncoding?.format ?? 0
    )
    let sent = session.sendMouseCapturingBytes(motionEvent)
    let bytes = sent.result == 0 ? sent.bytes : []
    guard !bytes.isEmpty else { return }
    lastForwardedHoverReport = bytes
    forwardEncodedMouseToDaemon(bytes, session: session)
    recordInput(
      kind: "mouse",
      route: "terminal",
      command: "mouseMoved",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
    )
  }

  override func mouseExited(with event: NSEvent) {
    setHoveredSidebarTab(nil)
    setHoverCursor(.arrow)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    dropOperation(for: sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard dropOperation(for: sender).contains(.copy) else { return false }
    TerminalDrop.resolve(sender.draggingPasteboard) { [weak self] result in
      DispatchQueue.main.async {
        guard let self else { return }
        switch result {
        case .success(let drop):
          self.pasteDroppedFilePaths(drop.urls, sourceKinds: drop.sourceKinds)
        case .failure(let error):
          EventLog.shared.log("drop.failed", ["error": String(describing: error)])
        }
      }
    }
    return true
  }

  override func flagsChanged(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    updateHoverCursor(at: pt, modifierFlags: event.modifierFlags)
  }

  private func updateHoverCursor(at pt: NSPoint, modifierFlags: NSEvent.ModifierFlags = []) {
    let uri = pt.x >= sidebarWidth ? externalHyperlinkURI(at: pt) : nil
    setHoverCursor(
      TerminalHyperlinkOpening.hoverCursorStyle(
        externalHyperlinkURI: uri,
        modifierFlags: modifierFlags
      ))
  }

  private func setHoverCursor(_ style: TerminalHoverCursorStyle) {
    guard hoverCursorStyle != style else { return }
    hoverCursorStyle = style
    switch style {
    case .arrow:
      NSCursor.arrow.set()
    case .pointingHand:
      NSCursor.pointingHand.set()
    }
  }

  private func updateHoveredSidebarTab(at pt: NSPoint) {
    guard pt.x < sidebarWidth else {
      setHoveredSidebarTab(nil)
      return
    }
    let sp = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(sidebarCellWidth),
      cellHeight: CGFloat(sidebarCellHeight)
    )
    switch sp.hitTest(
      at: pt, tabs: model.tabs, height: bounds.height,
      topInset: Self.titlebarReservedHeight,
      scrollOffset: currentSidebarScrollOffsetForHitTesting())
    {
    case .selectTab(let id), .closeTab(let id):
      setHoveredSidebarTab(id)
    case .newTab, .none:
      setHoveredSidebarTab(nil)
    }
  }

  private func setHoveredSidebarTab(_ id: Tab.ID?) {
    guard hoveredSidebarTabId != id else { return }
    hoveredSidebarTabId = id
    invalidateRenderAndWake()
  }

  private func makeSidebarProducer() -> SidebarProducer {
    SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(sidebarCellWidth),
      cellHeight: CGFloat(sidebarCellHeight))
  }

  private func sidebarMaxScrollOffset() -> CGFloat {
    makeSidebarProducer().maxScrollOffset(
      tabCount: model.tabs.count,
      height: bounds.height,
      topInset: Self.titlebarReservedHeight)
  }

  private func clampedSidebarScrollOffset(_ offset: Double) -> Double {
    Double(min(max(0, CGFloat(offset)), sidebarMaxScrollOffset()))
  }

  private func currentSidebarScrollOffsetForHitTesting() -> CGFloat {
    CGFloat(clampedSidebarScrollOffset(displayedSidebarScrollOffset))
  }

  private func resetSidebarScrollState(to offset: Double = 0) {
    let clamped = clampedSidebarScrollOffset(offset)
    targetSidebarScrollOffset = clamped
    displayedSidebarScrollOffset = clamped
    sidebarScrollVelocityPointsPerSec = 0
    lastSidebarScrollTickAt = nil
    sidebarScrollResidualPx = 0
    sidebarScrollAnimating = false
  }

  private func advanceSidebarScrollFrame(surfaceScale: CGFloat) -> (
    offset: CGFloat, animating: Bool
  ) {
    let maxOffset = Double(sidebarMaxScrollOffset())
    guard maxOffset > 0 else {
      resetSidebarScrollState()
      return (0, false)
    }

    targetSidebarScrollOffset = min(max(0, targetSidebarScrollOffset), maxOffset)
    displayedSidebarScrollOffset = min(max(0, displayedSidebarScrollOffset), maxOffset)
    let before = displayedSidebarScrollOffset
    var shouldContinue = false
    let error = targetSidebarScrollOffset - displayedSidebarScrollOffset
    if abs(error) > 0.01 || abs(sidebarScrollVelocityPointsPerSec) > 0.1 {
      let now = ContinuousClock.now
      let dt: Double
      if let last = lastSidebarScrollTickAt {
        let dur = now - last
        dt = max(0, min(1.0 / 30.0, Double(dur.components.attoseconds) / 1e18))
      } else {
        dt = 1.0 / 120.0
      }
      lastSidebarScrollTickAt = now

      let omega = Self.sidebarScrollOmega
      let e0 = -error
      let c2 = sidebarScrollVelocityPointsPerSec + omega * e0
      let decay = exp(-omega * dt)
      displayedSidebarScrollOffset = targetSidebarScrollOffset + (e0 + c2 * dt) * decay
      sidebarScrollVelocityPointsPerSec = (c2 - omega * (e0 + c2 * dt)) * decay
      displayedSidebarScrollOffset = min(max(0, displayedSidebarScrollOffset), maxOffset)

      if abs(targetSidebarScrollOffset - displayedSidebarScrollOffset) < 0.01,
        abs(sidebarScrollVelocityPointsPerSec) < 0.1
      {
        displayedSidebarScrollOffset = targetSidebarScrollOffset
        sidebarScrollVelocityPointsPerSec = 0
      } else {
        shouldContinue = true
      }
    } else {
      lastSidebarScrollTickAt = nil
    }

    let scale = max(1, surfaceScale)
    let snapped = (CGFloat(displayedSidebarScrollOffset) * scale).rounded() / scale
    let movedThisFrame = abs(displayedSidebarScrollOffset - before) > 0.001
    sidebarScrollAnimating = shouldContinue
    return (snapped, shouldContinue || movedThisFrame)
  }

  private func ensureSidebarTabVisible(_ tabId: Tab.ID, animated: Bool) {
    let tabs = model.tabs
    guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
    let producer = makeSidebarProducer()
    let visibleTop = max(0, bounds.height - Self.titlebarReservedHeight)
    let maxOffset = producer.maxScrollOffset(
      tabCount: tabs.count,
      height: bounds.height,
      topInset: Self.titlebarReservedHeight)
    guard maxOffset > 0 else {
      resetSidebarScrollState()
      return
    }

    let rowTopAtZero = visibleTop - CGFloat(index) * producer.rowHeight
    let rowBottomAtZero = rowTopAtZero - producer.rowHeight
    var desired = CGFloat(targetSidebarScrollOffset)
    if rowTopAtZero + desired > visibleTop {
      desired = visibleTop - rowTopAtZero
    }
    if rowBottomAtZero + desired < 0 {
      desired = -rowBottomAtZero
    }
    desired = min(max(0, desired), maxOffset)
    guard abs(Double(desired) - targetSidebarScrollOffset) > 0.001 else { return }
    targetSidebarScrollOffset = Double(desired)
    if animated {
      sidebarScrollAnimating = true
    } else {
      resetSidebarScrollState(to: Double(desired))
    }
  }

  /// Sidebar drag-reorder snapshot consumed by the renderer to draw the
  /// drop-target accent and dim the lifted row. Nil unless a drag has
  /// passed the activation threshold.
  var sidebarDragIndicator: SidebarProducer.DragIndicator? {
    guard let state = sidebarDragState, state.activated, let slot = state.currentSlot else {
      return nil
    }
    return SidebarProducer.DragIndicator(slot: slot, draggingTabId: state.tabId)
  }

  /// Advance the sidebar drag state in response to a mouseDragged event.
  /// Returns true when the event was consumed by the drag — the caller
  /// should bail out of its normal drag path. Activation is gated by
  /// `sidebarDragActivationDistance` so a small jitter during a plain
  /// click does not flip the gesture into a reorder. Once activated the
  /// drag latches even if the cursor leaves the sidebar column: macOS
  /// drag-reorder convention is that the originating control owns the
  /// drag until mouseUp.
  @discardableResult
  private func updateSidebarDrag(at pt: NSPoint) -> Bool {
    guard var state = sidebarDragState else { return false }
    if !state.activated {
      let dx = pt.x - state.origin.x
      let dy = pt.y - state.origin.y
      if (dx * dx + dy * dy).squareRoot() < Self.sidebarDragActivationDistance {
        return true
      }
      state.activated = true
    }
    let sp = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(sidebarCellWidth),
      cellHeight: CGFloat(sidebarCellHeight)
    )
    state.currentSlot = sp.dropSlot(
      at: pt, tabs: model.tabs, height: bounds.height,
      topInset: Self.titlebarReservedHeight,
      scrollOffset: currentSidebarScrollOffsetForHitTesting())
    sidebarDragState = state
    invalidateRenderAndWake()
    return true
  }

  /// Commit an in-progress sidebar drag on mouseUp. Returns true when
  /// the up event was consumed by the drag (whether or not the reorder
  /// actually moved a tab) so the caller can skip the normal mouseUp
  /// path. A non-activated drag is just a click-to-select and falls
  /// through (returns false) so existing semantics survive.
  private func commitSidebarDragIfActive(at pt: NSPoint) -> Bool {
    guard let state = sidebarDragState else { return false }
    sidebarDragState = nil
    guard state.activated else { return false }
    let sp = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(sidebarCellWidth),
      cellHeight: CGFloat(sidebarCellHeight)
    )
    let slot =
      sp.dropSlot(
        at: pt, tabs: model.tabs, height: bounds.height,
        topInset: Self.titlebarReservedHeight,
        scrollOffset: currentSidebarScrollOffsetForHitTesting()) ?? state.currentSlot
    if let slot {
      // `dropSlot` returns an insertion index in [0, count]; AppModel
      // works in [0, count-1]. When the drop is past the last row, the
      // dragged tab itself contributes to the count, so the post-move
      // index is `slot - 1`. We clamp; AppModel will too.
      let removed = model.tabs.firstIndex(where: { $0.id == state.tabId })
      let targetIndex: Int = {
        if let removed, slot > removed { return slot - 1 }
        return slot
      }()
      _ = try? model.moveTab(state.tabId, to: targetIndex)
    }
    invalidateRenderAndWake()
    return true
  }

  private func persistSelectionStateForCurrentTab() {
    guard let tabId = activeSelectionTabId else { return }
    if let anchor = selectionAnchor, selectionFocus != nil {
      selectionsByTab[tabId] = (anchor, selectionFocus)
    } else {
      selectionsByTab.removeValue(forKey: tabId)
    }
  }

  private func restoreSelectionState(for tabId: Tab.ID?) {
    activeSelectionTabId = tabId
    if let tabId, let restored = selectionsByTab[tabId] {
      selectionAnchor = restored.anchor
      selectionFocus = restored.focus
    } else {
      selectionAnchor = nil
      selectionFocus = nil
    }
    selectionOriginCell = nil
    stopDragAutoscroll()
    stopTrackedMouseDragFramePump()
    lastDragPoint = nil
  }

  private func syncSelectionStateToActiveTab() {
    let activeTabId = model.activeTab?.id
    if activeSelectionTabId == nil {
      if selectionAnchor == nil && selectionFocus == nil {
        restoreSelectionState(for: activeTabId)
      } else {
        activeSelectionTabId = activeTabId
      }
      return
    }
    guard activeSelectionTabId != activeTabId else { return }
    persistSelectionStateForCurrentTab()
    restoreSelectionState(for: activeTabId)
  }

  private func selectTabPreservingSelection(_ tabId: Tab.ID) {
    syncSelectionStateToActiveTab()
    guard model.activeTab?.id != tabId else { return }
    // Abandon any in-flight IME composition before leaving this tab. One
    // view hosts every tab, so AppKit never auto-discards marked text on a
    // tab switch; a leaked composition would force later keystrokes down
    // the native-text path and commit into the wrong session. (M-3)
    discardMarkedComposition()
    persistSelectionStateForCurrentTab()
    model.selectTab(tabId)
    ensureSidebarTabVisible(tabId, animated: true)
    restoreSelectionState(for: model.activeTab?.id)
  }

  private func selectTab(at index: Int) {
    guard index >= 0, index < model.tabs.count else { return }
    selectTabPreservingSelection(model.tabs[index].id)
    invalidateRenderAndWake()
  }

  private func selectLastTab() {
    guard !model.tabs.isEmpty else { return }
    selectTab(at: model.tabs.count - 1)
  }

  private func selectRelativeTab(delta: Int) {
    let tabs = model.tabs
    guard tabs.count > 1, let activeTab = model.activeTab,
      let currentIndex = tabs.firstIndex(where: { $0.id == activeTab.id })
    else {
      return
    }
    let nextIndex = (currentIndex + delta + tabs.count) % tabs.count
    selectTab(at: nextIndex)
  }

  @discardableResult
  private func createTabPreservingSelection() throws -> Tab {
    syncSelectionStateToActiveTab()
    persistSelectionStateForCurrentTab()
    // Invalidate the generation cache so a newly-created (or recycled)
    // Session.ID cannot alias a stale generation entry and cause sync
    // work to be incorrectly skipped on the first tick after creation.
    surfaceController.invalidateSessionSyncCache()
    let previousActiveTabId = model.activeTab?.id
    let tab = try model.createTab()
    do {
      try sessionCoordinator?.ensureSession(
        for: tab,
        session: model.session(forTab: tab.id),
        size: model.terminalSize)
    } catch {
      // Session creation is all-or-nothing (MVP Session Creation contract):
      // if the remote PTY fails to bind, roll back the tab we just appended
      // and restore the prior selection rather than stranding the user on a
      // dead, input-rejecting tab. (H-4)
      remoteSnapshotRenderTracker.clear(tabId: tab.id)
      remoteMouseEncodingByTab.removeValue(forKey: tab.id)
      try? model.closeTab(tab.id)
      if let previousActiveTabId {
        model.selectTab(previousActiveTabId)
      }
      throw error
    }
    restoreSelectionState(for: tab.id)
    ensureSidebarTabVisible(tab.id, animated: true)
    return tab
  }

  private func closeTabAndRemoteSession(_ tabId: Tab.ID) throws {
    if let tab = model.tabs.first(where: { $0.id == tabId }) {
      sessionCoordinator?.terminate(tab: tab)
    }
    remoteSnapshotRenderTracker.clear(tabId: tabId)
    remoteMouseEncodingByTab.removeValue(forKey: tabId)
    try model.closeTab(tabId)
    // Prune the stale generation entry so a recycled Session.ID cannot
    // alias this closed session's last-synced generation.
    surfaceController.invalidateSessionSyncCache()
  }

  private func closeTabRegisteringUndo(_ tabId: Tab.ID) throws {
    let undoPayload = closedTabUndoPayload(tabId)
    try closeTabAndRemoteSession(tabId)
    if let undoPayload {
      registerUndoForClosedTab(undoPayload)
    }
  }

  private func closedTabUndoPayload(_ tabId: Tab.ID) -> ClosedTabUndoPayload? {
    guard model.tabs.count > 1 else { return nil }
    let snapshot = model.snapshotForPersistence(windowId: "undo")
    guard let state = snapshot.windows.first?.tabs.first(where: { $0.id == tabId }) else {
      return nil
    }
    return ClosedTabUndoPayload(argv: model.launchArgv(forTab: tabId), cwd: state.cwd)
  }

  private func registerUndoForClosedTab(_ payload: ClosedTabUndoPayload) {
    let undoManager = undoManagerForTesting ?? window?.undoManager
    undoManager?.registerUndo(withTarget: self) { target in
      target.restoreClosedTab(payload)
    }
    undoManager?.setActionName("Close Tab")
  }

  private func restoreClosedTab(_ payload: ClosedTabUndoPayload) {
    do {
      let tab = try model.createTab(runningArgv: payload.argv ?? [], cwd: payload.cwd)
      sessionCoordinator?.setLaunchCwd(payload.cwd, forTab: tab.id)
      try sessionCoordinator?.ensureSession(
        for: tab,
        session: model.session(forTab: tab.id),
        size: model.terminalSize)
      restoreSelectionState(for: tab.id)
      ensureSidebarTabVisible(tab.id, animated: true)
      invalidateRenderAndWake()
    } catch {
      AppLog.app.error("close-tab undo failed: \(error)")
    }
  }

  private func postAutomationAutoQuitNotice(_ text: String) {
    guard let tabId = model.activeTab?.id else { return }
    _ = model.postTabNotice(
      forTab: tabId,
      note: TabStateJournal.automationAutoQuitArmedNote,
      text: text)
  }

  private static func formatAutomationSeconds(_ seconds: Double) -> String {
    seconds.rounded(.towardZero) == seconds
      ? "\(Int(seconds)) second\(seconds == 1 ? "" : "s")"
      : String(format: "%.1f seconds", seconds)
  }

  private func clearAllSelectionState() {
    selectionsByTab.removeAll()
    selectionAnchor = nil
    selectionFocus = nil
    selectionOriginCell = nil
    activeSelectionTabId = model.activeTab?.id
    stopDragAutoscroll()
    stopTrackedMouseDragFramePump()
    lastDragPoint = nil
  }

  /// Frame to restore on the next zoom-toggle. Set when we zoom out,
  /// cleared when the user resizes the window manually, when the window
  /// stops being key, or after a successful restore. Tracked here rather
  /// than relying on `NSWindow.zoom(_:)`'s own user-frame because that
  /// path doesn't reliably toggle when the window's content view performs
  /// its own resize-time adjustments (and `isZoomed` then returns false
  /// even though we just maximized).
  private var preZoomFrame: NSRect?

  /// Mirror AppKit's title-bar double-click handler. Reads the user's
  /// `AppleActionOnDoubleClick` preference (system default is zoom) and
  /// dispatches the matching window action. Needed because the contentView
  /// covers the titlebar region under `fullSizeContentView` and consumes
  /// the click before AppKit's own handler can run. Defers the action so
  /// it doesn't run while AppKit is still mid-dispatch of this mouseDown.
  ///
  /// Reads from `NSGlobalDomain` rather than `UserDefaults.standard`
  /// because AppKit can cache a stale `AppleActionOnDoubleClick = None`
  /// into the app's own preferences plist; that would shadow the real
  /// system preference and silently disable the action. Falls back to the
  /// legacy `AppleMiniaturizeOnDoubleClick` boolean and then to zoom,
  /// matching AppKit's own resolution order.
  private func performTitlebarDoubleClickAction() {
    let global = UserDefaults.standard.persistentDomain(
      forName: UserDefaults.globalDomain)
    let action: String
    if let raw = global?["AppleActionOnDoubleClick"] as? String {
      // User has an explicit system-wide choice; respect it (including "None").
      action = raw
    } else if let miniaturize = global?["AppleMiniaturizeOnDoubleClick"] as? Bool {
      action = miniaturize ? "Minimize" : "Maximize"
    } else {
      action = "Maximize"
    }
    AppLog.app.notice("titlebar double-click action=\(action)")
    guard let window else { return }
    DispatchQueue.main.async { [weak self] in
      switch action {
      case "Maximize", "Zoom":
        self?.toggleZoom(window)
      case "Minimize":
        window.performMiniaturize(nil)
      default:
        break
      }
    }
  }

  /// Toggle between the screen's visible frame and the previously saved
  /// window frame. Mirrors what the green traffic-light button does, but
  /// tracks the unzoomed frame explicitly so the second double-click
  /// always restores even when `NSWindow.isZoomed` would report false
  /// after a tiny content-driven frame adjustment.
  private func toggleZoom(_ window: NSWindow) {
    if let saved = preZoomFrame {
      window.setFrame(saved, display: true, animate: true)
      preZoomFrame = nil
      return
    }
    let target = (window.screen ?? NSScreen.main)?.visibleFrame
    guard let target, target != window.frame else { return }
    preZoomFrame = window.frame
    window.setFrame(target, display: true, animate: true)
  }

  private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
    let pt = convert(sender.draggingLocation, from: nil)
    guard pt.x >= sidebarWidth,
      let activeTab = model.activeTab,
      model.session(forTab: activeTab.id) != nil,
      TerminalDrop.canRead(sender.draggingPasteboard)
    else { return [] }
    return .copy
  }

  private func pruneClosedTabState(_ tabId: Tab.ID) {
    selectionsByTab.removeValue(forKey: tabId)
    remoteMouseEncodingByTab.removeValue(forKey: tabId)
    if hoveredSidebarTabId == tabId {
      hoveredSidebarTabId = nil
    }
    if sidebarDragState?.tabId == tabId {
      sidebarDragState = nil
    }
    if activeSelectionTabId == tabId {
      selectionAnchor = nil
      selectionFocus = nil
      selectionOriginCell = nil
      activeSelectionTabId = nil
      stopDragAutoscroll()
      lastDragPoint = nil
    }
    syncSelectionStateToActiveTab()
    if let active = model.activeTab {
      ensureSidebarTabVisible(active.id, animated: true)
    } else {
      resetSidebarScrollState()
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    layoutFindChip()
    layoutCaptureIndicator()
    if let active = model.activeTab {
      ensureSidebarTabVisible(active.id, animated: false)
    } else {
      resetSidebarScrollState()
    }
    let w = Int(newSize.width)
    let h = Int(newSize.height)
    guard w > 0, h > 0 else { return }
    let surfaceChanged = recreateSurface()
    if surfaceChanged {
      renderInvalidated = true
    }
    let insets = Self.contentInsets
    let termW = max(1, w - Int(sidebarWidth) - Int(insets.left) - Int(insets.right))
    let termH = max(1, h - Int(insets.top) - Int(insets.bottom))
    // Apply per-nudge so the rendered grid stays in lockstep with the Metal
    // target. Throttling here causes the cursor to jump as libghostty's row
    // count lags the surface dimensions during live drag. SIGWINCH per
    // nudge is fine for modern shells (the prompt redraw is one line);
    // libghostty's reflow is a no-op when dims are unchanged.
    let cols = max(1, termW / cellWidth)
    let rows = max(1, termH / cellHeight)
    if lastAppliedCols != 0, lastAppliedRows != 0,
      cols != lastAppliedCols || rows != lastAppliedRows
    {
      // Reflow invalidates grid-anchored selection coordinates.
      clearAllSelectionState()
    }
    lastAppliedCols = cols
    lastAppliedRows = rows
    model.resize(
      viewportWidth: termW, viewportHeight: termH,
      cellWidth: cellWidth, cellHeight: cellHeight,
      deferFindRescan: inLiveResize)
    sessionCoordinator?.resize(tabs: model.tabs, in: model, size: model.terminalSize)

    // Render synchronously inside the resize event during live drag so the
    // new drawable commits with the new grid dimensions in the same event
    // loop turn. Otherwise AppKit composites the previous drawable over the
    // resized layer until the next displayLink tick (~16 ms) and content
    // anchored to the top of the grid (e.g. cursor at row 0) appears to
    // jump as the gap closes. Metal resize frames also wait for command
    // completion so CAMetalLayer's top-left gravity has an actual drawable
    // to present before AppKit/WindowServer samples the resized surface.
    if inLiveResize || surfaceChanged {
      applyTransientResizeBackground()
      renderingResizeFrame = true
      let metal = backend as? MetalRenderer
      let previousWaitForFrameCompletion = metal?.waitForFrameCompletion ?? false
      metal?.waitForFrameCompletion = true
      defer {
        metal?.waitForFrameCompletion = previousWaitForFrameCompletion
        renderingResizeFrame = false
      }
      advanceFrame()
    }
  }

  // MARK: - Live font-size zoom

  /// Apply a new terminal font size live — the inverse of a window resize:
  /// viewport pixels stay fixed while the cell size changes, so cols/rows
  /// renegotiate with libghostty and every session's PTY receives a
  /// TIOCSWINSZ (SIGWINCH), exactly like a window-resize reflow. The sidebar
  /// font scales together with the terminal (same 11/14 ratio the restart
  /// path applies). The chosen size persists to UserDefaults on every step.
  func applyFontSize(_ requested: CGFloat) {
    let clamped = FontAtlas.clampedZoomPointSize(requested)
    guard clamped != fontAtlas.pointSize else { return }

    // Prefer prebuilt ladder atlases — a pure pointer swap. Fall back to a
    // synchronous build (a few ms) when the ladder is absent, still warming,
    // or stale against the active font family; correctness never depends
    // on the ladder.
    let ladderEntry: GlyphAtlasLadder.Entry? = {
      guard let ladder = atlasLadder,
        ladder.fontName == fontAtlas.fontPostScriptName,
        ladder.sidebarFontName == sidebarFontAtlas.fontPostScriptName
      else { return nil }
      return ladder.entry(forPointSize: Int(clamped))
    }()
    let newFontAtlas = ladderEntry?.fontAtlas ?? fontAtlas.withPointSize(clamped)
    let newSidebarFontAtlas =
      ladderEntry?.sidebarFontAtlas
      ?? sidebarFontAtlas.withPointSize(FontAtlas.sidebarPointSize(forTerminalPointSize: clamped))
    let cell = newFontAtlas.cellSize
    let sidebarCell = newSidebarFontAtlas.cellSize

    fontAtlas = newFontAtlas
    sidebarFontAtlas = newSidebarFontAtlas
    cellWidth = max(1, Int(cell.width))
    cellHeight = max(1, Int(cell.height))
    sidebarCellWidth = max(1, Int(sidebarCell.width))
    sidebarCellHeight = max(1, Int(sidebarCell.height))

    if let metal = backend as? MetalRenderer {
      metal.reconfigureFonts(
        fontAtlas: newFontAtlas,
        sidebarFontAtlas: newSidebarFontAtlas,
        prebuiltTerminalAtlas: ladderEntry?.terminalAtlas,
        prebuiltSidebarAtlas: ladderEntry?.sidebarAtlas)
    } else if let vector = backend as? VectorGlyphRenderer {
      vector.reconfigureFonts(fontAtlas: newFontAtlas, sidebarFontAtlas: newSidebarFontAtlas)
      vector.resize(
        pixelWidth: lastPixelWidth,
        pixelHeight: lastPixelHeight,
        scale: lastSurfaceScale)
    } else {
      // SoftwareRenderer rasterizes from its FontAtlas every frame and is
      // wired to one surface; recreate the backend with the new atlases at
      // the current pixel size (the applyRendererSelection pattern).
      backend = SoftwareBackend(
        fontAtlas: newFontAtlas,
        sidebarFontAtlas: newSidebarFontAtlas,
        pixelWidth: lastPixelWidth,
        pixelHeight: lastPixelHeight,
        scale: lastSurfaceScale)
      configurePresentationForCurrentBackend()
    }

    surfaceController.updateCellMetrics(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarCellWidth: sidebarCell.width,
      sidebarCellHeight: sidebarCell.height)

    // Renegotiate the grid with the unchanged viewport pixels. Mirrors
    // setFrameSize's interaction invalidation: a grid-size change invalidates
    // grid-anchored selection coordinates, and the find rescan runs
    // synchronously (deferFindRescan: false).
    let w = Int(bounds.width)
    let h = Int(bounds.height)
    if w > 0, h > 0 {
      let insets = Self.contentInsets
      let termW = max(1, w - Int(sidebarWidth) - Int(insets.left) - Int(insets.right))
      let termH = max(1, h - Int(insets.top) - Int(insets.bottom))
      let cols = max(1, termW / cellWidth)
      let rows = max(1, termH / cellHeight)
      if lastAppliedCols != 0, lastAppliedRows != 0,
        cols != lastAppliedCols || rows != lastAppliedRows
      {
        clearAllSelectionState()
      }
      lastAppliedCols = cols
      lastAppliedRows = rows
      model.resize(
        viewportWidth: termW, viewportHeight: termH,
        cellWidth: cellWidth, cellHeight: cellHeight,
        deferFindRescan: false)
      sessionCoordinator?.resize(tabs: model.tabs, in: model, size: model.terminalSize)
    }

    UserDefaults.standard.set(Double(clamped), forKey: FontAtlas.userFontSizeKey)
    lastObservedPersistedFontName = UserDefaults.standard.string(forKey: FontAtlas.userFontKey)
    NotificationCenter.default.post(name: FontAtlas.didChangeNotification, object: nil)

    // One synchronous frame so no presented frame mixes the old atlas with
    // the new grid (the live-resize pattern).
    renderInvalidated = true
    renderingResizeFrame = true
    let metal = backend as? MetalRenderer
    let previousWaitForFrameCompletion = metal?.waitForFrameCompletion ?? false
    metal?.waitForFrameCompletion = true
    defer {
      metal?.waitForFrameCompletion = previousWaitForFrameCompletion
      renderingResizeFrame = false
    }
    advanceFrame()
    if !backendSelfPresents {
      needsDisplay = true
    }
  }

  // MARK: - Responder

  override var acceptsFirstResponder: Bool { true }

  override func isAccessibilityElement() -> Bool { true }

  override func accessibilityRole() -> NSAccessibility.Role? {
    .textArea
  }

  override func accessibilityLabel() -> String? {
    "Terminal"
  }

  override func accessibilityValue() -> Any? {
    accessibilityVisibleText()
  }

  private func accessibilityVisibleText() -> String {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else { return "" }
    defer { laban_snapshot_destroy(snap) }
    return TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .trimmedNonEmptyRows)
  }

  override func resignFirstResponder() -> Bool {
    discardMarkedComposition()
    return super.resignFirstResponder()
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    // The full scrollback find rescan was deferred during the drag (H-5);
    // run it once now that the size has settled.
    model.refreshActiveFindsAfterResize()
    invalidateRenderAndWake()
  }

  override func keyDown(with event: NSEvent) {
    // Stamp the keystroke so the next render's GPU completion handler can
    // close out an input-to-photon latency sample. Only the most recent
    // keystroke is tracked; if you mash keys we attribute the eventual
    // visible frame to the latest one (closer to user-perceived latency).
    pendingInputAt = ContinuousClock.now
    blinkDriver.noteInput()
    let descriptor = TerminalKeyDescriptor(keyDown: event)
    switch descriptor.route(hasMarkedText: hasMarkedText()) {
    case .appCommand(let cmd):
      executeAppCommand(cmd)
    case .swallowCommand:
      recordInput(kind: "key", route: "ignored", key: descriptor.key.map(String.init(describing:)))
      break
    case .encodedKey(let keyEvent):
      sendKeyEvent(keyEvent)
    case .terminalBytes(let bytes):
      sendBytes(bytes)
    case .nativeText:
      currentKeyDescriptor = descriptor
      defer { currentKeyDescriptor = nil }
      interpretKeyEvents([event])
    case .ignored:
      recordInput(kind: "key", route: "ignored", key: descriptor.key.map(String.init(describing:)))
      break
    }
    // Wake the (possibly parked) frame loop for every keystroke. Echo rides
    // the PTY-output push, but no-echo cases (stty -echo, an app ignoring the
    // key) and the blink-phase reset above would otherwise paint nothing.
    advanceFrame(wake: .keyboard)
  }

  override func keyUp(with event: NSEvent) {
    let descriptor = TerminalKeyDescriptor(keyUp: event)
    if case .encodedKey(let keyEvent) = descriptor.route() {
      sendKeyEvent(keyEvent)
    }
  }

  // MARK: - NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
    blinkDriver.noteInput()
    unmarkText()
    let text: String
    if let s = string as? String {
      text = s
    } else if let a = string as? NSAttributedString {
      text = a.string
    } else {
      return
    }
    if let keyEvent = TerminalKeyDescriptor.buildTextKeyEvent(
      text: text, descriptor: currentKeyDescriptor)
    {
      sendKeyEvent(keyEvent)
    } else {
      sendBytes(Array(text.utf8))
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let s = string as? String {
      markedText = NSAttributedString(string: s)
    } else if let a = string as? NSAttributedString {
      markedText = a
    }
    // Place the caret at the IME's insertion point within the composition. The
    // selectedRange is the actively-edited segment in UTF-16 units relative to
    // the marked text; its end (NSMaxRange) is the caret for both a zero-length
    // insertion point and an active selection, and is also where macOS
    // dictation parks the caret (end of the transcript).
    let ns = markedText.string as NSString
    let caretUTF16 =
      selectedRange.location == NSNotFound
      ? ns.length : min(max(NSMaxRange(selectedRange), 0), ns.length)
    markedTextCaretCells = TerminalDisplayWidth.cells(of: ns.substring(to: caretUTF16))
    // The live composition (dictation transcript / IME preedit) is drawn inline
    // at the cursor by FrameProducer; force a fresh full-damage frame so the
    // updated marked text repaints the cursor row immediately as the user
    // speaks or composes, rather than waiting for the program to emit output.
    // Dictation drives this without any keyDown, so it must wake itself.
    invalidateRenderAndWake()
  }

  func unmarkText() {
    markedText = NSAttributedString(string: "")
    markedTextCaretCells = 0
    // Composition ended (committed or abandoned): repaint so the preedit run is
    // cleared from the cursor row on the next frame.
    invalidateRenderAndWake()
  }

  /// Finalize/abandon any in-flight IME composition. Safe to call when
  /// there is no marked text. Used on tab switch and on losing first
  /// responder, where AppKit does not auto-discard because one view hosts
  /// every tab. (M-3)
  private func discardMarkedComposition() {
    guard hasMarkedText() else { return }
    inputContext?.discardMarkedText()
    unmarkText()
  }
  func selectedRange() -> NSRange {
    // macOS dictation, IME candidate windows, and the press-and-hold accent
    // overlay all ask the focused text client for its insertion point here and
    // silently refuse to open (the dictation "ding" with no overlay) when the
    // location is NSNotFound. NSNotFound is the correct empty sentinel for
    // markedRange(), but selectedRange() must always report a valid caret. We
    // expose no document contents, so the caret sits at the end of any in-flight
    // composition, or at 0 when idle.
    NSRange(location: markedText.length, length: 0)
  }
  func markedRange() -> NSRange {
    markedText.length > 0
      ? NSRange(location: 0, length: markedText.length)
      : NSRange(location: NSNotFound, length: 0)
  }
  func hasMarkedText() -> Bool { markedText.length > 0 }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  { nil }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = NSRange(location: 0, length: markedText.length)
    guard let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let snap = session.snapshot()
    else { return .zero }
    defer { laban_snapshot_destroy(snap) }

    let rect = TerminalTextInputGeometry.cursorRect(
      rows: Int(snap.pointee.rows),
      cursorRow: Int(snap.pointee.cursor_row),
      cursorCol: Int(snap.pointee.cursor_col),
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight),
      boundsHeight: bounds.height,
      insets: Self.contentInsets
    )
    let windowRect = convert(rect, to: nil)
    return window?.convertToScreen(windowRect) ?? windowRect
  }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  override func doCommand(by commandSelector: Selector) {
    let mods = currentKeyDescriptor?.modifiers ?? []
    if let keyEvent = TerminalKeyDescriptor.selectorKeyEvent(
      for: commandSelector, modifiers: mods)
    {
      sendKeyEvent(keyEvent)
    }
  }

  private func sendKeyEvent(_ event: KeyEvent) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    let inputFollowDeltaRows: Int
    if event.action != .release {
      inputFollowDeltaRows = followActiveBottomBeforeTerminalInput(session: session)
      recordInputFollowBottom(deltaRows: inputFollowDeltaRows)
    } else {
      inputFollowDeltaRows = 0
    }
    let bytes: [UInt8]
    if let sessionCoordinator {
      bytes = session.encodeKey(event) ?? []
      if !bytes.isEmpty {
        do {
          try sessionCoordinator.write(
            bytes,
            to: activeTab,
            session: session,
            size: model.terminalSize)
        } catch {
          AppLog.app.error("laband key input failed: \(String(describing: error))")
        }
      }
    } else {
      let sent = session.sendKeyCapturingBytes(event)
      bytes = sent.result == 0 ? sent.bytes : []
    }
    recordInput(
      kind: "key",
      route: "terminal",
      key: String(describing: event.key),
      text: event.text,
      modifiers: TerminalInputCaptureMetadata.modifierNames(event.modifiers),
      consumedModifiers: TerminalInputCaptureMetadata.modifierNames(event.consumedModifiers),
      encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
    )
    invalidateRenderAndWake()
  }

  private func sendBytes(_ bytes: [UInt8]) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    let inputFollowDeltaRows = followActiveBottomBeforeTerminalInput(session: session)
    recordInputFollowBottom(deltaRows: inputFollowDeltaRows)
    if let sessionCoordinator {
      do {
        try sessionCoordinator.write(
          bytes,
          to: activeTab,
          session: session,
          size: model.terminalSize)
      } catch {
        AppLog.app.error("laband text input failed: \(String(describing: error))")
      }
    } else {
      session.write(bytes)
    }
    recordInput(
      kind: "text",
      route: "terminal",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
    )
  }

  private func executeAppCommand(_ command: AppCommand) {
    recordInput(
      kind: "key",
      route: "appCommand",
      command: TerminalInputCaptureMetadata.captureName(for: command))
    switch command {
    case .newTab:
      _ = try? createTabPreservingSelection()
      invalidateRenderAndWake()
    case .closeTab:
      closeTab(nil)
    case .selectTab(let index):
      selectTab(at: index)
    case .selectLastTab:
      selectLastTab()
    case .selectNextTab:
      selectRelativeTab(delta: 1)
    case .selectPreviousTab:
      selectRelativeTab(delta: -1)
    case .copy:
      copy(nil)
    case .paste:
      paste(nil)
    case .find:
      showFindChip(selectingExistingNeedle: true)
    case .dumpRenderJournal:
      dumpRenderJournal(nil)
    case .minimize:
      window?.miniaturize(nil)
    case .increaseFontSize:
      applyFontSize(fontAtlas.pointSize + 1)
    case .decreaseFontSize:
      applyFontSize(fontAtlas.pointSize - 1)
    case .resetFontSize:
      applyFontSize(FontAtlas.defaultTerminalPointSize)
    }
  }

  @objc func find(_ sender: Any?) {
    showFindChip(selectingExistingNeedle: true)
  }

  private func showFindChip(selectingExistingNeedle: Bool) {
    guard let activeTab = model.activeTab else { return }
    let sessionId = activeTab.sessionId
    var state = model.findState(forSession: sessionId)
    if !state.isActive {
      state = model.startFind(sessionID: sessionId, needle: lastFindNeedle) ?? .inactive
    }

    let chip: TerminalFindChipView
    if let existing = findChip {
      chip = existing
    } else {
      chip = TerminalFindChipView(frame: .zero)
      chip.onNeedleChanged = { [weak self] needle in
        self?.updateFindNeedle(needle)
      }
      chip.onStep = { [weak self] direction in
        self?.stepFind(direction)
      }
      chip.onClose = { [weak self] in
        self?.closeFindChip()
      }
      findChip = chip
      addSubview(chip)
    }

    chip.update(with: state)
    layoutFindChip()
    if selectingExistingNeedle {
      chip.focusAndSelectAll()
    }
    renderInvalidated = true
    advanceFrame()
  }

  private func updateFindNeedle(_ needle: String) {
    guard let sessionId = model.activeTab?.sessionId else { return }
    lastFindNeedle = needle
    if needle.isEmpty {
      cancelPendingFindSearch()
      _ = model.updateFindNeedle(sessionID: sessionId, needle: needle)
      syncFindChip()
      renderInvalidated = true
      advanceFrame()
      return
    }

    _ = model.setFindNeedlePending(sessionID: sessionId, needle: needle)
    scheduleFindSearch(sessionID: sessionId, needle: needle)
    syncFindChip()
  }

  private func stepFind(_ direction: TerminalFindDirection) {
    guard let sessionId = model.activeTab?.sessionId else { return }
    cancelPendingFindSearch()
    _ = model.stepFind(sessionID: sessionId, direction: direction)
    syncFindChip()
    renderInvalidated = true
    advanceFrame()
  }

  private func closeFindChip() {
    cancelPendingFindSearch()
    guard let sessionId = model.activeTab?.sessionId else {
      findChip?.removeFromSuperview()
      findChip = nil
      return
    }
    lastFindNeedle = model.findState(forSession: sessionId).needle
    _ = model.stopFind(sessionID: sessionId)
    findChip?.removeFromSuperview()
    findChip = nil
    window?.makeFirstResponder(self)
    renderInvalidated = true
    advanceFrame()
  }

  private func syncFindChip() {
    guard let chip = findChip, let sessionId = model.activeTab?.sessionId else { return }
    let state = model.findState(forSession: sessionId)
    let isSearching =
      pendingFindSearchSessionID == sessionId
      && pendingFindSearchNeedle == state.needle
    chip.update(with: state, isSearching: isSearching)
  }

  private func scheduleFindSearch(sessionID: Session.ID, needle: String) {
    pendingFindSearchGeneration &+= 1
    let generation = pendingFindSearchGeneration
    pendingFindSearchWorkItem?.cancel()
    pendingFindSearchSessionID = sessionID
    pendingFindSearchNeedle = needle

    let workItem = DispatchWorkItem { [weak self] in
      self?.runPendingFindSearch(sessionID: sessionID, needle: needle, generation: generation)
    }
    pendingFindSearchWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.findTypingSearchDelay,
      execute: workItem
    )
  }

  private func runPendingFindSearch(
    sessionID: Session.ID,
    needle: String,
    generation: UInt64
  ) {
    guard pendingFindSearchGeneration == generation,
      pendingFindSearchSessionID == sessionID,
      pendingFindSearchNeedle == needle
    else { return }

    pendingFindSearchWorkItem = nil
    pendingFindSearchSessionID = nil
    pendingFindSearchNeedle = ""
    guard model.activeTab?.sessionId == sessionID, findChip != nil else { return }

    _ = model.updateFindNeedle(
      sessionID: sessionID,
      needle: needle,
      scrollSelectedIntoView: true
    )
    syncFindChip()
    renderInvalidated = true
    advanceFrame()
  }

  private func cancelPendingFindSearch() {
    pendingFindSearchGeneration &+= 1
    pendingFindSearchWorkItem?.cancel()
    pendingFindSearchWorkItem = nil
    pendingFindSearchSessionID = nil
    pendingFindSearchNeedle = ""
  }

  private func layoutFindChip() {
    guard let chip = findChip else { return }
    let size = NSSize(width: 328, height: 30)
    let frame = TerminalFindChipView.defaultFrame(in: terminalContentRect(), size: size)
    if chip.frame.size == .zero {
      chip.frame = frame
    } else if chip.frame.origin.x == 0 && chip.frame.origin.y == 0 {
      chip.frame = frame
    } else {
      var next = chip.frame
      next.size = size
      next.origin.x = min(max(0, next.origin.x), max(0, bounds.width - size.width))
      next.origin.y = min(max(0, next.origin.y), max(0, bounds.height - size.height))
      chip.frame = next
    }
  }

  private func terminalContentRect() -> NSRect {
    let insets = Self.contentInsets
    let x = sidebarWidth + insets.left
    let y = insets.bottom
    return NSRect(
      x: x,
      y: y,
      width: max(1, bounds.width - x - insets.right),
      height: max(1, bounds.height - insets.top - insets.bottom)
    )
  }

  private func recordInput(
    kind: String,
    route: String,
    key: String? = nil,
    text: String? = nil,
    modifiers: [String]? = nil,
    consumedModifiers: [String]? = nil,
    command: String? = nil,
    encodedHex: String? = nil,
    encodedLength: Int? = nil,
    deltaRows: Int? = nil,
    anchor: (row: Int, col: Int)? = nil,
    focus: (row: Int, col: Int)? = nil
  ) {
    guard captureRecorder != nil else { return }
    let active = model.activeTab
    captureRecorder?.recordInput(
      InputEventEnvelope(
        inputId: UUID().uuidString,
        source: "appkit",
        kind: kind,
        route: route,
        frameBefore: renderedFrameCount,
        tabId: active?.id,
        sessionId: active?.sessionId,
        key: key,
        text: text,
        modifiers: modifiers,
        consumedModifiers: consumedModifiers,
        command: command,
        encodedHex: encodedHex,
        encodedLength: encodedLength,
        deltaRows: deltaRows,
        anchorRow: anchor?.row,
        anchorCol: anchor?.col,
        focusRow: focus?.row,
        focusCol: focus?.col
      ))
  }

  private func recordInputFollowBottom(deltaRows: Int) {
    guard deltaRows != 0 else { return }
    recordInput(
      kind: "scroll",
      route: "terminal",
      command: "inputFollowBottom",
      deltaRows: deltaRows
    )
  }

  // MARK: - Clipboard

  @objc func copy(_ sender: Any?) {
    guard let text = currentSelectionText() else { return }
    if testPasteboardEnabled {
      testPasteboardString = text
    } else {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
    EventLog.shared.log("copy", ["bytes": text.utf8.count])
    recordInput(kind: "copy", route: "appCommand", text: text, command: "copy")
  }

  /// The active tab's current selection rendered to text (scrollback-aware via
  /// the viewport path), or nil when there is no non-empty selection. Shared by
  /// Copy and Quick Look.
  private func currentSelectionText() -> String? {
    syncSelectionStateToActiveTab()
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else { return nil }
    defer { laban_snapshot_destroy(snap) }

    let viewportState = session.viewportState()
    guard
      let selection = currentTerminalSelection(
        sessionId: session.id,
        currentViewportOffset: viewportState?.viewportOffset ?? currentViewportOffset()
      )
    else { return nil }

    let text: String
    if let viewportState {
      text = selection.selectedText(
        from: session,
        viewportSnapshot: snap.pointee,
        viewportState: viewportState
      )
    } else {
      text = selection.selectedText(from: snap.pointee)
    }
    return text.isEmpty ? nil : text
  }

  /// Edit → Select All (⌘A): select the whole buffer including scrollback, so
  /// a following ⌘C copies everything. The selection is expressed against the
  /// absolute buffer (anchor row 0 → focus last row), so it stands regardless
  /// of where the viewport is currently scrolled; the rendered highlight is
  /// clipped to the visible rows by `TerminalSelection.segments`.
  override func selectAll(_ sender: Any?) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    let cols = currentCols()
    let totalRows: Int
    if let vs = session.viewportState() {
      totalRows = vs.totalRows
    } else if let snap = session.snapshot() {
      totalRows = Int(snap.pointee.rows)
      laban_snapshot_destroy(snap)
    } else {
      return
    }
    guard
      let points = TerminalSelectionInput.selectAllPoints(totalRows: totalRows, cols: cols)
    else { return }
    selectionMode = .char
    selectionOriginCell = points.anchor
    selectionAnchor = points.anchor
    selectionFocus = points.focus
    syncSelectionStateToActiveTab()
    advanceFrame()
    recordInput(
      kind: "selection",
      route: "appCommand",
      command: "selectAll",
      anchor: (row: points.anchor.row, col: points.anchor.col),
      focus: (row: points.focus.row, col: points.focus.col))
  }

  // MARK: - Quick Look

  /// The file currently shown in the Quick Look panel, or nil when nothing is
  /// being previewed. Drives the panel data source.
  private var quickLookPreviewURL: URL?

  /// Quick Look gesture (three-finger tap / force click). AppKit routes the
  /// system Quick Look gesture to this responder method; we preview the file
  /// named by the word under the gesture point, resolved against the session's
  /// working directory.
  override func quickLook(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    presentQuickLook(for: wordText(at: pt))
  }

  /// Edit → Quick Look (⌘Y): preview the file named by the current selection.
  @objc func quickLookSelection(_ sender: Any?) {
    presentQuickLook(for: currentSelectionText())
  }

  /// The on-screen word at `pt` (path/URL-aware via `wordBounds`'s glue chars),
  /// or nil when the point is outside the grid or lands on blank cells.
  private func wordText(at pt: NSPoint) -> String? {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot(),
      let cell = termCell(at: pt)
    else { return nil }
    defer { laban_snapshot_destroy(snap) }
    let bounds = TerminalSelectionInput.wordBounds(
      row: cell.row, col: cell.col, in: snap.pointee)
    let word = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: cell.row, col: bounds.start),
      focus: TerminalCellCoordinate(row: cell.row, col: bounds.end)
    ).selectedText(from: snap.pointee)
    return word.isEmpty ? nil : word
  }

  /// Resolve `candidate` to a file (relative paths use the session's OSC 7 /
  /// process-metadata cwd) and show it in the shared Quick Look panel. No-op
  /// when the candidate does not name an existing file.
  private func presentQuickLook(for candidate: String?) {
    guard let candidate else { return }
    let cwd =
      model.activeTab
      .flatMap { model.session(forTab: $0.id) }?
      .processMetadata()?.cwd
    // Resolve off the main actor: `fileExists` can block on a slow or dead
    // network mount, and a main-thread stall here would trip MainThreadWatchdog.
    // `resolvePreviewURL` is `nonisolated`, so awaiting it from this @MainActor
    // method runs the git/stat lookup on the cooperative pool (SE-0338); we
    // resume back on the main actor to drive the panel.
    Task { [weak self] in
      let url = await Self.resolvePreviewURL(for: candidate, workingDirectory: cwd)
      guard let self else { return }
      guard let url else {
        EventLog.shared.log("quicklook.miss", ["candidate": candidate])
        return
      }
      self.showQuickLook(url)
    }
  }

  private nonisolated static func resolvePreviewURL(
    for candidate: String,
    workingDirectory: String?
  ) async -> URL? {
    // Prefer a git commit preview when the token is a commit hash in the
    // session's repo; otherwise fall back to previewing a file.
    if let commit = TerminalGitLookup.commitPreviewURL(
      for: candidate, workingDirectory: workingDirectory)
    {
      return commit
    }
    return TerminalQuickLook.fileURL(for: candidate, workingDirectory: workingDirectory)
  }

  private func showQuickLook(_ url: URL) {
    quickLookPreviewURL = url
    EventLog.shared.log("quicklook.show", ["path": url.path(percentEncoded: false)])
    guard let panel = QLPreviewPanel.shared() else { return }
    if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
      panel.reloadData()
    } else {
      panel.makeKeyAndOrderFront(nil)
    }
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
    quickLookPreviewURL != nil
  }

  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = self
    panel.delegate = self
  }

  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    quickLookPreviewURL = nil
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
    quickLookPreviewURL == nil ? 0 : 1
  }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    quickLookPreviewURL as NSURL?
  }

  @objc func paste(_ sender: Any?) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }

    // Read the clipboard text BEFORE deciding to forward an image read. A mixed
    // text+image clipboard (web selection, screenshot annotation, Figma) must
    // paste its text; only an image-only clipboard (the .empty case below)
    // forwards Ctrl+V so a TUI can read the image itself. (H-7:
    // short-circuiting on hasImage here silently dropped the text.)
    let clipboardRead: TerminalClipboard.StringRead
    let hasImage: Bool
    if testPasteboardEnabled {
      hasImage = false
      if let raw = testPasteboardString, !raw.isEmpty {
        let bytes = raw.utf8.count
        clipboardRead =
          bytes > TerminalClipboard.hardLimitBytes ? .tooLarge(bytes) : .value(raw, bytes: bytes)
      } else {
        clipboardRead = .empty
      }
    } else {
      let pasteboard = NSPasteboard.general
      hasImage = TerminalClipboard.containsImage(pasteboard)
      clipboardRead = TerminalClipboard.readString(pasteboard)
    }

    let raw: String
    let rawBytes: Int
    switch clipboardRead {
    case .empty:
      // Image-only clipboard: mirror Ghostty's performable-keybind pass-through —
      // when the clipboard has no text, forward as ctrl+v so TUIs like Claude
      // Code can read the image from the system pasteboard themselves.
      if hasImage {
        forwardClipboardImagePasteToTerminal(session: session)
      }
      return
    case .tooLarge(let bytes):
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Paste too large"
      alert.informativeText =
        "Refusing to paste \(bytes) bytes (limit is \(TerminalClipboard.hardLimitBytes))."
      alert.addButton(withTitle: "OK")
      alert.runModal()
      EventLog.shared.log("paste.refused.size", ["bytes": bytes])
      return
    case .value(let value, let bytes):
      raw = value
      rawBytes = bytes
    }

    // Sanitize control characters out of the paste before handing it to
    // libghostty's bracketed-paste encoder. Strips ESC and the rest of the
    // C0 range (plus DEL) — keeps tab / newline / CR. This is the post-
    // CVE-2026-26982 baseline; without it a malicious clipboard payload
    // could smuggle arbitrary escape sequences (CSI / OSC) past bracketed
    // paste's framing and re-color the terminal, set the title, or set
    // the cursor as if the user had typed them.
    let sanitized = TerminalClipboard.sanitizePaste(raw)
    guard !sanitized.isEmpty else { return }
    let bytes = Array(sanitized.utf8)

    // Soft cap with a confirmation. Anything over a few KB is unusual
    // for terminal input; ChatGPT-style "I copied a giant blob"
    // accidents are common.
    if bytes.count > TerminalClipboard.warnLimitBytes {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Large paste"
      alert.informativeText = "About to paste \(bytes.count) bytes. Continue?"
      alert.addButton(withTitle: "Paste")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() != .alertFirstButtonReturn {
        EventLog.shared.log("paste.cancelled.size", ["bytes": bytes.count])
        return
      }
    }

    // Safety check: libghostty flags newlines / control bytes as
    // unsafe. When the receiving app has bracketed paste enabled it
    // can recognise paste boundaries explicitly, so we trust it and
    // skip the prompt. Raw shells (no bracketed paste) get the
    // prompt because a multi-line paste runs each line as a command.
    // Claude Code is exempt: it never enables bracketed paste, but its
    // chunk-arrival paste heuristic inserts pasted newlines into the
    // prompt buffer instead of submitting, so the warning is a false
    // alarm there (sanitizePaste already stripped everything except
    // tab / LF / CR, so "unsafe" can only mean newlines by this point).
    if !session.bracketedPasteEnabled(),
      !Session.pasteIsSafe(bytes)
    {
      if TerminalClipboard.tabRunsClaudeCode(activeTab) {
        EventLog.shared.log("paste.unsafe.exempt.claude", ["bytes": bytes.count])
      } else {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Paste contains control characters or newlines"
        alert.informativeText =
          "The active program isn't using bracketed paste. Pasting may run each line as a command. Continue?"
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn {
          EventLog.shared.log("paste.cancelled.unsafe", ["bytes": bytes.count])
          return
        }
      }
    }

    let inputFollowDeltaRows = followActiveBottomBeforeTerminalInput(session: session)
    recordInputFollowBottom(deltaRows: inputFollowDeltaRows)
    // For labpty / laband backends the local Session is fixture-mode (no
    // PTY in this process — the daemon owns it). writePasteCapturingBytes
    // would feed the encoded paste into the fixture VT, which renders the
    // paste content into the local grid at the cursor — visible as paste
    // digits leaking into adjacent UI rows. The daemon's PTY echo (if any)
    // arrives via the byte ring like every other output byte; that path is
    // the only one the local VT should receive paste-shaped input from.
    let sent: Session.CapturedPasteWrite
    if sessionCoordinator?.terminalClient != nil {
      sent = session.encodePaste(sanitized)
    } else {
      sent = session.writePasteCapturingBytes(sanitized)
    }
    if let sessionCoordinator, let activeTab = model.activeTab, !sent.bytes.isEmpty {
      do {
        try sessionCoordinator.write(
          sent.bytes,
          to: activeTab,
          session: session,
          size: model.terminalSize)
      } catch {
        // Never silently drop a paste (H-3). On the labpty backend an
        // oversized cooked-mode write is refused atomically with
        // LABPTY_E_INPUT_BACKPRESSURE (ADR 0008); surface it so the loss is
        // observable rather than vanishing with no log line.
        AppLog.app.error("paste write failed: \(String(describing: error))")
        EventLog.shared.log(
          "paste.failed",
          ["bytes": sent.bytes.count, "error": String(describing: error)])
      }
    }
    EventLog.shared.log(
      "paste",
      [
        "rawBytes": rawBytes,
        "sanitizedBytes": sanitized.utf8.count,
        "stripped": rawBytes - sanitized.utf8.count,
      ])
    recordInput(
      kind: "paste",
      route: "terminal",
      text: sanitized,
      command: "paste",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(sent.bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(sent.bytes)
    )

    // The paste has been emitted; drop the selection the user just pasted from.
    clearSelectionAfterPaste()
  }

  private func forwardClipboardImagePasteToTerminal(session: Session) {
    let inputFollowDeltaRows = followActiveBottomBeforeTerminalInput(session: session)
    recordInputFollowBottom(deltaRows: inputFollowDeltaRows)
    // 'v' (U+0076) is the unshifted codepoint a physical Ctrl+V carries. The key
    // encoder syncs from the live terminal, so when the foreground app enables
    // the Kitty keyboard protocol (Claude Code does) it encodes from the
    // codepoint rather than the key id — a synthesized event without it produces
    // zero bytes. That dropped cmd+V image pastes while a physical Ctrl+V (whose
    // codepoint comes from charactersIgnoringModifiers) kept working.
    let event = KeyEvent(
      action: .press,
      key: .v,
      modifiers: .control,
      unshiftedCodepoint: UInt32(UnicodeScalar("v").value))

    // Deliver the synthesized Ctrl+V exactly the way sendKeyEvent delivers a
    // physical one. A laband/labpty session has no PTY in this process — the
    // daemon owns it — so the local session's pty_fd is -1 and the send path
    // (sendKeyCapturingBytes) encodes the keystroke but then returns zero bytes
    // because it has nothing to write to. The pure key encoder produces the
    // bytes regardless of PTY ownership, and the coordinator forwards them to
    // the daemon PTY, so Claude Code receives Ctrl+V and reads the clipboard image.
    let bytes: [UInt8]
    if let sessionCoordinator {
      bytes = session.encodeKey(event) ?? []
      if !bytes.isEmpty, let activeTab = model.activeTab {
        try? sessionCoordinator.write(
          bytes,
          to: activeTab,
          session: session,
          size: model.terminalSize)
      }
    } else {
      let sent = session.sendKeyCapturingBytes(event)
      bytes = sent.result == 0 ? sent.bytes : []
    }
    EventLog.shared.log(
      "paste.image.forwarded",
      [
        "encodedBytes": bytes.count
      ])
    recordInput(
      kind: "key",
      route: "terminal",
      key: "v",
      modifiers: ["control"],
      command: "pasteImage",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
    )
    invalidateRenderAndWake()
  }

  private func pasteDroppedFilePaths(_ urls: [URL], sourceKinds: [String]) {
    guard !urls.isEmpty else { return }
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else {
      EventLog.shared.log("drop.cancelled", ["reason": "no-active-session"])
      return
    }

    let text = TerminalDrop.terminalText(for: urls)
    guard !text.isEmpty else { return }
    let inputFollowDeltaRows = followActiveBottomBeforeTerminalInput(session: session)
    recordInputFollowBottom(deltaRows: inputFollowDeltaRows)
    // Same backend split as the clipboard paste path: remote backends
    // (labpty / laband) must not have the encoded bytes fed into the
    // local fixture VT — only the daemon's PTY-echo via byte ring
    // should reach the local grid.
    let sent: Session.CapturedPasteWrite
    if sessionCoordinator?.terminalClient != nil {
      sent = session.encodePaste(text)
    } else {
      sent = session.writePasteCapturingBytes(text)
    }
    if let sessionCoordinator, !sent.bytes.isEmpty {
      try? sessionCoordinator.write(
        sent.bytes,
        to: activeTab,
        session: session,
        size: model.terminalSize)
    }
    EventLog.shared.log(
      "drop.files",
      [
        "count": urls.count,
        "sourceKinds": sourceKinds,
        "bytes": text.utf8.count,
      ])
    recordInput(
      kind: "drop",
      route: "terminal",
      text: text,
      command: "dropFiles",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(sent.bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(sent.bytes)
    )
    invalidateRenderAndWake()
  }

  // MARK: - Mouse (selection + sidebar hits + mouse tracking)

  override func scrollWheel(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    guard pt.y <= bounds.height - Self.titlebarReservedHeight else { return }
    if pt.x < sidebarWidth {
      scrollSidebar(with: event)
      return
    }

    guard
      let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else {
      return
    }

    guard let vs = session.viewportState() else { return }
    let mouseTracking = mouseTrackingActive(for: activeTab, session: session)

    // Shift+wheel is the universal escape hatch (iTerm2/Terminal.app/kitty) to
    // Laban's own scrollback even while a fullscreen app holds the mouse: skip
    // both the mouse-forward and alt-scroll branches so it falls through to the
    // local scrollback path below.
    let shiftScrollOverride = event.modifierFlags.contains(.shift)

    if mouseTracking && !localSelectionMouseGestureActive && !shiftScrollOverride {
      // Mouse tracking active: encode wheel as press+release. Use legacy
      // deltaY for notched wheels and precise scrollingDeltaY for trackpads.
      let direction = TerminalScrollInput.mouseTrackingWheelDirection(
        event: TerminalScrollInput.Event(
          deltaY: event.deltaY,
          scrollingDeltaY: event.scrollingDeltaY,
          hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        ))
      guard let direction else { return }
      let button: MouseButton = direction == .up ? .wheelUp : .wheelDown
      let geom = terminalMouseGeometry(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let me = MouseEvent(
        action: .press,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(me)
      let bytes = sent.result == 0 ? sent.bytes : []
      forwardEncodedMouseToDaemon(bytes, session: session)
      dismissLocalSelectionForForwardedInput()
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseWheel",
        encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
        encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
      )
      invalidateRenderAndWake()
      return
    }

    if vs.altScreen && vs.altScroll && !localSelectionMouseGestureActive && !shiftScrollOverride {
      // Alternate scroll mode (DEC private 1007): the app is on the alternate
      // screen, which has no scrollback for the wheel to move, so translate
      // wheel motion into cursor-key presses the app scrolls with (this is how
      // less/man/vim consume the wheel without enabling mouse reporting).
      // Reuse `decide` so trackpad feel and sub-cell residual carry match
      // native scrolling, and let the key encoder pick ESC O A vs ESC [ A from
      // the app's DECCKM state.
      let decision = TerminalScrollInput.decide(
        event: TerminalScrollInput.Event(
          deltaY: event.deltaY,
          scrollingDeltaY: event.scrollingDeltaY,
          hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        ),
        residualPx: scrollResidualPx,
        cellHeightPx: CGFloat(cellHeight)
      )
      scrollResidualPx = decision.newResidualPx
      guard let keys = TerminalScrollInput.altScrollKeys(rowsDelta: decision.rowsDelta)
      else {
        return
      }
      let key: Key = keys.key == .up ? .arrowUp : .arrowDown
      var bytes: [UInt8] = []
      for _ in 0..<keys.count {
        let sent = session.sendKeyCapturingBytes(KeyEvent(action: .press, key: key))
        if sent.result == 0 { bytes.append(contentsOf: sent.bytes) }
      }
      dismissLocalSelectionForForwardedInput()
      recordInput(
        kind: "scroll",
        route: "terminal",
        command: "altScroll",
        encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
        encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes),
        deltaRows: decision.rowsDelta
      )
      invalidateRenderAndWake()
      return
    }

    if event.hasPreciseScrollingDeltas && ScrollSettings.mode == .pixelSmooth {
      // Precise pixel-smooth path. Events only move the fractional target
      // accumulator; the rendered position chases it through the per-tick
      // PD resampler in `advanceFrame` (stiffness adapts to input speed).
      // Resampling is what makes velocity continuous: macOS quantizes slow
      // momentum deltas to whole points, so raw 1:1 tracking pulses 1-pt
      // steps with empty frames between — positionally exact, visibly
      // lumpy. The integer part reaches libghostty's viewport from the PD
      // tick (held at ≤ -1 while the target is in history so the
      // active-bottom snap cannot reset the gesture's accumulation); the
      // remainder renders as the sub-cell contentYOffset. Quantization
      // happens only at rest: once input goes quiet, the settle rounds the
      // target onto a whole row and the same controller glides it home.
      preciseScrollSettleWork?.cancel()
      preciseScrollSettleWork = nil
      // The notch-residual accumulator belongs to the quantized paths; a
      // stale carry must not leak into a later notched-wheel click.
      scrollResidualPx = 0
      if event.scrollingDeltaY != 0 {
        let rowsDelta = TerminalScrollInput.preciseRowsDelta(
          scrollingDeltaY: event.scrollingDeltaY,
          cellHeightPx: CGFloat(cellHeight))
        // Input-speed estimate for the resampler stiffness. A stream gap
        // resets it so a fresh gesture doesn't inherit stale speed.
        let nowInstant = ContinuousClock.now
        if let last = lastPreciseInputEventAt {
          let dt = Double((nowInstant - last).components.attoseconds) / 1e18
          preciseInputRowsPerSec =
            dt > 0.25
            ? 0
            : TerminalScrollInput.updatedInputVelocityEstimate(
              previous: preciseInputRowsPerSec, deltaRows: rowsDelta, dtSeconds: dt)
        } else {
          preciseInputRowsPerSec = 0
        }
        lastPreciseInputEventAt = nowInstant

        let previousTargetWholeRows = Int(targetScrollRows.rounded(.toNearestOrAwayFromZero))
        targetScrollRows = TerminalScrollInput.clampedFractionalTarget(
          targetScrollRows + rowsDelta,
          maxScrollbackRows: max(0, vs.totalRows - vs.viewportRows))
        let newTargetWholeRows = Int(targetScrollRows.rounded(.toNearestOrAwayFromZero))
        if ScrollDiagnostics.shared.isEnabled, let vs = session.viewportState() {
          ScrollDiagnostics.shared.event(
            kind: "scroll",
            off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows,
            sb: vs.scrollbackRows, alt: vs.altScreen, mouse: vs.mouseTracking,
            deltaRows: newTargetWholeRows - previousTargetWholeRows, applied: appliedScrollRows,
            note: "preciseWheel; target=\(targetScrollRows)")
        }
        if newTargetWholeRows != previousTargetWholeRows {
          recordInput(
            kind: "scroll",
            route: "terminal",
            command: "scrollViewport",
            deltaRows: newTargetWholeRows - previousTargetWholeRows
          )
          // Drag-extend through scroll, same as the quantized path below.
          if selectionFocus != nil, let pt = lastDragPoint {
            extendSelection(to: pt)
          }
        }
        renderInvalidated = true
      }
      let momentumEnded =
        event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled)
      // Fingers down or inertia flowing: the settle must wait. Phaseless
      // streams (synthetic events, some precise mice) report empty phases
      // and fall through to the quiescence timer.
      let gestureOrMomentumActive =
        !event.phase.intersection([.mayBegin, .began, .stationary, .changed]).isEmpty
        || !event.momentumPhase.intersection([.began, .changed]).isEmpty
      let settledTarget = TerminalScrollInput.settledTargetRows(
        displayedRows: targetScrollRows)
      let hasFraction =
        targetScrollRows != settledTarget || displayedScrollRows != settledTarget
      switch TerminalScrollInput.preciseSettleAction(
        momentumEnded: momentumEnded,
        gestureOrMomentumActive: gestureOrMomentumActive,
        hasFraction: hasFraction)
      {
      case .settleNow:
        if settledTarget == 0 {
          // A gesture/momentum that lands on (or overshoots into) the live
          // bottom pins immediately: chasing the last sub-row toward 0
          // leaves a window where streamed output lands below a
          // not-yet-pinned viewport and follow-output never re-engages —
          // the labpty-drift stall (bottom rows stale until a keystroke).
          applyScrollStep(
            toDesiredApplied: 0, tab: activeTab, session: session, resetOnClamp: true)
        } else {
          // Round the accumulated destination: the chase finishes the full
          // commanded distance and lands on a whole row.
          targetScrollRows = settledTarget
        }
      case .armQuiescence:
        armPreciseScrollSettle()
      case .none:
        break
      }
      // Let the display link pace rendering at the panel rate while the
      // stream flows: a synchronous full-damage render per event saturates
      // the main loop at larger window sizes and coalesces a 120 Hz event
      // stream (and the frames with it) down to ~60 fps. The first event of
      // a gesture finds the link parked and renders + un-parks explicitly
      // (ADR 0018 wake discipline); subsequent events only update state and
      // the next tick paints it. macOS 13's CVDisplayLink fallback reports
      // not-ticking and keeps the per-event wake.
      preciseScrollStreamActiveUntil = Date().addingTimeInterval(
        Self.preciseScrollStreamLinkHoldSeconds)
      if displayLinkIsTicking {
        updateDisplayLinkRunState()
      } else {
        advanceFrame(wake: .scrollWheel)
      }
      return
    }

    let decision = TerminalScrollInput.decide(
      event: TerminalScrollInput.Event(
        deltaY: event.deltaY,
        scrollingDeltaY: event.scrollingDeltaY,
        hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
      ),
      residualPx: scrollResidualPx,
      cellHeightPx: CGFloat(cellHeight)
    )
    scrollResidualPx = decision.newResidualPx
    if decision.rowsDelta != 0 {
      // Targeting below the live bottom is meaningless — the viewport can't
      // move past the active area — so clamp the accumulator at 0. Reaching 0
      // via a downward scroll then routes through applyScrollStep's
      // snap-to-active, so scroll-to-bottom follows output that streamed past
      // the old bottom while the user was scrolled up.
      // The rounding keeps this path's whole-row invariant after a
      // pixel-smooth gesture on another device left a fractional target.
      targetScrollRows = min(
        0, (targetScrollRows + Double(decision.rowsDelta)).rounded(.toNearestOrAwayFromZero))
      if ScrollDiagnostics.shared.isEnabled,
        let session = model.activeTab.flatMap({ model.session(forTab: $0.id) }),
        let vs = session.viewportState()
      {
        ScrollDiagnostics.shared.event(
          kind: "scroll",
          off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows,
          sb: vs.scrollbackRows, alt: vs.altScreen, mouse: vs.mouseTracking,
          deltaRows: decision.rowsDelta, applied: appliedScrollRows,
          note: "wheel; target=\(targetScrollRows)")
      }
      // Snap directly when:
      // - macOS reports precise (trackpad) deltas — already smoothed by the OS
      // - the input is small enough to be skim-reading clicks AND nothing is
      //   already animating (so continuous fast spins still get the glide)
      let isPrecise = event.hasPreciseScrollingDeltas
      let isSmallClick =
        abs(decision.rowsDelta) <= Self.scrollSmoothingThreshold && !scrollAnimating
      if isPrecise || isSmallClick {
        applyScrollStep(
          toDesiredApplied: Int(targetScrollRows.rounded(.toNearestOrAwayFromZero)),
          tab: activeTab,
          session: session,
          resetOnClamp: true)
        displayedScrollRows = Double(appliedScrollRows)
        scrollVelocityRowsPerSec = 0
      }
      recordInput(
        kind: "scroll",
        route: "terminal",
        command: "scrollViewport",
        deltaRows: decision.rowsDelta
      )
      // Drag-extend through scroll: if the user is mid-drag and scrolls
      // (e.g. with the trackpad in their other hand), re-evaluate the
      // selection at the same screen point so it follows the content
      // they're now looking at instead of staying anchored to the cell
      // they happened to last touch with the cursor.
      if selectionFocus != nil, let pt = lastDragPoint {
        extendSelection(to: pt)
      }
      renderInvalidated = true
    }
    // The single scroll wake: starts the glide immediately on a parked link.
    // The frame it produces sets `scrollAnimating`, whose defer-reconcile
    // un-parks the link at the active rate until the PD controller settles.
    advanceFrame(wake: .scrollWheel)
  }

  private func scrollSidebar(with event: NSEvent) {
    let producer = makeSidebarProducer()
    let maxOffset = producer.maxScrollOffset(
      tabCount: model.tabs.count,
      height: bounds.height,
      topInset: Self.titlebarReservedHeight)
    guard maxOffset > 0 else {
      resetSidebarScrollState()
      return
    }

    let delta: CGFloat
    if event.hasPreciseScrollingDeltas && ScrollSettings.mode == .pixelSmooth {
      sidebarScrollResidualPx = 0
      delta = CGFloat(
        TerminalScrollInput.preciseRowsDelta(
          scrollingDeltaY: event.scrollingDeltaY,
          cellHeightPx: 1))
    } else {
      let decision = TerminalScrollInput.decide(
        event: TerminalScrollInput.Event(
          deltaY: event.deltaY,
          scrollingDeltaY: event.scrollingDeltaY,
          hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas),
        residualPx: sidebarScrollResidualPx,
        cellHeightPx: producer.rowHeight)
      sidebarScrollResidualPx = decision.newResidualPx
      delta = CGFloat(decision.rowsDelta) * producer.rowHeight
    }

    guard delta != 0 else { return }
    let next = min(max(0, CGFloat(targetSidebarScrollOffset) + delta), maxOffset)
    guard abs(Double(next) - targetSidebarScrollOffset) > 0.001 else { return }
    targetSidebarScrollOffset = Double(next)
    sidebarScrollAnimating = true
    advanceFrame(wake: .scrollWheel)
  }

  private func externalHyperlinkURI(at pt: NSPoint) -> String? {
    guard let cell = termCell(at: pt),
      let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else {
      return nil
    }
    defer { laban_snapshot_destroy(snap) }
    guard let uri = TerminalHyperlink.uri(atRow: cell.row, col: cell.col, in: snap.pointee),
      TerminalHyperlinkOpening.browserURL(from: uri) != nil
    else {
      return nil
    }
    return uri
  }

  private func beginSelection(at pt: NSPoint, clickCount: Int) {
    syncSelectionStateToActiveTab()
    let hadSelection = selectionAnchor != nil && selectionFocus != nil
    let originCell = clampedSelectionPoint(at: pt)
    lastDragPoint = pt
    switch clickCount {
    case 2:
      selectionMode = .word
      selectionOriginCell = originCell
      selectWordAt(pt)
    case 3...:
      selectionMode = .line
      selectionOriginCell = originCell
      selectLineAt(pt)
    default:
      selectionMode = .char
      selectionOriginCell = originCell
      selectionAnchor = originCell
      selectionFocus = nil
    }
    if hadSelection, selectionAnchor == nil, selectionFocus == nil {
      recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    }
  }

  private func extendExistingSelection(at pt: NSPoint) -> Bool {
    syncSelectionStateToActiveTab()
    guard selectionAnchor != nil, selectionFocus != nil else { return false }
    selectionMode = .char
    selectionOriginCell = selectionAnchor
    lastDragPoint = pt
    extendSelection(to: pt)
    return true
  }

  private func beginLocalSelectionMouseGesture(at pt: NSPoint, clickCount: Int) {
    localSelectionMouseGestureActive = true
    if !extendExistingSelection(at: pt) {
      beginSelection(at: pt, clickCount: clickCount)
    }
  }

  private func updateLocalSelectionMouseGesture(to pt: NSPoint) {
    lastDragPoint = pt
    extendSelection(to: pt)
    updateDragAutoscroll(at: pt)
    if let anchor = selectionAnchor, let focus = selectionFocus {
      recordInput(
        kind: "selection",
        route: "terminal",
        command: "updateSelection",
        anchor: (row: anchor.row, col: anchor.col),
        focus: (row: focus.row, col: focus.col)
      )
    }
  }

  private func finishLocalSelectionMouseGesture(at pt: NSPoint) {
    localSelectionMouseGestureActive = false
    stopDragAutoscroll()
    lastDragPoint = nil
    // Only finalize focus if a drag established one. A bare click leaves
    // selectionFocus nil, which clears the rendered selection.
    if selectionFocus != nil {
      extendSelection(to: pt)
      if let anchor = selectionAnchor, let focus = selectionFocus {
        recordInput(
          kind: "selection",
          route: "terminal",
          command: "updateSelection",
          anchor: (row: anchor.row, col: anchor.col),
          focus: (row: focus.row, col: focus.col)
        )
      }
    } else {
      selectionAnchor = nil
      recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    }
  }

  private func clearSelectionAfterHyperlinkActivation() {
    let hadSelection = selectionAnchor != nil || selectionFocus != nil
    selectionAnchor = nil
    selectionFocus = nil
    selectionOriginCell = nil
    if hadSelection {
      recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    }
  }

  /// A bare click forwarded to the app (mouse reporting) is a deliberate pointer
  /// action, so it dismisses any committed local selection the same way a click
  /// does without tracking — scoped to the active tab, and scrubbed from the
  /// per-tab cache so it can't resurrect on a tab switch. Forwarded wheel
  /// input dismisses the selection too, because the remote app may move content
  /// under Laban's local highlight without Laban reprojecting the range.
  private func dismissLocalSelectionForForwardedInput() {
    guard selectionAnchor != nil || selectionFocus != nil else { return }
    syncSelectionStateToActiveTab()
    selectionAnchor = nil
    selectionFocus = nil
    selectionOriginCell = nil
    persistSelectionStateForCurrentTab()
    recordInput(kind: "selection", route: "terminal", command: "clearSelection")
  }

  /// A paste consumes the on-screen selection from the user's point of view:
  /// they selected, copied, and pasted, so the highlight has done its job and
  /// leaving it painted reads as stale. Scrub it the way a forwarded click does
  /// — scoped to the active tab and removed from the per-tab cache so it can't
  /// resurrect on a tab switch — and force a repaint so the highlight clears now
  /// rather than waiting on the app's paste echo.
  private func clearSelectionAfterPaste() {
    guard selectionAnchor != nil || selectionFocus != nil else { return }
    syncSelectionStateToActiveTab()
    selectionAnchor = nil
    selectionFocus = nil
    selectionOriginCell = nil
    persistSelectionStateForCurrentTab()
    recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    invalidateRenderAndWake()
  }

  private static func pointDistance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return (dx * dx + dy * dy).squareRoot()
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    pendingHyperlinkClick = nil

    // Reserved titlebar strip sits above both the terminal grid and the
    // sidebar tab list, behind the transparent system titlebar. Checked
    // before the sidebar hit test so that the sidebar's top strip (next
    // to the `+` accessory) gets the same window-chrome behavior as the
    // strip over the terminal grid. AppKit normally handles titlebar
    // clicks at the hit-test level, but with `fullSizeContentView` the
    // contentView intercepts the event first, so we dispatch the action
    // ourselves.
    if pt.y > bounds.height - Self.titlebarReservedHeight {
      mouseDownConsumedByChrome = true
      if event.clickCount == 2 {
        performTitlebarDoubleClickAction()
      }
      return
    }

    // Sidebar hit test.
    if pt.x < sidebarWidth {
      mouseDownConsumedByChrome = true
      let sp = SidebarProducer(
        sidebarWidth: sidebarWidth,
        cellWidth: CGFloat(sidebarCellWidth),
        cellHeight: CGFloat(sidebarCellHeight)
      )
      switch sp.hitTest(
        at: pt, tabs: model.tabs, height: bounds.height,
        topInset: Self.titlebarReservedHeight,
        scrollOffset: currentSidebarScrollOffsetForHitTesting())
      {
      case .newTab:
        _ = try? createTabPreservingSelection()
        invalidateRenderAndWake()
      case .selectTab(let id):
        selectTabPreservingSelection(id)
        // Arm the drag tracker. We do not activate until the cursor
        // moves past `sidebarDragActivationDistance`, so a plain
        // click-to-select still feels instant.
        sidebarDragState = SidebarDragState(
          tabId: id, origin: pt, activated: false, currentSlot: nil)
        invalidateRenderAndWake()
      case .closeTab(let id):
        do {
          try closeTabRegisteringUndo(id)
          pruneClosedTabState(id)
        } catch AppError.lastTabClosed {
          pruneClosedTabState(id)
          window?.close()
        } catch {}
        invalidateRenderAndWake()
      case .none: break
      }
      return
    }

    window?.makeFirstResponder(self)

    if TerminalHyperlinkOpening.shouldActivate(
      clickCount: event.clickCount,
      modifierFlags: event.modifierFlags
    ), let uri = externalHyperlinkURI(at: pt) {
      pendingHyperlinkClick = PendingHyperlinkClick(uri: uri, downPoint: pt)
      return
    }

    if event.modifierFlags.contains(.shift) {
      beginLocalSelectionMouseGesture(at: pt, clickCount: event.clickCount)
      invalidateRenderAndWake()
      return
    }
    localSelectionMouseGestureActive = false

    let mouseTracking: Bool = {
      guard let activeTab = model.activeTab,
        let session = model.session(forTab: activeTab.id)
      else { return false }
      return mouseTrackingActive(for: activeTab, session: session)
    }()
    switch TerminalMouseInput.leftMouseDownDisposition(
      mouseTracking: mouseTracking,
      shiftHeld: event.modifierFlags.contains(.shift)
    ) {
    case .forwardToApp:
      // The app has mouse tracking on (iTerm2/Ghostty model). Forward the press
      // now and claim the left button so mouseDragged forwards motion and
      // mouseUp forwards the release: the app runs its own selection and can
      // autoscroll its buffer past one screen, the only way to select text
      // spanning more than one screen in a fullscreen renderer.
      cancelSelectionDragForMouseTracking()
      // A forwarded press is a deliberate pointer action, so it dismisses any
      // existing local selection the same way a bare click does
      // (cancelSelectionDragForMouseTracking above only resets drag state, not
      // the committed selection).
      dismissLocalSelectionForForwardedInput()
      trackedMouseButton = .left
      resetTrackedMouseDragEdgeLatch()
      startTrackedMouseDragFramePump()
      forwardMousePress(at: pt, modifiers: event.labanModifiers)
    case .localSelection:
      // Focus stays nil until a drag actually happens, so a click without drag
      // clears any prior selection instead of leaving a one-cell highlight
      // behind. Double-click selects the word under the cursor; triple-click
      // selects the entire row.
      beginSelection(at: pt, clickCount: event.clickCount)
    }
    invalidateRenderAndWake()
  }

  override func mouseDragged(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if updateSidebarDrag(at: pt) {
      return
    }
    if mouseDownConsumedByChrome {
      return
    }
    if let pending = pendingHyperlinkClick {
      guard Self.pointDistance(pending.downPoint, pt) > Self.hyperlinkClickDragTolerance else {
        return
      }
      pendingHyperlinkClick = nil
      beginSelection(at: pending.downPoint, clickCount: 1)
      lastDragPoint = pt
      extendSelection(to: pt)
      updateDragAutoscroll(at: pt)
      if let anchor = selectionAnchor, let focus = selectionFocus {
        recordInput(
          kind: "selection",
          route: "terminal",
          command: "updateSelection",
          anchor: (row: anchor.row, col: anchor.col),
          focus: (row: focus.row, col: focus.col)
        )
      }
      invalidateRenderAndWake()
      return
    }

    if localSelectionMouseGestureActive {
      updateLocalSelectionMouseGesture(to: pt)
      invalidateRenderAndWake()
      return
    }

    // If mouse tracking is active, send motion events.
    if let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    {
      cancelSelectionDragForMouseTracking()
      guard pt.x >= sidebarWidth else { return }
      guard
        let button = TerminalMouseInput.trackedTerminalButton(
          trackedMouseButton,
          matching: .left
        )
      else {
        return
      }
      let geom = terminalMouseGeometryForForwardedLeftDrag(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let motionEvent = MouseEvent(
        action: .motion,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(motionEvent)
      let bytes = sent.result == 0 ? sent.bytes : []
      forwardEncodedMouseToDaemon(bytes, session: session)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseDragged",
        encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
        encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
      )
      invalidateRenderAndWake()
      return
    }
    updateLocalSelectionMouseGesture(to: pt)
    invalidateRenderAndWake()
  }

  /// Forward a left-button press to the active mouse-tracking app as an SGR
  /// mouse report. The matching motion and release are forwarded by
  /// mouseDragged and mouseUp once `trackedMouseButton` is `.left`. A bare
  /// click thus reports press-on-down and release-on-up, the order apps expect.
  private func forwardMousePress(at pt: NSPoint, modifiers: Int) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    else {
      return
    }
    let geom = terminalMouseGeometry(at: pt)
    let mouseEncoding = remoteMouseEncoding(for: activeTab)
    let pressEvent = MouseEvent(
      action: .press, button: .left,
      x: geom.x, y: geom.y,
      screenWidth: geom.screenWidth, screenHeight: geom.screenHeight,
      cellWidth: cellWidth, cellHeight: cellHeight, modifiers: modifiers,
      trackingMode: mouseEncoding?.trackingMode ?? 0,
      format: mouseEncoding?.format ?? 0)
    let sent = session.sendMouseCapturingBytes(pressEvent)
    let bytes = sent.result == 0 ? sent.bytes : []
    forwardEncodedMouseToDaemon(bytes, session: session)
    recordInput(
      kind: "mouse",
      route: "terminal",
      command: "mouseDown",
      encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
      encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
    )
  }

  override func mouseUp(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if commitSidebarDragIfActive(at: pt) {
      mouseDownConsumedByChrome = false
      return
    }
    if mouseDownConsumedByChrome {
      mouseDownConsumedByChrome = false
      return
    }
    if let pending = pendingHyperlinkClick {
      pendingHyperlinkClick = nil
      guard Self.pointDistance(pending.downPoint, pt) <= Self.hyperlinkClickDragTolerance else {
        return
      }
      clearSelectionAfterHyperlinkActivation()
      _ = TerminalHyperlinkOpening.open(pending.uri, using: urlOpener)
      EventLog.shared.log("hyperlink.open", ["url": pending.uri])
      recordInput(
        kind: "command",
        route: "appCommand",
        text: pending.uri,
        command: "openHyperlink")
      invalidateRenderAndWake()
      return
    }

    if localSelectionMouseGestureActive {
      finishLocalSelectionMouseGesture(at: pt)
      invalidateRenderAndWake()
      return
    }

    // If mouse tracking is active, send release event.
    if let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    {
      cancelSelectionDragForMouseTracking()
      guard
        let button = TerminalMouseInput.trackedTerminalButton(
          trackedMouseButton,
          matching: .left
        )
      else {
        return
      }
      let geom = terminalMouseGeometry(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let releaseEvent = MouseEvent(
        action: .release,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(releaseEvent)
      let bytes = sent.result == 0 ? sent.bytes : []
      forwardEncodedMouseToDaemon(bytes, session: session)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseUp",
        encodedHex: TerminalInputCaptureMetadata.encodedHex(bytes),
        encodedLength: TerminalInputCaptureMetadata.encodedLength(bytes)
      )
      if trackedMouseButton == .left { trackedMouseButton = .none }
      stopTrackedMouseDragFramePump()
      invalidateRenderAndWake()
      return
    }
    if trackedMouseButton == .left {
      trackedMouseButton = .none
      stopTrackedMouseDragFramePump()
    }
    finishLocalSelectionMouseGesture(at: pt)
    invalidateRenderAndWake()
  }

  override func rightMouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar right-click is consumed locally.
    if pt.x < sidebarWidth {
      return
    }

    if let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    {
      trackedMouseButton = .right
      let geom = terminalMouseGeometry(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let pressEvent = MouseEvent(
        action: .press,
        button: .right,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(pressEvent)
      forwardEncodedMouseToDaemon(sent.result == 0 ? sent.bytes : [], session: session)
      invalidateRenderAndWake()
    }
  }

  override func rightMouseDragged(with event: NSEvent) {
    if let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    {
      let pt = convert(event.locationInWindow, from: nil)
      guard pt.x >= sidebarWidth else { return }
      guard
        let button = TerminalMouseInput.trackedTerminalButton(
          trackedMouseButton,
          matching: .right
        )
      else {
        return
      }
      let geom = terminalMouseGeometry(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let motionEvent = MouseEvent(
        action: .motion,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(motionEvent)
      forwardEncodedMouseToDaemon(sent.result == 0 ? sent.bytes : [], session: session)
      invalidateRenderAndWake()
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    if let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      mouseTrackingActive(for: activeTab, session: session)
    {
      guard
        let button = TerminalMouseInput.trackedTerminalButton(
          trackedMouseButton,
          matching: .right
        )
      else {
        return
      }
      let pt = convert(event.locationInWindow, from: nil)
      let geom = terminalMouseGeometry(at: pt)
      let mouseEncoding = remoteMouseEncoding(for: activeTab)
      let releaseEvent = MouseEvent(
        action: .release,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers,
        trackingMode: mouseEncoding?.trackingMode ?? 0,
        format: mouseEncoding?.format ?? 0
      )
      let sent = session.sendMouseCapturingBytes(releaseEvent)
      forwardEncodedMouseToDaemon(sent.result == 0 ? sent.bytes : [], session: session)
      if trackedMouseButton == .right { trackedMouseButton = .none }
      invalidateRenderAndWake()
    }
    if trackedMouseButton == .right { trackedMouseButton = .none }
  }

  /// On the daemon-backed (labpty/laband) tier the local Session is fixture-mode,
  /// so `sendMouseCapturingBytes` only encodes — the bytes must reach the daemon's
  /// PTY the same way keystrokes and paste do, or no terminal app ever sees the
  /// mouse. No-op on the in-process tier (where `sendMouseCapturingBytes` already
  /// wrote locally) and when there is nothing to deliver.
  private func forwardEncodedMouseToDaemon(_ bytes: [UInt8], session: Session) {
    guard !bytes.isEmpty,
      let sessionCoordinator,
      sessionCoordinator.terminalClient != nil,
      let activeTab = model.activeTab
    else { return }
    try? sessionCoordinator.write(
      bytes,
      to: activeTab,
      session: session,
      size: model.terminalSize)
  }

  private func selectionGeometry() -> TerminalSelectionInput.GridGeometry {
    TerminalSelectionInput.GridGeometry(
      boundsWidth: bounds.width,
      boundsHeight: bounds.height,
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight),
      rows: lastRows,
      insets: Self.contentInsets)
  }

  // Convert a CG-coordinate view point to a terminal grid cell (row 0 = top).
  private func termCell(at pt: NSPoint) -> TerminalCellCoordinate? {
    TerminalSelectionInput.terminalCell(at: pt, geometry: selectionGeometry())
  }

  /// Like `termCell(at:)` but always returns a valid cell, clamped to the
  /// viewport edges. Used when extending a selection by drag — without
  /// clamping, dragging past the bottom would yield nil and clear the
  /// in-progress selection. Captures libghostty's viewport offset so the
  /// point tracks the actual content as the viewport scrolls.
  private func clampedSelectionPoint(at pt: NSPoint) -> TerminalSelectionPoint {
    TerminalSelectionInput.clampedPoint(
      at: pt,
      geometry: selectionGeometry(),
      viewportOffset: currentViewportOffset())
  }

  /// Word-grain selection at the click cell.
  private func selectWordAt(_ pt: NSPoint) {
    let p = clampedSelectionPoint(at: pt)
    let bounds = wordBoundsAt(row: p.row, col: p.col)
    selectionAnchor = TerminalSelectionPoint(
      row: p.row, col: bounds.start, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
    selectionFocus = TerminalSelectionPoint(
      row: p.row, col: bounds.end, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
  }

  /// Line-grain selection at the click cell.
  private func selectLineAt(_ pt: NSPoint) {
    let p = clampedSelectionPoint(at: pt)
    let cols = currentCols()
    selectionAnchor = TerminalSelectionPoint(
      row: p.row, col: 0, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
    selectionFocus = TerminalSelectionPoint(
      row: p.row, col: cols - 1, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
  }

  /// Find the word boundary cells at (row, col). Walks left and right
  /// along the row stopping at non-word characters. "Word chars" are
  /// alphanumerics plus the path / URL / identifier glue chars
  /// `-_./:~@` so file paths and URLs select cleanly.
  private func wordBoundsAt(row: Int, col: Int) -> (start: Int, end: Int) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else { return (col, col) }
    defer { laban_snapshot_destroy(snap) }
    return TerminalSelectionInput.wordBounds(row: row, col: col, in: snap.pointee)
  }

  private func currentCols() -> Int {
    selectionGeometry().cols
  }

  /// Update the selection from the current drag point, respecting the
  /// active selection grain. For char mode this is the existing behavior
  /// (focus = clamped cell at point). For word/line mode the selection
  /// spans the union of the original click word/line and the word/line
  /// at the drag point — without this, even tiny mouse jitter during a
  /// double-click collapses the just-selected word back to a single cell.
  private func extendSelection(to pt: NSPoint) {
    let p = clampedSelectionPoint(at: pt)
    switch selectionMode {
    case .char:
      selectionFocus = p
    case .word:
      extendWordSelection(to: p)
    case .line:
      extendLineSelection(to: p)
    }
  }

  private func extendWordSelection(to drag: TerminalSelectionPoint) {
    guard let orig = selectionOriginCell else {
      selectionFocus = drag
      return
    }
    let cols = currentCols()
    let origBounds = wordBoundsAt(row: orig.row, col: orig.col)
    let dragBounds = wordBoundsAt(row: drag.row, col: drag.col)
    let origStartLin = orig.row * cols + origBounds.start
    let origEndLin = orig.row * cols + origBounds.end
    let dragStartLin = drag.row * cols + dragBounds.start
    let dragEndLin = drag.row * cols + dragBounds.end
    let startLin = min(origStartLin, dragStartLin)
    let endLin = max(origEndLin, dragEndLin)
    selectionAnchor = TerminalSelectionPoint(
      row: startLin / cols, col: startLin % cols,
      viewportOffsetAtCapture: orig.viewportOffsetAtCapture)
    selectionFocus = TerminalSelectionPoint(
      row: endLin / cols, col: endLin % cols,
      viewportOffsetAtCapture: drag.viewportOffsetAtCapture)
  }

  private func extendLineSelection(to drag: TerminalSelectionPoint) {
    guard let orig = selectionOriginCell else {
      selectionFocus = drag
      return
    }
    let cols = currentCols()
    let topRow = min(orig.row, drag.row)
    let bottomRow = max(orig.row, drag.row)
    selectionAnchor = TerminalSelectionPoint(
      row: topRow, col: 0, viewportOffsetAtCapture: orig.viewportOffsetAtCapture)
    selectionFocus = TerminalSelectionPoint(
      row: bottomRow, col: cols - 1,
      viewportOffsetAtCapture: drag.viewportOffsetAtCapture)
  }

  /// libghostty's authoritative viewport offset for the active session,
  /// or 0 when unavailable. Used by selection translation so the rect
  /// follows the actual scroll position rather than a Swift accumulator
  /// that can drift past the scroll edges.
  private func currentViewportOffset() -> Int {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let vs = session.viewportState()
    else { return 0 }
    return vs.viewportOffset
  }

  private func mouseTrackingActive(for tab: Tab, session: Session) -> Bool {
    if sessionCoordinator?.usesRemoteSnapshots == true {
      return remoteMouseEncodingByTab[tab.id] != nil
    }
    return session.viewportState()?.mouseTracking == true
  }

  private func cacheRemoteMouseEncoding(_ snapshot: LabandSnapshotResponse, for tabId: Tab.ID) {
    guard snapshot.mouseTracking == true, let trackingMode = snapshot.mouseTrackingMode,
      trackingMode > 0
    else {
      remoteMouseEncodingByTab.removeValue(forKey: tabId)
      return
    }
    remoteMouseEncodingByTab[tabId] = (
      trackingMode: trackingMode,
      format: snapshot.mouseFormat ?? 0
    )
  }

  private func remoteMouseEncoding(for tab: Tab) -> (trackingMode: Int, format: Int)? {
    guard sessionCoordinator?.usesRemoteSnapshots == true else { return nil }
    return remoteMouseEncodingByTab[tab.id]
  }

  private func authoritativeAppliedRows(for session: Session) -> Int? {
    guard let vs = session.viewportState() else { return nil }
    return TerminalScrollInput.appliedRowsFromViewport(
      viewportOffset: vs.viewportOffset,
      totalRows: vs.totalRows,
      viewportRows: vs.viewportRows
    )
  }

  /// Re-arm the quiescence timer that settles a precise pixel-smooth gesture
  /// onto a whole row. Cancelled and re-armed by every precise event, so it
  /// fires only after ~150 ms of real input quiet — covering gestures that
  /// end without a momentum-end marker, momentum streams that die silently,
  /// phaseless precise devices, synthetic event streams, and a finger
  /// resting mid-gesture (which should sit on a whole row too).
  private func armPreciseScrollSettle() {
    preciseScrollSettleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.preciseScrollSettleWork = nil
      self.settlePreciseScrollToWholeRow()
    }
    preciseScrollSettleWork = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.preciseScrollSettleQuiescenceSeconds, execute: work)
  }

  /// Retarget the smooth-scroll controller onto the nearest whole row and
  /// wake the frame loop so the existing PD controller animates the
  /// remaining sub-cell distance (~80 ms at scrollOmega). The explicit wake
  /// is what un-parks an idle display link (ADR 0018).
  private func settlePreciseScrollToWholeRow() {
    preciseScrollSettleWork?.cancel()
    preciseScrollSettleWork = nil
    // Round the accumulated destination (not the lagging displayed
    // position): the resampler finishes the full commanded distance and
    // lands on a whole row.
    let settled = TerminalScrollInput.settledTargetRows(displayedRows: targetScrollRows)
    guard targetScrollRows != settled || displayedScrollRows != settled else { return }
    if settled == 0, let tab = model.activeTab, let session = model.session(forTab: tab.id) {
      // Landing on the live bottom pins immediately (no sub-row chase):
      // an animated approach leaves a window where streamed output lands
      // below a not-yet-pinned viewport — the labpty-drift stall.
      applyScrollStep(toDesiredApplied: 0, tab: tab, session: session, resetOnClamp: true)
    } else {
      targetScrollRows = settled
    }
    advanceFrame(wake: .scrollSettle)
  }

  private func resetSmoothScrollState(to appliedRows: Int) {
    appliedScrollRows = appliedRows
    displayedScrollRows = Double(appliedRows)
    targetScrollRows = Double(appliedRows)
    scrollVelocityRowsPerSec = 0
    lastScrollTickAt = nil
  }

  private func syncSmoothScrollState(
    session: Session,
    desiredAppliedRows: Int,
    resetOnClamp: Bool = true
  ) {
    guard let vs = session.viewportState() else {
      appliedScrollRows = desiredAppliedRows
      return
    }
    let reconciled = TerminalScrollInput.reconcileAppliedRows(
      desiredAppliedRows: desiredAppliedRows,
      viewportOffset: vs.viewportOffset,
      totalRows: vs.totalRows,
      viewportRows: vs.viewportRows
    )
    appliedScrollRows = reconciled.actualAppliedRows
    if resetOnClamp && reconciled.clamped {
      resetSmoothScrollState(to: reconciled.actualAppliedRows)
    }
  }

  /// Apply one smooth-scroll step toward `desiredApplied` (≤ 0; 0 == the live
  /// active bottom). When the step reaches the bottom, snap the viewport to the
  /// active area so it re-engages follow-output instead of moving by a bounded
  /// delta. A bounded delta stops on whatever pin `desiredApplied - applied`
  /// lands on, but output a non-alt-screen app (e.g. Codex) streamed while the
  /// user was scrolled back moves the true bottom past that pin — so a
  /// scroll-to-bottom would stall short of the live bottom and leave the overlay
  /// scroll indicator stuck visible at what only looks like the bottom. Snapping
  /// to active follows the real bottom wherever output pushed it.
  private func applyScrollStep(
    toDesiredApplied desiredApplied: Int,
    tab: Tab,
    session: Session,
    resetOnClamp: Bool
  ) {
    if desiredApplied >= 0 {
      snapScrollToActiveBottom(tab: tab, session: session)
      return
    }
    let delta = desiredApplied - appliedScrollRows
    guard delta != 0 else { return }
    scrollViewport(
      deltaRows: delta,
      tab: tab,
      session: session,
      desiredAppliedRows: desiredApplied,
      resetOnClamp: resetOnClamp)
    // A downward step (delta > 0 moves toward the live bottom) that reconciles
    // *further* from the bottom than it aimed — `appliedScrollRows` ends more
    // negative than `desiredApplied` — means a non-alt-screen app (e.g. Codex)
    // streamed output and pushed the live bottom past the step between our
    // viewport read and the scroll landing. Bounded steps then never catch the
    // receding bottom: the user nudges down a row, output adds a row, and the
    // overlay scroll indicator stays stuck a row short indefinitely (the
    // `targetScrollRows == 0` snap above only fires when a step lands exactly on
    // the bottom, which streaming prevents). Once within a small band of the
    // live bottom, pin to active so libghostty re-engages follow-output. The
    // band keeps a small down-scroll deep in history (navigation) from snapping.
    if delta > 0,
      appliedScrollRows < desiredApplied,
      appliedScrollRows >= -Self.scrollFollowReengageRows
    {
      if ScrollDiagnostics.shared.isEnabled, let vs = session.viewportState() {
        ScrollDiagnostics.shared.event(
          kind: "reengage",
          off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows,
          sb: vs.scrollbackRows, alt: vs.altScreen, mouse: vs.mouseTracking,
          deltaRows: delta, applied: appliedScrollRows,
          note: "step landed short of bottom; band-snapping")
      }
      snapScrollToActiveBottom(tab: tab, session: session)
    }
  }

  /// Snap the viewport to the live active bottom through whichever scroll path
  /// the session uses (remote daemon or in-process), then realign the
  /// smooth-scroll state to the reconciled position so the PD controller settles
  /// at the bottom and follows new output.
  private func snapScrollToActiveBottom(tab: Tab, session: Session) {
    if let sessionCoordinator, sessionCoordinator.usesRemoteSnapshots {
      // Remote daemon owns the authoritative viewport; reach it through the
      // coordinator with a delta computed from the latest snapshot state.
      if let vs = session.viewportState() {
        let toBottom = ViewportState.scrollDeltaToActiveBottom(
          viewportOffset: vs.viewportOffset,
          totalRows: vs.totalRows,
          viewportRows: vs.viewportRows)
        if toBottom > 0 {
          scrollViewport(
            deltaRows: toBottom,
            tab: tab,
            session: session,
            desiredAppliedRows: 0,
            resetOnClamp: false)
        }
      }
    } else {
      // Local session: pin atomically so the reader thread streaming output
      // can't move the live bottom between a delta read and the scroll and
      // leave us short of follow-output (the stuck-indicator race).
      session.scrollViewportToActiveBottom()
    }
    let snappedApplied = authoritativeAppliedRows(for: session) ?? 0
    resetSmoothScrollState(to: snappedApplied)
    if ScrollDiagnostics.shared.isEnabled, let vs = session.viewportState() {
      // What did the atomic pin actually land on? If `applied < 0` here, a feed
      // moved the bottom between the pin and this read-back, so the viewport is
      // already short of the live bottom again — follow-output won't be engaged.
      ScrollDiagnostics.shared.event(
        kind: "snap",
        off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows,
        sb: vs.scrollbackRows, alt: vs.altScreen, mouse: vs.mouseTracking,
        applied: snappedApplied,
        note: sessionCoordinator?.usesRemoteSnapshots == true ? "remote" : "local-pin")
    }
  }

  /// Drag-to-scrub from the overlay scrollbar (`spec.md` §scrollback): map a
  /// history fraction (0 = oldest scrollback, 1 = live bottom) to an absolute
  /// viewport offset and jump there immediately, settling the smooth-scroll PD
  /// state so the thumb tracks the pointer 1:1 with no glide. Reuses the shared
  /// `scrollViewport` path so it works on every backend (in-process, labpty,
  /// laband). No-op on the alternate screen or when there is no scrollback.
  func scrubViewportToHistoryFraction(_ fraction: Double) {
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id),
      let vs = session.viewportState(),
      !vs.altScreen
    else { return }
    let maxScrollback = max(0, vs.totalRows - vs.viewportRows)
    guard maxScrollback > 0 else { return }
    let target = Int((max(0, min(1, fraction)) * Double(maxScrollback)).rounded())
    let delta = target - vs.viewportOffset
    guard delta != 0 else { return }
    // applied-rows convention: appliedRows = viewportOffset - maxScrollback (≤ 0).
    let desiredApplied = target - maxScrollback
    scrollViewport(
      deltaRows: delta, tab: tab, session: session,
      desiredAppliedRows: desiredApplied, resetOnClamp: true)
    displayedScrollRows = Double(appliedScrollRows)
    targetScrollRows = Double(appliedScrollRows)
    scrollVelocityRowsPerSec = 0
    invalidateRenderAndWake()
    needsDisplay = true
  }

  @discardableResult
  private func followActiveBottomBeforeTerminalInput(session: Session) -> Int {
    let hadPendingScrollState =
      appliedScrollRows != 0
      || targetScrollRows != Double(appliedScrollRows)
      || displayedScrollRows != Double(appliedScrollRows)
      || abs(scrollVelocityRowsPerSec) > 0.001
      || scrollAnimating
      || scrollResidualPx != 0
    let deltaRows = session.scrollViewportToActiveBottom()
    let appliedRows = authoritativeAppliedRows(for: session) ?? 0
    resetSmoothScrollState(to: appliedRows)
    scrollResidualPx = 0
    scrollAnimating = false
    if deltaRows > 0 || hadPendingScrollState {
      invalidateRenderAndWake()
    }
    return deltaRows
  }

  /// Build the renderer-facing selection from view-state, translating each
  /// stored row by the actual viewport-offset delta since capture so the
  /// selection rect follows the underlying content as the viewport scrolls.
  private func currentTerminalSelection(sessionId: Session.ID) -> TerminalSelection? {
    currentTerminalSelection(
      sessionId: sessionId,
      currentViewportOffset: currentViewportOffset()
    )
  }

  private func currentTerminalSelection(
    sessionId: Session.ID,
    currentViewportOffset: Int
  ) -> TerminalSelection? {
    TerminalSelectionInput.terminalSelection(
      sessionId: sessionId,
      anchor: selectionAnchor,
      focus: selectionFocus,
      currentViewportOffset: currentViewportOffset)
  }

  // MARK: - Drag-edge auto-scroll

  /// Decide whether the active drag is pulling past the top or bottom edge
  /// of the terminal area and (re)arm or stop the auto-scroll timer to
  /// match. The terminal area is `[insets.bottom, bounds.height -
  /// insets.top]`; anything outside that band is considered an edge pull.
  private func updateDragAutoscroll(at pt: NSPoint) {
    let insets = Self.contentInsets
    let contentBottom = insets.bottom
    let contentTop = bounds.height - insets.top
    let direction = TerminalScrollInput.dragAutoscrollDeltaRows(
      pointerY: pt.y,
      contentBottom: contentBottom,
      contentTop: contentTop
    )
    if direction == 0 {
      stopDragAutoscroll()
    } else if dragAutoscrollDirection != direction {
      stopDragAutoscroll()
      dragAutoscrollDirection = direction
      let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
        [weak self] _ in self?.dragAutoscrollTick()
      }
      // Keep the timer firing during AppKit event-tracking modes (drag).
      RunLoop.current.add(timer, forMode: .eventTracking)
      dragAutoscrollTimer = timer
    }
  }

  private func stopDragAutoscroll() {
    dragAutoscrollTimer?.invalidate()
    dragAutoscrollTimer = nil
    dragAutoscrollDirection = 0
  }

  private func startTrackedMouseDragFramePump() {
    guard trackedMouseDragFrameTimer == nil else { return }
    let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
      [weak self] _ in self?.advanceFrame()
    }
    // AppKit switches the main run loop into event-tracking mode while the
    // mouse is held. Keep draining/repainting forwarded-mouse apps there too,
    // so fullscreen programs such as tmux can show their own drag autoscroll.
    RunLoop.current.add(timer, forMode: .eventTracking)
    trackedMouseDragFrameTimer = timer
  }

  private func stopTrackedMouseDragFramePump() {
    trackedMouseDragFrameTimer?.invalidate()
    trackedMouseDragFrameTimer = nil
    resetTrackedMouseDragEdgeLatch()
  }

  private func terminalMouseGeometryForForwardedLeftDrag(at pt: NSPoint) -> (
    x: Float, y: Float, screenWidth: Int, screenHeight: Int
  ) {
    var geom = terminalMouseGeometry(at: pt)
    guard let edge = trackedMouseDragVerticalEdge(for: geom) else {
      resetTrackedMouseDragEdgeLatch()
      return geom
    }

    if trackedMouseDragEdge != edge || shouldResetTrackedMouseDragEdgeX(to: geom.x) {
      trackedMouseDragEdge = edge
      trackedMouseDragEdgeX = geom.x
    }
    if let x = trackedMouseDragEdgeX {
      geom.x = x
    }
    return geom
  }

  private func trackedMouseDragVerticalEdge(
    for geom: (x: Float, y: Float, screenWidth: Int, screenHeight: Int)
  ) -> TrackedMouseDragVerticalEdge? {
    // tmux autoscroll is armed on the terminal edge row, before the pointer
    // necessarily leaves the grid.
    let edgeRowHeight = Float(max(cellHeight, 1))
    if geom.y < edgeRowHeight {
      return .top
    }
    let bottomEdgeY = max(0, Float(geom.screenHeight) - edgeRowHeight)
    if geom.y >= bottomEdgeY {
      return .bottom
    }
    return nil
  }

  private func shouldResetTrackedMouseDragEdgeX(to x: Float) -> Bool {
    guard let latchedX = trackedMouseDragEdgeX else { return true }
    let tolerance = Float(max(cellWidth, 1) * trackedMouseDragEdgeXJitterToleranceCells)
    return abs(x - latchedX) > tolerance
  }

  private func resetTrackedMouseDragEdgeLatch() {
    trackedMouseDragEdge = nil
    trackedMouseDragEdgeX = nil
  }

  private func cancelSelectionDragForMouseTracking() {
    stopDragAutoscroll()
    localSelectionMouseGestureActive = false
    lastDragPoint = nil
    selectionOriginCell = nil
  }

  /// Step the viewport one row in `dragAutoscrollDirection` and re-clamp
  /// the focus to the (new) edge cell. The selection tail is anchored to
  /// scroll position, so it grows naturally as we scroll.
  private func dragAutoscrollTick() {
    guard dragAutoscrollDirection != 0,
      let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let vs = session.viewportState(),
      !vs.mouseTracking || localSelectionMouseGestureActive
    else {
      stopDragAutoscroll()
      return
    }
    // Don't scroll forward past the active bottom of scrollback.
    guard
      TerminalScrollInput.canApplyDragAutoscroll(
        deltaRows: dragAutoscrollDirection,
        appliedRows: appliedScrollRows
      )
    else { return }
    scrollViewport(
      deltaRows: dragAutoscrollDirection,
      tab: activeTab,
      session: session,
      desiredAppliedRows: appliedScrollRows + dragAutoscrollDirection,
      resetOnClamp: true
    )
    // Keep the smooth-scroll PD controller in sync so a wheel input after
    // an auto-scroll doesn't snap us back to a stale target.
    displayedScrollRows = Double(appliedScrollRows)
    targetScrollRows = displayedScrollRows
    if let pt = lastDragPoint {
      selectionFocus = clampedSelectionPoint(at: pt)
    }
    // The 20 Hz autoscroll pump must paint each step itself: with a parked
    // link there is no other frame source while the pointer holds still past
    // the content edge.
    invalidateRenderAndWake()
  }

  private func terminalMouseGeometry(at pt: NSPoint) -> (
    x: Float, y: Float, screenWidth: Int, screenHeight: Int
  ) {
    let insets = Self.contentInsets
    let pos = TerminalMouseInput.surfacePosition(
      viewPoint: pt,
      boundsHeight: bounds.height - insets.top,
      sidebarWidth: sidebarWidth + insets.left
    )
    let size = TerminalMouseInput.surfaceSize(
      boundsWidth: bounds.width - insets.right,
      boundsHeight: bounds.height - insets.top - insets.bottom,
      sidebarWidth: sidebarWidth + insets.left
    )
    return (pos.x, pos.y, size.width, size.height)
  }

  // MARK: - Menu actions

  @objc func newTab(_ sender: Any?) {
    _ = try? createTabPreservingSelection()
    invalidateRenderAndWake()
  }

  @objc func closeTab(_ sender: Any?) {
    guard let tabId = model.activeTab?.id else { return }
    do {
      try closeTabRegisteringUndo(tabId)
      pruneClosedTabState(tabId)
    } catch AppError.lastTabClosed {
      pruneClosedTabState(tabId)
      window?.close()
      return
    } catch {}
    invalidateRenderAndWake()
  }

  @objc func selectTabByIndex(_ sender: Any?) {
    guard let item = sender as? NSMenuItem else { return }
    selectTab(at: item.tag - 1)
  }

  @objc func selectLastTab(_ sender: Any?) {
    selectLastTab()
  }

  @objc func increaseFontSize(_ sender: Any?) {
    applyFontSize(fontAtlas.pointSize + 1)
  }

  @objc func decreaseFontSize(_ sender: Any?) {
    applyFontSize(fontAtlas.pointSize - 1)
  }

  @objc func resetFontSize(_ sender: Any?) {
    applyFontSize(FontAtlas.defaultTerminalPointSize)
  }

  @objc func selectNextTab(_ sender: Any?) {
    selectRelativeTab(delta: 1)
  }

  @objc func selectPreviousTab(_ sender: Any?) {
    selectRelativeTab(delta: -1)
  }

  @objc func exportLastFiveSeconds(_ sender: Any?) { exportRecentBytes(seconds: 5) }
  @objc func exportLastTenSeconds(_ sender: Any?) { exportRecentBytes(seconds: 10) }
  @objc func exportLastThirtySeconds(_ sender: Any?) { exportRecentBytes(seconds: 30) }
  @objc func exportLastSixtySeconds(_ sender: Any?) { exportRecentBytes(seconds: 60) }

  /// Snapshot the active tab's recent-byte ring and write it out as
  /// an asciinema v2 cast file. Bytes that were dropped by ring
  /// overflow are not in the snapshot — for normal terminal usage
  /// the ring holds well over a minute, so 5/10/30/60 s windows
  /// always fit.
  private func exportRecentBytes(seconds: TimeInterval) {
    guard let tabId = model.activeTab?.id else {
      showCastAlert(title: "No active tab", message: "Open a tab and try again.")
      return
    }
    guard let ring = model.transcriptDelegate?.recentByteRing(forTabId: tabId) else {
      showCastAlert(
        title: "Recent-byte recording is not available",
        message:
          "This tab has no recent-byte recording — open a new tab and try again. "
          + "(The recording is always on; this state means no transcript host is wired, "
          + "which only happens in test or headless setups.)"
      )
      return
    }
    let castSnapshot = ring.castWindowSnapshot(window: seconds)
    let entries = castSnapshot.entries
    let size = model.terminalSize
    let cols = max(Int(size.cols), 1)
    let rows = max(Int(size.rows), 1)
    let initialFrameBytes = AsciinemaCast.fullFrameSnapshotBytes(
      replaying: castSnapshot.initialEntries,
      cols: cols,
      rows: rows)
    guard !entries.isEmpty || !initialFrameBytes.isEmpty else {
      showCastAlert(
        title: "Nothing to export",
        message:
          "No terminal output was recorded in the last \(Int(seconds)) seconds. Run a command and try again."
      )
      return
    }
    let title: String? = {
      guard let active = model.activeTab else { return nil }
      let raw = active.titleMetadata.workspace.cwd ?? active.title
      return raw.isEmpty ? nil : raw
    }()
    let startedAt = Date().addingTimeInterval(-seconds).timeIntervalSince1970
    do {
      let data = try AsciinemaCast.encode(
        entries: entries,
        cols: cols,
        rows: rows,
        title: title,
        startedAtUnixSeconds: startedAt,
        initialFrameBytes: initialFrameBytes,
        timelineBaseNanos: initialFrameBytes.isEmpty ? nil : castSnapshot.cutoffNanos)
      let url = try writeCast(data: data, seconds: Int(seconds))
      AppLog.app.info(
        "exported cast: \(url.path) (\(entries.count) chunks, \(data.count) bytes)")
      EventLog.shared.log(
        "cast.export",
        [
          "path": url.path,
          "window": "\(Int(seconds))s",
          "chunks": "\(entries.count)",
          "bytes": "\(data.count)",
        ])
      revealCastInFinder(url: url, seconds: Int(seconds))
    } catch {
      AppLog.app.error("cast export failed: \(error)")
      showCastAlert(
        title: "Export failed",
        message: "\(error.localizedDescription)")
    }
  }

  /// `~/Library/Logs/Laban/casts/` by default; overridable via
  /// `LABAN_CAST_DIR` for cases where the user wants casts somewhere
  /// auto-cleaned (e.g., a tmpfs).
  private static func castDirectory() -> URL {
    if let env = ProcessInfo.processInfo.environment["LABAN_CAST_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    if library == nil {
      AppLog.capture.error("Library directory unavailable; writing cast under temporary directory")
    }
    return (library ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("Logs/Laban/casts", isDirectory: true)
  }

  private func writeCast(data: Data, seconds: Int) throws -> URL {
    let dir = TerminalBitmapView.castDirectory()
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    let url = dir.appendingPathComponent("laban-\(stamp)-last\(seconds)s.cast")
    try data.write(to: url, options: [.atomic])
    return url
  }

  private func revealCastInFinder(url: URL, seconds: Int) {
    let alert = NSAlert()
    alert.messageText = "Exported last \(seconds) s to a cast file"
    alert.informativeText = """
      \(url.lastPathComponent)

      Heads up: terminal output can contain secrets (tokens, keys, .env contents). \
      Review the file before sharing it publicly.
      """
    alert.addButton(withTitle: "Open in Browser")
    alert.addButton(withTitle: "Reveal in Finder")
    alert.addButton(withTitle: "Copy Path")
    alert.addButton(withTitle: "Done")
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      do {
        let htmlURL = try openCastInBrowser(castURL: url)
        AppLog.app.info("opened cast HTML: \(htmlURL.path)")
      } catch {
        showCastAlert(
          title: "Could not open cast in browser",
          message: "\(error.localizedDescription)")
      }
    case .alertSecondButtonReturn:
      NSWorkspace.shared.activateFileViewerSelecting([url])
    case .alertThirdButtonReturn:
      let pb = NSPasteboard.general
      pb.clearContents()
      pb.setString(url.path, forType: .string)
    default:
      break
    }
  }

  /// Generate a self-contained HTML page that embeds the cast text
  /// inline and plays it back with the asciinema-player v3 bundle
  /// from a CDN. The HTML is written next to the `.cast` file so
  /// it's easy to find again later. Returns the HTML file URL.
  ///
  /// Inlining strategy: a `<script type="text/plain">` block holds
  /// the raw cast text. The browser does not execute it; the
  /// surrounding script reads `.textContent` and hands it to the
  /// asciinema player as the `data` source. This avoids the
  /// file://-CORS restrictions that would block a `<script src>` or
  /// `fetch()` of the sibling cast file.
  private func openCastInBrowser(castURL: URL) throws -> URL {
    let castData = try Data(contentsOf: castURL)
    let castText = String(data: castData, encoding: .utf8) ?? ""
    // PTY output containing the literal substring `</script>` is
    // extraordinarily unlikely but trivially defended against.
    let safeCast =
      castText.replacingOccurrences(of: "</script", with: "<\\/script")
    let title = castURL.lastPathComponent
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    let html = """
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <title>\(title) · Laban cast</title>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/asciinema-player@3.15.1/dist/bundle/asciinema-player.css">
        <style>
          html, body { height: 100%; margin: 0; padding: 0; background: #161616; color: #d8d8d8; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
          .wrap { max-width: 1200px; height: 100vh; box-sizing: border-box; margin: 0 auto; padding: 24px 24px 24px; display: flex; flex-direction: column; }
          h1 { flex: 0 0 auto; font-size: 13px; font-weight: 500; opacity: 0.7; margin: 0 0 12px; letter-spacing: 0.02em; }
          h1 code { font: 12px ui-monospace, "SF Mono", Menlo, monospace; opacity: 0.85; }
          #player { flex: 1 1 auto; min-height: 0; border-radius: 6px; overflow: hidden; }
        </style>
      </head>
      <body>
        <div class="wrap">
          <h1>Laban cast · <code>\(title)</code></h1>
          <div id="player"></div>
        </div>
        <script type="text/plain" id="cast">
      \(safeCast)
        </script>
        <script src="https://cdn.jsdelivr.net/npm/asciinema-player@3.15.1/dist/bundle/asciinema-player.min.js"></script>
        <script>
          AsciinemaPlayer.create(
            { data: () => document.getElementById('cast').textContent.trim() },
            document.getElementById('player'),
            { autoPlay: true, theme: 'monokai', fit: 'both' }
          );
        </script>
      </body>
      </html>
      """
    let htmlURL = castURL.deletingPathExtension().appendingPathExtension("html")
    try html.write(to: htmlURL, atomically: true, encoding: .utf8)
    NSWorkspace.shared.open(htmlURL)
    return htmlURL
  }

  private func showCastAlert(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  // MARK: - PTY-byte capture (debug)

  @objc func dumpRenderJournal(_ sender: Any?) {
    guard renderJournalEnabled else {
      let advice = RenderJournal.enablementAdvice()
      AppLog.render.info("render journal dump skipped because journal is disabled")
      EventLog.shared.log(
        "render.journal.dump.disabled",
        [
          "enableDefault": RenderJournal.enabledDefaultKey,
          "enableEnvironment": RenderJournal.enabledEnvironmentKey,
          "advice": advice,
        ])
      showRenderJournalDisabledAlert(advice: advice)
      return
    }
    do {
      let url = try renderJournal.dump(currentPNG: backend.pngData)
      AppLog.render.info("render journal dumped \(url.path)")
    } catch {
      AppLog.render.error("render journal dump failed: \(error)")
      EventLog.shared.log("render.journal.dump.failed", ["error": String(describing: error)])
    }
  }

  private func showRenderJournalDisabledAlert(advice: String) {
    let alert = NSAlert()
    alert.messageText = "Render Journal Is Disabled"
    alert.informativeText = advice
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  /// Toggle a full capture artifact. The directory path is printed to stderr so
  /// a user reproducing a bug can locate the capture without opening a save panel.
  @objc func toggleCapture(_ sender: Any?) {
    if let recorder = captureRecorder {
      let png = backend.pngData
      do {
        let manifest = try recorder.finish(
          interrupted: false,
          finalScreenshot: png,
          frame: renderedFrameCount
        )
        AppLog.capture.info("stopped \(manifest.path)")
        EventLog.shared.log("capture.stop", ["path": manifest.path])
      } catch {
        AppLog.capture.error("stop failed: \(error)")
      }
      captureRecorder = nil
      surfaceController.captureSink = nil
      // Capture stopped: drop the per-frame readback blit again.
      (backend as? MetalRenderer)?.captureMode = false
      model.captureSink = nil
      updateCaptureIndicator()
      invalidateRenderAndWake()
      return
    }

    let dir = TerminalBitmapView.captureDirectory()
    let stamp = ISO8601DateFormatter().string(from: Date())
      .replacingOccurrences(of: ":", with: "-")
    do {
      let recorder = try CaptureRecorder(
        artifactRoot: dir,
        name: "appkit-\(stamp)",
        screenshots: .final,
        executable: "LabanApp"
      )
      captureRecorder = recorder
      surfaceController.captureSink = recorder
      // Capture started: turn on the per-frame drawable→CPU readback so
      // pngData has bytes to serve. Off-state was the default since boot.
      (backend as? MetalRenderer)?.captureMode = true
      model.captureSink = recorder
      model.recordExistingStateForCapture()
      updateCaptureIndicator()
      AppLog.capture.info("started \(recorder.directoryURL.path)")
      EventLog.shared.log("capture.start", ["path": recorder.directoryURL.path])
      invalidateRenderAndWake()
    } catch {
      AppLog.capture.error("failed to start: \(error)")
    }
  }

  /// Single source of truth for "a capture is running" used by the Debug-menu
  /// title, the window-title suffix, and the on-surface "● REC" pill. The
  /// app-side recorder is the authority: it is attached exactly while capturing.
  var isCaptureActive: Bool { captureRecorder != nil }

  /// Mutate the persistent Debug-menu item's title in place (Start/Stop PTY
  /// Capture) rather than rebuilding the menu — the Show/Hide Sidebar pattern.
  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(TerminalBitmapView.toggleCapture(_:)) {
      menuItem.title = TerminalCaptureIndicator.menuTitle(active: isCaptureActive)
      return true
    }
    // Quick Look needs a selection to name a file; disable it otherwise.
    if menuItem.action == #selector(TerminalBitmapView.quickLookSelection(_:)) {
      return selectionAnchor != nil && selectionFocus != nil
    }
    return true
  }

  /// Show the "● REC" pill while capturing, hide it otherwise. Driven from
  /// `advanceFrame` off the same `isCaptureActive` state as the menu title.
  private func updateCaptureIndicator() {
    if isCaptureActive {
      let indicator: TerminalCaptureIndicatorView
      if let existing = captureIndicatorView {
        indicator = existing
      } else {
        indicator = TerminalCaptureIndicatorView(frame: .zero)
        captureIndicatorView = indicator
        addSubview(indicator)
      }
      indicator.isHidden = false
      layoutCaptureIndicator()
    } else {
      captureIndicatorView?.removeFromSuperview()
      captureIndicatorView = nil
    }
  }

  /// Pin the pill to the top-right corner of the terminal content area, just
  /// inside the inset so it clears the titlebar and right edge.
  private func layoutCaptureIndicator() {
    guard let indicator = captureIndicatorView else { return }
    let size = TerminalCaptureIndicatorView.preferredSize
    let content = terminalContentRect()
    let margin: CGFloat = 8
    let x = content.maxX - size.width - margin
    let y = content.maxY - size.height - margin
    indicator.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
  }

  /// `~/Library/Logs/Laban/captures` by default; overridable via
  /// `LABAN_CAPTURE_DIR` for cases where the user wants captures somewhere
  /// auto-cleaned (e.g., a tmpfs).
  private static func captureDirectory() -> URL {
    if let env = ProcessInfo.processInfo.environment["LABAN_CAPTURE_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    if library == nil {
      AppLog.capture.error(
        "Library directory unavailable; writing capture under temporary directory")
    }
    let logs = (library ?? FileManager.default.temporaryDirectory)
      .appendingPathComponent("Logs/Laban/captures", isDirectory: true)
    return logs
  }
}

// MARK: - NSEvent modifier conversion for mouse events

extension NSEvent {
  /// Convert AppKit modifier flags to Ghostty's modifier bit mask.
  /// Bit 0 = Shift, Bit 1 = Ctrl, Bit 2 = Alt/Option, Bit 3 = Super/Command.
  fileprivate var labanModifiers: Int {
    TerminalMouseInput.ghosttyModifierMask(from: modifierFlags)
  }
}

// MARK: - Scroll-indicator diagnostics (gated by --scroll-debug)

extension TerminalBitmapView {
  /// One read of everything the overlay scroll indicator depends on, plus the
  /// view's own scroll belief and window focus. Served by `ScrollDebugServer`.
  struct ScrollDebugSnapshot {
    var available: Bool
    var off: Int
    var total: Int
    var vp: Int
    var sb: Int
    var linesBack: Int
    var alt: Bool
    var mouse: Bool
    var focused: Bool
    var applied: Int
    var displayed: Double
    var target: Double
    var animating: Bool
    var renderedFrame: Int

    var dictionary: [String: Any] {
      [
        "available": available, "off": off, "total": total, "vp": vp, "sb": sb,
        "linesBack": linesBack, "alt": alt, "mouse": mouse, "focused": focused,
        "applied": applied, "displayed": displayed, "target": target,
        "animating": animating, "renderedFrame": renderedFrame,
      ]
    }
  }

  func debugScrollSnapshot() -> ScrollDebugSnapshot {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let vs = session.viewportState()
    else {
      return ScrollDebugSnapshot(
        available: false, off: 0, total: 0, vp: 0, sb: 0, linesBack: 0, alt: false,
        mouse: false, focused: window?.isKeyWindow == true, applied: appliedScrollRows,
        displayed: displayedScrollRows, target: targetScrollRows, animating: scrollAnimating,
        renderedFrame: renderedFrameCount)
    }
    return ScrollDebugSnapshot(
      available: true,
      off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows, sb: vs.scrollbackRows,
      linesBack: ScrollDiagnostics.linesBack(
        off: vs.viewportOffset, total: vs.totalRows, vp: vs.viewportRows),
      alt: vs.altScreen, mouse: vs.mouseTracking, focused: window?.isKeyWindow == true,
      applied: appliedScrollRows, displayed: displayedScrollRows, target: targetScrollRows,
      animating: scrollAnimating, renderedFrame: renderedFrameCount)
  }

  /// Drive a row-quantised scroll through the same single-step path the wheel
  /// handler's small-click branch uses, so a programmatic repro exercises the
  /// real `applyScrollStep` / snap-to-active-bottom logic. Negative scrolls up
  /// into history; positive scrolls toward the live bottom.
  func debugScrollByRows(_ rows: Int) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    targetScrollRows = min(0, targetScrollRows + Double(rows))
    applyScrollStep(
      toDesiredApplied: Int(targetScrollRows.rounded(.toNearestOrAwayFromZero)),
      tab: activeTab, session: session, resetOnClamp: true)
    displayedScrollRows = Double(appliedScrollRows)
    scrollVelocityRowsPerSec = 0
    invalidateRenderAndWake()
    needsDisplay = true
  }

  func debugSnapToBottom() {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }
    snapScrollToActiveBottom(tab: activeTab, session: session)
    invalidateRenderAndWake()
    needsDisplay = true
  }

  @discardableResult
  func debugWriteInput(_ bytes: [UInt8]) -> Bool {
    guard model.activeTab != nil else { return false }
    sendBytes(bytes)
    return true
  }

  func debugAccessibilityState() -> [String: Any] {
    [
      "isElement": isAccessibilityElement(),
      "role": accessibilityRole()?.rawValue ?? "",
      "label": accessibilityLabel() ?? "",
      "value": accessibilityVisibleText(),
      "focusRingType": focusRingType.rawValue,
      "increaseContrast": accessibilityDisplayOptions.increaseContrast,
      "differentiateWithoutColor": accessibilityDisplayOptions.differentiateWithoutColor,
      "reduceTransparency": accessibilityDisplayOptions.reduceTransparency,
    ]
  }

  /// Effective DEC private mode state for the active session, read from a fresh
  /// snapshot. GUI parity for the headless `/debug/terminal-modes` endpoint so
  /// the mode-2027 (grapheme cluster) handshake is observable from both paths.
  func debugTerminalModesState() -> [String: Any] {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let snap = session.snapshot()
    else {
      return [
        "grapheme_cluster_2027": false,
        "synchronized_output": false,
        "focus_reporting": false,
        "mouse_tracking": false,
      ]
    }
    defer { laban_snapshot_destroy(snap) }
    return [
      "grapheme_cluster_2027": snap.pointee.grapheme_cluster_2027 != 0,
      "synchronized_output": snap.pointee.synchronized_output != 0,
      "focus_reporting": snap.pointee.focus_reporting != 0,
      "mouse_tracking": snap.pointee.mouse_tracking != 0,
    ]
  }

  /// Enable the Metal drawable→CPU readback so `/scroll/screenshot.png` returns a
  /// fresh frame. A no-op on the software backend (which always keeps the last
  /// CGImage). Costs a per-frame blit, acceptable for a debug session.
  func debugEnableScreenshotReadback() {
    (backend as? MetalRenderer)?.captureMode = true
    invalidateRenderAndWake()
    needsDisplay = true
  }

  func debugFramePNG() -> Data? {
    (backend as? MetalRenderer)?.captureMode = true
    return backend.pngData
  }
}

// MARK: - CVDisplayLink lifetime indirection

/// Weak-ref holder used as the userInfo for `CVDisplayLinkSetOutputCallback`.
/// The proxy is retained for the link's lifetime; the weak `view` makes
/// callbacks that fire after the view is gone harmless.
private final class CVDisplayLinkProxy {
  weak var view: TerminalBitmapView?
  init(_ view: TerminalBitmapView) { self.view = view }
}
