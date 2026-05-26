import Foundation
import LabanCore
import XCTest

final class LabandLifecycleTests: XCTestCase {
  func testVersionNegotiationContinuesWithOlderCompatibleDaemon() {
    let policy = LabandLifecyclePolicy(
      protocolSupport: LabandProtocolSupport(current: 3, minimumCompatible: 1)
    )
    let hello = LabandHelloResponse(
      protocolVersion: 2,
      minimumProtocolVersion: 1,
      buildVersion: "old-helper",
      capabilities: ["control-json/v1", "snapshot-ring/v1"]
    )

    let decision = policy.decision(hello: hello, liveSessions: [])

    guard case .connect(let protocolVersion, let compatibility, let capabilities) = decision else {
      return XCTFail("expected compatible connection decision, got \(decision)")
    }
    XCTAssertEqual(protocolVersion, 2)
    XCTAssertEqual(compatibility, .olderCompatible)
    XCTAssertEqual(capabilities, ["control-json/v1", "snapshot-ring/v1"])
  }

  func testIncompatibleDaemonWithLiveSessionsPromptsAndDefaultsToContinue() {
    let policy = LabandLifecyclePolicy(
      protocolSupport: LabandProtocolSupport(current: 3, minimumCompatible: 2)
    )
    let hello = LabandHelloResponse(
      protocolVersion: 1,
      minimumProtocolVersion: 1,
      buildVersion: "too-old-helper",
      capabilities: ["control-json/v1"]
    )
    let live = [
      LabandLiveSessionSummary(
        logicalSessionId: "tab-a",
        title: "Claude",
        commandDisplayName: "claude",
        childPid: 1234)
    ]

    let decision = policy.decision(hello: hello, liveSessions: live)

    guard case .promptBeforeUpgrade(let prompt) = decision else {
      return XCTFail("expected upgrade prompt, got \(decision)")
    }
    XCTAssertEqual(prompt.defaultChoice, .continueCurrentHelper)
    XCTAssertEqual(prompt.liveSessions, live)
    XCTAssertEqual(prompt.title, "Live terminal sessions are still running")
    XCTAssertTrue(prompt.message.contains("Continue with the current helper"))
  }

  func testIncompatibleIdleDaemonCanRestart() {
    let policy = LabandLifecyclePolicy(
      protocolSupport: LabandProtocolSupport(current: 3, minimumCompatible: 2)
    )
    let hello = LabandHelloResponse(
      protocolVersion: 1,
      minimumProtocolVersion: 1,
      buildVersion: "too-old-helper",
      capabilities: ["control-json/v1"]
    )

    let decision = policy.decision(hello: hello, liveSessions: [])

    guard case .restartIdleHelper(let reason) = decision else {
      return XCTFail("expected idle restart decision, got \(decision)")
    }
    XCTAssertTrue(reason.contains("no live sessions exist"))
  }

  func testLifecycleControllerAttemptsHelloBeforeReadingSessions() throws {
    let client = RecordingLifecycleClient(
      hello: LabandHelloResponse(
        protocolVersion: 1,
        minimumProtocolVersion: 1,
        buildVersion: "dev",
        capabilities: ["control-json/v1"]),
      sessions: [Self.liveSession()]
    )
    let controller = LabandProductLifecycleController()

    let evaluation = try controller.evaluate(client: client)

    XCTAssertEqual(client.calls, ["hello", "listSessions"])
    XCTAssertEqual(evaluation.liveSessions.map(\.logicalSessionId), ["live-tab"])
  }

  func testLaunchAgentConfigurationUsesProductPathsAndMachService() throws {
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("laban-product-\(UUID().uuidString)", isDirectory: true)
    let paths = LabandProductPaths(applicationSupportURL: base)
    let executable = base.appendingPathComponent("laband")
    let config = LabandLaunchAgentConfiguration(
      label: "dev.laban.laband.test.\(UUID().uuidString)",
      machServiceName: "dev.laban.laband.test.xpc",
      executableURL: executable,
      paths: paths
    )

    XCTAssertEqual(config.programArguments[0], executable.path)
    XCTAssertTrue(config.programArguments.contains("--product"))
    XCTAssertTrue(config.programArguments.contains("--xpc-service"))
    XCTAssertTrue(config.programArguments.contains("--journal"))
    XCTAssertTrue(config.programArguments.contains(paths.journalDirectoryURL.path))
    XCTAssertFalse(config.programArguments.contains { $0.hasPrefix(".tmp/") })
    XCTAssertFalse(config.programArguments.contains { $0.hasPrefix(".artifacts/") })

    let data = try config.propertyListData()
    let plist = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    )
    XCTAssertEqual(plist["Label"] as? String, config.label)
    XCTAssertEqual(plist["ProgramArguments"] as? [String], config.programArguments)
    let machServices = try XCTUnwrap(plist["MachServices"] as? [String: Bool])
    XCTAssertEqual(machServices[config.machServiceName], true)
  }

  private static func liveSession() -> LabandSessionInfo {
    LabandSessionInfo(
      logicalSessionId: "live-tab",
      incarnationId: "incarnation",
      childPid: 1234,
      foregroundPid: 1234,
      daemonProcessPid: 999,
      cwd: "/tmp",
      commandDisplayName: "cat",
      title: "cat",
      rows: 24,
      cols: 80,
      lifecycleState: .running,
      attachedClientCount: 1,
      leaseHolder: nil,
      transportMode: "laband"
    )
  }
}

private final class RecordingLifecycleClient: LabandLifecycleClient {
  private let helloResponse: LabandHelloResponse
  private let sessionResponses: [LabandSessionInfo]
  private(set) var calls: [String] = []

  init(hello: LabandHelloResponse, sessions: [LabandSessionInfo]) {
    self.helloResponse = hello
    self.sessionResponses = sessions
  }

  func hello() throws -> LabandHelloResponse {
    calls.append("hello")
    return helloResponse
  }

  func listSessions() throws -> [LabandSessionInfo] {
    calls.append("listSessions")
    return sessionResponses
  }
}
