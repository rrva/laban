import AppKit
import LabanCore
import LabanRenderer

/// SOTA overlay scroll indicator: invisible at the live bottom, fades in when
/// the user scrolls back into history, holds while scrolled-up or hovered
/// over the right edge, and fades out a short delay after scrolling stops back
/// at the bottom. Matches the macOS Tahoe overlay-scrollbar spirit (hidden
/// chrome, hover-expand) but adds a numeric position pill so the user knows
/// *how far back* they are without reading the thumb.
///
/// The view is a sibling of `TerminalBitmapView` inside the window's
/// containerView — same z-ordering pattern as `UpdateBadgeView`. It is
/// click-transparent (`hitTest` returns nil) so terminal selection and
/// scrolling are unaffected; the right-edge tracking area only delivers
/// `mouseEntered/mouseExited` to drive hover-reveal.
///
/// Decision logic lives in `TerminalScrollIndicator`. This view only
/// translates `Input` → `Output` → CALayer geometry plus a fade timer.
final class TerminalScrollIndicatorView: NSView {

  // Inset from the rounded window corner in macOS Tahoe — without this, the
  // thumb visibly slides under the radius. 8pt clears the corner and matches
  // the visual breathing room around the find chip.
  private static let edgeInset: CGFloat = 8
  private static let topInset: CGFloat = TerminalBitmapView.titlebarReservedHeight + 6
  private static let bottomInset: CGFloat = 12
  private static let thumbWidthIdle: CGFloat = 3
  private static let thumbWidthHover: CGFloat = 7
  private static let minThumbHeight: CGFloat = 32
  private static let hoverZoneWidth: CGFloat = 24
  // Extra grab margin around the thin thumb so drag-to-scrub is forgiving to hit
  // without eating terminal selection across a wide strip.
  private static let thumbGrabSlop: CGFloat = 6
  private static let fadeInDuration: TimeInterval = 0.12
  private static let fadeOutDuration: TimeInterval = 0.24
  private static let idleHoldDuration: TimeInterval = 0.8

  private let thumbLayer = CALayer()
  private let pillContainer = NSView()
  private let pillLabel = NSTextField(labelWithString: "")

  private var lastInput: TerminalScrollIndicator.Input?
  private var lastOutput: TerminalScrollIndicator.Output = .hidden
  // Scrolled-back distance from the previous sample. Only a change here counts
  // as scroll activity that (re)arms the idle-hide countdown; output that grows
  // the buffer while the viewport stays pinned to the bottom must not.
  private var lastLinesBack = 0
  // Cached pill measurement. `fittingSize` runs AppKit auto-layout, so it is
  // only recomputed when the pill text actually changes.
  private var lastPillText: String?
  private var lastPillFittedSize: NSSize = .zero
  // Test hook: counts layoutFromOutput passes so a test can assert the
  // hidden-thumb streaming path performs no Core Animation layout.
  private(set) var layoutPassCountForTesting = 0
  private var isHoverEdge = false
  private var idleHideWorkItem: DispatchWorkItem?
  private var trackingArea: NSTrackingArea?
  private var themeChangeObserver: NSObjectProtocol?

  // Drag-to-scrub state. While dragging the thumb, the view maps the pointer to
  // an absolute history position and reports it through `onScrubToFraction`; the
  // terminal jumps the viewport there. See `spec.md` §scrollback.
  private var isDragging = false
  /// Offset from the pointer to the thumb's top edge at grab time, so the grab
  /// point stays under the cursor for the whole drag.
  private var dragGrabDY: CGFloat?
  /// Maps a history fraction (0 = oldest scrollback, 1 = live bottom) to an
  /// absolute viewport offset on the terminal. Wired by the window controller.
  var onScrubToFraction: ((Double) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false

    thumbLayer.backgroundColor = Self.thumbColor(hover: false)
    thumbLayer.cornerRadius = Self.thumbWidthIdle / 2
    thumbLayer.opacity = 0
    layer?.addSublayer(thumbLayer)

    pillContainer.wantsLayer = true
    pillContainer.layer?.cornerRadius = 8
    pillContainer.layer?.borderWidth = 1
    pillContainer.alphaValue = 0
    pillContainer.translatesAutoresizingMaskIntoConstraints = true
    applyThemeChrome()

    pillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    pillLabel.alignment = .center
    pillLabel.translatesAutoresizingMaskIntoConstraints = false
    pillContainer.addSubview(pillLabel)
    NSLayoutConstraint.activate([
      pillLabel.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 8),
      pillLabel.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -8),
      pillLabel.topAnchor.constraint(equalTo: pillContainer.topAnchor, constant: 3),
      pillLabel.bottomAnchor.constraint(equalTo: pillContainer.bottomAnchor, constant: -3),
    ])
    addSubview(pillContainer)

    themeChangeObserver = NotificationCenter.default.addObserver(
      forName: Theme.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.applyThemeChrome()
      self?.layoutFromOutput()
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let themeChangeObserver {
      NotificationCenter.default.removeObserver(themeChangeObserver)
    }
  }

  // Grabbable only over the visible thumb (drag-to-scrub); everywhere else stays
  // click-transparent so terminal selection and wheel scroll are unaffected. The
  // hover tracking area works independently of hit-testing.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isThumbGrabbable else { return nil }
    let inView = convert(point, from: superview)
    return thumbGrabRect.contains(inView) ? self : nil
  }

  /// There is a visible thumb to grab (scrollback exists and the thumb is shown,
  /// e.g. while scrolled back or hover-revealed at the bottom).
  private var isThumbGrabbable: Bool {
    lastOutput.thumbFraction > 0 && thumbLayer.opacity > 0
  }

  /// The thumb's frame padded by the grab slop, in view coordinates.
  private var thumbGrabRect: NSRect {
    thumbLayer.frame.insetBy(dx: -Self.thumbGrabSlop, dy: -Self.thumbGrabSlop)
  }

  override func mouseDown(with event: NSEvent) {
    guard isThumbGrabbable else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard thumbGrabRect.contains(p) else { return }
    isDragging = true
    dragGrabDY = thumbLayer.frame.maxY - p.y
    cancelIdleHide()
    setThumbOpacity(1, animated: false)
    layoutFromOutput()
  }

  override func mouseDragged(with event: NSEvent) {
    guard isDragging, let grabDY = dragGrabDY else { return }
    let p = convert(event.locationInWindow, from: nil)
    let thumbTopY = p.y + grabDY
    onScrubToFraction?(historyFraction(forThumbTopY: thumbTopY))
  }

  override func mouseUp(with event: NSEvent) {
    guard isDragging else { return }
    isDragging = false
    dragGrabDY = nil
    // Settle: re-validate hover against the live pointer and re-evaluate so the
    // idle-hide re-arms if we landed back at the bottom and the thumb width drops
    // to idle once the pointer leaves the edge.
    if !pointerInHoverZone() { isHoverEdge = false }
    if let lastInput { apply(input: lastInput.withHover(isHoverEdge)) }
  }

  /// Map a desired thumb top-edge Y (view coordinates) to a history fraction via
  /// the pure inverse of the thumb layout.
  private func historyFraction(forThumbTopY thumbTopY: CGFloat) -> Double {
    TerminalScrollIndicator.historyFraction(
      thumbTopY: Double(thumbTopY),
      trackTop: Double(bounds.height - Self.topInset),
      trackBottom: Double(Self.bottomInset),
      thumbHeight: Double(thumbLayer.frame.height))
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let existing = trackingArea { removeTrackingArea(existing) }
    let zone = NSRect(
      x: bounds.maxX - Self.hoverZoneWidth,
      y: 0,
      width: Self.hoverZoneWidth,
      height: bounds.height
    )
    let area = NSTrackingArea(
      rect: zone,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
    // Rebuilding the area drops AppKit's record that the pointer was inside (no
    // synthetic mouseExited is emitted). If the pointer has since left the zone,
    // clear the now-stale hover here so the thumb isn't stuck until a real exit.
    if isHoverEdge, !pointerInHoverZone() {
      isHoverEdge = false
      if let lastInput { apply(input: lastInput.withHover(false)) }
    }
  }

  override func mouseEntered(with event: NSEvent) {
    guard !isHoverEdge else { return }
    isHoverEdge = true
    if let lastInput { apply(input: lastInput.withHover(true)) }
  }

  override func mouseExited(with event: NSEvent) {
    guard isHoverEdge else { return }
    isHoverEdge = false
    if let lastInput { apply(input: lastInput.withHover(false)) }
  }

  /// Whether the pointer is actually within the right-edge hover zone right now,
  /// checked against the live pointer location instead of trusting the last
  /// `mouseEntered`/`mouseExited`. AppKit drops `mouseExited` when a tracking
  /// area is rebuilt with the pointer inside (and in a few other races), which
  /// pins `isHoverEdge` true and sticks the thumb visible at the live bottom —
  /// it then only clears on the next genuine enter/exit or on window unfocus
  /// (`.activeInKeyWindow` emits an exit on resignKey, which is why the bug
  /// "fixes itself" when the window loses focus). Re-validating here lets the
  /// view recover on its own. Only meaningful while the window is key; off-key
  /// hover is already cleared by the resignKey exit.
  /// Test seam: the real check reads the live pointer location, which a unit
  /// test cannot set. Tests inject a deterministic answer; production leaves it
  /// nil and uses the real geometry.
  var pointerInHoverZoneProbe: (() -> Bool)?

  private func pointerInHoverZone() -> Bool {
    if let pointerInHoverZoneProbe { return pointerInHoverZoneProbe() }
    guard let window, window.isKeyWindow else { return false }
    let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard bounds.contains(inView) else { return false }
    return inView.x >= bounds.maxX - Self.hoverZoneWidth
  }

  /// Called every frame from `TerminalBitmapView.advanceFrame`. Cheap noop
  /// when the viewport state hasn't changed.
  func applyViewport(
    viewportOffset: Int, totalRows: Int, viewportRows: Int,
    isAltScreen: Bool, isMouseTracking: Bool
  ) {
    // Recover from a dropped `mouseExited`: if hover is still flagged but the
    // pointer has left the right-edge zone, clear it so a stale hover can't pin
    // the thumb visible at the live bottom (the stuck-indicator bug). Cheap; the
    // pointer query only runs while a sample arrives and only acts when stuck.
    if isHoverEdge, !isDragging, !pointerInHoverZone() {
      isHoverEdge = false
      ScrollDiagnostics.shared.mark(
        kind: "hover-reconcile", note: "cleared stuck isHoverEdge on frame sample")
    }
    let input = TerminalScrollIndicator.Input(
      viewportOffset: viewportOffset,
      totalRows: totalRows,
      viewportRows: viewportRows,
      isHoverEdge: isHoverEdge,
      isAltScreen: isAltScreen,
      isMouseTracking: isMouseTracking
    )
    if input == lastInput { return }
    apply(input: input)
  }

  /// Hide immediately. Called when there is no active tab/session.
  func reset() {
    lastInput = nil
    lastOutput = .hidden
    lastLinesBack = 0
    cancelIdleHide()
    setThumbOpacity(0, animated: false)
    setPillAlpha(0, animated: false)
  }

  override func layout() {
    super.layout()
    layoutFromOutput()
  }

  private func apply(input: TerminalScrollIndicator.Input) {
    lastInput = input
    let output = TerminalScrollIndicator.decide(input)
    let wasVisible = thumbLayer.opacity > 0
    let linesBack = TerminalScrollIndicator.linesBack(input)
    let action = TerminalScrollIndicator.idleHideAction(
      shouldHold: output.shouldHold,
      linesBack: linesBack,
      previousLinesBack: lastLinesBack,
      isVisible: wasVisible,
      hidePending: idleHideWorkItem != nil
    )
    lastLinesBack = linesBack
    lastOutput = output
    // While the thumb stays hidden, skip the Core Animation layout entirely.
    // During sustained streaming at the live bottom `input` changes every frame
    // (rows keep arriving) but nothing is on screen, so laying out the invisible
    // thumb — and measuring the pill — is pure waste. The thumb reappears via
    // `.hold`, which lays out then with the current output.
    if !(action == .keep && !wasVisible) {
      layoutFromOutput()
    }

    switch action {
    case .hold:
      cancelIdleHide()
      setThumbOpacity(1, animated: !wasVisible)
      setPillAlpha(output.pillVisible ? 1 : 0, animated: !wasVisible && output.pillVisible)
    case .armHide:
      // Scrolling just brought us back to the live bottom (or input snapped us
      // there): hold briefly so the user sees the snap, then fade. Streaming
      // output keeps `linesBack` at 0, so it lands in `.keep` and cannot keep
      // re-arming this — the indicator hides once scrolling has actually stopped.
      scheduleIdleHide()
    case .keep:
      break
    }
  }

  private func layoutFromOutput() {
    layoutPassCountForTesting += 1
    guard lastOutput.thumbFraction > 0 else { return }
    let trackTop = bounds.height - Self.topInset
    let trackBottom = Self.bottomInset
    let trackHeight = max(0, trackTop - trackBottom)
    let rawThumbHeight = trackHeight * CGFloat(lastOutput.thumbFraction)
    let thumbHeight = min(trackHeight, max(Self.minThumbHeight, rawThumbHeight))
    let availableTravel = max(0, trackHeight - thumbHeight)
    // Map [0, 1 - thumbFraction] (decide's range) to [0, availableTravel].
    let normalized =
      lastOutput.thumbFraction < 1
      ? lastOutput.thumbOffsetFraction / max(1 - lastOutput.thumbFraction, 0.001)
      : 0
    let offsetFromTop = availableTravel * CGFloat(normalized)
    // Stay fat while scrolled back, dragging, or edge-hovering so the thumb
    // does not pulse between idle/hover widths during a scroll gesture.
    let expanded = isHoverEdge || isDragging || lastLinesBack > 0
    let thumbWidth = expanded ? Self.thumbWidthHover : Self.thumbWidthIdle

    let thumbX = bounds.maxX - Self.edgeInset - thumbWidth
    let thumbY = trackTop - offsetFromTop - thumbHeight
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    thumbLayer.frame = NSRect(x: thumbX, y: thumbY, width: thumbWidth, height: thumbHeight)
    thumbLayer.cornerRadius = thumbWidth / 2
    thumbLayer.backgroundColor = Self.thumbColor(hover: expanded)
    CATransaction.commit()

    // Pill: top-right, just under the titlebar reserve, left of the thumb.
    // Opacity (not isHidden) controls visibility — keeps the view in the tree
    // so the fade animation can run when scrolledBack flips. Only measure and
    // reposition while the pill is shown; `fittingSize` runs AppKit layout, so a
    // held-visible pill reuses the cached size until its text changes.
    if lastOutput.pillVisible {
      if lastOutput.pillText != lastPillText {
        pillLabel.stringValue = lastOutput.pillText
        lastPillText = lastOutput.pillText
        lastPillFittedSize = pillContainer.fittingSize
      }
      let pillSize = lastPillFittedSize
      let pillX = bounds.maxX - Self.edgeInset - Self.thumbWidthHover - 6 - pillSize.width
      let pillY = trackTop - pillSize.height
      pillContainer.frame = NSRect(
        x: max(pillX, 0), y: max(pillY, 0),
        width: pillSize.width, height: pillSize.height)
    }
  }

  private func setThumbOpacity(_ value: Float, animated: Bool) {
    guard abs(thumbLayer.opacity - value) > 0.001 else { return }
    if animated {
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = thumbLayer.opacity
      anim.toValue = value
      anim.duration = value > 0 ? Self.fadeInDuration : Self.fadeOutDuration
      thumbLayer.add(anim, forKey: "fade")
    } else {
      thumbLayer.removeAnimation(forKey: "fade")
    }
    thumbLayer.opacity = value
  }

  private func setPillAlpha(_ value: CGFloat, animated: Bool) {
    guard abs(pillContainer.alphaValue - value) > 0.001 else { return }
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = value > 0 ? Self.fadeInDuration : Self.fadeOutDuration
        pillContainer.animator().alphaValue = value
      }
    } else {
      NSAnimationContext.current.allowsImplicitAnimation = false
      pillContainer.alphaValue = value
    }
  }

  private func scheduleIdleHide() {
    cancelIdleHide()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.setThumbOpacity(0, animated: true)
      self.setPillAlpha(0, animated: true)
    }
    idleHideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleHoldDuration, execute: work)
  }

  private func cancelIdleHide() {
    idleHideWorkItem?.cancel()
    idleHideWorkItem = nil
  }

  /// Re-read chrome from `Theme.current` so the pill and thumb stay legible on
  /// dark palettes (Selenized Dark, Gruvbox, etc.) even when macOS appearance
  /// does not match the terminal theme.
  private func applyThemeChrome() {
    let theme = Theme.current
    pillContainer.layer?.backgroundColor = Self.themedCGColor(theme.bg2, alpha: 0.94)
    pillContainer.layer?.borderColor = Self.themedCGColor(theme.dim0, alpha: 0.55)
    pillLabel.textColor = Self.themedNSColor(theme.fg0)
  }

  private static func thumbColor(hover: Bool) -> CGColor {
    let theme = Theme.current
    let rgba = hover ? theme.fg0 : theme.dim0
    let alpha: CGFloat = hover ? 0.82 : 0.62
    return themedCGColor(rgba, alpha: alpha)
  }

  private static func themedNSColor(_ rgba: UInt32) -> NSColor {
    NSColor(
      red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
      green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
      blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
      alpha: 1)
  }

  private static func themedCGColor(_ rgba: UInt32, alpha: CGFloat) -> CGColor {
    CGColor(
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      components: [
        CGFloat((rgba >> 24) & 0xFF) / 255.0,
        CGFloat((rgba >> 16) & 0xFF) / 255.0,
        CGFloat((rgba >> 8) & 0xFF) / 255.0,
        alpha,
      ])!
  }
}

extension TerminalScrollIndicator.Input {
  fileprivate func withHover(_ value: Bool) -> Self {
    var copy = self
    copy.isHoverEdge = value
    return copy
  }
}

// MARK: - Scroll-indicator diagnostics (gated by --scroll-debug)

extension TerminalScrollIndicatorView {
  /// The indicator's *real on-screen* state — the layer opacities the user
  /// actually sees plus the last decision it rendered. Lets `ScrollDebugServer`
  /// confirm "the pill is visible" against hard numbers instead of a screenshot.
  struct DebugVisibility {
    var thumbOpacity: Double
    var pillAlpha: Double
    var shouldHold: Bool
    var pillVisible: Bool
    var pillText: String
    var lastLinesBack: Int
    /// The view's current hover flag and whether the pointer is *actually* in
    /// the right-edge zone. `isHoverEdge=true` with `pointerInZone=false` is the
    /// stuck-hover bug; the self-correction clears it on the next sample.
    var isHoverEdge: Bool
    var pointerInZone: Bool

    var dictionary: [String: Any] {
      [
        "thumbOpacity": thumbOpacity, "pillAlpha": pillAlpha, "shouldHold": shouldHold,
        "pillVisible": pillVisible, "pillText": pillText, "lastLinesBack": lastLinesBack,
        "isHoverEdge": isHoverEdge, "pointerInZone": pointerInZone,
      ]
    }
  }

  struct ThemeChromeForTesting {
    var pillBackground: CGColor?
    var pillBorder: CGColor?
    var pillText: NSColor?
  }

  func themeChromeForTesting() -> ThemeChromeForTesting {
    ThemeChromeForTesting(
      pillBackground: pillContainer.layer?.backgroundColor,
      pillBorder: pillContainer.layer?.borderColor,
      pillText: pillLabel.textColor)
  }

  func debugVisibility() -> DebugVisibility {
    DebugVisibility(
      thumbOpacity: Double(thumbLayer.opacity),
      pillAlpha: Double(pillContainer.alphaValue),
      shouldHold: lastOutput.shouldHold,
      pillVisible: lastOutput.pillVisible,
      pillText: lastOutput.pillText,
      lastLinesBack: lastLinesBack,
      isHoverEdge: isHoverEdge,
      pointerInZone: pointerInHoverZone())
  }
}
