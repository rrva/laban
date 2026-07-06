import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

final class ControlDefaultOnTests: XCTestCase {
  func testObserveOnByDefaultWithoutEnvOptIn() {
    let priorSettings = ControlServerSettings.isEnabled
    defer {
      ControlServerSettings.set(priorSettings)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }
    unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    ControlServerSettings.set(true)
    XCTAssertTrue(MainWindowController.shouldMountControlServer())
  }

  func testForceDisableEnvVarBlocksDefaultOnMount() {
    let priorSettings = ControlServerSettings.isEnabled
    defer {
      ControlServerSettings.set(priorSettings)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }
    ControlServerSettings.set(true)
    setenv(ControlEnvironmentKeys.controlServerForceDisable, "0", 1)
    XCTAssertFalse(MainWindowController.shouldMountControlServer())
  }

  func testSettingsToggleWinsOverDefaultOn() {
    let priorSettings = ControlServerSettings.isEnabled
    defer {
      ControlServerSettings.set(priorSettings)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }
    unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    ControlServerSettings.set(false)
    XCTAssertFalse(MainWindowController.shouldMountControlServer())
  }

  func testFreshLaunchWritesObserveOnlyControlJSON() throws {
    let controlDir = try makeTempControlDirectory()
    defer {
      try? FileManager.default.removeItem(at: controlDir)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }
    unsetenv(ControlEnvironmentKeys.controlServerForceDisable)

    let server = LabanControlServer(router: SpyDefaultOnRouter(), surface: .gui)
    let start = try server.start()
    defer { server.stop() }
    try ControlAdvertisement.write(
      url: start.socketPath,
      token: start.appObserveToken,
      pid: ProcessInfo.processInfo.processIdentifier,
      runId: "default-on-test")

    let controlJSON = controlDir.appendingPathComponent("control.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: controlJSON.path))
    let data = try Data(contentsOf: controlJSON)
    let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let token = try XCTUnwrap(payload["token"] as? String)
    XCTAssertEqual(token, start.appObserveToken)
    XCTAssertEqual(payload["url"] as? String, start.socketPath)

    let (sensitiveStatus, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/selection",
      token: token)
    XCTAssertEqual(sensitiveStatus, 403)
  }

  func testNormalLaunchContextHasControlURLButNoAttachBootstrap() throws {
    let coordinator = ControlSessionLaunchCoordinator()
    let server = LabanControlServer(router: SpyDefaultOnRouter(), surface: .gui)
    let start = try server.start()
    defer { server.stop() }
    coordinator.noteControlServerStarted(server, socketPath: start.socketPath)

    let context = coordinator.prepareLaunch(tabID: "tab-1", isAgentAttached: false)
    XCTAssertEqual(context.environmentOverrides[ControlEnvironmentKeys.controlURL], start.socketPath)
    XCTAssertNil(context.environmentOverrides[ControlEnvironmentKeys.sessionAttach])
    XCTAssertNil(context.sessionObserveBootstrap)
    XCTAssertFalse(context.isAgentAttached)
  }

  func testAgentAttachedLaunchContextCarriesSingleUseBootstrap() throws {
    setenv(ControlEnvironmentKeys.attachEnvOptIn, "1", 1)
    defer { unsetenv(ControlEnvironmentKeys.attachEnvOptIn) }

    let coordinator = ControlSessionLaunchCoordinator()
    let server = LabanControlServer(router: SpyDefaultOnRouter(), surface: .gui)
    let start = try server.start()
    defer { server.stop() }
    coordinator.noteControlServerStarted(server, socketPath: start.socketPath)

    let context = coordinator.prepareLaunch(tabID: "tab-agent", isAgentAttached: true)
    let bootstrap = try XCTUnwrap(context.sessionObserveBootstrap)
    XCTAssertEqual(context.environmentOverrides[ControlEnvironmentKeys.sessionAttach], bootstrap)
    XCTAssertTrue(context.isAgentAttached)

    server.registerAttachShellPID(
      sessionID: context.sessionID,
      shellPID: ProcessInfo.processInfo.processIdentifier)

    let (firstStatus, firstBody) = try request(
      socketPath: start.socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    XCTAssertEqual(firstStatus, 200)
    let firstJSON = try JSONSerialization.jsonObject(with: firstBody) as! [String: Any]
    let sessionToken = try XCTUnwrap(firstJSON["token"] as? String)
    XCTAssertEqual(firstJSON["sessionID"] as? String, context.sessionID)

    let (secondStatus, _) = try request(
      socketPath: start.socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    XCTAssertEqual(secondStatus, 401)

    let (ownStatus, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/selection",
      token: sessionToken)
    XCTAssertEqual(ownStatus, 200)
  }

  func testAgentAttachedLaunchOmitsBootstrapWithoutEnvOptIn() throws {
    unsetenv(ControlEnvironmentKeys.attachEnvOptIn)

    let coordinator = ControlSessionLaunchCoordinator()
    let server = LabanControlServer(router: SpyDefaultOnRouter(), surface: .gui)
    let start = try server.start()
    defer { server.stop() }
    coordinator.noteControlServerStarted(server, socketPath: start.socketPath)

    let context = coordinator.prepareLaunch(tabID: "tab-agent", isAgentAttached: true)
    XCTAssertNil(context.environmentOverrides[ControlEnvironmentKeys.sessionAttach])
    XCTAssertNil(context.sessionObserveBootstrap)
    XCTAssertTrue(context.isAgentAttached)
  }

  func testAttachRedeemRequiresShellPIDRegistration() throws {
    setenv(ControlEnvironmentKeys.attachEnvOptIn, "1", 1)
    defer { unsetenv(ControlEnvironmentKeys.attachEnvOptIn) }

    let server = LabanControlServer(router: SpyDefaultOnRouter(), surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let bootstrap = server.mintSessionAttachBootstrap(sessionID: "sess-unregistered")
    let (status, _) = try request(
      socketPath: start.socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    XCTAssertEqual(status, 401)
  }

  func testPreallocatedSessionIDMatchesRedeemedScope() throws {
    let coordinator = ControlSessionLaunchCoordinator()
    let model = try AppModel(
      sessionLaunchContextProvider: { tabId, isAgentAttached in
        coordinator.prepareLaunch(tabID: tabId, isAgentAttached: isAgentAttached)
      },
      sessionFactory: { size, context in
        try Session.fixture(size: size, sessionID: context.sessionID)
      })
    let router = LiveIntentRouter(model: model)
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }
    coordinator.noteControlServerStarted(server, socketPath: start.socketPath)

    let tab = try model.createAgentAttachedTab()
    let bootstrap = server.mintSessionAttachBootstrap(sessionID: tab.sessionId)
    server.registerAttachShellPID(
      sessionID: tab.sessionId,
      shellPID: ProcessInfo.processInfo.processIdentifier)
    let (_, body) = try udsRequest(
      socketPath: start.socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(bootstrap)"}"#.utf8))
    let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    XCTAssertEqual(json["sessionID"] as? String, tab.sessionId)

    let sessionToken = try XCTUnwrap(json["token"] as? String)
    let otherTab = try model.createTab()
    let (crossStatus, _) = try udsRequest(
      socketPath: start.socketPath,
      path: "/debug/sessions/\(otherTab.sessionId)",
      token: sessionToken)
    XCTAssertEqual(crossStatus, 403)
  }

  func testControlJSONCreated0600FromFirstByte() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-ctl-perm-\(UUID().uuidString)", isDirectory: true)
    setenv("LABAN_CONTROL_DIR", dir.path, 1)
    defer {
      unsetenv("LABAN_CONTROL_DIR")
      try? FileManager.default.removeItem(at: dir)
    }

    let socketPath = dir.appendingPathComponent("control.sock").path
    try ControlAdvertisement.write(
      url: socketPath,
      token: "observe-only",
      pid: 1,
      runId: "perm-test")

    let filePath = dir.appendingPathComponent("control.json").path
    let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o600)
  }

  func testUDSDirectoryIs0700AndPeerCredRequired() throws {
    let router = SpyDefaultOnRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let dir = ControlAdvertisement.directory()
    let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o700)
    XCTAssertTrue(FileManager.default.fileExists(atPath: start.socketPath))

    let (unauthorizedStatus, _) = try request(
      socketPath: start.socketPath,
      path: "/debug/state")
    XCTAssertEqual(unauthorizedStatus, 401)
  }

  func testLiveTokensDoNotGrantInputOrClipboard() throws {
    let router = SpyDefaultOnRouter()
    let server = LabanControlServer(router: router, surface: .gui)
    let start = try server.start()
    defer { server.stop() }

    let sessionBootstrap = server.mintSessionAttachBootstrap(sessionID: "s1")
    server.registerAttachShellPID(
      sessionID: "s1",
      shellPID: ProcessInfo.processInfo.processIdentifier)
    let (_, attachBody) = try request(
      socketPath: start.socketPath,
      path: LabanControlServer.sessionAttachPath,
      method: "POST",
      body: Data(#"{"bootstrap":"\#(sessionBootstrap)"}"#.utf8))
    let attachJSON = try JSONSerialization.jsonObject(with: attachBody) as! [String: Any]
    let sessionToken = try XCTUnwrap(attachJSON["token"] as? String)

    for token in [start.appObserveToken, sessionToken] {
      let input = try request(
        socketPath: start.socketPath,
        path: "/debug/actions",
        method: "POST",
        token: token,
        body: Data(#"{"action":"typeText","text":"x"}"#.utf8))
      XCTAssertTrue([403, 404].contains(input.0), "input must be unreachable for token")

      let clipboard = try request(
        socketPath: start.socketPath,
        path: "/debug/clipboard",
        token: token)
      XCTAssertTrue([403, 404].contains(clipboard.0), "clipboard must be unreachable for token")
    }
  }

  private func makeTempControlDirectory() throws -> URL {
    let name = String(UUID().uuidString.prefix(8))
    let dir = URL(fileURLWithPath: "/tmp/laban-default-on-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("LABAN_CONTROL_DIR", dir.path, 1)
    return dir
  }

  private func request(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    try ControlUDSTestSupport.requestFromBackgroundThread(
      socketPath: socketPath,
      path: path,
      method: method,
      token: token,
      body: body)
  }

  private func udsRequest(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    try ControlUDSTestSupport.requestFromBackgroundThread(
      socketPath: socketPath,
      path: path,
      method: method,
      token: token,
      body: body)
  }
}

private final class SpyDefaultOnRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse {
    .error(404, "unavailable on gui")
  }

  func query(_ query: Query) -> ControlResponse {
    .json(["ok": true])
  }

  func query(_ query: LegacyDebugQueryInput) -> ControlResponse {
    .json(["intentID": query.intentID])
  }

  func artifact(_ request: ArtifactRequest) -> ControlResponse? {
    nil
  }
}
