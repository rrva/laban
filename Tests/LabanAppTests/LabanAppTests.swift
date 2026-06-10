import AppKit
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class LabanAppTests: XCTestCase {
  func testAppDirectSessionEndToEnd() throws {
    let labptyURL = URL(fileURLWithPath: ".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: labptyURL.path) else {
      throw XCTSkip("labpty binary is not built")
    }

    let root = URL(
      fileURLWithPath: ".tmp/lbn-app-labpty-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let shmURL = root.appendingPathComponent("shm", isDirectory: true)
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let process = Process()
    process.executableURL = labptyURL
    process.arguments = ["--socket", socketPath, "--shm-dir", shmURL.path]
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
    let model = try AppModel(initialSize: size) { try Session.parserOnly(size: $0) }
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let client = try waitForLabptyClient(socketPath: socketPath)
    let coordinator = AppSessionCoordinator(
      labptyClient: client,
      shellLaunch: ShellIntegrationLaunch(
        argv: [
          "/bin/sh", "-c",
          "printf STARTED; while IFS= read -r x; do echo \"got $x\"; done",
        ]),
      cwdByTabId: [tab.id: FileManager.default.currentDirectoryPath]
    )
    defer { coordinator.detach() }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "STARTED")

    try coordinator.write(Array("ping\n".utf8), to: tab, session: session, size: size)
    let text = try waitForLocalSnapshotText(model: model, tab: tab, text: "got ping")
    XCTAssertTrue(text.contains("STARTED"))
    XCTAssertTrue(text.contains("got ping"))
  }

  func testLabanAppRestartPreservesChildViaLabpty() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-restart")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let tabId = "restart-tab"
    let command = [
      "/bin/sh", "-c",
      "printf READY; while IFS= read -r x; do echo \"got $x\"; done",
    ]

    let firstModel = try parserModel(tabId: tabId, size: size)
    let firstTab = try XCTUnwrap(firstModel.activeTab)
    let firstSession = try XCTUnwrap(firstModel.session(forTab: firstTab.id))
    let firstCoordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    let firstInfo = try firstCoordinator.ensureSession(
      for: firstTab,
      session: firstSession,
      size: size)
    let childPid = try XCTUnwrap(firstInfo.childPid)
    _ = try waitForLocalSnapshotText(model: firstModel, tab: firstTab, text: "READY")
    try firstCoordinator.write(Array("one\n".utf8), to: firstTab, session: firstSession, size: size)
    _ = try waitForLocalSnapshotText(model: firstModel, tab: firstTab, text: "got one")
    firstCoordinator.detach()
    firstModel.closeAllSessions()

    let secondModel = try parserModel(tabId: tabId, size: size)
    let secondTab = try XCTUnwrap(secondModel.activeTab)
    let secondSession = try XCTUnwrap(secondModel.session(forTab: secondTab.id))
    let secondCoordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      secondCoordinator.terminate(tab: secondTab)
      secondCoordinator.detach()
      secondModel.closeAllSessions()
    }

    let secondInfo = try secondCoordinator.ensureSession(
      for: secondTab,
      session: secondSession,
      size: size)
    XCTAssertEqual(secondInfo.childPid, childPid)
    try secondCoordinator.write(
      Array("two\n".utf8), to: secondTab, session: secondSession, size: size)
    let text = try waitForLocalSnapshotText(model: secondModel, tab: secondTab, text: "got two")
    XCTAssertTrue(text.contains("READY"))
    XCTAssertTrue(text.contains("got one"))
    XCTAssertTrue(text.contains("got two"))
    print(
      "[labpty-restart] child_pid before=\(childPid) after=\(secondInfo.childPid ?? -1) wroteBefore='got one' wroteAfter='got two'"
    )
  }

  func testLabptyOrphanSweepPreservesUnknownLiveSessions() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-sweep")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForLabptyClient(socketPath: socketPath)
    let kept = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "kept-tab"))
    let orphan = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "60"],
        logicalSessionId: "unknown-live-tab"))
    seedClient.close()
    defer {
      let cleanupClient = try? waitForLabptyClient(socketPath: socketPath)
      _ = try? cleanupClient?.terminate(handle: kept.ptyHandle)
      _ = try? cleanupClient?.terminate(handle: orphan.ptyHandle)
      cleanupClient?.close()
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try parserModel(tabId: "kept-tab", size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: .passthrough,
      cwdByTabId: ["kept-tab": FileManager.default.currentDirectoryPath])
    defer {
      coordinator.detach()
      model.closeAllSessions()
    }

    let attached = try coordinator.ensureSession(for: tab, session: session, size: size)
    XCTAssertEqual(attached.logicalSessionId, "kept-tab")

    coordinator.sweepOrphanedSessions()

    let verifyClient = try waitForLabptyClient(socketPath: socketPath)
    defer { verifyClient.close() }
    let sessions = try verifyClient.listLabptySessions()
    XCTAssertTrue(
      sessions.contains { $0.logicalSessionId == "kept-tab" && $0.alive },
      "the restored tab's labpty session must remain running")
    XCTAssertTrue(
      sessions.contains { $0.logicalSessionId == "unknown-live-tab" && $0.alive },
      "unknown labpty sessions must survive app-side orphan sweeps")
  }

  func testAdoptUnclaimedLabptySessionReattachesExistingChild() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-adopt")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let seedClient = try waitForLabptyClient(socketPath: socketPath)
    let kept = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "60"], logicalSessionId: "kept-tab"))
    let orphan = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80,
        argv: [
          "/bin/sh", "-c",
          "printf READY; while IFS= read -r x; do echo \"got $x\"; done",
        ],
        logicalSessionId: "unknown-live-tab"))
    seedClient.close()
    defer {
      let cleanupClient = try? waitForLabptyClient(socketPath: socketPath)
      _ = try? cleanupClient?.terminate(handle: kept.ptyHandle)
      _ = try? cleanupClient?.terminate(handle: orphan.ptyHandle)
      cleanupClient?.close()
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let model = try parserModel(tabId: "kept-tab", size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: .passthrough,
      cwdByTabId: ["kept-tab": FileManager.default.currentDirectoryPath])
    defer {
      coordinator.detach()
      model.closeAllSessions()
    }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)

    // Detection: the bound tab is claimed; only the unknown session shows
    // up as unclaimed.
    let unclaimed = coordinator.unclaimedLabptySessions(knownTabIds: Set(model.tabs.map(\.id)))
    XCTAssertEqual(unclaimed.map(\.logicalSessionId), ["unknown-live-tab"])

    // Adoption binds a new tab to the *existing* child (same pid) instead
    // of spawning a fresh shell.
    let adopted = coordinator.adoptLabptySessions(unclaimed, in: model, size: size)
    XCTAssertEqual(adopted.map(\.id), ["unknown-live-tab"])
    let adoptedTab = try XCTUnwrap(model.tabs.first { $0.id == "unknown-live-tab" })
    XCTAssertEqual(coordinator.sessionInfo(for: adoptedTab)?.childPid, Int(orphan.childPid))

    // The adopted tab is live, not merely bound: the byte-ring feed
    // attaches (prior output replays) and input round-trips through the
    // reattached child.
    let adoptedSession = try XCTUnwrap(model.session(forTab: adoptedTab.id))
    _ = try waitForLocalSnapshotText(model: model, tab: adoptedTab, text: "READY")
    try coordinator.write(Array("hi\n".utf8), to: adoptedTab, session: adoptedSession, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: adoptedTab, text: "got hi")

    // Reattach, not respawn: still exactly one live session for that id.
    let verifyClient = try waitForLabptyClient(socketPath: socketPath)
    defer { verifyClient.close() }
    let liveForId = try verifyClient.listLabptySessions()
      .filter { $0.logicalSessionId == "unknown-live-tab" && $0.alive }
    XCTAssertEqual(liveForId.count, 1, "adoption must reattach, not open a second session")
  }

  func testAppDirectMouseDragBelowBottomReachesChildViaLabpty() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-mouse")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 40
    size.pixel_width = 400
    size.pixel_height = 100
    size.cell_width = 10
    size.cell_height = 20
    let tabId = "mouse-tab"
    let model = try parserModel(tabId: tabId, size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let command = [
      "/bin/sh", "-lc",
      "stty raw -echo; printf '\\033[?1000h\\033[?1002h\\033[?1006hREADY'; exec cat -v",
    ]
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      coordinator.terminate(tab: tab)
      coordinator.detach()
      model.closeAllSessions()
    }

    let view = makeTerminalView(model: model, size: size, coordinator: coordinator)
    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "READY")
    XCTAssertEqual(
      session.viewportState()?.mouseTracking,
      true,
      "labpty parser feed must adopt the child's mouse tracking mode locally")

    view.advanceFrame()
    let start = terminalPoint(row: 2, col: 10, rows: Int(size.rows))
    let belowBottom = NSPoint(
      x: start.x,
      y: TerminalBitmapView.contentInsets.bottom - CGFloat(size.cell_height) * 2)
    let framesBeforePressPump = view.renderedFrameCountForTests
    view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: start))
    XCTAssertTrue(
      view.trackedMouseDragFrameTimerActiveForTests,
      """
      forwarded mouse-tracking drags should keep the frame loop alive during AppKit event tracking
      """)
    runEventTrackingLoop(for: 0.12)
    XCTAssertGreaterThan(
      view.renderedFrameCountForTests,
      framesBeforePressPump,
      "forwarded mouse-tracking drags must advance frames in AppKit event-tracking mode")
    view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: belowBottom))
    view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: belowBottom))
    XCTAssertFalse(view.trackedMouseDragFrameTimerActiveForTests)

    _ = try waitForLocalSnapshotText(
      model: model,
      tab: tab,
      text: "[<32;11;5M",
      message: "labpty child must receive the held-left SGR drag report on the bottom row")
  }

  func testAppDirectTmuxSelectionAutoscrollContinuesBelowBottomViaLabpty() throws {
    try requireTmux()
    let tmuxName = "lbn-tmux-mouse-\(UUID().uuidString.prefix(8))"
    defer { _ = try? runTmux(name: tmuxName, arguments: ["kill-server"]) }

    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-tmux")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 8
    size.cols = 40
    let tabId = "tmux-mouse-tab"
    let model = try parserModel(tabId: tabId, size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let command = [
      "/bin/sh", "-lc",
      """
      set -eu
      export TERM=xterm-256color
      tmux -L \(tmuxName) -f /dev/null new-session -d -x \(Int(size.cols)) \
        -y \(Int(size.rows)) \
        "sh -lc 'jot -w LINE-%03d 400; exec sleep 1000'"
      tmux -L \(tmuxName) -f /dev/null set -g mouse on
      tmux -L \(tmuxName) -f /dev/null set -g status off
      tmux -L \(tmuxName) -f /dev/null set -g mode-keys vi
      exec tmux -L \(tmuxName) -f /dev/null attach-session
      """,
    ]
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      coordinator.terminate(tab: tab)
      coordinator.detach()
      model.closeAllSessions()
    }

    let view = makeTerminalView(model: model, size: size, coordinator: coordinator)
    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "LINE-400")
    try waitUntil(
      session.viewportState()?.mouseTracking == true,
      "tmux must enable mouse tracking on attach")

    _ = try runTmux(name: tmuxName, arguments: ["copy-mode", "-u", "-t", ":0.0"])
    _ = try runTmux(
      name: tmuxName,
      arguments: ["send-keys", "-t", ":0.0", "-X", "-N", "40", "page-up"])
    let before = try waitForTmuxScrollPosition(name: tmuxName) { $0 > 12 }

    view.advanceFrame()
    let visibleBefore = try localSnapshotText(model: model, tab: tab)
    let start = terminalPoint(row: 2, col: 10, rows: Int(size.rows))
    let belowBottom = NSPoint(
      x: start.x,
      y: TerminalBitmapView.contentInsets.bottom - FontAtlas(pointSize: 14).cellSize.height * 2)
    view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: start))
    XCTAssertTrue(view.trackedMouseDragFrameTimerActiveForTests)
    view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: belowBottom))
    let jitterColumns = [13, 14, 15, 16, 17, 18]
    for index in 0..<30 {
      let column = jitterColumns[index % jitterColumns.count]
      let jitterPoint = NSPoint(
        x: terminalPoint(row: 2, col: column, rows: Int(size.rows)).x,
        y: belowBottom.y)
      view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: jitterPoint))
      Thread.sleep(forTimeInterval: 0.02)
    }
    let during = try tmuxScrollPosition(name: tmuxName)
    let visibleDuring = try waitForLocalSnapshotChange(
      model: model,
      tab: tab,
      previous: visibleBefore)
    view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: belowBottom))
    XCTAssertFalse(view.trackedMouseDragFrameTimerActiveForTests)

    XCTAssertGreaterThanOrEqual(
      before - during,
      5,
      """
      holding a tmux copy-mode drag below the bottom row should keep autoscrolling, not stop after one line
      """)
    XCTAssertNotEqual(
      visibleDuring,
      visibleBefore,
      "Laban must repaint tmux autoscroll output while the drag is still held")
  }

  func testAppDirectTmuxSelectionAutoscrollSurvivesBottomRowJitterViaLabpty() throws {
    try requireTmux()
    let tmuxName = "lbn-tmux-row-\(UUID().uuidString.prefix(8))"
    defer { _ = try? runTmux(name: tmuxName, arguments: ["kill-server"]) }

    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-tmux-row")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 8
    size.cols = 40
    let tabId = "tmux-row-mouse-tab"
    let model = try parserModel(tabId: tabId, size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let command = [
      "/bin/sh", "-lc",
      """
      set -eu
      export TERM=xterm-256color
      tmux -L \(tmuxName) -f /dev/null new-session -d -x \(Int(size.cols)) \
        -y \(Int(size.rows)) \
        "sh -lc 'jot -w LINE-%03d 400; exec sleep 1000'"
      tmux -L \(tmuxName) -f /dev/null set -g mouse on
      tmux -L \(tmuxName) -f /dev/null set -g status off
      tmux -L \(tmuxName) -f /dev/null set -g mode-keys vi
      exec tmux -L \(tmuxName) -f /dev/null attach-session
      """,
    ]
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      coordinator.terminate(tab: tab)
      coordinator.detach()
      model.closeAllSessions()
    }

    let view = makeTerminalView(model: model, size: size, coordinator: coordinator)
    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "LINE-400")
    try waitUntil(
      session.viewportState()?.mouseTracking == true,
      "tmux must enable mouse tracking on attach")

    _ = try runTmux(name: tmuxName, arguments: ["copy-mode", "-u", "-t", ":0.0"])
    _ = try runTmux(
      name: tmuxName,
      arguments: ["send-keys", "-t", ":0.0", "-X", "-N", "40", "page-up"])
    let before = try waitForTmuxScrollPosition(name: tmuxName) { $0 > 12 }

    view.advanceFrame()
    let visibleBefore = try localSnapshotText(model: model, tab: tab)
    let start = terminalPoint(row: 2, col: 10, rows: Int(size.rows))
    view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: start))
    XCTAssertTrue(view.trackedMouseDragFrameTimerActiveForTests)
    let jitterColumns = [13, 14, 15, 16, 17, 18]
    for index in 0..<30 {
      let column = jitterColumns[index % jitterColumns.count]
      let jitterPoint = terminalPoint(row: Int(size.rows) - 1, col: column, rows: Int(size.rows))
      view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: jitterPoint))
      Thread.sleep(forTimeInterval: 0.02)
    }
    let during = try tmuxScrollPosition(name: tmuxName)
    let visibleDuring = try waitForLocalSnapshotChange(
      model: model,
      tab: tab,
      previous: visibleBefore)
    view.mouseUp(
      with: mouseEvent(
        type: .leftMouseUp,
        at: terminalPoint(row: Int(size.rows) - 1, col: 18, rows: Int(size.rows))))
    XCTAssertFalse(view.trackedMouseDragFrameTimerActiveForTests)

    XCTAssertGreaterThanOrEqual(
      before - during,
      5,
      """
      tmux bottom-row copy-mode drag should keep autoscrolling despite small horizontal jitter
      """)
    XCTAssertNotEqual(
      visibleDuring,
      visibleBefore,
      "Laban must repaint tmux bottom-row autoscroll output while the drag is still held")
  }

  func testReattachedLabptySessionResetsParserStateAfterRingWrap() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-mouse-wrap")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 8
    size.cols = 40
    let tabId = "wrapped-mouse-tab"
    let capacity = UInt64(LabptyByteRingLayout.minimumOutputRingCapacity)
    let command = [
      "/bin/sh", "-lc",
      """
      printf '\\033[?1000h\\033[?1002h\\033[?1006hREADY\\n'
      jot -b X 180000
      printf 'TAIL\\n'
      exec cat -v
      """,
    ]

    let seedClient = try waitForLabptyClient(socketPath: socketPath)
    let seedDescriptor = try seedClient.openSession(
      LabptyOpenSessionRequest(
        rows: UInt32(size.rows),
        cols: UInt32(size.cols),
        outputRingCapacity: capacity,
        argv: command,
        cwd: FileManager.default.currentDirectoryPath,
        logicalSessionId: tabId))
    let reader = try LabptyByteRingReader(path: seedDescriptor.byteRingShmPath)
    try waitForByteRingOffset(reader, atLeast: capacity + 64 * 1024)
    XCTAssertTrue(
      reader.readSince(0).overflowed,
      "test setup must prove the reattach starts from a wrapped byte-ring window")
    seedClient.close()

    let model = try parserModel(tabId: tabId, size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      coordinator.terminate(tab: tab)
      coordinator.detach()
      model.closeAllSessions()
    }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(model: model, tab: tab, text: "TAIL")

    XCTAssertEqual(
      session.viewportState()?.mouseTracking,
      false,
      """
      labpty Phase 1 reattaches by replaying the retained byte-ring tail after \
      a parser reset; it cannot reconstruct DECSET mouse-tracking modes that \
      were overwritten before the readable window
      """)
  }

  func testLabptyViewerSessionAnswersCursorPositionQuery() throws {
    let (root, socketPath, process) = try startLabptyDaemon(prefix: "lbn-app-labpty-cpr")
    defer { try? FileManager.default.removeItem(at: root) }
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 67
    let tabId = "cpr-reply-tab"
    let model = try parserModel(tabId: tabId, size: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    // gh auth login's survey library probes the terminal size by entering raw
    // mode, emitting DECSC + CUP 999;999 + DSR-CPR (ESC[6n), then BLOCKING on
    // a read of the ESC[rows;colsR reply with no timeout. In the labpty tier
    // the daemon owns the PTY and the app-side viewer session parses the byte
    // ring, so the viewer's generated reply must travel back over the daemon
    // socket — otherwise the child hangs forever (the reported gh freeze).
    let command = [
      "/bin/sh", "-lc",
      """
      python3 -c '
      import os, sys, tty
      tty.setraw(sys.stdin.fileno())
      os.write(1, b"\\x1b7\\x1b[999;999f\\x1b[6n")
      reply = b""
      while not reply.endswith(b"R"):
          reply += os.read(0, 1)
      os.write(1, b"\\x1b8GOT:" + reply[2:] + b"\\r\\n")
      '
      exec cat
      """,
    ]
    let coordinator = AppSessionCoordinator(
      labptyClient: try waitForLabptyClient(socketPath: socketPath),
      shellLaunch: ShellIntegrationLaunch(argv: command),
      cwdByTabId: [tabId: FileManager.default.currentDirectoryPath])
    defer {
      coordinator.terminate(tab: tab)
      coordinator.detach()
      model.closeAllSessions()
    }

    _ = try coordinator.ensureSession(for: tab, session: session, size: size)
    _ = try waitForLocalSnapshotText(
      model: model,
      tab: tab,
      text: "GOT:24;67R",
      message: """
        the viewer session's CPR reply (ESC[24;67R) must reach the labpty child; \
        a child blocking on that read with no timeout is the gh auth login freeze
        """)
  }

  private func waitForLabptyClient(socketPath: String) throws -> LabptyTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabptyTerminalSessionClient(socketPath: socketPath)
        _ = try client.hello()
        return client
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    throw XCTSkip("timed out waiting for labpty: \(String(describing: lastError))")
  }

  private func startLabptyDaemon(prefix: String) throws -> (
    root: URL, socketPath: String, process: Process
  ) {
    let labptyURL = URL(fileURLWithPath: ".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: labptyURL.path) else {
      throw XCTSkip("labpty binary is not built")
    }
    let root = URL(
      fileURLWithPath: ".tmp/\(prefix)-\(UUID().uuidString.prefix(8))",
      isDirectory: true)
    let socketPath = root.appendingPathComponent("s.sock").path
    let shmURL = root.appendingPathComponent("shm", isDirectory: true)
    try FileManager.default.createDirectory(at: shmURL, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = labptyURL
    process.arguments = ["--socket", socketPath, "--shm-dir", shmURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    _ = try waitForLabptyClient(socketPath: socketPath)
    return (root, socketPath, process)
  }

  private func parserModel(tabId: String, size: LabanTerminalSize) throws -> AppModel {
    let model = try AppModel(initialSize: size) { try Session.parserOnly(size: $0) }
    model.replaceTabs(
      from: WorkspaceState(
        windows: [
          WindowState(
            id: "main-window",
            selectedTabId: tabId,
            tabs: [
              TabState(
                id: tabId,
                cwd: FileManager.default.currentDirectoryPath,
                launchCommand: "/bin/sh",
                lastActiveAt: Date())
            ])
        ]))
    return model
  }

  private func waitForLocalSnapshotText(
    model: AppModel,
    tab: Tab,
    text: String,
    message: String? = nil
  ) throws -> String {
    let deadline = Date().addingTimeInterval(5)
    var last = ""
    while Date() < deadline {
      if let session = model.session(forTab: tab.id), let snapshot = session.snapshot() {
        defer { laban_snapshot_destroy(snapshot) }
        let visible = TerminalSnapshotText.visibleText(
          from: UnsafePointer(snapshot),
          mode: .trimmedNonEmptyRows)
        if visible.contains(text) {
          return visible
        }
        last = visible
      }
      usleep(50_000)
    }
    XCTFail("\(message ?? "timed out waiting for \(text)"); last=\(last)")
    return last
  }

  private func localSnapshotText(model: AppModel, tab: Tab) throws -> String {
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let snapshot = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snapshot) }
    return TerminalSnapshotText.visibleText(
      from: UnsafePointer(snapshot),
      mode: .trimmedNonEmptyRows)
  }

  private func waitForLocalSnapshotChange(
    model: AppModel,
    tab: Tab,
    previous: String
  ) throws -> String {
    let deadline = Date().addingTimeInterval(5)
    var last = previous
    while Date() < deadline {
      if let session = model.session(forTab: tab.id) {
        session.poll()
      }
      let visible = try localSnapshotText(model: model, tab: tab)
      if visible != previous {
        return visible
      }
      last = visible
      usleep(50_000)
    }
    XCTFail("timed out waiting for snapshot change; last=\(last)")
    return last
  }

  private func makeTerminalView(
    model: AppModel,
    size: LabanTerminalSize,
    coordinator: AppSessionCoordinator
  ) -> TerminalBitmapView {
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * cellSize.width
      + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * cellSize.height + insets.bottom
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height),
      sessionCoordinator: coordinator)
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
    return view
  }

  private func terminalPoint(
    row: Int,
    col: Int,
    rows: Int,
  ) -> NSPoint {
    let cellSize = FontAtlas(pointSize: 14).cellSize
    return NSPoint(
      x: SidebarLayout.defaultWidth + TerminalBitmapView.contentInsets.left
        + CGFloat(col) * cellSize.width + cellSize.width / 2,
      y: TerminalBitmapView.contentInsets.bottom
        + CGFloat(rows - 1 - row) * cellSize.height + cellSize.height / 2)
  }

  private func mouseEvent(type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func requireTmux() throws {
    let result = try runProcess("/usr/bin/env", arguments: ["tmux", "-V"])
    guard result.status == 0 else {
      throw XCTSkip("tmux is not available")
    }
  }

  private func runTmux(name: String, arguments: [String]) throws -> String {
    let result = try runProcess(
      "/usr/bin/env",
      arguments: ["tmux", "-L", name, "-f", "/dev/null"] + arguments)
    guard result.status == 0 else {
      throw NSError(
        domain: "LabanAppTests.tmux",
        code: Int(result.status),
        userInfo: [
          NSLocalizedDescriptionKey:
            "tmux \(arguments.joined(separator: " ")) failed: \(result.stderr)"
        ])
    }
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func tmuxScrollPosition(name: String) throws -> Int {
    let output = try runTmux(
      name: name,
      arguments: ["display-message", "-p", "-t", ":0.0", "#{scroll_position}"])
    return Int(output) ?? 0
  }

  private func waitForTmuxScrollPosition(
    name: String,
    matching predicate: (Int) -> Bool
  ) throws -> Int {
    let deadline = Date().addingTimeInterval(5)
    var last = 0
    while Date() < deadline {
      last = try tmuxScrollPosition(name: name)
      if predicate(last) {
        return last
      }
      usleep(50_000)
    }
    XCTFail("timed out waiting for tmux scroll position; last=\(last)")
    return last
  }

  private func runEventTrackingLoop(for duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
      let slice = min(0.02, deadline.timeIntervalSinceNow)
      if slice <= 0 { break }
      RunLoop.current.run(mode: .eventTracking, before: Date().addingTimeInterval(slice))
    }
  }

  private func waitForByteRingOffset(
    _ reader: LabptyByteRingReader,
    atLeast target: UInt64
  ) throws {
    let deadline = Date().addingTimeInterval(5)
    var last: UInt64 = 0
    while Date() < deadline {
      last = reader.outputWriteOffset()
      if last >= target {
        return
      }
      usleep(50_000)
    }
    XCTFail("timed out waiting for byte ring offset >= \(target); last=\(last)")
    throw NSError(
      domain: "LabanAppTests.byteRing",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "byte ring offset \(last) < \(target)"])
  }

  private func waitUntil(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if condition() {
        return
      }
      usleep(50_000)
    }
    XCTFail(message)
    throw NSError(
      domain: "LabanAppTests.wait",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func runProcess(
    _ executablePath: String,
    arguments: [String]
  ) throws -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    return (
      process.terminationStatus,
      String(data: stdoutData, encoding: .utf8) ?? "",
      String(data: stderrData, encoding: .utf8) ?? ""
    )
  }

}
