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

  func testNewWriterJSONSnapshotPreservesExplicitBackgroundIdentity() throws {
    let (snapshot, _, _, _) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    let roundTrip = try jsonRoundTrip(
      LabandSnapshotResponse.copying(
        logicalSessionId: "explicit-json-new",
        incarnationId: "inc",
        snapshot: UnsafePointer(snapshot),
        lifecycleState: .running))

    try assertRemoteIdentity(roundTrip, expectsExplicitIdentity: true)
  }

  func testOldWriterJSONSnapshotWithoutExplicitBackgroundBitStillDecodes() throws {
    let (snapshot, _, _, _) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    let copied = LabandSnapshotResponse.copying(
      logicalSessionId: "explicit-json-old",
      incarnationId: "inc",
      snapshot: UnsafePointer(snapshot),
      lifecycleState: .running)
    let roundTrip = try jsonRoundTrip(removingExplicitBackgroundIdentity(from: copied))

    try assertRemoteIdentity(roundTrip, expectsExplicitIdentity: false)
  }

  func testNewWriterExplicitBackgroundIdentityCrossesABIV1Ring() throws {
    let (snapshot, _, _, _) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    let roundTrip = try ringRoundTrip(
      snapshot: snapshot,
      writerKind: "new",
      emitsExplicitBackgroundIdentity: true)

    try assertRemoteIdentity(roundTrip, expectsExplicitIdentity: true)
  }

  func testOldWriterABIV1RingWithoutExplicitBackgroundBitStillDecodes() throws {
    let (snapshot, _, _, _) = try makeIdentitySnapshot()
    defer { laban_snapshot_destroy(snapshot) }

    let roundTrip = try ringRoundTrip(
      snapshot: snapshot,
      writerKind: "old",
      emitsExplicitBackgroundIdentity: false)

    try assertRemoteIdentity(roundTrip, expectsExplicitIdentity: false)
  }

  func testExplicitBackgroundIdentityIsExcludedFromGlyphAttributes() {
    let styleFlags = UInt16(LABAN_CELL_FLAG_BOLD | LABAN_CELL_FLAG_ITALIC)
    let withBackgroundIdentity = styleFlags | explicitBackgroundFlag

    XCTAssertEqual(
      TextAttributes(cellFlags: withBackgroundIdentity),
      TextAttributes(cellFlags: styleFlags))
    XCTAssertEqual(TextAttributes(cellFlags: withBackgroundIdentity), [.bold, .italic])
  }

  private func jsonRoundTrip(_ response: LabandSnapshotResponse) throws
    -> LabandSnapshotResponse
  {
    try JSONDecoder().decode(
      LabandSnapshotResponse.self,
      from: JSONEncoder().encode(response))
  }

  private func removingExplicitBackgroundIdentity(
    from response: LabandSnapshotResponse
  ) -> LabandSnapshotResponse {
    var response = response
    response.cells = response.cells.map { cell in
      var cell = cell
      cell.flags &= ~explicitBackgroundFlag
      return cell
    }
    return response
  }

  private func ringRoundTrip(
    snapshot: UnsafePointer<LabanSnapshot>,
    writerKind: String,
    emitsExplicitBackgroundIdentity: Bool
  ) throws -> LabandSnapshotResponse {
    let logicalSessionId = "explicit-background-ring-\(writerKind)"
    let directory = ".tmp/\(logicalSessionId)-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: directory)) }
    let writer = try LabandSnapshotRingWriter(
      path: "\(directory)/ring.bin",
      logicalSessionId: logicalSessionId,
      incarnationId: "inc",
      maxRows: Int(snapshot.pointee.rows),
      maxCols: Int(snapshot.pointee.cols))
    XCTAssertEqual(LabandSnapshotRingLayout.abiVersion, 1)

    if emitsExplicitBackgroundIdentity {
      try writer.publish(snapshot: snapshot)
    } else {
      let value = snapshot.pointee
      let sourceCells = try XCTUnwrap(value.cells)
      let legacyCells = UnsafeBufferPointer(
        start: sourceCells,
        count: Int(value.cell_count)
      ).map { cell in
        var cell = cell
        cell.flags &= ~explicitBackgroundFlag
        return cell
      }
      try legacyCells.withUnsafeBufferPointer { cells in
        var legacySnapshot = value
        legacySnapshot.cells = cells.baseAddress
        try withUnsafePointer(to: &legacySnapshot) { pointer in
          try writer.publish(snapshot: pointer)
        }
      }
    }

    let reader = try LabandSnapshotRingReader(
      attachment: writer.attachment,
      logicalSessionId: logicalSessionId,
      incarnationId: "inc")
    return try reader.latestSnapshot()
  }

  private func assertRemoteIdentity(
    _ snapshot: LabandSnapshotResponse,
    expectsExplicitIdentity: Bool
  ) throws {
    let defaultCell = try XCTUnwrap(snapshot.cells.first { $0.text == "D" })
    let explicitCell = try XCTUnwrap(snapshot.cells.first { $0.text == "E" })
    let inverseCell = try XCTUnwrap(snapshot.cells.first { $0.text == "I" })
    XCTAssertEqual(defaultCell.flags & explicitBackgroundFlag, 0)
    XCTAssertEqual(
      explicitCell.backgroundRGBA,
      defaultCell.backgroundRGBA,
      "the theme-equal explicit cell must remain color-indistinguishable from the default cell")
    if expectsExplicitIdentity {
      XCTAssertNotEqual(explicitCell.flags & explicitBackgroundFlag, 0)
      XCTAssertNotEqual(inverseCell.flags & explicitBackgroundFlag, 0)
    } else {
      XCTAssertEqual(explicitCell.flags & explicitBackgroundFlag, 0)
      XCTAssertEqual(inverseCell.flags & explicitBackgroundFlag, 0)
    }
    XCTAssertNotEqual(inverseCell.flags & UInt16(LABAN_CELL_FLAG_INVERSE), 0)
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
