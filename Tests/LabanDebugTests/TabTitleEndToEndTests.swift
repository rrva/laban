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

  // MARK: - Terminal identity

  func testTermProgramIdentityReachesChildren() throws {
    // Children must see the configured identity — not one inherited from
    // whatever terminal happened to launch the Laban process. Codex picks its
    // notification backend from this variable; other tools gate progress
    // bars on it.
    TerminalIdentitySettings.set(.laban)
    defer {
      UserDefaults.standard.register(defaults: [
        TerminalIdentitySettings.defaultsKey: TerminalIdentity.ghosttyCompat.rawValue
      ])
    }
    let harness = try TitleHarness(runId: "title-e2e-term-program")
    defer { harness.tearDown() }

    try harness.runClient("titleenv 30")

    let tab = try harness.waitForTabState { $0.terminalTitle?.hasPrefix("Laban/") == true }
    let title = try XCTUnwrap(tab.terminalTitle)
    XCTAssertTrue(title.hasPrefix("Laban/"), "unexpected identity: \(title)")
    XCTAssertFalse(title.hasSuffix("/unset"), "TERM_PROGRAM_VERSION must be set: \(title)")
  }

  func testGhosttyCompatIdentityReachesChildren() throws {
    // The ghostty-compat setting claims TERM_PROGRAM=ghostty 1.3.1 so
    // identity-gated features (OSC 9;4 progress bars) light up in tools
    // that only recognize known terminals.
    TerminalIdentitySettings.set(.ghosttyCompat)
    defer {
      UserDefaults.standard.register(defaults: [
        TerminalIdentitySettings.defaultsKey: TerminalIdentity.ghosttyCompat.rawValue
      ])
    }

    let harness = try TitleHarness(runId: "title-e2e-ghostty-compat")
    defer { harness.tearDown() }

    try harness.runClient("titleenv 30")

    let tab = try harness.waitForTabState { $0.terminalTitle == "ghostty/1.3.1" }
    XCTAssertEqual(tab.terminalTitle, "ghostty/1.3.1")
  }

  func testIdentityChangeAppliesToNextTabWithoutRelaunch() throws {
    // Identity is resolved at spawn time, not captured at launch: flipping
    // the setting must reach the next new tab of the running app.
    defer {
      UserDefaults.standard.register(defaults: [
        TerminalIdentitySettings.defaultsKey: TerminalIdentity.ghosttyCompat.rawValue
      ])
    }
    TerminalIdentitySettings.set(.laban)

    let harness = try TitleHarness(runId: "title-e2e-identity-flip")
    defer { harness.tearDown() }

    TerminalIdentitySettings.set(.ghosttyCompat)
    try harness.newTab()
    try harness.runClient("titleenv 30")

    let deadline = Date().addingTimeInterval(5.0)
    var title: String?
    while title != "ghostty/1.3.1", Date() < deadline {
      harness.pumpMainQueue(0.3)
      title = try harness.syncPass(tabIndex: 1).terminalTitle
    }
    XCTAssertEqual(title, "ghostty/1.3.1")
  }

  // MARK: - Attention: agent wants the user

  func testOscNineApprovalNotificationRaisesNeedsActionOnBackgroundTab() throws {
    let harness = try TitleHarness(runId: "title-e2e-osc9")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]9;agent needs your approval\\007'\n")
    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(
      tab.attention, "needsAction",
      "an approval-flavored OSC 9 on a background tab must demand action")
  }

  func testOscNineInformationalNotificationMarksDone() throws {
    let harness = try TitleHarness(runId: "title-e2e-osc9-done")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]9;turn complete\\007'\n")
    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "done" }
    XCTAssertEqual(tab.attention, "done")
  }

  func testOsc777NotificationRaisesNeedsActionOnBackgroundTab() throws {
    let harness = try TitleHarness(runId: "title-e2e-osc777")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]777;notify;Codex;approval requested\\007'\n")
    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(tab.attention, "needsAction")
  }

  func testAwaitingInputTabStatusRaisesNeedsAction() throws {
    let harness = try TitleHarness(runId: "title-e2e-awaiting")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]21337;awaiting=1\\007'\n")
    var tab = try harness.waitForTabState { $0.awaitingInput == true }
    XCTAssertEqual(tab.awaitingInput, true)

    // An explicit empty value clears the flag; an absent key would preserve it.
    try harness.type("printf '\\033]21337;awaiting=\\007'\n")
    tab = try harness.waitForTabState { $0.awaitingInput == false }
    XCTAssertEqual(tab.awaitingInput, false)

    try harness.type("printf '\\033]21337;awaiting=1\\007'\n")
    _ = try harness.waitForTabState { $0.awaitingInput == true }
    try harness.newTab()
    tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(tab.attention, "needsAction")
  }

  func testActionRequiredTitleRaisesNeedsActionOnBackgroundTab() throws {
    // Codex's only unconditional signal in unrecognized terminals: it prefixes
    // the terminal title with "[ ! ]" while blocked on the user.
    let harness = try TitleHarness(runId: "title-e2e-action-required")
    defer { harness.tearDown() }

    try harness.runClient("osc0 '[ ! ] Action Required | codex' 30")
    _ = try harness.waitForTabState { $0.terminalTitle?.hasPrefix("[ ! ]") == true }

    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(tab.attention, "needsAction")
    XCTAssertEqual(tab.terminalTitle, "[ ! ] Action Required | codex")
  }

  // MARK: - Terminal-support spec conformance (full pipeline)

  /// Spec 9.2: an empty title payload clears the app-provided override and
  /// the tab reverts to the terminal's default title policy.
  func testEmptyTitlePayloadRevertsToDefaultTitlePolicy() throws {
    let harness = try TitleHarness(runId: "title-e2e-title-clear")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]0;Debug failing tests\\007'\n")
    let titled = try harness.waitForTabState { $0.terminalTitle == "Debug failing tests" }
    XCTAssertEqual(titled.displayTitle, "Debug failing tests")

    try harness.type("printf '\\033]0;\\007'\n")
    let cleared = try harness.waitForTabState { $0.terminalTitle == nil }
    XCTAssertNil(cleared.terminalTitle)
    XCTAssertNotEqual(cleared.displayTitle, "Debug failing tests")
    XCTAssertNotEqual(cleared.displayTitle, "")
  }

  /// Spec 9.6 + 9.7: omitted tab-status keys preserve the stored fields,
  /// empty values clear them.
  func testTabStatusOmittedFieldsPreservedAndEmptyFieldsClear() throws {
    let harness = try TitleHarness(runId: "title-e2e-status-merge")
    defer { harness.tearDown() }

    try harness.type(
      "printf '\\033]21337;indicator=#ff9500;status=Working;status-color=#ff9500\\007'\n")
    var deadline = Date().addingTimeInterval(4.0)
    while harness.agentStatus().statusText != "Working", Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }
    XCTAssertEqual(harness.agentStatus().indicatorColor, "#ff9500")

    try harness.type("printf '\\033]21337;status=Waiting\\007'\n")
    deadline = Date().addingTimeInterval(4.0)
    while harness.agentStatus().statusText != "Waiting", Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }
    let merged = harness.agentStatus()
    XCTAssertEqual(merged.statusText, "Waiting")
    XCTAssertEqual(merged.indicatorColor, "#ff9500", "omitted key must preserve the field")
    XCTAssertEqual(merged.statusTextColor, "#ff9500")

    try harness.type("printf '\\033]21337;indicator=;status=;status-color=\\007'\n")
    deadline = Date().addingTimeInterval(4.0)
    while !harness.agentStatus().isEmpty, Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }
    XCTAssertTrue(harness.agentStatus().isEmpty, "empty values must clear every field")
  }

  /// Spec 9.9-9.12: progress states reach the tab metadata and clear.
  func testProgressReportingReachesTabAndClears() throws {
    let harness = try TitleHarness(runId: "title-e2e-progress")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]9;4;1;42\\007'\n")
    var tab = try harness.waitForTabState { $0.progressState == "determinate" }
    XCTAssertEqual(tab.progressState, "determinate")
    XCTAssertEqual(tab.progressPercent, 42)

    try harness.type("printf '\\033]9;4;3;\\007'\n")
    tab = try harness.waitForTabState { $0.progressState == "indeterminate" }
    XCTAssertEqual(tab.progressState, "indeterminate")
    XCTAssertNil(tab.progressPercent)

    try harness.type("printf '\\033]9;4;2;80\\007'\n")
    tab = try harness.waitForTabState { $0.progressState == "error" }
    XCTAssertEqual(tab.progressState, "error")
    XCTAssertEqual(tab.progressPercent, 80)

    try harness.type("printf '\\033]9;4;0;\\007'\n")
    tab = try harness.waitForTabState { $0.progressState == nil }
    XCTAssertNil(tab.progressState)
  }

  /// Spec 9.13: a raw BEL on a background tab earns a quiet marker.
  func testRawBellMarksBackgroundTabPassive() throws {
    let harness = try TitleHarness(runId: "title-e2e-bell")
    defer { harness.tearDown() }

    // Arm a delayed bell, then background the tab before it rings: a bell on
    // the focused tab is intentionally silent (the user is already looking).
    try harness.type("( sleep 1; printf '\\007' ) &\n")
    try harness.newTab()

    let after = try harness.waitForTabState(timeout: 6.0) { $0.attention == "passive" }
    XCTAssertEqual(after.attention, "passive")
  }

  /// Spec 9.15 end-to-end: a kitty notification with "Permission needed"
  /// body lands as a blocking request on a background tab.
  func testKittyNotificationRaisesNeedsActionOnBackgroundTab() throws {
    let harness = try TitleHarness(runId: "title-e2e-kitty")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]99;i=123:d=0:p=title;Agent App\\007'\n")
    try harness.type("printf '\\033]99;i=123:p=body;Permission needed\\007'\n")
    try harness.newTab()
    let tab = try harness.waitForTabState { $0.attention == "needsAction" }
    XCTAssertEqual(tab.attention, "needsAction")
  }

  /// Spec 9.20: the combined cleanup sequence clears progress, tab status,
  /// and the title override.
  func testCombinedCleanupClearsEverything() throws {
    let harness = try TitleHarness(runId: "title-e2e-cleanup")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]0;Fix login bug\\007'\n")
    try harness.type(
      "printf '\\033]21337;indicator=#ff9500;status=Working;status-color=#ff9500\\007'\n")
    try harness.type("printf '\\033]9;4;3;\\007'\n")
    _ = try harness.waitForTabState {
      $0.terminalTitle == "Fix login bug" && $0.progressState == "indeterminate"
    }
    var deadline = Date().addingTimeInterval(4.0)
    while harness.agentStatus().statusText != "Working", Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }

    try harness.type("printf '\\033]9;4;0;\\007'\n")
    try harness.type("printf '\\033]21337;indicator=;status=;status-color=\\007'\n")
    try harness.type("printf '\\033]0;\\007'\n")

    let tab = try harness.waitForTabState {
      $0.terminalTitle == nil && $0.progressState == nil
    }
    XCTAssertNil(tab.terminalTitle)
    XCTAssertNil(tab.progressState)
    deadline = Date().addingTimeInterval(4.0)
    while !harness.agentStatus().isEmpty, Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }
    XCTAssertTrue(harness.agentStatus().isEmpty)
  }

  /// Spec §3: activity metadata must not outlive the session — status,
  /// awaiting-input, and progress all clear when the child exits.
  func testTabStatusAndProgressClearWhenSessionExits() throws {
    let harness = try TitleHarness(runId: "title-e2e-exit-clear")
    defer { harness.tearDown() }

    try harness.type("printf '\\033]21337;status=Working;awaiting=1\\007'\n")
    try harness.type("printf '\\033]9;4;1;42\\007'\n")
    _ = try harness.waitForTabState {
      $0.awaitingInput == true && $0.progressState == "determinate"
    }

    try harness.type("exit\n")
    let tab = try harness.waitForTabState {
      $0.awaitingInput == false && $0.progressState == nil
    }
    XCTAssertEqual(tab.awaitingInput, false)
    XCTAssertNil(tab.progressState)
    var deadline = Date().addingTimeInterval(4.0)
    while !harness.agentStatus().isEmpty, Date() < deadline {
      _ = try harness.syncPass()
      harness.pumpMainQueue()
    }
    XCTAssertTrue(harness.agentStatus().isEmpty)
    _ = deadline
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
    var attention: String?
    var awaitingInput: Bool?
    var progressState: String?
    var progressPercent: Int?
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
        titleenv) printf '\\033]0;%s/%s\\007' "${TERM_PROGRAM:-unset}" "${TERM_PROGRAM_VERSION:-unset}"; exec /bin/sleep "$1" ;;
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

  /// One explicit metadata-sync pass; returns the indexed tab's title state.
  @discardableResult
  func syncPass(tabIndex: Int = 0) throws -> TabState {
    let state = runtime.state()
    XCTAssertEqual(state.status, 200)
    let obj = try JSONSerialization.jsonObject(with: state.body) as! [String: Any]
    let tabs = obj["tabs"] as! [[String: Any]]
    let tab = tabs[tabIndex]
    let process = tab["process"] as? [String: Any]
    let agent = tab["agent"] as? [String: Any]
    let progress = tab["progress"] as? [String: Any]
    return TabState(
      displayTitle: tab["displayTitle"] as? String,
      titleSource: tab["titleSource"] as? String,
      terminalTitle: tab["terminalTitle"] as? String,
      foregroundProcess: process?["foregroundProcess"] as? String,
      attention: tab["attention"] as? String,
      awaitingInput: agent?["awaitingInput"] as? Bool,
      progressState: progress?["state"] as? String,
      progressPercent: progress?["percent"] as? Int
    )
  }

  /// Open a fresh tab (which becomes active), pushing the current tab into the
  /// background so attention classification on it becomes observable.
  func newTab() throws {
    let body = try JSONSerialization.data(withJSONObject: ["action": "newTab"])
    XCTAssertEqual(runtime.applyAction(body).status, 200)
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
      // Spin the main runloop rather than Thread.sleep: session callbacks
      // (OSC 9/777 notifications, OSC 21337 tab status) hop through the main
      // queue before they land on the model, and a blocked main thread would
      // park them forever.
      pumpMainQueue(pollInterval)
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
