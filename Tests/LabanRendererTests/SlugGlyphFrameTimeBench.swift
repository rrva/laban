import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Production Slug backend frame-time gate.
///
/// Opt in (off in normal CI):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter SlugGlyphFrameTimeBench
final class SlugGlyphFrameTimeBench: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private let cols = 160
  private let rows = 48
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 2
  private let timedFrames = 200
  private let warmupFrames = 40

  func testSlugRendererFrameTimeFullScreenIs120HzFlatAcrossPointSize() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let text = asciiText(cols: cols, rows: rows)
    let budget = 1000.0 / 120.0

    print("\n=== Slug glyph renderer frame-time ===")
    print("  PRODUCTION BACKEND")
    print("  grid \(cols)x\(rows) @ scale \(scale)  (\(pixelW)x\(pixelH) px)")
    print("  \(timedFrames) timed frames, render waits for GPU completion")
    print("  size   glyphs  wall p50/p95/p99 ms      verdict")

    var results: [(pointSize: CGFloat, result: BenchResult)] = []
    for pointSize in [CGFloat(9), CGFloat(14), CGFloat(28)] {
      let renderer = try XCTUnwrap(
        SlugGlyphRenderer(
          fontAtlas: FontAtlas(pointSize: pointSize),
          pixelWidth: pixelW,
          pixelHeight: pixelH,
          scale: scale))
      renderer.waitForFrameCompletion = true
      renderer.presentsToLayer = false
      let commands = frameCommands(text: text, pixelW: pixelW, pixelH: pixelH)
      let result = try timeFrames(renderer: renderer, commands: commands)
      printRow(pointSize: pointSize, glyphs: cols * rows, result: result, budget: budget)
      XCTAssertLessThanOrEqual(result.wallP99, budget)
      results.append((pointSize, result))
    }

    let p50At9 = try XCTUnwrap(results.first { $0.pointSize == 9 }?.result.wallP50)
    let p50At28 = try XCTUnwrap(results.first { $0.pointSize == 28 }?.result.wallP50)
    XCTAssertLessThanOrEqual(
      p50At28,
      p50At9 * 1.5,
      "Slug point-size cost should stay roughly flat; 28 pt p50 \(p50At28) vs 9 pt \(p50At9)")
    print(String(format: "  budget @120Hz = %.2f ms (verdict uses wall p99)", budget))
  }

  func testSlugRendererCJKFrameTimeFullScreenIsMeasured() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let budget = 1000.0 / 120.0
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: pixelW,
        pixelHeight: pixelH,
        scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let commands = frameCommands(
      text: cjkText(cols: cols, rows: rows), pixelW: pixelW, pixelH: pixelH)
    let result = try timeFrames(renderer: renderer, commands: commands)

    print("\n=== Slug glyph renderer CJK frame-time ===")
    print("  PRODUCTION BACKEND")
    print("  grid \(cols)x\(rows) @ scale \(scale)  (\(pixelW)x\(pixelH) px)")
    print("  \(timedFrames) timed frames, render waits for GPU completion")
    printRow(pointSize: 14, glyphs: cols * rows, result: result, budget: budget)
    print(String(format: "  budget @120Hz = %.2f ms (measurement only)", budget))
    XCTAssertGreaterThan(result.wallP99, 0)
  }

  private struct BenchResult {
    var wallP50: Double
    var wallP95: Double
    var wallP99: Double
  }

  private func timeFrames(
    renderer: SlugGlyphRenderer,
    commands: [FrameCommand]
  ) throws -> BenchResult {
    for _ in 0..<warmupFrames {
      XCTAssertTrue(renderer.render(commands, damage: .full))
    }

    var wall: [Double] = []
    wall.reserveCapacity(timedFrames)
    for _ in 0..<timedFrames {
      let start = DispatchTime.now().uptimeNanoseconds
      XCTAssertTrue(renderer.render(commands, damage: .full))
      let end = DispatchTime.now().uptimeNanoseconds
      wall.append(Double(end - start) / 1_000_000)
    }
    wall.sort()
    return BenchResult(
      wallP50: percentile(wall, 0.50),
      wallP95: percentile(wall, 0.95),
      wallP99: percentile(wall, 0.99))
  }

  private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded()) - 1))
    return sorted[idx]
  }

  private func printRow(
    pointSize: CGFloat,
    glyphs: Int,
    result: BenchResult,
    budget: Double
  ) {
    let verdict = result.wallP99 <= budget ? "PASS" : "OVER"
    print(
      String(
        format: "  %5.1f  %6d    %7.3f/%7.3f/%7.3f   %@",
        Double(pointSize),
        glyphs,
        result.wallP50,
        result.wallP95,
        result.wallP99,
        verdict as NSString))
  }

  private func asciiText(cols: Int, rows: Int) -> [String] {
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let doubled = ascii + ascii + ascii
    var lines: [String] = []
    lines.reserveCapacity(rows)
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      lines.append(String(doubled[from...].prefix(cols)))
    }
    return lines
  }

  private func cjkText(cols: Int, rows: Int) -> [String] {
    let cjk = "漢字かなカナ한글中文終端表示測試"
    let doubled = String(repeating: cjk, count: (cols / cjk.count) + 3)
    var lines: [String] = []
    lines.reserveCapacity(rows)
    for row in 0..<rows {
      let start = (row * 3) % cjk.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      lines.append(String(doubled[from...].prefix(cols)))
    }
    return lines
  }

  private func frameCommands(text: [String], pixelW: Int, pixelH: Int) -> [FrameCommand] {
    var commands: [FrameCommand] = [
      .rect(
        CGRect(
          x: 0,
          y: 0,
          width: CGFloat(pixelW) / scale,
          height: CGFloat(pixelH) / scale),
        color: 0x1010_10ff,
        source: .terminal)
    ]
    commands.reserveCapacity(text.count + 1)
    for (row, line) in text.enumerated() {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal))
    }
    return commands
  }
}
