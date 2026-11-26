import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// `laban split` divides the caller's own pane, not whichever pane has focus,
/// and can leave focus where it is (ADR 0024, Amendment 2026-11-26).
final class AppModelSpawnSplitTests: XCTestCase {
  private func fixture(_ id: Session.ID, _ size: LabanTerminalSize) throws -> Session {
    try Session.fixture(size: size, sessionID: id)
  }

  func testSplitDividesTheAnchorPaneAndCanKeepFocus() throws {
    let model = try AppModel()
    let tab = try XCTUnwrap(model.activeTab)
    let caller = tab.focusedSessionId
    let other = try model.splitPane(inTab: tab.id) { id, size, _ in try fixture(id, size) }
    XCTAssertEqual(model.activeTab?.focusedSessionId, other)

    let spawned = try model.splitPane(
      inTab: tab.id, axis: .horizontal, anchor: caller, focusNewPane: false
    ) { id, size, _ in try fixture(id, size) }

    let updated = try XCTUnwrap(model.tabs.first { $0.id == tab.id })
    XCTAssertEqual(updated.focusedSessionId, other, "focus stays on the pane the user had")
    XCTAssertEqual(Set(updated.allSessionIds), [caller, other, spawned])
    XCTAssertEqual(
      updated.panes,
      .split(
        axis: .vertical, fraction: 0.5,
        first: .split(
          axis: .horizontal, fraction: 0.5,
          first: .leaf(sessionId: caller), second: .leaf(sessionId: spawned)),
        second: .leaf(sessionId: other)),
      "the new pane sits under the caller's pane, not under the focused one")
  }

  func testPaneSessionWithArgvUsesTheCommandFactory() throws {
    let model = try AppModel()
    var factoryArgv: [String]?
    model.commandSessionFactory = { size, _, argv, context in
      factoryArgv = argv
      return try Session.fixture(size: size, sessionID: context.sessionID)
    }
    let tab = try XCTUnwrap(model.activeTab)
    let spawned = try model.splitPane(inTab: tab.id) { id, size, cwd in
      try model.makePaneSession(
        id: id, inTab: tab.id, size: size, cwd: cwd, argv: ["make", "test"])
    }
    XCTAssertEqual(factoryArgv, ["make", "test"])
    XCTAssertEqual(model.launchArgv(forSession: spawned), ["make", "test"])
  }
}
