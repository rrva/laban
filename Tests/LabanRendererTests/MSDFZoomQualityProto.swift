import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

/// M3b-1 feasibility prototype for `execplans/active/vector-zoom-smoothness.md`.
///
/// The gesture-time zoom path (chosen after M3a) bakes a distance-field atlas
/// ONCE at gesture start, then samples + scales it per frame to stay crisp
/// through the slide. The load-bearing unknown is QUALITY: signed-distance-field
/// text is known to degrade on thin strokes and at small sizes — exactly what a
/// terminal renders. Before building any GPU MSDF subsystem, this prototype
/// answers, on the CPU and headlessly:
///
///   If we bake an SDF at a single source size and reconstruct anti-aliased
///   coverage from it at every zoom size in 8…40 pt, how far does that coverage
///   drift from the supersampled winding-number oracle (the ground truth the
///   current renderer matches)?
///
/// A single-channel SDF (not yet multi-channel MSDF) is the conservative first
/// probe: if even true MSDF can't beat single-channel here, the idea is out; if
/// single-channel is already close except at sharp corners, MSDF's corner
/// channels are the known, bounded improvement. The metric is mean absolute
/// coverage error vs the oracle, per size, over printable ASCII.
///
/// Opt in (off in normal CI; it is a measurement, not a gate):
///   LABAN_RUN_PERF_BENCH=1 swift test --filter MSDFZoomQualityProto
final class MSDFZoomQualityProto: XCTestCase {
  private func enabled() -> Bool {
    ProcessInfo.processInfo.environment["LABAN_RUN_PERF_BENCH"] == "1"
  }

  func testSDFReconstructionQualityAcrossZoomRange() throws {
    guard enabled() else { return }

    // Bake the SDF from one source size (the gesture-start size). Use the glyph
    // outline in em-space; SDF distances are size-independent up to a scale.
    let sourcePt: CGFloat = 32  // bake near the top so down-scaling dominates
    let store = GlyphCurveStore()
    let font = CTFontCreateWithName("Menlo" as CFString, sourcePt, nil)

    // Zoom sizes to probe: small (thin-stroke risk) through large.
    let probeSizes: [CGFloat] = [8, 9, 10, 11, 12, 14, 18, 24, 32, 40]
    // SDF atlas resolution per glyph cell (device px at source size). The atlas
    // texel pitch sets the distance quantization; a real bake would size this to
    // the source cell. Use the source-size ink box padded for the SDF spread.
    let sdfSpreadPx: Double = 4  // distance range encoded, in source px

    print("\n=== SDF zoom-reconstruction quality vs supersampled oracle ===")
    print("  source bake \(sourcePt) pt, Menlo, printable ASCII")
    print("  size   meanAbsCovErr   p95AbsCovErr   maxAbsCovErr   glyphs")

    var worstMean = 0.0
    for pt in probeSizes {
      var sumMean = 0.0
      var allErrs: [Double] = []
      var maxErr = 0.0
      var glyphs = 0

      for value in 0x21...0x7E {
        guard let scalar = Unicode.Scalar(value),
          let glyph = glyph(for: scalar, font: font),
          let outline = store.outline(for: glyph, font: font)
        else { continue }

        // Cell box at the probe size (scale outline source->probe).
        let s = Double(pt / sourcePt)
        let scaled = outline.applying(CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
        let w = max(2, Int((scaled.bounds.width).rounded(.up)) + 2)
        let h = max(2, Int((scaled.bounds.height).rounded(.up)) + 2)
        if w * h > 64 * 64 { continue }  // skip pathological boxes for the proto

        // Ground truth: 4x4 supersampled coverage at the probe size.
        let oracle = GlyphCurveCPUOracle.rasterizeCoverage(
          outline: scaled, width: w, height: h, samplesPerAxis: 4
        ) { x, y, fx, fy in
          CGPoint(
            x: scaled.bounds.minX + (Double(x) + fx) - 1,
            y: scaled.bounds.minY + (Double(y) + fy) - 1)
        }

        // SDF path: sample a signed distance field (built at source size,
        // distances scaled to probe) and reconstruct AA coverage analytically.
        let recon = sdfReconstructedCoverage(
          outline: scaled, width: w, height: h,
          spreadPx: sdfSpreadPx * s, originInset: 1)

        for i in 0..<(w * h) {
          let e = abs(oracle[i] - recon[i])
          allErrs.append(e)
          maxErr = max(maxErr, e)
        }
        sumMean += allErrs.suffix(w * h).reduce(0, +) / Double(w * h)
        glyphs += 1
      }

      let meanErr = glyphs > 0 ? sumMean / Double(glyphs) : 0
      allErrs.sort()
      let p95Index = min(allErrs.count - 1, Int(Double(allErrs.count) * 0.95))
      let p95 = allErrs.isEmpty ? 0 : allErrs[p95Index]
      worstMean = max(worstMean, meanErr)
      print(
        String(
          format: "  %4.0f   %12.4f   %12.4f   %12.4f   %6d",
          Double(pt), meanErr, p95, maxErr, glyphs))
    }

    print(String(format: "  worst per-size mean abs coverage error = %.4f", worstMean))
    print("  (reference: oracle coverage is in [0,1]; <0.02 mean is visually clean,")
    print("   0.02-0.05 acceptable, >0.05 indicates SDF degradation -> MSDF needed)")
  }

  /// Build a single-channel signed distance field for the outline (sampled at
  /// texel centers over the box) and reconstruct anti-aliased coverage from it
  /// the way a shader would: coverage = clamp(0.5 - distance/texelPitch, 0, 1).
  /// Distance is the true Euclidean distance to the nearest curve point, signed
  /// by the winding sign (inside positive).
  private func sdfReconstructedCoverage(
    outline: GlyphCurveOutline, width: Int, height: Int,
    spreadPx: Double, originInset: Double
  ) -> [Double] {
    var out = [Double](repeating: 0, count: width * height)
    for y in 0..<height {
      for x in 0..<width {
        let p = CGPoint(
          x: outline.bounds.minX + Double(x) + 0.5 - originInset,
          y: outline.bounds.minY + Double(y) + 0.5 - originInset)
        let dist = signedDistance(to: outline, from: p)
        // Reconstruct coverage with a 1-texel-wide analytic edge.
        out[y * width + x] = min(max(0.5 + dist, 0), 1)
      }
    }
    return out
  }

  /// Signed Euclidean distance to the outline (positive inside). Brute force
  /// over flattened quadratics — fine for a CPU proto over ~one cell.
  private func signedDistance(to outline: GlyphCurveOutline, from p: CGPoint) -> Double {
    var minDist = Double.greatestFiniteMagnitude
    for curve in outline.curves {
      let d = distanceToQuadratic(p: p, c: curve)
      minDist = min(minDist, d)
    }
    let inside = abs(GlyphCurveCPUOracle.windingNumber(at: p, in: outline)) > 0
    return inside ? minDist : -minDist
  }

  private func distanceToQuadratic(p: CGPoint, c: GlyphQuadraticCurve, steps: Int = 16) -> Double {
    var best = Double.greatestFiniteMagnitude
    var prev = c.p0
    for i in 1...steps {
      let t = Double(i) / Double(steps)
      let omt = 1 - t
      let pt = CGPoint(
        x: omt * omt * c.p0.x + 2 * omt * t * c.p1.x + t * t * c.p2.x,
        y: omt * omt * c.p0.y + 2 * omt * t * c.p1.y + t * t * c.p2.y)
      best = min(best, distancePointToSegment(p: p, a: prev, b: pt))
      prev = pt
    }
    return best
  }

  private func distancePointToSegment(p: CGPoint, a: CGPoint, b: CGPoint) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let len2 = Double(dx * dx + dy * dy)
    if len2 <= 1e-12 { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
    var t = Double((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
    t = max(0, min(1, t))
    let projX = Double(a.x) + t * Double(dx)
    let projY = Double(a.y) + t * Double(dy)
    return hypot(Double(p.x) - projX, Double(p.y) - projY)
  }

  private func glyph(for scalar: Unicode.Scalar, font: CTFont) -> CGGlyph? {
    var chars = Array(String(scalar).utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    let ok = CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count)
    return ok ? glyphs.first : nil
  }
}
