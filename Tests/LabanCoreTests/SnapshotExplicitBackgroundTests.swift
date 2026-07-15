import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class SnapshotExplicitBackgroundTests: XCTestCase {
  private let explicitBackgroundFlag = UInt16(LABAN_CELL_FLAG_EXPLICIT_BACKGROUND)

  func testLocalSnapshotDistinguishesDefaultExplicitThemeEqualAndInverseBackgrounds() throws {
    let (snapshot, defaultCell, explicitCell, inverseCell) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    XCTAssertEqual(defaultCell.flags & explicitBackgroundFlag, 0)
    XCTAssertNotEqual(explicitCell.flags & explicitBackgroundFlag, 0)
    XCTAssertEqual(
      explicitCell.background_rgba,
      snapshot.pointee.default_background_rgba,
      "explicit identity must survive even when its resolved color equals the theme default")
    XCTAssertNotEqual(inverseCell.flags & explicitBackgroundFlag, 0)
    XCTAssertNotEqual(inverseCell.flags & UInt16(LABAN_CELL_FLAG_INVERSE), 0)
  }

  func testCopiedJSONSnapshotPreservesExplicitBackgroundIdentity() throws {
    let (snapshot, _, _, _) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    let copied = LabandSnapshotResponse.copying(
      logicalSessionId: "explicit-json",
      incarnationId: "inc",
      snapshot: UnsafePointer(snapshot),
      lifecycleState: .running)
    let roundTrip = try JSONDecoder().decode(
      LabandSnapshotResponse.self,
      from: JSONEncoder().encode(copied))

    let defaultCell = try XCTUnwrap(roundTrip.cells.first { $0.text == "D" })
    let explicitCell = try XCTUnwrap(roundTrip.cells.first { $0.text == "E" })
    let inverseCell = try XCTUnwrap(roundTrip.cells.first { $0.text == "I" })
    XCTAssertEqual(defaultCell.flags & explicitBackgroundFlag, 0)
    XCTAssertNotEqual(explicitCell.flags & explicitBackgroundFlag, 0)
    XCTAssertNotEqual(inverseCell.flags & explicitBackgroundFlag, 0)
  }

  func testExplicitBackgroundIdentityIsExcludedFromGlyphAttributes() {
    let styleFlags = UInt16(LABAN_CELL_FLAG_BOLD | LABAN_CELL_FLAG_ITALIC)
    let withBackgroundIdentity = styleFlags | explicitBackgroundFlag

    XCTAssertEqual(
      TextAttributes(cellFlags: withBackgroundIdentity),
      TextAttributes(cellFlags: styleFlags))
    XCTAssertEqual(TextAttributes(cellFlags: withBackgroundIdentity), [.bold, .italic])
  }

  private func makeIdentitySnapshot() throws -> (
    UnsafeMutablePointer<LabanSnapshot>, LabanCell, LabanCell, LabanCell
  ) {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)

    let initial = try XCTUnwrap(session.snapshot())
    let defaultBackground = initial.pointee.default_background_rgba
    laban_snapshot_destroy(initial)
    let red = (defaultBackground >> 24) & 0xFF
    let green = (defaultBackground >> 16) & 0xFF
    let blue = (defaultBackground >> 8) & 0xFF

    let input =
      "D"
      + "\u{1B}[48;2;\(red);\(green);\(blue)mE"
      + "\u{1B}[0m"
      + "\u{1B}[7mI"
      + "\u{1B}[0m"
    _ = session.write(Array(input.utf8))
    _ = session.poll()

    let snapshot = try XCTUnwrap(session.snapshot())
    let defaultCell = try XCTUnwrap(cell(in: snapshot, text: "D"))
    let explicitCell = try XCTUnwrap(cell(in: snapshot, text: "E"))
    let inverseCell = try XCTUnwrap(cell(in: snapshot, text: "I"))
    return (snapshot, defaultCell, explicitCell, inverseCell)
  }

  private func cell(
    in snapshot: UnsafePointer<LabanSnapshot>,
    text: String
  ) -> LabanCell? {
    let value = snapshot.pointee
    guard let cells = value.cells, let storage = value.utf8_storage else { return nil }
    for index in 0..<Int(value.cell_count) {
      let cell = cells[index]
      guard cell.utf8_length > 0 else { continue }
      let bytes = UnsafeRawPointer(storage)
        .advanced(by: Int(cell.utf8_offset))
        .assumingMemoryBound(to: UInt8.self)
      let cellText = String(
        bytes: UnsafeBufferPointer(start: bytes, count: Int(cell.utf8_length)),
        encoding: .utf8)
      if cellText == text { return cell }
    }
    return nil
  }
}
