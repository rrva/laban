import AppKit
import CoreGraphics
import CoreVideo
import LabanCore
import LabanDebug
import LabanRenderer
import LabanTerminalCore
import QuartzCore
import os

protocol ExternalURLOpening {
  @discardableResult
  func open(_ url: URL) -> Bool
}

extension NSWorkspace: ExternalURLOpening {}

enum TerminalHoverCursorStyle: Equatable {
  case arrow
  case pointingHand
}

private final class AppKitFrameProbe {
  private struct ProbeGlyph: Encodable {
    var x: Double
    var y: Double
    var text: String
  }

  private struct ProbeCursor: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
  }

  private struct ProbeEvent: Encodable {
    var schemaVersion = 1
    var frame: Int
    var timeNs: UInt64
    var surfaceWidth: Int
    var surfaceHeight: Int
    var surfaceScale: Double
    var commandCount: Int
    var cursorRow: Int
    var cursorCol: Int
    var cursorVisible: Bool
    var terminalGlyphs: [ProbeGlyph]
    var cursors: [ProbeCursor]
  }

  private let handle: FileHandle
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  init(directory: URL) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("frame-probe.ndjson")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
  }

  func record(
    frame: Int,
    snapshot: LabanSnapshot,
    commands: [FrameCommand],
    surfaceWidth: Int,
    surfaceHeight: Int,
    surfaceScale: Double
  ) {
    var glyphs: [ProbeGlyph] = []
    var cursors: [ProbeCursor] = []
    for command in commands {
      switch command {
      case .glyphRun(let origin, let text, _, _, _, let source, _, _, _)
      where source == .terminal:
        glyphs.append(ProbeGlyph(x: Double(origin.x), y: Double(origin.y), text: text))
      case .cursor(let rect, _):
        cursors.append(
          ProbeCursor(
            x: Double(rect.origin.x), y: Double(rect.origin.y),
            width: Double(rect.size.width), height: Double(rect.size.height)))
      default:
        break
      }
    }

    let event = ProbeEvent(
      frame: frame,
      timeNs: CaptureClock.nowNs(),
      surfaceWidth: surfaceWidth,
      surfaceHeight: surfaceHeight,
      surfaceScale: surfaceScale,
      commandCount: commands.count,
      cursorRow: Int(snapshot.cursor_row),
      cursorCol: Int(snapshot.cursor_col),
      cursorVisible: snapshot.cursor_visible != 0,
      terminalGlyphs: glyphs,
      cursors: cursors)
    guard let data = try? encoder.encode(event) else { return }
    handle.write(data)
    handle.write(Data([0x0A]))
  }

  func close() {
    try? handle.close()
  }

  deinit { close() }
}

private final class AppKitResizeProbe {
  private struct ProbeRect: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
      x = Double(rect.origin.x)
      y = Double(rect.origin.y)
      width = Double(rect.size.width)
      height = Double(rect.size.height)
    }
  }

  private struct ProbeSize: Encodable {
    var width: Double
    var height: Double

    init(_ size: CGSize) {
      width = Double(size.width)
      height = Double(size.height)
    }
  }

  private struct ProbeEvent: Encodable {
    var schemaVersion = 1
    var sequence: Int
    var label: String
    var timeNs: UInt64
    var renderedFrame: Int
    var windowNumber: Int
    var windowFrame: ProbeRect
    var viewBounds: ProbeRect
    var layerBounds: ProbeRect?
    var drawableSize: ProbeSize
    var screenshotPath: String?
  }

  private let directory: URL
  private let screenshotsDirectory: URL
  private let handle: FileHandle
  private var sequence = 0
  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }()

  init(directory: URL) throws {
    self.directory = directory
    screenshotsDirectory = directory.appendingPathComponent("screenshots", isDirectory: true)
    try FileManager.default.createDirectory(
      at: screenshotsDirectory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("resize-probe.ndjson")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
  }

  func record(
    label: String,
    window: NSWindow,
    view: NSView,
    backend: RendererBackend,
    renderedFrame: Int
  ) {
    sequence += 1
    let safeLabel = label.map { char -> Character in
      char.isLetter || char.isNumber || char == "-" || char == "_" ? char : "-"
    }
    let screenshotName = String(format: "%03d-%@.png", sequence, String(safeLabel))
    let screenshotURL = screenshotsDirectory.appendingPathComponent(screenshotName)
    let screenshotPath: String?
    if let image = CGWindowListCreateImage(
      .null,
      .optionIncludingWindow,
      CGWindowID(window.windowNumber),
      [.boundsIgnoreFraming, .nominalResolution]),
      let data = PNGEncoder.encode(image)
    {
      try? data.write(to: screenshotURL, options: [.atomic])
      screenshotPath = "screenshots/\(screenshotName)"
    } else {
      screenshotPath = nil
    }

    let event = ProbeEvent(
      sequence: sequence,
      label: label,
      timeNs: CaptureClock.nowNs(),
      renderedFrame: renderedFrame,
      windowNumber: window.windowNumber,
      windowFrame: ProbeRect(window.frame),
      viewBounds: ProbeRect(view.bounds),
      layerBounds: view.layer.map { ProbeRect($0.bounds) },
      drawableSize: ProbeSize(
        CGSize(width: backend.surfaceWidth, height: backend.surfaceHeight)),
      screenshotPath: screenshotPath)
    guard let payload = try? encoder.encode(event) else { return }
    handle.write(payload)
    handle.write(Data([0x0A]))
  }

  func close() {
    try? handle.close()
  }

  deinit { close() }
}

final class TerminalBitmapView: NSView, NSTextInputClient {

  /// Reserved strip at the top of the contentView that sits behind the
  /// transparent full-size titlebar. Picked to clear the standard window
  /// traffic-light cluster (~22 pt visually + breathing room).
  static let titlebarReservedHeight: CGFloat = 28
  static let contentInsets = NSEdgeInsets(
    top: 8 + titlebarReservedHeight, left: 14, bottom: 8, right: 8)

  private let model: AppModel
  private let urlOpener: any ExternalURLOpening
  private let fontAtlas: FontAtlas
  /// Either a SoftwareBackend (legacy path: blits a CGImage in `draw(_:)`)
  /// or a MetalRenderer (self-presents into its own CAMetalLayer). Picked at
  /// init time; toggle with the LABAN_RENDERER env var (`metal` is default,
  /// `software` falls back to the CG path used through 2026-05).
  private var backend: RendererBackend
  /// True when `backend` self-presents — TerminalBitmapView skips its own
  /// draw() blit and lets the layer composite directly.
  private let backendSelfPresents: Bool
  private let cellWidth: Int
  private let cellHeight: Int
  private let sidebarWidth: CGFloat = SidebarLayout.defaultWidth
  // Vsync-aligned tick.
  // - macOS 14+: CADisplayLink with a `preferredFrameRateRange` so a
  //   ProMotion panel can drop to a low rate when the terminal is idle and
  //   ramp up under load. Real VRR.
  // - macOS 13: CVDisplayLink as fallback. Vsync-aligned, no VRR throttle —
  //   always fires at the panel's max refresh.
  private var caDisplayLink: AnyObject?
  private var cvDisplayLink: CVDisplayLink?

  // Last known terminal grid size (updated each frame)
  private var lastRows: Int = 24

  /// One end of a selection. Stores the cell coordinate the user clicked
  /// AND libghostty's authoritative viewport offset at that moment so the
  /// selection tracks the actual content even after the user scrolls.
  ///
  /// `viewportOffsetAtCapture` is `scrollbar.offset` from libghostty:
  /// "offset into the total scrollable area that the viewport's top is
  /// at". 0 = scrolled all the way back; `total - len` = at-bottom.
  /// Decreases as the user scrolls back, increases as they scroll
  /// forward toward the latest output. Clamped by libghostty at the
  /// edges, which is *why* we use it instead of our own Swift counter
  /// — the Swift counter can drift past the edge (logging requested
  /// scrolls libghostty refuses to honor) and the rect drifts with it.
  private struct SelectionPoint: Equatable {
    var row: Int
    var col: Int
    var viewportOffsetAtCapture: Int

    func visibleRow(currentViewportOffset: Int) -> Int {
      row + (viewportOffsetAtCapture - currentViewportOffset)
    }
  }

  private var selectionAnchor: SelectionPoint?
  private var selectionFocus: SelectionPoint?

  /// Grain of the active selection. Set on mouseDown by the click count;
  /// drives whether mouseDragged extends by character (`.char`), by word
  /// boundary (`.word`), or by full line (`.line`). Without this, even
  /// 1-pixel jitter during a double-click would fire mouseDragged and
  /// collapse the just-selected word back to a single character.
  private enum SelectionMode { case char, word, line }
  private var selectionMode: SelectionMode = .char
  /// The cell the user originally clicked when starting a word- or
  /// line-grain selection. Drag extension recomputes the selection union
  /// from this origin to the current drag cell, in the chosen grain —
  /// without remembering the origin we'd lose it the moment a drag fires.
  private var selectionOriginCell: SelectionPoint?
  private struct PendingHyperlinkClick {
    var uri: String
    var downPoint: NSPoint
  }
  private var pendingHyperlinkClick: PendingHyperlinkClick?
  private static let hyperlinkClickDragTolerance: CGFloat = 3
  /// Per-tab saved selection state. Without this, switching tabs leaves
  /// the previous tab's selection rectangle painted across the new tab's
  /// grid (the renderer reads view-level state, not session-level). On
  /// tab switch we save the outgoing tab's pair into this dict and
  /// restore the incoming tab's pair from it.
  private var selectionsByTab: [Tab.ID: (anchor: SelectionPoint, focus: SelectionPoint?)] = [:]
  private var trackedMouseButton: MouseButton = .none

  enum PasteboardStringRead: Equatable {
    case empty
    case tooLarge(Int)
    case value(String, bytes: Int)
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
  private var hoverCursorStyle: TerminalHoverCursorStyle?

  // Damage-driven render budget state
  private var renderInvalidated = true
  private var themeChangeObserver: NSObjectProtocol?
  private var lastRenderedActiveTabId: Tab.ID?
  private var scrollResidualPx: CGFloat = 0

  /// Last cols value applied to libghostty. Used to detect when a reflow
  /// invalidates the selection's grid coordinates so we can drop it.
  private var lastAppliedCols: Int = 0

  // Smooth-scroll animation state. Wheel input adds to `targetScrollRows`
  // (cumulative target). A critically-damped PD controller advances
  // `displayedScrollRows` toward the target each frame, applying the
  // integer delta to libghostty's viewport and the sub-cell remainder as
  // a vertical pixel shift in the renderer. Trackpad (precise) input
  // bypasses smoothing — macOS already smoothed it. Reset on tab switch.
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
  // Wheel deltas at or below this magnitude snap directly when nothing's
  // already animating. Single click-and-read scrollback navigation feels
  // crisp; only fast continuous spins go through the controller.
  private static let scrollSmoothingThreshold: Int = 3
  /// Set true by the per-frame PD controller while it's still moving
  /// `displayedScrollRows` toward `targetScrollRows`. The render path
  /// reads it to (1) compute the sub-cell `contentYOffset` and (2) force
  /// damage = .full so the persistent target is fully repainted at the
  /// new fractional position.
  private var scrollAnimating: Bool = false

  // IME composition buffer
  private var markedText: NSAttributedString = .init(string: "")

  // Active key descriptor during interpretKeyEvents dispatch
  private var currentKeyDescriptor: TerminalKeyDescriptor?

  // Tracks last surface dimensions to avoid redundant reallocations
  private var lastPixelWidth: Int = 0
  private var lastPixelHeight: Int = 0
  private var lastSurfaceScale: CGFloat = 0
  private var captureRecorder: CaptureRecorder?
  private var frameProbe: AppKitFrameProbe?
  private var resizeProbe: AppKitResizeProbe?
  private var resizeAutomationScheduled = false
  private var renderingResizeFrame = false
  private var renderedFrameCount: Int = 0
  var renderedFrameCountForTests: Int { renderedFrameCount }

  private var windowFocusObservers: [NSObjectProtocol] = []
  private var lastReportedFocusBySession: [Session.ID: Bool] = [:]

  struct SynchronizedOutputHold: Equatable {
    var sessionId: Session.ID
    var startedAt: Date
  }

  struct SynchronizedOutputGateDecision: Equatable {
    var shouldDefer: Bool
    var shouldResetMode: Bool
    var hold: SynchronizedOutputHold?
  }

  struct OutputSettleHold: Equatable {
    var sessionId: Session.ID
    var startedAt: Date
  }

  struct OutputSettleGateDecision: Equatable {
    var shouldDefer: Bool
    var hold: OutputSettleHold?
    var wakeAfter: TimeInterval?
  }

  private static let synchronizedOutputMaxHoldSeconds: TimeInterval = 1.0
  private var synchronizedOutputHold: SynchronizedOutputHold?
  var synchronizedOutputHoldForTests: SynchronizedOutputHold? {
    get { synchronizedOutputHold }
    set { synchronizedOutputHold = newValue }
  }

  private static let outputSettleQuietSeconds: TimeInterval = 0.012
  private static let outputSettleMaxHoldSeconds: TimeInterval = 0.025
  private var outputSettleHold: OutputSettleHold?
  private var outputSettleWakeScheduled = false
  var outputSettleHoldForTests: OutputSettleHold? {
    get { outputSettleHold }
    set { outputSettleHold = newValue }
  }

  private static let cursorBlinkInterval: TimeInterval = 0.5
  private var cursorBlinkVisible = true
  private var lastCursorBlinkToggleAt = Date()
  private var lastRenderedCursorBlinking = false

  /// Coalesces wake-ups from per-session reader threads. Set to true
  /// when a background drain has fired but no main-thread advanceFrame
  /// is yet in flight; cleared when the main-thread block runs. Lives
  /// behind an unfair lock so the comparison/swap is atomic across
  /// the reader threads and the main thread.
  private let pendingDisplayKick = OSAllocatedUnfairLock(initialState: false)
  private let latestOutputDirtyAt = OSAllocatedUnfairLock<Date?>(initialState: nil)

  // Input-to-photon latency tracking. Stamped on keyDown; closed out by the
  // renderer's onFrameCompleted callback. Bounded ring buffer.
  private var pendingInputAt: ContinuousClock.Instant?
  private var inputLatencyMs: [Double] = []
  private static let inputLatencyCap = 240
  private var lastLatencyLogAt: Date = Date.distantPast

  /// Smaller font for sidebar chrome — different visual weight from the
  /// terminal content (matches what every modern editor + terminal does)
  /// and fits ~25 % more chars per line so worktree paths stop truncating.
  private let sidebarFontAtlas: FontAtlas
  private let sidebarCellWidth: Int
  private let sidebarCellHeight: Int

  init(
    model: AppModel,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas,
    cellWidth: Int,
    cellHeight: Int,
    urlOpener: any ExternalURLOpening = NSWorkspace.shared
  ) {
    self.model = model
    self.urlOpener = urlOpener
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.sidebarCellWidth = Int(sidebarFontAtlas.cellSize.width)
    self.sidebarCellHeight = Int(sidebarFontAtlas.cellSize.height)

    let preference = ProcessInfo.processInfo.environment["LABAN_RENDERER"]?.lowercased()
    let wantSoftware = preference == "software" || preference == "cpu"
    if !wantSoftware,
      let metal = MetalRenderer(fontAtlas: fontAtlas, sidebarFontAtlas: sidebarFontAtlas)
    {
      self.backend = metal
      self.backendSelfPresents = true
    } else {
      self.backend = SoftwareBackend(
        fontAtlas: fontAtlas, sidebarFontAtlas: sidebarFontAtlas)
      self.backendSelfPresents = false
    }
    super.init(frame: .zero)

    if backendSelfPresents, let layer = backend.presentationLayer {
      self.layer = layer
      wantsLayer = true
      // Metal layers must opt in to backing scale changes via the view.
      layerContentsRedrawPolicy = .duringViewResize
    }

    // Install the per-frame completion hook so we can close out
    // input-to-photon latency samples on the GPU completion handler. The
    // callback fires on a Metal-internal queue; bounce to main before
    // touching shared state.
    if let metal = backend as? MetalRenderer {
      metal.onFrameCompleted = { [weak self] in
        DispatchQueue.main.async { self?.recordInputLatencyIfPending() }
      }
    }

    // Force a full redraw on every theme swap so chrome (sidebar bg, cursor,
    // selection) re-reads `Theme.current`. AppModel re-injects the OSC
    // palette into running sessions in its own observer; this one is just
    // about getting the next frame onto screen with the new chrome colors.
    themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.renderInvalidated = true
    }

    // The per-session reader thread fires this callback whenever it drained
    // bytes. We coalesce them into a single main-thread advanceFrame so a chatty
    // child does not pile up advanceFrame tasks behind a long render. The
    // display link still ticks on its own clock -- this hop only matters when
    // VRR has throttled the link to a low rate and we need to bypass that
    // throttle.
    model.onSessionDirty = { [weak self] _ in
      self?.kickDisplayFromBackground()
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
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      if let self, self.captureRecorder != nil {
        self.toggleCapture(nil)
      }
      NSApp.terminate(nil)
    }
  }

  private func scheduleResizeAutomationIfRequested() {
    guard !resizeAutomationScheduled,
      ProcessInfo.processInfo.environment["LABAN_RESIZE_AUTOMATION"] == "1",
      window != nil
    else { return }
    resizeAutomationScheduled = true
    let delay = Self.envDouble("LABAN_RESIZE_START_DELAY_MS", fallback: 500) / 1000
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?.runResizeAutomation()
    }
  }

  private static func envDouble(_ name: String, fallback: Double) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[name],
      let value = Double(raw)
    else { return fallback }
    return value
  }

  private static func resizeAutomationSteps() -> [CGSize] {
    let raw =
      ProcessInfo.processInfo.environment["LABAN_RESIZE_STEPS"]
      ?? "1200x788,960x640,1328x860,1040x700,1260x820,900x620"
    let parsed = raw.split(separator: ",").compactMap { part -> CGSize? in
      let pieces = part.lowercased().split(separator: "x")
      guard pieces.count == 2,
        let width = Double(pieces[0]),
        let height = Double(pieces[1]),
        width > 0,
        height > 0
      else { return nil }
      return CGSize(width: width, height: height)
    }
    return parsed.isEmpty ? [CGSize(width: 1000, height: 680)] : parsed
  }

  private func runResizeAutomation() {
    guard let window else { return }
    let steps = Self.resizeAutomationSteps()
    let settleDelay = Self.envDouble("LABAN_RESIZE_CAPTURE_DELAY_MS", fallback: 35) / 1000
    resizeProbe?.record(
      label: "initial", window: window, view: self, backend: backend,
      renderedFrame: renderedFrameCount)

    func applyStep(_ index: Int) {
      guard index < steps.count else {
        resizeProbe?.record(
          label: "final", window: window, view: self, backend: backend,
          renderedFrame: renderedFrameCount)
        if ProcessInfo.processInfo.environment["LABAN_RESIZE_AUTO_QUIT"] == "1" {
          NSApp.terminate(nil)
        }
        return
      }
      let size = steps[index]
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeWindowFocusObservers()
    guard window != nil else {
      syncActiveSessionFocus(windowFocused: false)
      stopDisplayLink()
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
    renderInvalidated = true
    window?.makeFirstResponder(self)
    syncActiveSessionFocus(windowFocused: window?.isKeyWindow == true)
    scheduleResizeAutomationIfRequested()
  }

  private func installWindowFocusObservers(for window: NSWindow) {
    let center = NotificationCenter.default
    windowFocusObservers.append(
      center.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.syncActiveSessionFocus(windowFocused: true)
      })
    windowFocusObservers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        self?.syncActiveSessionFocus(windowFocused: false)
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
    reportFocus(to: session, focused: windowFocused)
  }

  private func reportFocus(to session: Session, focused: Bool) {
    guard session.focusReportingEnabled else {
      lastReportedFocusBySession.removeValue(forKey: session.id)
      return
    }
    guard lastReportedFocusBySession[session.id] != focused else { return }
    if session.sendFocus(focused: focused) == 0 {
      lastReportedFocusBySession[session.id] = focused
    }
  }

  private func startDisplayLink() {
    if #available(macOS 14.0, *) {
      // CADisplayLink + preferredFrameRateRange unlocks VRR throttling on
      // ProMotion: when nothing's changing the OS will fire us at the
      // minimum rate (~24 Hz here), and ramp up to the maximum (panel max,
      // typically 120 Hz) when the terminal becomes busy. Idle terminals
      // use less battery; scrolling stays smooth.
      let link = displayLink(target: self, selector: #selector(displayLinkTick))
      link.preferredFrameRateRange = CAFrameRateRange(
        minimum: 24, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      caDisplayLink = link
      return
    }
    var link: CVDisplayLink?
    let createResult = CVDisplayLinkCreateWithActiveCGDisplays(&link)
    guard createResult == kCVReturnSuccess, let link else { return }

    let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
    let setCallbackResult = CVDisplayLinkSetOutputCallback(
      link,
      { (_, _, _, _, _, userInfo) -> CVReturn in
        guard let userInfo else { return kCVReturnSuccess }
        let view = Unmanaged<TerminalBitmapView>.fromOpaque(userInfo).takeUnretainedValue()
        // Vsync callback runs on a dedicated high-priority thread; bounce to
        // main where AppKit, the model, and the renderer must be touched.
        DispatchQueue.main.async { view.advanceFrame() }
        return kCVReturnSuccess
      },
      opaqueSelf
    )
    guard setCallbackResult == kCVReturnSuccess else { return }

    cvDisplayLink = link
    CVDisplayLinkStart(link)
  }

  /// CADisplayLink target/selector. Already on main, so no dispatch hop.
  @objc private func displayLinkTick(_ link: AnyObject) {
    advanceFrame()
  }

  /// Called from a per-session reader thread (off main) when the
  /// reader has drained bytes through the VT parser. Coalesces wake-
  /// ups via `pendingDisplayKick`: only the first dirty drain since
  /// the last main-thread tick posts to main, the rest are folded
  /// into that pending tick. Bypasses the CADisplayLink VRR throttle
  /// so a top(1) refresh that lands during an "idle" window is not
  /// stuck waiting up to 41 ms for the link to ramp back up.
  fileprivate func kickDisplayFromBackground() {
    latestOutputDirtyAt.withLock { $0 = Date() }
    let alreadyPending = pendingDisplayKick.withLock { value -> Bool in
      let was = value
      value = true
      return was
    }
    if alreadyPending { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingDisplayKick.withLock { $0 = false }
      self.advanceFrame()
    }
  }

  private func scheduleOutputSettleWake(after delay: TimeInterval) {
    guard !outputSettleWakeScheduled else { return }
    outputSettleWakeScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.outputSettleWakeScheduled = false
      self.advanceFrame()
    }
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
  }

  deinit {
    stopDisplayLink()
    removeWindowFocusObservers()
    frameProbe?.close()
    resizeProbe?.close()
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if recreateSurface() {
      renderInvalidated = true
    }
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
    if let metal = backend as? MetalRenderer {
      metal.resize(pixelWidth: pixW, pixelHeight: pixH, scale: scale)
    } else if let software = backend as? SoftwareBackend {
      software.resize(pixelWidth: pixW, pixelHeight: pixH, scale: scale)
    }
    return true
  }

  private func invalidateFrame() {
    renderInvalidated = true
  }

  /// Translate libghostty's per-row dirty bits into the CG-point Y bands the
  /// renderer's damage hint expects. Returns `.full` whenever the snapshot
  /// can't supply per-row info or when the caller needs a full redraw for
  /// reasons unrelated to terminal content (tab change, invalidation,
  /// resize). Returns `.partial([])` when nothing changed (renderer skips
  /// the persistent-target update entirely and just re-presents).
  private func computeDamage(
    snapshot snap: UnsafePointer<LabanSnapshot>,
    forceFull: Bool,
    cellHeight: CGFloat,
    originY: CGFloat
  ) -> RenderDamage {
    if forceFull { return .full }
    let s = snap.pointee
    let rows = Int(s.rows)
    guard
      rows > 0,
      s.dirty_row_count == rows,
      let dirty = s.dirty_rows
    else {
      return .full
    }
    var ranges: [DirtyYRange] = []
    var i = 0
    while i < rows {
      if dirty[i] != 0 {
        var j = i
        while j < rows, dirty[j] != 0 { j += 1 }
        // Rows count top-down; FrameProducer maps row r → y = originY +
        // (rows - 1 - r) * cellHeight. A contiguous dirty span [i, j) maps
        // to y-bottom = originY + (rows - 1 - (j-1)) * cellHeight = originY
        // + (rows - j) * cellHeight, height = (j - i) * cellHeight.
        let yBottom = originY + CGFloat(rows - j) * cellHeight
        let height = CGFloat(j - i) * cellHeight
        ranges.append(DirtyYRange(y: yBottom, height: height))
        i = j
      } else {
        i += 1
      }
    }
    return .partial(yRanges: ranges)
  }

  // MARK: - Frame loop

  static func synchronizedOutputGateDecision(
    terminalDirty: Bool,
    synchronizedOutputActive: Bool,
    sessionId: Session.ID,
    now: Date,
    hold: SynchronizedOutputHold?,
    timeout: TimeInterval = synchronizedOutputMaxHoldSeconds
  ) -> SynchronizedOutputGateDecision {
    guard terminalDirty && synchronizedOutputActive else {
      return SynchronizedOutputGateDecision(shouldDefer: false, shouldResetMode: false, hold: nil)
    }

    let currentHold: SynchronizedOutputHold
    if let hold, hold.sessionId == sessionId {
      currentHold = hold
    } else {
      currentHold = SynchronizedOutputHold(sessionId: sessionId, startedAt: now)
    }

    if now.timeIntervalSince(currentHold.startedAt) >= timeout {
      return SynchronizedOutputGateDecision(shouldDefer: false, shouldResetMode: true, hold: nil)
    }

    return SynchronizedOutputGateDecision(
      shouldDefer: true, shouldResetMode: false, hold: currentHold)
  }

  static func outputSettleGateDecision(
    terminalDirty: Bool,
    sessionId: Session.ID,
    lastDirtyAt: Date?,
    now: Date,
    hold: OutputSettleHold?,
    quiet: TimeInterval = outputSettleQuietSeconds,
    maxHold: TimeInterval = outputSettleMaxHoldSeconds
  ) -> OutputSettleGateDecision {
    guard terminalDirty, let lastDirtyAt else {
      return OutputSettleGateDecision(shouldDefer: false, hold: nil, wakeAfter: nil)
    }

    let currentHold: OutputSettleHold
    if let hold, hold.sessionId == sessionId {
      currentHold = hold
    } else {
      currentHold = OutputSettleHold(sessionId: sessionId, startedAt: now)
    }

    let quietElapsed = now.timeIntervalSince(lastDirtyAt)
    let holdElapsed = now.timeIntervalSince(currentHold.startedAt)
    guard quietElapsed < quiet, holdElapsed < maxHold else {
      return OutputSettleGateDecision(shouldDefer: false, hold: nil, wakeAfter: nil)
    }

    let remainingQuiet = quiet - quietElapsed
    let remainingHold = maxHold - holdElapsed
    let wakeAfter = max(0.001, min(remainingQuiet, remainingHold))
    return OutputSettleGateDecision(
      shouldDefer: true, hold: currentHold, wakeAfter: wakeAfter)
  }

  private func advanceCursorBlinkState(now: Date = Date()) -> Bool {
    guard lastRenderedCursorBlinking else {
      let changed = !cursorBlinkVisible
      cursorBlinkVisible = true
      lastCursorBlinkToggleAt = now
      return changed
    }
    guard now.timeIntervalSince(lastCursorBlinkToggleAt) >= Self.cursorBlinkInterval else {
      return false
    }
    cursorBlinkVisible.toggle()
    lastCursorBlinkToggleAt = now
    return true
  }

  @objc func advanceFrame() {
    // Heartbeat the stall watchdog at the top of every tick. If
    // advanceFrame stops returning (or takes very long), the background
    // watchdog will spot the gap and snapshot our threads via sample(1).
    MainThreadWatchdog.shared.heartbeat()

    let captureFrame = renderedFrameCount + 1
    let activeTabId = model.activeTab?.id
    var activeTerminalDirty = false

    for tab in model.tabs {
      if let session = model.session(forTab: tab.id) {
        session.setCaptureFrame(captureFrame)
        // PTY draining now happens off the main thread on the per-session
        // reader thread that AppModel spawns; the main thread just observes the
        // snapshot via renderDirty() / snapshot() below. The reader wakes us
        // here via onSessionDirty -> kickDisplay() so we don't have to wait for
        // the next vsync when bytes arrive between ticks.
        if model.syncProcessMetadata(forTab: tab.id, from: session) {
          renderInvalidated = true
        }
        if model.syncTitle(forTab: tab.id, from: session) {
          renderInvalidated = true
        }
        if model.syncExitState(forTab: tab.id, from: session) {
          renderInvalidated = true
        }
        let dirty = session.renderDirty()
        if dirty {
          if model.noteOutput(forTab: tab.id) {
            renderInvalidated = true
          }
          if tab.id == activeTabId {
            activeTerminalDirty = true
          } else {
            session.markRendered()
          }
        }
      }
    }

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }

    let suffix = captureRecorder == nil ? "" : " — capturing"
    window?.title = model.windowTitle + suffix

    let tabChanged = lastRenderedActiveTabId != activeTab.id
    if tabChanged,
      let outgoing = lastRenderedActiveTabId,
      let outgoingSession = model.session(forTab: outgoing)
    {
      reportFocus(to: outgoingSession, focused: false)
    }
    syncActiveSessionFocus(windowFocused: window?.isKeyWindow == true)

    let cursorBlinkFrame = advanceCursorBlinkState()

    // Tab change interrupts any in-flight scroll animation: snap the
    // displayed position to whatever the new session is showing so the PD
    // controller doesn't keep ticking against the wrong viewport.
    if tabChanged {
      resetSmoothScrollState(to: authoritativeAppliedRows(for: session) ?? 0)
      // Save the outgoing tab's selection and restore the incoming tab's,
      // so the rectangle stays in the tab where it was made instead of
      // bleeding through to whatever's next.
      if let outgoing = lastRenderedActiveTabId {
        if let anchor = selectionAnchor {
          selectionsByTab[outgoing] = (anchor, selectionFocus)
        } else {
          selectionsByTab.removeValue(forKey: outgoing)
        }
      }
      if let restored = selectionsByTab[activeTab.id] {
        selectionAnchor = restored.anchor
        selectionFocus = restored.focus
      } else {
        selectionAnchor = nil
        selectionFocus = nil
      }
      stopDragAutoscroll()
      lastDragPoint = nil
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
        dt = max(1.0 / 240.0, min(1.0 / 30.0, Double(dur.components.attoseconds) / 1e18))
      } else {
        dt = 1.0 / 120.0
      }
      lastScrollTickAt = now

      let omega = Self.scrollOmega
      let accel = omega * omega * scrollError - 2 * omega * scrollVelocityRowsPerSec
      scrollVelocityRowsPerSec += accel * dt
      displayedScrollRows += scrollVelocityRowsPerSec * dt

      // Snap once we're close enough that further integration is noise.
      if abs(targetScrollRows - displayedScrollRows) < 0.01,
        abs(scrollVelocityRowsPerSec) < 0.1
      {
        displayedScrollRows = targetScrollRows
        scrollVelocityRowsPerSec = 0
      }

      let desiredApplied = Int(displayedScrollRows.rounded(.toNearestOrAwayFromZero))
      let delta = desiredApplied - appliedScrollRows
      if delta != 0 {
        session.scrollViewport(deltaRows: delta)
        syncSmoothScrollState(session: session, desiredAppliedRows: desiredApplied)
      }

      renderInvalidated = true
      activeTerminalDirty = true
      scrollAnimating = true
    } else {
      lastScrollTickAt = nil
    }
    self.scrollAnimating = scrollAnimating

    let terminalDirty = activeTerminalDirty || session.renderDirty()

    let syncGate = Self.synchronizedOutputGateDecision(
      terminalDirty: terminalDirty,
      synchronizedOutputActive: session.synchronizedOutputActive,
      sessionId: session.id,
      now: Date(),
      hold: synchronizedOutputHold)
    synchronizedOutputHold = syncGate.hold
    if syncGate.shouldResetMode {
      _ = session.resetSynchronizedOutput()
    }
    if syncGate.shouldDefer {
      // Hold the previous completed frame during DEC synchronized output. Laban
      // uses libghostty-vt without Ghostty's termio timer, so this mirrors
      // Ghostty's one-second watchdog before rendering anyway.
      return
    }

    // PTY output often arrives as related fragments that together form one
    // visual update. Rendering between fragments can expose transient parser
    // states, so wait for a short quiet window while bounding the hold for
    // continuous output.
    if !tabChanged && !scrollAnimating && !renderingResizeFrame {
      let settleGate = Self.outputSettleGateDecision(
        terminalDirty: terminalDirty,
        sessionId: session.id,
        lastDirtyAt: latestOutputDirtyAt.withLock { $0 },
        now: Date(),
        hold: outputSettleHold)
      outputSettleHold = settleGate.hold
      if settleGate.shouldDefer {
        scheduleOutputSettleWake(after: settleGate.wakeAfter ?? Self.outputSettleQuietSeconds)
        return
      }
    } else {
      outputSettleHold = nil
    }

    // Return early when nothing changed
    guard terminalDirty || renderInvalidated || tabChanged || cursorBlinkFrame else { return }

    guard let snap = session.snapshot() else { return }
    defer { laban_snapshot_destroy(snap) }

    captureRecorder?.record(CaptureTimelineEvent(kind: .frameBegin, frame: captureFrame))
    captureRecorder?.recordTerminalSnapshot(
      frame: captureFrame,
      tabId: activeTab.id,
      sessionId: session.id,
      snapshot: UnsafePointer(snap)
    )

    lastRows = Int(snap.pointee.rows)
    let snapshotCursorBlinking = snap.pointee.cursor_blinking != 0
    lastRenderedCursorBlinking = snapshotCursorBlinking
    if !snapshotCursorBlinking {
      cursorBlinkVisible = true
      lastCursorBlinkToggleAt = Date()
    }
    let h = bounds.height

    var cmds: [FrameCommand] = []

    let sidebarProducer = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(sidebarCellWidth),
      cellHeight: CGFloat(sidebarCellHeight)
    )
    cmds += sidebarProducer.commands(
      tabs: model.tabs, activeTabId: activeTab.id, height: h,
      topInset: Self.titlebarReservedHeight,
      hoveredTabId: hoveredSidebarTabId)

    // Fill the entire terminal area (including the inset padding) with the
    // session's default background so the gap between the sidebar and the
    // first cell doesn't expose the underlying cleared surface.
    let insets = Self.contentInsets
    let termAreaWidth = max(0, bounds.width - sidebarWidth)
    cmds.append(
      .rect(
        CGRect(x: sidebarWidth, y: 0, width: termAreaWidth, height: h),
        color: snap.pointee.default_background_rgba,
        source: .terminal
      ))

    // Sub-cell pixel offset for smooth scroll. Fractional remainder of the
    // PD-controlled displayed position is rendered as a vertical pixel
    // shift on the terminal cells; sign matches the existing scrollViewport
    // direction so positive = same direction as a positive scrollViewport
    // delta. Zero when no scroll is in flight.
    let subCellRows = displayedScrollRows - Double(appliedScrollRows)
    let scrollContentYOffset = -CGFloat(subCellRows) * CGFloat(cellHeight)
    let termProducer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + insets.left,
      originY: insets.bottom,
      contentYOffset: scrollContentYOffset
    )
    let selection = currentTerminalSelection(sessionId: session.id)
    cmds += termProducer.commands(
      from: UnsafePointer(snap),
      selection: selection,
      cursorBlinkVisible: cursorBlinkVisible)

    frameProbe?.record(
      frame: captureFrame,
      snapshot: snap.pointee,
      commands: cmds,
      surfaceWidth: backend.surfaceWidth,
      surfaceHeight: backend.surfaceHeight,
      surfaceScale: Double(backend.surfaceScale))

    captureRecorder?.recordFrameCommands(
      frame: captureFrame,
      commands: cmds,
      surfaceWidth: backend.surfaceWidth,
      surfaceHeight: backend.surfaceHeight,
      scale: Double(backend.surfaceScale)
    )
    // Compute damage hint from libghostty's per-row dirty bits. Tab changes
    // and renderInvalidated force .full because we may be drawing different
    // content into the persistent target. Otherwise translate dirty rows
    // into CG-point Y bands matching the FrameProducer's row→y mapping
    // (originY + (rows-1-row) * cellHeight, height = cellHeight).
    //
    // Smooth-scroll forces .full while animating: the persistent target
    // holds last frame's pixels at the previous fractional position, so
    // partial damage would leave stale pixels at the new sub-cell offset.
    let damage = computeDamage(
      snapshot: snap,
      forceFull: renderInvalidated || tabChanged || scrollAnimating,
      cellHeight: CGFloat(cellHeight),
      originY: insets.bottom)
    backend.render(cmds, damage: damage)
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
        backend: backend is MetalRenderer ? "metal" : "software")
    }
    if !backendSelfPresents {
      needsDisplay = true
    }

    session.markRendered()
    renderInvalidated = false
    lastRenderedActiveTabId = activeTab.id
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
  }

  override func mouseExited(with event: NSEvent) {
    setHoveredSidebarTab(nil)
    setHoverCursor(.arrow)
  }

  override func flagsChanged(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    updateHoverCursor(at: pt, modifierFlags: event.modifierFlags)
  }

  private func updateHoverCursor(at pt: NSPoint, modifierFlags: NSEvent.ModifierFlags = []) {
    let uri = pt.x >= sidebarWidth ? externalHyperlinkURI(at: pt) : nil
    setHoverCursor(Self.hoverCursorStyle(externalHyperlinkURI: uri, modifierFlags: modifierFlags))
  }

  static func shouldActivateExternalHyperlink(
    clickCount: Int,
    modifierFlags: NSEvent.ModifierFlags
  ) -> Bool {
    clickCount == 1 && modifierFlags.contains(.command)
  }

  static func hoverCursorStyle(
    externalHyperlinkURI uri: String?,
    modifierFlags: NSEvent.ModifierFlags = []
  ) -> TerminalHoverCursorStyle {
    uri != nil && modifierFlags.contains(.command) ? .pointingHand : .arrow
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
      topInset: Self.titlebarReservedHeight)
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
    renderInvalidated = true
  }

  private func pruneClosedTabState(_ tabId: Tab.ID) {
    selectionsByTab.removeValue(forKey: tabId)
    if hoveredSidebarTabId == tabId {
      hoveredSidebarTabId = nil
    }
    if lastRenderedActiveTabId == tabId {
      selectionAnchor = nil
      selectionFocus = nil
      selectionOriginCell = nil
      stopDragAutoscroll()
      lastDragPoint = nil
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    let w = Int(newSize.width)
    let h = Int(newSize.height)
    guard w > 0, h > 0 else { return }
    if recreateSurface() {
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
    if cols != lastAppliedCols, lastAppliedCols != 0 {
      // Reflow invalidates grid-anchored selection coordinates.
      selectionAnchor = nil
      selectionFocus = nil
    }
    lastAppliedCols = cols
    model.resize(
      viewportWidth: termW, viewportHeight: termH,
      cellWidth: cellWidth, cellHeight: cellHeight)

    // Render synchronously inside the resize event during live drag so the
    // new drawable commits with the new grid dimensions in the same event
    // loop turn. Otherwise AppKit composites the previous drawable over the
    // resized layer until the next displayLink tick (~16 ms) and content
    // anchored to the top of the grid (e.g. cursor at row 0) appears to
    // jump as the gap closes.
    if inLiveResize {
      advanceFrame()
    }
  }

  // MARK: - Responder

  override var acceptsFirstResponder: Bool { true }

  override func keyDown(with event: NSEvent) {
    // Stamp the keystroke so the next render's GPU completion handler can
    // close out an input-to-photon latency sample. Only the most recent
    // keystroke is tracked; if you mash keys we attribute the eventual
    // visible frame to the latest one (closer to user-perceived latency).
    pendingInputAt = ContinuousClock.now
    let descriptor = TerminalKeyDescriptor(keyDown: event)
    switch descriptor.route(hasMarkedText: hasMarkedText()) {
    case .appCommand(let cmd):
      executeAppCommand(cmd)
    case .swallowCommand:
      recordInput(kind: "key", route: "ignored", key: descriptor.key.map(String.init(describing:)))
      break
    case .encodedKey(let keyEvent):
      sendKeyEvent(keyEvent)
    case .nativeText:
      currentKeyDescriptor = descriptor
      defer { currentKeyDescriptor = nil }
      interpretKeyEvents([event])
    case .ignored:
      recordInput(kind: "key", route: "ignored", key: descriptor.key.map(String.init(describing:)))
      break
    }
  }

  override func keyUp(with event: NSEvent) {
    let descriptor = TerminalKeyDescriptor(keyUp: event)
    if case .encodedKey(let keyEvent) = descriptor.route() {
      sendKeyEvent(keyEvent)
    }
  }

  // MARK: - NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
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
  }

  func unmarkText() { markedText = NSAttributedString(string: "") }
  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
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

    let rect = Self.cursorRectForTextInput(
      rows: Int(snap.pointee.rows),
      cursorRow: Int(snap.pointee.cursor_row),
      cursorCol: Int(snap.pointee.cursor_col),
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight),
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
    guard let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId)
    else { return }
    let sent = session.sendKeyCapturingBytes(event)
    let bytes = sent.result == 0 ? sent.bytes : []
    recordInput(
      kind: "key",
      route: "terminal",
      key: String(describing: event.key),
      text: event.text,
      modifiers: modifierNames(event.modifiers),
      consumedModifiers: modifierNames(event.consumedModifiers),
      encodedHex: Self.encodedHex(bytes),
      encodedLength: Self.encodedLength(bytes)
    )
    renderInvalidated = true
  }

  private func sendBytes(_ bytes: [UInt8]) {
    guard let tabId = model.activeTab?.id else { return }
    model.session(forTab: tabId)?.write(bytes)
    recordInput(
      kind: "text",
      route: "terminal",
      encodedHex: Self.encodedHex(bytes),
      encodedLength: Self.encodedLength(bytes)
    )
  }

  private static func encodedHex(_ bytes: [UInt8]) -> String? {
    guard !bytes.isEmpty else { return nil }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func encodedLength(_ bytes: [UInt8]) -> Int? {
    bytes.isEmpty ? nil : bytes.count
  }

  private func executeAppCommand(_ command: AppCommand) {
    recordInput(kind: "key", route: "appCommand", command: command.captureName)
    switch command {
    case .newTab:
      _ = try? model.createTab()
      renderInvalidated = true
    case .closeTab:
      closeTab(nil)
    case .selectTab(let index):
      guard index < model.tabs.count else { return }
      model.selectTab(model.tabs[index].id)
      renderInvalidated = true
    case .copy:
      copy(nil)
    case .paste:
      paste(nil)
    }
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

  private func modifierNames(_ modifiers: KeyModifiers) -> [String]? {
    var names: [String] = []
    if modifiers.contains(.shift) { names.append("shift") }
    if modifiers.contains(.control) { names.append("control") }
    if modifiers.contains(.alt) { names.append("option") }
    if modifiers.contains(.command) { names.append("command") }
    if modifiers.contains(.capsLock) { names.append("capsLock") }
    return names.isEmpty ? nil : names
  }

  // MARK: - Clipboard

  @objc func copy(_ sender: Any?) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id),
      let selection = currentTerminalSelection(sessionId: session.id),
      let snap = session.snapshot()
    else { return }
    defer { laban_snapshot_destroy(snap) }

    let text = selection.selectedText(from: snap.pointee)
    guard !text.isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    EventLog.shared.log("copy", ["bytes": text.utf8.count])
    recordInput(kind: "copy", route: "appCommand", text: text, command: "copy")
  }

  @objc func paste(_ sender: Any?) {
    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else { return }

    let pasteboard = NSPasteboard.general
    if Self.pasteboardContainsImage(pasteboard),
      Self.shouldForwardImagePasteToTerminal(for: activeTab)
    {
      forwardClipboardImagePasteToTerminal(session: session)
      return
    }

    let raw: String
    let rawBytes: Int
    switch Self.readPasteboardString(pasteboard) {
    case .empty:
      return
    case .tooLarge(let bytes):
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Paste too large"
      alert.informativeText =
        "Refusing to paste \(bytes) bytes (limit is \(Self.pasteHardLimitBytes))."
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
    let sanitized = TerminalPaste.sanitize(raw)
    guard !sanitized.isEmpty else { return }
    let bytes = Array(sanitized.utf8)

    // Soft cap with a confirmation. Anything over a few KB is unusual
    // for terminal input; ChatGPT-style "I copied a giant blob"
    // accidents are common.
    if bytes.count > Self.pasteWarnLimitBytes {
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
    if !session.bracketedPasteEnabled(),
      !Session.pasteIsSafe(bytes)
    {
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

    let sent = session.writePasteCapturingBytes(sanitized)
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
      encodedHex: Self.encodedHex(sent.bytes),
      encodedLength: Self.encodedLength(sent.bytes)
    )
  }

  private func forwardClipboardImagePasteToTerminal(session: Session) {
    let event = KeyEvent(action: .press, key: .v, modifiers: .control)
    let sent = session.sendKeyCapturingBytes(event)
    EventLog.shared.log(
      "paste.image.forwarded",
      [
        "encodedBytes": sent.bytes.count,
        "result": Int(sent.result),
      ])
    recordInput(
      kind: "key",
      route: "terminal",
      key: "v",
      modifiers: ["control"],
      command: "pasteImage",
      encodedHex: Self.encodedHex(sent.bytes),
      encodedLength: Self.encodedLength(sent.bytes)
    )
    renderInvalidated = true
  }

  static let pasteHardLimitBytes = TerminalPaste.hardLimitBytes
  static let pasteWarnLimitBytes = TerminalPaste.warnLimitBytes

  static func readPasteboardString(_ pasteboard: NSPasteboard) -> PasteboardStringRead {
    if let data = pasteboard.data(forType: .string), data.count > pasteHardLimitBytes {
      return .tooLarge(data.count)
    }
    guard let raw = pasteboard.string(forType: .string), !raw.isEmpty else {
      return .empty
    }
    let bytes = raw.utf8.count
    if bytes > pasteHardLimitBytes {
      return .tooLarge(bytes)
    }
    return .value(raw, bytes: bytes)
  }

  static func pasteboardContainsImage(_ pasteboard: NSPasteboard) -> Bool {
    pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
  }

  static func shouldForwardImagePasteToTerminal(for tab: Tab) -> Bool {
    let metadata = tab.titleMetadata
    if executableLooksLikeClaude(metadata.process.foregroundProcess) {
      return true
    }
    if executableLooksLikeClaude(metadata.process.foregroundCommand) {
      return true
    }

    let titles = [
      metadata.terminalTitle,
      metadata.displayTitle,
      metadata.userTitle,
      metadata.agent.agentName,
      metadata.agent.sessionName,
    ]
    return titles.contains { value in
      value?.range(of: "Claude Code", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private static func executableLooksLikeClaude(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
    let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    let basename = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
    return basename == "claude" || basename == "claude-code"
  }

  static func sanitizePaste(_ text: String) -> String {
    TerminalPaste.sanitize(text)
  }

  static func externalBrowserURL(from uri: String) -> URL? {
    guard let url = URL(string: uri),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host,
      !host.isEmpty
    else {
      return nil
    }
    return url
  }

  @discardableResult
  static func openExternalHyperlink(
    _ uri: String,
    using opener: any ExternalURLOpening
  ) -> Bool {
    guard let url = externalBrowserURL(from: uri) else { return false }
    return opener.open(url)
  }

  // MARK: - Mouse (selection + sidebar hits + mouse tracking)

  override func scrollWheel(with event: NSEvent) {
    guard
      let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId)
    else {
      return
    }

    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar scrolls are consumed locally.
    guard pt.x >= sidebarWidth else { return }

    guard let vs = session.viewportState() else { return }

    if vs.mouseTracking {
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
      let me = MouseEvent(
        action: .press,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      let sent = session.sendMouseCapturingBytes(me)
      let bytes = sent.result == 0 ? sent.bytes : []
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseWheel",
        encodedHex: Self.encodedHex(bytes),
        encodedLength: Self.encodedLength(bytes)
      )
      renderInvalidated = true
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
      targetScrollRows += Double(decision.rowsDelta)
      // Snap directly when:
      // - macOS reports precise (trackpad) deltas — already smoothed by the OS
      // - the input is small enough to be skim-reading clicks AND nothing is
      //   already animating (so continuous fast spins still get the glide)
      let isPrecise = event.hasPreciseScrollingDeltas
      let isSmallClick =
        abs(decision.rowsDelta) <= Self.scrollSmoothingThreshold && !scrollAnimating
      if isPrecise || isSmallClick {
        let delta = Int(targetScrollRows.rounded(.toNearestOrAwayFromZero)) - appliedScrollRows
        if delta != 0 {
          session.scrollViewport(deltaRows: delta)
          syncSmoothScrollState(
            session: session,
            desiredAppliedRows: appliedScrollRows + delta,
            resetOnClamp: true
          )
        }
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
      Self.externalBrowserURL(from: uri) != nil
    else {
      return nil
    }
    return uri
  }

  private func beginSelection(at pt: NSPoint, clickCount: Int) {
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

  private func clearSelectionAfterHyperlinkActivation() {
    let hadSelection = selectionAnchor != nil || selectionFocus != nil
    selectionAnchor = nil
    selectionFocus = nil
    selectionOriginCell = nil
    if hadSelection {
      recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    }
  }

  private static func pointDistance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
    let dx = lhs.x - rhs.x
    let dy = lhs.y - rhs.y
    return (dx * dx + dy * dy).squareRoot()
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    pendingHyperlinkClick = nil

    // Sidebar hit test.
    if pt.x < sidebarWidth {
      let sp = SidebarProducer(
        sidebarWidth: sidebarWidth,
        cellWidth: CGFloat(sidebarCellWidth),
        cellHeight: CGFloat(sidebarCellHeight)
      )
      switch sp.hitTest(
        at: pt, tabs: model.tabs, height: bounds.height,
        topInset: Self.titlebarReservedHeight)
      {
      case .newTab:
        _ = try? model.createTab()
        renderInvalidated = true
      case .selectTab(let id):
        model.selectTab(id)
        renderInvalidated = true
      case .closeTab(let id):
        do {
          try model.closeTab(id)
          pruneClosedTabState(id)
        } catch AppError.lastTabClosed {
          pruneClosedTabState(id)
          window?.close()
        } catch {}
        renderInvalidated = true
      case .none: break
      }
      return
    }

    window?.makeFirstResponder(self)

    if Self.shouldActivateExternalHyperlink(
      clickCount: event.clickCount,
      modifierFlags: event.modifierFlags
    ), let uri = externalHyperlinkURI(at: pt) {
      pendingHyperlinkClick = PendingHyperlinkClick(uri: uri, downPoint: pt)
      return
    }

    // Check if mouse tracking is active.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      cancelSelectionDragForMouseTracking()
      trackedMouseButton = .left
      let geom = terminalMouseGeometry(at: pt)
      let pressEvent = MouseEvent(
        action: .press,
        button: .left,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      let sent = session.sendMouseCapturingBytes(pressEvent)
      let bytes = sent.result == 0 ? sent.bytes : []
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseDown",
        encodedHex: Self.encodedHex(bytes),
        encodedLength: Self.encodedLength(bytes)
      )
      renderInvalidated = true
      return
    }

    // Fall back to selection. Focus stays nil until a drag actually happens,
    // so a click without drag clears any prior selection instead of leaving a
    // one-cell highlight behind. Double-click selects the word under the
    // cursor; triple-click selects the entire row.
    beginSelection(at: pt, clickCount: event.clickCount)
    renderInvalidated = true
  }

  override func mouseDragged(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
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
      renderInvalidated = true
      return
    }

    // If mouse tracking is active, send motion events.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
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
      let geom = terminalMouseGeometry(at: pt)
      let motionEvent = MouseEvent(
        action: .motion,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      let sent = session.sendMouseCapturingBytes(motionEvent)
      let bytes = sent.result == 0 ? sent.bytes : []
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseDragged",
        encodedHex: Self.encodedHex(bytes),
        encodedLength: Self.encodedLength(bytes)
      )
      renderInvalidated = true
      return
    }
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
    renderInvalidated = true
  }

  override func mouseUp(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if let pending = pendingHyperlinkClick {
      pendingHyperlinkClick = nil
      guard Self.pointDistance(pending.downPoint, pt) <= Self.hyperlinkClickDragTolerance else {
        return
      }
      clearSelectionAfterHyperlinkActivation()
      _ = Self.openExternalHyperlink(pending.uri, using: urlOpener)
      EventLog.shared.log("hyperlink.open", ["url": pending.uri])
      recordInput(
        kind: "command",
        route: "appCommand",
        text: pending.uri,
        command: "openHyperlink")
      renderInvalidated = true
      return
    }

    // If mouse tracking is active, send release event.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
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
      let releaseEvent = MouseEvent(
        action: .release,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      let sent = session.sendMouseCapturingBytes(releaseEvent)
      let bytes = sent.result == 0 ? sent.bytes : []
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseUp",
        encodedHex: Self.encodedHex(bytes),
        encodedLength: Self.encodedLength(bytes)
      )
      if trackedMouseButton == .left { trackedMouseButton = .none }
      renderInvalidated = true
      return
    }
    if trackedMouseButton == .left { trackedMouseButton = .none }
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
    renderInvalidated = true
  }

  override func rightMouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar right-click is consumed locally.
    if pt.x < sidebarWidth {
      return
    }

    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      trackedMouseButton = .right
      let geom = terminalMouseGeometry(at: pt)
      let pressEvent = MouseEvent(
        action: .press,
        button: .right,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      _ = session.sendMouseCapturingBytes(pressEvent)
      renderInvalidated = true
    }
  }

  override func rightMouseDragged(with event: NSEvent) {
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
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
      let motionEvent = MouseEvent(
        action: .motion,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      _ = session.sendMouseCapturingBytes(motionEvent)
      renderInvalidated = true
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
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
      let releaseEvent = MouseEvent(
        action: .release,
        button: button,
        x: geom.x, y: geom.y,
        screenWidth: geom.screenWidth,
        screenHeight: geom.screenHeight,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        modifiers: event.labanModifiers
      )
      _ = session.sendMouseCapturingBytes(releaseEvent)
      if trackedMouseButton == .right { trackedMouseButton = .none }
      renderInvalidated = true
    }
    if trackedMouseButton == .right { trackedMouseButton = .none }
  }

  // Convert a CG-coordinate view point to a terminal grid cell (row 0 = top).
  private func termCell(at pt: NSPoint) -> (row: Int, col: Int)? {
    let insets = Self.contentInsets
    let x = pt.x - sidebarWidth - insets.left
    let yLocal = pt.y - insets.bottom
    guard x >= 0, yLocal >= 0 else { return nil }
    let col = Int(x / CGFloat(cellWidth))
    // CG y=0 at bottom; terminal row 0 is at the top of the cell grid.
    let row = lastRows - 1 - Int(yLocal / CGFloat(cellHeight))
    guard row >= 0, row < lastRows, col >= 0 else { return nil }
    return (row, col)
  }

  /// Like `termCell(at:)` but always returns a valid cell, clamped to the
  /// viewport edges. Used when extending a selection by drag — without
  /// clamping, dragging past the bottom would yield nil and clear the
  /// in-progress selection. Captures libghostty's viewport offset so the
  /// point tracks the actual content as the viewport scrolls.
  private func clampedSelectionPoint(at pt: NSPoint) -> SelectionPoint {
    let insets = Self.contentInsets
    let x = max(0, pt.x - sidebarWidth - insets.left)
    let yLocal = pt.y - insets.bottom
    let cols = max(
      1,
      Int((bounds.width - sidebarWidth - insets.left - insets.right) / CGFloat(cellWidth)))
    let col = min(cols - 1, max(0, Int(x / CGFloat(cellWidth))))
    let unclampedRow = lastRows - 1 - Int(yLocal / CGFloat(cellHeight))
    let row = min(max(0, unclampedRow), max(0, lastRows - 1))
    return SelectionPoint(
      row: row, col: col, viewportOffsetAtCapture: currentViewportOffset())
  }

  /// Word-grain selection at the click cell.
  private func selectWordAt(_ pt: NSPoint) {
    let p = clampedSelectionPoint(at: pt)
    let bounds = wordBoundsAt(row: p.row, col: p.col)
    selectionAnchor = SelectionPoint(
      row: p.row, col: bounds.start, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
    selectionFocus = SelectionPoint(
      row: p.row, col: bounds.end, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
  }

  /// Line-grain selection at the click cell.
  private func selectLineAt(_ pt: NSPoint) {
    let p = clampedSelectionPoint(at: pt)
    let cols = currentCols()
    selectionAnchor = SelectionPoint(
      row: p.row, col: 0, viewportOffsetAtCapture: p.viewportOffsetAtCapture)
    selectionFocus = SelectionPoint(
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
    let snapPtr = snap.pointee
    let cols = Int(snapPtr.cols)
    guard row >= 0, row < Int(snapPtr.rows), col >= 0, col < cols,
      let cells = snapPtr.cells, let storage = snapPtr.utf8_storage
    else { return (col, col) }
    func cellChar(at c: Int) -> Unicode.Scalar? {
      let cell = cells[row * cols + c]
      guard cell.utf8_length > 0 else { return nil }
      let buf = UnsafeBufferPointer<UInt8>(
        start: UnsafeRawPointer(storage)
          .advanced(by: Int(cell.utf8_offset))
          .assumingMemoryBound(to: UInt8.self),
        count: Int(cell.utf8_length))
      let s = String(bytes: buf, encoding: .utf8) ?? ""
      return s.unicodeScalars.first
    }
    func isWord(_ scalar: Unicode.Scalar?) -> Bool {
      guard let scalar else { return false }
      if CharacterSet.alphanumerics.contains(scalar) { return true }
      return "-_./:~@".unicodeScalars.contains(scalar)
    }
    var startCol = col
    var endCol = col
    while startCol > 0, isWord(cellChar(at: startCol - 1)) { startCol -= 1 }
    while endCol < cols - 1, isWord(cellChar(at: endCol + 1)) { endCol += 1 }
    return (startCol, endCol)
  }

  private func currentCols() -> Int {
    let insets = Self.contentInsets
    return max(
      1,
      Int((bounds.width - sidebarWidth - insets.left - insets.right) / CGFloat(cellWidth)))
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

  private func extendWordSelection(to drag: SelectionPoint) {
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
    selectionAnchor = SelectionPoint(
      row: startLin / cols, col: startLin % cols,
      viewportOffsetAtCapture: orig.viewportOffsetAtCapture)
    selectionFocus = SelectionPoint(
      row: endLin / cols, col: endLin % cols,
      viewportOffsetAtCapture: drag.viewportOffsetAtCapture)
  }

  private func extendLineSelection(to drag: SelectionPoint) {
    guard let orig = selectionOriginCell else {
      selectionFocus = drag
      return
    }
    let cols = currentCols()
    let topRow = min(orig.row, drag.row)
    let bottomRow = max(orig.row, drag.row)
    selectionAnchor = SelectionPoint(
      row: topRow, col: 0, viewportOffsetAtCapture: orig.viewportOffsetAtCapture)
    selectionFocus = SelectionPoint(
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

  static func cursorRectForTextInput(
    rows: Int,
    cursorRow: Int,
    cursorCol: Int,
    sidebarWidth: CGFloat,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    insets: NSEdgeInsets
  ) -> NSRect {
    let clampedRows = max(rows, 1)
    let row = min(max(cursorRow, 0), clampedRows - 1)
    let col = max(cursorCol, 0)
    return NSRect(
      x: sidebarWidth + insets.left + CGFloat(col) * cellWidth,
      y: insets.bottom + CGFloat(clampedRows - 1 - row) * cellHeight,
      width: cellWidth,
      height: cellHeight
    )
  }

  private func authoritativeAppliedRows(for session: Session) -> Int? {
    guard let vs = session.viewportState() else { return nil }
    return TerminalScrollInput.appliedRowsFromViewport(
      viewportOffset: vs.viewportOffset,
      totalRows: vs.totalRows,
      viewportRows: vs.viewportRows
    )
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

  /// Build the renderer-facing selection from view-state, translating each
  /// stored row by the actual viewport-offset delta since capture so the
  /// selection rect follows the underlying content as the viewport scrolls.
  private func currentTerminalSelection(sessionId: Session.ID) -> TerminalSelection? {
    guard let anchor = selectionAnchor, let focus = selectionFocus else { return nil }
    let offset = currentViewportOffset()
    let aRow = anchor.visibleRow(currentViewportOffset: offset)
    let fRow = focus.visibleRow(currentViewportOffset: offset)
    return TerminalSelection(
      sessionId: sessionId,
      anchor: TerminalCellCoordinate(row: aRow, col: anchor.col),
      focus: TerminalCellCoordinate(row: fRow, col: focus.col)
    )
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

  private func cancelSelectionDragForMouseTracking() {
    stopDragAutoscroll()
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
      !vs.mouseTracking
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
    session.scrollViewport(deltaRows: dragAutoscrollDirection)
    syncSmoothScrollState(
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
    renderInvalidated = true
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
    _ = try? model.createTab()
    renderInvalidated = true
  }

  @objc func closeTab(_ sender: Any?) {
    guard let tabId = model.activeTab?.id else { return }
    do {
      try model.closeTab(tabId)
      pruneClosedTabState(tabId)
    } catch AppError.lastTabClosed {
      pruneClosedTabState(tabId)
      window?.close()
      return
    } catch {}
    renderInvalidated = true
  }

  @objc func selectTabByIndex(_ sender: Any?) {
    guard let item = sender as? NSMenuItem else { return }
    let idx = item.tag - 1
    guard idx >= 0, idx < model.tabs.count else { return }
    model.selectTab(model.tabs[idx].id)
    renderInvalidated = true
  }

  // MARK: - PTY-byte capture (debug)

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
      // Capture stopped: drop the per-frame readback blit again.
      (backend as? MetalRenderer)?.captureMode = false
      model.captureSink = nil
      renderInvalidated = true
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
      // Capture started: turn on the per-frame drawable→CPU readback so
      // pngData has bytes to serve. Off-state was the default since boot.
      (backend as? MetalRenderer)?.captureMode = true
      model.captureSink = recorder
      model.recordExistingStateForCapture()
      AppLog.capture.info("started \(recorder.directoryURL.path)")
      EventLog.shared.log("capture.start", ["path": recorder.directoryURL.path])
      renderInvalidated = true
    } catch {
      AppLog.capture.error("failed to start: \(error)")
    }
  }

  /// `~/Library/Logs/Laban/captures` by default; overridable via
  /// `LABAN_CAPTURE_DIR` for cases where the user wants captures somewhere
  /// auto-cleaned (e.g., a tmpfs).
  private static func captureDirectory() -> URL {
    if let env = ProcessInfo.processInfo.environment["LABAN_CAPTURE_DIR"], !env.isEmpty {
      return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    let logs = FileManager.default
      .urls(for: .libraryDirectory, in: .userDomainMask).first!
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

extension AppCommand {
  fileprivate var captureName: String {
    switch self {
    case .newTab: return "newTab"
    case .closeTab: return "closeTab"
    case .selectTab: return "selectTab"
    case .copy: return "copy"
    case .paste: return "paste"
    }
  }
}

enum TerminalMouseInput {
  static func surfacePosition(
    viewPoint: NSPoint,
    boundsHeight: CGFloat,
    sidebarWidth: CGFloat
  ) -> (x: Float, y: Float) {
    (
      Float(viewPoint.x - sidebarWidth),
      Float(boundsHeight - viewPoint.y)
    )
  }

  static func surfaceSize(
    boundsWidth: CGFloat,
    boundsHeight: CGFloat,
    sidebarWidth: CGFloat
  ) -> (width: Int, height: Int) {
    (
      max(1, Int(boundsWidth - sidebarWidth)),
      max(1, Int(boundsHeight))
    )
  }

  static func ghosttyModifierMask(from modifierFlags: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if modifierFlags.contains(.shift) { m |= 1 }
    if modifierFlags.contains(.control) { m |= 2 }
    if modifierFlags.contains(.option) { m |= 4 }
    if modifierFlags.contains(.command) { m |= 8 }
    return m
  }

  static func trackedTerminalButton(
    _ trackedButton: MouseButton,
    matching expectedButton: MouseButton
  ) -> MouseButton? {
    trackedButton == expectedButton ? trackedButton : nil
  }
}
