import AppKit

/// Single source of truth for how active recording surfaces in the UI:
/// Debug-menu titles, window-title suffixes, and on-surface pills derive from
/// these helpers so the chrome cannot disagree about what is running.
enum TerminalCaptureIndicator {
  static let ptyPillText = "● REC"
  static let profilePillText = "● CPU"

  /// Backward-compatible alias for the PTY capture pill label.
  static let pillText = ptyPillText

  /// Mutating Debug-menu title. AppKit keeps one persistent NSMenuItem and one
  /// action (`toggleCapture(_:)`); only the title flips, like Show/Hide Sidebar.
  static func menuTitle(active: Bool) -> String {
    active ? "Stop PTY Capture" : "Start PTY Capture"
  }

  /// Window-title suffix while PTY capture is active; empty when idle.
  static func windowTitleSuffix(active: Bool) -> String {
    windowTitleSuffix(ptyActive: active, profileActive: false)
  }

  /// Window-title suffix for any combination of PTY and profile capture.
  static func windowTitleSuffix(ptyActive: Bool, profileActive: Bool) -> String {
    var parts: [String] = []
    if ptyActive { parts.append(ptyPillText) }
    if profileActive { parts.append(profilePillText) }
    return parts.isEmpty ? "" : " — " + parts.joined(separator: " ")
  }
}

/// A small, unobtrusive red pill drawn in the top-right corner of the terminal
/// surface while a capture or profile sample is running. Hidden when idle.
/// Mirrors the find-chip subview pattern: a sibling NSView laid out by the
/// host TerminalBitmapView, not painted into the Metal surface.
final class TerminalCaptureIndicatorView: NSView {
  static let preferredSize = NSSize(width: 64, height: 20)

  private let label = NSTextField(labelWithString: "")

  init(
    text: String = TerminalCaptureIndicator.ptyPillText,
    accessibilityLabel: String = "Recording PTY capture"
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
    layer?.borderWidth = 1

    label.stringValue = text
    label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    label.textColor = .systemRed
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityLabel(accessibilityLabel)
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityRole(.staticText)
    setAccessibilityLabel(accessibilityLabel)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The pill is purely decorative; clicks fall through to the terminal.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
