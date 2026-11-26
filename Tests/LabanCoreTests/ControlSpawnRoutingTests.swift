import Foundation
import XCTest

@testable import LabanCore

final class ControlSpawnRoutingTests: XCTestCase {
  private func plan(
    _ intentID: String, _ body: String, scoped: String? = "own", active: String? = "active",
    directories: Set<String> = ["/tmp"]
  ) -> Result<ControlSpawnPlan, ControlSpawnRouting.Rejection> {
    ControlSpawnRouting.plan(
      intentID: intentID, body: Data(body.utf8), scopedSessionID: scoped,
      activeSessionID: active, directoryExists: { directories.contains($0) })
  }

  func testTabRunsArgvInTheGivenDirectory() throws {
    let result = try plan(
      "session.spawnTab",
      #"{"action":"spawnTab","argv":["make","test"],"cwd":"/tmp","label":" build ","focus":false}"#
    ).get()
    XCTAssertEqual(result.placement, .tab)
    XCTAssertEqual(result.argv, ["make", "test"])
    XCTAssertEqual(result.cwd, "/tmp")
    XCTAssertEqual(result.label, "build")
    XCTAssertFalse(result.focus)
  }

  func testNoArgvMeansLoginShellAndFocusDefaultsOn() throws {
    let result = try plan("session.spawnTab", #"{"action":"spawnTab"}"#).get()
    XCTAssertEqual(result.argv, [])
    XCTAssertTrue(result.focus)
  }

  func testScopedSplitAlwaysDividesTheCallersOwnPane() throws {
    let result = try plan("session.spawnSplit", #"{"action":"spawnSplit","direction":"down"}"#)
      .get()
    XCTAssertEqual(result.placement, .down)
    XCTAssertEqual(result.placement.paneAxis, .horizontal)
    XCTAssertEqual(result.anchorSessionID, "own", "never the active pane for a scoped caller")
  }

  func testSplitDefaultsRight() throws {
    let result = try plan("session.spawnSplit", #"{"action":"spawnSplit"}"#).get()
    XCTAssertEqual(result.placement, .right)
    XCTAssertEqual(result.placement.paneAxis, .vertical)
  }

  func testUnscopedSplitFallsBackToTheActivePane() throws {
    let result = try plan("session.spawnSplit", #"{"action":"spawnSplit"}"#, scoped: nil).get()
    XCTAssertEqual(result.anchorSessionID, "active")
  }

  func testRefusals() {
    let cases: [(String, String, Int)] = [
      ("session.spawnSplit", #"{"action":"spawnSplit","direction":"left"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","direction":"down"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","cwd":"relative/dir"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","cwd":"/missing"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","argv":[""]}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","label":"a\u001b[31mb"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","label":"a‮b"}"#, 400),
      ("session.spawnTab", #"{"action":"spawnTab","argv":"make"}"#, 400),
      ("terminal.typeText", #"{"action":"typeText"}"#, 400),
    ]
    for (intent, body, status) in cases {
      guard case .failure(let rejection) = plan(intent, body) else {
        XCTFail("expected refusal for \(body)")
        continue
      }
      XCTAssertEqual(rejection.status, status, body)
    }
  }

  func testOversizedArgvIsRefused() {
    let argv = Array(repeating: "x", count: ControlSpawnRouting.maxArgvCount + 1)
    let body = String(
      data: try! JSONEncoder().encode(ControlSpawnRequest(action: "spawnTab", argv: argv)),
      encoding: .utf8)!
    guard case .failure(let rejection) = plan("session.spawnTab", body) else {
      return XCTFail("expected refusal")
    }
    XCTAssertEqual(rejection.status, 413)
  }

  func testNoticeNamesTheCommandSafely() {
    XCTAssertEqual(
      ControlSpawnRouting.noticeText(argv: ["/usr/bin/make", "test"]),
      "Opened by a program: make")
    XCTAssertEqual(ControlSpawnRouting.noticeText(argv: []), "Opened by a program: shell")
    XCTAssertEqual(
      ControlSpawnRouting.noticeText(argv: ["evil\u{1b}[2J"]), "Opened by a program: command")
  }

  func testRateLimiterCapsBurstsAndRecovers() {
    var limiter = ControlSpawnRateLimiter()
    let start = Date(timeIntervalSince1970: 1000)
    for _ in 0..<ControlSpawnRateLimiter.limit {
      XCTAssertTrue(limiter.admit(now: start))
    }
    XCTAssertFalse(limiter.admit(now: start.addingTimeInterval(1)))
    XCTAssertTrue(limiter.admit(now: start.addingTimeInterval(ControlSpawnRateLimiter.window)))
  }
}
