import AppKit
import LabanCore
import LabanRenderer

/// The About window: build identity, the component stack, what programs see
/// (with a live capability self-test), and credits. Replaces the standard
/// About panel so the page doubles as the first stop of a bug report.
final class AboutWindowController: NSWindowController {
  /// Live renderer status of the frontmost terminal, nil when no window.
  var rendererStatus: () -> RendererStatus? = { nil }

  private let content = NSStackView()
  private var selfTestStack: NSStackView?
  private var selfTestButton: NSButton?

  init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = L10n.tr("About Laban")
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

  // MARK: - Sections

  private func rebuild() {
    content.arrangedSubviews.forEach { $0.removeFromSuperview() }
    content.addArrangedSubview(header())
    content.addArrangedSubview(section(L10n.tr("Build"), rows: buildRows()))
    content.addArrangedSubview(section(L10n.tr("Components"), rows: componentRows()))
    content.addArrangedSubview(programsSection())
    content.addArrangedSubview(creditsSection())
  }

  private func header() -> NSView {
    let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
    icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 64),
      icon.heightAnchor.constraint(equalToConstant: 64),
    ])
    let name = label("Laban", font: .systemFont(ofSize: 22, weight: .semibold))
    let version = label(
      "Version \(BuildInfo.version) (\(BuildInfo.commit))", font: .systemFont(ofSize: 13))
    let built = label(
      ["Built \(BuildInfo.date)", BuildInfo.ageDescription()].compactMap { $0 }
        .joined(separator: " · "),
      font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    let text = NSStackView(views: [name, version, built])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2
    let row = NSStackView(views: [icon, text])
    row.spacing = 14
    row.alignment = .centerY
    return row
  }

  private func buildRows() -> [(String, String)] {
    let signing = AboutInfo.codeSigning()
    let updates: String
    if UpdaterController.shared.isConfigured {
      let last = UpdaterController.shared.lastUpdateCheckDate.map {
        "last checked \(AboutInfo.relative($0))"
      }
      let auto =
        UpdaterController.shared.automaticallyChecksForUpdates
        ? "automatic checks on" : "automatic checks off"
      updates = [auto, last].compactMap { $0 }.joined(separator: ", ")
    } else {
      updates = "Off: this build has no update feed"
    }
    return [
      ("Signed by", signing.summary),
      ("Signature", signing.details),
      ("Updates", updates),
    ]
  }

  private func componentRows() -> [(String, String)] {
    let vt = AboutInfo.vtCore()
    var rows: [(String, String)] = [
      ("macOS", AboutInfo.systemSummary()),
      ("Terminal engine", vt.summary),
    ]
    if !vt.patches.isEmpty {
      rows.append(("Patches", vt.patches.joined(separator: "\n")))
    }
    if let status = rendererStatus() {
      var renderer = status.effectiveRenderer
      if status.configuredRenderer != status.effectiveRenderer {
        renderer += " (configured: \(status.configuredRenderer))"
      }
      if let reason = status.fallbackReason { renderer += ", fallback: \(reason)" }
      rows.append(("Renderer", renderer))
    }
    rows.append(("Font", AboutInfo.fontSummary()))
    rows.append(("Theme", AboutInfo.themeSummary()))
    rows.append(("GPU", AboutInfo.gpuName()))
    rows.append(("Display", AboutInfo.displaySummary(for: window?.screen ?? NSScreen.main)))
    let daemons = AboutInfo.sessionDaemons()
    if daemons.isEmpty {
      rows.append(("Session daemon", "No labpty session daemon running"))
    } else {
      for daemon in daemons {
        var text = "labpty pid \(daemon.pid), started \(AboutInfo.relative(daemon.startedAt))"
        if !daemon.isThisAppsBinary {
          text += "\nLaunched from \(daemon.executablePath)"
        }
        if daemon.runsDifferentBuild == true {
          text += "\nRuns a different build than this app's labpty; it keeps your shells "
            + "alive and switches to this build when it is next started."
        }
        rows.append(("Session daemon", text))
      }
    }
    return rows
  }

  private func programsSection() -> NSView {
    let rows: [(String, String)] = [
      ("TERM", AboutInfo.terminalType),
      ("TERM_PROGRAM", AboutInfo.terminalProgram()),
      ("Kitty graphics", AboutInfo.kittyGraphicsSummary()),
    ]
    let stack = section(L10n.tr("What programs see"), rows: rows)

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
    selfTestButton = button
    selfTestStack = results
    return stack
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
    let stack = section(L10n.tr("Credits"), rows: [])
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
    let summary = Self.selfTestSummary(outcome)
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
      switch result.status {
      case .passed: (mark, color) = ("✓", .systemGreen)
      case .failed: (mark, color) = ("✗", .systemRed)
      case .disabled: (mark, color) = ("–", .secondaryLabelColor)
      }
      let statusWord: String
      switch result.status {
      case .passed: statusWord = "Passed"
      case .failed: statusWord = "Failed"
      case .disabled: statusWord = "Turned off"
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
    guard
      let url = Bundle.main.resourceURL?
        .appendingPathComponent("Licenses/THIRD_PARTY_LICENSES.md"),
      FileManager.default.fileExists(atPath: url.path)
    else {
      NSSound.beep()
      return
    }
    // Open as plain text: a .md file's default handler may be Xcode or nothing.
    let configuration = NSWorkspace.OpenConfiguration()
    if let textEdit = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.apple.TextEdit")
    {
      NSWorkspace.shared.open(
        [url], withApplicationAt: textEdit, configuration: configuration,
        completionHandler: nil)
    } else {
      NSWorkspace.shared.open(url)
    }
  }

  /// "10 passed", "9 passed, 1 turned off", "8 passed, 2 failed".
  static func selfTestSummary(
    _ results: [TerminalCapabilitySelfTest.Result]
  ) -> (text: String, allPassed: Bool) {
    let passed = results.filter { $0.status == .passed }.count
    let failed = results.filter { $0.status == .failed }.count
    let off = results.filter { $0.status == .disabled }.count
    var parts = ["\(passed) passed"]
    if off > 0 { parts.append("\(off) turned off") }
    if failed > 0 { parts.append("\(failed) failed") }
    return (parts.joined(separator: ", "), failed == 0)
  }

  // MARK: - Building blocks

  private func section(_ title: String, rows: [(String, String)]) -> NSStackView {
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
    let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
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
