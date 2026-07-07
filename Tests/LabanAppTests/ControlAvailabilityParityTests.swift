import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanApp

/// Availability parity for the GUI surface: every op the catalog marks
/// `availability.gui == true` must be implemented by `LiveIntentRouter` (C8 —
/// "gui:true only where LiveIntentRouter implements"). The headless half of the
/// parity is enforced by `HeadlessIntentRouterTests` + `scripts/test-e2e`.
final class ControlAvailabilityParityTests: XCTestCase {
  private static let liveImplementedIntentIDs: Set<String> = [
    "app.state",
    "app.stateSummary",
    "app.accessibility",
    "terminal.modes",
    "find.state",
    "shellIntegration.state",
    "scrollIndicator.state",
    "session.list",
    "session.detail",
    "selection.read",
    "terminal.scrollViewport",
    "command.propose",
    "debug.discovery",
    "debug.capabilities",
    "debug.health",
    DebugActionIntentID.unsupported,
  ]

  func testLiveRouterImplementsEveryGUIAvailableOp() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let router = LiveIntentRouter(model: model)

    let guiIDs = Set(
      IntentCatalog.all.descriptors
        .filter(\.availability.gui)
        .map(\.id))
    XCTAssertEqual(guiIDs, Self.liveImplementedIntentIDs)

    XCTAssertLessThan(router.query(.state).status, 400)

    let scrollBody = Data(
      #"{"action":"scrollViewport","deltaRows":1}"#.utf8)
    let scroll = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "terminal.scrollViewport",
          action: "scrollViewport",
          body: scrollBody)))
    XCTAssertLessThan(scroll.status, 400)

    let proposeBody = Data(
      #"{"action":"propose","command":"echo hi","targetSessionID":"\#(model.tabs[0].sessionId)"}"#
        .utf8)
    let propose = router.route(
      .legacyDebugAction(
        LegacyDebugActionInput(
          intentID: "command.propose",
          action: "propose",
          body: proposeBody,
          scopedSessionID: model.tabs[0].sessionId)))
    XCTAssertLessThan(propose.status, 400)

    XCTAssertGreaterThanOrEqual(
      router.route(.tabSelect(TabSelectInput(tabId: "missing-tab"))).status,
      400)
  }
}
