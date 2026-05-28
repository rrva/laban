import Foundation
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Regression: pasting 4 lines into Claude Code over a labpty session
/// produced visibly corrupt rendering in Laban.app — spurious digits
/// landing inside the bottom status row ("rrj/wrk/laban" rendered as
/// "rrj/wr  3aban (main)"), spaces in the [Pasted text #1 +3 lines]
/// indicator rendering as horizontal-line glyphs. Same byte stream
/// against the same Claude Code in iTerm renders correctly.
///
/// These tests replay the actual byte stream observed on the labpty
/// byte ring during a real Laban.app paste (captured via
/// `labpty-dump`, see Tools/LabptyDump). The 9046-byte fixture covers
/// the title-set, the chat-history rerender, the paste-indicator
/// rendering, and the bottom-prompt rerender — i.e. everything Claude
/// Code emits between paste and the post-paste UI settling.
///
/// Three variants test different feedOutput chunking patterns:
///  - feedAsBlob: one feedOutput call with the full 9046 bytes.
///                Tells us whether libghostty itself misrenders the
///                stream as-given.
///  - feedAsObservedChunks: feed in the same chunk boundaries the
///                          byte-ring dumper saw (4083 / 4173 / 357 /
///                          279 / 154). Mimics LabptyParserFeed.
///  - feedByteByByte: one byte per feedOutput. Stresses any cross-
///                    call state in the VT parser.
///
/// If feedAsBlob succeeds but feedAsObservedChunks fails, the bug is
/// in libghostty's feed-boundary handling — a "seam" in the labpty
/// reader's chunking. If feedAsBlob also fails, libghostty's
/// interpretation of the byte stream itself is wrong.
final class LabptyPasteRenderingRegressionTests: XCTestCase {
  private func loadFixture() throws -> [UInt8] {
    let url = Bundle.module.url(
      forResource: "labpty-paste-rendering", withExtension: "bin")
    let path = url?.path ?? "Tests/LabanCoreTests/Fixtures/labpty-paste-rendering.bin"
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return [UInt8](data)
  }

  private func session() throws -> Session {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 67
    return try Session.fixture(size: size)
  }

  private func rawRows(from session: Session) -> [String] {
    guard let snap = session.snapshot() else { return [] }
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap.pointee
    let rows = Int(snapshot.rows)
    let cols = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else { return [] }
    var lines: [String] = []
    for row in 0..<rows {
      var line = ""
      for col in 0..<cols {
        let cell = cells[row * cols + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          if let text = String(bytes: buf, encoding: .utf8) { line += text }
        } else {
          line += " "
        }
      }
      lines.append(line)
    }
    return lines
  }

  private func dump(label: String, rows: [String]) {
    print("===== \(label) =====")
    for (i, row) in rows.enumerated() {
      print(String(format: "%2d|", i) + row + "|")
    }
  }

  private func assertNoCorruption(label: String, rows: [String]) {
    // The captured fixture's bottom status row contains "/Users/rrj".
    // A correctly rendered grid keeps the path and paste indicator intact;
    // the live bug injected paste digits into status text or drew paste
    // indicator spaces as horizontal-line glyphs.
    let joined = rows.joined(separator: "\n")
    XCTAssertTrue(
      joined.contains("/Users/rrj"),
      "[\(label)] /Users/rrj not found intact in grid; see test log")
    XCTAssertTrue(
      joined.contains("[Pasted text #1 +3 lines]"),
      "[\(label)] paste indicator not found intact in grid; see test log")
    if let pastedRow = rows.first(where: { $0.contains("Pasted") }) {
      XCTAssertFalse(
        pastedRow.contains("─"),
        "[\(label)] paste indicator row contains horizontal-line glyphs: \(pastedRow)")
    } else {
      XCTFail("[\(label)] paste indicator row not found; see test log")
    }
  }

  func testFeedAsBlob() throws {
    let bytes = try loadFixture()
    let s = try session()
    defer { s.close() }
    XCTAssertEqual(s.feedOutput(bytes), 0)
    let rows = rawRows(from: s)
    dump(label: "feedAsBlob", rows: rows)
    assertNoCorruption(label: "feedAsBlob", rows: rows)
  }

  func testFeedAsKilobyteChunks() throws {
    // 1 KiB chunks approximate typical PTY read sizes — the byte ring
    // writer copies PTY reads verbatim, so the local Session is fed
    // in similarly sized chunks.
    let bytes = try loadFixture()
    let s = try session()
    defer { s.close() }
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 1024, bytes.count)
      XCTAssertEqual(s.feedOutput(Array(bytes[offset..<end])), 0)
      offset = end
    }
    let rows = rawRows(from: s)
    dump(label: "feedAsKilobyteChunks", rows: rows)
    assertNoCorruption(label: "feedAsKilobyteChunks", rows: rows)
  }

  func testFeedByteByByte() throws {
    let bytes = try loadFixture()
    let s = try session()
    defer { s.close() }
    for b in bytes {
      XCTAssertEqual(s.feedOutput([b]), 0)
    }
    let rows = rawRows(from: s)
    dump(label: "feedByteByByte", rows: rows)
    assertNoCorruption(label: "feedByteByByte", rows: rows)
  }

  /// Simulates the live app's startup ordering:
  ///   1. Create Session at AppModel.defaultSize() = 24×80
  ///   2. Inject theme palette (the OSC sequence string AppModel emits)
  ///   3. Resize to 24×67 (the actual window size — what labpty sees)
  ///   4. Feed the byte-ring capture
  /// If the bug reproduces here but not in testFeedAsBlob, the
  /// difference is the early-life startup state (size mismatch on
  /// initial frames, or palette-injection side effects).
  func testFeedWithLiveStartupSequence() throws {
    var initialSize = LabanTerminalSize()
    initialSize.rows = 24
    initialSize.cols = 80
    let s = try Session.fixture(size: initialSize)
    defer { s.close() }

    // Approximate ThemePaletteInjector's output: 16 ANSI colors + fg/bg/cursor.
    // The exact bytes don't matter for cell text — only that they land
    // in the VT parser before the byte-ring stream like the live app.
    var palette: [UInt8] = []
    for index in 0..<16 {
      let seq = "\u{1B}]4;\(index);#808080\u{07}"
      palette += Array(seq.utf8)
    }
    palette += Array("\u{1B}]10;#ffffff\u{07}\u{1B}]11;#000000\u{07}\u{1B}]12;#ffffff\u{07}".utf8)
    XCTAssertEqual(s.feedOutput(palette), 0)

    var finalSize = LabanTerminalSize()
    finalSize.rows = 24
    finalSize.cols = 67
    XCTAssertEqual(s.resize(finalSize), 0)

    let bytes = try loadFixture()
    XCTAssertEqual(s.feedOutput(bytes), 0)

    let rows = rawRows(from: s)
    dump(label: "feedWithLiveStartupSequence", rows: rows)
    assertNoCorruption(label: "feedWithLiveStartupSequence", rows: rows)
  }
}
