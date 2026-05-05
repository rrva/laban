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

private func processMetadata(
  pid: Int,
  process: String,
  command: String,
  cwd: String? = nil
) -> Session.ProcessMetadata {
  Session.ProcessMetadata(
    childPid: pid,
    foregroundPid: pid,
    foregroundProcess: process,
    foregroundCommand: command,
    cwd: cwd
  )
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

  func testSelectTabWithStaleIdKeepsExistingActiveTab() throws {
    let model = try makeModel()
    let firstId = model.tabs[0].id
    let second = try model.createTab()

    XCTAssertEqual(model.activeTab?.id, second.id)
    model.selectTab("missing-\(UUID().uuidString)")

    XCTAssertEqual(model.activeTab?.id, second.id)
    XCTAssertFalse(model.tabs.first { $0.id == firstId }?.isActive ?? true)
    XCTAssertEqual(model.tabs.filter { $0.isActive }.count, 1)
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

  func testResizePropagatesPixelAndCellMetricsToTerminalSizeReports() throws {
    let sink = AppModelCaptureSink()
    let model = try makeModel(rows: 24, cols: 80)
    model.captureSink = sink

    model.resize(viewportWidth: 900, viewportHeight: 540, cellWidth: 9, cellHeight: 18)

    guard let session = model.session(forTab: model.tabs[0].id) else {
      XCTFail("session missing for active tab")
      return
    }
    sink.byteEvents.removeAll()
    XCTAssertEqual(session.write(Array("\u{1B}[14t\u{1B}[16t\u{1B}[18t".utf8)), 0)

    let responseBytes = sink.byteEvents
      .filter { $0.direction == .terminalResponse }
      .flatMap { $0.bytes }
    let response = String(bytes: responseBytes, encoding: .utf8) ?? ""

    XCTAssertTrue(
      response.contains("\u{1B}[4;540;900t"),
      "text-area pixel size reply missing from \(response.debugDescription)")
    XCTAssertTrue(
      response.contains("\u{1B}[6;18;9t"),
      "cell pixel size reply missing from \(response.debugDescription)")
    XCTAssertTrue(
      response.contains("\u{1B}[8;30;100t"),
      "character size reply missing from \(response.debugDescription)")
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

  func testTabStatusCallbackCanArriveFromBackgroundQueue() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id
    guard let session = model.session(forTab: tabId) else {
      XCTFail("session not found")
      return
    }

    let delivered = expectation(description: "background tab status delivered")
    DispatchQueue.global(qos: .userInitiated).async {
      _ = session.feedOutput(Array("\u{1B}]21337;status=background\u{07}".utf8))
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 1)

    XCTAssertEqual(model.tabs[0].titleMetadata.agentStatus.statusText, "background")
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

  func testTerminalTitleOwnedByForegroundProcessBeatsVersionedProcessName() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "* Claude Code")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .terminal)
    XCTAssertEqual(model.tabs[0].titleMetadata.terminalTitle, "* Claude Code")
  }

  func testProcessIdentityChangeClearsOwnedTerminalTitle() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    XCTAssertTrue(
      model.applyProcessMetadata(
        processMetadata(
          pid: 1002,
          process: "top",
          command: "/usr/bin/top",
          cwd: NSHomeDirectory()
        ),
        forTab: tabId
      ))

    XCTAssertNil(model.tabs[0].titleMetadata.terminalTitle)
    XCTAssertEqual(model.tabs[0].title, "top")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .process)
  }

  func testShellProcessIdentityChangeFallsBackToHomeCwd() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1001,
        process: "2.1.126",
        command: "/opt/homebrew/bin/2.1.126",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    _ = model.applyProcessMetadata(
      processMetadata(
        pid: 1002,
        process: "zsh",
        command: "/bin/zsh",
        cwd: NSHomeDirectory()
      ),
      forTab: tabId
    )

    XCTAssertNil(model.tabs[0].titleMetadata.terminalTitle)
    XCTAssertEqual(model.tabs[0].title, "~")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .cwd)
  }

  func testManualTitleSurvivesProcessAndTerminalChanges() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(pid: 1001, process: "2.1.126", command: "/opt/homebrew/bin/2.1.126"),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)
    try model.renameTab(tabId, title: "manual")
    _ = model.applyProcessMetadata(
      processMetadata(pid: 1002, process: "top", command: "/usr/bin/top"),
      forTab: tabId
    )
    try model.updateTerminalTitle("top", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "manual")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .user)
  }

  func testFrozenTitleSurvivesProcessAndTerminalChanges() throws {
    let model = try makeModel()
    let tabId = model.tabs[0].id

    _ = model.applyProcessMetadata(
      processMetadata(pid: 1001, process: "zsh", command: "/bin/zsh", cwd: NSHomeDirectory()),
      forTab: tabId
    )
    try model.updateTerminalTitle("zsh", forTab: tabId)
    try model.freezeTitle(forTab: tabId)
    _ = model.applyProcessMetadata(
      processMetadata(pid: 1002, process: "2.1.126", command: "/opt/homebrew/bin/2.1.126"),
      forTab: tabId
    )
    try model.updateTerminalTitle("* Claude Code", forTab: tabId)

    XCTAssertEqual(model.tabs[0].title, "~")
    XCTAssertEqual(model.tabs[0].titleMetadata.titleSource, .user)
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

private final class AppModelCaptureSink: CaptureSink {
  struct ByteEvent {
    var direction: CaptureByteDirection
    var sessionId: Session.ID?
    var frame: Int
    var bytes: [UInt8]
  }

  var sequence = 0
  var events: [CaptureTimelineEvent] = []
  var byteEvents: [ByteEvent] = []

  func nextSequence() -> Int {
    defer { sequence += 1 }
    return sequence
  }

  func record(_ event: CaptureTimelineEvent) {
    events.append(event)
  }

  func recordBytes(
    direction: CaptureByteDirection,
    sessionId: Session.ID?,
    frame: Int,
    bytes: UnsafeRawBufferPointer,
    preview: String?
  ) -> CaptureByteRef? {
    let array = bytes.bindMemory(to: UInt8.self).map { $0 }
    byteEvents.append(
      ByteEvent(direction: direction, sessionId: sessionId, frame: frame, bytes: array))
    return CaptureByteRef(
      stream: direction.rawValue,
      path: "streams/\(direction.streamFileName)",
      offset: 0,
      length: array.count,
      sha256: ""
    )
  }
}
