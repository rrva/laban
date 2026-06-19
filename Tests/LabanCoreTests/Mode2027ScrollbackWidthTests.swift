import LabanCore
import LabanTerminalCore
import XCTest

/// M3 — Swift width-consumer coherence under DEC private mode 2027.
///
/// These tests place a grapheme cluster (the "farmer" emoji, which the engine
/// lays as ONE 2-column cluster when mode 2027 is ON but TWO clusters / 4
/// columns when OFF) and a CJK character into scrollback, scroll them off the
/// live viewport, then exercise the scrollback FIND and COPY consumers. Under
/// mode ON the consumers must report the engine's actual width (2 per cluster)
/// and copy the exact cluster bytes; under mode OFF they report the legacy
/// per-scalar columns (farmer = 4).
///
/// The whole point of M3 is that find/copy use the engine's carried width
/// (`ScrollbackBlock.graphemeWidths`) rather than re-deriving it from the pinned
/// `TerminalDisplayWidth` scalar table. The mutation guard at the bottom proves
/// that forcing the scalar path makes the mode-ON assertion fail.
final class Mode2027ScrollbackWidthTests: XCTestCase {

  // F0 9F A7 91 E2 80 8D F0 9F 8C BE — decodes to U+1F9D1 ZWJ U+1F33E.
  // (Derive the comparison string from the bytes, never a typed literal.)
  private let farmerBytes: [UInt8] = [
    0xF0, 0x9F, 0xA7, 0x91, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x8C, 0xBE,
  ]
  private var farmer: String { String(decoding: farmerBytes, as: UTF8.self) }

  // U+4E2D 中 — a CJK ideograph, width 2 in both modes.
  private let cjkBytes: [UInt8] = [0xE4, 0xB8, 0xAD]
  private var cjk: String { String(decoding: cjkBytes, as: UTF8.self) }

  private func size(rows: Int32 = 4, cols: Int32 = 80) -> LabanTerminalSize {
    var s = LabanTerminalSize()
    s.rows = rows
    s.cols = cols
    return s
  }

  /// Print `bytes` on row 0 then push the row into scrollback with line feeds,
  /// returning a session whose history row 0 holds the cluster(s). `modeOn`
  /// toggles DEC 2027 before printing.
  private func sessionWithScrolledOff(_ bytes: [UInt8], modeOn: Bool) throws -> Session {
    let session = try Session.fixture(size: size(rows: 4, cols: 80))
    if modeOn {
      XCTAssertEqual(session.write(Array("\u{1b}[?2027h".utf8)), 0)
    }
    XCTAssertEqual(session.write(bytes), 0)
    XCTAssertEqual(session.write([0x0D]), 0)  // CR
    // rows=4, so 12 LFs guarantees row 0 scrolled into history.
    XCTAssertEqual(session.write(Array(repeating: 0x0A, count: 12)), 0)
    return session
  }

  /// Find the scrollback row index that contains `needle`'s bytes.
  private func rowContaining(_ needle: String, in block: ScrollbackBlock) -> Int? {
    let textBytes = Array(block.text.utf8)
    let needleBytes = Array(needle.utf8)
    for row in 0..<block.rowOffsets.count {
      let start = block.rowOffsets[row]
      let end = (row + 1 < block.rowOffsets.count) ? block.rowOffsets[row + 1] : textBytes.count
      guard start <= end, end <= textBytes.count else { continue }
      let slice = Array(textBytes[start..<end])
      if containsSubsequence(slice, needleBytes) { return row }
    }
    return nil
  }

  private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for i in 0...(haystack.count - needle.count) where Array(haystack[i..<i + needle.count]) == needle {
      return true
    }
    return false
  }

  // MARK: - Diagnostic (records the carried metadata)

  func testDiagnostic_carriedWidthsForFarmer() throws {
    let on = try sessionWithScrolledOff(farmerBytes, modeOn: true)
    defer { on.close() }
    guard let block = on.scrollbackBlock() else {
      XCTFail("scrollbackBlock returned nil")
      return
    }
    XCTAssertNotNil(block.graphemeWidths, "engine width metadata must be carried")
    guard let row = rowContaining(farmer, in: block) else {
      XCTFail("farmer row not found in scrollback")
      return
    }
    let clusters = block.graphemeWidths?[row] ?? []
    let leading = clusters.prefix(3).map { "(\($0.byteLength)b,\($0.columns)c)" }.joined(separator: " ")
    print("M3 diag ON: row=\(row) firstClusters=\(leading) totalClusters=\(clusters.count)")
  }

  // MARK: - FIND

  func testScrollbackFind_farmer_modeON_columnsAre2() throws {
    let session = try sessionWithScrolledOff(farmerBytes, modeOn: true)
    defer { session.close() }
    guard let block = session.scrollbackBlock() else {
      XCTFail("scrollbackBlock nil")
      return
    }
    XCTAssertNotNil(block.graphemeWidths, "mode ON must carry engine widths")
    let matches = TerminalFind.search(needle: farmer, in: block)
    guard let row = rowContaining(farmer, in: block),
      let match = matches.first(where: { $0.row == row })
    else {
      XCTFail("farmer not found via scrollback find (matches=\(matches))")
      return
    }
    // Engine laid the farmer as ONE 2-column cluster at the start of the row.
    XCTAssertEqual(match.startColumn, 0, "farmer starts at column 0")
    XCTAssertEqual(
      match.endColumn, 2,
      "mode ON: farmer cluster spans the engine's 2 columns, not the legacy 4")
  }

  func testScrollbackFind_farmer_modeOFF_columnsAre4() throws {
    let session = try sessionWithScrolledOff(farmerBytes, modeOn: false)
    defer { session.close() }
    guard let block = session.scrollbackBlock() else {
      XCTFail("scrollbackBlock nil")
      return
    }
    let matches = TerminalFind.search(needle: farmer, in: block)
    guard let row = rowContaining(farmer, in: block),
      let match = matches.first(where: { $0.row == row })
    else {
      XCTFail("farmer not found via scrollback find (matches=\(matches))")
      return
    }
    XCTAssertEqual(match.startColumn, 0, "farmer starts at column 0")
    XCTAssertEqual(
      match.endColumn, 4,
      "mode OFF: farmer lays as two WIDE clusters = 4 legacy columns")
  }

  func testScrollbackFind_cjk_modeON_columnsAre2() throws {
    let session = try sessionWithScrolledOff(cjkBytes, modeOn: true)
    defer { session.close() }
    guard let block = session.scrollbackBlock() else {
      XCTFail("scrollbackBlock nil")
      return
    }
    let matches = TerminalFind.search(needle: cjk, in: block)
    guard let row = rowContaining(cjk, in: block),
      let match = matches.first(where: { $0.row == row })
    else {
      XCTFail("CJK not found via scrollback find (matches=\(matches))")
      return
    }
    XCTAssertEqual(match.startColumn, 0)
    XCTAssertEqual(match.endColumn, 2, "CJK is 2 columns under mode ON")
  }

  // MARK: - COPY (via the scrollback selection path)

  /// Select the whole scrolled-off cluster row and assert copy returns the exact
  /// cluster bytes. Uses the public selection path that drives `plainLineText`.
  private func copyScrolledOffRow(
    _ bytes: [UInt8], modeOn: Bool
  ) throws -> String {
    let session = try sessionWithScrolledOff(bytes, modeOn: modeOn)
    defer { session.close() }
    guard let block = session.scrollbackBlock() else {
      throw XCTSkip("scrollbackBlock nil")
    }
    guard let row = rowContaining(String(decoding: bytes, as: UTF8.self), in: block) else {
      throw XCTSkip("cluster row not found")
    }
    guard let snapPtr = session.snapshot(), let vp = session.viewportState() else {
      throw XCTSkip("snapshot/viewport nil")
    }
    defer { laban_snapshot_destroy(snapPtr) }
    let snap = snapPtr.pointee
    let cols = Int(snap.cols)

    // The selection is in absolute (scrollback-anchored) coordinates: anchor at
    // the start of the cluster row, focus at the far right so the whole row is
    // covered. selectedText maps absolute rows through scrollbackBlock for any
    // row not in the live viewport.
    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: row - vp.viewportOffset, col: 0),
      focus: TerminalCellCoordinate(row: row - vp.viewportOffset, col: cols - 1)
    )
    return sel.selectedText(from: session, viewportSnapshot: snap, viewportState: vp)
  }

  func testScrollbackCopy_farmer_modeON_returnsExactClusterBytes() throws {
    let copied = try copyScrolledOffRow(farmerBytes, modeOn: true)
    XCTAssertEqual(
      Array(copied.utf8), farmerBytes,
      "mode ON copy must return the exact farmer cluster bytes, got \(Array(copied.utf8))")
  }

  func testScrollbackCopy_cjk_modeON_returnsExactBytes() throws {
    let copied = try copyScrolledOffRow(cjkBytes, modeOn: true)
    XCTAssertEqual(Array(copied.utf8), cjkBytes, "mode ON copy must return the CJK bytes")
  }

  // MARK: - Mutation guard

  /// Demonstrates the Review Gate mutation guard: the engine-width carried path
  /// gives column 2 for the farmer, while the legacy per-scalar table gives 4.
  /// If a consumer were forced back onto `TerminalDisplayWidth`, the mode-ON
  /// assertion (endColumn == 2) would become 4 and fail. We assert the gap here
  /// directly so the guard is self-documenting and CI-visible.
  func testMutationGuard_scalarTableWouldDisagreeWithEngineWidth() throws {
    let session = try sessionWithScrolledOff(farmerBytes, modeOn: true)
    defer { session.close() }
    guard let block = session.scrollbackBlock() else {
      XCTFail("scrollbackBlock nil")
      return
    }
    // Engine-width path (what the consumer actually uses): column 2.
    let engineMatch = TerminalFind.search(needle: farmer, in: block).first
    XCTAssertEqual(engineMatch?.endColumn, 2, "engine width path gives 2")

    // What the legacy scalar table WOULD compute for the same cluster string.
    let scalarColumns = TerminalDisplayWidth.cells(of: farmer)
    XCTAssertEqual(
      scalarColumns, 4,
      "the pinned scalar table over-counts the clustered farmer as 4 — forcing "
        + "the consumer onto this path would break the mode-ON endColumn==2 assertion")
    XCTAssertNotEqual(
      engineMatch?.endColumn, scalarColumns,
      "engine width (2) must differ from the scalar fallback (4); this is the "
        + "drift M3 fixes")
  }

  // MARK: - Wrapped (multi-screen-row) alignment

  /// A logical line wider than the terminal soft-wraps onto multiple screen
  /// rows. The scrollback width metadata is sourced by walking the engine grid
  /// per SCREEN row and aligning grid screen-row R to formatter row R (the
  /// formatter runs with unwrap=false, one text row per screen row). Earlier
  /// tests only place a single cluster on one row; this one drives a hard-wrapped
  /// CJK line (each 中 = 2 columns) through a narrow terminal so the line occupies
  /// a first row plus a continuation row, then asserts the carried widths describe
  /// EACH wrapped row correctly. If the continuation row inherited another row's
  /// metadata, either the global tiling check would drop all metadata
  /// (`graphemeWidths == nil`) or the per-cluster widths/count would be wrong —
  /// so this catches a row-alignment regression across a wrap.
  func testWrappedMultiRowClusterWidthsAlignPerScreenRow() throws {
    let session = try Session.fixture(size: size(rows: 4, cols: 4))
    defer { session.close() }
    XCTAssertEqual(session.write(Array("\u{1b}[?2027h".utf8)), 0)
    // Three CJK ideographs = 6 columns; at cols=4 the engine wraps after two, so
    // screen row 0 holds 中中 (4 cols) and the continuation row holds 中 (2 cols).
    XCTAssertEqual(session.write(cjkBytes + cjkBytes + cjkBytes), 0)
    XCTAssertEqual(session.write([0x0D]), 0)
    XCTAssertEqual(session.write(Array(repeating: 0x0A, count: 12)), 0)

    guard let block = session.scrollbackBlock() else {
      XCTFail("scrollbackBlock nil")
      return
    }
    XCTAssertNotNil(
      block.graphemeWidths,
      "wrapped rows must still carry engine widths (nil ⇒ a row mis-tiled ⇒ "
        + "grid/formatter row alignment broke across the wrap)")

    let textBytes = Array(block.text.utf8)
    var cjkRowCount = 0
    var cjkClusters: [ScrollbackBlock.ClusterWidth] = []
    for row in 0..<block.rowOffsets.count {
      let start = block.rowOffsets[row]
      let end = (row + 1 < block.rowOffsets.count) ? block.rowOffsets[row + 1] : textBytes.count
      guard start <= end, end <= textBytes.count else { continue }
      let slice = Array(textBytes[start..<end])
      guard containsSubsequence(slice, cjkBytes) else { continue }
      cjkRowCount += 1
      cjkClusters.append(contentsOf: (block.graphemeWidths?[row] ?? []).filter { $0.byteLength == 3 })
    }

    XCTAssertGreaterThanOrEqual(
      cjkRowCount, 2, "the 6-column line must wrap onto a continuation row at cols=4")
    XCTAssertEqual(
      cjkClusters.count, 3,
      "all three 中 must be carried as clusters across the wrapped rows; got \(cjkClusters.count)")
    for c in cjkClusters {
      XCTAssertEqual(c.columns, 2, "each 中 is a 2-column cluster on every wrapped row")
    }

    // Find must report 2-column matches on the continuation row too.
    let matches = TerminalFind.search(needle: cjk, in: block)
    XCTAssertFalse(matches.isEmpty, "find locates the wrapped CJK")
    for m in matches {
      XCTAssertEqual(m.endColumn - m.startColumn, 2, "each CJK match spans the engine's 2 columns")
    }
  }
}
