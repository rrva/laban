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
    let commands = producer.commands(from: snap, cursorBlinkVisible: false)
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
}
