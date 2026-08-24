import AppKit
import LabanControl
import LabanCore
import LabanRenderer
import UniformTypeIdentifiers

/// The native Settings (⌘,) window. It surfaces the choices that used to live
/// in the View and Workspace menus — theme, font, renderer, session backend,
/// and restore-on-launch — as standard AppKit controls. Every control drives
/// the same menu-controller apply path, so there is a single source of truth
/// and flipping a setting here behaves exactly as the old menu item did.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
  typealias BackgroundImagePicker =
    (NSWindow?, @escaping (URL?) -> Void) -> Void
  typealias BackgroundImageErrorPresenter =
    (NSWindow?, String, String) -> Void
  typealias ThemeFilePicker =
    (NSWindow?, @escaping (URL?) -> Void) -> Void
  typealias ThemeImportErrorPresenter =
    (NSWindow?, String, String) -> Void

  static let windowIdentifier = NSUserInterfaceItemIdentifier("LabanSettings")
  private let themeController: ThemeMenuController
  private let rendererController: RendererModeMenuController
  private let backendController: TerminalBackendMenuController
  private let onChangeFont: () -> Void
  private let onChangeCJKFont: () -> Void
  private let onTestNotification: () -> Void
  private let focusStatusSnapshot: () -> NativeNotificationFocusSnapshot
  private let onCheckFocusStatus: (@escaping (NativeNotificationFocusSnapshot) -> Void) -> Void
  private let onControlServerEnabledChanged: (Bool) -> Void
  private let transparencyDefaults: UserDefaults
  private let transparencyNotificationCenter: NotificationCenter
  private let transparencyPersistence: TerminalTransparencyLivePersistence
  private let backgroundImageStore: TerminalBackgroundImageStore
  private let backgroundImagePicker: BackgroundImagePicker
  private let backgroundImageErrorPresenter: BackgroundImageErrorPresenter
  private let themeStore: TerminalThemeStore
  private let themeFilePicker: ThemeFilePicker
  private let themeImportErrorPresenter: ThemeImportErrorPresenter

  private let themePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  /// Per-appearance selectors shown instead of `themePopUp` while Follow
  /// System Appearance is on, so both pinned variants are visible at once.
  private let darkThemePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let lightThemePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let themeImportButton = NSButton(
    title: L10n.tr("Import Theme…"), target: nil, action: nil)
  private let themeRemoveButton = NSButton(
    title: L10n.tr("Remove Theme"), target: nil, action: nil)
  private let followSystemCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Follow system appearance"), target: nil, action: nil)
  private let backgroundPresetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let backgroundSourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let backgroundImageStatusLabel = NSTextField(labelWithString: "")
  private let backgroundImageChooseButton = NSButton(
    title: L10n.tr("Choose…"), target: nil, action: nil)
  private let backgroundImageRemoveButton = NSButton(
    title: L10n.tr("Remove Image"), target: nil, action: nil)
  private let backgroundImageScalingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let backgroundOpacitySlider = NSSlider(
    value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
  private let backgroundOpacityValueLabel = NSTextField(labelWithString: "100%")
  private let backgroundBlurSlider = NSSlider(
    value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
  private let backgroundBlurValueLabel = NSTextField(labelWithString: "0%")
  private let explicitCellBackgroundOpacityCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Apply opacity to colored cell backgrounds"),
    target: nil,
    action: nil)
  private let fontLabel = NSTextField(labelWithString: "")
  private let cjkFontPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let cjkFontStatusLabel = NSTextField(labelWithString: "")
  private let rendererPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let backendPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let identityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let restoreCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Restore tabs on launch"), target: nil, action: nil)
  private let controlServerCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Enable agent control server"), target: nil, action: nil)
  private let agentAttachedSessionCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Auto-attach agents at launch without approval (advanced)"),
    target: nil,
    action: nil)
  private let autoUpdateCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Automatically check for updates"),
    target: nil,
    action: nil)
  private let cursorStylePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let scrollModePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let graphemeWidthPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let emojiRenderingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let vectorSubpixelLayoutPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  private let vectorSubpixelRField = NSTextField(frame: .zero)
  private let vectorSubpixelGField = NSTextField(frame: .zero)
  private let vectorSubpixelBField = NSTextField(frame: .zero)
  private let vectorSubpixelWidthField = NSTextField(frame: .zero)
  private let vectorSubpixelApplyButton = NSButton(
    title: L10n.tr("Apply"), target: nil, action: nil)
  private let vectorTextWeightSlider = NSSlider(
    value: VectorTextWeightSettings.defaultWeight, minValue: 0,
    maxValue: VectorTextWeightSettings.maxWeight,
    target: nil, action: nil)
  private let vectorTextWeightValueLabel = NSTextField(labelWithString: "")
  private let vectorSmoothScrollPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  // Held as properties so refresh() can dim them when the active renderer does
  // not consume vector-specific settings. The controls themselves get disabled
  // too; dimming the label keeps the whole row reading as inactive.
  private let vectorTextLabel = NSTextField(labelWithString: L10n.tr("Vector text AA:"))
  private let vectorOverlapLabel = NSTextField(labelWithString: L10n.tr("Overlap:"))
  private let vectorTextWeightLabel = NSTextField(labelWithString: L10n.tr("Text weight:"))
  private let vectorSmoothScrollLabel = NSTextField(labelWithString: L10n.tr("Smooth scroll:"))
  private let hoverPreviewCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Sidebar hover preview"), target: nil, action: nil)
  private var vectorSubpixelCustomGridRow: NSGridRow?
  private let optionAsMetaCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Option as Meta"), target: nil, action: nil)
  private let needsActionNotificationsCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Notify when a tab needs action"), target: nil, action: nil)
  private let completionNotificationsCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Notify when a task completes"), target: nil, action: nil)
  private let passiveNotificationsCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Notify for passive tab attention"), target: nil, action: nil)
  private let notificationSoundCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Play notification sound"), target: nil, action: nil)
  private let testNotificationButton = NSButton(
    title: L10n.tr("Test Native Notification"), target: nil, action: nil)
  private let focusTroubleshootingStatusLabel = NSTextField(wrappingLabelWithString: "")
  private let focusTroubleshootingButton = NSButton(
    title: L10n.tr("Check Focus Blocking…"), target: nil, action: nil)
  private let openFocusSettingsButton = NSButton(
    title: L10n.tr("Open Settings"), target: nil, action: nil)
  private var focusCheckInFlight = false
  private var focusSettingsDestination: NativeFocusSettingsDestination?
  private let blinkCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Blink cursor"), target: nil, action: nil)
  private let profileRecorderCheckbox = NSButton(
    checkboxWithTitle: L10n.tr("Enable CPU profile capture"), target: nil, action: nil)
  private let profileRecorderHelpLabel = NSTextField(wrappingLabelWithString: "")
  private let approvalStore = ControlAttachApprovalStore(
    signer: ControlAttachApprovalStore.defaultSigner())
  private let approvalsStackView = NSStackView()
  private let approvalsRefreshButton = NSButton(
    title: L10n.tr("Refresh"), target: nil, action: nil)

  /// Theme index (into `themeController.orderedThemes`) behind each popup row,
  /// or -1 for the dark/light separator. Maps a popup selection back to a theme.
  private var themeRowIndices: [Int] = []
  /// Same mapping for the per-appearance popups; each lists only themes of its
  /// own brightness, so no separator rows exist here.
  private var darkThemeRowIndices: [Int] = []
  private var lightThemeRowIndices: [Int] = []
  /// Appearance-grid rows for the single theme popup and the two per-appearance
  /// popups; exactly one shape is visible depending on Follow System Appearance.
  private var singleThemeGridRow: NSGridRow?
  private var darkThemeGridRow: NSGridRow?
  private var lightThemeGridRow: NSGridRow?
  private let rendererOptions: [RendererSelection] = RendererSelection.selectableCases
  private let backendOptions: [TerminalSessionBackend] = [.inProcess, .labpty, .laband]
  private let identityOptions: [TerminalIdentity] = [.laban, .ghosttyCompat]
  private let cursorStyleOptions: [CursorSettings.Style] = CursorSettings.Style.allCases
  private let scrollModeOptions: [ScrollSettings.Mode] = ScrollSettings.Mode.allCases
  private let graphemeWidthOptions: [GraphemeWidthMode] = GraphemeWidthMode.allCases
  private let emojiRenderingOptions: [EmojiRenderingMode] = EmojiRenderingMode.allCases
  private let cjkFontOptions: [CJKFontPreference] = CJKFontPreference.presetCases
  private let vectorSubpixelLayoutOptions: [VectorSubpixelLayoutPreset] =
    VectorSubpixelLayoutPreset.settingsCases
  private let vectorSmoothScrollOptions: [VectorSmoothScrollMode] =
    VectorSmoothScrollMode.allCases
  private let backgroundPresetOptions: [TerminalTransparencyPreset] =
    TerminalTransparencyPreset.allCases
  private let backgroundSourceOptions: [TerminalBackdropStyle] =
    TerminalBackdropStyle.allCases
  private let backgroundImageScalingOptions: [TerminalBackgroundImageScaling] =
    TerminalBackgroundImageScaling.allCases

  init(
    theme: ThemeMenuController,
    renderer: RendererModeMenuController,
    backend: TerminalBackendMenuController,
    onChangeFont: @escaping () -> Void,
    onChangeCJKFont: @escaping () -> Void,
    onTestNotification: @escaping () -> Void,
    focusStatusSnapshot: @escaping () -> NativeNotificationFocusSnapshot,
    onCheckFocusStatus:
      @escaping (@escaping (NativeNotificationFocusSnapshot) -> Void) -> Void,
    onControlServerEnabledChanged: @escaping (Bool) -> Void = { _ in },
    transparencyDefaults: UserDefaults = .standard,
    transparencyNotificationCenter: NotificationCenter = .default,
    backgroundImageStore: TerminalBackgroundImageStore? = nil,
    backgroundImagePicker: BackgroundImagePicker? = nil,
    backgroundImageErrorPresenter: BackgroundImageErrorPresenter? = nil,
    themeStore: TerminalThemeStore? = nil,
    themeFilePicker: ThemeFilePicker? = nil,
    themeImportErrorPresenter: ThemeImportErrorPresenter? = nil
  ) {
    self.themeController = theme
    self.rendererController = renderer
    self.backendController = backend
    self.onChangeFont = onChangeFont
    self.onChangeCJKFont = onChangeCJKFont
    self.onTestNotification = onTestNotification
    self.focusStatusSnapshot = focusStatusSnapshot
    self.onCheckFocusStatus = onCheckFocusStatus
    self.onControlServerEnabledChanged = onControlServerEnabledChanged
    self.transparencyDefaults = transparencyDefaults
    self.transparencyNotificationCenter = transparencyNotificationCenter
    self.transparencyPersistence = TerminalTransparencyLivePersistence(
      defaults: transparencyDefaults,
      notificationCenter: transparencyNotificationCenter)
    self.backgroundImageStore =
      backgroundImageStore
      ?? TerminalBackgroundImageStore(
        defaults: transparencyDefaults,
        notificationCenter: transparencyNotificationCenter)
    self.backgroundImagePicker = backgroundImagePicker ?? Self.presentBackgroundImagePicker
    self.backgroundImageErrorPresenter =
      backgroundImageErrorPresenter ?? Self.presentBackgroundImageImportError
    self.themeStore = themeStore ?? TerminalThemeStore()
    self.themeFilePicker = themeFilePicker ?? Self.presentThemeFilePicker
    self.themeImportErrorPresenter =
      themeImportErrorPresenter ?? Self.presentThemeImportError
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 10),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.identifier = Self.windowIdentifier
    window.title = L10n.tr("Laban Settings")
    // Reused across openings; without this AppKit frees it on close and the
    // next ⌘, would message a dead window.
    window.isReleasedWhenClosed = false
    super.init(window: window)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(fontDidChange(_:)),
      name: FontAtlas.didChangeNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(cjkFontSettingsDidChange(_:)),
      name: CJKFontSettings.didChangeNotification,
      object: nil)
    transparencyNotificationCenter.addObserver(
      self,
      selector: #selector(transparencySettingsDidChange(_:)),
      name: TerminalTransparencySettings.didChangeNotification,
      object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(themeStoreDidChange(_:)),
      name: TerminalThemeStore.didChangeNotification,
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

  func windowWillClose(_ notification: Notification) {
    transparencyPersistence.flush()
  }

  // MARK: Layout

  private func buildLayout() {
    guard let window, let content = window.contentView else { return }

    themePopUp.target = self
    themePopUp.action = #selector(themeChanged(_:))
    darkThemePopUp.target = self
    darkThemePopUp.action = #selector(darkThemeChanged(_:))
    lightThemePopUp.target = self
    lightThemePopUp.action = #selector(lightThemeChanged(_:))
    populateThemePopUp()

    themeImportButton.target = self
    themeImportButton.action = #selector(importThemeClicked(_:))
    themeImportButton.bezelStyle = .rounded
    themeImportButton.toolTip = L10n.tr(
      "Import a Laban theme file (.laban-theme.json). See schemas/theme/examples/ for reference themes."
    )
    themeImportButton.setAccessibilityLabel(L10n.tr("Import Theme"))

    themeRemoveButton.target = self
    themeRemoveButton.action = #selector(removeThemeClicked(_:))
    themeRemoveButton.bezelStyle = .rounded
    themeRemoveButton.toolTip = L10n.tr(
      "Remove the selected imported theme. Bundled themes cannot be removed.")
    themeRemoveButton.setAccessibilityLabel(L10n.tr("Remove Theme"))

    followSystemCheckbox.target = self
    followSystemCheckbox.action = #selector(followSystemChanged(_:))

    backgroundPresetPopUp.target = self
    backgroundPresetPopUp.action = #selector(backgroundPresetChanged(_:))
    for preset in backgroundPresetOptions {
      backgroundPresetPopUp.addItem(withTitle: backgroundPresetTitle(preset))
    }
    backgroundPresetPopUp.toolTip = L10n.tr(
      "Choose an exact background preset. Changing an individual background control shows Custom."
    )
    backgroundPresetPopUp.setAccessibilityLabel(L10n.tr("Preset:"))

    backgroundSourcePopUp.target = self
    backgroundSourcePopUp.action = #selector(backgroundSourceChanged(_:))
    for source in backgroundSourceOptions {
      backgroundSourcePopUp.addItem(withTitle: backgroundSourceTitle(source))
    }
    backgroundSourcePopUp.toolTip = L10n.tr(
      "Choose direct transparency, a blurred system backdrop, or a managed local image behind the terminal."
    )
    backgroundSourcePopUp.setAccessibilityLabel(L10n.tr("Background source:"))

    backgroundImageStatusLabel.lineBreakMode = .byTruncatingMiddle
    backgroundImageStatusLabel.usesSingleLineMode = true
    backgroundImageStatusLabel.setAccessibilityLabel(L10n.tr("Image"))

    backgroundImageChooseButton.target = self
    backgroundImageChooseButton.action = #selector(chooseBackgroundImageClicked(_:))
    backgroundImageChooseButton.bezelStyle = .rounded
    backgroundImageChooseButton.toolTip = L10n.tr(
      "Import a still image into Laban’s private background-image storage."
    )
    backgroundImageChooseButton.setAccessibilityLabel(L10n.tr("Choose Image"))

    backgroundImageRemoveButton.target = self
    backgroundImageRemoveButton.action = #selector(removeBackgroundImageClicked(_:))
    backgroundImageRemoveButton.bezelStyle = .rounded
    backgroundImageRemoveButton.toolTip = L10n.tr(
      "Delete the managed background image and select None."
    )
    backgroundImageRemoveButton.setAccessibilityLabel(L10n.tr("Remove Image"))

    backgroundImageScalingPopUp.target = self
    backgroundImageScalingPopUp.action = #selector(backgroundImageScalingChanged(_:))
    for scaling in backgroundImageScalingOptions {
      backgroundImageScalingPopUp.addItem(withTitle: backgroundImageScalingTitle(scaling))
    }
    backgroundImageScalingPopUp.toolTip = L10n.tr(
      "Choose how the managed image fills the terminal area."
    )
    backgroundImageScalingPopUp.setAccessibilityLabel(L10n.tr("Image scaling:"))

    let backgroundImageActionsRow = NSStackView(views: [
      backgroundImageChooseButton,
      backgroundImageRemoveButton,
    ])
    backgroundImageActionsRow.orientation = .horizontal
    backgroundImageActionsRow.spacing = 8
    backgroundImageActionsRow.alignment = .firstBaseline

    backgroundOpacitySlider.isContinuous = true
    backgroundOpacitySlider.numberOfTickMarks = 11
    backgroundOpacitySlider.allowsTickMarkValuesOnly = false
    backgroundOpacitySlider.target = self
    backgroundOpacitySlider.action = #selector(backgroundOpacityChanged(_:))
    backgroundOpacitySlider.toolTip = L10n.tr(
      "Choose how much of the themed terminal background covers the selected source. The entire sidebar remains opaque; text, the cursor, and selections remain fully visible. 100% is fully opaque."
    )
    backgroundOpacitySlider.setAccessibilityLabel(L10n.tr("Background opacity"))
    backgroundOpacitySlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
    backgroundOpacityValueLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize,
      weight: .regular)
    backgroundOpacityValueLabel.alignment = .right
    backgroundOpacityValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

    backgroundBlurSlider.isContinuous = true
    backgroundBlurSlider.numberOfTickMarks = 11
    backgroundBlurSlider.allowsTickMarkValuesOnly = false
    backgroundBlurSlider.target = self
    backgroundBlurSlider.action = #selector(backgroundBlurChanged(_:))
    backgroundBlurSlider.toolTip = L10n.tr(
      "Choose how strongly macOS blurs content behind the terminal. 0% shows the content directly; 100% applies the strongest available window blur."
    )
    backgroundBlurSlider.setAccessibilityLabel(L10n.tr("Background blur"))
    backgroundBlurSlider.widthAnchor.constraint(equalToConstant: 190).isActive = true
    backgroundBlurValueLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize,
      weight: .regular)
    backgroundBlurValueLabel.alignment = .right
    backgroundBlurValueLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

    explicitCellBackgroundOpacityCheckbox.target = self
    explicitCellBackgroundOpacityCheckbox.action =
      #selector(explicitCellBackgroundOpacityChanged(_:))
    explicitCellBackgroundOpacityCheckbox.toolTip = L10n.tr(
      "Also applies the selected opacity to background colors set by terminal programs, including inverse video."
    )

    let backgroundOpacityRow = NSStackView(views: [
      backgroundOpacitySlider,
      backgroundOpacityValueLabel,
    ])
    backgroundOpacityRow.orientation = .horizontal
    backgroundOpacityRow.spacing = 8
    backgroundOpacityRow.alignment = .firstBaseline

    let backgroundBlurRow = NSStackView(views: [
      backgroundBlurSlider,
      backgroundBlurValueLabel,
    ])
    backgroundBlurRow.orientation = .horizontal
    backgroundBlurRow.spacing = 8
    backgroundBlurRow.alignment = .firstBaseline

    fontLabel.lineBreakMode = .byTruncatingTail
    let changeFontButton = NSButton(
      title: L10n.tr("Change…"), target: self, action: #selector(changeFontClicked(_:)))
    changeFontButton.bezelStyle = .rounded
    let fontRow = NSStackView(views: [fontLabel, changeFontButton])
    fontRow.orientation = .horizontal
    fontRow.spacing = 8
    fontRow.alignment = .firstBaseline

    cjkFontPopUp.target = self
    cjkFontPopUp.action = #selector(cjkFontChanged(_:))
    for option in cjkFontOptions {
      cjkFontPopUp.addItem(withTitle: option.displayName)
    }
    cjkFontPopUp.toolTip =
      "Quick picks for common CJK fallback fonts. Use Choose… for any installed "
      + "CJK font."

    let changeCJKFontButton = NSButton(
      title: L10n.tr("Choose…"), target: self, action: #selector(changeCJKFontClicked(_:)))
    changeCJKFontButton.bezelStyle = .rounded
    changeCJKFontButton.toolTip =
      "Pick any installed font with Hanzi coverage. Size follows the primary "
      + "terminal font; fonts without a usable 中 glyph are rejected."
    let cjkFontRow = NSStackView(views: [cjkFontPopUp, changeCJKFontButton])
    cjkFontRow.orientation = .horizontal
    cjkFontRow.spacing = 8
    cjkFontRow.alignment = .firstBaseline

    cjkFontStatusLabel.lineBreakMode = .byTruncatingTail
    cjkFontStatusLabel.usesSingleLineMode = true
    cjkFontStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    cjkFontStatusLabel.textColor = .secondaryLabelColor

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
    backendPopUp.toolTip =
      "Where terminal sessions live. Takes effect on the next launch — tabs "
      + "opened in this launch keep the current backend, so restart Laban to "
      + "switch."

    identityPopUp.target = self
    identityPopUp.action = #selector(identityChanged(_:))
    for option in identityOptions {
      identityPopUp.addItem(withTitle: identityTitle(option))
    }
    identityPopUp.toolTip =
      "What new sessions report as TERM_PROGRAM. Some programs only enable "
      + "features like OSC 9;4 progress bars for terminals they recognize; "
      + "the ghostty option claims that identity for compatibility. Applies "
      + "to new sessions; a running program isn't affected until it restarts, "
      + "though a fresh program launched in an idle tab (e.g. starting Claude "
      + "Code at the prompt) picks it up."

    restoreCheckbox.target = self
    restoreCheckbox.action = #selector(restoreChanged(_:))
    restoreCheckbox.toolTip =
      "Reopens the tabs that were open when Laban last quit. Takes effect on "
      + "the next launch — toggle it before quitting to control whether your "
      + "tabs return."

    controlServerCheckbox.target = self
    controlServerCheckbox.action = #selector(controlServerChanged(_:))
    controlServerCheckbox.toolTip =
      "When off, the agent control server never starts: no control.json, no "
      + "session credential injection, and no remote observation surface — "
      + "even if LABAN_CONTROL_SERVER=1 is set."

    agentAttachedSessionCheckbox.target = self
    agentAttachedSessionCheckbox.action = #selector(agentAttachedSessionChanged(_:))
    agentAttachedSessionCheckbox.toolTip =
      "Advanced / dev / CI. When on, the first tab at launch injects a one-time "
      + "C14 attach bootstrap so an agent started with `laban agent run` can "
      + "attach with no approval dialog. Most users do not need this: an agent "
      + "already running in any tab can attach on demand through lazy attach "
      + "(you approve it once). Requires the agent control server to be on."

    autoUpdateCheckbox.target = self
    autoUpdateCheckbox.action = #selector(autoUpdateChanged(_:))
    autoUpdateCheckbox.toolTip =
      "Release builds check the update feed in the background and offer to "
      + "install new versions. Only available in released builds; local dev "
      + "builds never check."

    cursorStylePopUp.target = self
    cursorStylePopUp.action = #selector(cursorStyleChanged(_:))
    for option in cursorStyleOptions {
      cursorStylePopUp.addItem(withTitle: cursorStyleTitle(option))
    }

    blinkCheckbox.target = self
    blinkCheckbox.action = #selector(blinkChanged(_:))

    profileRecorderCheckbox.target = self
    profileRecorderCheckbox.action = #selector(profileRecorderChanged(_:))
    profileRecorderCheckbox.toolTip =
      "Allows Debug-menu CPU captures immediately. Sampling runs only during a capture; "
      + "Laban does not open a profiler listener."

    profileRecorderHelpLabel.isEditable = false
    profileRecorderHelpLabel.isSelectable = true
    profileRecorderHelpLabel.isBezeled = false
    profileRecorderHelpLabel.drawsBackground = false
    profileRecorderHelpLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    profileRecorderHelpLabel.textColor = .secondaryLabelColor
    profileRecorderHelpLabel.preferredMaxLayoutWidth = 420

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
      + "it at runtime. Applies to new sessions; a running program isn't "
      + "affected until it restarts, though a fresh program launched in an "
      + "idle tab (e.g. starting Claude Code at the prompt) picks it up."

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

    hoverPreviewCheckbox.target = self
    hoverPreviewCheckbox.action = #selector(hoverPreviewChanged(_:))
    hoverPreviewCheckbox.toolTip = L10n.tr(
      "Available with Slug Glyph; hovering a background tab's sidebar row shows a live miniature of its recent output."
    )
    hoverPreviewCheckbox.setAccessibilityLabel(L10n.tr("Sidebar hover preview"))

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

    focusTroubleshootingStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    focusTroubleshootingStatusLabel.preferredMaxLayoutWidth = 360
    focusTroubleshootingStatusLabel.toolTip = L10n.tr(
      "Focus is checked only when you press the troubleshooting button. Laban never reads or requests Focus Status during launch or normal notification delivery."
    )

    focusTroubleshootingButton.target = self
    focusTroubleshootingButton.action = #selector(checkFocusStatusClicked(_:))
    focusTroubleshootingButton.bezelStyle = .rounded
    focusTroubleshootingButton.toolTip = L10n.tr(
      "Checks whether the current Focus is silencing Laban. The first check may ask for Focus Status permission."
    )

    openFocusSettingsButton.target = self
    openFocusSettingsButton.action = #selector(openFocusSettingsClicked(_:))
    openFocusSettingsButton.bezelStyle = .rounded

    approvalsRefreshButton.target = self
    approvalsRefreshButton.action = #selector(approvalsRefreshClicked(_:))
    approvalsRefreshButton.bezelStyle = .rounded
    approvalsRefreshButton.toolTip =
      "Reload the list of approved lazy-attach principals."
    approvalsStackView.orientation = .vertical
    approvalsStackView.alignment = .leading
    approvalsStackView.spacing = 8

    let themeActionsRow = NSStackView(views: [
      themeImportButton,
      themeRemoveButton,
    ])
    themeActionsRow.orientation = .horizontal
    themeActionsRow.spacing = 8
    themeActionsRow.alignment = .firstBaseline

    let appearanceGrid = makeSettingsGrid([
      [makeLabel(L10n.tr("Theme:")), themePopUp],
      [makeLabel(L10n.tr("Dark theme:")), darkThemePopUp],
      [makeLabel(L10n.tr("Light theme:")), lightThemePopUp],
      [NSGridCell.emptyContentView, themeActionsRow],
      [NSGridCell.emptyContentView, followSystemCheckbox],
      [makeLabel(L10n.tr("Preset:")), backgroundPresetPopUp],
      [makeLabel(L10n.tr("Background source:")), backgroundSourcePopUp],
      [NSGridCell.emptyContentView, backgroundImageStatusLabel],
      [NSGridCell.emptyContentView, backgroundImageActionsRow],
      [makeLabel(L10n.tr("Image scaling:")), backgroundImageScalingPopUp],
      [makeLabel(L10n.tr("Background opacity:")), backgroundOpacityRow],
      [makeLabel(L10n.tr("Background blur:")), backgroundBlurRow],
      [NSGridCell.emptyContentView, explicitCellBackgroundOpacityCheckbox],
      [makeLabel(L10n.tr("Font:")), fontRow],
      [makeLabel(L10n.tr("CJK font:")), cjkFontRow],
      [NSGridCell.emptyContentView, cjkFontStatusLabel],
      [makeLabel(L10n.tr("Cursor:")), cursorStylePopUp],
      [NSGridCell.emptyContentView, blinkCheckbox],
    ])
    singleThemeGridRow = appearanceGrid.row(at: 0)
    darkThemeGridRow = appearanceGrid.row(at: 1)
    lightThemeGridRow = appearanceGrid.row(at: 2)
    let terminalGrid = makeSettingsGrid([
      [makeLabel(L10n.tr("Scroll:")), scrollModePopUp],
      [makeLabel(L10n.tr("Unicode width:")), graphemeWidthPopUp],
      [makeLabel(L10n.tr("Sessions:")), backendPopUp],
      [NSGridCell.emptyContentView, restoreCheckbox],
      [NSGridCell.emptyContentView, autoUpdateCheckbox],
      [NSGridCell.emptyContentView, controlServerCheckbox],
      [NSGridCell.emptyContentView, agentAttachedSessionCheckbox],
      [NSGridCell.emptyContentView, profileRecorderCheckbox],
      [NSGridCell.emptyContentView, profileRecorderHelpLabel],
      [makeLabel(L10n.tr("Identity:")), identityPopUp],
      [NSGridCell.emptyContentView, optionAsMetaCheckbox],
    ])
    let renderingGrid = makeSettingsGrid([
      [makeLabel(L10n.tr("Renderer:")), rendererPopUp],
      [makeLabel(L10n.tr("Emoji rendering:")), emojiRenderingPopUp],
      [vectorTextLabel, vectorSubpixelLayoutPopUp],
      [vectorOverlapLabel, makeVectorSubpixelCustomRow()],
      [vectorTextWeightLabel, makeVectorTextWeightRow()],
      [vectorSmoothScrollLabel, vectorSmoothScrollPopUp],
      [NSGridCell.emptyContentView, hoverPreviewCheckbox],
    ])
    vectorSubpixelCustomGridRow = renderingGrid.row(at: 3)
    let notificationsGrid = makeSettingsGrid([
      [makeLabel(L10n.tr("Notifications:")), needsActionNotificationsCheckbox],
      [NSGridCell.emptyContentView, completionNotificationsCheckbox],
      [NSGridCell.emptyContentView, passiveNotificationsCheckbox],
      [NSGridCell.emptyContentView, notificationSoundCheckbox],
      [NSGridCell.emptyContentView, testNotificationButton],
      [makeLabel(L10n.tr("Focus troubleshooting:")), makeFocusTroubleshootingButtonColumn()],
      [NSGridCell.emptyContentView, focusTroubleshootingStatusLabel],
    ])

    let approvalsGrid = makeSettingsGrid([
      [makeLabel(L10n.tr("Approvals:")), approvalsRefreshButton],
      [NSGridCell.emptyContentView, makeApprovalsListView()],
    ])

    let tabs = NSTabView(frame: .zero)
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.addTabViewItem(makeTabItem(label: L10n.tr("Appearance"), grid: appearanceGrid))
    tabs.addTabViewItem(makeTabItem(label: L10n.tr("Terminal"), grid: terminalGrid))
    tabs.addTabViewItem(makeTabItem(label: L10n.tr("Rendering"), grid: renderingGrid))
    tabs.addTabViewItem(makeTabItem(label: L10n.tr("Notifications"), grid: notificationsGrid))
    tabs.addTabViewItem(makeTabItem(label: L10n.tr("Agent"), grid: approvalsGrid))
    content.addSubview(tabs)
    NSLayoutConstraint.activate([
      tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
      tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: tabs.trailingAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 20),
    ])
    window.layoutIfNeeded()
    window.setContentSize(NSSize(width: 620, height: 520))
  }

  private func populateThemePopUp() {
    themeRowIndices.removeAll()
    themePopUp.removeAllItems()
    darkThemeRowIndices.removeAll()
    darkThemePopUp.removeAllItems()
    lightThemeRowIndices.removeAll()
    lightThemePopUp.removeAllItems()
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
      if theme.isDark {
        darkThemePopUp.addItem(withTitle: theme.name)
        darkThemeRowIndices.append(i)
      } else {
        lightThemePopUp.addItem(withTitle: theme.name)
        lightThemeRowIndices.append(i)
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

  private func makeFocusTroubleshootingButtonColumn() -> NSStackView {
    Self.makeFocusTroubleshootingButtonColumn(
      checkButton: focusTroubleshootingButton,
      settingsButton: openFocusSettingsButton)
  }

  static func makeFocusTroubleshootingButtonColumn(
    checkButton: NSButton,
    settingsButton: NSButton
  ) -> NSStackView {
    let column = NSStackView(views: [checkButton, settingsButton])
    column.orientation = .vertical
    column.spacing = 8
    column.alignment = .leading
    return column
  }

  private func makeVectorTextWeightRow() -> NSStackView {
    vectorTextWeightSlider.isContinuous = true
    vectorTextWeightSlider.target = self
    vectorTextWeightSlider.action = #selector(vectorTextWeightChanged(_:))
    vectorTextWeightSlider.toolTip =
      "How much to thicken vector text (stem darkening). 0 = thin geometric outline; "
      + "1 = matched to the classic/CoreText weight; 2 = extra heavy. Applies live."
    vectorTextWeightSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
    vectorTextWeightSlider.numberOfTickMarks = 3
    vectorTextWeightSlider.allowsTickMarkValuesOnly = false
    vectorTextWeightValueLabel.font = .monospacedDigitSystemFont(
      ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let row = NSStackView(views: [
      makeSmallLabel(L10n.tr("Thin")),
      vectorTextWeightSlider,
      makeSmallLabel(L10n.tr("Heavy")),
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

  /// Disable (and dim) the vector-only settings when the active renderer does
  /// not consume them. Vector text AA, the custom overlap editor, and text
  /// weight are read by both vector renderers. Smooth scroll is read only by
  /// the atlas-based Vector Glyph renderer — Slug renders from curves every
  /// frame, so the fluid/crisp mask-reuse choice has no effect there.
  private func refreshVectorControlsForRenderer(_ selection: RendererSelection) {
    let vectorAA = selection == .vectorGlyph || selection == .slugGlyph
    let smoothScroll = selection == .vectorGlyph

    vectorSubpixelLayoutPopUp.isEnabled = vectorAA
    vectorTextLabel.textColor = vectorAA ? .labelColor : .secondaryLabelColor
    for field in vectorSubpixelFields {
      field.isEnabled = vectorAA
    }
    vectorSubpixelApplyButton.isEnabled = vectorAA
    vectorOverlapLabel.textColor = vectorAA ? .labelColor : .secondaryLabelColor

    vectorTextWeightSlider.isEnabled = vectorAA
    vectorTextWeightLabel.textColor = vectorAA ? .labelColor : .secondaryLabelColor

    vectorSmoothScrollPopUp.isEnabled = smoothScroll
    vectorSmoothScrollLabel.textColor = smoothScroll ? .labelColor : .secondaryLabelColor

    let slugSelected = selection == .slugGlyph
    let hoverPreviewEnvLocked = HoverPreviewSettings.environmentOverride() != nil
    hoverPreviewCheckbox.isEnabled = slugSelected && !hoverPreviewEnvLocked
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
    let rendererSelection = rendererController.currentSelection
    let vectorAA = rendererSelection == .vectorGlyph || rendererSelection == .slugGlyph
    let followsSystem = themeController.followsSystemAppearance
    let current = themeController.currentThemeName
    if let row = themeRowIndices.firstIndex(where: {
      $0 >= 0 && themeController.orderedThemes[$0].name == current
    }) {
      themePopUp.selectItem(at: row)
    }
    if let row = darkThemeRowIndices.firstIndex(where: {
      $0 >= 0 && themeController.orderedThemes[$0].name == themeController.darkVariantName
    }) {
      darkThemePopUp.selectItem(at: row)
    }
    if let row = lightThemeRowIndices.firstIndex(where: {
      $0 >= 0 && themeController.orderedThemes[$0].name == themeController.lightVariantName
    }) {
      lightThemePopUp.selectItem(at: row)
    }
    // While following the system, both pinned variants are editable at once;
    // the single combined popup only makes sense for a manual pick.
    singleThemeGridRow?.isHidden = followsSystem
    darkThemeGridRow?.isHidden = !followsSystem
    lightThemeGridRow?.isHidden = !followsSystem
    followSystemCheckbox.state = followsSystem ? .on : .off
    let importedNames = Set((try? themeStore.allManagedThemes().map(\.name)) ?? [])
    themeRemoveButton.isEnabled = themeRemovalCandidates(followsSystem: followsSystem)
      .contains { $0.map(importedNames.contains) ?? false }
    refreshTransparencyControls()
    fontLabel.stringValue = currentFontDisplayName()
    refreshCJKFontControls()
    if let row = rendererOptions.firstIndex(of: rendererSelection) {
      rendererPopUp.selectItem(at: row)
    }
    if let row = backendOptions.firstIndex(of: backendController.currentSelection) {
      backendPopUp.selectItem(at: row)
    }
    restoreCheckbox.state = RestoreOnLaunchSettings.isEnabled ? .on : .off
    autoUpdateCheckbox.isEnabled = UpdaterController.shared.isConfigured
    autoUpdateCheckbox.state =
      UpdaterController.shared.automaticallyChecksForUpdates ? .on : .off
    controlServerCheckbox.state = ControlServerSettings.isEnabled ? .on : .off
    agentAttachedSessionCheckbox.state = AgentAttachedSessionSettings.isEnabled() ? .on : .off
    profileRecorderCheckbox.state = ProfileRecorderSettings.persisted() ? .on : .off
    profileRecorderHelpLabel.stringValue = ProfileRecorderSettings.settingsHelpText
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
      !vectorAA || VectorSubpixelLayout.persistedPreset() != .customOverlap
    vectorTextWeightSlider.doubleValue = VectorTextWeightSettings.current()
    updateVectorTextWeightLabel()
    if let row = vectorSmoothScrollOptions.firstIndex(of: VectorSmoothScrollSettings.current()) {
      vectorSmoothScrollPopUp.selectItem(at: row)
    }
    refreshVectorControlsForRenderer(rendererSelection)
    hoverPreviewCheckbox.state = HoverPreviewSettings.enabled ? .on : .off
    optionAsMetaCheckbox.state = OptionKeySettings.current() ? .on : .off
    needsActionNotificationsCheckbox.state =
      AttentionNotificationSettings.needsActionEnabled ? .on : .off
    completionNotificationsCheckbox.state =
      AttentionNotificationSettings.completionEnabled ? .on : .off
    passiveNotificationsCheckbox.state =
      AttentionNotificationSettings.passiveEnabled ? .on : .off
    notificationSoundCheckbox.state =
      AttentionNotificationSettings.soundEnabled ? .on : .off
    refreshFocusTroubleshootingControls()
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

  @objc private func darkThemeChanged(_ sender: NSPopUpButton) {
    pinVariant(from: sender, indices: darkThemeRowIndices)
  }

  @objc private func lightThemeChanged(_ sender: NSPopUpButton) {
    pinVariant(from: sender, indices: lightThemeRowIndices)
  }

  /// Per-appearance picks pin the dark/light variant and stay in follow-system
  /// mode; the controller applies immediately only when the system is already
  /// in that appearance.
  private func pinVariant(from popup: NSPopUpButton, indices: [Int]) {
    let row = popup.indexOfSelectedItem
    guard row >= 0, row < indices.count else { return }
    themeController.pinVariant(at: indices[row])
    refresh()
  }

  /// Names currently selected in the visible theme popup(s), in removal
  /// priority order. Following the system exposes both variants, so Remove can
  /// target either one.
  private func themeRemovalCandidates(followsSystem: Bool) -> [String?] {
    if followsSystem {
      return [
        selectedThemeName(in: darkThemePopUp, indices: darkThemeRowIndices),
        selectedThemeName(in: lightThemePopUp, indices: lightThemeRowIndices),
      ]
    }
    return [selectedThemeName(in: themePopUp, indices: themeRowIndices)]
  }

  private func selectedThemeName(in popup: NSPopUpButton, indices: [Int]) -> String? {
    let row = popup.indexOfSelectedItem
    guard row >= 0, row < indices.count else { return nil }
    let index = indices[row]
    guard index >= 0, index < themeController.orderedThemes.count else { return nil }
    return themeController.orderedThemes[index].name
  }

  @objc private func followSystemChanged(_ sender: NSButton) {
    themeController.setFollowsSystem(sender.state == .on)
    refresh()
  }

  @objc private func themeStoreDidChange(_ notification: Notification) {
    themeController.reloadImportedThemes()
    populateThemePopUp()
    refresh()
  }

  @objc private func importThemeClicked(_ sender: Any?) {
    themeFilePicker(window) { [weak self] selectedURL in
      guard let self else { return }
      guard let selectedURL else {
        self.refresh()
        return
      }
      do {
        _ = try self.themeStore.importTheme(from: selectedURL)
      } catch {
        self.themeImportErrorPresenter(
          self.window,
          L10n.tr("Couldn’t Import Theme"),
          L10n.tr(
            "The selected file is not a valid Laban theme. Check the version, name, and color values and try again."
          ))
      }
      // The store posts a did-change notification on success, which reloads
      // the popup. Refresh regardless so a cancelled picker restores selection.
      self.refresh()
    }
  }

  @objc private func removeThemeClicked(_ sender: Any?) {
    let importedNames = Set((try? themeStore.allManagedThemes().map(\.name)) ?? [])
    guard
      let name = themeRemovalCandidates(
        followsSystem: themeController.followsSystemAppearance
      )
      .compactMap({ $0 })
      .first(where: importedNames.contains)
    else { return }
    do {
      try themeStore.removeManagedTheme(named: name)
    } catch {
      themeImportErrorPresenter(
        window,
        L10n.tr("Couldn’t Remove Theme"),
        L10n.tr("The selected theme could not be removed."))
    }
    // The store posts a did-change notification on success. Refresh regardless.
    refresh()
  }

  @objc private func backgroundPresetChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < backgroundPresetOptions.count else {
      refreshTransparencyControls()
      return
    }
    let preset = backgroundPresetOptions[row]
    guard preset != .custom else {
      refreshTransparencyControls()
      return
    }
    transparencyPersistence.applyPreset(preset, themeIsDark: Theme.current.isDark)
    refreshTransparencyControls()
  }

  @objc private func backgroundSourceChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < backgroundSourceOptions.count else {
      refreshTransparencyControls()
      return
    }
    let source = backgroundSourceOptions[row]
    if source == .image {
      // The picker is transactional. Do not publish Image until a usable
      // managed asset exists, so cancellation is an exact settings no-op.
      transparencyPersistence.flush()
      let previous = TerminalTransparencySettings.requestedSettings(
        defaults: transparencyDefaults)
      let resolution = backgroundImageStore.resolveManagedImage(
        previous.managedBackgroundImage)
      guard resolution.availability == .available else {
        chooseBackgroundImage(previousSettings: previous)
        return
      }
    }
    transparencyPersistence.updateRequestedConfiguration { configuration in
      configuration.backdropStyle = source
    }
  }

  @objc private func chooseBackgroundImageClicked(_ sender: Any?) {
    transparencyPersistence.flush()
    chooseBackgroundImage(
      previousSettings: TerminalTransparencySettings.requestedSettings(
        defaults: transparencyDefaults))
  }

  @objc private func removeBackgroundImageClicked(_ sender: Any?) {
    transparencyPersistence.flush()
    backgroundImageStore.removeManagedImage()
    refreshTransparencyControls()
  }

  @objc private func backgroundImageScalingChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < backgroundImageScalingOptions.count else {
      refreshTransparencyControls()
      return
    }
    let scaling = backgroundImageScalingOptions[row]
    transparencyPersistence.updateRequestedConfiguration { configuration in
      configuration.backgroundImageScaling = scaling
    }
  }

  @objc private func backgroundOpacityChanged(_ sender: NSSlider) {
    let percent = min(100, max(0, Int(sender.doubleValue.rounded())))
    sender.doubleValue = Double(percent)
    updateBackgroundOpacityValueLabel(percent: percent)
    transparencyPersistence.scheduleBackgroundOpacity(Double(percent) / 100)
    selectBackgroundPreset(.custom)
  }

  @objc private func backgroundBlurChanged(_ sender: NSSlider) {
    let percent = min(100, max(0, Int(sender.doubleValue.rounded())))
    sender.doubleValue = Double(percent)
    updateBackgroundBlurValueLabel(percent: percent)
    transparencyPersistence.scheduleBackgroundBlur(Double(percent) / 100)
    selectBackgroundPreset(.custom)
  }

  @objc private func explicitCellBackgroundOpacityChanged(_ sender: NSButton) {
    transparencyPersistence.updateRequestedConfiguration { configuration in
      configuration.applyToExplicitCellBackgrounds = sender.state == .on
    }
  }

  @objc private func changeFontClicked(_ sender: Any?) {
    onChangeFont()
  }

  @objc private func changeCJKFontClicked(_ sender: Any?) {
    onChangeCJKFont()
  }

  @objc private func fontDidChange(_ notification: Notification) {
    refresh()
  }

  @objc private func cjkFontSettingsDidChange(_ notification: Notification) {
    refresh()
  }

  @objc private func transparencySettingsDidChange(_ notification: Notification) {
    refreshTransparencyControls()
  }

  private func refreshTransparencyControls() {
    let requested = TerminalTransparencySettings.requestedSettings(
      defaults: transparencyDefaults)
    let configuration = requested.configuration
    let opacityPercent = min(
      100, max(0, Int((configuration.backgroundOpacity * 100).rounded())))
    let blurPercent = min(
      100, max(0, Int((configuration.backgroundBlur * 100).rounded())))
    backgroundOpacitySlider.doubleValue = Double(opacityPercent)
    backgroundBlurSlider.doubleValue = Double(blurPercent)
    explicitCellBackgroundOpacityCheckbox.state =
      configuration.applyToExplicitCellBackgrounds ? .on : .off
    updateBackgroundOpacityValueLabel(percent: opacityPercent)
    updateBackgroundBlurValueLabel(percent: blurPercent)

    selectBackgroundPreset(TerminalTransparencyPreset.derive(from: configuration))
    if let row = backgroundSourceOptions.firstIndex(of: configuration.backdropStyle) {
      backgroundSourcePopUp.selectItem(at: row)
    }
    if let row = backgroundImageScalingOptions.firstIndex(
      of: configuration.backgroundImageScaling)
    {
      backgroundImageScalingPopUp.selectItem(at: row)
    }
    backgroundImageScalingPopUp.isEnabled = configuration.backdropStyle == .image

    let resolution = backgroundImageStore.resolveManagedImage(requested.managedBackgroundImage)
    refreshBackgroundImageControls(
      managedImage: requested.managedBackgroundImage,
      availability: resolution.availability)
  }

  private func selectBackgroundPreset(_ preset: TerminalTransparencyPreset) {
    if let row = backgroundPresetOptions.firstIndex(of: preset) {
      backgroundPresetPopUp.selectItem(at: row)
    }
  }

  private func refreshBackgroundImageControls(
    managedImage: TerminalManagedBackgroundImage?,
    availability: TerminalBackgroundImageAvailability
  ) {
    let displayName = managedImage?.displayName ?? ""
    switch availability {
    case .none:
      backgroundImageStatusLabel.stringValue = L10n.tr("No image selected.")
      backgroundImageStatusLabel.textColor = .secondaryLabelColor
    case .available:
      backgroundImageStatusLabel.stringValue = String(
        format: L10n.tr("Image: %@"), displayName)
      backgroundImageStatusLabel.textColor = .secondaryLabelColor
    case .missing:
      backgroundImageStatusLabel.stringValue = String(
        format: L10n.tr("Image file is missing: %@"), displayName)
      backgroundImageStatusLabel.textColor = .systemOrange
    case .corrupt, .headlessUnsupported:
      backgroundImageStatusLabel.stringValue = String(
        format: L10n.tr("Image could not be loaded: %@"), displayName)
      backgroundImageStatusLabel.textColor = .systemOrange
    }
    let hasManagedImage = managedImage != nil
    backgroundImageChooseButton.title =
      hasManagedImage
      ? L10n.tr("Choose Again…") : L10n.tr("Choose…")
    backgroundImageRemoveButton.isEnabled = hasManagedImage
  }

  private func chooseBackgroundImage(
    previousSettings: TerminalTransparencyRequestedSettings
  ) {
    backgroundImagePicker(window) { [weak self] selectedURL in
      guard let self else { return }
      guard let selectedURL else {
        // Only the popup's temporary visual selection changed. Re-derive all
        // controls from the untouched requested configuration.
        self.refreshTransparencyControls()
        return
      }
      do {
        try self.backgroundImageStore.importImage(
          from: selectedURL,
          scaling: previousSettings.configuration.backgroundImageScaling)
      } catch {
        self.backgroundImageErrorPresenter(
          self.window,
          L10n.tr("Couldn’t Import Background Image"),
          L10n.tr(
            "The selected file could not be imported as a background image. Choose a valid still image and try again."
          ))
      }
      self.refreshTransparencyControls()
    }
  }

  private func updateBackgroundOpacityValueLabel(percent: Int) {
    backgroundOpacityValueLabel.stringValue = "\(percent)%"
    backgroundOpacitySlider.setAccessibilityValueDescription(
      String(
        format: L10n.tr("Background opacity: %lld percent"),
        Int64(percent)))
  }

  private func updateBackgroundBlurValueLabel(percent: Int) {
    backgroundBlurValueLabel.stringValue = "\(percent)%"
    backgroundBlurSlider.setAccessibilityValueDescription(
      String(
        format: L10n.tr("Background blur: %lld percent"),
        Int64(percent)))
  }

  var transparencyControlsForTesting:
    (
      slider: NSSlider,
      valueLabel: NSTextField,
      explicitCellCheckbox: NSButton
    )
  {
    (backgroundOpacitySlider, backgroundOpacityValueLabel, explicitCellBackgroundOpacityCheckbox)
  }

  var backgroundBlurControlsForTesting: (slider: NSSlider, valueLabel: NSTextField) {
    (backgroundBlurSlider, backgroundBlurValueLabel)
  }

  var backgroundSourceControlsForTesting:
    (
      preset: NSPopUpButton,
      source: NSPopUpButton,
      status: NSTextField,
      choose: NSButton,
      remove: NSButton,
      scaling: NSPopUpButton
    )
  {
    (
      backgroundPresetPopUp,
      backgroundSourcePopUp,
      backgroundImageStatusLabel,
      backgroundImageChooseButton,
      backgroundImageRemoveButton,
      backgroundImageScalingPopUp
    )
  }

  func flushPendingTransparencyPersistenceForTesting() {
    transparencyPersistence.flush()
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

  @objc private func autoUpdateChanged(_ sender: NSButton) {
    UpdaterController.shared.automaticallyChecksForUpdates = sender.state == .on
  }

  @objc private func controlServerChanged(_ sender: NSButton) {
    let enabled = sender.state == .on
    ControlServerSettings.set(enabled)
    onControlServerEnabledChanged(enabled)
  }

  @objc private func agentAttachedSessionChanged(_ sender: NSButton) {
    AgentAttachedSessionSettings.set(sender.state == .on)
  }

  @objc private func profileRecorderChanged(_ sender: NSButton) {
    ProfileRecorderSettings.set(sender.state == .on)
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

  @objc private func hoverPreviewChanged(_ sender: NSButton) {
    let enabled = sender.state == .on
    guard HoverPreviewSettings.setEnabled(enabled) else {
      sender.state = HoverPreviewSettings.enabled ? .on : .off
      return
    }
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

  @objc private func checkFocusStatusClicked(_ sender: NSButton) {
    guard !focusCheckInFlight else { return }
    focusCheckInFlight = true
    focusTroubleshootingButton.isEnabled = false
    focusTroubleshootingStatusLabel.stringValue = L10n.tr("Checking Focus…")
    focusTroubleshootingStatusLabel.textColor = .secondaryLabelColor

    onCheckFocusStatus { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.focusCheckInFlight = false
        self.refreshFocusTroubleshootingControls()
      }
    }
  }

  @objc private func openFocusSettingsClicked(_ sender: NSButton) {
    guard let destination = focusSettingsDestination else { return }
    for url in destination.urls where NSWorkspace.shared.open(url) {
      return
    }
  }

  private func refreshFocusTroubleshootingControls() {
    guard !focusCheckInFlight else { return }
    let presentation = NativeFocusTroubleshootingPresentation(focusStatusSnapshot())
    focusTroubleshootingStatusLabel.stringValue = presentation.message
    focusTroubleshootingStatusLabel.textColor =
      presentation.tone == .warning ? .systemOrange : .secondaryLabelColor
    focusTroubleshootingButton.title = presentation.buttonTitle
    focusTroubleshootingButton.isEnabled = true
    focusSettingsDestination = presentation.settingsDestination
    openFocusSettingsButton.title = presentation.settingsButtonTitle ?? L10n.tr("Open Settings")
    openFocusSettingsButton.toolTip = presentation.settingsToolTip
    openFocusSettingsButton.isHidden = !presentation.showsOpenSettings
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

  // MARK: Agent Approvals

  private func makeApprovalsListView() -> NSScrollView {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    scroll.autohidesScrollers = true
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
    scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
    scroll.documentView = approvalsStackView
    refreshApprovalsList()
    return scroll
  }

  private func refreshApprovalsList() {
    for subview in approvalsStackView.subviews {
      subview.removeFromSuperview()
    }
    let records = approvalStore.loadAll().filter { $0.isRevoked == false }
    if records.isEmpty {
      let label = makeSmallLabel("No active lazy-attach approvals.")
      approvalsStackView.addArrangedSubview(label)
    } else {
      for record in records {
        let row = NSStackView(views: [makeApprovalLabel(record), makeRevokeButton(record)])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        approvalsStackView.addArrangedSubview(row)
      }
    }
  }

  private func makeApprovalLabel(_ record: ControlAttachApprovalRecord) -> NSTextField {
    let scope = (record.allowedRouteIDs + record.allowedIntentIDs).joined(separator: ", ")
    let text = "\(record.displayName) — \(scope)"
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.usesSingleLineMode = true
    label.preferredMaxLayoutWidth = 240
    return label
  }

  private func makeRevokeButton(_ record: ControlAttachApprovalRecord) -> NSButton {
    let button = NSButton(
      title: L10n.tr("Revoke"), target: self, action: #selector(revokeApprovalClicked(_:)))
    button.bezelStyle = .rounded
    button.toolTip = "Revoke approval for \(record.displayName)"
    button.identifier = NSUserInterfaceItemIdentifier(record.id)
    return button
  }

  @objc private func approvalsRefreshClicked(_ sender: Any?) {
    refreshApprovalsList()
  }

  @objc private func revokeApprovalClicked(_ sender: NSButton) {
    guard let id = sender.identifier?.rawValue else { return }
    approvalStore.revoke(id: id)
    refreshApprovalsList()
    // Audit the revocation through the security coordinator.
    let security = ControlSecurityCoordinator(indicatorHost: nil)
    let context = ControlSecurityContext(
      intentID: "control.attach.revoke",
      capability: .observeSensitive,
      surface: .gui,
      sessionID: nil)
    security.didAttachRevoke(context)
  }

  static func configureBackgroundImageOpenPanel(_ panel: NSOpenPanel) {
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true
    panel.allowedContentTypes = [.image]
    panel.title = L10n.tr("Choose a Background Image")
    panel.prompt = L10n.tr("Choose Image")
  }

  private static func presentBackgroundImagePicker(
    _ window: NSWindow?,
    completion: @escaping (URL?) -> Void
  ) {
    let panel = NSOpenPanel()
    configureBackgroundImageOpenPanel(panel)
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completion(response == .OK ? panel.url : nil)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  private static func presentBackgroundImageImportError(
    _ window: NSWindow?,
    title: String,
    message: String
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L10n.tr("OK"))
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  static func configureThemeFileOpenPanel(_ panel: NSOpenPanel) {
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true
    panel.allowedContentTypes = [UTType.json]
    panel.title = L10n.tr("Choose a Laban Theme")
    panel.prompt = L10n.tr("Import Theme")
    panel.directoryURL = bundledThemeExamplesDirectoryURL()
  }

  private static func bundledThemeExamplesDirectoryURL() -> URL? {
    LabanAppResources.bundle.url(forResource: "ThemeExamples", withExtension: nil)
  }

  private static func presentThemeFilePicker(
    _ window: NSWindow?,
    completion: @escaping (URL?) -> Void
  ) {
    let panel = NSOpenPanel()
    configureThemeFileOpenPanel(panel)
    let finish: (NSApplication.ModalResponse) -> Void = { response in
      completion(response == .OK ? panel.url : nil)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: finish)
    } else {
      panel.begin(completionHandler: finish)
    }
  }

  private static func presentThemeImportError(
    _ window: NSWindow?,
    title: String,
    message: String
  ) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: L10n.tr("OK"))
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  // MARK: Titles

  private func backgroundPresetTitle(_ preset: TerminalTransparencyPreset) -> String {
    switch preset {
    case .opaque:
      return L10n.tr("Opaque")
    case .frosted:
      return L10n.tr("Frosted")
    case .custom:
      return L10n.tr("Custom")
    }
  }

  private func backgroundSourceTitle(_ source: TerminalBackdropStyle) -> String {
    switch source {
    case .none:
      return L10n.tr("None")
    case .systemBlur:
      return L10n.tr("System Blur")
    case .image:
      return L10n.tr("Image")
    }
  }

  private func backgroundImageScalingTitle(
    _ scaling: TerminalBackgroundImageScaling
  ) -> String {
    switch scaling {
    case .fill:
      return L10n.tr("Fill")
    case .fit:
      return L10n.tr("Fit")
    case .stretch:
      return L10n.tr("Stretch")
    }
  }

  private func rendererTitle(_ selection: RendererSelection) -> String {
    switch selection {
    case .software:
      return L10n.tr("Software")
    case .classic:
      return L10n.tr("Classic (Metal)")
    case .gpuDriven:
      return selection.isAvailableOnCurrentOS
        ? L10n.tr("GPU-driven (Metal)") : L10n.tr("GPU-driven (requires macOS 26)")
    case .vectorGlyph:
      return L10n.tr("Vector Glyph")
    case .slugGlyph:
      return L10n.tr("Slug Glyph")
    }
  }

  private func backendTitle(_ backend: TerminalSessionBackend) -> String {
    switch backend {
    case .inProcess:
      return L10n.tr("Local")
    case .labpty:
      return L10n.tr("Background")
    case .laband:
      return L10n.tr("Detached")
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
    case .block: return L10n.tr("Block")
    case .bar: return L10n.tr("Bar")
    case .underline: return L10n.tr("Underline")
    }
  }

  private func scrollModeTitle(_ mode: ScrollSettings.Mode) -> String {
    switch mode {
    case .pixelSmooth: return L10n.tr("Pixel-smooth")
    case .lineQuantized: return L10n.tr("Line-quantized")
    }
  }

  private func graphemeWidthTitle(_ mode: GraphemeWidthMode) -> String {
    switch mode {
    case .auto: return L10n.tr("Auto (recommended)")
    case .preferGrapheme: return L10n.tr("Prefer grapheme width")
    }
  }

  private func emojiRenderingTitle(_ mode: EmojiRenderingMode) -> String {
    switch mode {
    case .monochrome: return L10n.tr("Monochrome")
    case .color: return L10n.tr("Color")
    }
  }

  private func vectorSubpixelLayoutTitle(_ preset: VectorSubpixelLayoutPreset) -> String {
    switch preset {
    case .grayscale: return L10n.tr("Grayscale")
    case .calibratedRGB: return L10n.tr("Calibrated")
    case .customOverlap: return L10n.tr("Custom overlap")
    case .rgbStripe: return L10n.tr("RGB subpixel")
    case .bgrStripe: return L10n.tr("BGR subpixel")
    }
  }

  private func vectorSmoothScrollTitle(_ mode: VectorSmoothScrollMode) -> String {
    switch mode {
    case .fluid: return L10n.tr("Fluid")
    case .perPhase: return L10n.tr("Crisp")
    }
  }

  private func refreshCJKFontControls() {
    let preference = CJKFontSettings.current()
    let atlas = FontAtlas(pointSize: FontAtlas.persistedTerminalPointSize)
    for (index, option) in cjkFontOptions.enumerated() {
      let installed = TerminalCJKFontPolicy.isAvailable(option, baseFont: atlas.font)
      let title =
        installed
        ? option.displayName
        : "\(option.displayName) \(L10n.tr("(not installed)"))"
      cjkFontPopUp.item(at: index)?.title = title
      cjkFontPopUp.item(at: index)?.isEnabled = installed
      cjkFontPopUp.item(at: index)?.toolTip =
        installed
        ? "Use \(option.displayName) for CJK fallback."
        : "Install \(option.displayName) to enable this choice."
    }
    if preference != .custom, let row = cjkFontOptions.firstIndex(of: preference) {
      cjkFontPopUp.selectItem(at: row)
    } else {
      cjkFontPopUp.select(nil)
    }
    let status = TerminalCJKFontPolicy.userStatus(
      baseFont: atlas.font,
      cellWidth: atlas.cellSize.width)
    if preference == .custom {
      let customName = CJKFontSettings.currentDisplayName(baseFont: atlas.font)
      cjkFontStatusLabel.stringValue = "Custom: \(customName). \(status.message)"
    } else {
      cjkFontStatusLabel.stringValue = status.message
    }
    cjkFontStatusLabel.textColor = status.isDegraded ? .systemOrange : .secondaryLabelColor
    cjkFontPopUp.toolTip =
      status.isDegraded
      ? status.message
      : "Quick picks for common CJK fallback fonts."
  }

  @objc private func cjkFontChanged(_ sender: NSPopUpButton) {
    let row = sender.indexOfSelectedItem
    guard row >= 0, row < cjkFontOptions.count else { return }
    let option = cjkFontOptions[row]
    guard sender.item(at: row)?.isEnabled == true else {
      NSSound.beep()
      refreshCJKFontControls()
      return
    }
    CJKFontSettings.set(option)
    refreshCJKFontControls()
  }

  private func currentFontDisplayName() -> String {
    let name = UserDefaults.standard.string(forKey: FontAtlas.userFontKey) ?? "JetBrains Mono"
    let size = FontAtlas.persistedTerminalPointSize
    let displayName = NSFont(name: name, size: size)?.displayName ?? name
    return "\(displayName), \(String(format: "%.0f pt", size))"
  }
}
