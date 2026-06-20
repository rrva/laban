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
  func testLiveRouterImplementsEveryGUIAvailableOp() throws {
    let model = try AppModel()
    _ = try model.createTab()
    let router = LiveIntentRouter(model: model)

    // The gui-available actions are exactly the ops LiveIntentRouter wires, plus
    // the unknown-action fallback. If a new action is marked gui:true without a
    // live implementation, this set assertion fails before the dispatch loop does.
    let guiActionIDs = Set(
      IntentCatalog.all.descriptors
        .filter { $0.kind == .action && $0.availability.gui }
        .map(\.id))
    XCTAssertEqual(
      guiActionIDs,
      ["tab.select", "terminal.typeText", "terminal.sendKey", DebugActionIntentID.unsupported])

    // app.state is the gui-available query.
    XCTAssertLessThan(router.query(.state).status, 400)

    let actions: [Intent] = [
      .tabSelect(TabSelectInput(index: 0)),
      .terminalTypeText(TypeTextInput(text: "parity")),
      .terminalSendKey(SendKeyInput(key: "a")),
    ]
    for intent in actions {
      XCTAssertLessThan(router.route(intent).status, 400, intent.id)
    }

    // The unknown-action fallback is gui-available, but its contract is to fail.
    XCTAssertGreaterThanOrEqual(
      router.route(.unsupportedDebugAction(UnsupportedDebugActionInput(action: "nope"))).status,
      400)
  }
}
