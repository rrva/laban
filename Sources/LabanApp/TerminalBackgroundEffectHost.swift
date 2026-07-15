import AppKit
import LabanCore

/// Owns the optional AppKit material behind the terminal content plane.
///
/// The host itself is constrained to begin at the terminal/sidebar boundary,
/// so the sidebar remains fully opaque even while the terminal uses a
/// behind-window material.
@MainActor
final class TerminalBackgroundEffectHost: NSView {
  private var effectView: NSVisualEffectView?
  private var placementConstraints: [NSLayoutConstraint] = []

  private(set) var appliedStyle: TerminalBackdropStyle = .none

  var supportsBehindWindowBlur: Bool {
    superview != nil && !placementConstraints.isEmpty
  }
  var backdropSubviewCount: Int { effectView == nil ? 0 : 1 }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isHidden = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    isHidden = true
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

  func apply(_ style: TerminalBackdropStyle) {
    switch style {
    case .none:
      effectView?.removeFromSuperview()
      effectView = nil
      isHidden = true

    case .systemBlur:
      if effectView == nil {
        let effectView = NSVisualEffectView(frame: bounds)
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .underWindowBackground
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        addSubview(effectView)
        NSLayoutConstraint.activate([
          effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
          effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
          effectView.topAnchor.constraint(equalTo: topAnchor),
          effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.effectView = effectView
      }
      isHidden = false
    }
    appliedStyle = style
  }
}
