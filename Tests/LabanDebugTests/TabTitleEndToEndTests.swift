import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// End-to-end tab-title coverage. A real /bin/sh PTY session runs a small
/// client script that exercises each channel that can influence a tab title
/// — OSC 0 (BEL-terminated), OSC 2 (ST-terminated), and OSC 21337 tab-status
/// — and the tests assert what the debug state endpoint reports for the tab.
///
/// In deterministic headless mode no background loop runs: every `state()`
/// call is one metadata-sync pass (PTY drain + title consume + the throttled
/// process-metadata refresh). Driving passes explicitly makes historically
/// racy behaviors — like a title being wiped because the process-identity
/// refresh landed in a different pass than the title consume — reproducible
/// on demand instead of a timing lottery.
final class TabTitleEndToEndTests: XCTestCase {

  // MARK: - OSC 0 / OSC 2 titles reach the tab and the display

  func testOscZeroTitleDisplaysWhileNonShellForeground() throws {
    let harness = try TitleHarness(runId: "title-e2e-osc0")
    defer { harness.tearDown() }

    try harness.runClient("osc0 E2E-OSC0-TITLE 30")

    let tab = try harness.waitForTabState {
      $0.terminalTitle == "E2E-OSC0-TITLE" && $0.foregroundProcess == "sleep"
    }
    XCTAssertEqual(tab.terminalTitle, "E2E-OSC0-TITLE")
    XCTAssertEqual(tab.foregroundProcess, "sleep")
    XCTAssertEqual(tab.displayTitle, "E2E-OSC0-TITLE")
    XCTAssertEqual(tab.titleSource, "terminal")
  }

  func testOscTwoStTerminatedTitleDisplays() throws {
    let harness = try TitleHarness(runId: "title-e2e-osc2st")
    defer { harness.tearDown() }

    try harness.runClient("osc2st E2E-OSC2-TITLE 30")

    let tab = try harness.waitForTabState {
      $0.terminalTitle == "E2E-OSC2-TITLE" && $0.foregroundProcess == "sleep"
    }
    XCTAssertEqual(tab.terminalTitle, "E2E-OSC2-TITLE")
    XCTAssertEqual(tab.displayTitle, "E2E-OSC2-TITLE")
    XCTAssertEqual(tab.titleSource, "terminal")
  }

  // MARK: - Title survives foreground-identity flutter

  func testFreshTitleSurvivesProcessIdentityRefresh() throws {
    // The historical "title lottery": a title consumed during a pass whose
    // process-metadata refresh was throttled got attributed to a stale owner,
    // and the next refresh — seeing a different foreground identity — wiped
    // it. Whether a tab kept its title depended on which pass the title bytes
    // landed in. With ownership-liveness wipes it must survive both orders.
    let harness = try TitleHarness(runId: "title-e2e-lottery")
    defer { harness.tearDown() }

    // Anchor the throttle window on a fresh, unthrottled pass.
    Thread.sleep(forTimeInterval: 0.3)
    _ = try harness.syncPass()

    try harness.runClient("osc0 E2E-LOTTERY-TITLE 30")

    // Consume the title inside the throttle window: this pass skips the
    // process refresh, so the title is attributed to the pre-launch identity.
    Thread.sleep(forTimeInterval: 0.15)
    _ = try harness.syncPass()

    // Let the throttle elapse, then refresh: the foreground is now /bin/sleep,
    // a different identity than the recorded owner — which is still alive.
    Thread.sleep(forTimeInterval: 0.3)
    let tab = try harness.syncPass()
    XCTAssertEqual(
      tab.terminalTitle, "E2E-LOTTERY-TITLE",
      "a fresh title must survive a foreground-identity refresh while its owner lives")

    let settled = try harness.waitForTabState {
      $0.displayTitle == "E2E-LOTTERY-TITLE" && $0.foregroundProcess == "sleep"
    }
    XCTAssertEqual(settled.displayTitle, "E2E-LOTTERY-TITLE")
  }

  func testLiveTitleDisplaysWhileShellIsForeground() throws {
    // The regression that made agent tabs anonymous: a title set while the
    // foreground process classifies as a shell was demoted below the cwd
    // folder name, so every tab in the same directory looked identical even
    // though a rich OSC title had been received and stored.
    let harness = try TitleHarness(runId: "title-e2e-shell-fg")
    defer { harness.tearDown() }

    // Set the title from the interactive shell itself: the foreground stays
    // /bin/sh the whole time, so the title's only path to the sidebar is
    // winning the precedence fight against the cwd.
    try harness.type("printf '\\033]0;E2E-SHELL-FG-TITLE\\007'\n")

    let tab = try harness.waitForTabState {
      $0.terminalTitle == "E2E-SHELL-FG-TITLE" && $0.foregroundProcess == "sh"
    }
    XCTAssertEqual(tab.terminalTitle, "E2E-SHELL-FG-TITLE")
    XCTAssertEqual(tab.displayTitle, "E2E-SHELL-FG-TITLE")
    XCTAssertEqual(tab.titleSource, "terminal")
  }

  // MARK: - OSC 21337 tab status reaches agent metadata

  func testOscTabStatusReachesAgentMetadata() throws {
    let harness = try TitleHarness(runId: "title-e2e-status")
    defer { harness.tearDown() }

    try harness.runClient(
      "status 'indicator=#00ff00;status=Compiling shaders;status-color=#ffcc00' 30")

    let deadline = Date().addingTimeInterval(4.0)
    var status = harness.agentStatus()
    while status.statusText != "Compiling shaders", Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
      status = harness.agentStatus()
    }
    XCTAssertEqual(status.indicatorColor, "#00ff00")
    XCTAssertEqual(status.statusText, "Compiling shaders")
    XCTAssertEqual(status.statusTextColor, "#ffcc00")
  }

  // MARK: - Title lifecycle around process changes

  func testTitleClearedAfterOwnerExits() throws {
    let harness = try TitleHarness(runId: "title-e2e-owner-exit")
    defer { harness.tearDown() }

    try harness.runClient("osc0 E2E-EXIT-TITLE 1")

    let live = try harness.waitForTabState { $0.terminalTitle == "E2E-EXIT-TITLE" }
    XCTAssertEqual(live.terminalTitle, "E2E-EXIT-TITLE")

    // After /bin/sleep exits the foreground returns to the interactive shell;
    // the title's owner is gone, so the title must be cleared.
    let cleared = try harness.waitForTabState {
      $0.terminalTitle == nil && $0.foregroundProcess == "sh"
    }
    XCTAssertNil(cleared.terminalTitle)
    XCTAssertNotEqual(cleared.displayTitle, "E2E-EXIT-TITLE")
  }
}

/// Shared driver for the title E2E tests: one deterministic real-shell
/// headless runtime plus the on-disk client script.
final class TitleHarness {
  let runtime: HeadlessDebugRuntime
  private let artifacts: URL
  private let clientDir: URL
  let clientScript: URL

  struct TabState {
    var displayTitle: String?
    var titleSource: String?
    var terminalTitle: String?
    var foregroundProcess: String?
  }

  init(runId: String) throws {
    artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-title-e2e-\(UUID().uuidString)")
    runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: runId,
      sessionMode: .realShell
    )
    clientDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-title-client-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: clientDir, withIntermediateDirectories: true)
    clientScript = clientDir.appendingPathComponent("title-client.sh")
    let body = """
      #!/bin/sh
      # Tab-title E2E client: each subcommand exercises one channel that can
      # influence a Laban tab title, then parks in a deterministic foreground
      # state (`exec` keeps the pid stable so the foreground identity settles).
      set -eu
      mode="$1"; shift
      case "$mode" in
        osc0)   printf '\\033]0;%s\\007' "$1"; exec /bin/sleep "$2" ;;
        osc2st) printf '\\033]2;%s\\033\\\\' "$1"; exec /bin/sleep "$2" ;;
        status) printf '\\033]21337;%s\\007' "$1"; exec /bin/sleep "$2" ;;
        *)      echo "unknown mode: $mode" >&2; exit 64 ;;
      esac
      """
    try body.write(to: clientScript, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: clientScript.path)
  }

  func tearDown() {
    try? FileManager.default.removeItem(at: artifacts)
    try? FileManager.default.removeItem(at: clientDir)
  }

  func type(_ text: String) throws {
    let body = try JSONSerialization.data(
      withJSONObject: ["action": "typeText", "text": text])
    XCTAssertEqual(runtime.applyAction(body).status, 200)
  }

  /// Type a client-script invocation into the interactive shell.
  func runClient(_ arguments: String) throws {
    try type("sh \(clientScript.path) \(arguments)\n")
  }

  /// One explicit metadata-sync pass; returns the first tab's title state.
  @discardableResult
  func syncPass() throws -> TabState {
    let state = runtime.state()
    XCTAssertEqual(state.status, 200)
    let obj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = obj["tabs"] as! [[String: Any]]
    let tab = tabs[0]
    let process = tab["process"] as? [String: Any]
    return TabState(
      displayTitle: tab["displayTitle"] as? String,
      titleSource: tab["titleSource"] as? String,
      terminalTitle: tab["terminalTitle"] as? String,
      foregroundProcess: process?["foregroundProcess"] as? String
    )
  }

  /// Drive sync passes spaced wider than the process-metadata throttle so
  /// every pass refreshes the foreground identity before consuming titles.
  func waitForTabState(
    timeout: TimeInterval = 5.0,
    pollInterval: TimeInterval = 0.3,
    until predicate: (TabState) -> Bool
  ) throws -> TabState {
    let deadline = Date().addingTimeInterval(timeout)
    var last = try syncPass()
    while !predicate(last), Date() < deadline {
      Thread.sleep(forTimeInterval: pollInterval)
      last = try syncPass()
    }
    return last
  }

  /// OSC 21337 updates hop through the main queue before they land on the
  /// model; spin the runloop briefly so the hop completes.
  func pumpMainQueue(_ interval: TimeInterval = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(interval))
  }

  func agentStatus() -> TabAgentStatus {
    runtime.model.tabs.first?.titleMetadata.agentStatus ?? TabAgentStatus()
  }
}
