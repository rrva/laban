import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class LabandUpgradePromptTests: XCTestCase {
  func testLiveSessionUpgradePromptDefaultsToContinueCurrentHelper() {
    let prompt = LabandUpgradePromptModel(
      title: "Live terminal sessions are still running",
      message: "Continue with the current helper or close selected sessions to upgrade it.",
      liveSessions: [
        LabandLiveSessionSummary(
          logicalSessionId: "tab-a",
          title: "Claude",
          commandDisplayName: "claude",
          childPid: 1234),
        LabandLiveSessionSummary(
          logicalSessionId: "tab-b",
          title: "Codex",
          commandDisplayName: "codex",
          childPid: 5678),
      ],
      defaultChoice: .continueCurrentHelper
    )

    let presentation = LabandUpgradePromptPolicy.presentation(
      for: .promptBeforeUpgrade(prompt)
    )

    XCTAssertEqual(presentation?.title, "Live terminal sessions are still running")
    XCTAssertEqual(presentation?.defaultAction, .continueCurrentHelper)
    XCTAssertEqual(
      presentation?.actions.map(\.identifier),
      [.continueCurrentHelper, .closeSessionsAndUpgrade]
    )
    XCTAssertTrue(
      presentation?.informativeText.contains("2 live terminal sessions") == true
    )
    XCTAssertTrue(
      presentation?.informativeText.contains("keep running") == true
    )
  }

  func testCompatibleOrIdleDecisionsDoNotShowUpgradePrompt() {
    XCTAssertNil(
      LabandUpgradePromptPolicy.presentation(
        for: .connect(
          protocolVersion: 1,
          compatibility: .current,
          capabilities: ["control-json/v1"]
        )
      )
    )
    XCTAssertNil(
      LabandUpgradePromptPolicy.presentation(
        for: .restartIdleHelper(reason: "no live sessions exist")
      )
    )
  }

  func testServiceManagementInstallerNamesProductLaunchAgentPlist() {
    XCTAssertEqual(
      LabandServiceManagementInstaller.launchAgentPlistName,
      "dev.laban.laband.plist"
    )
  }
}
