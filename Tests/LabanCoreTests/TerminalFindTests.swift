import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalFindTests: XCTestCase {
  func testEmptyNeedleReturnsNoMatches() throws {
    try withSnapshot(text: "hello") { snap in
      XCTAssertEqual(TerminalFind.search(needle: "", inSnapshot: snap), [])
    }
  }

  func testSingleRowMatchAtStart() throws {
    try withSnapshot(text: "hello world") { snap in
      XCTAssertEqual(
        TerminalFind.search(needle: "hello", inSnapshot: snap),
        [TerminalFindMatch(row: 0, startColumn: 0, endColumn: 5)]
      )
    }
  }

  func testTwoNonOverlappingMatchesOnSameRow() throws {
    try withSnapshot(text: "apple banana apple pie") { snap in
      XCTAssertEqual(
        TerminalFind.search(needle: "apple", inSnapshot: snap),
        [
          TerminalFindMatch(row: 0, startColumn: 0, endColumn: 5),
          TerminalFindMatch(row: 0, startColumn: 13, endColumn: 18),
        ])
    }
  }

  func testSmartCaseFoldsAllLowercaseNeedle() throws {
    try withSnapshot(text: "Hello") { snap in
      XCTAssertEqual(
        TerminalFind.search(needle: "hello", inSnapshot: snap),
        [TerminalFindMatch(row: 0, startColumn: 0, endColumn: 5)]
      )
    }
  }

  func testSmartCaseUsesCaseSensitiveNeedleWithUppercaseASCII() throws {
    try withSnapshot(text: "hello Hello") { snap in
      XCTAssertEqual(
        TerminalFind.search(needle: "Hello", inSnapshot: snap),
        [TerminalFindMatch(row: 0, startColumn: 6, endColumn: 11)]
      )
    }
  }

  func testWideCharacterMatchCoversWideCell() throws {
    try withSnapshot(text: "中A", rows: 2, cols: 10) { snap in
      XCTAssertEqual(
        TerminalFind.search(needle: "中", inSnapshot: snap),
        [TerminalFindMatch(row: 0, startColumn: 0, endColumn: 2)]
      )
    }
  }

  func testSoftWrappedNeedleAcrossRowsIsNotFound() throws {
    try withSnapshot(text: "abcdeF", rows: 3, cols: 5) { snap in
      XCTAssertEqual(TerminalFind.search(needle: "eF", inSnapshot: snap), [])
    }
  }

  func testInvisibleCellsDoNotCreateFalsePositive() throws {
    try withSnapshot(text: "a\u{1B}[8msecret\u{1B}[0m b", rows: 2, cols: 20) { snap in
      XCTAssertEqual(TerminalFind.search(needle: "secret", inSnapshot: snap), [])
    }
  }

  func testScrollbackASCIIPathFindsRowsAndColumns() {
    let block = ScrollbackBlock(
      text: "alpha apple\nbanana\napple pie",
      rowOffsets: [0, 12, 19]
    )

    XCTAssertEqual(
      TerminalFind.search(needle: "apple", in: block),
      [
        TerminalFindMatch(row: 0, startColumn: 6, endColumn: 11),
        TerminalFindMatch(row: 2, startColumn: 0, endColumn: 5),
      ])
  }

  func testScrollbackUnicodeFallbackMapsCharacterColumns() {
    let block = ScrollbackBlock(
      text: "aéx\n cafe\u{301}",
      rowOffsets: [0, 5]
    )

    XCTAssertEqual(
      TerminalFind.search(needle: "é", in: block),
      [TerminalFindMatch(row: 0, startColumn: 1, endColumn: 2)]
    )
    XCTAssertEqual(
      TerminalFind.search(needle: "e\u{301}", in: block),
      [TerminalFindMatch(row: 1, startColumn: 4, endColumn: 5)]
    )
  }

  func testScrollbackUnicodeFallbackUsesDisplayColumnsAfterWidePrefix() {
    let cjk = ScrollbackBlock(
      text: "中apple",
      rowOffsets: [0]
    )
    XCTAssertEqual(
      TerminalFind.search(needle: "apple", in: cjk),
      [TerminalFindMatch(row: 0, startColumn: 2, endColumn: 7)]
    )

    let emoji = ScrollbackBlock(
      text: "👩\u{200D}💻apple",
      rowOffsets: [0]
    )
    XCTAssertEqual(
      TerminalFind.search(needle: "apple", in: emoji),
      [TerminalFindMatch(row: 0, startColumn: 4, endColumn: 9)]
    )
  }

  func testSessionFastScrollbackFindMatchesExtractedScrollback() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("alpha apple\r\nbanana\r\nApple pie\r\n".utf8))
    session.poll()

    let viewportRows = try XCTUnwrap(session.viewportState()).totalRows
    let fastMatches = try XCTUnwrap(
      session.findMatchesInScrollback(needle: "apple", maxRows: viewportRows))
    let block = try XCTUnwrap(session.scrollbackBlock(maxRows: viewportRows))

    XCTAssertEqual(fastMatches, TerminalFind.search(needle: "apple", in: block))
    XCTAssertEqual(
      fastMatches,
      [
        TerminalFindMatch(row: 0, startColumn: 6, endColumn: 11),
        TerminalFindMatch(row: 2, startColumn: 0, endColumn: 5),
      ])
  }

  func testSessionFastScrollbackFindDeclinesUnicodeRows() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("café apple\r\n".utf8))
    session.poll()

    let viewportRows = try XCTUnwrap(session.viewportState()).totalRows
    XCTAssertNil(session.findMatchesInScrollback(needle: "apple", maxRows: viewportRows))
  }

  private func withSnapshot(
    text: String,
    rows: Int32 = 4,
    cols: Int32 = 80,
    _ body: (UnsafePointer<LabanSnapshot>) throws -> Void
  ) throws {
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(text.utf8))
    session.poll()
    guard let snapshot = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snapshot) }
    try body(UnsafePointer(snapshot))
  }
}
