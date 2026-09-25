import AppKit
import LabanCore
import LabanRenderer

/// Help → Diagnostics…: the build, component stack and what programs are
/// told, a live capability self-test, and credits. The rows come from
/// `LabanDiagnostics`, shared with `laban version --verbose`; this window adds
/// the facts only the running app knows (updates, renderer, theme, display).
final class DiagnosticsWindowController: NSWindowController {
  /// Live renderer status of the frontmost terminal, nil when no window.
  var rendererStatus: () -> RendererStatus? = { nil }

  private let content = NSStackView()
  private var selfTestStack: NSStackView?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = L10n.tr("Diagnostics")
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 520, height: 420)
    super.init(window: window)

    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = 14
    content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 24, right: 24)
    content.translatesAutoresizingMaskIntoConstraints = false

    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = document
    window.contentView = scroll
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      content.topAnchor.constraint(equalTo: document.topAnchor),
      content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Rebuilds every section from live state and brings the window forward.
  func present() {
    rebuild()
    if window?.isVisible != true { window?.center() }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
  }

  // MARK: - App-only facts

  static func appFacts(
    renderer status: RendererStatus?, screen: NSScreen?,
    appearance: NSAppearance = NSApp.effectiveAppearance
  ) -> LabanDiagnostics.AppFacts {
    let updates: String
    if UpdaterController.shared.isConfigured {
      let last = UpdaterController.shared.lastUpdateCheckDate.map {
        "last checked \(LabanDiagnostics.relative($0))"
      }
      let auto =
        UpdaterController.shared.automaticallyChecksForUpdates
        ? "automatic checks on" : "automatic checks off"
      updates = [auto, last].compactMap { $0 }.joined(separator: ", ")
    } else {
      updates = "Off: this build has no update feed"
    }
    let renderer = status.map { status in
      var text = status.effectiveRenderer
      if status.configuredRenderer != status.effectiveRenderer {
        text += " (configured: \(status.configuredRenderer))"
      }
      if let reason = status.fallbackReason { text += ", fallback: \(reason)" }
      return text
    }
    return LabanDiagnostics.AppFacts(
      updates: updates, renderer: renderer, theme: themeSummary(appearance: appearance),
      display: displaySummary(for: screen),
      kittyImagesInUse: FrameImageStore.shared.count)
  }

  static func themeSummary(appearance: NSAppearance) -> String {
    let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let follows = Theme.followsSystemAppearance ? ", follows system appearance" : ""
    return "\(Theme.current.name) (\(dark ? "dark" : "light") mode\(follows))"
  }

  static func displaySummary(for screen: NSScreen?) -> String {
    guard let screen else { return "No display" }
    let points = screen.frame.size
    let scale = screen.backingScaleFactor
    let scaleText =
      scale == scale.rounded() ? String(Int(scale)) : String(format: "%.1f", scale)
    return "\(Int(points.width))×\(Int(points.height)) pt @\(scaleText)x, "
      + "\(screen.maximumFramesPerSecond) Hz"
  }

  // MARK: - Sections

  private func rebuild() {
    content.arrangedSubviews.forEach { $0.removeFromSuperview() }
    content.addArrangedSubview(header())
    let facts = Self.appFacts(
      renderer: rendererStatus(), screen: window?.screen ?? NSScreen.main)
    for section in LabanDiagnostics.sections(app: facts) {
      let stack = sectionView(
        L10n.tr(String.LocalizationValue(section.title)),
        rows: section.rows.map { ($0.label, $0.value) })
      if section.title == "What programs see" { addSelfTest(to: stack) }
      content.addArrangedSubview(stack)
    }
    content.addArrangedSubview(creditsSection())
  }

  private func header() -> NSView {
    let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 48),
      icon.heightAnchor.constraint(equalToConstant: 48),
    ])
    let name = label("Laban", font: .systemFont(ofSize: 18, weight: .semibold))
    let hint = label(
      "Also available as text: laban version --verbose (add --json for agents).",
      font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    hint.isSelectable = true
    let text = NSStackView(views: [name, hint])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2
    let row = NSStackView(views: [icon, text])
    row.spacing = 12
    row.alignment = .centerY
    return row
  }

  private func addSelfTest(to stack: NSStackView) {
    let button = NSButton(
      title: L10n.tr("Run Self-Test"), target: self, action: #selector(runSelfTest(_:)))
    button.bezelStyle = .rounded
    let hint = label(
      "Sends the queries programs use to detect terminal features to a scratch session of "
        + "this app's terminal engine, the same one that answers in-process and labpty "
        + "tabs, and checks each reply.",
      font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
    let results = NSStackView()
    results.orientation = .vertical
    results.alignment = .leading
    results.spacing = 4
    stack.addArrangedSubview(button)
    stack.addArrangedSubview(hint)
    stack.addArrangedSubview(results)
    selfTestStack = results
  }

  private func creditsSection() -> NSView {
    let copyright =
      Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    let credits = [
      "Terminal emulation is libghostty-vt from the Ghostty project (MIT). Laban builds "
        + "its rendering, sessions and agent integration on top.",
      "Slug Glyph rendering implements Eric Lengyel's Slug algorithm (“GPU-Centered Font "
        + "Rendering Directly from Glyph Outlines”, JCGT 2017).",
      "JetBrains Mono (SIL Open Font License 1.1) · Sparkle (MIT) · color palettes from "
        + "Selenized (Jan Warchoł), Rosé Pine, Catppuccin, Dracula, Nord, Tokyo Night and "
        + "Gruvbox.",
    ] + [copyright.map { "Laban \($0), MIT License." }].compactMap { $0 }
    let stack = sectionView(L10n.tr("Credits"), rows: [])
    for line in credits {
      stack.addArrangedSubview(label(line, font: .systemFont(ofSize: 12), wraps: true))
    }
    let licenses = NSButton(
      title: L10n.tr("Open Licenses"), target: self, action: #selector(openLicenses(_:)))
    licenses.bezelStyle = .rounded
    stack.addArrangedSubview(licenses)
    return stack
  }

  // MARK: - Actions

  @objc private func runSelfTest(_ sender: Any?) {
    guard let results = selfTestStack else { return }
    results.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard let outcome = TerminalCapabilitySelfTest.run() else {
      results.addArrangedSubview(
        label("Could not create a scratch terminal session.", font: .systemFont(ofSize: 12)))
      return
    }
    let summary = LabanDiagnostics.selfTestSummary(outcome)
    let summaryLabel = label(
      summary.text, font: .systemFont(ofSize: 12, weight: .semibold),
      color: summary.allPassed ? .systemGreen : .systemRed)
    results.addArrangedSubview(summaryLabel)
    NSAccessibility.post(
      element: summaryLabel, notification: .announcementRequested,
      userInfo: [.announcement: "Self-test finished. \(summary.text)."])
    for result in outcome {
      let mark: String
      let color: NSColor
      let statusWord: String
      switch result.status {
      case .passed: (mark, color, statusWord) = ("✓", .systemGreen, "Passed")
      case .failed: (mark, color, statusWord) = ("✗", .systemRed, "Failed")
      case .disabled: (mark, color, statusWord) = ("–", .secondaryLabelColor, "Turned off")
      }
      let symbol = label(mark, font: .systemFont(ofSize: 12, weight: .bold), color: color)
      let name = label(result.name, font: .systemFont(ofSize: 12))
      let replyText = result.status == .disabled ? "turned off" : result.reply
      let reply = label(
        replyText, font: .monospacedSystemFont(ofSize: 11, weight: .regular),
        color: .secondaryLabelColor)
      reply.isSelectable = true
      let purpose = label(
        result.purpose, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, wraps: true)
      let line = NSStackView(views: [symbol, name, reply])
      line.spacing = 8
      let row = NSStackView(views: [line, purpose])
      row.orientation = .vertical
      row.alignment = .leading
      row.spacing = 1
      row.setAccessibilityElement(true)
      row.setAccessibilityRole(.group)
      row.setAccessibilityLabel(
        "\(statusWord): \(result.name). \(result.purpose) Reply: \(replyText)")
      results.addArrangedSubview(row)
    }
  }

  @objc private func openLicenses(_ sender: Any?) {
    Self.openLicenses()
  }

  /// Opens the bundled `THIRD_PARTY_LICENSES.md` as plain text: a .md file's
  /// default handler may be Xcode or nothing.
  static func openLicenses() {
    guard
      let url = Bundle.main.resourceURL?
        .appendingPathComponent("Licenses/THIRD_PARTY_LICENSES.md"),
      FileManager.default.fileExists(atPath: url.path)
    else {
      NSSound.beep()
      return
    }
    if let textEdit = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.TextEdit")
    {
      NSWorkspace.shared.open(
        [url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration(),
        completionHandler: nil)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  // MARK: - Building blocks

  private func sectionView(_ title: String, rows: [(String, String)]) -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.addArrangedSubview(label(title, font: .systemFont(ofSize: 13, weight: .semibold)))
    if !rows.isEmpty {
      let grid = NSGridView(
        views: rows.map { key, value in
          let valueLabel = label(value, font: .systemFont(ofSize: 12), wraps: true)
          valueLabel.isSelectable = true
          valueLabel.setAccessibilityLabel("\(key): \(value)")
          return [
            label(
              L10n.tr(String.LocalizationValue(key)), font: .systemFont(ofSize: 12),
              color: .secondaryLabelColor),
            valueLabel,
          ]
        })
      grid.columnSpacing = 12
      grid.rowSpacing = 4
      grid.column(at: 0).xPlacement = .trailing
      grid.column(at: 0).width = 110
      for index in 0..<grid.numberOfRows {
        grid.row(at: index).yPlacement = .top
      }
      stack.addArrangedSubview(grid)
    }
    return stack
  }

  private func label(
    _ text: String, font: NSFont, color: NSColor = .labelColor, wraps: Bool = false
  ) -> NSTextField {
    let field =
      wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
    field.font = font
    field.textColor = color
    if wraps { field.preferredMaxLayoutWidth = 420 }
    return field
  }
}

/// Top-down document view so the scrolled content starts at the top.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}
