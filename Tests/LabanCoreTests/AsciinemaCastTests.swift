import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class AsciinemaCastTests: XCTestCase {

  func testEmptyEntriesProduceHeaderOnly() throws {
    let data = try AsciinemaCast.encode(
      entries: [],
      cols: 80,
      rows: 24,
      title: nil,
      startedAtUnixSeconds: 1_716_000_000)
    let lines = decodeLines(data)
    XCTAssertEqual(lines.count, 1)
    let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    XCTAssertEqual(header?["version"] as? Int, 2)
    XCTAssertEqual(header?["width"] as? Int, 80)
    XCTAssertEqual(header?["height"] as? Int, 24)
    XCTAssertEqual(header?["timestamp"] as? Int, 1_716_000_000)
    XCTAssertNil(header?["title"])
  }

  func testHeaderEnvCarriesTermAndExplicitOverrideWins() throws {
    // Default env: TERM=xterm-256color (Laban's advertised TERM).
    let defaultCast = try AsciinemaCast.encode(
      entries: [], cols: 80, rows: 24, title: nil,
      startedAtUnixSeconds: 1_716_000_000)
    let defaultHeader = try decodeHeader(defaultCast)
    let defaultEnv = try XCTUnwrap(defaultHeader["env"] as? [String: String])
    XCTAssertEqual(defaultEnv["TERM"], "xterm-256color")

    // Caller-supplied env replaces the default in full so test
    // assertions never accidentally read the host's $SHELL.
    let customCast = try AsciinemaCast.encode(
      entries: [], cols: 80, rows: 24, title: nil,
      startedAtUnixSeconds: 0,
      env: ["TERM": "screen-256color", "SHELL": "/bin/zsh"])
    let customHeader = try decodeHeader(customCast)
    let customEnv = try XCTUnwrap(customHeader["env"] as? [String: String])
    XCTAssertEqual(customEnv["TERM"], "screen-256color")
    XCTAssertEqual(customEnv["SHELL"], "/bin/zsh")
  }

  func testEmitsHeaderAndOnePerChunkEvent() throws {
    let entries = [
      RecentByteRing.Entry(timestampNanos: 1_000_000_000, bytes: Array("hi".utf8)),
      RecentByteRing.Entry(timestampNanos: 1_500_000_000, bytes: Array("there\n".utf8)),
    ]
    let data = try AsciinemaCast.encode(
      entries: entries,
      cols: 100,
      rows: 30,
      title: "demo",
      startedAtUnixSeconds: 1_716_000_000)
    let lines = decodeLines(data)
    XCTAssertEqual(lines.count, 3)
    let header = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    XCTAssertEqual(header?["width"] as? Int, 100)
    XCTAssertEqual(header?["height"] as? Int, 30)
    XCTAssertEqual(header?["title"] as? String, "demo")

    let firstEvent = try parseEvent(lines[1])
    XCTAssertEqual(firstEvent.0, 0.0, accuracy: 1e-9)
    XCTAssertEqual(firstEvent.1, "o")
    XCTAssertEqual(firstEvent.2, "hi")

    let secondEvent = try parseEvent(lines[2])
    XCTAssertEqual(secondEvent.0, 0.5, accuracy: 1e-9)
    XCTAssertEqual(secondEvent.1, "o")
    XCTAssertEqual(secondEvent.2, "there\n")
  }

  func testInitialFrameBytesAreEmittedBeforeRecordedDeltas() throws {
    let entries = [
      RecentByteRing.Entry(timestampNanos: 1_000_000_000, bytes: Array("\u{1B}[2;5H!".utf8))
    ]
    let data = try AsciinemaCast.encode(
      entries: entries,
      cols: 100,
      rows: 30,
      title: "demo",
      startedAtUnixSeconds: 1_716_000_000,
      initialFrameBytes: Array("\u{1B}[2Jalpha\r\nbeta!".utf8))
    let lines = decodeLines(data)
    XCTAssertEqual(lines.count, 3)

    let seedEvent = try parseEvent(lines[1])
    XCTAssertEqual(seedEvent.0, 0.0, accuracy: 1e-9)
    XCTAssertEqual(seedEvent.1, "o")
    XCTAssertTrue(seedEvent.2.contains("\u{1B}[2J"))
    XCTAssertTrue(seedEvent.2.contains("alpha"))

    let deltaEvent = try parseEvent(lines[2])
    XCTAssertEqual(deltaEvent.0, 0.0, accuracy: 1e-9)
    XCTAssertEqual(deltaEvent.1, "o")
    XCTAssertEqual(deltaEvent.2, "\u{1B}[2;5H!")
  }

  func testTimelineBasePreservesDelayAfterInitialFrame() throws {
    let entries = [
      RecentByteRing.Entry(timestampNanos: 1_000_000_000, bytes: Array("late".utf8))
    ]
    let data = try AsciinemaCast.encode(
      entries: entries,
      cols: 80,
      rows: 24,
      title: nil,
      startedAtUnixSeconds: 1_716_000_000,
      initialFrameBytes: Array("\u{1B}[2Jseed".utf8),
      timelineBaseNanos: 750_000_000)
    let lines = decodeLines(data)
    XCTAssertEqual(lines.count, 3)

    let deltaEvent = try parseEvent(lines[2])
    XCTAssertEqual(deltaEvent.0, 0.25, accuracy: 1e-9)
    XCTAssertEqual(deltaEvent.2, "late")
  }

  func testEscapeSequencesAreJSONEncoded() throws {
    // Real PTY output contains ESC, control chars, quotes. The
    // encoder must produce valid JSON the asciinema player can
    // decode and the terminal can replay verbatim.
    let raw: [UInt8] = [0x1B, 0x5B, 0x31, 0x6D, 0x22, 0x68, 0x69, 0x22, 0x0A]  // ESC[1m"hi"\n
    let entries = [RecentByteRing.Entry(timestampNanos: 1, bytes: raw)]
    let data = try AsciinemaCast.encode(
      entries: entries, cols: 80, rows: 24, title: nil,
      startedAtUnixSeconds: 0)
    let lines = decodeLines(data)
    let event = try parseEvent(lines[1])
    XCTAssertEqual(Array(event.2.utf8), raw, "round-trip preserves all bytes")
  }

  func testMultiByteUTF8AcrossChunksDecodesCleanly() throws {
    // The é (U+00E9) UTF-8 sequence is 0xC3 0xA9. Split it across
    // two chunks. Decoder must stitch them back together — no
    // U+FFFD should appear.
    let entries = [
      RecentByteRing.Entry(timestampNanos: 0, bytes: [0xC3]),
      RecentByteRing.Entry(timestampNanos: 10_000_000, bytes: [0xA9, 0x21]),
    ]
    let data = try AsciinemaCast.encode(
      entries: entries, cols: 80, rows: 24, title: nil,
      startedAtUnixSeconds: 0)
    let lines = decodeLines(data)
    // First chunk has only the dangling lead byte — emits no
    // visible characters yet (the entry is deferred to the next).
    // Second chunk emits "é!".
    let visible = lines[1...].map { try? parseEvent($0).2 }.compactMap { $0 }
      .joined()
    XCTAssertFalse(visible.contains("\u{FFFD}"))
    XCTAssertTrue(visible.contains("é!"))
  }

  func testInvalidUTF8BytesBecomeReplacementCharacter() throws {
    // Lone continuation byte is genuinely invalid. The encoder
    // should not crash and should substitute U+FFFD rather than
    // silently dropping the byte.
    let entries = [
      RecentByteRing.Entry(timestampNanos: 0, bytes: [0x80, 0x41])
    ]
    let data = try AsciinemaCast.encode(
      entries: entries, cols: 80, rows: 24, title: nil,
      startedAtUnixSeconds: 0)
    let lines = decodeLines(data)
    let event = try parseEvent(lines[1])
    XCTAssertTrue(event.2.contains("\u{FFFD}"))
    XCTAssertTrue(event.2.contains("A"))
  }

  func testFullFrameSnapshotBytesRehydrateVisibleGrid() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 14
    let source = try Session.fixture(size: size)
    XCTAssertEqual(
      source.feedOutput(
        Array("\u{1B}[2J\u{1B}[Halpha\u{1B}[2;3Hβeta\u{1B}[4;1Hdone".utf8)),
      0)

    let sourceSnap = try XCTUnwrap(source.snapshot())
    defer { laban_snapshot_destroy(sourceSnap) }

    let seed = AsciinemaCast.fullFrameSnapshotBytes(from: UnsafePointer(sourceSnap))
    let seedText = String(decoding: seed, as: UTF8.self)
    XCTAssertTrue(seedText.contains("\u{1B}[2J"), seedText.debugDescription)
    XCTAssertTrue(seedText.contains("alpha"), seedText.debugDescription)
    XCTAssertTrue(seedText.contains("βeta"), seedText.debugDescription)

    let target = try Session.fixture(size: size)
    XCTAssertEqual(target.replayPtyOutput(seed), 0)
    let targetSnap = try XCTUnwrap(target.snapshot())
    defer { laban_snapshot_destroy(targetSnap) }

    XCTAssertEqual(
      TerminalSnapshotText.visibleText(from: UnsafePointer(targetSnap), mode: .fullGrid),
      TerminalSnapshotText.visibleText(from: UnsafePointer(sourceSnap), mode: .fullGrid)
    )
    XCTAssertEqual(targetSnap.pointee.cursor_row, sourceSnap.pointee.cursor_row)
    XCTAssertEqual(targetSnap.pointee.cursor_col, sourceSnap.pointee.cursor_col)
  }

  // MARK: - Helpers

  private func decodeHeader(_ data: Data) throws -> [String: Any] {
    let line = try XCTUnwrap(decodeLines(data).first)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
  }

  private func decodeLines(_ data: Data) -> [String] {
    String(data: data, encoding: .utf8)?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map(String.init) ?? []
  }

  private func parseEvent(_ line: String) throws -> (Double, String, String) {
    let arr = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any]
    let time = (arr?[0] as? NSNumber)?.doubleValue ?? -1
    let kind = arr?[1] as? String ?? ""
    let payload = arr?[2] as? String ?? ""
    return (time, kind, payload)
  }
}
