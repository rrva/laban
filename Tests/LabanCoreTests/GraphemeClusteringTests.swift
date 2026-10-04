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

  /// With mode 2027 off the engine puts an Indic conjunct in two narrow cells
  /// (`स्` then `ते`). Swift joins them into one Character, so the conjunct
  /// must end its run like any other multi-column cluster; otherwise every
  /// later cluster in the run is drawn one column left of its engine column.
  func testIndicConjunctAcrossCellsEndsItsRun() throws {
    // |नमस्ते दु|
    let cmds = try runWithText(
      "|\u{928}\u{92E}\u{938}\u{94D}\u{924}\u{947} \u{926}\u{941}|\r\n")
    var runs: [String] = []
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd
      {
        runs.append("\(Int(origin.x / 9)):\(text.count):\(cells.map(String.init) ?? "nil")")
      }
    }
    // Column:Characters:span. The conjunct's run covers columns 0-4; the rest
    // starts at the conjunct's end, column 5.
    XCTAssertEqual(runs, ["0:4:5", "5:3:3"], "got runs: \(runs)")
  }

  /// Thai SARA AM and Prepend scalars (Malayalam dot reph, Arabic number
  /// sign) join across cells the same way, so a run never holds fewer
  /// Characters than it has columns.
  func testSaraAmAndPrependAcrossCellsEndTheirRun() throws {
    for (text, expected) in [
      ("|\u{0E01}\u{0E33}x|", ["0:2:3", "3:2:2"]),  // |กำx|
      ("|\u{0D4E}\u{0D2F}x|", ["0:2:3", "3:2:2"]),  // |ൎയx|
      // |؀12x| is a BiDi row (U+0600 is Arabic), whose runs never join cells
      // that would merge, so every cell keeps its own Character.
      ("|\u{0600}12x|", ["0:2:2", "2:4:4"]),
    ] {
      var runs: [String] = []
      for cmd in try runWithText(text + "\r\n") {
        if case .glyphRun(let origin, let run, _, _, _, .terminal, _, _, _, let cells, _, _, _) =
          cmd
        {
          runs.append("\(Int(origin.x / 9)):\(run.count):\(cells.map(String.init) ?? "nil")")
        }
      }
      XCTAssertEqual(runs, expected, "\(text.unicodeScalars.map { String($0.value, radix: 16) })")
    }
  }

  /// A one-column emoji (VS16 with mode 2027 off) draws two columns wide when
  /// the next cell is blank, exactly like a wide emoji and its spacer tail. A
  /// visible neighbor, or an underline that would change length, keeps it in
  /// one column.
  func testNarrowEmojiBorrowsBlankNeighbor() throws {
    let heart = "\u{2764}\u{FE0F}"
    let cmds = try runWithText(
      "[\(heart) x|\(heart)y|\u{1b}[4m\(heart) \u{1b}[0m|\(heart)\r\n")
    var runs: [String] = []
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd
      {
        runs.append("\(Int(origin.x / 9)):\(text):\(cells.map(String.init) ?? "nil")")
      }
    }
    XCTAssertEqual(
      runs,
      [
        "0:[\(heart):3",  // the space after it is borrowed
        "3:x|\(heart)y|:5",  // `y` is visible, so the heart keeps one column
        "8:\(heart) :2",  // underlined: the space stays a cell of its own
        "10:|\(heart):3",  // the empty cell at the end of the line is borrowed
      ],
      "got runs: \(runs)")
  }

  /// A borrowed blank ends the emoji's run: a ZWJ before it cannot pull the
  /// next emoji across the space into one cluster.
  func testBorrowedBlankEndsTheEmojiRun() throws {
    let cmds = try runWithText("\u{2764}\u{FE0F}\u{200D} \u{1F525}x\r\n")  // ❤️‍ 🔥x
    var runs: [String] = []
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd
      {
        let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
        runs.append("\(Int(origin.x / 9)):\(scalars):\(cells.map(String.init) ?? "nil")")
      }
    }
    XCTAssertEqual(runs, ["0:2764.fe0f.200d:2", "2:1f525:2", "4:78:1"], "got runs: \(runs)")
  }

  /// The cursor covers one column, so an emoji under it or right before it
  /// keeps one column rather than having half of it hidden.
  func testCursorBesideNarrowEmojiKeepsItOneColumn() throws {
    // The cursor ends right after the heart, on the blank it would borrow.
    let cmds = try runWithText("\u{2764}\u{FE0F}")
    var spans: [String: Int?] = [:]
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd {
        spans[text] = cells
      }
    }
    XCTAssertEqual(spans["\u{2764}\u{FE0F}"], 1, "got \(spans)")
  }

  /// The emoji paints over the cell it borrows, so an empty cell with another
  /// background (here red from an erase) keeps the emoji to one column.
  func testEmptyNeighborWithOtherBackgroundIsNotBorrowed() throws {
    let cmds = try runWithText("\u{2764}\u{FE0F}\u{1b}[41m\u{1b}[K\u{1b}[0m\r\n")
    var spans: [String: Int?] = [:]
    for cmd in cmds {
      if case .glyphRun(_, let text, _, _, _, .terminal, _, _, _, let cells, _, _, _) = cmd {
        spans[text] = cells
      }
    }
    XCTAssertEqual(spans["\u{2764}\u{FE0F}"], 1, "got \(spans)")
  }
}
