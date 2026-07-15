import AppKit
import CoreGraphics
import Foundation
import ImageIO
import LabanCore
import LabanRenderer
import LabanTerminalCore
import UniformTypeIdentifiers
import XCTest

@testable import LabanApp

@MainActor
final class TerminalBackgroundImageStoreTests: XCTestCase {
  private var roots: [URL] = []
  private var suiteNames: [String] = []

  override func tearDown() {
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    roots = []
    suiteNames = []
    super.tearDown()
  }

  func testValidImportPublishesManagedReferenceAndSurvivesStoreRelaunch() throws {
    let context = try makeContext()
    var notificationCount = 0
    let token = context.notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { context.notifications.removeObserver(token) }
    let sourceURL = context.externalURL.appendingPathComponent("original-wallpaper.png")
    try writeImage(makeImage(width: 3, height: 2, color: .red), to: sourceURL, type: .png)

    let result = try XCTUnwrap(
      try context.store.importImage(from: sourceURL, scaling: .fit))
    let requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)

    XCTAssertEqual(requested.configuration.backdropStyle, .image)
    XCTAssertEqual(requested.configuration.backgroundImageScaling, .fit)
    XCTAssertEqual(requested.managedBackgroundImage, result.managedImage)
    XCTAssertEqual(result.managedImage.displayName, "original-wallpaper.png")
    XCTAssertEqual(result.sourceFrameCount, 1)
    XCTAssertEqual(result.sourceOrientation, 1)
    XCTAssertEqual(result.pixelWidth, 3)
    XCTAssertEqual(result.pixelHeight, 2)
    XCTAssertFalse(result.managedImage.identifier.contains("/"))
    XCTAssertEqual(notificationCount, 1)
    XCTAssertEqual(
      context.store.diagnostics,
      TerminalBackgroundImageStoreDiagnostics(importCount: 1, decodeCount: 1, fileReadCount: 1))

    let relaunched = TerminalBackgroundImageStore(
      baseURL: context.baseURL,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    let resolution = relaunched.resolveRequestedImage()
    let repeatedResolution = relaunched.resolveRequestedImage()
    XCTAssertEqual(resolution.availability, .available)
    XCTAssertEqual(resolution.asset?.managedImage, result.managedImage)
    XCTAssertEqual(resolution.asset?.image.width, 3)
    XCTAssertEqual(resolution.asset?.image.height, 2)
    XCTAssertEqual(resolution.asset?.contentDigest.count, 64)
    let firstResolvedImage = try XCTUnwrap(resolution.asset?.image)
    let repeatedResolvedImage = try XCTUnwrap(repeatedResolution.asset?.image)
    XCTAssertTrue(firstResolvedImage === repeatedResolvedImage)
    XCTAssertEqual(
      relaunched.diagnostics,
      TerminalBackgroundImageStoreDiagnostics(importCount: 0, decodeCount: 1, fileReadCount: 1))
  }

  func testCancelledImportIsExactNoOp() throws {
    let context = try makeContext()
    var notificationCount = 0
    let token = context.notifications.addObserver(
      forName: TerminalTransparencySettings.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { context.notifications.removeObserver(token) }

    XCTAssertNil(try context.store.importImage(from: nil))
    XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.directoryURL.path))
    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: context.defaults),
      TerminalTransparencyRequestedSettings(
        configuration: TerminalTransparencyConfiguration(
          backgroundOpacity: 1,
          applyToExplicitCellBackgrounds: false,
          backdropStyle: .none,
          backgroundImageScaling: .fill),
        managedBackgroundImage: nil))
    XCTAssertEqual(notificationCount, 0)
  }

  func testDecodeFailurePreservesPreviousAssetAndSettings() throws {
    let context = try makeContext()
    let validURL = context.externalURL.appendingPathComponent("valid.png")
    try writeImage(makeImage(width: 2, height: 2, color: .green), to: validURL, type: .png)
    let first = try XCTUnwrap(try context.store.importImage(from: validURL, scaling: .stretch))
    let previous = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    let previousURL = context.store.directoryURL.appendingPathComponent(
      first.managedImage.identifier)
    let previousData = try Data(contentsOf: previousURL)

    let invalidURL = context.externalURL.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: invalidURL)
    XCTAssertThrowsError(try context.store.importImage(from: invalidURL)) { error in
      XCTAssertEqual(error as? TerminalBackgroundImageStoreError, .invalidImage)
    }

    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: context.defaults), previous)
    XCTAssertEqual(try Data(contentsOf: previousURL), previousData)
    XCTAssertEqual(
      try managedAssetNames(in: context.store.directoryURL),
      [
        first.managedImage.identifier
      ])
  }

  func testPublicationFailureRollsBackNewFileAndKeepsPreviousAsset() throws {
    let context = try makeContext()
    let firstURL = context.externalURL.appendingPathComponent("first.png")
    let secondURL = context.externalURL.appendingPathComponent("second.png")
    try writeImage(makeImage(width: 2, height: 2, color: .red), to: firstURL, type: .png)
    try writeImage(makeImage(width: 2, height: 2, color: .blue), to: secondURL, type: .png)
    let first = try XCTUnwrap(try context.store.importImage(from: firstURL))
    let previous = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    let failingStore = TerminalBackgroundImageStore(
      baseURL: context.baseURL,
      defaults: context.defaults,
      notificationCenter: context.notifications,
      beforeSettingsPublication: {
        throw TerminalBackgroundImageStoreError.publicationFailed
      })

    XCTAssertThrowsError(try failingStore.importImage(from: secondURL)) { error in
      XCTAssertEqual(error as? TerminalBackgroundImageStoreError, .publicationFailed)
    }

    XCTAssertEqual(
      TerminalTransparencySettings.requestedSettings(defaults: context.defaults), previous)
    XCTAssertEqual(
      try managedAssetNames(in: context.store.directoryURL),
      [
        first.managedImage.identifier
      ])
    XCTAssertEqual(context.store.resolveRequestedImage().availability, .available)
  }

  func testManagedDirectoryAndFileArePrivateAndSymlinkEscapeIsInvalid() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("private.png")
    try writeImage(makeImage(width: 2, height: 2, color: .green), to: sourceURL, type: .png)
    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let managedURL = context.store.directoryURL.appendingPathComponent(
      result.managedImage.identifier)

    XCTAssertEqual(try permissions(at: context.store.directoryURL), 0o700)
    XCTAssertEqual(try permissions(at: managedURL), 0o600)

    let escaped = try XCTUnwrap(
      TerminalManagedBackgroundImage(
        identifier: TerminalBackgroundImageStore.managedAssetPrefix
          + UUID().uuidString.lowercased() + ".png",
        displayName: "escaped.png"))
    let escapedURL = context.store.directoryURL.appendingPathComponent(escaped.identifier)
    try FileManager.default.createSymbolicLink(at: escapedURL, withDestinationURL: sourceURL)
    XCTAssertEqual(context.store.resolveManagedImage(escaped).availability, .invalid)
  }

  func testSymlinkedManagedRootIsRejectedWithoutTouchingTarget() throws {
    let context = try makeContext()
    let target = context.externalURL.appendingPathComponent("not-managed", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let targetStaging = target.appendingPathComponent(
      TerminalBackgroundImageStore.stagingPrefix + UUID().uuidString.lowercased() + ".png")
    try Data([1, 2, 3]).write(to: targetStaging)
    try FileManager.default.createDirectory(
      at: context.baseURL,
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: context.store.directoryURL,
      withDestinationURL: target)

    let reopened = TerminalBackgroundImageStore(
      baseURL: context.baseURL,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetStaging.path))

    let sourceURL = context.externalURL.appendingPathComponent("source.png")
    try writeImage(makeImage(width: 2, height: 2, color: .red), to: sourceURL, type: .png)
    XCTAssertThrowsError(try reopened.importImage(from: sourceURL)) { error in
      XCTAssertEqual(
        error as? TerminalBackgroundImageStoreError,
        .managedDirectoryUnavailable)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetStaging.path))
  }

  func testMissingAndCorruptManagedCopiesResolveSafely() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("managed.png")
    try writeImage(makeImage(width: 2, height: 2, color: .blue), to: sourceURL, type: .png)
    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let managedURL = context.store.directoryURL.appendingPathComponent(
      result.managedImage.identifier)

    try FileManager.default.removeItem(at: managedURL)
    XCTAssertEqual(context.store.resolveRequestedImage().availability, .missing)

    try Data("corrupt".utf8).write(to: managedURL)
    XCTAssertEqual(context.store.resolveRequestedImage().availability, .invalid)

    let repairURL = context.externalURL.appendingPathComponent("repair.png")
    try writeImage(makeImage(width: 3, height: 2, color: .green), to: repairURL, type: .png)
    let repaired = try XCTUnwrap(try context.store.importImage(from: repairURL))
    XCTAssertNotEqual(repaired.managedImage.identifier, result.managedImage.identifier)
    XCTAssertEqual(context.store.resolveRequestedImage().availability, .available)
    XCTAssertFalse(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertEqual(
      TerminalTransparencySettings.requestedConfiguration(defaults: context.defaults)
        .backdropStyle,
      .image)
  }

  func testRemovalAndCleanupDeleteOnlyGeneratedFeatureFiles() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("managed.png")
    try writeImage(makeImage(width: 2, height: 2, color: .red), to: sourceURL, type: .png)
    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let orphanName =
      TerminalBackgroundImageStore.managedAssetPrefix
      + UUID().uuidString.lowercased() + ".png"
    let stagingName =
      TerminalBackgroundImageStore.stagingPrefix
      + UUID().uuidString.lowercased() + ".png"
    let unrelatedName = "notes.txt"
    try Data([1]).write(to: context.store.directoryURL.appendingPathComponent(orphanName))
    try Data([2]).write(to: context.store.directoryURL.appendingPathComponent(stagingName))
    try Data([3]).write(to: context.store.directoryURL.appendingPathComponent(unrelatedName))

    let relaunched = TerminalBackgroundImageStore(
      baseURL: context.baseURL,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: relaunched.directoryURL.appendingPathComponent(stagingName).path))
    try relaunched.cleanupOrphans(keeping: result.managedImage)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: relaunched.directoryURL.appendingPathComponent(orphanName).path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: relaunched.directoryURL.appendingPathComponent(unrelatedName).path))

    TerminalTransparencySettings.setBackdropStyle(
      .systemBlur,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    relaunched.removeManagedImage()
    let requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    XCTAssertEqual(requested.configuration.backdropStyle, .none)
    XCTAssertNil(requested.managedBackgroundImage)
    XCTAssertEqual(relaunched.resolveRequestedImage().availability, .none)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: relaunched.directoryURL.appendingPathComponent(unrelatedName).path))
  }

  func testDefaultsNeverContainExternalAbsolutePath() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("private-origin.png")
    try writeImage(makeImage(width: 2, height: 2, color: .blue), to: sourceURL, type: .png)
    _ = try context.store.importImage(from: sourceURL)

    let domain = try XCTUnwrap(
      context.defaults.persistentDomain(forName: context.suiteName))
    let persistedStrings = domain.values.compactMap { $0 as? String }
    XCTAssertFalse(persistedStrings.contains { $0.contains(context.externalURL.path) })
    XCTAssertFalse(persistedStrings.contains { $0 == sourceURL.path })
    XCTAssertEqual(
      domain[TerminalTransparencySettings.backgroundImageDisplayNameKey] as? String,
      "private-origin.png")
  }

  func testAnimatedInputUsesOnlyFirstFrameAndProducesStillManagedPNG() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("animated.gif")
    try writeAnimatedGIF(
      [
        makeImage(width: 2, height: 1, color: .red),
        makeImage(width: 2, height: 1, color: .blue),
      ],
      to: sourceURL)

    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let asset = try XCTUnwrap(context.store.resolveRequestedImage().asset)
    let managedSource = try XCTUnwrap(
      CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil))
    let pixel = pixelRGBA(asset.image)

    XCTAssertEqual(result.sourceFrameCount, 2)
    XCTAssertEqual(CGImageSourceGetCount(managedSource), 1)
    XCTAssertEqual(CGImageSourceGetType(managedSource) as String?, UTType.png.identifier)
    XCTAssertGreaterThan(pixel.red, 200)
    XCTAssertLessThan(pixel.blue, 40)
  }

  func testOrientationIsValidatedAndNormalizedIntoManagedPixels() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("rotated.jpg")
    try writeImage(
      makeImage(width: 4, height: 2, color: .green),
      to: sourceURL,
      type: .jpeg,
      properties: [kCGImagePropertyOrientation: 6])

    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let asset = try XCTUnwrap(context.store.resolveRequestedImage().asset)

    XCTAssertEqual(result.sourceOrientation, 6)
    XCTAssertEqual(result.pixelWidth, 2)
    XCTAssertEqual(result.pixelHeight, 4)
    XCTAssertEqual(asset.image.width, 2)
    XCTAssertEqual(asset.image.height, 4)
  }

  func testCoordinatorResolvesOnLaunchAndActivationWithoutPolling() throws {
    let context = try makeContext()
    TerminalTransparencySettings.setBackgroundOpacity(
      0.7,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    let sourceURL = context.externalURL.appendingPathComponent("active.png")
    try writeImage(makeImage(width: 2, height: 2, color: .red), to: sourceURL, type: .png)
    let result = try XCTUnwrap(try context.store.importImage(from: sourceURL))
    let (view, model) = try makeView()
    let tabIdentity = model.tabs.map(\.id)
    let sessionIdentity = model.tabs.map(\.sessionId)
    let window = NSWindow()
    let backdropContainer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let backgroundHost = TerminalBackgroundEffectHost(frame: .zero)
    backgroundHost.install(
      in: backdropContainer,
      terminalLeadingInset: SidebarLayout.defaultWidth)
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: context.defaults,
      notificationCenter: context.notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported,
      backgroundImageStore: context.store,
      backgroundEffectHost: backgroundHost)

    XCTAssertEqual(coordinator.status.backgroundImageAvailability, .available)
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .image)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 1)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .image)
    let imageView = try XCTUnwrap(backgroundHost.imageView)

    TerminalTransparencySettings.setBackgroundImageScaling(
      .stretch,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    XCTAssertTrue(backgroundHost.imageView === imageView)
    XCTAssertEqual(imageView.scaling, .stretch)
    XCTAssertEqual(imageView.configurationApplyCount, 2)

    TerminalTransparencySettings.setBackgroundOpacity(
      1,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    assertInactiveImage(coordinator: coordinator, host: backgroundHost)
    TerminalTransparencySettings.setBackgroundOpacity(
      0.7,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    assertActiveImage(coordinator: coordinator, host: backgroundHost)

    coordinator.updateReduceTransparency(true)
    assertInactiveImage(coordinator: coordinator, host: backgroundHost)
    coordinator.updateReduceTransparency(false)
    assertActiveImage(coordinator: coordinator, host: backgroundHost)

    context.notifications.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    assertInactiveImage(coordinator: coordinator, host: backgroundHost)
    context.notifications.post(name: NSWindow.didExitFullScreenNotification, object: window)
    assertActiveImage(coordinator: coordinator, host: backgroundHost)

    coordinator.updateSnapshotBackgroundCapability(.legacy)
    assertInactiveImage(coordinator: coordinator, host: backgroundHost)
    coordinator.updateSnapshotBackgroundCapability(.supported)
    assertActiveImage(coordinator: coordinator, host: backgroundHost)

    let managedURL = context.store.directoryURL.appendingPathComponent(
      result.managedImage.identifier)
    try Data("corrupt".utf8).write(to: managedURL)
    XCTAssertEqual(coordinator.status.backgroundImageAvailability, .available)
    context.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(coordinator.status.backgroundImageAvailability, .invalid)
    XCTAssertEqual(
      coordinator.status.effective.forceOpaqueReason,
      .backgroundImageUnavailable)
    assertInactiveImage(coordinator: coordinator, host: backgroundHost)

    _ = try context.store.importImage(from: sourceURL)
    assertActiveImage(coordinator: coordinator, host: backgroundHost)
    XCTAssertEqual(model.tabs.map(\.id), tabIdentity)
    XCTAssertEqual(model.tabs.map(\.sessionId), sessionIdentity)
  }

  func testGUIFixtureImportUsesContainedControlRootAndRunScopedManagedStore() throws {
    let context = try makeContext()
    let controlRoot = context.baseURL.appendingPathComponent("gui-control", isDirectory: true)
    let fixtureDirectory = controlRoot.appendingPathComponent("fixtures", isDirectory: true)
    try FileManager.default.createDirectory(
      at: fixtureDirectory, withIntermediateDirectories: true)
    let sourceURL = fixtureDirectory.appendingPathComponent("backdrop.png")
    try writeImage(makeImage(width: 4, height: 2, color: .purple), to: sourceURL, type: .png)
    let runStore = TerminalBackgroundImageStore(
      baseURL: controlRoot,
      defaults: context.defaults,
      notificationCenter: context.notifications)
    let controller = MainWindowController(window: NSWindow())
    controller.terminalBackgroundFixtureRootURL = controlRoot
    controller.terminalBackgroundImageStore = runStore

    try controller.importBackgroundImageFixture(
      relativePath: "fixtures/backdrop.png",
      scaling: .fit)

    let requested = TerminalTransparencySettings.requestedSettings(defaults: context.defaults)
    let identifier = try XCTUnwrap(requested.managedBackgroundImage?.identifier)
    XCTAssertEqual(requested.configuration.backdropStyle, .image)
    XCTAssertEqual(requested.configuration.backgroundImageScaling, .fit)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: controlRoot.appendingPathComponent("background-images/\(identifier)").path))
    XCTAssertFalse(identifier.contains(controlRoot.path))

    let outside = context.baseURL.appendingPathComponent("outside.png")
    try writeImage(makeImage(width: 1, height: 1, color: .red), to: outside, type: .png)
    XCTAssertThrowsError(
      try controller.importBackgroundImageFixture(relativePath: outside.path, scaling: .fill))
    XCTAssertThrowsError(
      try controller.importBackgroundImageFixture(
        relativePath: "../outside.png", scaling: .fill))
    let link = fixtureDirectory.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(
      try controller.importBackgroundImageFixture(
        relativePath: "fixtures/link.png", scaling: .fill))
  }

  func testCheckedInHighResolutionBackgroundFixtureImportsThroughImageIO() throws {
    let context = try makeContext()
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = repositoryRoot.appendingPathComponent(
      "fixtures/transparency/background-gradient.png")

    let result = try XCTUnwrap(try context.store.importImage(from: fixture, scaling: .fill))

    XCTAssertEqual(result.pixelWidth, 1_920)
    XCTAssertEqual(result.pixelHeight, 1_080)
    XCTAssertEqual(context.store.resolveRequestedImage().availability, .available)
  }

  private struct Context {
    let baseURL: URL
    let externalURL: URL
    let suiteName: String
    let defaults: UserDefaults
    let notifications: NotificationCenter
    let store: TerminalBackgroundImageStore
  }

  private func makeContext() throws -> Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "laban-background-store-tests-\(UUID().uuidString)",
      isDirectory: true)
    roots.append(root)
    let baseURL = root.appendingPathComponent("application-support", isDirectory: true)
    let externalURL = root.appendingPathComponent("external-picker", isDirectory: true)
    try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    let suiteName = "TerminalBackgroundImageStoreTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let notifications = NotificationCenter()
    return Context(
      baseURL: baseURL,
      externalURL: externalURL,
      suiteName: suiteName,
      defaults: defaults,
      notifications: notifications,
      store: TerminalBackgroundImageStore(
        baseURL: baseURL,
        defaults: defaults,
        notificationCenter: notifications))
  }

  private func makeImage(width: Int, height: Int, color: NSColor) -> CGImage {
    let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
  }

  private func writeImage(
    _ image: CGImage,
    to url: URL,
    type: UTType,
    properties: [CFString: Any]? = nil
  ) throws {
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  private func writeAnimatedGIF(_ frames: [CGImage], to url: URL) throws {
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.gif.identifier as CFString,
        frames.count,
        nil))
    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for frame in frames {
      CGImageDestinationAddImage(
        destination,
        frame,
        [
          kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
        ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
  }

  private func managedAssetNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(TerminalBackgroundImageStore.managedAssetPrefix) }
      .sorted()
  }

  private func pixelRGBA(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)
  {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &bytes,
      width: 1,
      height: 1,
      bitsPerComponent: 8,
      bytesPerRow: 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (bytes[0], bytes[1], bytes[2], bytes[3])
  }

  private func assertActiveImage(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .image, file: file, line: line)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 1, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .image, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewCount, 1, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewKind, .image, file: file, line: line)
  }

  private func assertInactiveImage(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .none, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .none, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewKind, .none, file: file, line: line)
  }

  private func makeView() throws -> (TerminalBitmapView, AppModel) {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(fontAtlas.cellSize.width),
      cellHeight: Int(fontAtlas.cellSize.height))
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    return (view, model)
  }
}
