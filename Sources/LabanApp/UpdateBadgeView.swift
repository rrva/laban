import AppKit

/// Subtle bottom-left pill that appears only when a newer release is published.
/// Hidden in the up-to-date state — no chrome impact for users on the latest version.
final class UpdateBadgeView: NSView {
  static let preferredHeight: CGFloat = 18
  static let cornerInset: CGFloat = 8

  private let button = NSButton()
  private var onClick: (() -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    isHidden = true

    button.bezelStyle = .smallSquare
    button.isBordered = false
    button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
    button.contentTintColor = .white
    button.wantsLayer = true
    button.layer?.cornerRadius = Self.preferredHeight / 2
    button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
    button.translatesAutoresizingMaskIntoConstraints = false
    button.target = self
    button.action = #selector(handleClick)
    addSubview(button)

    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func showUpdate(version: String, notes: String?, onClick: @escaping () -> Void) {
    self.onClick = onClick
    button.title = " ↓ \(version) "
    button.toolTip = notes?.isEmpty == false ? notes : "Update to Laban \(version)"
    isHidden = false
    invalidateIntrinsicContentSize()
  }

  func clear() {
    isHidden = true
    onClick = nil
  }

  @objc private func handleClick() {
    onClick?()
  }

  override func updateLayer() {
    // Re-resolve the accent color when appearance changes (light/dark switch).
    button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
  }
}
