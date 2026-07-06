import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

final class ControlSecurityFloorTests: XCTestCase {
  private final class IndicatorSpy: ControlAgentAttachedIndicatorHost {
    var active = false
    func setAgentAttachedIndicatorActive(_ active: Bool) {
      self.active = active
    }
  }

  func testPrivilegedRequestLightsIndicatorAndWritesAudit() throws {
    let indicator = IndicatorSpy()
    let coordinator = ControlSecurityCoordinator(indicatorHost: indicator)
    let (model, router, sessionID, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(
      router: router, surface: .gui, securityObserver: coordinator)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: sessionID)
    let (status, _) = try request(
      socketPath: socketPath,
      path: "/debug/selection",
      token: sessionToken)
    XCTAssertEqual(status, 200)

    let indicatorLit = expectation(description: "indicator")
    DispatchQueue.main.async {
      if indicator.active { indicatorLit.fulfill() }
    }
    wait(for: [indicatorLit], timeout: 2)

    let audit = expectation(description: "audit")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
      if Self.latestEventLogEntry(matching: "control.privileged") != nil {
        audit.fulfill()
      }
    }
    wait(for: [audit], timeout: 2)

    let entry = try XCTUnwrap(Self.latestEventLogEntry(matching: "control.privileged"))
    XCTAssertEqual(entry["intent"] as? String, "selection.read")
    XCTAssertEqual(entry["capability"] as? String, Capability.observeSensitive.rawValue)
    XCTAssertEqual(entry["surface"] as? String, "gui")
    XCTAssertEqual(entry["session"] as? String, sessionID)
    XCTAssertNil(entry["token"])
  }

  func testDisableSwitchStopsServerAndRemovesControlJSON() throws {
    let controlDir = try makeTempControlDirectory()
    defer {
      try? FileManager.default.removeItem(at: controlDir)
      ControlServerSettings.set(true)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }
    unsetenv(ControlEnvironmentKeys.controlServerForceDisable)

    let controller = MainWindowController(window: NSWindow())
    let model = try AppModel()
    controller.startControlServer(model: model)

    let controlJSON = controlDir.appendingPathComponent("control.json")
    XCTAssertTrue(FileManager.default.fileExists(atPath: controlJSON.path))
    XCTAssertNotNil(controller.controlServer)

    let socketPath = controlDir.appendingPathComponent("control.sock").path
    _ = try ControlUDSClient.connect(socketPath: socketPath)

    controller.disableControlServer()
    XCTAssertFalse(ControlServerSettings.isEnabled)
    XCTAssertNil(controller.controlServer)
    XCTAssertFalse(FileManager.default.fileExists(atPath: controlJSON.path))

    XCTAssertThrowsError(try ControlUDSClient.connect(socketPath: socketPath))
  }

  func testSettingsToggleOffPreventsServerStart() {
    let prior = ControlServerSettings.isEnabled
    defer {
      ControlServerSettings.set(prior)
      unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    }

    unsetenv(ControlEnvironmentKeys.controlServerForceDisable)
    ControlServerSettings.set(false)
    XCTAssertFalse(MainWindowController.shouldMountControlServer())

    ControlServerSettings.set(true)
    XCTAssertTrue(MainWindowController.shouldMountControlServer())

    setenv(ControlEnvironmentKeys.controlServerForceDisable, "0", 1)
    XCTAssertFalse(MainWindowController.shouldMountControlServer())
  }

  func testMintedTokensNeverAppearInLogs() throws {
    let controlDir = try makeTempControlDirectory()
    defer { try? FileManager.default.removeItem(at: controlDir) }

    let coordinator = ControlSecurityCoordinator(indicatorHost: nil)
    let (model, router, sessionID, _) = try makeModelRouterAndSessions()
    _ = model
    let server = LabanControlServer(
      router: router, surface: .gui, securityObserver: coordinator)
    let start = try server.start()
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: sessionID)
    try ControlAdvertisement.write(
      url: start.socketPath,
      token: start.appObserveToken,
      pid: ProcessInfo.processInfo.processIdentifier,
      runId: "security-floor-test")

    _ = try request(
      socketPath: start.socketPath,
      path: "/debug/state",
      token: start.appObserveToken)
    _ = try request(
      socketPath: start.socketPath,
      path: "/debug/selection",
      token: sessionToken)

    AppLog.app.info("control server started at \(start.socketPath)")
    try awaitLogFlush()

    let controlJSON = try Data(
      contentsOf: controlDir.appendingPathComponent("control.json"))
    let controlPayload =
      try JSONSerialization.jsonObject(with: controlJSON) as! [String: Any]
    XCTAssertEqual(controlPayload["token"] as? String, start.appObserveToken)

    let searchable = try Self.collectSearchableArtifacts(excludingControlJSONAt: controlDir)
    for token in [start.appObserveToken, sessionToken] {
      for (path, contents) in searchable where contents.contains(token) {
        XCTFail("token leaked into \(path.lastPathComponent)")
      }
    }
  }

  private func makeModelRouterAndSessions() throws -> (
    AppModel, LiveIntentRouter, String, String
  ) {
    let model = try AppModel()
    _ = try model.createTab()
    let tabs = model.tabs
    XCTAssertGreaterThanOrEqual(tabs.count, 2)
    let ownSessionID = tabs[0].sessionId
    let otherSessionID = tabs[1].sessionId
    let router = LiveIntentRouter(model: model)
    return (model, router, ownSessionID, otherSessionID)
  }

  private func makeTempControlDirectory() throws -> URL {
    let name = String(UUID().uuidString.prefix(8))
    let dir = URL(fileURLWithPath: "/tmp/laban-ctl-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    setenv("LABAN_CONTROL_DIR", dir.path, 1)
    return dir
  }

  private func makeTempSocketPath() throws -> String {
    let dir = try makeTempControlDirectory()
    return dir.appendingPathComponent("c.sock").path
  }

  private func request(
    socketPath: String,
    path: String,
    method: String = "GET",
    token: String? = nil,
    body: Data? = nil
  ) throws -> (Int, Data) {
    try DispatchQueue.global(qos: .userInitiated).sync {
      try ControlUDSClient.request(
        socketPath: socketPath,
        method: method,
        path: path,
        token: token,
        body: body)
    }
  }

  private func awaitLogFlush() throws {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      usleep(50_000)
    }
  }

  private static func latestEventLogEntry(matching kind: String) -> [String: Any]? {
    let dir = EventLog.shared.directoryURL
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return nil }
    let sorted = files.sorted {
      let l =
        (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      let r =
        (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast
      return l > r
    }
    for file in sorted where file.pathExtension == "jsonl" {
      guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
      else { continue }
      for line in text.split(separator: "\n").reversed() {
        guard
          let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          object["kind"] as? String == kind
        else { continue }
        return object
      }
    }
    return nil
  }

  private static func collectSearchableArtifacts(excludingControlJSONAt controlDir: URL) throws
    -> [(URL, String)]
  {
    var results: [(URL, String)] = []
    let roots = [
      LogFile.shared.directoryURL,
      EventLog.shared.directoryURL,
      controlDir,
    ]
    let skipNames: Set<String> = ["control.json"]
    for root in roots {
      guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in enumerator {
        if skipNames.contains(url.lastPathComponent) { continue }
        guard let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8)
        else { continue }
        results.append((url, text))
      }
    }
    return results
  }
}
