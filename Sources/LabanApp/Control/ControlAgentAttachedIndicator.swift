import AppKit

/// Chrome for the Phase 2 "agent attached" indicator: a small pill in the
/// terminal surface corner while a privileged control request was recent.
enum ControlAgentAttachedIndicator {
  static let pillText = "● Agent"
  static let accessibilityLabel = "Agent attached"
}

/// Unobtrusive pill drawn in the top-right of the terminal while privileged
/// control activity was recent (TTL-based — HTTP has no durable connection).
final class ControlAgentAttachedIndicatorView: NSView {
  static let preferredSize = NSSize(width: 72, height: 20)

  private let label = NSTextField(labelWithString: ControlAgentAttachedIndicator.pillText)

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
    layer?.borderWidth = 1

    label.stringValue = ControlAgentAttachedIndicator.pillText
    label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    label.textColor = .systemOrange
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityLabel(ControlAgentAttachedIndicator.accessibilityLabel)
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityRole(.staticText)
    setAccessibilityLabel(ControlAgentAttachedIndicator.accessibilityLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

protocol ControlAgentAttachedIndicatorHost: AnyObject {
  func setAgentAttachedIndicatorActive(_ active: Bool)
}
