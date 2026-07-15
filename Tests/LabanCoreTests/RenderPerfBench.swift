import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

// Microbench for FrameProducer + SoftwareRenderer. Disabled in normal CI; run
// explicitly via:
//   LABAN_RUN_PERF_BENCH=1 swift test --filter RenderPerfBench
//
// Numbers below were captured on Apple silicon, release-mode dependencies.
// Use them as a baseline only — no assertion.
final class RenderPerfBench: XCTestCase {

  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private func measure(label: String, iterations: Int, _ body: () -> Void) {
    // Warm up.
    for _ in 0..<3 { body() }
    var samples: [Double] = []
    for _ in 0..<iterations {
      let t0 = ContinuousClock.now
      body()
      let dt = ContinuousClock.now - t0
      samples.append(Double(dt.components.attoseconds) / 1e15)  // ms
    }
    samples.sort()
    let p50 = samples[samples.count / 2]
    let p95 = samples[Int(Double(samples.count) * 0.95)]
    let mean = samples.reduce(0, +) / Double(samples.count)
    print(
      String(
        format: "  [%@]  mean=%.3fms  p50=%.3fms  p95=%.3fms  (n=%d)",
        label, mean, p50, p95, iterations))
  }

  private func makeSession(cols: Int32, rows: Int32) throws -> Session {
    var size = LabanTerminalSize()
    size.cols = cols
    size.rows = rows
    let s = try Session.fixture(size: size)
    return s
  }

  private func feed(_ s: Session, _ payload: String) {
    s.write(Array(payload.utf8))
    s.poll()
  }

  private func textPayload(cols: Int, rows: Int) -> String {
    let body = String(repeating: "lorem ipsum dolor sit amet ", count: max(1, cols / 28))
    let line = String(body.prefix(cols))
    return "\u{1b}[H" + String(repeating: line + "\r\n", count: rows)
  }

  /// Mostly default background with a few accent runs (status bar, selection
  /// stripe). Closer to typical TUI screens (vim, htop) than the all-unique
  /// pathological colored field. Rect-batch optimisations should shine here.
  private func tuiPayload(cols: Int, rows: Int) -> String {
    var out = ["\u{1b}[H"]
    let bodyLine =
      String(repeating: "lorem ipsum dolor sit amet ", count: max(1, cols / 28))
    let body = String(bodyLine.prefix(cols))
    for r in 0..<rows {
      if r == rows - 1 {
        // Status bar: solid accent bg across the whole row.
        out.append("\u{1b}[44m" + String(repeating: " ", count: cols) + "\u{1b}[0m")
      } else if r % 4 == 0 {
        // Mid-row accent spans (mimic selection highlights / diff hunks).
        out.append("\u{1b}[42m" + String(repeating: " ", count: 20) + "\u{1b}[0m")
        out.append(String(body.dropFirst(20)))
      } else {
        out.append(body)
      }
      out.append("\r\n")
    }
    out.append("\u{1b}[0m")
    return out.joined()
  }

  private func coloredPayload(cols: Int, rows: Int) -> String {
    var out = ["\u{1b}[H"]
    for r in 0..<rows {
      for c in 0..<cols {
        let red = (r * 7 + c) & 0xFF
        let green = (c * 5 + r * 3) & 0xFF
        let blue = (r * c) & 0xFF
        let scalar = UnicodeScalar(0x21 + ((r * 31 + c) % 94))!
        out.append("\u{1b}[48;2;\(red);\(green);\(blue)m\(scalar)")
      }
      out.append("\r\n")
    }
    out.append("\u{1b}[0m")
    return out.joined()
  }

  // MARK: - FrameProducer

  func testFrameProducerColored80x24() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 80, rows: 24)
    defer { s.close() }
    feed(s, coloredPayload(cols: 80, rows: 24))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    measure(label: "FrameProducer colored 80x24", iterations: 200) {
      _ = producer.commands(from: UnsafePointer(snap))
    }
  }

  func testFrameProducerColored160x48() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, coloredPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    measure(label: "FrameProducer colored 160x48", iterations: 100) {
      _ = producer.commands(from: UnsafePointer(snap))
    }
  }

  // A/B: the legacy String-per-cell glyph pass vs the macOS 26 Span/UTF8Span
  // pass. Both emit byte-identical FrameCommands (FrameProducerSpanParityTests),
  // so this isolates the producer-side CPU win the perf change targets.
  func testFrameProducerGlyphPassLegacyVsFast() throws {
    guard enabled() else { return }
    guard #available(macOS 26, *) else {
      throw XCTSkip("Span/UTF8Span fast path requires macOS 26")
    }
    defer { FrameProducer._forceLegacyGlyphRuns = false }
    func bench(_ label: String, cols: Int32, rows: Int32, payload: String) throws {
      let s = try makeSession(cols: cols, rows: rows)
      defer { s.close() }
      feed(s, payload)
      let snap = s.snapshot()!
      defer { laban_snapshot_destroy(snap) }
      let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
      FrameProducer._forceLegacyGlyphRuns = true
      measure(label: "\(label) glyph [legacy]", iterations: 200) {
        _ = producer.commands(from: UnsafePointer(snap))
      }
      FrameProducer._forceLegacyGlyphRuns = false
      measure(label: "\(label) glyph [fast]  ", iterations: 200) {
        _ = producer.commands(from: UnsafePointer(snap))
      }
    }
    try bench("text    160x48", cols: 160, rows: 48, payload: textPayload(cols: 160, rows: 48))
    try bench("tui     160x48", cols: 160, rows: 48, payload: tuiPayload(cols: 160, rows: 48))
    try bench("colored 160x48", cols: 160, rows: 48, payload: coloredPayload(cols: 160, rows: 48))
  }

  // MARK: - Command counts (for sanity-checking what hits the renderer)

  func testCommandCountsAcrossWorkloads() throws {
    guard enabled() else { return }
    func dump(_ label: String, cols: Int32, rows: Int32, payload: String) throws {
      let s = try makeSession(cols: cols, rows: rows)
      defer { s.close() }
      feed(s, payload)
      let snap = s.snapshot()!
      defer { laban_snapshot_destroy(snap) }
      let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
      let cmds = producer.commands(from: UnsafePointer(snap))
      var rectCount = 0
      var glyphCount = 0
      var rectColors: Set<UInt32> = []
      var rectRunBoundaries = 0
      var lastRectColor: UInt32? = nil
      for cmd in cmds {
        switch cmd {
        case .rect(_, let c, _, _):
          rectCount += 1
          rectColors.insert(c)
          if c != lastRectColor { rectRunBoundaries += 1 }
          lastRectColor = c
        case .glyphRun:
          glyphCount += 1
          lastRectColor = nil
        default:
          lastRectColor = nil
        }
      }
      print(
        "  [\(label)]  rects=\(rectCount)  glyphRuns=\(glyphCount)"
          + "  uniqueColors=\(rectColors.count)  rectColorRuns=\(rectRunBoundaries)")
    }
    try dump("colored 80x24", cols: 80, rows: 24, payload: coloredPayload(cols: 80, rows: 24))
    try dump("colored 160x48", cols: 160, rows: 48, payload: coloredPayload(cols: 160, rows: 48))
    try dump("text 160x48", cols: 160, rows: 48, payload: textPayload(cols: 160, rows: 48))
    try dump("tui 160x48", cols: 160, rows: 48, payload: tuiPayload(cols: 160, rows: 48))
  }

  // MARK: - SoftwareRenderer

  func testSoftwareRendererColored80x24() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 80, rows: 24)
    defer { s.close() }
    feed(s, coloredPayload(cols: 80, rows: 24))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(width: 200 + 80 * 9, height: 24 * 19)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer colored 80x24", iterations: 100) {
      renderer.render(cmds)
    }
  }

  func testSoftwareRendererColored160x48() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, coloredPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(width: 200 + 160 * 9, height: 48 * 19)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer colored 160x48", iterations: 60) {
      renderer.render(cmds)
    }
  }

  func testSoftwareRendererTUI160x48() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, tuiPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(width: 200 + 160 * 9, height: 48 * 19)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer tui-shape 160x48", iterations: 60) {
      renderer.render(cmds)
    }
  }

  func testSoftwareRendererText160x48() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, textPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(width: 200 + 160 * 9, height: 48 * 19)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer text 160x48", iterations: 60) {
      renderer.render(cmds)
    }
  }

  func testSoftwareRendererText160x48HiDPI() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, textPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(
      width: (200 + 160 * 9) * 2, height: 48 * 19 * 2, scale: 2)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer text 160x48 @2x", iterations: 60) {
      renderer.render(cmds)
    }
  }

  func testSoftwareRendererColored160x48HiDPI() throws {
    guard enabled() else { return }
    let s = try makeSession(cols: 160, rows: 48)
    defer { s.close() }
    feed(s, coloredPayload(cols: 160, rows: 48))
    let snap = s.snapshot()!
    defer { laban_snapshot_destroy(snap) }
    let producer = FrameProducer(cellWidth: 9, cellHeight: 19, originX: 200, originY: 0)
    let cmds = producer.commands(from: UnsafePointer(snap))
    let surface = BitmapSurface(
      width: (200 + 160 * 9) * 2, height: 48 * 19 * 2, scale: 2)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas(pointSize: 14))
    measure(label: "SoftwareRenderer colored 160x48 @2x", iterations: 60) {
      renderer.render(cmds)
    }
  }

  func testCGImageRealisation160x48() throws {
    guard enabled() else { return }
    let surface = BitmapSurface(width: 200 + 160 * 9, height: 48 * 19)
    measure(label: "BitmapSurface.cgImage 160x48", iterations: 100) {
      _ = surface.cgImage
    }
  }
}
