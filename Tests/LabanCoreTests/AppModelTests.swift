import Darwin
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

private func canonicalPath(_ path: String) -> String {
  path.withCString { cPath in
    guard let resolved = realpath(cPath, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
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

  func testFinalTabClosedThrows() throws {
    let model = try makeModel()
    let originalTabId = model.tabs[0].id
    let originalSessionRef = model.session(forTab: originalTabId)!
    XCTAssertThrowsError(try model.closeTab(originalTabId)) { error in
      XCTAssertEqual(error as? AppError, AppError.lastTabClosed)
    }
    XCTAssertTrue(model.tabs.isEmpty, "tabs cleared after last close")
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
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "zsh")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
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

  func testTabStatusDefaultsToRunning() throws {
    let model = try makeModel()
    XCTAssertEqual(model.tabs[0].status, .running)
  }

  func testSyncExitStateIsMonotonic() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("session not found")
      return
    }
    model.forceExitState(forTab: tabId, status: .exited(code: 0))
    XCTAssertEqual(model.tabs[0].status, .exited(code: 0))
    XCTAssertEqual(model.tabs[0].titleMetadata.activityState, .exited)
    XCTAssertEqual(model.tabs[0].titleMetadata.exitStatus, 0)
    let changed = model.syncExitState(forTab: tabId, from: session)
    XCTAssertFalse(changed, "syncExitState must be no-op once tab is already exited")
    XCTAssertEqual(model.tabs[0].status, .exited(code: 0))
  }

  func testSyncProcessMetadataUsesForegroundProcessForTitle() throws {
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-app-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let tempPath = canonicalPath(tempURL.path)

    let exe = "/bin/sleep"
    let argStrings = ["/bin/sleep", "2"]
    try exe.withCString { exeCStr in
      try tempPath.withCString { cwdCStr in
        try withCArgv(argStrings) { argvPtr in
          var config = LabanLaunchConfig()
          config.executable = exeCStr
          config.argv = argvPtr
          config.cwd = cwdCStr
          config.fixture_mode = 0

          var size = LabanTerminalSize()
          size.rows = 24
          size.cols = 80

          let model = try AppModel(
            initialSize: size,
            sessionFactory: { sz in try Session(config: &config, size: sz) }
          )
          let tabId = model.tabs[0].id
          guard let session = model.session(forTab: tabId) else {
            XCTFail("session not found")
            return
          }

          let deadline = Date().addingTimeInterval(2.0)
          var changed = false
          while Date() < deadline {
            session.poll()
            changed = model.syncProcessMetadata(forTab: tabId, from: session) || changed
            if model.tabs[0].titleMetadata.process.foregroundProcess == "sleep" {
              break
            }
            Thread.sleep(forTimeInterval: 0.01)
          }

          XCTAssertTrue(changed)
          XCTAssertEqual(model.tabs[0].titleMetadata.process.foregroundProcess, "sleep")
          XCTAssertEqual(model.tabs[0].titleMetadata.workspace.cwd, tempPath)
          XCTAssertEqual(model.tabs[0].title, "sleep")
          XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .process)
        }
      }
    }
  }

  private func withCArgv(
    _ strings: [String],
    body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> Void
  ) rethrows {
    var mptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    mptrs.append(nil)
    defer { for p in mptrs { if let p { free(p) } } }
    let count = mptrs.count
    try mptrs.withUnsafeMutableBufferPointer { mbuf in
      try mbuf.baseAddress!.withMemoryRebound(
        to: UnsafePointer<CChar>?.self, capacity: count
      ) { rebound in
        try body(UnsafePointer(rebound))
      }
    }
  }

  func testAppModelRecordsExitStateFromRealPTY() {
    let exe = "/bin/sh"
    let argStrings = ["/bin/sh", "-c", "exit 7"]
    exe.withCString { exeCStr in
      withCArgv(argStrings) { argvPtr in
        var config = LabanLaunchConfig()
        config.executable = exeCStr
        config.argv = argvPtr
        config.fixture_mode = 0

        var size = LabanTerminalSize()
        size.rows = 24
        size.cols = 80

        let model: AppModel
        do {
          model = try AppModel(
            initialSize: size,
            sessionFactory: { sz in try Session(config: &config, size: sz) }
          )
        } catch {
          XCTFail("AppModel init failed: \(error)")
          return
        }

        let tabId = model.tabs[0].id
        guard let session = model.session(forTab: tabId) else {
          XCTFail("session not found")
          return
        }

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
          session.poll()
          if model.syncExitState(forTab: tabId, from: session) { break }
          Thread.sleep(forTimeInterval: 0.05)
        }

        XCTAssertNotEqual(model.tabs[0].status, .running)
        if case .exited(let code) = model.tabs[0].status {
          XCTAssertEqual(code, 7)
        } else {
          XCTFail("expected .exited(code:) but got \(model.tabs[0].status)")
        }
      }
    }
  }
}
