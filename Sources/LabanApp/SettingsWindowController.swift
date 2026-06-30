import AppKit
import LabanCore
import LabanRenderer

/// The native Settings (⌘,) window. It surfaces the choices that used to live
/// in the View and Workspace menus — theme, font, renderer, session backend,
/// and restore-on-launch — as standard AppKit controls. Every control drives
/// the same menu-controller apply path, so there is a single source of truth
/// and flipping a setting here behaves exactly as the old menu item did.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
  private let themeController: ThemeMenuController
  private let rendererController: RendererModeMenuController
  private let backendController: TerminalBackendMenuController
  private let onChangeFont: () -> Void
  private let onTestNotification: () -> Void

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
  private let scrollModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let graphemeWidthPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let emojiRenderingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let vectorSubpixelLayoutPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let vectorSubpixelRField = NSTextField(frame: .zero)
  private let vectorSubpixelGField = NSTextField(frame: .zero)
  private let vectorSubpixelBField = NSTextField(frame: .zero)
  private let vectorSubpixelWidthField = NSTextField(frame: .zero)
  private let vectorSubpixelApplyButton = NSButton(title: "Apply", target: nil, action: nil)
  private let vectorTextWeightSlider = NSSlider(
    value: VectorTextWeightSettings.defaultWeight, minValue: 0, maxValue: 1,
    target: nil, action: nil)
  private let vectorTextWeightValueLabel = NSTextField(labelWithString: "")
  private let vectorSmoothScrollPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private var vectorSubpixelCustomGridRow: NSGridRow?
  private let optionAsMetaCheckbox = NSButton(
    checkboxWithTitle: "Option as Meta", target: nil, action: nil)
  private let needsActionNotificationsCheckbox = NSButton(
    checkboxWithTitle: "Notify when a tab needs action", target: nil, action: nil)
  private let completionNotificationsCheckbox = NSButton(
    checkboxWithTitle: "Notify when a task completes", target: nil, action: nil)
  private let passiveNotificationsCheckbox = NSButton(
    checkboxWithTitle: "Notify for passive tab attention", target: nil, action: nil)
  private let notificationSoundCheckbox = NSButton(
    checkboxWithTitle: "Play notification sound", target: nil, action: nil)
  private let testNotificationButton = NSButton(
    title: "Test Native Notification", target: nil, action: nil)
  private let blinkCheckbox = NSButton(
    checkboxWithTitle: "Blink cursor", target: nil, action: nil)

  /// Theme index (into `themeController.orderedThemes`) behind each popup row,
  /// or -1 for the dark/light separator. Maps a popup selection back to a theme.
  private var themeRowIndices: [Int] = []
  private let rendererOptions: [RendererSelection] = RendererSelection.allCases
  private let backendOptions: [TerminalSessionBackend] = [.inProcess, .labpty, .laband]
  private let identityOptions: [TerminalIdentity] = [.laban, .ghosttyCompat]
  private let cursorStyleOptions: [CursorSettings.Style] = CursorSettings.Style.allCases
  private let scrollModeOptions: [ScrollSettings.Mode] = ScrollSettings.Mode.allCases
  private let graphemeWidthOptions: [GraphemeWidthMode] = GraphemeWidthMode.allCases
  private let emojiRenderingOptions: [EmojiRenderingMode] = EmojiRenderingMode.allCases
  private let vectorSubpixelLayoutOptions: [VectorSubpixelLayoutPreset] =
    VectorSubpixelLayoutPreset.settingsCases
  private let vectorSmoothScrollOptions: [VectorSmoothScrollMode] =
    VectorSmoothScrollMode.allCases

  init(
    theme: ThemeMenuController,
    renderer: RendererModeMenuController,
    backend: TerminalBackendMenuController,
    onChangeFont: @escaping () -> Void,
    onTestNotification: @escaping () -> Void
  ) {
    self.themeController = theme
    self.rendererController = renderer
    self.backendController = backend
    self.onChangeFont = onChangeFont
    self.onTestNotification = onTestNotification
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
      backendPopUp.lastItem?.toolTip = backendTooltip(option)
    }
    backendPopUp.toolTip = "Where terminal sessions live. Applies to new sessions."

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

    scrollModePopUp.target = self
    scrollModePopUp.action = #selector(scrollModeChanged(_:))
    for option in scrollModeOptions {
      scrollModePopUp.addItem(withTitle: scrollModeTitle(option))
    }
    scrollModePopUp.toolTip =
      "How trackpad scrolling moves the scrollback. Pixel-smooth tracks the "
      + "finger continuously and settles on a whole line at rest; "
      + "line-quantized moves in whole lines only."

    graphemeWidthPopUp.target = self
    graphemeWidthPopUp.action = #selector(graphemeWidthChanged(_:))
    for option in graphemeWidthOptions {
      graphemeWidthPopUp.addItem(withTitle: graphemeWidthTitle(option))
    }
    graphemeWidthPopUp.toolTip =
      "How new sessions start measuring Unicode width (DEC mode 2027). Auto "
      + "starts off and lets programs opt in; prefer grapheme width starts on "
      + "so emoji and clusters line up immediately. A program can still toggle "
      + "it at runtime. Applies to new sessions."

    emojiRenderingPopUp.target = self
    emojiRenderingPopUp.action = #selector(emojiRenderingChanged(_:))
    for option in emojiRenderingOptions {
      emojiRenderingPopUp.addItem(withTitle: emojiRenderingTitle(option))
    }
    emojiRenderingPopUp.toolTip =
      "Color uses CoreText color/bitmap glyphs for emoji. Monochrome keeps the "
      + "legacy tinted glyph path for compatibility."

    vectorSubpixelLayoutPopUp.target = self
    vectorSubpixelLayoutPopUp.action = #selector(vectorSubpixelLayoutChanged(_:))
    for option in vectorSubpixelLayoutOptions {
      vectorSubpixelLayoutPopUp.addItem(withTitle: vectorSubpixelLayoutTitle(option))
    }
    vectorSubpixelLayoutPopUp.toolTip =
      "Grayscale is neutral. Calibrated uses measured overlapping RGB sample areas. "
      + "RGB subpixel uses a stronger RGB stripe layout for maximum horizontal text acuity."
    configureVectorSubpixelCustomControls()

    vectorSmoothScrollPopUp.target = self
    vectorSmoothScrollPopUp.action = #selector(vectorSmoothScrollModeChanged(_:))
    for option in vectorSmoothScrollOptions {
      vectorSmoothScrollPopUp.addItem(withTitle: vectorSmoothScrollTitle(option))
    }
    vectorSmoothScrollPopUp.toolTip =
      "Fluid slides one cached glyph mask to any fractional position (smoothest, "
      + "softens slightly while moving). Crisp rasterizes a mask per sub-pixel phase "
      + "(sharper subpixel-AA in motion, a touch more GPU work). Vector renderer only."

    optionAsMetaCheckbox.target = self
    optionAsMetaCheckbox.action = #selector(optionAsMetaChanged(_:))
    optionAsMetaCheckbox.toolTip =
      "When enabled, Option-modified keys are sent to the terminal as Alt/Meta "
      + "instead of being treated as native text input."

    needsActionNotificationsCheckbox.target = self
    needsActionNotificationsCheckbox.action = #selector(needsActionNotificationsChanged(_:))
    needsActionNotificationsCheckbox.toolTip =
      "Posts a macOS notification when a background tab is blocked on user input."

    completionNotificationsCheckbox.target = self
    completionNotificationsCheckbox.action = #selector(completionNotificationsChanged(_:))
    completionNotificationsCheckbox.toolTip =
      "Posts a macOS notification for informational completion notices."

    passiveNotificationsCheckbox.target = self
    passiveNotificationsCheckbox.action = #selector(passiveNotificationsChanged(_:))
    passiveNotificationsCheckbox.toolTip =
      "Posts a passive macOS notification for low-salience attention such as BEL."

    notificationSoundCheckbox.target = self
    notificationSoundCheckbox.action = #selector(notificationSoundChanged(_:))
    notificationSoundCheckbox.toolTip = "Adds the default macOS sound to posted notifications."

    testNotificationButton.target = self
    testNotificationButton.action = #selector(testNotificationClicked(_:))
    testNotificationButton.bezelStyle = .rounded
    testNotificationButton.toolTip =
      "Sends one native macOS notification through the same path as tab attention."

    let appearanceGrid = makeSettingsGrid([
      [makeLabel("Theme:"), themePopUp],
      [NSGridCell.emptyContentView, followSystemCheckbox],
      [makeLabel("Font:"), fontRow],
      [makeLabel("Cursor:"), cursorStylePopUp],
      [NSGridCell.emptyContentView, blinkCheckbox],
    ])
    let terminalGrid = makeSettingsGrid([
      [makeLabel("Scroll:"), scrollModePopUp],
      [makeLabel("Unicode width:"), graphemeWidthPopUp],
      [makeLabel("Sessions:"), backendPopUp],
      [NSGridCell.emptyContentView, restoreCheckbox],
      [makeLabel("Identity:"), identityPopUp],
      [NSGridCell.emptyContentView, optionAsMetaCheckbox],
    ])
    let renderingGrid = makeSettingsGrid([
      [makeLabel("Renderer:"), rendererPopUp],
      [makeLabel("Emoji rendering:"), emojiRenderingPopUp],
      [makeLabel("Vector text AA:"), vectorSubpixelLayoutPopUp],
      [makeLabel("Overlap:"), makeVectorSubpixelCustomRow()],
      [makeLabel("Text weight:"), makeVectorTextWeightRow()],
      [makeLabel("Smooth scroll:"), vectorSmoothScrollPopUp],
    ])
    vectorSubpixelCustomGridRow = renderingGrid.row(at: 3)
    let notificationsGrid = makeSettingsGrid([
      [makeLabel("Notifications:"), needsActionNotificationsCheckbox],
      [NSGridCell.emptyContentView, completionNotificationsCheckbox],
      [NSGridCell.emptyContentView, passiveNotificationsCheckbox],
      [NSGridCell.emptyContentView, notificationSoundCheckbox],
      [NSGridCell.emptyContentView, testNotificationButton],
    ])

    let tabs = NSTabView(frame: .zero)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.addTabViewItem(makeTabItem(label: "Appearance", grid: appearanceGrid))
    tabs.addTabViewItem(makeTabItem(label: "Terminal", grid: terminalGrid))
    tabs.addTabViewItem(makeTabItem(label: "Rendering", grid: renderingGrid))
    tabs.addTabViewItem(makeTabItem(label: "Notifications", grid: notificationsGrid))
    content.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 20),
    ])
    window.layoutIfNeeded()
    window.setContentSize(NSSize(width: 560, height: 300))
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

  private func makeSettingsGrid(_ rows: [[NSView]]) -> NSGridView {
    let grid = NSGridView(views: rows)
    grid.translatesAutoresizingMaskIntoConstraints = false
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .firstBaseline
    grid.columnSpacing = 10
    grid.rowSpacing = 14
    return grid
  }

  private func makeTabItem(label: String, grid: NSGridView) -> NSTabViewItem {
    let item = NSTabViewItem(identifier: label)
    item.label = label

    let view = NSView(frame: .zero)
    view.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
      view.trailingAnchor.constraint(greaterThanOrEqualTo: grid.trailingAnchor, constant: 12),
      view.bottomAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 12),
    ])
    item.view = view
    return item
  }

  private func makeSmallLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    return label
  }

  private func makeVectorTextWeightRow() -> NSStackView {
    vectorTextWeightSlider.isContinuous = true
    vectorTextWeightSlider.target = self
    vectorTextWeightSlider.action = #selector(vectorTextWeightChanged(_:))
    vectorTextWeightSlider.toolTip =
      "How much to thicken vector text (stem darkening). 0 = thin geometric outline; "
      + "1 = matched to the classic/CoreText weight. Applies live."
    vectorTextWeightSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
    vectorTextWeightValueLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let row = NSStackView(views: [
      makeSmallLabel("Thin"),
      vectorTextWeightSlider,
      makeSmallLabel("CoreText"),
      vectorTextWeightValueLabel,
    ])
    row.orientation = .horizontal
    row.spacing = 6
    return row
  }

  @objc private func vectorTextWeightChanged(_ sender: NSSlider) {
    VectorTextWeightSettings.setCurrent(sender.doubleValue)
    updateVectorTextWeightLabel()
  }

  private func updateVectorTextWeightLabel() {
    vectorTextWeightValueLabel.stringValue = String(
      format: "%.2f", VectorTextWeightSettings.current())
  }

  private func makeVectorSubpixelCustomRow() -> NSStackView {
    let row = NSStackView(views: [
      makeSmallLabel("R"),
      vectorSubpixelRField,
      makeSmallLabel("G"),
      vectorSubpixelGField,
      makeSmallLabel("B"),
      vectorSubpixelBField,
      makeSmallLabel("W"),
      vectorSubpixelWidthField,
      vectorSubpixelApplyButton,
    ])
    row.orientation = .horizontal
    row.spacing = 6
    row.alignment = .firstBaseline
    return row
  }

  private func configureVectorSubpixelCustomControls() {
    for field in vectorSubpixelFields {
      field.alignment = .right
      field.font = .monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular)
      field.target = self
      field.action = #selector(vectorSubpixelCustomFieldChanged(_:))
      field.delegate = self
      field.translatesAutoresizingMaskIntoConstraints = false
      field.widthAnchor.constraint(equalToConstant: 52).isActive = true
    }
    vectorSubpixelRField.toolTip = "Red channel sample-area center offset in device pixels."
    vectorSubpixelGField.toolTip = "Green channel sample-area center offset in device pixels."
    vectorSubpixelBField.toolTip = "Blue channel sample-area center offset in device pixels."
    vectorSubpixelWidthField.toolTip = "Width of each overlapping channel sample area in pixels."
    vectorSubpixelApplyButton.target = self
    vectorSubpixelApplyButton.action = #selector(vectorSubpixelCustomApplyClicked(_:))
    vectorSubpixelApplyButton.bezelStyle = .rounded
    vectorSubpixelApplyButton.toolTip = "Save these values as a custom vector text AA layout."
  }

  private var vectorSubpixelFields: [NSTextField] {
    [
      vectorSubpixelRField,
      vectorSubpixelGField,
      vectorSubpixelBField,
      vectorSubpixelWidthField,
    ]
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
    if let row = scrollModeOptions.firstIndex(of: ScrollSettings.mode) {
      scrollModePopUp.selectItem(at: row)
    }
    if let row = graphemeWidthOptions.firstIndex(of: GraphemeWidthSettings.current()) {
      graphemeWidthPopUp.selectItem(at: row)
    }
    if let row = emojiRenderingOptions.firstIndex(of: EmojiRenderingSettings.current()) {
      emojiRenderingPopUp.selectItem(at: row)
    }
    let vectorLayout = VectorSubpixelLayout.persisted()
    if let row = vectorSubpixelLayoutOptions.firstIndex(of: VectorSubpixelLayout.persistedPreset())
    {
      vectorSubpixelLayoutPopUp.selectItem(at: row)
    }
    refreshVectorSubpixelCustomFields(vectorLayout)
    vectorSubpixelCustomGridRow?.isHidden =
      VectorSubpixelLayout.persistedPreset() != .customOverlap
    vectorTextWeightSlider.doubleValue = VectorTextWeightSettings.current()
    updateVectorTextWeightLabel()
    if let row = vectorSmoothScrollOptions.firstIndex(of: VectorSmoothScrollSettings.current()) {
      vectorSmoothScrollPopUp.selectItem(at: row)
    }
    optionAsMetaCheckbox.state = OptionKeySettings.current() ? .on : .off
    needsActionNotificationsCheckbox.state =
      AttentionNotificationSettings.needsActionEnabled ? .on : .off
    completionNotificationsCheckbox.state =
      AttentionNotificationSettings.completionEnabled ? .on : .off
    passiveNotificationsCheckbox.state =
      AttentionNotificationSettings.passiveEnabled ? .on : .off
    notificationSoundCheckbox.state =
      AttentionNotificationSettings.soundEnabled ? .on : .off
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

  @objc private func scrollModeChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < scrollModeOptions.count else { return }
    ScrollSettings.setMode(scrollModeOptions[row])
  }

  @objc private func graphemeWidthChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < graphemeWidthOptions.count else { return }
    GraphemeWidthSettings.set(graphemeWidthOptions[row])
  }

  @objc private func emojiRenderingChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < emojiRenderingOptions.count else { return }
    EmojiRenderingSettings.set(emojiRenderingOptions[row])
  }

  @objc private func vectorSubpixelLayoutChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < vectorSubpixelLayoutOptions.count else { return }
    let option = vectorSubpixelLayoutOptions[row]
    if option == .customOverlap {
      applyCustomVectorSubpixelLayout()
    } else {
      VectorSubpixelLayout.setPersistedPreset(option)
      refresh()
    }
  }

  @objc private func vectorSmoothScrollModeChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < vectorSmoothScrollOptions.count else { return }
    VectorSmoothScrollSettings.setCurrent(vectorSmoothScrollOptions[row])
    refresh()
  }

  @objc private func vectorSubpixelCustomFieldChanged(_ sender: NSTextField) {
    applyCustomVectorSubpixelLayout()
  }

  @objc private func vectorSubpixelCustomApplyClicked(_ sender: NSButton) {
    applyCustomVectorSubpixelLayout()
  }

  @objc private func optionAsMetaChanged(_ sender: NSButton) {
    OptionKeySettings.set(sender.state == .on)
  }

  @objc private func needsActionNotificationsChanged(_ sender: NSButton) {
    AttentionNotificationSettings.setEnabled(sender.state == .on, for: .needsAction)
  }

  @objc private func completionNotificationsChanged(_ sender: NSButton) {
    AttentionNotificationSettings.setEnabled(sender.state == .on, for: .completion)
  }

  @objc private func passiveNotificationsChanged(_ sender: NSButton) {
    AttentionNotificationSettings.setEnabled(sender.state == .on, for: .passive)
  }

  @objc private func notificationSoundChanged(_ sender: NSButton) {
    AttentionNotificationSettings.setSoundEnabled(sender.state == .on)
  }

  @objc private func testNotificationClicked(_ sender: NSButton) {
    onTestNotification()
  }

  @objc private func blinkChanged(_ sender: NSButton) {
    CursorSettings.setBlinkEnabled(sender.state == .on)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard let field = obj.object as? NSTextField,
      vectorSubpixelFields.contains(where: { $0 === field })
    else { return }
    applyCustomVectorSubpixelLayout()
  }

  private func applyCustomVectorSubpixelLayout() {
    guard
      let r = fieldFloat(vectorSubpixelRField),
      let g = fieldFloat(vectorSubpixelGField),
      let b = fieldFloat(vectorSubpixelBField),
      let width = fieldFloat(vectorSubpixelWidthField)
    else {
      NSSound.beep()
      refreshVectorSubpixelCustomFields(VectorSubpixelLayout.persisted())
      return
    }

    let resolvedWidth = min(max(width, 0.05), 1.50)
    let layout = VectorSubpixelLayout.custom(
      name: "customOverlap",
      areas: VectorSubpixelAreas.horizontalOverlap(
        centerOffsets: SIMD3<Float>(r, g, b),
        width: resolvedWidth))
    VectorSubpixelLayout.setPersisted(layout)
    refresh()
  }

  private func fieldFloat(_ field: NSTextField) -> Float? {
    let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty, let value = Float(raw), value.isFinite else { return nil }
    return value
  }

  private func refreshVectorSubpixelCustomFields(_ layout: VectorSubpixelLayout) {
    vectorSubpixelRField.stringValue = formatSubpixelValue(layout.offsets.x)
    vectorSubpixelGField.stringValue = formatSubpixelValue(layout.offsets.y)
    vectorSubpixelBField.stringValue = formatSubpixelValue(layout.offsets.z)
    vectorSubpixelWidthField.stringValue = formatSubpixelValue(layout.areas.averageWidthX)
  }

  private func formatSubpixelValue(_ value: Float) -> String {
    String(format: "%.2f", value)
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
    case .vectorGlyph:
      return "Vector Glyph"
    case .slugGlyph:
      return "Slug Glyph"
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

  private func backendTooltip(_ backend: TerminalSessionBackend) -> String {
    switch backend {
    case .inProcess:
      return "Sessions run inside the Laban process. Simplest, "
        + "but every session ends when Laban quits."
    case .labpty:
      return "PTYs live in the labpty daemon: sessions keep running "
        + "across Laban relaunches and upgrades, and reattach on launch."
    case .laband:
      return "Sessions run in the laband daemon, which can serve multiple "
        + "clients and keeps sessions alive while no window is attached."
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

  private func scrollModeTitle(_ mode: ScrollSettings.Mode) -> String {
    switch mode {
    case .pixelSmooth: return "Pixel-smooth"
    case .lineQuantized: return "Line-quantized"
    }
  }

  private func graphemeWidthTitle(_ mode: GraphemeWidthMode) -> String {
    switch mode {
    case .auto: return "Auto (recommended)"
    case .preferGrapheme: return "Prefer grapheme width"
    }
  }

  private func emojiRenderingTitle(_ mode: EmojiRenderingMode) -> String {
    switch mode {
    case .monochrome: return "Monochrome"
    case .color: return "Color"
    }
  }

  private func vectorSubpixelLayoutTitle(_ preset: VectorSubpixelLayoutPreset) -> String {
    switch preset {
    case .grayscale: return "Grayscale"
    case .calibratedRGB: return "Calibrated"
    case .customOverlap: return "Custom overlap"
    case .rgbStripe: return "RGB subpixel"
    case .bgrStripe: return "BGR subpixel"
    }
  }

  private func vectorSmoothScrollTitle(_ mode: VectorSmoothScrollMode) -> String {
    switch mode {
    case .fluid: return "Fluid"
    case .perPhase: return "Crisp"
    }
  }

  private func currentFontDisplayName() -> String {
    let name = UserDefaults.standard.string(forKey: FontAtlas.userFontKey) ?? "JetBrains Mono"
    let size = FontAtlas.persistedTerminalPointSize
    let displayName = NSFont(name: name, size: size)?.displayName ?? name
    return "\(displayName), \(String(format: "%.0f pt", size))"
  }
}
