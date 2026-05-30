import AppKit
import LabanCore

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
  private var isHoverEdge = false
  private var idleHideWorkItem: DispatchWorkItem?
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.masksToBounds = false

    thumbLayer.backgroundColor = TerminalScrollIndicatorView.thumbColor(hover: false)
    thumbLayer.cornerRadius = Self.thumbWidthIdle / 2
    thumbLayer.opacity = 0
    layer?.addSublayer(thumbLayer)

    pillContainer.wantsLayer = true
    pillContainer.layer?.cornerRadius = 8
    pillContainer.layer?.backgroundColor =
      NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
    pillContainer.layer?.borderColor = NSColor.separatorColor.cgColor
    pillContainer.layer?.borderWidth = 1
    pillContainer.alphaValue = 0
    pillContainer.translatesAutoresizingMaskIntoConstraints = true

    pillLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    pillLabel.textColor = .secondaryLabelColor
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
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Click-transparent: pass all hits through to the terminal. The tracking
  // area for hover-reveal works independently of hit-testing.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

  /// Called every frame from `TerminalBitmapView.advanceFrame`. Cheap noop
  /// when the viewport state hasn't changed.
  func applyViewport(
    viewportOffset: Int, totalRows: Int, viewportRows: Int, isAltScreen: Bool
  ) {
    let input = TerminalScrollIndicator.Input(
      viewportOffset: viewportOffset,
      totalRows: totalRows,
      viewportRows: viewportRows,
      isHoverEdge: isHoverEdge,
      isAltScreen: isAltScreen
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
    layoutFromOutput()

    switch action {
    case .hold:
      cancelIdleHide()
      setThumbOpacity(1, animated: !wasVisible)
      setPillAlpha(output.pillVisible ? 1 : 0, animated: true)
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
    let thumbWidth = isHoverEdge ? Self.thumbWidthHover : Self.thumbWidthIdle

    let thumbX = bounds.maxX - Self.edgeInset - thumbWidth
    let thumbY = trackTop - offsetFromTop - thumbHeight
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    thumbLayer.frame = NSRect(x: thumbX, y: thumbY, width: thumbWidth, height: thumbHeight)
    thumbLayer.cornerRadius = thumbWidth / 2
    thumbLayer.backgroundColor = TerminalScrollIndicatorView.thumbColor(hover: isHoverEdge)
    CATransaction.commit()

    // Pill: top-right, just under the titlebar reserve, left of the thumb.
    // Opacity (not isHidden) controls visibility — keeps the view in the tree
    // so the fade animation can run when scrolledBack flips.
    if lastOutput.pillVisible {
      pillLabel.stringValue = lastOutput.pillText
    }
    let pillSize = pillContainer.fittingSize
    let pillX = bounds.maxX - Self.edgeInset - Self.thumbWidthHover - 6 - pillSize.width
    let pillY = trackTop - pillSize.height
    pillContainer.frame = NSRect(
      x: max(pillX, 0), y: max(pillY, 0),
      width: pillSize.width, height: pillSize.height)
  }

  private func setThumbOpacity(_ value: Float, animated: Bool) {
    if animated {
      let anim = CABasicAnimation(keyPath: "opacity")
      anim.fromValue = thumbLayer.opacity
      anim.toValue = value
      anim.duration = value > 0 ? Self.fadeInDuration : Self.fadeOutDuration
      thumbLayer.add(anim, forKey: "fade")
    }
    thumbLayer.opacity = value
  }

  private func setPillAlpha(_ value: CGFloat, animated: Bool) {
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = value > 0 ? Self.fadeInDuration : Self.fadeOutDuration
        pillContainer.animator().alphaValue = value
      }
    } else {
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

  private static func thumbColor(hover: Bool) -> CGColor {
    let base: NSColor = hover ? .secondaryLabelColor : .tertiaryLabelColor
    let alpha: CGFloat = hover ? 0.78 : 0.55
    return base.withAlphaComponent(alpha).cgColor
  }
}

extension TerminalScrollIndicator.Input {
  fileprivate func withHover(_ value: Bool) -> Self {
    var copy = self
    copy.isHoverEdge = value
    return copy
  }
}
