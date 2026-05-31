import AppKit

/// Single source of truth for how an active PTY capture surfaces in the UI:
/// the Debug-menu item title, the window-title suffix, and the on-surface
/// "● REC" pill all derive their text/visibility from these pure helpers so
/// the menu and the indicator can never disagree about whether capture is on.
enum TerminalCaptureIndicator {
  /// Mutating Debug-menu title. AppKit keeps one persistent NSMenuItem and one
  /// action (`toggleCapture(_:)`); only the title flips, like Show/Hide Sidebar.
  static func menuTitle(active: Bool) -> String {
    active ? "Stop PTY Capture" : "Start PTY Capture"
  }

  /// Window-title suffix shown while capturing; empty when idle.
  static func windowTitleSuffix(active: Bool) -> String {
    active ? " — ● REC" : ""
  }

  /// Text drawn in the on-surface recording pill.
  static let pillText = "● REC"
}

/// A small, unobtrusive but obvious red "● REC" pill drawn in the top-right
/// corner of the terminal surface while a capture is running. Hidden when no
/// capture is active. Mirrors the find-chip subview pattern: a sibling NSView
/// laid out by the host TerminalBitmapView, not painted into the Metal surface.
final class TerminalCaptureIndicatorView: NSView {
  static let preferredSize = NSSize(width: 64, height: 20)

  private let label = NSTextField(labelWithString: TerminalCaptureIndicator.pillText)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = true
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
    layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
    layer?.borderWidth = 1

    label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)
    label.textColor = .systemRed
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setAccessibilityLabel("Recording PTY capture")
    addSubview(label)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    setAccessibilityRole(.staticText)
    setAccessibilityLabel("Recording PTY capture")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // The pill is purely decorative; clicks fall through to the terminal.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
