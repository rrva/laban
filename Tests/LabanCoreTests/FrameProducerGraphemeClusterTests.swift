import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// M2 render proof — separate from grid-width conformance.
///
/// Grid width alone does not prove correct rendering: a width-correct cell
/// (one WIDE head + spacer tail) can still render as TWO glyphs if the producer
/// splits the cluster, or if it shapes the spacer separately. This test pins the
/// FrameProducer contract: a `👩‍🌾` cluster carried in ONE wide cell (full
/// 11-byte cluster in `utf8_storage`, `wide = WIDE`, plus a SPACER_TAIL) must
/// emit a SINGLE terminal glyph-run draw command carrying the whole cluster's
/// bytes — not two separate emoji runs (person, ear-of-rice).
///
/// The snapshot is produced by the REAL engine under mode 2027 ON, so this also
/// proves the live snapshot → FrameProducer path end to end.
final class FrameProducerGraphemeClusterTests: XCTestCase {

  // F0 9F A7 91 E2 80 8D F0 9F 8C BE = U+1F9D1 (person) ZWJ U+1F33E (ear-of-rice),
  // i.e. the gender-NEUTRAL farmer 🧑‍🌾. (The plan/source spell the cluster with
  // the woman glyph 👩‍🌾 = U+1F469, but the canonical bytes use the person base
  // U+1F9D1; derive the comparison string from the bytes, never a hand-typed glyph.)
  private let farmerBytes: [UInt8] = [
    0xF0, 0x9F, 0xA7, 0x91, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x8C, 0xBE,
  ]
  private var farmerString: String { String(decoding: farmerBytes, as: UTF8.self) }

  func testFarmerClusterRendersAsSingleGlyphRun() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // Mode 2027 ON, then print the farmer emoji. The engine lays it as one WIDE
    // head cell (all 11 bytes) + a SPACER_TAIL — the precondition this test needs.
    session.write(Array("\u{1b}[?2027h".utf8))
    session.write(farmerBytes)
    session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("snapshot must be non-nil")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    // Precondition guard: confirm the snapshot really has ONE wide cell carrying
    // the full cluster + a spacer tail (mirror of the M2 grid conformance).
    let cells = snap.pointee.cells
    XCTAssertNotNil(cells, "snapshot must have cells")
    if let cells, let storage = snap.pointee.utf8_storage {
      let head = cells[0]
      let tail = cells[1]
      XCTAssertEqual(head.wide, UInt8(LABAN_CELL_WIDE_WIDE), "head cell must be WIDE")
      XCTAssertEqual(
        tail.wide, UInt8(LABAN_CELL_WIDE_SPACER_TAIL), "col 1 must be SPACER_TAIL")
      let base = UnsafeRawPointer(storage).advanced(by: Int(head.utf8_offset))
      let headBytes = Array(
        UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self), count: Int(head.utf8_length)))
      XCTAssertEqual(headBytes, farmerBytes, "head cell must carry all 11 cluster bytes")
    }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16)
    let cmds = producer.commands(from: UnsafePointer(snap))

    // Collect terminal glyph runs whose text contains any farmer code point.
    // The farmer is built from person (U+1F9D1), ZWJ (U+200D), ear-of-rice
    // (U+1F33E). A correct producer emits ONE run carrying all of them; a broken
    // one would split into two emoji runs.
    let farmerScalars: Set<UInt32> = [0x1F9D1, 0x1F33E]
    let farmerRuns: [String] = cmds.compactMap { cmd in
      guard case .glyphRun(_, let text, _, _, _, let src, _, _, _, _, _, _) = cmd, src == .terminal
      else { return nil }
      let touchesFarmer = text.unicodeScalars.contains { farmerScalars.contains($0.value) }
      return touchesFarmer ? text : nil
    }

    XCTAssertEqual(
      farmerRuns.count, 1,
      "the farmer cluster must produce exactly ONE glyph run, not split into "
        + "separate emoji runs; got \(farmerRuns.count): \(farmerRuns.map { $0.debugDescription })")

    // That single run must carry the WHOLE cluster (all three code points), i.e.
    // it shapes as one renderable unit — proving width-correct AND glyph-correct.
    guard let run = farmerRuns.first else { return }
    XCTAssertTrue(
      run.contains(farmerString),
      "the single glyph run must carry the full cluster bytes; got \(run.debugDescription)")
    XCTAssertTrue(
      run.unicodeScalars.contains(where: { $0.value == 0x1F9D1 })
        && run.unicodeScalars.contains(where: { $0.value == 0x200D })
        && run.unicodeScalars.contains(where: { $0.value == 0x1F33E }),
      "the single run must contain person + ZWJ + ear-of-rice, not a fragment")
  }
}
