import AppKit
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest
import os

@testable import LabanApp

final class AppSessionCoordinatorTests: XCTestCase {
  func testRestoredAppTabAttachesExistingDaemonSession() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let seed = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-lc", "printf app-laband-existing-ready; sleep 60"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "top-tab"
      ))
    _ = try seedClient.detachSession(sessionId: seed.logicalSessionId)
    seedClient.close()

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "top-tab",
            tabs: [
              TabState(
                id: "top-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "top",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["top-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    let attached = try coordinator.ensureSession(for: tab, size: size)
    XCTAssertEqual(attached.logicalSessionId, seed.logicalSessionId)
    XCTAssertEqual(attached.incarnationId, seed.incarnationId)
    XCTAssertEqual(attached.childPid, seed.childPid)

    let snapshot = try waitForSnapshotText(
      coordinator: coordinator,
      tab: tab,
      size: size,
      text: "app-laband-existing-ready")
    XCTAssertEqual(snapshot.logicalSessionId, "top-tab")

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "top-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testSweepOrphanedSessionsTerminatesDaemonSessionsNotInKnownTabs() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-sweep-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let kept = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-lc", "sleep 60"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "kept-tab"
      ))
    let orphan = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-lc", "sleep 60"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "orphan"
      ))
    _ = try seedClient.detachSession(sessionId: kept.logicalSessionId)
    _ = try seedClient.detachSession(sessionId: orphan.logicalSessionId)
    seedClient.close()

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "kept-tab",
            tabs: [
              TabState(
                id: "kept-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "sh",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["kept-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    let attached = try coordinator.ensureSession(for: tab, size: size)
    XCTAssertEqual(attached.logicalSessionId, "kept-tab")

    coordinator.sweepOrphanedSessions()

    let verifyClient = try LabandTerminalSessionClient(socketPath: socketPath)
    defer { verifyClient.close() }
    let sessions = try verifyClient.listSessions()
    let keptAfter = sessions.first { $0.logicalSessionId == "kept-tab" }
    let orphanAfter = sessions.first { $0.logicalSessionId == "orphan" }
    XCTAssertEqual(
      keptAfter?.lifecycleState, .running,
      "the tab's session must remain running after sweep")
    XCTAssertNotEqual(
      orphanAfter?.lifecycleState, .running,
      "the orphan session must no longer be running after sweep")

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "kept-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testRestoredAppTabReappliesCurrentThemeToExistingDaemonSession() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let previousTheme = Theme.current
    let previousFollowsSystem = Theme.followsSystemAppearance
    defer {
      Theme.current = previousTheme
      Theme.followsSystemAppearance = previousFollowsSystem
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-theme-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let seed = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "theme-tab"
      ))
    try seedClient.writeInput(sessionId: seed.logicalSessionId, bytes: Array("t".utf8))
    _ = try waitForSnapshotText(
      client: seedClient,
      sessionId: seed.logicalSessionId,
      text: "t")
    try seedClient.applyTheme(
      sessionId: seed.logicalSessionId,
      paletteBytes: ThemePaletteInjector.paletteBytes(for: Theme.selenizedDark),
      colorScheme: .dark)
    _ = try seedClient.detachSession(sessionId: seed.logicalSessionId)
    seedClient.close()

    Theme.current = Theme.selenizedLight
    Theme.followsSystemAppearance = false

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "theme-tab",
            tabs: [
              TabState(
                id: "theme-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "cat",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["theme-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)
    let snapshot = try waitForSnapshotText(
      coordinator: coordinator,
      tab: tab,
      size: size,
      text: "t")
    let themedCell = try XCTUnwrap(snapshot.cells.first { $0.text == "t" })
    XCTAssertEqual(themedCell.foregroundRGBA, Theme.selenizedLight.fg0)
    XCTAssertEqual(themedCell.backgroundRGBA, Theme.selenizedLight.bg0)

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "theme-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testRestoredAppTabScrollsExistingDaemonSessionScrollback() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-scroll-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    let seed = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: [
          "/bin/sh", "-lc",
          "i=1; while [ $i -le 30 ]; do printf 'line-%02d\\n' \"$i\"; i=$((i+1)); done; sleep 60",
        ],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 5,
        cols: 40,
        logicalSessionId: "scroll-tab"
      ))
    _ = try waitForSnapshotText(
      client: seedClient,
      sessionId: seed.logicalSessionId,
      text: "line-30")
    _ = try seedClient.detachSession(sessionId: seed.logicalSessionId)
    seedClient.close()

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 40
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "scroll-tab",
            tabs: [
              TabState(
                id: "scroll-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "scroll",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["scroll-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)
    try coordinator.scrollViewport(tab: tab, size: size, deltaRows: -20)

    let older = try waitForSnapshotText(
      coordinator: coordinator,
      tab: tab,
      size: size,
      text: "line-10")
    XCTAssertFalse(older.visibleText.contains("line-30"))

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "scroll-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testSnapshotGenerationMonitorWakesAfterDaemonOutput() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-generation-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let coordinatorClient = try waitForClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: [:]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)
    let woke = expectation(description: "daemon snapshot generation advanced")
    let wokeOnce = OSAllocatedUnfairLock(initialState: false)
    coordinator.startSnapshotGenerationMonitor { logicalSessionId, _ in
      XCTAssertEqual(logicalSessionId, tab.id)
      let shouldFulfill = wokeOnce.withLock { fulfilled -> Bool in
        guard !fulfilled else { return false }
        fulfilled = true
        return true
      }
      if shouldFulfill {
        woke.fulfill()
      }
    }

    try coordinator.write(Array("g".utf8), to: tab, size: size)
    wait(for: [woke], timeout: 2)

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: tab.id)
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testUnchangedBackgroundSnapshotDoesNotAdvanceRenderedFrame() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-render-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "render-tab",
            tabs: [
              TabState(
                id: "render-tab",
                cwd: root.path,
                launchCommand: "cat",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try waitForClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: ShellIntegrationLaunch(argv: ["/bin/cat"]),
      cwdByTabId: ["render-tab": root.path]
    )
    defer { coordinator.detach() }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * CGFloat(cellWidth)
      + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * CGFloat(cellHeight) + insets.bottom
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sessionCoordinator: coordinator
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)
    try coordinator.write(Array("steady".utf8), to: tab, size: size)
    _ = try waitForSnapshotText(coordinator: coordinator, tab: tab, size: size, text: "steady")

    view.advanceFrame()
    let baselineFrame = view.renderedFrameCountForTests
    XCTAssertGreaterThan(baselineFrame, 0)

    view.advanceFrame()
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      baselineFrame,
      "unchanged background snapshot generation must not force another rendered frame")

    try coordinator.write(Array("!".utf8), to: tab, size: size)
    _ = try waitForSnapshotText(coordinator: coordinator, tab: tab, size: size, text: "steady!")

    let expectedFrame = baselineFrame + 1
    let deadline = Date().addingTimeInterval(1)
    while view.renderedFrameCountForTests < expectedFrame && Date() < deadline {
      view.advanceFrame()
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      expectedFrame,
      "new background snapshot generation must render")

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "render-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  func testRefreshTabMetadataFlowsForegroundCommandIntoModel() throws {
    let labandURL = URL(fileURLWithPath: ".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: labandURL.path) else {
      throw XCTSkip("laband binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-meta-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let journalURL = root.appendingPathComponent("journal", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labandURL
    process.arguments = ["--socket", socketPath, "--journal", journalURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForClient(socketPath: socketPath)
    // `/bin/sh -c 'sleep 30'` gives a stable two-frame foreground tree: sh
    // is the child, sleep becomes the PTY foreground group leader. The
    // daemon's `refreshProcessMetadata` therefore reports
    // `foregroundCommand` ~= "sleep" after a brief settle.
    _ = try seedClient.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/sh",
        argv: ["/bin/sh", "-c", "sleep 30"],
        cwd: FileManager.default.homeDirectoryForCurrentUser.path,
        rows: 24,
        cols: 80,
        logicalSessionId: "meta-tab"
      ))
    seedClient.close()

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: "meta-tab",
            tabs: [
              TabState(
                id: "meta-tab",
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                launchCommand: "sh",
                lastActiveAt: Date())
            ])
        ]))

    let coordinatorClient = try LabandTerminalSessionClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      client: coordinatorClient,
      shellLaunch: .passthrough,
      cwdByTabId: ["meta-tab": FileManager.default.homeDirectoryForCurrentUser.path]
    )
    defer { coordinator.detach() }

    let tab = try XCTUnwrap(model.tabs.first)
    _ = try coordinator.ensureSession(for: tab, size: size)

    // Drive the daemon a little so foreground-process polling has time to
    // see `sleep`. The coordinator throttles its own refresh internally;
    // forward time so the throttle does not skip subsequent calls.
    let deadline = Date().addingTimeInterval(5)
    var observedCommand: String?
    while Date() < deadline {
      coordinator.refreshTabMetadata(for: model.tabs, into: model, now: Date())
      observedCommand = model.tabs.first?.titleMetadata.process.foregroundCommand
      if let cmd = observedCommand, cmd.contains("sleep") { break }
      usleep(150_000)
    }
    XCTAssertNotNil(
      observedCommand,
      "tab process metadata must be populated from daemon")
    if let cmd = observedCommand {
      XCTAssertTrue(
        cmd.contains("sleep"),
        "expected foregroundCommand containing 'sleep', got \(cmd)")
    }

    let cleanupClient = try LabandTerminalSessionClient(socketPath: socketPath)
    _ = try? cleanupClient.terminate(sessionId: "meta-tab")
    _ = try? cleanupClient.shutdownWhenIdle()
    cleanupClient.close()
    process.waitUntilExit()
  }

  private func waitForClient(socketPath: String) throws -> LabandTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabandTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    throw XCTSkip("timed out waiting for laband: \(String(describing: lastError))")
  }

  private func waitForSnapshotText(
    coordinator: AppSessionCoordinator,
    tab: Tab,
    size: LabanTerminalSize,
    text: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try coordinator.snapshot(for: tab, size: size)
      if snapshot.visibleText.contains(text) {
        return snapshot
      }
      last = snapshot
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(text); last=\(last?.visibleText ?? "")")
    return try XCTUnwrap(last)
  }

  private func waitForSnapshotText(
    client: LabandTerminalSessionClient,
    sessionId: String,
    text: String
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(5)
    var last: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try client.snapshot(sessionId: sessionId)
      if snapshot.visibleText.contains(text) {
        return snapshot
      }
      last = snapshot
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(text); last=\(last?.visibleText ?? "")")
    return try XCTUnwrap(last)
  }
}
