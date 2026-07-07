import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp
@testable import LabanDebug

final class CommandProposalsTests: XCTestCase {
  override func setUp() {
    super.setUp()
    CommandProposalStore.shared.resetForTesting()
  }

  func testProposeReturnsExpectedShapeOnHeadlessSurface() throws {
    let runtime = try makeHeadlessRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.artifacts) }
    let sessionID = try XCTUnwrap(runtime.runtime.model.tabs.first?.sessionId)

    let server = LabanControlServer(
      router: HeadlessIntentRouter(runtime: runtime.runtime),
      surface: .headless,
      catalog: .shared)
    let socketPath = try makeTempSocketPath()
    let start = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let body = proposeBody(sessionID: sessionID, command: "echo hello")
    let (status, data) = try request(
      socketPath: start.debugServer,
      token: start.debugToken,
      body: body)
    XCTAssertEqual(status, 200)

    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["ok"] as? Bool, true)
    XCTAssertNotNil(json["proposalID"] as? String)
    XCTAssertEqual(json["targetSessionID"] as? String, sessionID)
    XCTAssertEqual(json["state"] as? String, "pendingReview")
    XCTAssertEqual(json["writtenToPTY"] as? Bool, false)
  }

  func testProposeReturnsExpectedShapeOnGuiSurface() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let sessionID = try XCTUnwrap(model.tabs.first?.sessionId)
    let router = LiveIntentRouter(model: model)

    let server = LabanControlServer(router: router, surface: .gui, catalog: .shared)
    let socketPath = try makeTempSocketPath()
    let start = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: sessionID)
    let body = proposeBody(sessionID: sessionID, command: "echo gui")
    let (status, data) = try request(
      socketPath: start.debugServer,
      token: sessionToken,
      body: body)
    XCTAssertEqual(status, 200)

    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertEqual(json["writtenToPTY"] as? Bool, false)
    XCTAssertEqual(json["state"] as? String, "pendingReview")
  }

  func testProposeDoesNotWritePTYBytesHeadless() throws {
    let runtime = try makeHeadlessRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.artifacts) }
    let sessionID = try XCTUnwrap(runtime.runtime.model.tabs.first?.sessionId)

    let before = terminalInputBytes(runtime.runtime)
    let body = proposeBody(sessionID: sessionID, command: "echo $(rm -rf /)\n")
    _ = runtime.runtime.applyAction(body)
    let after = terminalInputBytes(runtime.runtime)
    XCTAssertEqual(before, after)
  }

  func testProposeDoesNotWritePTYBytesGuiRouter() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let sessionID = try XCTUnwrap(model.tabs.first?.sessionId)

    let router = LiveIntentRouter(model: model)
    let body = proposeBody(sessionID: sessionID, command: "should-not-write")
    let response = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "command.propose",
          action: "propose",
          body: body,
          scopedSessionID: sessionID)))
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(CommandProposeResponse.self, from: response.body)
    XCTAssertFalse(decoded.writtenToPTY)
    XCTAssertEqual(decoded.state, CommandProposalState.pendingReview.rawValue)
  }

  func testCrossSessionProposeReturns403() throws {
    let model = try AppModel()
    _ = try model.createTab()
    _ = try model.createTab()
    let ownSessionID = model.tabs[0].sessionId
    let otherSessionID = model.tabs[1].sessionId
    let router = LiveIntentRouter(model: model)

    let server = LabanControlServer(router: router, surface: .gui, catalog: .shared)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: ownSessionID)
    let body = proposeBody(sessionID: otherSessionID, command: "echo cross")
    let (status, _) = try request(
      socketPath: socketPath,
      token: sessionToken,
      body: body)
    XCTAssertEqual(status, 403)
  }

  func testSafeRenderingEscapesZeroWidthSpace() {
    let rendered = CommandProposalSafeText.render("echo safe\u{200B}tail")
    XCTAssertTrue(rendered.displayText.contains("[INVIS:U+200B]"))
    XCTAssertEqual(rendered.displayText, rendered.copyText)
  }

  func testOversizedProposalRejected() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let sessionID = try XCTUnwrap(model.tabs.first?.sessionId)
    let router = LiveIntentRouter(model: model)
    let server = LabanControlServer(router: router, surface: .gui, catalog: .shared)
    let socketPath = try makeTempSocketPath()
    _ = try server.start(socketPath: socketPath)
    defer { server.stop() }

    let sessionToken = server.mintSessionObserveToken(sessionID: sessionID)
    let huge = String(repeating: "A", count: CommandProposalStore.maxCommandBytes + 1)
    let body = proposeBody(sessionID: sessionID, command: huge)
    let (status, _) = try request(
      socketPath: socketPath,
      token: sessionToken,
      body: body)
    XCTAssertEqual(status, 413)
  }

  func testSafeRenderingEscapesHiddenNewline() {
    let rendered = CommandProposalSafeText.render("echo safe\nrm -rf /")
    XCTAssertTrue(rendered.displayText.contains("\\n"))
    XCTAssertFalse(rendered.displayText.contains("\nrm"))
    XCTAssertEqual(rendered.displayText, rendered.copyText)
  }

  func testSafeRenderingEscapesBidiOverride() {
    let bidi = "echo \u{202E}evil"
    let rendered = CommandProposalSafeText.render(bidi)
    XCTAssertTrue(rendered.displayText.contains("[BIDI:RLO"))
    XCTAssertEqual(rendered.displayText, rendered.copyText)
  }

  func testSafeRenderingEscapesAnsiOsc() {
    let payload = "echo \u{1B}[31mred\u{1B}]0;https://evil.example\u{7}"
    let rendered = CommandProposalSafeText.render(payload)
    XCTAssertTrue(rendered.displayText.contains("\\e"))
    XCTAssertEqual(rendered.displayText, rendered.copyText)
  }

  func testSafeRenderingOverLengthShowsTruncationMarker() {
    let long = String(repeating: "A", count: 5000)
    let rendered = CommandProposalSafeText.render(long)
    XCTAssertTrue(rendered.truncated)
    XCTAssertTrue(rendered.displayText.contains("[TRUNCATED:"))
    XCTAssertEqual(rendered.displayText, rendered.copyText)
  }

  func testReviewRenderingCopyMatchesDisplay() {
    let proposal = CommandProposal(
      targetSessionID: "sess-1",
      command: "printf 'hi\\n'\u{202E}tail",
      purpose: "demo")
    let rendered = CommandProposalReviewRendering.renderedCopyText(for: proposal)
    XCTAssertEqual(rendered.command.displayText, rendered.command.copyText)
    XCTAssertEqual(rendered.purpose?.displayText, rendered.purpose?.copyText)
  }

  // MARK: - Helpers

  private func makeHeadlessRuntime() throws -> (runtime: HeadlessDebugRuntime, artifacts: URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-command-proposals-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "command-proposals")
    return (runtime, artifacts)
  }

  private func makeTempSocketPath() throws -> String {
    "/tmp/laban-command-proposals-\(UUID().uuidString.prefix(8)).sock"
  }

  private func proposeBody(sessionID: String, command: String) -> Data {
    let escaped =
      command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return Data(
      #"{"action":"propose","command":"\#(escaped)","purpose":"test","targetSessionID":"\#(sessionID)"}"#
        .utf8)
  }

  private func request(
    socketPath: String,
    token: String,
    body: Data
  ) throws -> (status: Int, body: Data) {
    try ControlUDSTestSupport.requestFromBackgroundThread(
      socketPath: socketPath,
      path: "/debug/actions",
      method: "POST",
      token: token,
      body: body)
  }

  private func terminalInputBytes(_ runtime: HeadlessDebugRuntime) -> Int {
    let response = runtime.metricsResponse()
    let json = try! JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    let terminalBytes = json["terminalBytes"] as! [String: Any]
    return terminalBytes["input"] as! Int
  }
}
