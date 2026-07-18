import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

@MainActor
final class TerminalWindowTransparencyCoordinatorTests: XCTestCase {
  private var suiteNames: [String] = []
  private var savedRenderer: String?

  override func setUp() {
    super.setUp()
    savedRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
  }

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    if let savedRenderer {
      setenv("LABAN_RENDERER", savedRenderer, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    super.tearDown()
  }

  func testInitialPolicyConfiguresClearNonopaqueWindowBeforePresentation() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.setBackgroundOpacity(
      0.7,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()

    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported)

    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(window.isOpaque)
    XCTAssertEqual(window.backgroundColor, .clear)
    XCTAssertEqual(coordinator.status.requested.backgroundOpacity, 0.7)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 0.7)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0)
    XCTAssertEqual(view.transparencyDiagnostics.effectiveTransparencyApplyCount, 1)
    XCTAssertEqual(view.transparencyDiagnostics.transparencyRenderWakeCount, 0)
  }

  func testInstalledHostPreservesOpaqueNoEffectDefault() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let view = try makeView()
    let window = NSWindow()
    let container = NSView(frame: view.bounds)
    let host = TerminalBackgroundEffectHost(frame: .zero)
    host.install(in: container, terminalLeadingInset: SidebarLayout.defaultWidth)

    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported,
      backgroundEffectHost: host)

    XCTAssertEqual(coordinator.status.requested.backgroundOpacity, 1)
    XCTAssertEqual(coordinator.status.requested.backdropStyle, .none)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 1)
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .none)
    XCTAssertTrue(window.isOpaque)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0)
    XCTAssertTrue(host.subviews.isEmpty)
  }

  func testSystemBlurRequiresInstalledHostCapability() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.72,
      applyToExplicitCellBackgrounds: false,
      backdropStyle: .systemBlur)
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()

    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported)

    XCTAssertEqual(coordinator.status.requested.backdropStyle, .systemBlur)
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .none)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0)
  }

  func testImageAvailabilityFailsClosedThenRestoresWithoutChangingRequest() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.67,
      applyToExplicitCellBackgrounds: false,
      backdropStyle: .image,
      backgroundImageScaling: .fit)
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported,
      backgroundImageAvailability: .missing)

    XCTAssertEqual(coordinator.status.requested, requested)
    XCTAssertEqual(coordinator.status.backgroundImageAvailability, .missing)
    XCTAssertEqual(
      coordinator.status.effective.forceOpaqueReason, .backgroundImageUnavailable)
    XCTAssertTrue(window.isOpaque)

    coordinator.updateBackgroundImageAvailability(.available)
    XCTAssertEqual(coordinator.status.requested, requested)
    XCTAssertEqual(coordinator.status.backgroundImageAvailability, .available)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 0.67)
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .image)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason)
    XCTAssertFalse(window.isOpaque)
  }

  func testPrivateSystemBlurRadiusFollowsAllTemporaryForceOpaqueTransitions() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.72,
      applyToExplicitCellBackgrounds: false,
      backdropStyle: .systemBlur,
      backgroundBlur: 0.20)
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let container = NSView(frame: view.bounds)
    let host = TerminalBackgroundEffectHost(frame: .zero)
    host.install(in: container, terminalLeadingInset: SidebarLayout.defaultWidth)
    var blurCalls: [Int32] = []
    let blurController = TerminalWindowBlurController { _, radius in
      blurCalls.append(radius)
      return 0
    }
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported,
      backgroundEffectHost: host,
      windowBlurController: blurController)

    assertActivePrivateSystemBlur(coordinator: coordinator, host: host, radius: 20)

    notifications.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    assertInactivePrivateSystemBlur(
      coordinator: coordinator,
      host: host,
      forceOpaqueReason: .nativeFullscreen)

    notifications.post(name: NSWindow.didExitFullScreenNotification, object: window)
    assertActivePrivateSystemBlur(coordinator: coordinator, host: host, radius: 20)

    coordinator.updateReduceTransparency(true)
    assertInactivePrivateSystemBlur(
      coordinator: coordinator,
      host: host,
      forceOpaqueReason: .reduceTransparency)

    coordinator.updateReduceTransparency(false)
    assertActivePrivateSystemBlur(coordinator: coordinator, host: host, radius: 20)

    coordinator.updateSnapshotBackgroundCapability(.legacy)
    assertInactivePrivateSystemBlur(
      coordinator: coordinator,
      host: host,
      forceOpaqueReason: .legacySnapshotWriter)

    coordinator.updateSnapshotBackgroundCapability(.supported)
    assertActivePrivateSystemBlur(coordinator: coordinator, host: host, radius: 20)

    var updated = requested
    updated.backgroundBlur = 0.21
    TerminalTransparencySettings.setRequestedConfiguration(
      updated,
      defaults: defaults,
      notificationCenter: notifications)
    assertActivePrivateSystemBlur(coordinator: coordinator, host: host, radius: 21)
    XCTAssertEqual(blurCalls, [20, 0, 20, 0, 20, 0, 20, 21])
  }

  func testUnavailablePrivateBlurUsesPublicMaterialFallback() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.setRequestedConfiguration(
      TerminalTransparencyConfiguration(
        backgroundOpacity: 0.72,
        applyToExplicitCellBackgrounds: false,
        backdropStyle: .systemBlur,
        backgroundBlur: 0.20),
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let container = NSView(frame: view.bounds)
    let host = TerminalBackgroundEffectHost(frame: .zero)
    host.install(in: container, terminalLeadingInset: SidebarLayout.defaultWidth)
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported,
      backgroundEffectHost: host,
      windowBlurController: TerminalWindowBlurController(setBlurRadius: nil))

    assertActiveSystemBlur(coordinator: coordinator, host: host)
    XCTAssertFalse(coordinator.status.windowBlurAvailable)
    XCTAssertEqual(coordinator.status.windowBlurRadius, 0)

    coordinator.updateReduceTransparency(true)
    assertInactiveSystemBlur(
      coordinator: coordinator,
      host: host,
      forceOpaqueReason: .reduceTransparency)
  }

  func testFullScreenForcesOpaqueThenRestoresRequestedValues() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.64,
      applyToExplicitCellBackgrounds: true,
      backdropStyle: .none)
    TerminalTransparencySettings.setRequestedConfiguration(
      requested,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .supported)
    view.resetTransparencyDiagnostics()

    notifications.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    XCTAssertTrue(window.isOpaque)
    XCTAssertEqual(coordinator.status.requested, requested)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 1)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .nativeFullscreen)

    notifications.post(name: NSWindow.didExitFullScreenNotification, object: window)
    XCTAssertFalse(window.isOpaque)
    XCTAssertEqual(coordinator.status.requested, requested)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 0.64)
    XCTAssertTrue(coordinator.status.effective.applyToExplicitCellBackgrounds)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason)
    XCTAssertEqual(view.transparencyDiagnostics.effectiveTransparencyApplyCount, 2)
    XCTAssertEqual(view.transparencyDiagnostics.transparencyRenderWakeCount, 2)
  }

  func testForceOpaquePriorityAndCapabilityRestorationAreDeterministic() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.setBackgroundOpacity(
      0.5,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: false,
      snapshotBackgroundCapability: .legacy)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .legacySnapshotWriter)

    notifications.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .nativeFullscreen)

    coordinator.updateReduceTransparency(true)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .reduceTransparency)

    coordinator.updateReduceTransparency(false)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .nativeFullscreen)

    notifications.post(name: NSWindow.didExitFullScreenNotification, object: window)
    XCTAssertEqual(coordinator.status.effective.forceOpaqueReason, .legacySnapshotWriter)

    coordinator.updateSnapshotBackgroundCapability(.supported)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 0.5)
  }

  func testRequestedSettingsChangeWhileForcedOpaqueIsPreservedForRestoration() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.setBackgroundOpacity(
      0.8,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    let coordinator = TerminalWindowTransparencyCoordinator(
      window: window,
      terminalView: view,
      defaults: defaults,
      notificationCenter: notifications,
      reduceTransparency: true,
      snapshotBackgroundCapability: .supported)

    TerminalTransparencySettings.setBackgroundOpacity(
      0.37,
      defaults: defaults,
      notificationCenter: notifications)
    XCTAssertEqual(coordinator.status.requested.backgroundOpacity, 0.37)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 1)

    coordinator.updateReduceTransparency(false)
    XCTAssertEqual(coordinator.status.effective.backgroundOpacity, 0.37)
    XCTAssertFalse(window.isOpaque)
  }

  func testTeardownRemovesObservers() throws {
    let defaults = try makeDefaults()
    let notifications = NotificationCenter()
    TerminalTransparencySettings.setBackgroundOpacity(
      0.6,
      defaults: defaults,
      notificationCenter: notifications)
    let view = try makeView()
    let window = NSWindow()
    var coordinator: TerminalWindowTransparencyCoordinator? =
      TerminalWindowTransparencyCoordinator(
        window: window,
        terminalView: view,
        defaults: defaults,
        notificationCenter: notifications,
        reduceTransparency: false,
        snapshotBackgroundCapability: .supported)
    weak var weakCoordinator = coordinator
    XCTAssertFalse(window.isOpaque)

    coordinator = nil
    XCTAssertNil(weakCoordinator)
    notifications.post(name: NSWindow.didEnterFullScreenNotification, object: window)
    XCTAssertFalse(window.isOpaque)
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "TerminalWindowTransparencyCoordinatorTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  private func assertActivePrivateSystemBlur(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    radius: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      coordinator.status.effective.backdropStyle, .systemBlur, file: file, line: line)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .none, file: file, line: line)
    XCTAssertTrue(host.subviews.isEmpty, file: file, line: line)
    XCTAssertTrue(coordinator.status.windowBlurAvailable, file: file, line: line)
    XCTAssertEqual(coordinator.status.windowBlurRadius, radius, file: file, line: line)
  }

  private func assertInactivePrivateSystemBlur(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    forceOpaqueReason: TerminalTransparencyForceOpaqueReason,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .none, file: file, line: line)
    XCTAssertEqual(
      coordinator.status.effective.forceOpaqueReason, forceOpaqueReason, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .none, file: file, line: line)
    XCTAssertTrue(host.subviews.isEmpty, file: file, line: line)
    XCTAssertTrue(coordinator.status.windowBlurAvailable, file: file, line: line)
    XCTAssertEqual(coordinator.status.windowBlurRadius, 0, file: file, line: line)
  }

  private func assertActiveSystemBlur(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      coordinator.status.effective.backdropStyle, .systemBlur, file: file, line: line)
    XCTAssertNil(coordinator.status.effective.forceOpaqueReason, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 1, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .systemBlur, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewCount, 1, file: file, line: line)
    XCTAssertEqual(host.subviews.count, 1, file: file, line: line)
  }

  private func assertInactiveSystemBlur(
    coordinator: TerminalWindowTransparencyCoordinator,
    host: TerminalBackgroundEffectHost,
    forceOpaqueReason: TerminalTransparencyForceOpaqueReason,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(coordinator.status.effective.backdropStyle, .none, file: file, line: line)
    XCTAssertEqual(
      coordinator.status.effective.forceOpaqueReason, forceOpaqueReason, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertEqual(coordinator.status.backdropSubviewKind, .none, file: file, line: line)
    XCTAssertEqual(host.backdropSubviewCount, 0, file: file, line: line)
    XCTAssertTrue(host.subviews.isEmpty, file: file, line: line)
  }

  private func makeView() throws -> TerminalBitmapView {
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
    return view
  }
}
