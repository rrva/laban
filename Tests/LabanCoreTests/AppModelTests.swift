import LabanTerminalCore
import XCTest

@testable import LabanCore

private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
  try Session.fixture(size: size)
}

private func makeModel(rows: Int32 = 24, cols: Int32 = 80) throws -> AppModel {
  var size = LabanTerminalSize()
  size.rows = rows
  size.cols = cols
  return try AppModel(initialSize: size, sessionFactory: fixtureFactory)
}

final class AppModelTests: XCTestCase {

  func testInitialModelHasOneActiveTabAndSession() throws {
    let model = try makeModel()
    XCTAssertEqual(model.tabs.count, 1)
    XCTAssertEqual(model.tabs[0].position, 1)
    XCTAssertTrue(model.tabs[0].isActive)
    let session = model.session(forTab: model.tabs[0].id)
    XCTAssertNotNil(session)
    XCTAssertFalse(session!.isClosed)
  }

  func testCreateTabAddsTabAndSelectsIt() throws {
    let model = try makeModel()
    let originalId = model.tabs[0].id
    let newTab = try model.createTab()
    XCTAssertEqual(model.tabs.count, 2)
    XCTAssertTrue(newTab.isActive)
    XCTAssertFalse(model.tabs[0].isActive, "first tab should be deselected after createTab")
    XCTAssertEqual(model.tabs[0].id, originalId, "original tab id must not change")
  }

  func testSelectTabChangesActiveTab() throws {
    let model = try makeModel()
    try model.createTab()
    let firstId = model.tabs[0].id
    model.selectTab(firstId)
    XCTAssertTrue(model.tabs[0].isActive)
    XCTAssertFalse(model.tabs[1].isActive)
  }

  func testHiddenSessionIdentitySurvivesSelection() throws {
    let model = try makeModel()
    let firstTabId = model.tabs[0].id
    let firstSessionId = model.tabs[0].sessionId
    try model.createTab()
    // Switch back to first tab
    model.selectTab(firstTabId)
    XCTAssertEqual(
      model.tabs[0].sessionId, firstSessionId,
      "session id must not change across selection")
    let session = model.session(forTab: firstTabId)
    XCTAssertNotNil(session)
    XCTAssertFalse(session!.isClosed)
  }

  func testCloseTabRemovesTabAndDestroysSession() throws {
    let model = try makeModel()
    try model.createTab()
    let secondTabId = model.tabs[1].id
    let secondSessionId = model.tabs[1].sessionId
    // Grab session reference before close
    let sessionRef = model.session(forTab: secondTabId)!
    try model.closeTab(secondTabId)
    XCTAssertEqual(model.tabs.count, 1)
    XCTAssertTrue(sessionRef.isClosed, "session must be closed when tab is removed")
    XCTAssertNil(model.session(forTab: secondTabId))
    _ = secondSessionId  // used above
  }

  func testFinalTabReplacement() throws {
    let model = try makeModel()
    let originalTabId = model.tabs[0].id
    let originalSessionId = model.tabs[0].sessionId
    let originalSessionRef = model.session(forTab: originalTabId)!
    try model.closeTab(originalTabId)
    XCTAssertEqual(model.tabs.count, 1, "still one tab after closing last")
    XCTAssertTrue(model.tabs[0].isActive)
    XCTAssertNotEqual(model.tabs[0].id, originalTabId, "new tab must have new id")
    XCTAssertNotEqual(model.tabs[0].sessionId, originalSessionId, "new session id")
    XCTAssertTrue(originalSessionRef.isClosed, "original session must be destroyed")
  }

  func testMaxNineEnforcement() throws {
    let model = try makeModel()
    for _ in 2...AppModel.maxTabs {
      try model.createTab()
    }
    XCTAssertEqual(model.tabs.count, AppModel.maxTabs)
    XCTAssertThrowsError(try model.createTab()) { error in
      XCTAssertEqual(error as? AppError, AppError.tabLimitReached)
    }
  }

  func testTitleUpdatePreservesIdentity() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    let sessionId = model.tabs[0].sessionId
    try model.updateTitle("zsh", forTab: tabId)
    XCTAssertEqual(model.tabs[0].title, "zsh")
    XCTAssertEqual(model.tabs[0].id, tabId, "tab id unchanged after title update")
    XCTAssertEqual(model.tabs[0].sessionId, sessionId, "session id unchanged after title update")
  }

  func testResizeAppliesToBackgroundSessions() throws {
    let model = try makeModel(rows: 24, cols: 80)
    try model.createTab()
    // Select first tab so second is background
    model.selectTab(model.tabs[0].id)
    model.resize(viewportWidth: 800, viewportHeight: 600, cellWidth: 10, cellHeight: 20)
    // Both sessions must still be alive and accept a snapshot with updated dims
    for tab in model.tabs {
      guard let session = model.session(forTab: tab.id) else {
        XCTFail("session missing for tab \(tab.id)")
        continue
      }
      XCTAssertFalse(session.isClosed)
      let snap = session.snapshot()
      defer { laban_snapshot_destroy(snap) }
      XCTAssertNotNil(snap, "snapshot must be non-nil after resize")
      XCTAssertEqual(snap!.pointee.rows, 30, "rows = 600/20")
      XCTAssertEqual(snap!.pointee.cols, 80, "cols = 800/10")
    }
  }

  func testStaleSessionHandlesNotUsedAfterClose() throws {
    let model = try makeModel()
    try model.createTab()
    let firstTabId = model.tabs[0].id
    let sessionRef = model.session(forTab: firstTabId)!
    try model.closeTab(firstTabId)
    XCTAssertTrue(sessionRef.isClosed)
    // All guarded methods must return sentinel values, not crash
    XCTAssertEqual(sessionRef.poll(), -1)
    XCTAssertEqual(sessionRef.write([0x41]), -1)
    var s = LabanTerminalSize()
    s.rows = 10
    s.cols = 10
    XCTAssertEqual(sessionRef.resize(s), -1)
    XCTAssertNil(sessionRef.snapshot())
  }

  func testPositionsAfterCloseMiddleTab() throws {
    let model = try makeModel()
    try model.createTab()
    try model.createTab()
    XCTAssertEqual(model.tabs.count, 3)
    let middleId = model.tabs[1].id
    try model.closeTab(middleId)
    XCTAssertEqual(model.tabs.count, 2)
    XCTAssertEqual(model.tabs[0].position, 1)
    XCTAssertEqual(model.tabs[1].position, 2)
  }
}
