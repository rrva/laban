import CoreGraphics
import Foundation
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

/// Renders a captured PTY-byte stream through the actual SoftwareRenderer
/// and writes a PNG to /tmp. If the PNG reproduces the visual overlap from
/// the live app, the bug is in the renderer; if the PNG looks clean, the
/// bug is in the AppKit draw/cache layer (cgImage staleness, NSView dirty
/// rect, etc.).
///
/// Enable by setting LABAN_CAPTURE_BISECT to a .bin path.
final class CaptureRenderBisect: XCTestCase {

  func testRenderCapturedBytesToPNG() throws {
    guard let path = ProcessInfo.processInfo.environment["LABAN_CAPTURE_BISECT"],
      !path.isEmpty
    else {
      throw XCTSkip("set LABAN_CAPTURE_BISECT=/path/to/session.bin to enable")
    }
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)

    let geometries: [(rows: Int32, cols: Int32)] = [
      (38, 120),
      (40, 120),
    ]

    for geom in geometries {
      try renderToPNG(data: data, rows: geom.rows, cols: geom.cols)
    }
  }

  private func renderToPNG(data: Data, rows: Int32, cols: Int32) throws {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    guard laban_session_create(&config, size, &session) == 0, let s = session else {
      XCTFail("session_create failed")
      return
    }
    defer { laban_session_destroy(s) }

    data.withUnsafeBytes { buf in
      _ = laban_session_write(
        s, buf.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count)
    }

    var snap: UnsafeMutablePointer<LabanSnapshot>?
    XCTAssertEqual(laban_session_snapshot(s, &snap), 0)
    defer { laban_snapshot_destroy(snap) }
    let snapshot = snap!.pointee

    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let cellW = Int(cellSize.width)
    let cellH = Int(cellSize.height)
    let bitmapW = Int(cols) * cellW
    let bitmapH = Int(rows) * cellH
    let surface = BitmapSurface(width: bitmapW, height: bitmapH)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

    var cmds: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(bitmapW), height: CGFloat(bitmapH)),
        color: snapshot.default_background_rgba,
        source: .terminal)
    ]
    let producer = FrameProducer(cellWidth: cellW, cellHeight: cellH)
    cmds += producer.commands(from: UnsafePointer(snap!))

    // Dump glyph runs containing "bypass" so we can see the y assigned by the
    // producer — and any other runs at the same y, which would prove they
    // share the row.
    print("---- glyph runs containing 'bypass' (rows=\(rows), cellH=\(cellH)) ----")
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, _) = cmd, text.contains("bypass") {
        print("  bypass-run: y=\(origin.y) x=\(origin.x) text=\"\(text)\"")
      }
    }
    print("---- glyph runs sharing the y of the 'bypass' run ----")
    var bypassY: CGFloat? = nil
    for cmd in cmds {
      if case .glyphRun(let origin, let text, _, _, _) = cmd, text.contains("bypass") {
        bypassY = origin.y
        break
      }
    }
    if let by = bypassY {
      for cmd in cmds {
        if case .glyphRun(let origin, let text, _, _, _) = cmd, origin.y == by {
          print("  y=\(origin.y) x=\(origin.x) text=\"\(text)\"")
        }
      }
    }

    renderer.render(cmds)

    guard let pngData = surface.pngData else {
      XCTFail("png encode failed")
      return
    }
    let outPath = "/tmp/laban-replay-\(rows)x\(cols).png"
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("---- wrote \(outPath) (\(bitmapW)×\(bitmapH) px) ----")
  }
}
