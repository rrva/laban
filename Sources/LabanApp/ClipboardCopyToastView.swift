import AppKit

/// Brief status pill over the terminal: "Copied 1.2 KB to clipboard" when a
/// program copies through OSC 52 (usually a remote program over SSH, otherwise
/// silent), and the progress/failure of a clipboard image upload over SSH
/// (ADR 0039).
///
/// A sibling overlay of the terminal view in the window's container (like
/// `TerminalScrollIndicatorView`), so the Metal layer compositing is untouched.
/// It never takes mouse events.
final class ClipboardCopyToastView: NSView {
  /// How long the pill stays fully visible before fading out.
  static let visibleDuration: TimeInterval = 1.6

  private let label = NSTextField(labelWithString: "")
  private var hideWorkItem: DispatchWorkItem?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
    alphaValue = 0
    isHidden = true
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    label.textColor = .white
    label.alignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  /// The pill's text, for tests and diagnostics.
  var message: String { label.stringValue }

  /// Localized message for a copy of `byteCount` bytes.
  static func message(forByteCount byteCount: Int) -> String {
    let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    return String(format: L10n.tr("Copied %@ to clipboard"), size)
  }

  /// Localized "Uploading image to <destination>…" message.
  static func uploadingImageMessage(destination: String) -> String {
    String(format: L10n.tr("Uploading image to %@…"), destination)
  }

  /// Localized "Couldn't upload image: <reason>" message.
  static func imageUploadFailedMessage(reason: String) -> String {
    String(format: L10n.tr("Couldn't upload image: %@"), reason)
  }

  /// Show the pill for a copy of `byteCount` bytes, centered near the bottom
  /// of `bounds` (the superview's bounds), restarting the fade timer.
  func show(byteCount: Int, in bounds: NSRect) {
    show(message: Self.message(forByteCount: byteCount), in: bounds)
  }

  /// Show `message` centered near the bottom of `bounds` for `duration`
  /// seconds, restarting the fade timer.
  func show(message: String, in bounds: NSRect, duration: TimeInterval = visibleDuration) {
    label.stringValue = message
    setAccessibilityLabel(label.stringValue)
    let textSize = label.intrinsicContentSize
    // An upload failure reason can be long; never grow past the terminal.
    let maxWidth = max(bounds.width - 32, 48)
    let size = NSSize(
      width: min(ceil(textSize.width) + 24, maxWidth), height: ceil(textSize.height) + 12)
    frame = NSRect(
      x: bounds.midX - size.width / 2, y: bounds.minY + 24,
      width: size.width, height: size.height)
    autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
    superview?.addSubview(self, positioned: .above, relativeTo: nil)
    isHidden = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      animator().alphaValue = 1
    }
    hideWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
    hideWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
  }

  /// Fade the pill out now (e.g. an upload finished before its timeout).
  func hide() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    guard !isHidden else { return }
    fadeOut()
  }

  private func fadeOut() {
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.3
        animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        guard let self, self.alphaValue == 0 else { return }
        self.isHidden = true
      })
  }
}
