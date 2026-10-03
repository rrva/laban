import CoreGraphics
import Darwin
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Heap allocations the Slug backend makes on the render thread per frame
/// once its glyph caches are warm. A steady-state frame allocates a small,
/// fixed set of blocks (Metal command objects, signpost messages) whatever
/// the screen holds; anything that grows with the glyph count is per-glyph
/// waste in the hot path.
///
/// Debug builds allocate per glyph by themselves (unoptimized closures and
/// enum copies), so there the test only gates large, content-sized buffers.
/// The full gate, plus render-thread CPU time, runs optimized:
///   scripts/bench-slug-frame-alloc
/// `LABAN_ALLOC_SITES=1` also prints the allocating call sites.
final class SlugGlyphFrameAllocationTests: XCTestCase {
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 2
  private let warmupFrames = 8
  private let measuredFrames = 16
  private let timedFrames = 200

  func testSteadyStateFrameAllocationsDoNotScaleWithGlyphCount() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    guard ThreadAllocationCounter.isAvailable else {
      throw XCTSkip("malloc_logger hook unavailable")
    }
    let small = try measure(cols: 20, rows: 4)
    let large = try measure(cols: 160, rows: 48)
    print(
      "slug frame allocations: 80 glyphs \(small.allocations)/frame \(small.bytes) B; "
        + "7680 glyphs \(large.allocations)/frame \(large.bytes) B")
    XCTAssertEqual(
      large.largeAllocations, 0,
      "a steady-state frame allocated buffers of at least "
        + "\(ThreadAllocationCounter.largeAllocationBytes) bytes")
    #if !DEBUG
      XCTAssertLessThanOrEqual(
        large.allocations, small.allocations + 4,
        "steady-state frame allocations grew with the glyph count")
    #endif
  }

  /// Mean per-frame tally over `measuredFrames` full redraws of a warm
  /// renderer, after printing render-thread CPU time for the same frame.
  private func measure(cols: Int, rows: Int) throws -> ThreadAllocationCounter.Tally {
    let pixelW = Int(CGFloat(cols) * cellW * scale)
    let pixelH = Int(CGFloat(rows) * cellH * scale)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14),
        pixelWidth: pixelW,
        pixelHeight: pixelH,
        scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    let commands = frameCommands(cols: cols, rows: rows, pixelW: pixelW, pixelH: pixelH)
    for _ in 0..<warmupFrames {
      XCTAssertTrue(renderer.render(commands, damage: .full))
    }

    // Thread CPU time excludes the wait for GPU completion. The minimum is
    // the comparable number: the median moves with P/E-core placement.
    var cpuNanos: [UInt64] = []
    cpuNanos.reserveCapacity(timedFrames)
    for _ in 0..<timedFrames {
      let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      XCTAssertTrue(renderer.render(commands, damage: .full))
      cpuNanos.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
    }
    cpuNanos.sort()
    print(
      "slug frame \(cols)x\(rows): render-thread CPU min \(cpuNanos[0] / 1000) us, "
        + "p50 \(cpuNanos[timedFrames / 2] / 1000) us")

    if ProcessInfo.processInfo.environment["LABAN_ALLOC_SITES"] == "1" {
      let sites = ThreadAllocationCounter.callSites {
        XCTAssertTrue(renderer.render(commands, damage: .full))
      }
      print("slug frame \(cols)x\(rows) allocation sites (count, bytes, frames):")
      for site in sites.prefix(25) {
        print("  \(site.allocations)\t\(site.bytes)\t\(site.frames)")
      }
    }

    var total = ThreadAllocationCounter.Tally()
    for _ in 0..<measuredFrames {
      let tally = try XCTUnwrap(
        ThreadAllocationCounter.measure {
          XCTAssertTrue(renderer.render(commands, damage: .full))
        })
      total.allocations += tally.allocations
      total.bytes += tally.bytes
      total.largeAllocations += tally.largeAllocations
    }
    return ThreadAllocationCounter.Tally(
      allocations: total.allocations / measuredFrames,
      bytes: total.bytes / measuredFrames,
      largeAllocations: total.largeAllocations)
  }

  private func frameCommands(cols: Int, rows: Int, pixelW: Int, pixelH: Int) -> [FrameCommand] {
    let ascii = String((0x21...0x7E).map { Character(UnicodeScalar($0)!) })
    let doubled = ascii + ascii + ascii
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(pixelW) / scale, height: CGFloat(pixelH) / scale),
        color: 0x1010_10ff,
        source: .terminal)
    ]
    for row in 0..<rows {
      let from = doubled.index(doubled.startIndex, offsetBy: (row * 7) % ascii.count)
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: String(doubled[from...].prefix(cols)),
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal))
    }
    return commands
  }
}
