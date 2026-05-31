import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

/// Isolates the per-frame glyph-atlas lookup cost. `buildInstanceLists` calls
/// `MetalGlyphAtlas.entry(character:)` once per glyph per frame; after warmup
/// every call is a cache hit, so this measures pure lookup. A/B compares the
/// scalar-integer key (fast path) against the String key in one release binary
/// via `MetalGlyphAtlas.useScalarFastPath`.
///
/// Opt in (release only — debug doesn't specialise generics/hashing):
///   LABAN_RUN_PERF_BENCH=1 swift test -c release --filter MetalGlyphAtlasLookupBench
final class MetalGlyphAtlasLookupBench: XCTestCase {

  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  func testScalarKeyVsStringKeyLookup() throws {
    guard enabled() else { return }
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let fontAtlas = FontAtlas(pointSize: 14)
    let cell = fontAtlas.cellSize
    guard
      let atlas = MetalGlyphAtlas(
        device: device, cellWidth: cell.width, cellHeight: cell.height,
        descent: fontAtlas.descent, scale: 2)
    else {
      XCTFail("MetalGlyphAtlas.init returned nil")
      return
    }
    let font = fontAtlas.font

    // A representative screen: ASCII printable cycled across a 160x48 grid
    // (7,680 glyph lookups, the dominant terminal workload).
    let printable: [Character] = (0x20...0x7E).compactMap {
      Unicode.Scalar($0).map(Character.init)
    }
    let cols = 160
    let rows = 48
    var screen: [Character] = []
    screen.reserveCapacity(cols * rows)
    for i in 0..<(cols * rows) { screen.append(printable[i % printable.count]) }

    // Populate both caches so the measured loop is pure cache hits.
    for useFast in [true, false] {
      MetalGlyphAtlas.useScalarFastPath = useFast
      for ch in screen {
        _ = atlas.entry(
          character: ch, font: font, boldFallback: false, italicFallback: false)
      }
    }

    func bench(_ label: String, useFast: Bool, iters: Int) -> Double {
      MetalGlyphAtlas.useScalarFastPath = useFast
      for _ in 0..<3 {
        for ch in screen {
          _ = atlas.entry(
            character: ch, font: font, boldFallback: false, italicFallback: false)
        }
      }
      var samples: [Double] = []
      for _ in 0..<iters {
        let t0 = ContinuousClock.now
        for ch in screen {
          _ = atlas.entry(
            character: ch, font: font, boldFallback: false, italicFallback: false)
        }
        samples.append(Double((ContinuousClock.now - t0).components.attoseconds) / 1e15)
      }
      samples.sort()
      let p50 = samples[samples.count / 2]
      let mean = samples.reduce(0, +) / Double(samples.count)
      let perLookupNs = mean * 1e6 / Double(screen.count)
      print(
        String(
          format: "  [%@]  frame(%d lookups) mean=%.4fms p50=%.4fms => %.1f ns/lookup",
          label, screen.count, mean, p50, perLookupNs))
      return mean
    }

    let fast = bench("scalar-key (fast)", useFast: true, iters: 300)
    let base = bench("string-key (base)", useFast: false, iters: 300)
    MetalGlyphAtlas.useScalarFastPath = true
    print(String(format: "  => scalar-key is %.1f%% faster per frame", (base - fast) / base * 100))
  }
}
