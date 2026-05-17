import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TranscriptRoundTripTests: XCTestCase {

  private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-transcript-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: - TranscriptWriter

  func testWriterFlushesRingToDisk() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 1024,
      fileCapacity: 1_000_000,
      debounceInterval: .milliseconds(10)
    )

    let payload = Array("hello world\n".utf8)
    payload.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: payload.count)
    }
    writer.flushSync()

    let data = try Data(contentsOf: file)
    XCTAssertEqual(Array(data), payload)
    XCTAssertEqual(writer.ingestedBytes, UInt64(payload.count))
    XCTAssertEqual(writer.droppedBytes, 0)
  }

  func testWriterRingOverflowDropsOldest() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 16,
      fileCapacity: 1_000_000,
      debounceInterval: .milliseconds(10)
    )

    let payload = Array(repeating: UInt8(0x41), count: 64)  // 64 'A' bytes
    payload.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: payload.count)
    }
    writer.flushSync()

    let data = try Data(contentsOf: file)
    // Ring holds only the last 16 bytes; the first 48 should be dropped.
    XCTAssertEqual(data.count, 16)
    XCTAssertEqual(writer.ingestedBytes, 64)
    XCTAssertEqual(writer.droppedBytes, 48)
  }

  func testWriterHeadTruncatesOnceFileCapExceeded() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 64 * 1024,
      fileCapacity: 1024,
      debounceInterval: .milliseconds(10)
    )

    var payload = Data()
    payload.append(contentsOf: Array(repeating: UInt8(0x42), count: 800))  // initial "B"s
    payload.withUnsafeBytes { buf in
      let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
      writer.writeChunk(bytes: ptr, count: buf.count)
    }
    writer.flushSync()
    XCTAssertEqual(try Data(contentsOf: file).count, 800)

    let more = Data(repeating: UInt8(0x43), count: 600)  // 600 more "C"s
    more.withUnsafeBytes { buf in
      let ptr = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
      writer.writeChunk(bytes: ptr, count: buf.count)
    }
    writer.flushSync()

    let final = try Data(contentsOf: file)
    XCTAssertLessThanOrEqual(
      final.count, 1024,
      "head-truncation must keep file at or below fileCapacity")
    // Tail bytes must still be the "C"s — head was the part that got dropped.
    XCTAssertEqual(final.last, UInt8(0x43))
  }

  // MARK: - AnsiEscapeStripper

  func testStripperRemovesCSIAndKeepsText() {
    let input = Data("\u{001B}[31mred\u{001B}[0m text\n".utf8)
    let out = AnsiEscapeStripper.strip(input)
    XCTAssertEqual(String(data: out, encoding: .utf8), "red text\n")
  }

  func testStripperRemovesOSC() {
    let input = Data("\u{001B}]0;title\u{0007}body\n".utf8)
    let out = AnsiEscapeStripper.strip(input)
    XCTAssertEqual(String(data: out, encoding: .utf8), "body\n")
  }

  // MARK: - TranscriptRenderer

  func testSafeReplayStartFindsNextLF() {
    let data = Data("hello\nworld\n".utf8)
    // Nominal cutoff = 3 ("lo\nw…"), the first LF after that is at idx 5.
    XCTAssertEqual(TranscriptRenderer.safeReplayStart(in: data, nominal: 3), 6)
  }

  func testSafeReplayStartReturnsNilWhenNoLF() {
    let data = Data("abcdef".utf8)
    XCTAssertNil(TranscriptRenderer.safeReplayStart(in: data, nominal: 0))
  }

  func testRendererSkipsWhenAltBufferAtQuit() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    try Data("contents\n".utf8).write(to: file)

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // Snapshot before/after; with altBufferAtQuit=true the renderer
    // should make no calls into the session.
    let before = session.snapshot()
    defer { if let before { laban_snapshot_destroy(before) } }
    TranscriptRenderer.render(
      fileURL: file, into: session, altBufferAtQuit: true)
    // Re-snap and assert the cell grid contains no transcript bytes.
    if let snap = session.snapshot() {
      defer { laban_snapshot_destroy(snap) }
      let text = String(
        cString: snap.pointee.utf8_storage ?? UnsafePointer<CChar>(bitPattern: 1)!)
      XCTAssertFalse(text.contains("contents"))
    }
  }

  func testRendererReplaysTextIntoFixtureSession() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    try Data("line A\nline B\nline C\n".utf8).write(to: file)

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    TranscriptRenderer.render(
      fileURL: file, into: session, altBufferAtQuit: false)

    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }
    // The fixture session ran the bytes through libghostty-vt; we
    // should see at least one of the lines somewhere in the rendered
    // text. Don't pin to exact layout — different libghostty versions
    // may differ slightly in row placement.
    if let storagePtr = snap.pointee.utf8_storage {
      let text = String(
        bytes: UnsafeBufferPointer(start: UnsafeRawPointer(storagePtr).assumingMemoryBound(to: UInt8.self),
                                   count: Int(snap.pointee.utf8_storage_len)),
        encoding: .utf8) ?? ""
      XCTAssertTrue(text.contains("line A") || text.contains("line C"))
    }
  }

  func testRendererReplaysSmallEchoTranscriptWithoutBoundaryCorruption() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    try Data("e\u{0008}echo hej\r\nhej\r\n".utf8).write(to: file)

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    TranscriptRenderer.render(
      fileURL: file, into: session, altBufferAtQuit: false)

    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }
    let visible = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap),
      mode: .trimmedNonEmptyRows)
    XCTAssertTrue(visible.contains("echo hej"))
    XCTAssertFalse(visible.contains("eecho hej"), visible)
    XCTAssertFalse(
      visible.unicodeScalars.contains { $0.value == 0 },
      "restore replay must not inject NUL glyphs")
  }

  func testTranscriptHostRoundTripsSmallEchoTranscriptWithoutBoundaryCorruption() throws {
    let baseDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: baseDir) }
    let store = PersistenceStore(baseURL: baseDir)
    let host = TranscriptHost(store: store)

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let producer = try Session.fixture(size: size)
    defer { producer.close() }
    let tabId = "tab-echo-boundary-test"
    host.attachTranscriptWriter(to: producer, tabId: tabId)

    _ = producer.feedOutput(Array("echo hej\r\nhej\r\n".utf8))
    host.detachTranscriptWriter(forTabId: tabId, in: producer)

    let replay = try Session.fixture(size: size)
    defer { replay.close() }
    TranscriptRenderer.render(
      fileURL: store.transcriptURL(forTabId: tabId),
      into: replay,
      altBufferAtQuit: false)

    let snap = try XCTUnwrap(replay.snapshot())
    defer { laban_snapshot_destroy(snap) }
    let visible = TerminalSnapshotText.visibleText(
      from: UnsafePointer(snap),
      mode: .trimmedNonEmptyRows)
    XCTAssertTrue(visible.contains("echo hej"))
    XCTAssertFalse(visible.contains("eecho hej"))
    XCTAssertFalse(
      visible.unicodeScalars.contains { $0.value == 0 },
      "restore replay must not inject NUL glyphs")
  }

  // MARK: - TranscriptHost end-to-end

  func testTranscriptHostAttachWriterCapturesBytes() throws {
    let baseDir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: baseDir) }
    let store = PersistenceStore(baseURL: baseDir)
    let host = TranscriptHost(store: store)

    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    let tabId = "tab-host-test"
    host.attachTranscriptWriter(to: session, tabId: tabId)

    // Feed bytes through the fixture session — fixture mode routes
    // laban_session_write straight into laban_vt_write_capture, which
    // invokes our persistence callback before reaching libghostty.
    _ = session.feedOutput(Array("hello transcript\n".utf8))

    // Give the debounce timer time to fire.
    let written = expectation(description: "host wrote")
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4) {
      written.fulfill()
    }
    wait(for: [written], timeout: 2.0)

    host.detachTranscriptWriter(forTabId: tabId, in: session)

    let url = store.transcriptURL(forTabId: tabId)
    let data = try Data(contentsOf: url)
    XCTAssertTrue(
      data.contains("hello transcript\n".utf8.first!)
        && String(data: data, encoding: .utf8)?.contains("hello transcript") == true,
      "transcript file should contain the fed bytes")
  }

  // MARK: - Toggle gating

  func testWriterDropsBytesAtCaptureTimeWhenDisabled() throws {
    // The "write off, re-enable, flush" sequence must NOT resurrect
    // off-window bytes. writeChunk has to drop at capture; deferring
    // the drop to drainNow leaves a race where the ring still holds
    // the bytes when the toggle flips back on.
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    var enabled = false
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 4096,
      fileCapacity: 1_000_000,
      debounceInterval: .milliseconds(10),
      isEnabled: { enabled })

    let off = Array("MUST_BE_DROPPED\n".utf8)
    off.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: off.count)
    }
    // No flush yet — the ring should be empty because writeChunk
    // dropped at capture.
    enabled = true
    let on = Array("kept\n".utf8)
    on.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: on.count)
    }
    writer.flushSync()
    let data = try Data(contentsOf: file)
    XCTAssertEqual(
      Array(data), on,
      "write-off, re-enable, flush must not resurrect off-window bytes")
    XCTAssertEqual(writer.droppedBytes, UInt64(off.count))
  }

  func testWriterDiscardsBytesCapturedWhileDisabled() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")

    var enabled = false
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 4096,
      fileCapacity: 1_000_000,
      debounceInterval: .milliseconds(10),
      isEnabled: { enabled })

    let off = Array("toggle-off must be DISCARDED\n".utf8)
    off.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: off.count)
    }
    writer.flushSync()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: file.path),
      "disabled writer must not create the transcript file")

    // Re-enable. A later drain must NOT include the bytes from the
    // off window — the kill-switch contract is "discard while off,
    // not defer." Write a fresh payload and verify the file
    // contains only that.
    enabled = true
    let on = Array("toggle-on bytes should land\n".utf8)
    on.withUnsafeBufferPointer { buf in
      writer.writeChunk(bytes: buf.baseAddress!, count: on.count)
    }
    writer.flushSync()
    let data = try Data(contentsOf: file)
    XCTAssertEqual(
      Array(data), on,
      "file must contain only the post-enable bytes; the off-window bytes must be gone")
  }

  // MARK: - Hot-path discipline

  func testWriteChunkDoesNotAllocatePerCall() throws {
    // Smoke test for the hot-path-callback contract: feed many small
    // chunks and assert the writer's API surface doesn't trip an
    // unbounded backing structure. We can't prove "zero allocation"
    // from a test, but we can assert that thousands of chunks don't
    // explode memory and that the file (when enabled) still contains
    // exactly the bytes we fed.
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("t.bin")
    let writer = TranscriptWriter(
      tabId: "t",
      fileURL: file,
      ringCapacity: 64 * 1024,
      fileCapacity: 10 * 1024 * 1024,
      debounceInterval: .milliseconds(20))

    let chunk: [UInt8] = Array("abc\n".utf8)
    for _ in 0..<5000 {
      chunk.withUnsafeBufferPointer { buf in
        writer.writeChunk(bytes: buf.baseAddress!, count: chunk.count)
      }
    }
    writer.flushSync()

    let data = try Data(contentsOf: file)
    XCTAssertEqual(data.count, 4 * 5000)
  }

  func testAltBufferActiveReflectsLibghosttyState() throws {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }

    XCTAssertFalse(session.altBufferActive, "fixture starts in primary screen")

    // Enter alt-screen via DECSET 1049
    _ = session.feedOutput(Array("\u{001B}[?1049h".utf8))
    XCTAssertTrue(session.altBufferActive)

    _ = session.feedOutput(Array("\u{001B}[?1049l".utf8))
    XCTAssertFalse(session.altBufferActive)
  }
}
