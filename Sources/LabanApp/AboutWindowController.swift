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
      updates = "Not configured (local build)"
    }
    return [
      ("Signed by", signing.summary),
      ("Signature", signing.details),
      ("Updates", updates),
    ]
  }

  private func componentRows() -> [(String, String)] {
    let vt = AboutInfo.vtCore()
    var rows: [(String, String)] = [("VT core", vt.summary)]
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
    rows.append(("GPU", AboutInfo.gpuName()))
    rows.append(("Display", AboutInfo.displaySummary(for: window?.screen ?? NSScreen.main)))
    let daemons = AboutInfo.sessionDaemons()
    if daemons.isEmpty {
      rows.append(("Session daemon", "Not running (sessions run inside the app)"))
    } else {
      for daemon in daemons {
        var text = "labpty pid \(daemon.pid), started \(AboutInfo.relative(daemon.startedAt))"
        if daemon.isOlderThanInstalledBinary {
          text += "\nRunning an older build than the installed app; it keeps your shells "
            + "alive and upgrades when it is next started."
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
      "Sends the capability queries programs use to a scratch terminal and checks each reply.",
      font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
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
    let credits = [
      "Terminal emulation is libghostty-vt from the Ghostty project (MIT); everything "
        + "above it (rendering, sessions, agent integration) is Laban.",
      "Slug Glyph rendering implements Eric Lengyel's Slug algorithm (“GPU-Centered Font "
        + "Rendering Directly from Glyph Outlines”, JCGT 2017).",
      "JetBrains Mono (SIL Open Font License 1.1) · Sparkle (MIT) · Selenized colors by "
        + "Jan Warchoł.",
    ]
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
    let passed = outcome.filter { $0.status != .failed }.count
    results.addArrangedSubview(
      label(
        "\(passed) of \(outcome.count) as expected",
        font: .systemFont(ofSize: 12, weight: .semibold),
        color: passed == outcome.count ? .systemGreen : .systemRed))
    for result in outcome {
      let mark: String
      let color: NSColor
      switch result.status {
      case .passed: (mark, color) = ("✓", .systemGreen)
      case .failed: (mark, color) = ("✗", .systemRed)
      case .disabled: (mark, color) = ("–", .secondaryLabelColor)
      }
      let symbol = label(mark, font: .systemFont(ofSize: 12, weight: .bold), color: color)
      let name = label(result.name, font: .systemFont(ofSize: 12))
      name.toolTip = result.purpose
      let reply = label(
        result.status == .disabled ? "switched off" : result.reply,
        font: .monospacedSystemFont(ofSize: 11, weight: .regular),
        color: .secondaryLabelColor)
      reply.isSelectable = true
      let row = NSStackView(views: [symbol, name, reply])
      row.spacing = 8
      results.addArrangedSubview(row)
    }
    selfTestButton?.title = L10n.tr("Run Self-Test")
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
    NSWorkspace.shared.open(url)
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
          return [
            label(key, font: .systemFont(ofSize: 12), color: .secondaryLabelColor),
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
