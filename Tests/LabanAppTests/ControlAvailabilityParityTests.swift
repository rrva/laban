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
    "notifications.state",
    "notifications.test",
    "app.accessibility",
    "terminal.modes",
    "find.state",
    "shellIntegration.state",
    "terminal.getText",
    "window.screenshot",
    "scrollIndicator.state",
    "session.list",
    "session.detail",
    "selection.read",
    "terminal.scrollViewport",
    "command.propose",
    "commandProposal.list",
    "commandProposal.get",
    "commandProposal.cancel",
    "debug.discovery",
    "debug.capabilities",
    "debug.health",
    "transparency.state",
    "transparency.setBackground",
    "transparency.diagnostics.reset",
    "transparency.reduceTransparencyOverride.set",
    "transparency.nativeFullScreen.set",
  ]

  func testLiveRouterImplementsEveryGUIAvailableOp() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let router = LiveIntentRouter(model: model)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    router.bindWindowScreenshotProvider {
      .success(LabanWindowScreenshot(pngData: png, width: 1, height: 1))
    }
    var notificationTestCalled = false
    router.bindNotificationTestHandler { _, _ in
      notificationTestCalled = true
    }

    let guiIDs = Set(
      IntentCatalog.all.descriptors
        .filter(\.availability.gui)
        .map(\.id))
    XCTAssertEqual(guiIDs, Self.liveImplementedIntentIDs)

    XCTAssertLessThan(router.query(.state).status, 400)
    XCTAssertLessThan(
      router.query(LegacyDebugQueryInput(intentID: "notifications.state")).status,
      400)
    let notificationTest = router.control(
      LegacyDebugControlInput(
        intentID: "notifications.test",
        body: Data("{}".utf8)))
    XCTAssertEqual(notificationTest.status, 202)
    XCTAssertTrue(notificationTestCalled)

    let sessionID = try XCTUnwrap(model.activeTab?.sessionId)
    XCTAssertLessThan(
      router.query(
        LegacyDebugQueryInput(intentID: "window.screenshot", scopedSessionID: sessionID)
      ).status,
      400)

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
