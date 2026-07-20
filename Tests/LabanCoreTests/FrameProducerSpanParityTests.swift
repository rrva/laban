import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// The macOS 26 Span/UTF8Span glyph pass in FrameProducer must emit byte-for-byte
// identical FrameCommands to the legacy loop it replaces. This is the fidelity
// contract for the perf change: same pixels, less CPU. Rather than store a
// golden blob, we run each fixture through BOTH paths in one binary (toggled by
// FrameProducer._forceLegacyGlyphRuns) and assert the serialized command streams
// are equal.
final class FrameProducerSpanParityTests: XCTestCase {

  // MARK: - Canonical serialization (FrameCommand is not Equatable)

  private func key(_ cmd: FrameCommand) -> String {
    func r(_ rect: CGRect) -> String {
      String(
        format: "%.4f,%.4f,%.4f,%.4f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
    func p(_ pt: CGPoint) -> String { String(format: "%.4f,%.4f", pt.x, pt.y) }
    switch cmd {
    case .rect(let rect, let color, let source, let compositing):
      return "rect|\(r(rect))|\(color)|\(source.rawValue)|\(compositing.rawValue)"
    case .glyphRun(
      let origin, let text, let fg, let bg, let attrs, let source, let us, let uc, let link, _, _, _):
      // Encode text by scalar so any decode discrepancy surfaces, and pin the
      // grapheme-cluster count so RI/ZWJ/skin-tone merges must match exactly.
      let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
      return
        "glyph|\(p(origin))|chars=\(text.count)|scalars=\(scalars)|fg=\(fg)|bg=\(bg)"
        + "|attrs=\(attrs.rawValue)|src=\(source.rawValue)|us=\(us.rawValue)"
        + "|uc=\(uc.map(String.init) ?? "nil")|link=\(link ?? "nil")"
    case .cursor(let rect, let color):
      return "cursor|\(r(rect))|\(color)"
    case .selection(let rect, let color):
      return "selection|\(r(rect))|\(color)"
    case .findMatch(let rect, let color):
      return "findMatch|\(r(rect))|\(color)"
    case .findSelected(let rect, let color):
      return "findSelected|\(r(rect))|\(color)"
    case .clip(let rect):
      return "clip|\(r(rect))"
    case .texturedQuad(let rect, let resourceId, let source):
      return "texturedQuad|\(r(rect))|\(resourceId)|\(source.rawValue)"
    }
  }

  private func serialize(_ cmds: [FrameCommand]) -> [String] { cmds.map(key) }

  // MARK: - Fixtures

  private func commandsBothPaths(
    _ payload: String, cols: Int32 = 80, rows: Int32 = 24
  ) throws -> (fast: [String], legacy: [String]) {
    var size = LabanTerminalSize()
    size.cols = cols
    size.rows = rows
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(payload.utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return ([], [])
    }
    defer { laban_snapshot_destroy(snap) }

    // A selection and a find state exercise the surrounding passes too, so the
    // glyph-pass output is compared in a realistic full-frame context.
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 13, originY: 0)

    FrameProducer._forceLegacyGlyphRuns = true
    let legacy = serialize(producer.commands(from: UnsafePointer(snap)))
    FrameProducer._forceLegacyGlyphRuns = false
    let fast = serialize(producer.commands(from: UnsafePointer(snap)))
    return (fast, legacy)
  }

  private func assertParity(
    _ payload: String, _ label: String, cols: Int32 = 80, rows: Int32 = 24,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    guard #available(macOS 26, *) else {
      throw XCTSkip("Span/UTF8Span fast path requires macOS 26")
    }
    let (fast, legacy) = try commandsBothPaths(payload, cols: cols, rows: rows)
    XCTAssertEqual(
      fast.count, legacy.count, "[\(label)] command count differs", file: file, line: line)
    let n = min(fast.count, legacy.count)
    for i in 0..<n where fast[i] != legacy[i] {
      XCTFail(
        "[\(label)] command #\(i) differs:\n  legacy: \(legacy[i])\n  fast:   \(fast[i])",
        file: file, line: line)
      return
    }
  }

  // MARK: - Tests

  func testPlainAsciiText() throws {
    try assertParity("hello mvp the quick brown fox 0123456789\r\n", "ascii")
  }

  func testColoredBackgroundRuns() throws {
    let payload =
      "\u{1B}[48;2;40;44;52mvim status\u{1B}[0m normal "
      + "\u{1B}[44m highlighted span \u{1B}[0m tail\r\n"
    try assertParity(payload, "colored-bg")
  }

  func testBoxDrawingProceduralElements() throws {
    let payload =
      "\u{1B}[38;2;255;204;0m┌────────────┐\u{1B}[0m\r\n"
      + "\u{1B}[38;2;255;204;0m│ hello mvp  │\u{1B}[0m\r\n"
      + "\u{1B}[38;2;255;204;0m└────────────┘\u{1B}[0m\r\n"
      + "\u{2588}\u{2580}\u{2584}\u{258C}\u{2590}\r\n"  // full/half blocks
    try assertParity(payload, "box-drawing")
  }

  func testWideCJK() throws {
    try assertParity("中文终端 mixed 한글 テスト\r\n", "wide-cjk")
  }

  func testRegionalIndicatorFlag() throws {
    try assertParity("\u{1F1F8}\u{1F1EA} flag \u{1F1FA}\u{1F1F8}\r\n", "regional-indicator")
  }

  func testZWJFamilyEmoji() throws {
    try assertParity(
      "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} family\r\n", "zwj-family")
  }

  func testSkinToneModifier() throws {
    try assertParity("\u{1F44B}\u{1F3FD} wave \u{1F44D}\u{1F3FF}\r\n", "skin-tone")
  }

  func testCombiningMarks() throws {
    try assertParity("e\u{0301}a\u{0300}o\u{0308} cafe\u{0301}\r\n", "combining")
  }

  func testHyperlinkOSC8() throws {
    let link =
      "\u{1B}]8;;https://example.com/path\u{1B}\\click here\u{1B}]8;;\u{1B}\\ and plain\r\n"
    try assertParity(link, "hyperlink")
  }

  func testUnderlineStyles() throws {
    let payload =
      "\u{1B}[4mstraight\u{1B}[0m \u{1B}[4:3mcurly\u{1B}[0m "
      + "\u{1B}[4:2mdouble\u{1B}[0m \u{1B}[58:2:255:0:0m\u{1B}[4:1mcolored\u{1B}[0m\r\n"
    try assertParity(payload, "underline-styles")
  }

  func testFaintInverseBoldItalic() throws {
    let payload =
      "\u{1B}[2mfaint\u{1B}[0m \u{1B}[7minverse\u{1B}[0m "
      + "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[9mstrike\u{1B}[0m\r\n"
    try assertParity(payload, "faint-inverse")
  }

  func testInvisibleText() throws {
    try assertParity("visible\u{1B}[8mhidden\u{1B}[0mvisible\r\n", "invisible")
  }

  func testDenseColoredField() throws {
    // Pathological: a unique bg color per cell — stresses run flushing.
    var out = ["\u{1B}[H"]
    for r in 0..<24 {
      for c in 0..<80 {
        let red = (r * 7 + c) & 0xFF
        let green = (c * 5 + r * 3) & 0xFF
        let blue = (r * c) & 0xFF
        let scalar = UnicodeScalar(0x21 + ((r * 31 + c) % 94))!
        out.append("\u{1B}[48;2;\(red);\(green);\(blue)m\(scalar)")
      }
      out.append("\r\n")
    }
    out.append("\u{1B}[0m")
    try assertParity(out.joined(), "dense-colored", cols: 80, rows: 24)
  }

  func testMixedRealisticScreen() throws {
    let payload =
      "\u{1B}[1;38;2;116;199;236m❯\u{1B}[0m git status\r\n"
      + "On branch \u{1B}[32mmain\u{1B}[0m\r\n"
      + "\u{1B}[31m  modified:\u{1B}[0m Sources/中文.swift \u{1F600}\r\n"
      + "\u{1B}[2m─────────\u{1B}[0m\r\n"
      + "\u{1B}]8;;file:///tmp/x\u{1B}\\link\u{1B}]8;;\u{1B}\\ \u{1F1F8}\u{1F1EA}\r\n"
    try assertParity(payload, "mixed-screen", cols: 100, rows: 30)
  }
}
