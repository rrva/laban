import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Production Slug backend frame-time gate, plus the M0 baseline workloads for
/// `execplans/active/slug-render-loop-perf-and-aa-quality.md`.
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

  private var pixelW: Int { Int(CGFloat(cols) * cellW * scale) }
  private var pixelH: Int { Int(CGFloat(rows) * cellH * scale) }

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

  // MARK: - M0 workloads (typing, cursor-blink, new-glyph-burst)
  //
  // Each workload reports CPU-encode time (render() timed with
  // waitForFrameCompletion = false, i.e. "start of render() to just after
  // commit") and wall time (waitForFrameCompletion = true, i.e. encode + GPU).
  // Both are measured on a fresh renderer per (workload, AA mode) pair so
  // geometry-cache state starts identically for each. Before M2 lands,
  // `.partial` damage is accepted but ignored by `render()`, so these numbers
  // are the full-rebuild cost of a one-row change / cursor toggle; after M2
  // they are expected to drop materially (recorded per milestone below).

  func testSlugTypingWorkloadCPUAndWallTime() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    print("\n=== Slug typing workload (one dirty row per frame, \(timedFrames) frames) ===")
    print("  mode        cpu-encode p50/p95/p99 ms      wall p50/p95/p99 ms")
    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      let frames = typingWorkloadFrames()
      let result = try measureWorkload(layout: layout, frames: frames)
      printWorkloadRow(name: layout.name, result: result)
    }
  }

  func testSlugCursorBlinkWorkloadCPUAndWallTime() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    print("\n=== Slug cursor-blink workload (empty partial, \(timedFrames) frames) ===")
    print("  mode        cpu-encode p50/p95/p99 ms      wall p50/p95/p99 ms")
    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      let frames = cursorBlinkWorkloadFrames()
      let result = try measureWorkload(layout: layout, frames: frames)
      printWorkloadRow(name: layout.name, result: result)
    }
  }

  func testSlugNewGlyphBurstWorkloadCPUAndWallTime() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    print("\n=== Slug new-glyph-burst workload (~20 new glyphs/frame, \(timedFrames) frames) ===")
    print("  mode        cpu-encode p50/p95/p99 ms      wall p50/p95/p99 ms")
    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      let frames = newGlyphBurstWorkloadFrames()
      let result = try measureWorkload(layout: layout, frames: frames)
      printWorkloadRow(name: layout.name, result: result)
    }
  }

  // MARK: - Measurement core

  private struct BenchResult {
    var wallP50: Double
    var wallP95: Double
    var wallP99: Double
  }

  private struct WorkloadResult {
    var cpuP50: Double
    var cpuP95: Double
    var cpuP99: Double
    var wallP50: Double
    var wallP95: Double
    var wallP99: Double
  }

  private func measureWorkload(
    layout: VectorSubpixelLayout,
    frames: [(commands: [FrameCommand], damage: RenderDamage)]
  ) throws -> WorkloadResult {
    let cpuSamples = try timeRun(layout: layout, frames: frames, waitForCompletion: false)
    let wallSamples = try timeRun(layout: layout, frames: frames, waitForCompletion: true)
    return WorkloadResult(
      cpuP50: percentile(cpuSamples, 0.50),
      cpuP95: percentile(cpuSamples, 0.95),
      cpuP99: percentile(cpuSamples, 0.99),
      wallP50: percentile(wallSamples, 0.50),
      wallP95: percentile(wallSamples, 0.95),
      wallP99: percentile(wallSamples, 0.99))
  }

  /// Times one full pass over `frames` on a fresh renderer. `waitForCompletion
  /// = false` yields CPU-encode time (render() returns after commit, without
  /// blocking on the GPU); `= true` yields wall time (encode + GPU).
  private func timeRun(
    layout: VectorSubpixelLayout,
    frames: [(commands: [FrameCommand], damage: RenderDamage)],
    waitForCompletion: Bool
  ) throws -> [Double] {
    guard
      let renderer = SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: pixelW,
        pixelHeight: pixelH,
        scale: scale)
    else { throw XCTSkip("SlugGlyphRenderer unavailable") }
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(layout)
    renderer.waitForFrameCompletion = waitForCompletion
    guard let firstFrame = frames.first else { return [] }
    for _ in 0..<warmupFrames {
      _ = renderer.render(firstFrame.commands, damage: .full)
    }
    var samples: [Double] = []
    samples.reserveCapacity(frames.count)
    for frame in frames {
      let start = DispatchTime.now().uptimeNanoseconds
      _ = renderer.render(frame.commands, damage: frame.damage)
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }
    samples.sort()
    return samples
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

  private func printWorkloadRow(name: String, result: WorkloadResult) {
    print(
      String(
        format: "  %-10@  %7.3f/%7.3f/%7.3f          %7.3f/%7.3f/%7.3f",
        name as NSString,
        result.cpuP50,
        result.cpuP95,
        result.cpuP99,
        result.wallP50,
        result.wallP95,
        result.wallP99))
  }

  // MARK: - Workload frame generators

  /// Row index `row` (0 = top) to a `.partial` damage y-range in surface
  /// CG-points, y measured up from the bottom of the surface (the
  /// `RenderDamage` contract), matching `MetalFrameTimingBench`'s convention.
  private func damageForRow(_ row: Int) -> RenderDamage {
    .partial(yRanges: [DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)])
  }

  /// One full-screen frame, then `timedFrames` frames each mutating a single
  /// row (round-robin) to simulate typing at different points on screen.
  private func typingWorkloadFrames() -> [(commands: [FrameCommand], damage: RenderDamage)] {
    var text = asciiText(cols: cols, rows: rows)
    var result: [(commands: [FrameCommand], damage: RenderDamage)] = [
      (frameCommands(text: text, pixelW: pixelW, pixelH: pixelH), .full)
    ]
    for i in 0..<timedFrames {
      let row = i % rows
      text[row] = mutatedLine(original: text[row], seed: i)
      result.append((frameCommands(text: text, pixelW: pixelW, pixelH: pixelH), damageForRow(row)))
    }
    return result
  }

  /// One full-screen frame, then `timedFrames` frames with identical text but
  /// a toggling cursor rect, passed as empty `.partial` (the cursor-blink
  /// contract: "nothing changed in the grid").
  private func cursorBlinkWorkloadFrames() -> [(commands: [FrameCommand], damage: RenderDamage)] {
    let text = asciiText(cols: cols, rows: rows)
    let base = frameCommands(text: text, pixelW: pixelW, pixelH: pixelH)
    let cursorRect = CGRect(x: 0, y: 0, width: cellW, height: cellH)
    var result: [(commands: [FrameCommand], damage: RenderDamage)] = [(base, .full)]
    for i in 0..<timedFrames {
      var commands = base
      if i % 2 == 0 {
        commands.append(.cursor(cursorRect, color: 0xffff_ffff))
      }
      result.append((commands, .partial(yRanges: [])))
    }
    return result
  }

  /// One full-screen frame, then `timedFrames` frames each introducing ~20
  /// previously unseen glyphs by walking up the Unicode plane, to time the
  /// full-array geometry re-upload path (`ensureGeometryBuffersIfNeeded`).
  private func newGlyphBurstWorkloadFrames() -> [(commands: [FrameCommand], damage: RenderDamage)]
  {
    var text = asciiText(cols: cols, rows: rows)
    var result: [(commands: [FrameCommand], damage: RenderDamage)] = [
      (frameCommands(text: text, pixelW: pixelW, pixelH: pixelH), .full)
    ]
    // Start well above common CJK/emoji ranges already exercised elsewhere,
    // in a run of assigned scalars with simple glyph outlines (Latin
    // Extended Additional), to keep the burst about new-geometry cost, not
    // fallback-cascade or color-glyph cost.
    var nextScalar: UInt32 = 0x1E00
    for i in 0..<timedFrames {
      let row = i % rows
      var newGlyphs = ""
      for _ in 0..<20 {
        if let scalar = Unicode.Scalar(nextScalar) {
          newGlyphs.unicodeScalars.append(scalar)
        }
        nextScalar += 1
      }
      var line = Array(text[row])
      let replaceCount = min(newGlyphs.count, line.count)
      for (offset, ch) in newGlyphs.prefix(replaceCount).enumerated() {
        line[offset] = ch
      }
      text[row] = String(line)
      result.append((frameCommands(text: text, pixelW: pixelW, pixelH: pixelH), damageForRow(row)))
    }
    return result
  }

  private func mutatedLine(original: String, seed: Int) -> String {
    var chars = Array(original)
    guard !chars.isEmpty else { return original }
    let ascii = (0x21...0x7E).map { Character(UnicodeScalar($0)!) }
    for i in chars.indices {
      chars[i] = ascii[(i + seed) % ascii.count]
    }
    return String(chars)
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
