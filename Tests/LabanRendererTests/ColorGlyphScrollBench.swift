import CoreGraphics
import Darwin
import Dispatch
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Regression bench for the color-emoji fallback path (commit bed1a2b).
///
/// Disabled in normal CI; opt in via:
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter ColorGlyphScrollBench
///
/// Drives a scrolling full-screen workload through the real `MetalRenderer`
/// and reports `render()` CPU wall-clock per frame in monochrome vs color
/// emoji mode.
///
/// The headline proof is the ASCII workload: with no emoji on screen the GPU
/// work is identical in both modes, so any `render()` wall-clock delta is
/// purely the CPU-side `commandsContainColorGlyph` pre-scan that color mode
/// runs every frame (a CoreText CTLine built per cluster, across the whole
/// screen). `ColorGlyphSupport` is net-new in bed1a2b, so the delta is 100%
/// attributable to that commit.
final class ColorGlyphScrollBench: XCTestCase {

  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  private struct Stats {
    let p50: Double
    let p95: Double
    let p99: Double
    let mean: Double
  }

  private func stats(_ samplesNs: [UInt64]) -> Stats {
    let us = samplesNs.map { Double($0) / 1000.0 }.sorted()
    func pct(_ p: Double) -> Double {
      guard !us.isEmpty else { return 0 }
      let idx = min(us.count - 1, max(0, Int((p / 100.0) * Double(us.count - 1).rounded())))
      return us[idx]
    }
    let mean = us.isEmpty ? 0 : us.reduce(0, +) / Double(us.count)
    return Stats(p50: pct(50), p95: pct(95), p99: pct(99), mean: mean)
  }

  /// Build one scrolling frame of `rows` glyph runs. When `emojiPerRow > 0`
  /// a handful of emoji clusters are sprinkled into each row.
  private func frame(
    at index: Int, cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat,
    asciiPrintable: String, emojiPerRow: Int
  ) -> [FrameCommand] {
    let emoji = ["😀", "🎉", "🚀", "🔥", "✨", "🌟"]
    var cmds: [FrameCommand] = []
    cmds.reserveCapacity(rows * 2 + 1)
    for r in 0..<rows {
      let row = index + r
      let color: UInt32 =
        (UInt32((row * 37) & 0xFF) << 24)
        | (UInt32((row * 89) & 0xFF) << 16)
        | (UInt32((row * 167) & 0xFF) << 8) | 0xFF
      let y = CGFloat(rows - 1 - r) * cellH
      cmds.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: color, source: .terminal))
      let start = row % asciiPrintable.count
      var chars = String((asciiPrintable + asciiPrintable).dropFirst(start).prefix(cols))
      if emojiPerRow > 0 {
        var scalars = Array(chars)
        let stride = max(1, cols / (emojiPerRow + 1))
        var pos = stride
        var e = row
        while pos < scalars.count {
          scalars[pos] = Character(emoji[e % emoji.count])
          e += 1
          pos += stride
        }
        chars = String(scalars)
      }
      cmds.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: chars,
          foreground: 0xFF_FF_FF_FF,
          background: color,
          attributes: [],
          source: .terminal))
    }
    cmds.append(.cursor(CGRect(x: 0, y: 0, width: cellW, height: cellH), color: 0xAD_BC_BC_FF))
    return cmds
  }

  private func measure(
    label: String, cols: Int, rows: Int, mode: EmojiRenderingMode, emojiPerRow: Int,
    fontAtlas: FontAtlas
  ) -> Stats? {
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)

    // Fresh renderer per case so it picks up the emoji mode at init regardless
    // of how the renderer caches it.
    UserDefaults.standard.register(defaults: [EmojiRenderingSettings.defaultsKey: mode.rawValue])
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("MetalRenderer.init returned nil")
      return nil
    }
    renderer.invalidateContentForThemeChange()
    renderer.resize(pixelWidth: pixelW, pixelHeight: pixelH, scale: scale)

    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()

    for i in 0..<12 {
      _ = renderer.render(
        frame(
          at: i, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
          asciiPrintable: asciiPrintable, emojiPerRow: emojiPerRow),
        damage: .full)
    }
    renderer.waitForLastFrame()

    var samples: [UInt64] = []
    samples.reserveCapacity(240)
    for i in 12..<252 {
      let cmds = frame(
        at: i, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
        asciiPrintable: asciiPrintable, emojiPerRow: emojiPerRow)
      let start = DispatchTime.now().uptimeNanoseconds
      _ = renderer.render(cmds, damage: .full)
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(end - start)
    }
    renderer.waitForLastFrame()
    return stats(samples)
  }

  func testColorGlyphScrollRegression() throws {
    guard enabled() else { return }
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let savedMode = EmojiRenderingSettings.current()
    defer { UserDefaults.standard.register(defaults: [EmojiRenderingSettings.defaultsKey: savedMode.rawValue]) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let grids: [(String, Int, Int)] = [("160x48", 160, 48), ("240x72", 240, 72)]

    print("\n=== Color-glyph scroll bench: render() CPU wall-clock (us/frame) ===")
    print("  workload        grid     mode        p50      p95      p99     mean")
    for (gridLabel, cols, rows) in grids {
      for (wlLabel, emojiPerRow) in [("ascii  ", 0), ("emoji  ", 3)] {
        var mono: Stats?
        var color: Stats?
        for mode in [EmojiRenderingMode.monochrome, .color] {
          guard
            let s = measure(
              label: wlLabel, cols: cols, rows: rows, mode: mode, emojiPerRow: emojiPerRow,
              fontAtlas: fontAtlas)
          else { continue }
          if mode == .monochrome { mono = s } else { color = s }
          print(
            String(
              format: "  %@ %@  %@  %7.1f  %7.1f  %7.1f  %7.1f",
              wlLabel, gridLabel, mode == .monochrome ? "monochrome" : "color     ",
              s.p50, s.p95, s.p99, s.mean))
        }
        if let mono, let color {
          let factor = mono.p50 > 0 ? color.p50 / mono.p50 : 0
          print(
            String(
              format: "    -> color/mono p50 = %.2fx  (delta %.1f us/frame)",
              factor, color.p50 - mono.p50))
        }
      }
    }
  }

  /// Pure-CPU `SoftwareRenderer` variant (no GPU pacing floor), so the absolute
  /// numbers are the real glyph-drawing cost. Pre-fix this path ran a CoreText
  /// CTLine per cluster in BOTH modes; post-fix color ≈ monochrome.
  private func measureSoftware(
    cols: Int, rows: Int, mode: EmojiRenderingMode, emojiPerRow: Int, fontAtlas: FontAtlas
  ) -> Stats {
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    let scale: CGFloat = 2
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    UserDefaults.standard.register(defaults: [EmojiRenderingSettings.defaultsKey: mode.rawValue])
    let surface = BitmapSurface(width: pixelW, height: pixelH, scale: scale)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
    let asciiPrintable = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()

    for i in 0..<12 {
      renderer.render(
        frame(
          at: i, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
          asciiPrintable: asciiPrintable, emojiPerRow: emojiPerRow))
    }
    var samples: [UInt64] = []
    samples.reserveCapacity(240)
    for i in 12..<252 {
      let cmds = frame(
        at: i, cols: cols, rows: rows, cellW: cellW, cellH: cellH,
        asciiPrintable: asciiPrintable, emojiPerRow: emojiPerRow)
      let start = DispatchTime.now().uptimeNanoseconds
      renderer.render(cmds)
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(end - start)
    }
    return stats(samples)
  }

  func testSoftwareColorGlyphScrollRegression() throws {
    guard enabled() else { return }
    let savedMode = EmojiRenderingSettings.current()
    defer { UserDefaults.standard.register(defaults: [EmojiRenderingSettings.defaultsKey: savedMode.rawValue]) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let grids: [(String, Int, Int)] = [("160x48", 160, 48), ("240x72", 240, 72)]

    print("\n=== SoftwareRenderer color-glyph scroll bench: render() CPU (us/frame) ===")
    print("  workload        grid     mode        p50      p95      p99     mean")
    for (gridLabel, cols, rows) in grids {
      for (wlLabel, emojiPerRow) in [("ascii  ", 0), ("emoji  ", 3)] {
        var mono: Stats?
        var color: Stats?
        for mode in [EmojiRenderingMode.monochrome, .color] {
          let s = measureSoftware(
            cols: cols, rows: rows, mode: mode, emojiPerRow: emojiPerRow, fontAtlas: fontAtlas)
          if mode == .monochrome { mono = s } else { color = s }
          print(
            String(
              format: "  %@ %@  %@  %7.1f  %7.1f  %7.1f  %7.1f",
              wlLabel, gridLabel, mode == .monochrome ? "monochrome" : "color     ",
              s.p50, s.p95, s.p99, s.mean))
        }
        if let mono, let color {
          let factor = mono.p50 > 0 ? color.p50 / mono.p50 : 0
          print(
            String(
              format: "    -> color/mono p50 = %.2fx  (delta %.1f us/frame)",
              factor, color.p50 - mono.p50))
        }
      }
    }
  }
}
