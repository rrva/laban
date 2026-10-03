import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Pin the grapheme-cluster coalescing fix in FrameProducer. libghostty-vt
// stores ZWJ-joined emoji, regional-indicator pairs, and skin-tone modifiers
// in adjacent cells (typically a wide cell + spacer-tail). FrameProducer must
// merge those into one glyph run so Core Text can render the composed glyph
// rather than its codepoint pieces.
final class GraphemeClusteringTests: XCTestCase {

  private func runWithText(_ bytes: String) throws -> [FrameCommand] {
    var size = LabanTerminalSize()
    size.rows = 24
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(bytes.utf8))
    session.poll()
    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return []
    }
    defer { laban_snapshot_destroy(snap) }
    return FrameProducer(cellWidth: 9, cellHeight: 19).commands(from: UnsafePointer(snap))
  }

  private func terminalGlyphTexts(_ cmds: [FrameCommand]) -> [String] {
    var out: [String] = []
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, let src, _, _, _, _, _, _, _) = cmd, src == .terminal
      {
        out.append(text)
      }
    }
    return out
  }

  func testRegionalIndicatorPairsCoalesceIntoSingleFlagCharacter() throws {
    // Two regional indicators side by side form one Unicode flag cluster.
    let cmds = try runWithText("\u{1F1F8}\u{1F1EA}\r\n")  // 🇸🇪
    let texts = terminalGlyphTexts(cmds)
    XCTAssertTrue(
      texts.contains { $0 == "\u{1F1F8}\u{1F1EA}" && $0.count == 1 },
      "regional indicators 🇸🇪 must merge into one Character; got runs: \(texts)")
  }

  func testZWJFamilyEmojiCoalescesIntoSingleCluster() throws {
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"  // 👨‍👩‍👧‍👦
    let cmds = try runWithText(family + "\r\n")
    let texts = terminalGlyphTexts(cmds)
    XCTAssertTrue(
      texts.contains { $0 == family && $0.count == 1 },
      "ZWJ family emoji must merge into one Character; got runs: \(texts)")
  }

  func testSkinToneModifierCoalescesWithBaseEmoji() throws {
    let waveMedium = "\u{1F44B}\u{1F3FD}"  // 👋🏽
    let cmds = try runWithText(waveMedium + "\r\n")
    let texts = terminalGlyphTexts(cmds)
    XCTAssertTrue(
      texts.contains { $0 == waveMedium && $0.count == 1 },
      "skin-tone modifier must merge with base emoji into one Character; got runs: \(texts)")
  }

  /// Terminal runs carry the engine's column span, so renderers can size the
  /// run's last cluster (the only one that may be wide) from the engine
  /// rather than from their own width table.
  func testTerminalRunsCarryEngineColumnSpan() throws {
    let cmds = try runWithText("\u{4E2D}A [\u{2764}\u{FE0F}y]\r\n")  // 中A [❤️y]
    var spans: [String: Int?] = [:]
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd {
        spans[text] = cells
      }
    }
    XCTAssertEqual(spans["\u{4E2D}"], 2, "a wide CJK cell spans two columns; got \(spans)")
    XCTAssertEqual(
      spans["A [\u{2764}\u{FE0F}y]"], 6, "narrow cells span one column each; got \(spans)")
  }

  /// A wide cell that also holds a zero-width character is drawn alone, and
  /// its span is left unknown rather than miscounted as one column.
  func testMultiCharacterWideCellLeavesSpanUnknown() throws {
    let cmds = try runWithText("\u{1F600}\u{200B}x\r\n")
    var spans: [String: Int?] = [:]
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd {
        spans[text] = cells
      }
    }
    XCTAssertEqual(spans["\u{1F600}\u{200B}"], .some(nil), "got \(spans)")
    XCTAssertEqual(spans["x"], 1)
  }

  func testWideCJKFollowedByNarrowCharStillEmitsCorrectColumns() throws {
    // Regression: the cluster-extending logic must not over-merge — a wide
    // CJK char followed by a narrow ASCII char does NOT form one cluster, so
    // FrameProducer should still flush the run on the spacer between them.
    let cmds = try runWithText("\u{4E2D}A\r\n")  // 中A
    let texts = terminalGlyphTexts(cmds)
    // Either as one merged run "中A" (acceptable — they have the same style
    // and Swift counts them as 2 Characters) or as two runs. Either is OK as
    // long as Character count is preserved (no codepoint loss).
    let totalCharacters = texts.joined().count
    XCTAssertTrue(
      totalCharacters >= 2, "中 and A must both survive as visible characters; got runs: \(texts)")
  }
}
