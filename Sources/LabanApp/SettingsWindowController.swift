import AppKit
import LabanCore
import LabanRenderer

/// The native Settings (⌘,) window. It surfaces the choices that used to live
/// in the View and Workspace menus — theme, font, renderer, session backend,
/// and restore-on-launch — as standard AppKit controls. Every control drives
/// the same menu-controller apply path, so there is a single source of truth
/// and flipping a setting here behaves exactly as the old menu item did.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
  private let themeController: ThemeMenuController
  private let rendererController: RendererModeMenuController
  private let backendController: TerminalBackendMenuController
  private let onChangeFont: () -> Void

  private let themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let followSystemCheckbox = NSButton(
    checkboxWithTitle: "Follow system appearance", target: nil, action: nil)
  private let fontLabel = NSTextField(labelWithString: "")
  private let rendererPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let backendPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let identityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let restoreCheckbox = NSButton(
    checkboxWithTitle: "Restore tabs on launch", target: nil, action: nil)
  private let cursorStylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let blinkCheckbox = NSButton(
    checkboxWithTitle: "Blink cursor", target: nil, action: nil)

  /// Theme index (into `themeController.orderedThemes`) behind each popup row,
  /// or -1 for the dark/light separator. Maps a popup selection back to a theme.
  private var themeRowIndices: [Int] = []
  private let rendererOptions: [RendererSelection] = RendererSelection.allCases
  private let backendOptions: [TerminalSessionBackend] = [.inProcess, .labpty, .laband]
  private let identityOptions: [TerminalIdentity] = [.laban, .ghosttyCompat]
  private let cursorStyleOptions: [CursorSettings.Style] = CursorSettings.Style.allCases

  init(
    theme: ThemeMenuController,
    renderer: RendererModeMenuController,
    backend: TerminalBackendMenuController,
    onChangeFont: @escaping () -> Void
  ) {
    self.themeController = theme
    self.rendererController = renderer
    self.backendController = backend
    self.onChangeFont = onChangeFont
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Laban Settings"
    // Reused across openings; without this AppKit frees it on close and the
    // next ⌘, would message a dead window.
    window.isReleasedWhenClosed = false
    super.init(window: window)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(fontDidChange(_:)),
      name: FontAtlas.didChangeNotification,
      object: nil)
    window.delegate = self
    buildLayout()
    refresh()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Show centered and key. Re-reads live values first so it always opens in
  /// sync with whatever changed since last time (e.g. a system dark/light flip
  /// or a font change applied while the window was closed).
  func present() {
    refresh()
    if let window, !window.isVisible {
      window.center()
    }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowDidBecomeKey(_ notification: Notification) {
    refresh()
  }

  // MARK: Layout

  private func buildLayout() {
    guard let window, let content = window.contentView else { return }

    themePopUp.target = self
    themePopUp.action = #selector(themeChanged(_:))
    populateThemePopUp()

    followSystemCheckbox.target = self
    followSystemCheckbox.action = #selector(followSystemChanged(_:))

    fontLabel.lineBreakMode = .byTruncatingTail
    let changeFontButton = NSButton(
      title: "Change…", target: self, action: #selector(changeFontClicked(_:)))
    changeFontButton.bezelStyle = .rounded
    let fontRow = NSStackView(views: [fontLabel, changeFontButton])
    fontRow.orientation = .horizontal
    fontRow.spacing = 8
    fontRow.alignment = .firstBaseline

    rendererPopUp.target = self
    rendererPopUp.action = #selector(rendererChanged(_:))
    for option in rendererOptions {
      rendererPopUp.addItem(withTitle: rendererTitle(option))
      rendererPopUp.lastItem?.isEnabled = option.isAvailableOnCurrentOS
    }

    backendPopUp.target = self
    backendPopUp.action = #selector(backendChanged(_:))
    for option in backendOptions {
      backendPopUp.addItem(withTitle: backendTitle(option))
    }

    identityPopUp.target = self
    identityPopUp.action = #selector(identityChanged(_:))
    for option in identityOptions {
      identityPopUp.addItem(withTitle: identityTitle(option))
    }
    identityPopUp.toolTip =
      "What new sessions report as TERM_PROGRAM. Some programs only enable "
      + "features like OSC 9;4 progress bars for terminals they recognize; "
      + "the ghostty option claims that identity for compatibility."

    restoreCheckbox.target = self
    restoreCheckbox.action = #selector(restoreChanged(_:))

    cursorStylePopUp.target = self
    cursorStylePopUp.action = #selector(cursorStyleChanged(_:))
    for option in cursorStyleOptions {
      cursorStylePopUp.addItem(withTitle: cursorStyleTitle(option))
    }

    blinkCheckbox.target = self
    blinkCheckbox.action = #selector(blinkChanged(_:))

    let grid = NSGridView(views: [
      [makeLabel("Theme:"), themePopUp],
      [NSGridCell.emptyContentView, followSystemCheckbox],
      [makeLabel("Font:"), fontRow],
      [makeLabel("Cursor:"), cursorStylePopUp],
      [NSGridCell.emptyContentView, blinkCheckbox],
      [makeLabel("Renderer:"), rendererPopUp],
      [makeLabel("Sessions:"), backendPopUp],
      [NSGridCell.emptyContentView, restoreCheckbox],
      [makeLabel("Identity:"), identityPopUp],
    ])
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.columnSpacing = 10
    grid.rowSpacing = 14
    content.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: grid.trailingAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
    ])
    window.layoutIfNeeded()
    let fitting = grid.fittingSize
    window.setContentSize(NSSize(width: fitting.width + 40, height: fitting.height + 40))
  }

  private func populateThemePopUp() {
    themeRowIndices.removeAll()
    let themes = themeController.orderedThemes
    for (i, theme) in themes.enumerated() {
      themePopUp.addItem(withTitle: theme.name)
      themeRowIndices.append(i)
      // Separator between the last dark theme and the first light theme, so the
      // popup keeps the same two-group shape the menu showed.
      if theme.isDark, i + 1 < themes.count, !themes[i + 1].isDark {
        themePopUp.menu?.addItem(.separator())
        themeRowIndices.append(-1)
      }
    }
  }

  private func makeLabel(_ text: String) -> NSTextField {
    NSTextField(labelWithString: text)
  }

  // MARK: Live values

  private func refresh() {
    let current = themeController.currentThemeName
    if let row = themeRowIndices.firstIndex(where: {
      $0 >= 0 && themeController.orderedThemes[$0].name == current
    }) {
      themePopUp.selectItem(at: row)
    }
    followSystemCheckbox.state = themeController.followsSystemAppearance ? .on : .off
    fontLabel.stringValue = currentFontDisplayName()
    if let row = rendererOptions.firstIndex(of: rendererController.currentSelection) {
      rendererPopUp.selectItem(at: row)
    }
    if let row = backendOptions.firstIndex(of: backendController.currentSelection) {
      backendPopUp.selectItem(at: row)
    }
    restoreCheckbox.state = RestoreOnLaunchSettings.isEnabled ? .on : .off
    if let row = identityOptions.firstIndex(of: TerminalIdentitySettings.identity()) {
      identityPopUp.selectItem(at: row)
    }
    if let row = cursorStyleOptions.firstIndex(of: CursorSettings.style) {
      cursorStylePopUp.selectItem(at: row)
    }
    blinkCheckbox.state = CursorSettings.blinkEnabled ? .on : .off
  }

  // MARK: Actions

  @objc private func themeChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < themeRowIndices.count else { return }
    let themeIndex = themeRowIndices[row]
    guard themeIndex >= 0 else { return }
    themeController.applyTheme(at: themeIndex)
    // Picking a theme turns following the system off; reflect that here.
    refresh()
  }

  @objc private func followSystemChanged(_ sender: NSButton) {
    themeController.setFollowsSystem(sender.state == .on)
    refresh()
  }

  @objc private func changeFontClicked(_ sender: Any?) {
    onChangeFont()
  }

  @objc private func fontDidChange(_ notification: Notification) {
    refresh()
  }

  @objc private func rendererChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < rendererOptions.count else { return }
    let option = rendererOptions[row]
    guard option.isAvailableOnCurrentOS else {
      refresh()
      return
    }
    rendererController.choose(option)
    refresh()
  }

  @objc private func backendChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < backendOptions.count else { return }
    backendController.choose(backendOptions[row])
    refresh()
  }

  @objc private func restoreChanged(_ sender: NSButton) {
    RestoreOnLaunchSettings.set(sender.state == .on)
  }

  @objc private func identityChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < identityOptions.count else { return }
    TerminalIdentitySettings.set(identityOptions[row])
  }

  @objc private func cursorStyleChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < cursorStyleOptions.count else { return }
    CursorSettings.setStyle(cursorStyleOptions[row])
  }

  @objc private func blinkChanged(_ sender: NSButton) {
    CursorSettings.setBlinkEnabled(sender.state == .on)
  }

  // MARK: Titles

  private func rendererTitle(_ selection: RendererSelection) -> String {
    switch selection {
    case .software:
      return "Software"
    case .classic:
      return "Classic (Metal)"
    case .gpuDriven:
      return selection.isAvailableOnCurrentOS
        ? "GPU-driven (Metal)" : "GPU-driven (requires macOS 26)"
    }
  }

  private func backendTitle(_ backend: TerminalSessionBackend) -> String {
    switch backend {
    case .inProcess:
      return "Local"
    case .labpty:
      return "Background"
    case .laband:
      return "Detached"
    }
  }

  private func identityTitle(_ identity: TerminalIdentity) -> String {
    switch identity {
    case .laban:
      return "Laban"
    case .ghosttyCompat:
      return "ghostty"
    }
  }

  private func cursorStyleTitle(_ style: CursorSettings.Style) -> String {
    switch style {
    case .block: return "Block"
    case .bar: return "Bar"
    case .underline: return "Underline"
    }
  }

  private func currentFontDisplayName() -> String {
    let name = UserDefaults.standard.string(forKey: FontAtlas.userFontKey) ?? "JetBrains Mono"
    let size = FontAtlas.persistedTerminalPointSize
    let displayName = NSFont(name: name, size: size)?.displayName ?? name
    return "\(displayName), \(String(format: "%.0f pt", size))"
  }
}
