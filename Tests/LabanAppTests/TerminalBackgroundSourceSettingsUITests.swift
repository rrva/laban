import AppKit
import CoreGraphics
import ImageIO
import LabanCore
import UniformTypeIdentifiers
import XCTest

@testable import LabanApp

@MainActor
final class TerminalBackgroundSourceSettingsUITests: XCTestCase {
  private var suiteNames: [String] = []
  private var roots: [URL] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    suiteNames = []
    roots = []
    super.tearDown()
  }

  func testDefaultControlsExposeExactSourcesScalingAndVisibleCustomState() throws {
    let context = try makeContext()
    let controller = makeController(context: context)
    let controls = controller.backgroundSourceControlsForTesting

    XCTAssertEqual(
      controls.preset.itemTitles,
      [L10n.tr("Opaque"), L10n.tr("Frosted"), L10n.tr("Custom")])
    XCTAssertEqual(controls.preset.titleOfSelectedItem, L10n.tr("Opaque"))
    XCTAssertEqual(
      controls.source.itemTitles,
      [L10n.tr("None"), L10n.tr("System Blur"), L10n.tr("Image")])
    XCTAssertEqual(controls.source.titleOfSelectedItem, L10n.tr("None"))
    XCTAssertEqual(
      controls.scaling.itemTitles,
      [L10n.tr("Fill"), L10n.tr("Fit"), L10n.tr("Stretch")])
    XCTAssertEqual(controls.scaling.titleOfSelectedItem, L10n.tr("Fill"))
    XCTAssertFalse(controls.scaling.isEnabled)
    XCTAssertEqual(controls.status.stringValue, L10n.tr("No image selected."))
    XCTAssertEqual(controls.choose.title, L10n.tr("Choose…"))
    XCTAssertFalse(controls.remove.isEnabled)
    XCTAssertEqual(controls.preset.accessibilityLabel(), L10n.tr("Preset:"))
    XCTAssertEqual(controls.source.accessibilityLabel(), L10n.tr("Background source:"))
    XCTAssertEqual(controls.status.accessibilityLabel(), L10n.tr("Image"))
    XCTAssertEqual(controls.scaling.accessibilityLabel(), L10n.tr("Image scaling:"))
    XCTAssertNotNil(controls.preset.toolTip)
    XCTAssertNotNil(controls.source.toolTip)
    XCTAssertNotNil(controls.choose.toolTip)
    XCTAssertNotNil(controls.remove.toolTip)
    XCTAssertNotNil(controls.scaling.toolTip)
  }

  func testFrostedIsThemeNeutralAndIndividualControlsDeriveCustom() throws {
    let context = try makeContext()
    let themeController = ThemeMenuController()
    let originalThemeName = themeController.currentThemeName
    let originalFollowsSystem = themeController.followsSystemAppearance
    let controller = makeController(context: context, themeController: themeController)
    let background = controller.backgroundSourceControlsForTesting
    let opacity = controller.transparencyControlsForTesting
    let blur = controller.backgroundBlurControlsForTesting

    background.preset.selectItem(at: 1)
    sendAction(background.preset)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: context.defaults),
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.80,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fill,
        backgroundBlur: 0.20))
    XCTAssertEqual(background.preset.titleOfSelectedItem, L10n.tr("Frosted"))
    XCTAssertEqual(themeController.currentThemeName, originalThemeName)
    XCTAssertEqual(themeController.followsSystemAppearance, originalFollowsSystem)

    opacity.slider.doubleValue = 72
    sendAction(opacity.slider)
    XCTAssertEqual(background.preset.titleOfSelectedItem, L10n.tr("Custom"))

    background.preset.selectItem(at: 1)
    sendAction(background.preset)
    blur.slider.doubleValue = 33
    sendAction(blur.slider)
    XCTAssertEqual(background.preset.titleOfSelectedItem, L10n.tr("Custom"))

    background.preset.selectItem(at: 1)
    sendAction(background.preset)
    opacity.explicitCellCheckbox.state = .on
    sendAction(opacity.explicitCellCheckbox)
    XCTAssertEqual(background.preset.titleOfSelectedItem, L10n.tr("Custom"))

    background.preset.selectItem(at: 1)
    sendAction(background.preset)
    background.source.selectItem(at: 0)
    sendAction(background.source)
    XCTAssertEqual(background.preset.titleOfSelectedItem, L10n.tr("Custom"))
  }

  func testImageSelectionCancelRestoresExactPreviousConfiguration() throws {
    let context = try makeContext()
    let previous = TerminalTransparencyRequestedSettings(
      configuration: TerminalTransparencyConfiguration(
        backgroundOpacity: 0.63,
        applyToExplicitCellBackgrounds: true,
        backdropStyle: .systemBlur,
        backgroundImageScaling: .fit),
      managedBackgroundImage: nil)
    TerminalTransparencySettings.setRequestedSettings(
      previous,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    var pickerCount = 0
    let controller = makeController(
      context: context,
      picker: { _, completion in
        pickerCount += 1
        completion(nil)
      })
    let controls = controller.backgroundSourceControlsForTesting

    controls.source.selectItem(at: 2)
    sendAction(controls.source)

    XCTAssertEqual(pickerCount, 1)
    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: context.defaults), previous)
    XCTAssertEqual(controls.source.titleOfSelectedItem, L10n.tr("System Blur"))
    XCTAssertEqual(controls.preset.titleOfSelectedItem, L10n.tr("Custom"))
  }

  func testSuccessfulImportSelectsImageUpdatesStatusScalingAndRemove() throws {
    let context = try makeContext()
    let imageURL = context.externalURL.appendingPathComponent("Northern Lights.png")
    try writeImage(to: imageURL)
    let controller = makeController(
      context: context,
      picker: { _, completion in completion(imageURL) })
    let controls = controller.backgroundSourceControlsForTesting

    controls.source.selectItem(at: 2)
    sendAction(controls.source)

    var requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    XCTAssertEqual(requested.configuration.backdropStyle, .image)
    XCTAssertEqual(requested.configuration.backgroundImageScaling, .fill)
    XCTAssertEqual(requested.managedBackgroundImage?.displayName, "Northern Lights.png")
    XCTAssertEqual(controls.source.titleOfSelectedItem, L10n.tr("Image"))
    XCTAssertEqual(controls.preset.titleOfSelectedItem, L10n.tr("Custom"))
    XCTAssertEqual(
      controls.status.stringValue,
      String(format: L10n.tr("Image: %@"), "Northern Lights.png"))
    XCTAssertEqual(controls.choose.title, L10n.tr("Choose Again…"))
    XCTAssertTrue(controls.remove.isEnabled)
    XCTAssertTrue(controls.scaling.isEnabled)

    controls.scaling.selectItem(at: 2)
    sendAction(controls.scaling)
    requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    XCTAssertEqual(requested.configuration.backgroundImageScaling, .stretch)
    XCTAssertEqual(controls.preset.titleOfSelectedItem, L10n.tr("Custom"))

    sendAction(controls.remove)
    requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    XCTAssertEqual(requested.configuration.backdropStyle, .none)
    XCTAssertNil(requested.managedBackgroundImage)
    XCTAssertEqual(controls.status.stringValue, L10n.tr("No image selected."))
    XCTAssertFalse(controls.remove.isEnabled)
    XCTAssertFalse(controls.scaling.isEnabled)
  }

  func testImportFailurePreservesPreviousStateAndPresentsLocalizedError() throws {
    let context = try makeContext()
    let invalidURL = context.externalURL.appendingPathComponent("not-an-image.txt")
    try Data("plain text".utf8).write(to: invalidURL)
    let previous = TerminalTransparencyRequestedSettings(
      configuration: TerminalTransparencyConfiguration(
        backgroundOpacity: 0.81,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .none,
        backgroundImageScaling: .stretch),
      managedBackgroundImage: nil)
    TerminalTransparencySettings.setRequestedSettings(
      previous,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    var presentedError: (title: String, message: String)?
    let controller = makeController(
      context: context,
      picker: { _, completion in completion(invalidURL) },
      errorPresenter: { _, title, message in
        presentedError = (title, message)
      })
    let controls = controller.backgroundSourceControlsForTesting

    controls.source.selectItem(at: 2)
    sendAction(controls.source)

    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: context.defaults), previous)
    XCTAssertEqual(presentedError?.title, L10n.tr("Couldn’t Import Background Image"))
    XCTAssertEqual(
      presentedError?.message,
      L10n.tr(
        "The selected file could not be imported as a background image. Choose a valid still image and try again."
      ))
    XCTAssertEqual(controls.source.titleOfSelectedItem, L10n.tr("None"))
  }

  func testOpenPanelIsLimitedToOneImageFile() {
    let panel = NSOpenPanel()

    SettingsWindowController.configureBackgroundImageOpenPanel(panel)

    XCTAssertFalse(panel.allowsMultipleSelection)
    XCTAssertFalse(panel.canChooseDirectories)
    XCTAssertTrue(panel.canChooseFiles)
    XCTAssertEqual(panel.allowedContentTypes, [.image])
    XCTAssertEqual(panel.title, L10n.tr("Choose a Background Image"))
    XCTAssertEqual(panel.prompt, L10n.tr("Choose Image"))
  }

  private struct Context {
    let defaults: UserDefaults
    let notifications: NotificationCenter
    let store: TerminalBackgroundImageStore
    let externalURL: URL
  }

  private func makeContext() throws -> Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "laban-background-source-ui-tests-\(UUID().uuidString)",
      isDirectory: true)
    roots.append(root)
    let externalURL = root.appendingPathComponent("picker", isDirectory: true)
    try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    let suiteName = "TerminalBackgroundSourceSettingsUITests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let notifications = NotificationCenter()
    return Context(
      defaults: defaults,
      notifications: notifications,
      store: TerminalBackgroundImageStore(
        baseURL: root.appendingPathComponent("application-support", isDirectory: true),
        defaults: defaults,
        notificationCenter: notifications),
      externalURL: externalURL)
  }

  private func makeController(
    context: Context,
    themeController: ThemeMenuController = ThemeMenuController(),
    picker: @escaping SettingsWindowController.BackgroundImagePicker = { _, completion in
      completion(nil)
    },
    errorPresenter: @escaping SettingsWindowController.BackgroundImageErrorPresenter = {
      _, _, _ in
    }
  ) -> SettingsWindowController {
    SettingsWindowController(
      theme: themeController,
      renderer: RendererModeMenuController(applySelection: { _ in }),
      backend: TerminalBackendMenuController(),
      onChangeFont: {},
      onChangeCJKFont: {},
      onTestNotification: {},
      focusStatusSnapshot: { .notChecked },
      onCheckFocusStatus: { completion in completion(.notChecked) },
      transparencyDefaults: context.defaults,
      transparencyNotificationCenter: context.notifications,
      backgroundImageStore: context.store,
      backgroundImagePicker: picker,
      backgroundImageErrorPresenter: errorPresenter)
  }

  private func sendAction(_ control: NSControl) {
    control.sendAction(control.action, to: control.target)
  }

  private func writeImage(to url: URL) throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.systemBlue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
