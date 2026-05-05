import AppKit
import CoreGraphics
import CoreVideo
import LabanCore
import LabanDebug
import LabanRenderer
import LabanTerminalCore
import QuartzCore

final class TerminalBitmapView: NSView, NSTextInputClient {

  static let contentInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 8)

  private let model: AppModel
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

  // Selection anchor/focus in terminal grid coordinates (row, col); row 0 = top
  private var selectionAnchor: (row: Int, col: Int)?
  private var selectionFocus: (row: Int, col: Int)?
  private var trackedMouseButton: MouseButton = .none

  // Damage-driven render budget state
  private var renderInvalidated = true
  private var lastRenderedActiveTabId: Tab.ID?
  private var scrollResidualPx: CGFloat = 0

  // IME composition buffer
  private var markedText: NSAttributedString = .init(string: "")

  // Active key descriptor during interpretKeyEvents dispatch
  private var currentKeyDescriptor: TerminalKeyDescriptor?

  // Tracks last surface dimensions to avoid redundant reallocations
  private var lastPixelWidth: Int = 0
  private var lastPixelHeight: Int = 0
  private var lastSurfaceScale: CGFloat = 0
  private var captureRecorder: CaptureRecorder?
  private var renderedFrameCount: Int = 0

  // Input-to-photon latency tracking. Stamped on keyDown; closed out by the
  // renderer's onFrameCompleted callback. Bounded ring buffer.
  private var pendingInputAt: ContinuousClock.Instant?
  private var inputLatencyMs: [Double] = []
  private static let inputLatencyCap = 240
  private var lastLatencyLogAt: Date = Date.distantPast

  init(
    model: AppModel,
    fontAtlas: FontAtlas,
    cellWidth: Int,
    cellHeight: Int
  ) {
    self.model = model
    self.fontAtlas = fontAtlas
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight

    let preference = ProcessInfo.processInfo.environment["LABAN_RENDERER"]?.lowercased()
    let wantSoftware = preference == "software" || preference == "cpu"
    if !wantSoftware, let metal = MetalRenderer(fontAtlas: fontAtlas) {
      self.backend = metal
      self.backendSelfPresents = true
    } else {
      self.backend = SoftwareBackend(fontAtlas: fontAtlas)
      self.backendSelfPresents = false
    }
    super.init(frame: .zero)

    if backendSelfPresents, let layer = backend.presentationLayer {
      wantsLayer = true
      self.layer = layer
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
        metalTimings = String(
          format: "  frame cpu p50/p99=%.2f/%.2f ms  gpu p50/p99=%.2f/%.2f ms",
          t.cpuP50Ms, t.cpuP99Ms, t.gpuP50Ms, t.gpuP99Ms)
      } else {
        metalTimings = ""
      }
      fputs(
        String(
          format: "laban: input→commit n=%d  mean=%.2f ms  p50=%.2f ms  p99=%.2f ms%@\n",
          inputLatencyMs.count, mean, p50, p99, metalTimings),
        stderr)
    }
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else {
      stopDisplayLink()
      return
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

  @objc func advanceFrame() {
    let captureFrame = renderedFrameCount + 1
    let activeTabId = model.activeTab?.id
    var activeTerminalDirty = false

    for tab in model.tabs {
      if let session = model.session(forTab: tab.id) {
        session.setCaptureFrame(captureFrame)
        session.poll()
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

    let terminalDirty = activeTerminalDirty || session.renderDirty()
    let tabChanged = lastRenderedActiveTabId != activeTab.id

    // Return early when nothing changed
    guard terminalDirty || renderInvalidated || tabChanged else { return }

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
    let h = bounds.height

    var cmds: [FrameCommand] = []

    let sidebarProducer = SidebarProducer(
      sidebarWidth: sidebarWidth,
      cellWidth: CGFloat(cellWidth),
      cellHeight: CGFloat(cellHeight)
    )
    cmds += sidebarProducer.commands(tabs: model.tabs, activeTabId: activeTab.id, height: h)

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

    let termProducer = FrameProducer(
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      originX: sidebarWidth + insets.left,
      originY: insets.bottom
    )
    var selection: TerminalSelection?
    if let anchor = selectionAnchor, let focus = selectionFocus {
      selection = TerminalSelection(
        sessionId: session.id,
        anchor: TerminalCellCoordinate(row: anchor.row, col: anchor.col),
        focus: TerminalCellCoordinate(row: focus.row, col: focus.col)
      )
    }
    cmds += termProducer.commands(from: UnsafePointer(snap), selection: selection)

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
    let damage = computeDamage(
      snapshot: snap,
      forceFull: renderInvalidated || tabChanged,
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
      ctx.setFillColor(cgColorFrom(Theme.CurrentTheme.bg0))
      ctx.fill(bounds)
      return
    }
    ctx.saveGState()
    ctx.interpolationQuality = .none
    ctx.draw(cgImg, in: bounds)
    ctx.restoreGState()
  }

  // MARK: - Resize

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
    model.resize(
      viewportWidth: termW, viewportHeight: termH, cellWidth: cellWidth, cellHeight: cellHeight)
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
    switch descriptor.route() {
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
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
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
    let bytes = session.encodeKey(event)
    session.sendKey(event)
    recordInput(
      kind: "key",
      route: "terminal",
      key: String(describing: event.key),
      text: event.text,
      modifiers: modifierNames(event.modifiers),
      consumedModifiers: modifierNames(event.consumedModifiers),
      encodedHex: bytes?.map { String(format: "%02x", $0) }.joined(),
      encodedLength: bytes?.count
    )
    renderInvalidated = true
  }

  private func sendBytes(_ bytes: [UInt8]) {
    guard let tabId = model.activeTab?.id else { return }
    model.session(forTab: tabId)?.write(bytes)
    recordInput(
      kind: "text",
      route: "terminal",
      encodedHex: bytes.map { String(format: "%02x", $0) }.joined(),
      encodedLength: bytes.count
    )
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
      let anchor = selectionAnchor,
      let focus = selectionFocus,
      let snap = session.snapshot()
    else { return }
    defer { laban_snapshot_destroy(snap) }

    let selection = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: anchor.row, col: anchor.col),
      focus: TerminalCellCoordinate(row: focus.row, col: focus.col)
    )
    let text = selection.selectedText(from: snap.pointee)
    guard !text.isEmpty else { return }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    recordInput(kind: "copy", route: "appCommand", text: text, command: "copy")
  }

  @objc func paste(_ sender: Any?) {
    guard let str = NSPasteboard.general.string(forType: .string),
      !str.isEmpty,
      let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId)
    else { return }
    _ = session.writePaste(str)
    recordInput(kind: "paste", route: "terminal", text: str, command: "paste")
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
      // deltaY sign so a single physical notch maps to a single button press.
      guard event.deltaY != 0 else { return }
      let button: MouseButton = event.deltaY > 0 ? .wheelUp : .wheelDown
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
      let bytes = session.encodeMouse(me)
      session.sendMouse(me)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseWheel",
        encodedHex: bytes?.map { String(format: "%02x", $0) }.joined(),
        encodedLength: bytes?.count
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
      session.scrollViewport(deltaRows: decision.rowsDelta)
      recordInput(
        kind: "scroll",
        route: "terminal",
        command: "scrollViewport",
        deltaRows: decision.rowsDelta
      )
      renderInvalidated = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)

    // Sidebar hit test.
    if pt.x < sidebarWidth {
      let sp = SidebarProducer(
        sidebarWidth: sidebarWidth,
        cellWidth: CGFloat(cellWidth),
        cellHeight: CGFloat(cellHeight)
      )
      switch sp.hitTest(at: pt, tabs: model.tabs, height: bounds.height) {
      case .newTab:
        _ = try? model.createTab()
        renderInvalidated = true
      case .selectTab(let id):
        model.selectTab(id)
        renderInvalidated = true
      case .closeTab(let id):
        _ = try? model.closeTab(id)
        renderInvalidated = true
      case .none: break
      }
      return
    }

    window?.makeFirstResponder(self)

    // Check if mouse tracking is active.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
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
      let bytes = session.encodeMouse(pressEvent)
      session.sendMouse(pressEvent)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseDown",
        encodedHex: bytes?.map { String(format: "%02x", $0) }.joined(),
        encodedLength: bytes?.count
      )
      renderInvalidated = true
      return
    }

    // Fall back to selection. Focus stays nil until a drag actually happens,
    // so a click without drag clears any prior selection instead of leaving a
    // one-cell highlight behind.
    let hadSelection = selectionAnchor != nil && selectionFocus != nil
    selectionAnchor = termCell(at: pt)
    selectionFocus = nil
    if hadSelection {
      recordInput(kind: "selection", route: "terminal", command: "clearSelection")
    }
    renderInvalidated = true
  }

  override func mouseDragged(with event: NSEvent) {
    // If mouse tracking is active, send motion events.
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
      let bytes = session.encodeMouse(motionEvent)
      session.sendMouse(motionEvent)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseDragged",
        encodedHex: bytes?.map { String(format: "%02x", $0) }.joined(),
        encodedLength: bytes?.count
      )
      renderInvalidated = true
      return
    }
    selectionFocus = termCell(at: convert(event.locationInWindow, from: nil))
    if let anchor = selectionAnchor, let focus = selectionFocus {
      recordInput(
        kind: "selection",
        route: "terminal",
        command: "updateSelection",
        anchor: anchor,
        focus: focus
      )
    }
    renderInvalidated = true
  }

  override func mouseUp(with event: NSEvent) {
    // If mouse tracking is active, send release event.
    if let tabId = model.activeTab?.id,
      let session = model.session(forTab: tabId),
      let vs = session.viewportState(),
      vs.mouseTracking
    {
      guard
        let button = TerminalMouseInput.trackedTerminalButton(
          trackedMouseButton,
          matching: .left
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
      let bytes = session.encodeMouse(releaseEvent)
      session.sendMouse(releaseEvent)
      recordInput(
        kind: "mouse",
        route: "terminal",
        command: "mouseUp",
        encodedHex: bytes?.map { String(format: "%02x", $0) }.joined(),
        encodedLength: bytes?.count
      )
      if trackedMouseButton == .left { trackedMouseButton = .none }
      renderInvalidated = true
      return
    }
    if trackedMouseButton == .left { trackedMouseButton = .none }
    // Only finalize focus if a drag established one. A bare click leaves
    // selectionFocus nil, which clears the rendered selection.
    if selectionFocus != nil {
      selectionFocus = termCell(at: convert(event.locationInWindow, from: nil))
      if let anchor = selectionAnchor, let focus = selectionFocus {
        recordInput(
          kind: "selection",
          route: "terminal",
          command: "updateSelection",
          anchor: anchor,
          focus: focus
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
      session.sendMouse(pressEvent)
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
      session.sendMouse(motionEvent)
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
      session.sendMouse(releaseEvent)
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
    } catch AppError.lastTabClosed {
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
        fputs("laban: capture stopped \(manifest.path)\n", stderr)
      } catch {
        fputs("laban: capture stop failed \(error)\n", stderr)
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
      fputs("laban: capture started \(recorder.directoryURL.path)\n", stderr)
      renderInvalidated = true
    } catch {
      fputs("laban: capture failed to start \(error)\n", stderr)
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
