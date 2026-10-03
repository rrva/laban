import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class FrameProducerBidiTests: XCTestCase {
  private func commands(_ text: String, bidi: Bool = true) throws -> [FrameCommand] {
    var size = LabanTerminalSize()
    size.rows = 3
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array(text.utf8))
    guard let snap = session.snapshot() else {
      XCTFail("snapshot nil")
      return []
    }
    defer { laban_snapshot_destroy(snap) }
    var producer = FrameProducer(cellWidth: 10, cellHeight: 20)
    producer.bidiDisplay = bidi
    return producer.commands(from: UnsafePointer(snap))
  }

  private func runs(_ cmds: [FrameCommand]) -> [(x: CGFloat, text: String, rtl: Bool)] {
    cmds.compactMap { cmd in
      if case .glyphRun(let origin, let text, _, _, let attrs, .terminal, _, _, _, _, _, _, _) = cmd
      {
        return (origin.x, text, attrs.contains(.rightToLeft))
      }
      return nil
    }
  }

  func testHebrewRunIsEmittedRightToLeftAtItsVisualColumn() throws {
    // "ab שלום cd": the Hebrew word keeps columns 3-6 and is mirrored.
    let emitted = runs(try commands("ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd"))
    let hebrew = try XCTUnwrap(emitted.first { $0.text == "\u{05E9}\u{05DC}\u{05D5}\u{05DD}" })
    XCTAssertTrue(hebrew.rtl)
    XCTAssertEqual(hebrew.x, 30)
    let tail = try XCTUnwrap(emitted.first { $0.text == "cd" })
    XCTAssertFalse(tail.rtl)
    XCTAssertEqual(tail.x, 80)
  }

  func testRightToLeftTextAfterLeftToRightMovesToTheEnd() throws {
    // "שלום 12": RTL then digits; with a left-to-right paragraph the digits
    // sit at the left of the Hebrew word.
    let emitted = runs(try commands("\u{05E9}\u{05DC}\u{05D5}\u{05DD} 12"))
    let hebrew = try XCTUnwrap(emitted.first { $0.rtl })
    let digits = try XCTUnwrap(emitted.first { $0.text == "12" })
    XCTAssertLessThan(digits.x, hebrew.x, "digits inside the RTL run display before the word")
  }

  func testBracketsInRightToLeftRunAreMirrored() throws {
    // "שלום (עולם)": the brackets sit between Hebrew letters, so they are in
    // the RTL run; drawn mirrored, each must be its counterpart so it still
    // opens toward the word it encloses.
    let emitted = runs(
      try commands(
        "\u{05E9}\u{05DC}\u{05D5}\u{05DD} (\u{05E2}\u{05D5}\u{05DC}\u{05DD})"))
    XCTAssertTrue(
      emitted.contains { $0.rtl && $0.text == ")\u{05E2}\u{05D5}\u{05DC}\u{05DD}(" },
      "got \(emitted.map(\.text))")
  }

  func testBoxDrawingAndEmojiRowsStayOnTheOrdinaryPath() throws {
    let emitted = runs(try commands("\u{2500}\u{2502} \u{1F600} \u{4E2D}\u{6587} abc"))
    XCTAssertFalse(emitted.contains { $0.rtl })
    var size = LabanTerminalSize()
    size.rows = 3
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("\u{2500}\u{2502} \u{1F600} \u{4E2D}\u{6587} abc".utf8))
    guard let snap = session.snapshot() else { return XCTFail("snapshot nil") }
    defer { laban_snapshot_destroy(snap) }
    XCTAssertTrue(
      FrameProducer(cellWidth: 10, cellHeight: 20).bidiLayouts(
        snapshot: snap.pointee, rows: 3, cols: 20, hyperlinkURIs: []
      ).isEmpty, "rows without strong RTL text must not get a BiDi layout")
  }

  func testBidiOffKeepsLogicalOrder() throws {
    let emitted = runs(try commands("ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd", bidi: false))
    XCTAssertFalse(emitted.contains { $0.rtl })
    XCTAssertEqual(emitted.first?.x, 0)
  }

  func testCursorFollowsItsCellOnABidiRow() throws {
    // Cursor moved onto the first Hebrew letter (logical column 3), which is
    // drawn at visual column 6.
    let cmds = try commands("ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd\u{1B}[1;4H")
    let cursor = cmds.compactMap { cmd -> CGRect? in
      if case .cursor(let rect, _) = cmd { return rect }
      return nil
    }.first
    XCTAssertEqual(cursor?.minX, 60)
  }

  func testLogicalColumnForClickOnBidiRow() throws {
    var size = LabanTerminalSize()
    size.rows = 3
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array("ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd".utf8))
    guard let snap = session.snapshot() else { return XCTFail("snapshot nil") }
    defer { laban_snapshot_destroy(snap) }
    XCTAssertEqual(
      FrameProducer.logicalColumn(row: 0, visualColumn: 6, in: snap.pointee, bidiDisplay: true), 3)
    XCTAssertEqual(
      FrameProducer.logicalColumn(row: 0, visualColumn: 1, in: snap.pointee, bidiDisplay: true), 1)
    XCTAssertEqual(
      FrameProducer.logicalColumn(row: 0, visualColumn: 6, in: snap.pointee, bidiDisplay: false), 6)
  }
}
