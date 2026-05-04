import LabanTerminalCore
import XCTest

/// Ad-hoc bisect harness for the captured overlap bug. Disabled by default;
/// run with the LABAN_CAPTURE_BISECT env var set to a path:
///   LABAN_CAPTURE_BISECT=/path/to/session.bin swift test --filter testBisectCapturedBug
final class CaptureBugBisect: XCTestCase {

  func testBisectCapturedBug() throws {
    guard let path = ProcessInfo.processInfo.environment["LABAN_CAPTURE_BISECT"],
      !path.isEmpty
    else {
      throw XCTSkip("set LABAN_CAPTURE_BISECT=/path/to/session.bin to enable")
    }

    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let total = data.count

    // Try common geometries until one produces overlap. From the screenshot
    // the window looks ~120 cols × ~38 rows, but try a small spread.
    let geometries: [(rows: Int32, cols: Int32)] = [
      (38, 120),
      (40, 120),
      (44, 152),
    ]

    for geom in geometries {
      let grid = try replay(data: data, rows: geom.rows, cols: geom.cols, byteLimit: nil)
      let overlapping = rowsWithOverlap(grid)
      print("---- replay rows=\(geom.rows) cols=\(geom.cols) bytes=\(total) ----")
      print(grid)
      if !overlapping.isEmpty {
        print(">>> overlap detected at rows \(overlapping)")
      }
    }
  }

  /// Heuristic: a row has "overlap" if it contains content from two distinct
  /// UI elements, e.g. an orange-tip-like "Tip:" and another bracket of text,
  /// or a permission marker like "bypass permissions" mixed with prose. The
  /// real check is whether replay reproduces the visual symptom — print the
  /// grid and inspect.
  private func rowsWithOverlap(_ grid: String) -> [Int] {
    let lines = grid.split(separator: "\n", omittingEmptySubsequences: false)
    var hits: [Int] = []
    for (i, line) in lines.enumerated() {
      let s = String(line)
      let markers = [
        "bypass permissions",
        "Tip:",
        "shift+tab to cycle",
      ]
      let matches = markers.filter { s.contains($0) }
      // Two markers on one row, or a marker appearing mid-line with content
      // around it, is a sign of overlap.
      if matches.count >= 2 { hits.append(i) }
    }
    return hits
  }

  private func replay(data: Data, rows: Int32, cols: Int32, byteLimit: Int?) throws
    -> String
  {
    var slice = data
    if let n = byteLimit, n < slice.count { slice = slice.prefix(n) }

    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0, let s = session else {
      throw NSError(
        domain: "Bisect", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "session_create failed"])
    }
    defer { laban_session_destroy(s) }

    slice.withUnsafeBytes { buf in
      _ = laban_session_write(
        s, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), slice.count)
    }

    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(s, &snap) == 0)
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap!.pointee
    let r = Int(snapshot.rows)
    let c = Int(snapshot.cols)
    guard let cells = snapshot.cells, let storage = snapshot.utf8_storage else {
      return ""
    }
    var lines: [String] = []
    for row in 0..<r {
      var line = ""
      for col in 0..<c {
        let cell = cells[row * c + col]
        if cell.utf8_length > 0 {
          let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
          let buf = UnsafeBufferPointer<UInt8>(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: Int(cell.utf8_length))
          line += String(bytes: buf, encoding: .utf8) ?? " "
        } else {
          line += " "
        }
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n")
  }
}
