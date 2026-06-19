import Darwin
import LabanTerminalCore
import XCTest

/// M2 — Grid & cursor-advance conformance for DEC private mode 2027
/// (grapheme-cluster / Unicode core width).
///
/// M0 already characterized the engine (every assumption confirmed, no gaps).
/// This milestone PINS the engine's grid behavior with hard-coded expectations:
/// for each test grapheme, in BOTH mode OFF and mode ON, it asserts the per-cell
/// `wide` layout (head + spacer tail) carried in `LabanSnapshot`, the cursor
/// advance (`cursor_col`), AND the cursor advance the engine reports to a program
/// via `CSI 6n` (DSR cursor-position report). Every expected width/advance is a
/// LITERAL measured first (see the table below), so changing an ON expected value
/// to the OFF value makes exactly that row FAIL — the Review Gate's mutation check.
///
/// Measured 2026-06-19 through the real bridge (fixture session →
/// `ghostty_terminal_vt_write`). Layout notation: `W` = WIDE head cell, `T` =
/// SPACER_TAIL, `N` = NARROW. Cursor advance = cells consumed; CSI 6n column is
/// 1-based, so reported column == advance + 1 (printing starts at column 1).
///
///   grapheme            | OFF (layout / advance) | ON (layout / advance)
///   --------------------|------------------------|----------------------
///   a       U+0061      | N            / 1       | N            / 1
///   中      U+4E2D      | W T          / 2       | W T          / 2
///   👩‍🌾  farmer (ZWJ) | W T W T      / 4       | W T          / 2   (11 bytes in head)
///   ▶️      U+25B6 VS16 | N            / 1       | W T          / 2
///   ▶︎      U+25B6 VS15 | N            / 1       | N            / 1
///   🇸🇪    regional pr | W T W T      / 4       | W T          / 2
///   👨‍👩‍👧 ZWJ family | W T W T W T  / 6       | W T          / 2
///
/// Notable measured fact (NOT a gap): a base + VS16 is NARROW/advance-1 with mode
/// OFF — the engine only widens the VS16 emoji-presentation sequence to 2 cells
/// when grapheme clustering is ON. VS15 (text presentation) stays 1 cell in both
/// modes. OFF is also NOT strictly per-codepoint: the engine forms grapheme
/// clusters even with mode OFF (e.g. farmer → two `W T` clusters, ZWJ riding the
/// head), then sums their legacy widths — matching M0's Surprises & Discoveries.
final class Mode2027GridConformanceTests: XCTestCase {

  // MARK: - Expected per-cell width category

  private enum Wide: UInt8, CustomStringConvertible {
    case narrow = 0
    case wide = 1
    case spacerTail = 2
    var description: String {
      switch self {
      case .narrow: return "NARROW"
      case .wide: return "WIDE"
      case .spacerTail: return "SPACER_TAIL"
      }
    }
  }

  /// One conformance row: the grapheme bytes and its expected layout/advance in
  /// each mode. Every numeric/enum value here is a measured literal (see header).
  private struct Case {
    let name: String
    let bytes: [UInt8]
    /// Expected `wide` category per occupied cell, left-to-right (head + tails).
    let offLayout: [Wide]
    /// Cursor columns consumed (== `cursor_col` after printing at column 0).
    let offAdvance: Int
    let onLayout: [Wide]
    let onAdvance: Int
    /// The full cluster bytes the engine packs into the head cell under mode ON
    /// (nil for cases the engine keeps as multiple clusters / a single scalar
    /// cell where head bytes are simply the input). When set, asserts the head
    /// cell carries ALL these bytes — proving the cluster is one renderable unit.
    let onHeadBytes: [UInt8]?
  }

  // F0 9F A7 91 E2 80 8D F0 9F 8C BE
  private static let farmer: [UInt8] = [
    0xF0, 0x9F, 0xA7, 0x91, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x8C, 0xBE,
  ]

  private let cases: [Case] = [
    // ASCII: one narrow cell, advance 1, both modes.
    Case(
      name: "a (ASCII U+0061)",
      bytes: Array("a".utf8),
      offLayout: [.narrow], offAdvance: 1,
      onLayout: [.narrow], onAdvance: 1,
      onHeadBytes: Array("a".utf8)),
    // CJK wide: WIDE + spacer tail, advance 2, both modes.
    Case(
      name: "中 (CJK U+4E2D)",
      bytes: Array("中".utf8),
      offLayout: [.wide, .spacerTail], offAdvance: 2,
      onLayout: [.wide, .spacerTail], onAdvance: 2,
      onHeadBytes: Array("中".utf8)),
    // ZWJ farmer: OFF = two WIDE+tail clusters (advance 4, ZWJ rides the head);
    // ON = ONE WIDE+tail carrying all 11 bytes (advance 2).
    Case(
      name: "👩‍🌾 (ZWJ farmer U+1F9D1 ZWJ U+1F33E)",
      bytes: farmer,
      offLayout: [.wide, .spacerTail, .wide, .spacerTail], offAdvance: 4,
      onLayout: [.wide, .spacerTail], onAdvance: 2,
      onHeadBytes: farmer),
    // VS16 (emoji presentation): OFF = NARROW/advance 1; ON = WIDE+tail/advance 2.
    Case(
      name: "▶️ (U+25B6 VS16 emoji)",
      bytes: Array("▶️".utf8),
      offLayout: [.narrow], offAdvance: 1,
      onLayout: [.wide, .spacerTail], onAdvance: 2,
      onHeadBytes: Array("▶️".utf8)),
    // VS15 (text presentation): NARROW/advance 1 in BOTH modes.
    Case(
      name: "▶︎ (U+25B6 VS15 text)",
      bytes: Array("▶︎".utf8),
      offLayout: [.narrow], offAdvance: 1,
      onLayout: [.narrow], onAdvance: 1,
      onHeadBytes: Array("▶︎".utf8)),
    // Regional-indicator flag pair: OFF = two WIDE+tail (advance 4); ON = one
    // WIDE+tail (advance 2) carrying both regional indicators.
    Case(
      name: "🇸🇪 (regional indicator pair / flag)",
      bytes: Array("🇸🇪".utf8),
      offLayout: [.wide, .spacerTail, .wide, .spacerTail], offAdvance: 4,
      onLayout: [.wide, .spacerTail], onAdvance: 2,
      onHeadBytes: Array("🇸🇪".utf8)),
    // ZWJ family: OFF = three WIDE+tail clusters (advance 6); ON = one WIDE+tail
    // (advance 2) carrying all five code points.
    Case(
      name: "👨‍👩‍👧 (ZWJ family)",
      bytes: Array("👨‍👩‍👧".utf8),
      offLayout: [.wide, .spacerTail, .wide, .spacerTail, .wide, .spacerTail], offAdvance: 6,
      onLayout: [.wide, .spacerTail], onAdvance: 2,
      onHeadBytes: Array("👨‍👩‍👧".utf8)),
  ]

  // MARK: - Session / IO helpers (mirror Mode2027CharacterizationTests)

  private func makeFixtureSession(rows: Int32 = 24, cols: Int32 = 80) -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0 else { return nil }
    return session
  }

  private func writeBytes(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  private func drainResponse(_ session: OpaquePointer) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 256)
    var len: size_t = 0
    let r = laban_session_drain_response(session, &buf, buf.count, &len)
    XCTAssertEqual(r, 0, "drain_response must succeed")
    return Array(buf.prefix(Int(len)))
  }

  /// Occupied cells of row 0: (wide category, utf8 bytes) for any cell that
  /// carries text or is a spacer. This is exactly what the renderer/cursor read.
  private func occupiedRow0(
    _ session: OpaquePointer
  ) -> (cursorCol: Int, cells: [(wide: UInt8, utf8: [UInt8])])? {
    var snapPtr: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(session, &snapPtr) == 0, let snapPtr else { return nil }
    defer { laban_snapshot_destroy(snapPtr) }
    let snap = snapPtr.pointee
    let cols = Int(snap.cols)
    guard let cells = snap.cells, let storage = snap.utf8_storage else {
      return (Int(snap.cursor_col), [])
    }
    var out: [(wide: UInt8, utf8: [UInt8])] = []
    for col in 0..<cols {
      let cell = cells[col]
      let hasText = cell.utf8_length > 0
      let isSpacer = cell.wide == 2 || cell.wide == 3
      guard hasText || isSpacer else { continue }
      var bytes: [UInt8] = []
      if hasText {
        let base = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self), count: Int(cell.utf8_length))
        bytes = Array(buf)
      }
      out.append((wide: cell.wide, utf8: bytes))
    }
    return (Int(snap.cursor_col), out)
  }

  /// Print bytes then `CSI 6n`; return the 1-based column from the CPR reply.
  private func cprColumnAfter(_ bytes: [UInt8], modeOn: Bool) -> Int? {
    guard let s = makeFixtureSession() else { return nil }
    defer { laban_session_destroy(s) }
    if modeOn { writeBytes(s, Array("\u{1b}[?2027h".utf8)) }
    writeBytes(s, bytes)
    writeBytes(s, Array("\u{1b}[6n".utf8))
    let reply = drainResponse(s)
    guard let str = String(bytes: reply, encoding: .utf8),
      str.hasPrefix("\u{1b}["), str.hasSuffix("R")
    else { return nil }
    let mid = str.dropFirst(2).dropLast()
    let parts = mid.split(separator: ";")
    guard parts.count == 2, let col = Int(parts[1]) else { return nil }
    return col
  }

  private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
  }

  // MARK: - Conformance assertions

  func testGridLayoutAndAdvance_modeOFF() {
    for c in cases {
      guard let s = makeFixtureSession() else {
        XCTFail("create session for \(c.name)")
        continue
      }
      writeBytes(s, c.bytes)  // mode OFF (default)
      guard let r = occupiedRow0(s) else {
        XCTFail("snapshot for \(c.name)")
        laban_session_destroy(s)
        continue
      }
      laban_session_destroy(s)

      let layout = r.cells.map { Wide(rawValue: $0.wide) }
      print(
        "M2 OFF \(c.name): cursor_col=\(r.cursorCol) "
          + "layout=\(layout.map { $0?.description ?? "?(\($0.debugDescription))" })")

      XCTAssertEqual(
        r.cells.map { $0.wide }, c.offLayout.map { $0.rawValue },
        "OFF \(c.name): wide layout must match measured baseline")
      XCTAssertEqual(
        r.cursorCol, c.offAdvance,
        "OFF \(c.name): cursor must advance by the legacy width")
    }
  }

  func testGridLayoutAndAdvance_modeON() {
    for c in cases {
      guard let s = makeFixtureSession() else {
        XCTFail("create session for \(c.name)")
        continue
      }
      writeBytes(s, Array("\u{1b}[?2027h".utf8))
      writeBytes(s, c.bytes)
      guard let r = occupiedRow0(s) else {
        XCTFail("snapshot for \(c.name)")
        laban_session_destroy(s)
        continue
      }
      laban_session_destroy(s)

      let layout = r.cells.map { Wide(rawValue: $0.wide) }
      print(
        "M2 ON  \(c.name): cursor_col=\(r.cursorCol) "
          + "layout=\(layout.map { $0?.description ?? "?(\($0.debugDescription))" }) "
          + "head=[\(hex(r.cells.first?.utf8 ?? []))]")

      XCTAssertEqual(
        r.cells.map { $0.wide }, c.onLayout.map { $0.rawValue },
        "ON \(c.name): wide layout must match measured baseline")
      XCTAssertEqual(
        r.cursorCol, c.onAdvance,
        "ON \(c.name): cursor must advance by the grapheme-cluster width")

      // When the engine clusters into a single head cell, that head cell must
      // carry ALL the cluster's bytes (the renderable unit, not a split).
      if c.onLayout.first == .wide, c.onLayout.count == 2, let expectedHead = c.onHeadBytes {
        XCTAssertEqual(
          r.cells.first?.utf8, expectedHead,
          "ON \(c.name): head cell must carry the full cluster bytes")
      }
    }
  }

  /// The engine's `CSI 6n` cursor report must agree with the snapshot's
  /// `cursor_col` advance — this is the value a program negotiating mode 2027
  /// actually receives. 1-based column == advance + 1.
  func testCursorReportMatchesAdvance_bothModes() {
    for c in cases {
      let offCol = cprColumnAfter(c.bytes, modeOn: false)
      XCTAssertEqual(
        offCol, c.offAdvance + 1,
        "OFF \(c.name): CSI 6n column must be advance+1 (1-based)")
      let onCol = cprColumnAfter(c.bytes, modeOn: true)
      XCTAssertEqual(
        onCol, c.onAdvance + 1,
        "ON \(c.name): CSI 6n column must be advance+1 (1-based)")
    }
  }
}
