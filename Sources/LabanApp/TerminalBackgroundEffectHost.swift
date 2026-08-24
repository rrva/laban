import AppKit
import LabanCore

/// A native terminal-background plane that consumes only an already-decoded,
/// app-managed image. It never resolves paths, decodes files, or schedules
/// independent redraws.
@MainActor
final class TerminalBackgroundImageView: NSView {
  private var image: CGImage?
  private(set) var managedImageIdentifier: String?
  private(set) var scaling: TerminalBackgroundImageScaling = .default
  private(set) var configurationApplyCount = 0
  private(set) var drawCount = 0
  private(set) var resizeInvalidationCount = 0

  override var isOpaque: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override func setFrameSize(_ newSize: NSSize) {
    let changed = frame.size != newSize
    super.setFrameSize(newSize)
    if changed {
      resizeInvalidationCount += 1
      needsDisplay = true
    }
  }

  /// Returns true only when the visible image configuration changed.
  @discardableResult
  func configure(
    asset: TerminalResolvedBackgroundImage,
    scaling: TerminalBackgroundImageScaling
  ) -> Bool {
    guard
      managedImageIdentifier != asset.managedImage.identifier
        || image !== asset.image
        || self.scaling != scaling
    else { return false }

    image = asset.image
    managedImageIdentifier = asset.managedImage.identifier
    self.scaling = scaling
    configurationApplyCount += 1
    needsDisplay = true
    return true
  }

  static func destinationRect(
    imageSize: CGSize,
    in bounds: CGRect,
    scaling: TerminalBackgroundImageScaling
  ) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0
    else { return .zero }

    switch scaling {
    case .stretch:
      return bounds

    case .fill, .fit:
      let widthScale = bounds.width / imageSize.width
      let heightScale = bounds.height / imageSize.height
      let scale =
        scaling == .fill
        ? max(widthScale, heightScale)
        : min(widthScale, heightScale)
      let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
      return CGRect(
        x: bounds.midX - size.width / 2,
        y: bounds.midY - size.height / 2,
        width: size.width,
        height: size.height)
    }
  }

  var imageDestinationRect: CGRect {
    guard let image else { return .zero }
    return Self.destinationRect(
      imageSize: CGSize(width: image.width, height: image.height),
      in: bounds,
      scaling: scaling)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    drawCount += 1

    // Fit letterboxes and transparent source pixels must never reveal another
    // app or window. The entire semantic child is therefore opaque black.
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(dirtyRect)
    guard let image else { return }

    context.saveGState()
    context.clip(to: bounds)
    context.interpolationQuality = .high
    context.draw(image, in: imageDestinationRect)
    context.restoreGState()
  }
}

/// Owns the optional native backdrop behind the terminal content plane.
///
/// The host itself is constrained to begin at the terminal/sidebar boundary,
/// so the sidebar remains fully opaque while the terminal may use a system
/// material or managed image.
@MainActor
final class TerminalBackgroundEffectHost: NSView {
  private var effectView: NSVisualEffectView?
  private(set) var imageView: TerminalBackgroundImageView?
  private var semanticChildConstraints: [NSLayoutConstraint] = []
  private var placementConstraints: [NSLayoutConstraint] = []
  private var retiredImageRedrawCount = 0
  /// Set when the material view was installed before the host had real
  /// geometry. A behind-window material created at zero bounds can render
  /// only its flat tint — the WindowServer backdrop never engages — so the
  /// material is reinstalled once at the first layout with real bounds.
  private var needsBlurReinstallForRealGeometry = false

  private(set) var backgroundImageApplyCount = 0

  var backgroundImageRedrawCount: Int {
    retiredImageRedrawCount + (imageView?.drawCount ?? 0)
  }

  private(set) var appliedStyle: TerminalBackdropStyle = .none

  var supportsBehindWindowBlur: Bool {
    superview != nil && !placementConstraints.isEmpty
  }

  var backdropSubviewCount: Int {
    (effectView == nil ? 0 : 1) + (imageView == nil ? 0 : 1)
  }

  var backdropSubviewKind: TerminalBackdropStyle {
    if effectView != nil { return .systemBlur }
    if imageView != nil { return .image }
    return .none
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isHidden = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    isHidden = true
  }

  override func layout() {
    super.layout()
    reinstallSystemBlurForRealGeometryIfNeeded()
  }

  /// The persisted-backdrop launch path applies System Blur before the first
  /// layout pass (coordinator init precedes order-in), so the material view is
  /// created at zero bounds. Reinstall it once real geometry exists — the
  /// state the post-order install path reaches directly.
  private func reinstallSystemBlurForRealGeometryIfNeeded() {
    guard needsBlurReinstallForRealGeometry, appliedStyle == .systemBlur, !bounds.isEmpty
    else { return }
    needsBlurReinstallForRealGeometry = false
    removeSemanticChild()
    installSystemBlurIfNeeded()
  }

  /// Installs this host behind the terminal plane and pins it to the portion
  /// of the window that excludes the sidebar.
  func install(in containerView: NSView, terminalLeadingInset: CGFloat) {
    precondition(superview == nil, "TerminalBackgroundEffectHost can only be installed once")
    translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(self)
    placementConstraints = [
      leadingAnchor.constraint(
        equalTo: containerView.leadingAnchor,
        constant: terminalLeadingInset),
      trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      topAnchor.constraint(equalTo: containerView.topAnchor),
      bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
    ]
    NSLayoutConstraint.activate(placementConstraints)
  }

  /// Move the host's leading edge, so hiding the sidebar hands its strip to the
  /// background/blur plane instead of leaving it uncovered.
  func setTerminalLeadingInset(_ inset: CGFloat) {
    guard let leading = placementConstraints.first(where: { $0.firstAttribute == .leading })
    else { return }
    guard leading.constant != inset else { return }
    leading.constant = inset
  }

  func apply(
    _ style: TerminalBackdropStyle,
    imageAsset: TerminalResolvedBackgroundImage? = nil,
    imageScaling: TerminalBackgroundImageScaling = .default
  ) {
    switch style {
    case .none:
      removeSemanticChild()
      appliedStyle = .none
      isHidden = true

    case .systemBlur:
      installSystemBlurIfNeeded()
      appliedStyle = .systemBlur
      isHidden = false

    case .image:
      guard let imageAsset else {
        removeSemanticChild()
        appliedStyle = .none
        isHidden = true
        return
      }
      installImageIfNeeded(asset: imageAsset, scaling: imageScaling)
      appliedStyle = .image
      isHidden = false
    }

    precondition(backdropSubviewCount <= 1, "Terminal backdrop must own at most one child")
  }

  func resetBackgroundImageDiagnostics() {
    backgroundImageApplyCount = 0
    retiredImageRedrawCount = -(imageView?.drawCount ?? 0)
  }

  private func installSystemBlurIfNeeded() {
    guard effectView == nil else { return }
    removeSemanticChild()
    let effectView = NSVisualEffectView(frame: bounds)
    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.material = .underWindowBackground
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    addSubview(effectView)
    self.effectView = effectView
    pinSemanticChild(effectView)
    needsBlurReinstallForRealGeometry = bounds.isEmpty
  }

  private func installImageIfNeeded(
    asset: TerminalResolvedBackgroundImage,
    scaling: TerminalBackgroundImageScaling
  ) {
    if let imageView {
      if imageView.configure(asset: asset, scaling: scaling) {
        backgroundImageApplyCount += 1
      }
      return
    }

    removeSemanticChild()
    let imageView = TerminalBackgroundImageView(frame: bounds)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.configure(asset: asset, scaling: scaling)
    backgroundImageApplyCount += 1
    addSubview(imageView)
    self.imageView = imageView
    pinSemanticChild(imageView)
  }

  private func pinSemanticChild(_ child: NSView) {
    semanticChildConstraints = [
      child.leadingAnchor.constraint(equalTo: leadingAnchor),
      child.trailingAnchor.constraint(equalTo: trailingAnchor),
      child.topAnchor.constraint(equalTo: topAnchor),
      child.bottomAnchor.constraint(equalTo: bottomAnchor),
    ]
    NSLayoutConstraint.activate(semanticChildConstraints)
  }

  private func removeSemanticChild() {
    NSLayoutConstraint.deactivate(semanticChildConstraints)
    semanticChildConstraints.removeAll()
    effectView?.removeFromSuperview()
    if let imageView {
      retiredImageRedrawCount += imageView.drawCount
      imageView.removeFromSuperview()
    }
    effectView = nil
    imageView = nil
  }
}
