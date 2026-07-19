import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// The smooth-scroll continuity invariant: a fractional scroll position can be
/// rendered through different integer-viewport/fraction splits, and every
/// split must place the same content line at the same screen Y. The view
/// computes `contentYOffset = +(displayed - applied) * cellHeight`; rendering
/// `displayed = -9.5` as (applied -10, offset +0.5·ch) and as (applied -9,
/// offset -0.5·ch) must coincide. A sign error here is invisible at fast
/// scroll speeds but turns slow trackpad momentum tails into a sawtooth —
/// half-row backward creep punctuated by two-row forward leaps.
final class FrameProducerScrollOffsetContinuityTests: XCTestCase {

  private let cellHeight = 19

  private func glyphY(_ commands: [FrameCommand], lineText: String) -> CGFloat? {
    for cmd in commands {
      if case .glyphRun(let origin, let text, _, _, _, _, _, _, _, _, _) = cmd,
        text.contains(lineText)
      {
        return origin.y
      }
    }
    return nil
  }

  func testAdjacentAppliedSplitsRenderSameContentAtSameY() throws {
    var size = LabanTerminalSize()
    size.cols = 40
    size.rows = 6
    let session = try Session.fixture(size: size)
    defer { session.close() }
    session.write(Array((0..<40).map { "line \($0)\r\n" }.joined().utf8))
    session.poll()

    // Split A: viewport 10 rows back, fraction +0.5 (displayed -9.5).
    XCTAssertEqual(session.scrollViewport(deltaRows: -10), 0)
    session.poll()
    guard let snapA = session.snapshot() else { return XCTFail("snapshot A") }
    let producerA = FrameProducer(
      cellWidth: 9, cellHeight: cellHeight, originX: 13, originY: 0,
      contentYOffset: +0.5 * CGFloat(cellHeight))
    let commandsA = producerA.commands(from: UnsafePointer(snapA))
    laban_snapshot_destroy(snapA)

    // Split B: one row less deep, fraction -0.5 (same displayed -9.5).
    XCTAssertEqual(session.scrollViewport(deltaRows: 1), 0)
    session.poll()
    guard let snapB = session.snapshot() else { return XCTFail("snapshot B") }
    let producerB = FrameProducer(
      cellWidth: 9, cellHeight: cellHeight, originX: 13, originY: 0,
      contentYOffset: -0.5 * CGFloat(cellHeight))
    let commandsB = producerB.commands(from: UnsafePointer(snapB))
    laban_snapshot_destroy(snapB)

    // A content line visible in both viewports must land on the same Y.
    for line in ["line 26", "line 27", "line 28"] {
      let yA = try XCTUnwrap(glyphY(commandsA, lineText: line), "\(line) missing in split A")
      let yB = try XCTUnwrap(glyphY(commandsB, lineText: line), "\(line) missing in split B")
      XCTAssertEqual(
        yA, yB, accuracy: 0.001,
        "\(line): the same displayed position rendered via adjacent applied/fraction splits must coincide on screen"
      )
    }
  }
}
