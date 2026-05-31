import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// True cross-backend bitmap parity: drive a deterministic child
/// program through two different terminal-session backends — the
/// in-process Session (libghostty owns the PTY in this process)
/// and a real labpty daemon (separate process, byte ring feeds a
/// fixture-mode local Session) — then render both screens with the
/// same software renderer and assert pixel-identical output.
///
/// What this guards against:
///   - The two backends seeing different bytes for the same child.
///     Catches PTY-setup divergence, line-ending drift between
///     in-process libghostty's pump and the labpty daemon's read
///     loop, or VT-parser-state differences between a long-lived
///     session and a fresh fixture replay.
///   - The byte ring's write/read path corrupting or reordering
///     bytes vs the in-process pump.
///   - Future renderer changes that produce different pixels for
///     the same cell grid depending on construction path (e.g. a
///     glyph-cache key bug that's sensitive to feed order).
///
/// What this does NOT guard against (separate test layer):
///   - Concurrency / dirty-bit race between parser thread and
///     render thread (covered in `MarkRenderedSnapshotRaceTests`).
///   - Live-app paste paths through `TerminalBitmapView` (covered
///     in `TerminalPasteTests` + `BitmapInvarianceTests`).
final class CrossBackendBitmapTests: XCTestCase {

  // MARK: - Backend harnesses

  private struct LabptyHarness {
    let socketPath: String
    let shmDir: String
    let process: Process
  }

  private var launchedProcesses: [Process] = []
  private var tempRoots: [URL] = []

  override func tearDownWithError() throws {
    for process in launchedProcesses where process.isRunning {
      process.terminate()
    }
    for process in launchedProcesses where process.isRunning {
      process.waitUntilExit()
    }
    for url in tempRoots {
      try? FileManager.default.removeItem(at: url)
    }
    launchedProcesses.removeAll()
    tempRoots.removeAll()
  }

  private struct LabandHarness {
    let socketPath: String
    let process: Process
  }

  private func launchLabandHarness() throws -> LabandHarness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let executable = root.appendingPathComponent(".build/debug/laband")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build laband first: swift build --product laband")
    }
    let runId = "laband-xb-\(UUID().uuidString)"
    let tempRoot = root.appendingPathComponent(".tmp/\(runId)", isDirectory: true)
    tempRoots.append(tempRoot)
    try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let socketPath = "\(tempRoot.path)/s.sock"
    let journalPath = "\(tempRoot.path)/journal"
    try FileManager.default.createDirectory(
      atPath: journalPath, withIntermediateDirectories: true, attributes: nil)

    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--journal", journalPath]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    launchedProcesses.append(process)
    return LabandHarness(socketPath: socketPath, process: process)
  }

  private func waitForLabandClient(socketPath: String) throws -> LabandTerminalSessionClient {
    let deadline = Date().addingTimeInterval(5)
    var lastError: Error?
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) {
        do {
          return try LabandTerminalSessionClient(socketPath: socketPath)
        } catch {
          lastError = error
        }
      }
      usleep(50_000)
    }
    if let lastError { throw lastError }
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForLabandSnapshotContains(
    client: LabandTerminalSessionClient,
    sessionId: String,
    _ needle: String,
    timeout: TimeInterval = 10
  ) throws -> LabandSnapshotResponse {
    let deadline = Date().addingTimeInterval(timeout)
    var lastSnapshot: LabandSnapshotResponse?
    while Date() < deadline {
      let snapshot = try client.snapshot(sessionId: sessionId)
      lastSnapshot = snapshot
      if snapshot.visibleText.contains(needle) { return snapshot }
      usleep(20_000)
    }
    XCTFail(
      "laband snapshot never contained \(needle); last=\(lastSnapshot?.visibleText ?? "<none>")")
    throw POSIXError(.ETIMEDOUT)
  }

  private func renderLabandBitmap(snapshot: LabandSnapshotResponse, rows: Int, cols: Int)
    -> BitmapSurface
  {
    let producer = FrameProducer(
      cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    let commands = producer.commands(from: snapshot, cursorBlinkVisible: true)
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(),
      pixelWidth: cols * 8, pixelHeight: rows * 16, scale: 1)
    _ = backend.render(commands, damage: .full)
    return backend.surface
  }

  private func launchLabptyHarness() throws -> LabptyHarness {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let executable = root.appendingPathComponent(".build/debug/labpty")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw XCTSkip("build labpty first: swift build --product labpty")
    }
    let runId = "labpty-xb-\(UUID().uuidString)"
    let tempRoot = root.appendingPathComponent(".tmp/\(runId)", isDirectory: true)
    tempRoots.append(tempRoot)
    let shmDir = tempRoot.appendingPathComponent("shm").path
    try FileManager.default.createDirectory(
      atPath: shmDir, withIntermediateDirectories: true, attributes: nil)
    let socketPath = tempRoot.appendingPathComponent("s.sock").path

    let process = Process()
    process.currentDirectoryURL = root
    process.executableURL = executable
    process.arguments = ["--socket", socketPath, "--shm-dir", shmDir]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    launchedProcesses.append(process)
    return LabptyHarness(socketPath: socketPath, shmDir: shmDir, process: process)
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

  private func waitForOutputBytes(
    reader: LabptyByteRingReader,
    contains needle: String,
    timeout: TimeInterval = 10
  ) throws -> [UInt8] {
    let deadline = Date().addingTimeInterval(timeout)
    var offset: UInt64 = 0
    var data = Data()
    while Date() < deadline {
      let result = reader.readSince(offset)
      offset = result.newOffset
      data.append(result.bytes)
      if let text = String(data: data, encoding: .utf8), text.contains(needle) {
        return [UInt8](data)
      }
      usleep(10_000)
    }
    XCTFail("byte ring never contained \(needle)")
    throw POSIXError(.ETIMEDOUT)
  }

  private func waitForGridContains(session: Session, _ needle: String, timeout: TimeInterval = 10)
    throws
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if gridString(of: session).contains(needle) { return }
      usleep(10_000)
    }
    XCTFail("in-process grid never contained \(needle)")
    throw POSIXError(.ETIMEDOUT)
  }

  // MARK: - Rendering helpers

  private func gridString(of session: Session) -> String {
    guard let snap = session.snapshot() else { return "" }
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else { return "" }
    var s = ""
    for row in 0..<rows {
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          s += String(bytes: buf, encoding: .utf8) ?? ""
        }
      }
      s += "\n"
    }
    return s
  }

  private func renderBitmap(session: Session, rows: Int, cols: Int) -> BitmapSurface {
    guard let snap = session.snapshot() else {
      return BitmapSurface(width: 1, height: 1)
    }
    defer { laban_snapshot_destroy(snap) }
    let cellWidth = 8
    let cellHeight = 16
    let producer = FrameProducer(
      cellWidth: cellWidth, cellHeight: cellHeight, originX: 0, originY: 0)
    let commands = producer.commands(from: snap, cursorBlinkVisible: true)
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(),
      pixelWidth: cols * cellWidth, pixelHeight: rows * cellHeight, scale: 1)
    _ = backend.render(commands, damage: .full)
    return backend.surface
  }

  // MARK: - The cross-backend test

  /// Drive the same deterministic child program through:
  ///   - an in-process Session (libghostty owns the PTY here)
  ///   - a real labpty daemon → fixture-mode local Session fed from
  ///     the byte ring (the labpty-backend production path)
  /// Then render both with the software renderer and assert pixel
  /// equality. The child writes a fixed payload terminated by a
  /// `DONE` marker that both readers poll for.
  func testInProcessAndLabptyRenderIdenticallyForSameChild() throws {
    let rows = 24
    let cols = 80
    let payload = "alpha\nbeta\ngamma\ndelta\nDONE\n"
    // The child sleeps after printing so neither backend's snapshot
    // sees process_exited != 0. The exit banner FrameProducer adds
    // when status != 0 would otherwise diverge the two renders —
    // in-process knows the child exited, the labpty fixture replay
    // does not.
    let scriptArgv = ["/bin/sh", "-c", "printf '\(payload)'; sleep 60"]

    // --- in-process backend ---
    var sizeStruct = LabanTerminalSize()
    sizeStruct.rows = Int32(rows)
    sizeStruct.cols = Int32(cols)
    let inProcess = try Session.realShell(
      size: sizeStruct,
      launchArgv: scriptArgv)
    // The in-process Session needs an active SessionRunner to drain
    // its PTY; without it the libghostty VT never sees the child's
    // output. The labpty backend has a structurally similar pump
    // inside the daemon, so we run both as their production code
    // would.
    let runner = inProcess.makeRunner(onDirty: {})
    runner?.start()
    try waitForGridContains(session: inProcess, "DONE")
    let inProcessBitmap = renderBitmap(session: inProcess, rows: rows, cols: cols)
    runner?.stop()
    inProcess.close()

    // --- labpty backend ---
    let harness = try launchLabptyHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: UInt32(rows),
        cols: UInt32(cols),
        argv: scriptArgv,
        logicalSessionId: "cross-backend"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)
    let bytes = try waitForOutputBytes(reader: reader, contains: "DONE")

    let labptyLocal = try Session.fixture(size: sizeStruct)
    defer { labptyLocal.close() }
    XCTAssertEqual(labptyLocal.feedOutput(bytes), 0)
    let labptyBitmap = renderBitmap(session: labptyLocal, rows: rows, cols: cols)

    // --- compare ---
    guard let result = BitmapDiff.compare(inProcessBitmap, labptyBitmap) else {
      XCTFail("bitmap dimensions differ")
      return
    }
    if !result.isIdentical {
      BitmapDiffHarness.saveFailureArtifacts(
        label: "cross-backend-printf",
        expected: inProcessBitmap,
        actual: labptyBitmap,
        diff: result.diff,
        file: #file, line: #line)
    }
  }

  /// Three-backend parity: in-process, labpty, and laband all run
  /// the same child program; their rendered bitmaps must be
  /// pixel-identical. laband's snapshot protocol returns a
  /// `LabandSnapshotResponse` (cells already in Swift), so its
  /// render path goes through `FrameProducer.commands(from: Laband…)`
  /// rather than the libghostty `LabanSnapshot` path that
  /// in-process and labpty share. Any divergence between the two
  /// FrameProducer overloads — different default backgrounds,
  /// off-by-one on row direction, exit-banner-only-on-one-side —
  /// shows up here as a visible diff.
  func testInProcessAndLabandAndLabptyRenderIdenticallyForSameChild() throws {
    let rows = 24
    let cols = 80
    let payload = "alpha\nbeta\ngamma\ndelta\nDONE\n"
    let scriptArgv = ["/bin/sh", "-c", "printf '\(payload)'; sleep 60"]

    var sizeStruct = LabanTerminalSize()
    sizeStruct.rows = Int32(rows)
    sizeStruct.cols = Int32(cols)

    // --- in-process backend ---
    let inProcess = try Session.realShell(size: sizeStruct, launchArgv: scriptArgv)
    let runner = inProcess.makeRunner(onDirty: {})
    runner?.start()
    try waitForGridContains(session: inProcess, "DONE")
    let inProcessBitmap = renderBitmap(session: inProcess, rows: rows, cols: cols)
    runner?.stop()
    inProcess.close()

    // --- labpty backend ---
    let labptyHarness = try launchLabptyHarness()
    let labptyClient = try waitForClient(socketPath: labptyHarness.socketPath)
    defer { labptyClient.close() }
    let labptyDescriptor = try labptyClient.openSession(
      LabptyOpenSessionRequest(
        rows: UInt32(rows), cols: UInt32(cols),
        argv: scriptArgv, logicalSessionId: "tri-labpty"))
    let labptyReader = try LabptyByteRingReader(path: labptyDescriptor.byteRingShmPath)
    let labptyBytes = try waitForOutputBytes(reader: labptyReader, contains: "DONE")
    let labptyLocal = try Session.fixture(size: sizeStruct)
    defer { labptyLocal.close() }
    XCTAssertEqual(labptyLocal.feedOutput(labptyBytes), 0)
    let labptyBitmap = renderBitmap(session: labptyLocal, rows: rows, cols: cols)

    // --- laband backend ---
    let labandHarness = try launchLabandHarness()
    let labandClient = try waitForLabandClient(socketPath: labandHarness.socketPath)
    defer { labandClient.close() }
    _ = try labandClient.hello()
    let labandSession = try labandClient.createSession(
      TerminalSessionLaunchRequest(
        executable: scriptArgv[0],
        argv: scriptArgv,
        cwd: FileManager.default.currentDirectoryPath,
        rows: rows, cols: cols))
    let labandSnapshot = try waitForLabandSnapshotContains(
      client: labandClient,
      sessionId: labandSession.logicalSessionId,
      "DONE")
    let labandBitmap = renderLabandBitmap(snapshot: labandSnapshot, rows: rows, cols: cols)

    // --- compare every pair ---
    func assertMatch(_ a: BitmapSurface, _ b: BitmapSurface, label: String) {
      guard let result = BitmapDiff.compare(a, b) else {
        XCTFail("\(label): bitmap dimensions differ")
        return
      }
      if !result.isIdentical {
        BitmapDiffHarness.saveFailureArtifacts(
          label: label, expected: a, actual: b, diff: result.diff,
          file: #file, line: #line)
      }
    }
    assertMatch(inProcessBitmap, labptyBitmap, label: "tri-inprocess-vs-labpty")
    assertMatch(inProcessBitmap, labandBitmap, label: "tri-inprocess-vs-laband")
    assertMatch(labptyBitmap, labandBitmap, label: "tri-labpty-vs-laband")
  }

  /// Cross-backend paste contract: sending the same paste through
  /// the backend-appropriate API must produce identical rendered
  /// output. The buggy labpty path (the one that shipped before
  /// `12cc18d`) called `writePasteCapturingBytes` on the fixture-
  /// mode local Session, which fed the encoded paste directly into
  /// the local VT — visible as duplicated lines in the local grid
  /// that the in-process backend never produced. The fixed path
  /// calls `encodePaste` (encode-only, no VT write) and forwards
  /// the bytes to the daemon via `writeInput`; the daemon's PTY
  /// echo arrives back through the byte ring like any other output.
  /// If the two backends still produce identical bitmaps with this
  /// flow, the contract holds; if they diverge, the regression has
  /// returned.
  func testPasteThroughCorrectAPIsRendersIdentically() throws {
    let rows = 24
    let cols = 80
    // /bin/cat echoes whatever we write to its PTY back out. With
    // the default termios (ICANON | ECHO), both backends produce
    // "hello\r\nhello\r\n" for a "hello\n" write — one from the
    // kernel's ECHO of the input, one from cat reading the line
    // and writing it back. The doubling is fine; what matters is
    // that the two backends produce the *same* bytes.
    let scriptArgv = ["/bin/cat"]
    let pasteText = "hello\n"

    var sizeStruct = LabanTerminalSize()
    sizeStruct.rows = Int32(rows)
    sizeStruct.cols = Int32(cols)

    // --- in-process backend ---
    let inProcess = try Session.realShell(size: sizeStruct, launchArgv: scriptArgv)
    let runner = inProcess.makeRunner(onDirty: {})
    runner?.start()
    // writePasteCapturingBytes is the right API for in-process:
    // fixture_mode == 0 in C, so it writes to the PTY master; cat
    // echoes back.
    _ = inProcess.writePasteCapturingBytes(pasteText)
    try waitForGridContains(session: inProcess, "hello")
    // Give the second echo a moment to land too, otherwise the
    // snapshots can race between "one hello" and "two hellos".
    let inProcessTarget = "hello\nhello"
    try waitForGridContains(session: inProcess, inProcessTarget, timeout: 5)
    let inProcessBitmap = renderBitmap(session: inProcess, rows: rows, cols: cols)
    runner?.stop()
    inProcess.close()

    // --- labpty backend ---
    let harness = try launchLabptyHarness()
    let client = try waitForClient(socketPath: harness.socketPath)
    defer { client.close() }
    let descriptor = try client.openSession(
      LabptyOpenSessionRequest(
        rows: UInt32(rows),
        cols: UInt32(cols),
        argv: scriptArgv,
        logicalSessionId: "paste-cross-backend"))
    let reader = try LabptyByteRingReader(path: descriptor.byteRingShmPath)

    let labptyLocal = try Session.fixture(size: sizeStruct)
    defer { labptyLocal.close() }
    // encodePaste is the right API for labpty: encode-only, the
    // bytes get forwarded to the daemon via writeInput. If a
    // future refactor accidentally uses writePasteCapturingBytes
    // here, the local fixture VT will gain a phantom paste-content
    // line and the bitmaps will diverge.
    let encoded = labptyLocal.encodePaste(pasteText)
    XCTAssertFalse(encoded.bytes.isEmpty, "encodePaste returned no bytes for non-empty input")
    try client.writeInput(handle: descriptor.ptyHandle, bytes: encoded.bytes)

    // Pull bytes from the byte ring until we have both echoes
    // ("hello\r\nhello\r\n"). Two passes through waitForOutputBytes
    // would re-read from offset 0; instead collect cumulatively.
    var collected = Data()
    var offset: UInt64 = 0
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      let result = reader.readSince(offset)
      offset = result.newOffset
      collected.append(result.bytes)
      if let text = String(data: collected, encoding: .utf8),
        text.components(separatedBy: "hello").count >= 3
      {
        // 2x "hello" means 3 components when split.
        break
      }
      usleep(10_000)
    }
    XCTAssertEqual(labptyLocal.feedOutput([UInt8](collected)), 0)
    let labptyBitmap = renderBitmap(session: labptyLocal, rows: rows, cols: cols)

    // --- compare ---
    guard let result = BitmapDiff.compare(inProcessBitmap, labptyBitmap) else {
      XCTFail("bitmap dimensions differ")
      return
    }
    if !result.isIdentical {
      BitmapDiffHarness.saveFailureArtifacts(
        label: "cross-backend-paste",
        expected: inProcessBitmap,
        actual: labptyBitmap,
        diff: result.diff,
        file: #file, line: #line)
    }
  }
}
