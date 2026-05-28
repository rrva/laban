import Darwin
import Foundation
import XCTest

@testable import LabanCore

final class LabptyDaemonTests: XCTestCase {
  private let highInheritedFDCount = 1100
  private var launched: [Process] = []
  private var tempRoots: [URL] = []

  override func tearDown() {
    for process in launched where process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    launched.removeAll()
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  func testOpenAndListAndTerminate() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "open-list-terminate"))

    XCTAssertGreaterThan(descriptor.childPid, 0)
    XCTAssertEqual(Darwin.kill(pid_t(descriptor.childPid), 0), 0)
    let listed = try client.listLabptySessions()
    XCTAssertTrue(listed.contains { $0.ptyHandle == descriptor.ptyHandle && $0.alive })

    _ = try client.terminate(handle: descriptor.ptyHandle)
    try waitForDead(pid: pid_t(descriptor.childPid))
  }

  func testConnectedClientsCountTracksAttachAndDisconnect() throws {
    let harness = try launchHarness()
    let clientA = try waitForClient(socketPath: harness.socketPath)
    defer { clientA.close() }

    // The opener is implicitly attached, so the descriptor it gets back
    // already reports one connected client.
    let opened = try clientA.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "60"], logicalSessionId: "counter"))
    let handle = opened.ptyHandle
    XCTAssertEqual(opened.connectedClients, 1)
    XCTAssertEqual(try connectedCount(clientA, handle: handle), 1)

    // A second connection attaches: the count rises to 2, visible to A.
    let clientB = try waitForClient(socketPath: harness.socketPath)
    let afterAttach = try clientB.attachLabptySession(handle: handle)
    XCTAssertEqual(afterAttach.connectedClients, 2)
    XCTAssertEqual(try connectedCount(clientA, handle: handle), 2)

    // B drops its socket. The daemon only learns on its next poll cycle,
    // so poll-until the count falls back to 1 rather than asserting now.
    clientB.close()
    try waitForConnectedCount(clientA, handle: handle, expected: 1)

    // A detaches without terminating: count hits 0 but the shell lives on
    // — this is exactly the "adoptable orphan" signal (alive, zero owners).
    let afterDetach = try clientA.detachLabptySession(handle: handle)
    XCTAssertEqual(afterDetach.connectedClients, 0)
    let listed = try clientA.listLabptySessions().first { $0.ptyHandle == handle }
    XCTAssertEqual(listed?.alive, true)
    XCTAssertEqual(listed?.connectedClients, 0)

    _ = try clientA.terminate(handle: handle)
  }

  func testEstablishedIdleClientStaysCounted() throws {
    let harness = try launchHarness()
    let owner = try waitForClient(socketPath: harness.socketPath)
    defer { owner.close() }
    let opened = try owner.openSession(
      LabptyOpenSessionRequest(
        rows: 24, cols: 80, argv: ["/bin/sleep", "60"], logicalSessionId: "idle-counter"))

    // `owner` is established (hello + open). A live tab reads output over
    // the byte ring, not the control socket, so the socket sits idle for
    // long stretches. Idle well past LABPTY_IO_IDLE_TIMEOUT_NS (250ms): if
    // the daemon reaped established-idle clients, the count would
    // false-drop to 0 on a live session and break orphan detection.
    usleep(700_000)

    let observer = try waitForClient(socketPath: harness.socketPath)
    defer { observer.close() }
    XCTAssertEqual(
      try connectedCount(observer, handle: opened.ptyHandle), 1,
      "an established but idle owner must stay counted")

    _ = try owner.terminate(handle: opened.ptyHandle)
  }

  private func connectedCount(
    _ client: LabptyTerminalSessionClient, handle: UInt64
  ) throws -> UInt32 {
    try client.listLabptySessions().first { $0.ptyHandle == handle }?.connectedClients ?? 0
  }

  private func waitForConnectedCount(
    _ client: LabptyTerminalSessionClient, handle: UInt64, expected: UInt32
  ) throws {
    let deadline = Date().addingTimeInterval(2)
    var last: UInt32 = .max
    while Date() < deadline {
      last = try connectedCount(client, handle: handle)
      if last == expected { return }
      usleep(20_000)
    }
    XCTFail("connectedClients for \(handle) settled at \(last), expected \(expected)")
  }

  func testDaemonToleratesHighInheritedFileDescriptors() throws {
    try requireHighInheritedFDLimit()
    let harness = try launchHarness(inheritHighFileDescriptors: true)
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/cat"],
        logicalSessionId: "high-inherited-fd"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    try client.writeInput(handle: descriptor.ptyHandle, bytes: Array("high-fd-ok\n".utf8))
    let output = try waitForOutput(reader: reader, contains: "high-fd-ok")
    XCTAssertTrue(output.contains("high-fd-ok"))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testSignalSendsToProcessGroup() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "while true; do sleep 1; done"],
        logicalSessionId: "signal-test"))

    _ = try client.signal(handle: descriptor.ptyHandle, signal: Int32(SIGKILL))
    try waitForDead(pid: pid_t(descriptor.childPid))
  }

  func testResizeUpdatesWinsize() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "resize-test"))

    let resized = try client.resize(handle: descriptor.ptyHandle, rows: 41, cols: 132)
    XCTAssertEqual(resized.rows, 41)
    XCTAssertEqual(resized.cols, 132)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testListSessionsCarriesByteRingPath() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "ring-path-test"))
    let listed = try XCTUnwrap(try client.listLabptySessions().first)

    XCTAssertEqual(listed.byteRingShmPath, descriptor.byteRingShmPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: listed.byteRingShmPath))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testWriteBySessionIdReconnectsAfterControlSocketClose() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/cat"],
        logicalSessionId: "reconnect-write"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    client.close()
    try client.writeInput(sessionId: "reconnect-write", bytes: Array("after-reconnect\n".utf8))

    let output = try waitForOutput(reader: reader, contains: "after-reconnect")
    XCTAssertTrue(output.contains("after-reconnect"))
    _ = try client.terminate(sessionId: "reconnect-write")
  }

  func testSessionIdWriteRefreshesStaleHandleCache() throws {
    let harness = try launchHarness()
    let staleClient = try waitForClient(socketPath: harness.socketPath)
    defer { staleClient.close() }
    let manager = try waitForClient(socketPath: harness.socketPath)
    defer { manager.close() }

    let first = try staleClient.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/cat"],
        logicalSessionId: "stale-handle-write"))
    _ = try manager.terminate(handle: first.ptyHandle)
    try waitForDead(pid: pid_t(first.childPid))

    let second = try manager.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/cat"],
        logicalSessionId: "stale-handle-write"))
    let reader = try LabptyByteRingReader(path: second.byteRingShmPath)

    try staleClient.writeInput(sessionId: "stale-handle-write", bytes: Array("after-reuse\n".utf8))
    let output = try waitForOutput(reader: reader, contains: "after-reuse")
    XCTAssertTrue(output.contains("after-reuse"))
    _ = try staleClient.terminate(sessionId: "stale-handle-write")
  }

  func testTerminateReleasesSlotsAndRingFilesForReuse() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    for index in 0...LabptyProtocolLimits.maxSessionDescriptorCount {
      let descriptor = try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: ["/bin/sleep", "30"],
          logicalSessionId: "reuse-\(index)"))
      let ringPath = descriptor.byteRingShmPath
      XCTAssertTrue(FileManager.default.fileExists(atPath: ringPath))

      _ = try client.terminate(handle: descriptor.ptyHandle)
      try waitForDead(pid: pid_t(descriptor.childPid))
      try waitForPathGone(ringPath)
    }
  }

  func testInvalidRingCapacityDoesNotKillDaemon() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let badCapacities = [
      UInt64(LabptyByteRingLayout.minimumOutputRingCapacity - 1),
      UInt64(LabptyByteRingLayout.maximumOutputRingCapacity) + 1,
    ]
    for (index, capacity) in badCapacities.enumerated() {
      let markerPath = "\(harness.shmDir)/bad-capacity-\(index).marker"
      XCTAssertThrowsError(
        try client.openSession(
          LabptyOpenSessionRequest(
            rows: 24,
            cols: 80,
            outputRingCapacity: capacity,
            argv: ["/bin/sh", "-c", "touch \"\(markerPath)\"; sleep 30"],
            logicalSessionId: "bad-capacity-\(index)")))
      XCTAssertTrue(harness.process.isRunning)
      usleep(100_000)
      XCTAssertFalse(FileManager.default.fileExists(atPath: markerPath))
    }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "after-bad-capacity"))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testStalledClientIsDisconnectedWithoutBlockingDaemon() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let raw = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(raw) }
    try setReceiveTimeout(fd: raw, milliseconds: 100)

    var byte: UInt8 = LabptyFrameHeader.magic[0]
    XCTAssertEqual(Darwin.write(raw, &byte, 1), 1)
    try waitForSocketClosed(fd: raw)

    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    _ = try client.hello()
  }

  func testSocketPathIsOwnerOnly() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let attrs = try FileManager.default.attributesOfItem(atPath: harness.socketPath)
    let permissions = try XCTUnwrap(attrs[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
  }

  func testSecondDaemonCannotStealLiveSocket() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/cat"],
        logicalSessionId: "socket-steal"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = root.appendingPathComponent(".build/debug/labpty")
    process.arguments = ["--socket", harness.socketPath, "--shm-dir", harness.shmDir]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    launched.append(process)
    try waitForProcessExit(process)
    XCTAssertNotEqual(process.terminationStatus, 0)

    let reattached = try waitForClient(socketPath: harness.socketPath)
    defer { reattached.close() }
    let listed = try reattached.listLabptySessions()
    XCTAssertTrue(listed.contains { $0.ptyHandle == descriptor.ptyHandle && $0.alive })

    try reattached.writeInput(handle: descriptor.ptyHandle, bytes: Array("still-attached\n".utf8))
    let output = try waitForOutput(reader: reader, contains: "still-attached")
    XCTAssertTrue(output.contains("still-attached"))
    _ = try reattached.terminate(handle: descriptor.ptyHandle)
  }

  func testDaemonCanRestartAfterCrashWhileChildIgnoresHangup() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: [
          "/bin/sh",
          "-c",
          "trap '' HUP; (trap '' HUP; exec /bin/sleep 30 </dev/null >/dev/null 2>/dev/null) & echo survivor:$!; wait",
        ],
        logicalSessionId: "restart-after-crash"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    let output = try waitForOutput(reader: reader, contains: "survivor:")
    let survivorLine = try XCTUnwrap(output.split(whereSeparator: \.isNewline).first {
      $0.hasPrefix("survivor:")
    })
    let survivorPid = try XCTUnwrap(pid_t(String(survivorLine.dropFirst("survivor:".count))))
    defer {
      _ = Darwin.kill(survivorPid, SIGKILL)
      _ = Darwin.kill(-pid_t(descriptor.childPid), SIGKILL)
      try? waitForDead(pid: pid_t(descriptor.childPid))
    }

    XCTAssertEqual(Darwin.kill(pid_t(harness.process.processIdentifier), SIGKILL), 0)
    try waitForProcessExit(harness.process)

    let replacement = try launchReplacementHarness(
      socketPath: harness.socketPath,
      shmDir: harness.shmDir)
    let replacementClient = try waitForClient(socketPath: replacement.socketPath)
    defer { replacementClient.close() }
    _ = try replacementClient.hello()
  }

  func testShortLivedSessionPreservesOutputUntilTerminate() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "printf quick-output; exit 0"],
        logicalSessionId: "short-lived-drain"))
    let ringPath = descriptor.byteRingShmPath

    try waitForDead(pid: pid_t(descriptor.childPid))
    XCTAssertTrue(FileManager.default.fileExists(atPath: ringPath))

    let reader = try LabptyByteRingReader(path: ringPath)
    let output = try waitForOutput(reader: reader, contains: "quick-output")
    XCTAssertTrue(output.contains("quick-output"))

    var sawDead = false
    let listDeadline = Date().addingTimeInterval(2)
    while Date() < listDeadline {
      let listed = try client.listLabptySessions()
      if listed.contains(where: { $0.ptyHandle == descriptor.ptyHandle && !$0.alive }) {
        sawDead = true
        break
      }
      usleep(50_000)
    }
    XCTAssertTrue(sawDead, "dead session must remain listed until terminate")

    _ = try client.terminate(handle: descriptor.ptyHandle)
    try waitForPathGone(ringPath)
  }

  func testNaturalExitAllowsLogicalSessionIdReuse() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let first = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "exit 0"],
        logicalSessionId: "reuse-natural-exit"))
    try waitForDead(pid: pid_t(first.childPid))
    try waitForSessionAliveState(
      client: client,
      handle: first.ptyHandle,
      alive: false)

    let second = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "reuse-natural-exit"))

    XCTAssertNotEqual(second.ptyHandle, first.ptyHandle)
    XCTAssertTrue(second.alive)
    _ = try client.terminate(handle: second.ptyHandle)
  }

  func testNaturalExitedSessionsAreReclaimedUnderSlotPressure() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    var handles: [UInt64] = []

    for index in 0..<LabptyProtocolLimits.maxSessionDescriptorCount {
      let descriptor = try client.openSession(
        LabptyOpenSessionRequest(
          rows: 24,
          cols: 80,
          argv: ["/bin/sh", "-c", "exit 0"],
          logicalSessionId: "natural-exit-\(index)"))
      handles.append(descriptor.ptyHandle)
      try waitForDead(pid: pid_t(descriptor.childPid))
    }
    for handle in handles {
      try waitForSessionAliveState(client: client, handle: handle, alive: false)
    }

    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "after-natural-exits"))

    XCTAssertTrue(descriptor.alive)
    XCTAssertFalse(handles.contains(descriptor.ptyHandle))
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testStalledClientDoesNotBlockSessionDraining() throws {
    let harness = try launchHarness()
    let active = try waitForClient(socketPath: harness.socketPath)
    defer { active.close() }
    let descriptor = try active.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", "printf phase-one; sleep 1; printf phase-two"],
        logicalSessionId: "stall-test"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    try waitForSocketFile(socketPath: harness.socketPath)
    let stalled = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(stalled) }
    var byte: UInt8 = LabptyFrameHeader.magic[0]
    XCTAssertEqual(Darwin.write(stalled, &byte, 1), 1)

    _ = try waitForOutput(reader: reader, contains: "phase-two")
    _ = try active.terminate(handle: descriptor.ptyHandle)
  }

  func testOpenRejectsInvalidWinsize() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }

    let invalid: [(UInt32, UInt32)] = [(0, 80), (24, 0), (24, 100_000), (100_000, 80)]
    for (index, dim) in invalid.enumerated() {
      XCTAssertThrowsError(
        try client.openSession(
          LabptyOpenSessionRequest(
            rows: dim.0,
            cols: dim.1,
            argv: ["/bin/sleep", "30"],
            logicalSessionId: "bad-winsize-\(index)")))
      XCTAssertTrue(harness.process.isRunning)
    }
  }

  func testHelloRequiresPhase1Capabilities() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let raw = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(raw) }

    let payload = try LabptyHelloRequest(
      clientId: "missing-caps", capabilities: []).encode()
    let frame = try LabptyFraming.encodeRequest(
      operation: .hello, sequence: 1, payload: payload)
    try writeAllRaw(fd: raw, data: frame)
    let response = try readFrameRaw(fd: raw)
    XCTAssertEqual(response.header.operationRaw, LabptyFrameHeader.responseOperation)
    XCTAssertNotEqual(response.header.responseCode, .ok)
    XCTAssertTrue(harness.process.isRunning)
  }

  func testRejectedPreHelloClientsDoNotExhaustControlSlots() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    var rejectedFds: [Int32] = []
    defer {
      for fd in rejectedFds {
        Darwin.close(fd)
      }
    }

    for index in 0..<8 {
      let fd = try connectRaw(socketPath: harness.socketPath)
      rejectedFds.append(fd)
      try setReceiveTimeout(fd: fd, milliseconds: 500)
      let payload = try LabptyHelloRequest(
        clientId: "missing-caps-\(index)",
        capabilities: []
      ).encode()
      let frame = try LabptyFraming.encodeRequest(
        operation: .hello,
        sequence: UInt64(index + 1),
        payload: payload)
      try writeAllRaw(fd: fd, data: frame)
      let response = try readFrameRaw(fd: fd)
      XCTAssertEqual(response.header.responseCode, .capabilityRequired)
    }

    let deadline = Date().addingTimeInterval(2)
    var connectedClient: LabptyTerminalSessionClient?
    var lastError: Error?
    while Date() < deadline {
      do {
        let client = try LabptyTerminalSessionClient(
          socketPath: harness.socketPath,
          rpcTimeoutMilliseconds: 200)
        _ = try client.hello()
        connectedClient = client
        break
      } catch {
        lastError = error
        usleep(50_000)
      }
    }
    let client = try XCTUnwrap(
      connectedClient,
      "rejected pre-hello clients kept all control slots busy: \(String(describing: lastError))")
    defer { client.close() }
    XCTAssertNoThrow(try client.listLabptySessions())
    XCTAssertTrue(harness.process.isRunning)
  }

  func testNonHelloRequestBeforeHelloIsRejected() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let raw = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(raw) }

    let listFrame = try LabptyFraming.encodeRequest(
      operation: .listSessions, sequence: 7, payload: Data())
    try writeAllRaw(fd: raw, data: listFrame)
    let rejected = try readFrameRaw(fd: raw)
    XCTAssertEqual(rejected.header.sequence, 7)
    XCTAssertEqual(rejected.header.responseCode, .capabilityRequired)

    let helloFrame = try LabptyFraming.encodeRequest(
      operation: .hello,
      sequence: 8,
      payload: try LabptyHelloRequest(clientId: "after-reject").encode())
    try writeAllRaw(fd: raw, data: helloFrame)
    let accepted = try readFrameRaw(fd: raw)
    XCTAssertEqual(accepted.header.sequence, 8)
    XCTAssertEqual(accepted.header.responseCode, .ok)
    XCTAssertTrue(harness.process.isRunning)
  }

  // Regression for ADR 0007's "additive-only" promise: an OLD labpty must
  // accept trailing bytes appended by a NEWER client to every fixed-shape
  // request decoder. Without that tolerance, any future field added to
  // hello/open/resize/signal/terminate would force users to upgrade
  // labpty in lockstep — exactly what the rock-solid-forever contract
  // forbids. Strict-exhaust regressions here would silently force daemon
  // upgrades, so this test pins the contract end-to-end through the
  // wire format.
  func testFixedShapeRequestsTolerateTrailingAdditiveBytes() throws {
    let harness = try launchHarness()
    try waitForSocketFile(socketPath: harness.socketPath)
    let raw = try connectRaw(socketPath: harness.socketPath)
    defer { Darwin.close(raw) }

    let extra = Data(repeating: 0xAB, count: 16)

    let helloPayload = try LabptyHelloRequest(clientId: "additive-hello").encode() + extra
    let helloFrame = try LabptyFraming.encodeRequest(
      operation: .hello, sequence: 1, payload: helloPayload)
    try writeAllRaw(fd: raw, data: helloFrame)
    let helloResponse = try readFrameRaw(fd: raw)
    XCTAssertEqual(helloResponse.header.sequence, 1)
    XCTAssertEqual(helloResponse.header.responseCode, .ok)

    let openPayload =
      try LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "additive-open").encode() + extra
    let openFrame = try LabptyFraming.encodeRequest(
      operation: .openSession, sequence: 2, payload: openPayload)
    try writeAllRaw(fd: raw, data: openFrame)
    let openResponse = try readFrameRaw(fd: raw)
    XCTAssertEqual(openResponse.header.sequence, 2)
    XCTAssertEqual(openResponse.header.responseCode, .ok)
    let descriptor = try LabptySessionDescriptor.decode(from: openResponse.payload)

    let resizePayload =
      LabptyResizeSessionRequest(ptyHandle: descriptor.ptyHandle, rows: 30, cols: 100).encode()
      + extra
    let resizeFrame = try LabptyFraming.encodeRequest(
      operation: .resizeSession, sequence: 3, payload: resizePayload)
    try writeAllRaw(fd: raw, data: resizeFrame)
    let resizeResponse = try readFrameRaw(fd: raw)
    XCTAssertEqual(resizeResponse.header.sequence, 3)
    XCTAssertEqual(resizeResponse.header.responseCode, .ok)

    let signalPayload =
      LabptySignalSessionRequest(ptyHandle: descriptor.ptyHandle, signal: 0).encode() + extra
    let signalFrame = try LabptyFraming.encodeRequest(
      operation: .signalSession, sequence: 4, payload: signalPayload)
    try writeAllRaw(fd: raw, data: signalFrame)
    let signalResponse = try readFrameRaw(fd: raw)
    XCTAssertEqual(signalResponse.header.sequence, 4)
    XCTAssertEqual(signalResponse.header.responseCode, .ok)

    let terminatePayload =
      LabptyTerminateSessionRequest(ptyHandle: descriptor.ptyHandle).encode() + extra
    let terminateFrame = try LabptyFraming.encodeRequest(
      operation: .terminateSession, sequence: 5, payload: terminatePayload)
    try writeAllRaw(fd: raw, data: terminateFrame)
    let terminateResponse = try readFrameRaw(fd: raw)
    XCTAssertEqual(terminateResponse.header.sequence, 5)
    XCTAssertEqual(terminateResponse.header.responseCode, .ok)

    XCTAssertTrue(harness.process.isRunning)
  }

  func testShutdownSignalTerminatesSessionsAndUnlinksArtifacts() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "shutdown-cleanup"))
    let ringPath = descriptor.byteRingShmPath
    XCTAssertTrue(FileManager.default.fileExists(atPath: ringPath))

    XCTAssertEqual(Darwin.kill(pid_t(harness.process.processIdentifier), SIGTERM), 0)
    try waitForProcessExit(harness.process)
    try waitForDead(pid: pid_t(descriptor.childPid))
    try waitForPathGone(harness.socketPath)
    try waitForPathGone(ringPath)
  }

  func testByteRingHeaderAndCapacity() throws {
    let url = try temporaryRingURL()
    let writer = try LabptyByteRingWriter(
      path: url.path,
      outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity),
      logicalSessionId: "header")
    _ = writer
    let reader = try LabptyByteRingReader(path: url.path)

    XCTAssertEqual(reader.outputRingOffset, LabptyByteRingLayout.inputRingOffset)
    XCTAssertEqual(reader.outputRingCapacity, UInt64(LabptyByteRingLayout.minimumOutputRingCapacity))
  }

  func testByteRingReaderToleratesAdditiveHeaderLayout() throws {
    let url = try temporaryRingURL()
    let payload = Data("future-compatible-output".utf8)
    let capacity = UInt64(LabptyByteRingLayout.minimumOutputRingCapacity)
    do {
      let writer = try LabptyByteRingWriter(
        path: url.path,
        outputRingCapacity: capacity,
        logicalSessionId: "future-header")
      writer.write(payload)
    }

    let headerBytes: UInt32 = 192
    let countersOffset: UInt32 = 256
    let readerSlotOffset: UInt32 = 384
    let readerSlotBytes: UInt32 = 96
    let readerSlotCount = LabptyByteRingLayout.readerSlotCount
    let inputRingOffset = UInt64(readerSlotOffset) + UInt64(readerSlotBytes) * UInt64(readerSlotCount)
    let outputRingOffset = inputRingOffset
    let oldOutputRingOffset = LabptyByteRingLayout.inputRingOffset
    let newFileLength = outputRingOffset + capacity
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: newFileLength)
    try copyBytes(
      handle: handle,
      from: oldOutputRingOffset,
      to: outputRingOffset,
      count: UInt64(payload.count))
    try copyBytes(
      handle: handle,
      from: LabptyByteRingLayout.outputBytesWrittenTotalOffset,
      to: UInt64(countersOffset),
      count: 8)
    try copyBytes(
      handle: handle,
      from: LabptyByteRingLayout.outputWrapCountOffset,
      to: UInt64(countersOffset + 16),
      count: 8)
    try copyBytes(
      handle: handle,
      from: LabptyByteRingLayout.producerAliveMonoNsOffset,
      to: UInt64(countersOffset + 32),
      count: 8)
    try patchUInt32(handle: handle, offset: 16, value: headerBytes)
    try patchUInt32(handle: handle, offset: 20, value: countersOffset)
    try patchUInt32(handle: handle, offset: 24, value: readerSlotOffset)
    try patchUInt32(handle: handle, offset: 28, value: readerSlotBytes)
    try patchUInt64(handle: handle, offset: 40, value: inputRingOffset)
    try patchUInt64(handle: handle, offset: 56, value: outputRingOffset)
    try patchUInt64(handle: handle, offset: 72, value: newFileLength)

    let reader = try LabptyByteRingReader(path: url.path)
    let result = reader.readSince(0)

    XCTAssertEqual(reader.outputRingOffset, outputRingOffset)
    XCTAssertEqual(result.bytes, payload)
    XCTAssertFalse(result.overflowed)
  }

  func testByteRingRoundTripSmall() throws {
    let url = try temporaryRingURL()
    let writer = try LabptyByteRingWriter(
      path: url.path,
      outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity),
      logicalSessionId: "small")
    let reader = try LabptyByteRingReader(path: url.path)

    writer.write(Data("hello labpty".utf8))
    let result = reader.readSince(0)

    XCTAssertEqual(String(data: result.bytes, encoding: .utf8), "hello labpty")
    XCTAssertFalse(result.overflowed)
  }

  func testByteRingWrapDetection() throws {
    let url = try temporaryRingURL()
    let capacity = UInt64(LabptyByteRingLayout.minimumOutputRingCapacity)
    let writer = try LabptyByteRingWriter(path: url.path, outputRingCapacity: capacity)
    let reader = try LabptyByteRingReader(path: url.path)
    var payload = Data()
    payload.reserveCapacity(Int(capacity * 2 + 32))
    for index in 0..<Int(capacity * 2 + 32) {
      payload.append(UInt8(index & 0xFF))
    }

    writer.write(payload)
    let result = reader.readSince(0)

    XCTAssertTrue(result.overflowed)
    let expectedCount = Int(LabptyByteRingLayout.readableOutputWindow(for: capacity))
    XCTAssertEqual(result.bytes.count, expectedCount)
    XCTAssertEqual(result.bytes, Data(payload.suffix(expectedCount)))
    XCTAssertEqual(result.newOffset, UInt64(payload.count))
  }

  func testByteRingReaderRejectsUnsupportedAbiMajor() throws {
    let url = try temporaryRingURL()
    do {
      _ = try LabptyByteRingWriter(
        path: url.path,
        outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity))
    }
    try patchUInt32(url: url, offset: 8, value: 99)

    XCTAssertThrowsError(try LabptyByteRingReader(path: url.path))
  }

  func testByteRingReaderRejectsOutputSpanPastEndOfFile() throws {
    let url = try temporaryRingURL()
    do {
      _ = try LabptyByteRingWriter(
        path: url.path,
        outputRingCapacity: UInt64(LabptyByteRingLayout.minimumOutputRingCapacity))
    }
    XCTAssertEqual(Darwin.truncate(url.path, off_t(LabptyByteRingLayout.inputRingOffset + 1024)), 0)

    XCTAssertThrowsError(try LabptyByteRingReader(path: url.path))
  }

  func testProducerAliveHeartbeat() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sleep", "30"],
        logicalSessionId: "heartbeat"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let first = reader.producerAliveMonoNs()
    usleep(150_000)
    let second = reader.producerAliveMonoNs()

    XCTAssertGreaterThan(second, first + 50_000_000)
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  func testHighVolumeOutputIsNotSplitOrLost() throws {
    let harness = try launchHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let command =
      "i=1; while [ $i -le 100000 ]; do printf 'line-%06d\\n' \"$i\"; i=$((i+1)); done; sleep 2"
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: 24,
        cols: 80,
        argv: ["/bin/sh", "-c", command],
        logicalSessionId: "high-volume"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let output = try waitForOutput(reader: reader, contains: "line-100000")
    let regex = try NSRegularExpression(pattern: #"line-(\d{6})"#)
    let nsOutput = output as NSString
    let matches = regex.matches(
      in: output,
      range: NSRange(location: 0, length: nsOutput.length))

    XCTAssertEqual(matches.count, 100_000)
    XCTAssertEqual(nsOutput.substring(with: matches.first!.range), "line-000001")
    XCTAssertEqual(nsOutput.substring(with: matches.last!.range), "line-100000")
    for (index, match) in matches.enumerated() {
      let expected = String(format: "line-%06d", index + 1)
      let actual = nsOutput.substring(with: match.range)
      if actual != expected {
        XCTFail("expected \(expected), got \(actual) at match \(index)")
        break
      }
    }
    _ = try client.terminate(handle: descriptor.ptyHandle)
  }

  private struct Harness {
    let socketPath: String
    let shmDir: String
    let process: Process
  }

  private func launchHarness(inheritHighFileDescriptors: Bool = false) throws -> Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let runId = "labpty-\(UUID().uuidString)"
    let tempRoot = ".tmp/\(runId)"
    let shmDir = "\(tempRoot)/shm"
    tempRoots.append(root.appendingPathComponent(tempRoot, isDirectory: true))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(shmDir),
      withIntermediateDirectories: true)
    let socketPath = "\(tempRoot)/s.sock"
    let process = try launchHarnessProcess(
      root: root,
      socketPath: socketPath,
      shmDir: shmDir,
      inheritHighFileDescriptors: inheritHighFileDescriptors)
    launched.append(process)
    return Harness(socketPath: socketPath, shmDir: shmDir, process: process)
  }

  private func launchReplacementHarness(socketPath: String, shmDir: String) throws -> Harness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let process = try launchHarnessProcess(
      root: root,
      socketPath: socketPath,
      shmDir: shmDir,
      inheritHighFileDescriptors: false)
    launched.append(process)
    return Harness(socketPath: socketPath, shmDir: shmDir, process: process)
  }

  private func launchHarnessProcess(
    root: URL,
    socketPath: String,
    shmDir: String,
    inheritHighFileDescriptors: Bool
  ) throws -> Process {
    let executable = root.appendingPathComponent(".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build labpty first: swift build --product labpty")
    }
    let process = Process()
    process.currentDirectoryURL = root
    if inheritHighFileDescriptors {
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = [
        "-c",
        highInheritedFDLaunchScript(),
        "labpty-high-fd",
        executable.path,
        socketPath,
        shmDir,
      ]
    } else {
      process.executableURL = executable
      process.arguments = ["--socket", socketPath, "--shm-dir", shmDir]
    }
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
  }

  private func requireHighInheritedFDLimit() throws {
    var limit = rlimit()
    guard Darwin.getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard limit.rlim_cur > rlim_t(highInheritedFDCount + 16) else {
      throw XCTSkip("RLIMIT_NOFILE is too low to exercise high inherited fds")
    }
  }

  private func highInheritedFDLaunchScript() -> String {
    """
    typeset -a labpty_fds
    integer i=0
    while (( i < \(highInheritedFDCount) )); do
      exec {fd}</dev/null || exit 70
      labpty_fds+=($fd)
      (( i++ ))
    done
    exec "$1" --socket "$2" --shm-dir "$3"
    """
  }

  private func waitForClient(socketPath: String) throws -> LabptyTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        do {
          return try LabptyTerminalSessionClient(socketPath: socketPath)
        } catch {
          lastError = error
        }
      }
      usleep(50_000)
    }
    if let lastError { throw lastError }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForSocketFile(socketPath: String) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        return
      }
      usleep(50_000)
    }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForDead(pid: pid_t) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
        return
      }
      usleep(50_000)
    }
    XCTFail("pid \(pid) was still alive")
  }

  private func waitForPathGone(_ path: String) throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if !FileManager.default.fileExists(atPath: path) {
        return
      }
      usleep(20_000)
    }
    XCTFail("path \(path) still existed")
  }

  private func waitForProcessExit(_ process: Process) throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if !process.isRunning {
        return
      }
      usleep(20_000)
    }
    XCTFail("process \(process.processIdentifier) was still running")
  }

  private func waitForSessionAliveState(
    client: LabptyTerminalSessionClient,
    handle: UInt64,
    alive: Bool
  ) throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if let descriptor = try client.listLabptySessions().first(where: { $0.ptyHandle == handle }),
        descriptor.alive == alive
      {
        return
      }
      usleep(20_000)
    }
    XCTFail("session \(handle) did not reach alive=\(alive)")
  }

  private func waitForSocketClosed(fd: Int32) throws {
    let deadline = Date().addingTimeInterval(2)
    var byte: UInt8 = 0
    while Date() < deadline {
      let n = Darwin.read(fd, &byte, 1)
      if n == 0 {
        return
      }
      if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
        usleep(20_000)
        continue
      }
      if n < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    XCTFail("stalled socket was not closed")
  }

  private func connectRaw(socketPath: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let err = errno
      Darwin.close(fd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    return fd
  }

  private func writeAllRaw(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }

  private func readExactRaw(fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    let deadline = Date().addingTimeInterval(2)
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { throw POSIXError(.ECONNRESET) }
      if n < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK {
          if Date() > deadline { throw POSIXError(.ETIMEDOUT) }
          usleep(10_000)
          continue
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
    return data
  }

  private func readFrameRaw(fd: Int32) throws -> LabptyFrame {
    let header = try readExactRaw(fd: fd, count: LabptyFrameHeader.headerByteCount)
    let headerBytes = [UInt8](header)
    let totalLength = Int(
      UInt32(headerBytes[8])
        | (UInt32(headerBytes[9]) << 8)
        | (UInt32(headerBytes[10]) << 16)
        | (UInt32(headerBytes[11]) << 24))
    guard totalLength >= LabptyFrameHeader.headerByteCount else {
      throw LabptyProtocolError.truncatedFrame
    }
    let body = try readExactRaw(fd: fd, count: totalLength - LabptyFrameHeader.headerByteCount)
    return try LabptyFraming.decode(header + body)
  }

  private func setReceiveTimeout(fd: Int32, milliseconds: Int) throws {
    var timeout = timeval(tv_sec: milliseconds / 1000, tv_usec: Int32((milliseconds % 1000) * 1000))
    let result = setsockopt(
      fd,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &timeout,
      socklen_t(MemoryLayout<timeval>.size))
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func waitForOutput(reader: LabptyByteRingReader, contains needle: String) throws -> String {
    let deadline = Date().addingTimeInterval(10)
    var offset: UInt64 = 0
    var data = Data()
    while Date() < deadline {
      let result = reader.readSince(offset)
      offset = result.newOffset
      data.append(result.bytes)
      if let text = String(data: data, encoding: .utf8), text.contains(needle) {
        return text
      }
      usleep(10_000)
    }
    let text = String(data: data, encoding: .utf8) ?? "<invalid utf8>"
    XCTFail("output never contained \(needle); got \(text.suffix(200))")
    throw POSIXError(.ETIMEDOUT)
  }

  private func temporaryRingURL() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let dir = root.appendingPathComponent(".tmp")
      .appendingPathComponent("labpty-ring-tests-\(UUID().uuidString)", isDirectory: true)
    tempRoots.append(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("ring.br")
  }

  private func patchUInt32(url: URL, offset: UInt64, value: UInt32) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try patchUInt32(handle: handle, offset: offset, value: value)
  }

  private func patchUInt32(handle: FileHandle, offset: UInt64, value: UInt32) throws {
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: Data([
      UInt8(value & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 24) & 0xFF),
    ]))
  }

  private func patchUInt64(handle: FileHandle, offset: UInt64, value: UInt64) throws {
    try handle.seek(toOffset: offset)
    var bytes = Data()
    bytes.reserveCapacity(8)
    for index in 0..<8 {
      bytes.append(UInt8((value >> UInt64(index * 8)) & 0xFF))
    }
    try handle.write(contentsOf: bytes)
  }

  private func copyBytes(handle: FileHandle, from: UInt64, to: UInt64, count: UInt64) throws {
    try handle.seek(toOffset: from)
    let data = try handle.read(upToCount: Int(count)) ?? Data()
    XCTAssertEqual(UInt64(data.count), count)
    try handle.seek(toOffset: to)
    try handle.write(contentsOf: data)
  }
}
