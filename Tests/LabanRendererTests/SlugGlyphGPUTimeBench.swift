import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// GPU execution time (command buffer gpuStartTime..gpuEndTime) of full Slug
/// redraws of a 1440x912 pt window at 2x, with the grid each point size fits.
/// Unlike `SlugGlyphFrameTimeBench`, it excludes CPU encode and keeps the
/// glyphs inside their cells, so it isolates the fragment shader. Opt in,
/// optimized (debug Swift does not change GPU time, but the build is slow):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphGPUTimeBench
/// The 120 Hz budget is 8.33 ms per frame.
final class SlugGlyphGPUTimeBench: XCTestCase {
  private let scale: CGFloat = 2
  private let surfacePoints = CGSize(width: 1440, height: 912)

  func testGPUTimePerPointSize() throws {
    guard ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1" else { return }
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
    print(
      "\n=== Slug GPU time, full redraw, \(Int(surfacePoints.width * scale))x\(Int(surfacePoints.height * scale)) px ==="
    )
    print("  size  layout     grid      glyphs  gpu min/p50/p95 ms")
    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      for pointSize in [CGFloat(9), 14, 28] {
        let atlas = FontAtlas(pointSize: pointSize)
        let cols = Int(surfacePoints.width / atlas.cellSize.width)
        let rows = Int(surfacePoints.height / atlas.cellSize.height)
        let r = try gpuTimes(
          pointSize: pointSize, layout: layout, cols: cols, rows: rows, cellH: atlas.cellSize.height
        )
        print(
          String(
            format: "  %4.0f  %-9@  %3dx%-3d  %6d  %6.2f/%6.2f/%6.2f",
            Double(pointSize), layout.name as NSString, cols, rows, cols * rows, r[0],
            r[r.count / 2], r[r.count * 95 / 100]))
      }
    }
  }

  private func gpuTimes(
    pointSize: CGFloat, layout: VectorSubpixelLayout, cols: Int, rows: Int, cellH: CGFloat
  ) throws -> [Double] {
    let pixelW = Int(surfacePoints.width * scale)
    let pixelH = Int(surfacePoints.height * scale)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: pointSize), pixelWidth: pixelW, pixelHeight: pixelH,
        scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(layout)
    let ascii = String((0x21...0x7E).map { Character(UnicodeScalar($0)!) })
    let doubled = ascii + ascii + ascii + ascii
    var commands: [FrameCommand] = [
      .rect(CGRect(origin: .zero, size: surfacePoints), color: 0x1010_10ff, source: .terminal)
    ]
    for row in 0..<rows {
      let from = doubled.index(doubled.startIndex, offsetBy: (row * 7) % ascii.count)
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: String(doubled[from...].prefix(cols)),
          foreground: 0xffff_ffff, background: 0, attributes: [], source: .terminal))
    }
    for _ in 0..<20 { _ = renderer.render(commands, damage: .full) }
    var times: [Double] = []
    for _ in 0..<100 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
      if let ms = renderer.lastFrameGPUMillisecondsForTesting { times.append(ms) }
    }
    return times.sorted()
  }
}

extension SlugGlyphGPUTimeBench {
  /// Writes raw BGRA readbacks of fixed frames (both AA modes, three sizes,
  /// plain/bold/italic/underline, box drawing, braille, Greek, accents) to
  /// `$LABAN_DUMP_DIR`, so a shader change that should not alter output can
  /// be compared pixel for pixel against the build before it.
  func testDumpFrames() throws {
    guard let dir = ProcessInfo.processInfo.environment["LABAN_DUMP_DIR"] else { return }
    let text = [
      "The quick brown fox jumps over 0123456789 @#$%&*()[]{}<>/\\|~^`'\";:,.!?",
      "gjpqy ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz -> => != ===",
      "┌─┬─┐ │ ├─┼─┤ ╔═╗ ░▒▓█ ⣿⠿ αβγδ λ Ωπ é ñ ü ø å",
    ]
    let attributeSets: [TextAttributes] = [[], [.bold], [.italic], [.underline]]
    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      for pointSize in [CGFloat(9), 13, 28] {
        let atlas = FontAtlas(pointSize: pointSize)
        let size = CGSize(
          width: 900, height: atlas.cellSize.height * CGFloat(text.count * attributeSets.count + 1))
        let renderer = try XCTUnwrap(
          SlugGlyphRenderer(
            fontAtlas: atlas, pixelWidth: Int(size.width * scale),
            pixelHeight: Int(size.height * scale), scale: scale))
        renderer.waitForFrameCompletion = true
        renderer.presentsToLayer = false
        renderer.setSubpixelLayout(layout)
        var commands: [FrameCommand] = [
          .rect(CGRect(origin: .zero, size: size), color: 0xf0f0_e8ff, source: .terminal)
        ]
        var row = 0
        for attributes in attributeSets {
          for line in text {
            commands.append(
              .glyphRun(
                origin: CGPoint(x: 4, y: CGFloat(row) * atlas.cellSize.height), text: line,
                foreground: row % 2 == 0 ? 0x1020_30ff : 0x8030_10ff, background: 0,
                attributes: attributes, source: .terminal))
            row += 1
          }
        }
        XCTAssertTrue(renderer.render(commands, damage: .full))
        let image = try XCTUnwrap(renderer.readbackBGRA())
        let url = URL(fileURLWithPath: dir).appendingPathComponent(
          "\(layout.name)-\(Int(pointSize))-\(image.width)x\(image.height).bgra")
        try Data(image.bytes).write(to: url)
      }
    }
  }
}
