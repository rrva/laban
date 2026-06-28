import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

/// Sweeps point sizes and compares the GPU scratch rasterizer (Metal, 32-bit
/// float winding) against the CPU winding oracle (64-bit double) on the *same*
/// point-sample grid. The two must agree: the GPU path is the production
/// rasterizer and the oracle is ground truth. Structured disagreement on
/// straight-stroke glyphs at specific sizes is the size-dependent garbling
/// reported in the field (e.g. `/` rendering like `7`, `N` garbled), caused by
/// catastrophic cancellation in the quadratic root solve when a near-linear
/// stroke yields a tiny but non-zero quadratic coefficient.
final class VectorGlyphSizeSweepTests: XCTestCase {
  private let curveStore = GlyphCurveStore()

  // The glyphs the field report flagged, plus a few controls.
  private let probes: [Character] = [
    "/", "v", "D", "l", "U", "N", "4", "C", "K", "O", "X", "t", "H", "8", "i",
  ]
  private let pointSizes: [CGFloat] = Array(stride(from: 18.0, through: 28.0, by: 1.0))
  private let scales: [CGFloat] = [2, 1]

  func testGPUWindingMatchesOracleAcrossSizes() throws {
    guard let rasterizer = VectorGlyphScratchRasterizer() else {
      throw XCTSkip("no Metal device for scratch rasterizer")
    }

    var failures: [String] = []
    for scale in scales {
      for pointSize in pointSizes {
        let font = FontAtlas(pointSize: pointSize, fontName: nil).font
        for probe in probes {
          guard let scalar = probe.unicodeScalars.first,
            scalar.value <= UInt32(UInt16.max)
          else { continue }
          var unit = UniChar(scalar.value)
          var glyph = CGGlyph()
          guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else { continue }
          guard let outline = curveStore.outline(for: glyph, font: font) else { continue }

          // Masks are rasterized at an integer glyph origin (see maskDescriptor).
          let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
          let width = max(1, Int(ceil(bounds.width * scale)))
          let height = max(1, Int(ceil(bounds.height * scale)))
          let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))

          guard
            let gpu = rasterizer.rasterize(
              outline: outline,
              width: width,
              height: height,
              origin: origin,
              rasterScale: scale)
          else {
            failures.append("\(probe) @\(pointSize)pt x\(scale): GPU rasterize returned nil")
            continue
          }

          let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
            outline: outline,
            width: width,
            height: height,
            samplesPerAxis: 1
          ) { x, y, fx, fy in
            CGPoint(
              x: Double(origin.x) + (Double(x) + fx) / Double(scale),
              y: Double(origin.y) + (Double(height - 1 - y) + fy) / Double(scale))
          }

          var mismatched = 0
          var inkPixels = 0
          for index in 0..<(width * height) {
            let gpuOn = gpu[index] > 127
            let cpuOn = cpu[index] >= 0.5
            if gpuOn || cpuOn { inkPixels += 1 }
            if gpuOn != cpuOn { mismatched += 1 }
          }
          // Point-sampled float-vs-double can legitimately differ on a handful
          // of edge pixels (a sample landing within an ULP of a contour). The
          // garbling bug produces structured, large disagreements. Allow a
          // small absolute slack; flag anything beyond it.
          let slack = max(2, inkPixels / 50)
          if mismatched > slack {
            failures.append(
              "\(probe) @\(Int(pointSize))pt x\(Int(scale)): \(mismatched) px disagree "
                + "(ink \(inkPixels), slack \(slack)) [\(width)x\(height)]")
          }
        }
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "GPU winding disagrees with oracle on \(failures.count) cases:\n"
          + failures.prefix(60).joined(separator: "\n"))
    }
  }

  /// Exercises the *production* accumulate kernel (512 jittered samples,
  /// grayscale) and compares its converged coverage against a supersampled CPU
  /// oracle. This is the path the live app uses; the scratch path above is only
  /// used for snapshots. Large, size-dependent disagreement here is the field
  /// garbling.
  func testAccumulateKernelMatchesSupersampledOracleAcrossSizes() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
      let rasterizer = VectorGlyphScratchRasterizer(device: device),
      let queue = device.makeCommandQueue()
    else {
      throw XCTSkip("no Metal device")
    }

    var failures: [String] = []
    let scale: CGFloat = 2
    for pointSize in pointSizes {
      let font = FontAtlas(pointSize: pointSize, fontName: nil).font
      for probe in probes {
        guard let scalar = probe.unicodeScalars.first,
          scalar.value <= UInt32(UInt16.max)
        else { continue }
        var unit = UniChar(scalar.value)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else { continue }
        guard let outline = curveStore.outline(for: glyph, font: font) else { continue }

        let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))

        guard
          let resolved = accumulateResolved(
            device: device,
            queue: queue,
            rasterizer: rasterizer,
            outline: outline,
            width: width,
            height: height,
            origin: origin,
            scale: scale)
        else {
          failures.append("\(probe) @\(Int(pointSize))pt: accumulate failed")
          continue
        }

        let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
          outline: outline,
          width: width,
          height: height,
          samplesPerAxis: 8
        ) { x, y, fx, fy in
          CGPoint(
            x: Double(origin.x) + (Double(x) + fx) / Double(scale),
            y: Double(origin.y) + (Double(height - 1 - y) + fy) / Double(scale))
        }

        var maxDelta = 0
        var grossPixels = 0
        for index in 0..<(width * height) {
          let gpu = Int(resolved[index])
          let ref = Int((cpu[index] * 255).rounded())
          let delta = abs(gpu - ref)
          maxDelta = max(maxDelta, delta)
          if delta > 80 { grossPixels += 1 }
        }
        // Jittered 512-sample vs 64-sample oracle differ by AA noise (small).
        // Gross (>80/255) disagreements mean a stroke is structurally wrong.
        if grossPixels > 1 {
          failures.append(
            "\(probe) @\(Int(pointSize))pt: \(grossPixels) gross px (maxΔ \(maxDelta)) "
              + "[\(width)x\(height)]")
        }
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "Accumulate kernel garbles \(failures.count) cases:\n"
          + failures.prefix(60).joined(separator: "\n"))
    }
  }

  private func accumulateResolved(
    device: MTLDevice,
    queue: MTLCommandQueue,
    rasterizer: VectorGlyphScratchRasterizer,
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint,
    scale: CGFloat
  ) -> [UInt8]? {
    let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba32Uint, width: width, height: height, mipmapped: false)
    accumDesc.usage = [.shaderRead, .shaderWrite]
    accumDesc.storageMode = .shared
    let resolvedDesc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    resolvedDesc.usage = [.shaderRead, .shaderWrite]
    resolvedDesc.storageMode = .shared
    guard let accum = device.makeTexture(descriptor: accumDesc),
      let resolved = device.makeTexture(descriptor: resolvedDesc),
      let commandBuffer = queue.makeCommandBuffer()
    else { return nil }
    guard
      rasterizer.encodeAccumulate(
        outline: outline,
        width: width,
        height: height,
        origin: origin,
        rasterScale: scale,
        targetX: 0,
        targetY: 0,
        sampleStart: 0,
        sampleCount: 512,
        seed: 0x9E37_79B9,
        subpixelLayout: .grayscale,
        accumTexture: accum,
        resolvedTexture: resolved,
        commandBuffer: commandBuffer)
    else { return nil }
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.error == nil else { return nil }
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    rgba.withUnsafeMutableBytes { raw in
      guard let base = raw.baseAddress else { return }
      resolved.getBytes(
        base, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }
    var coverage = [UInt8](repeating: 0, count: width * height)
    for i in 0..<(width * height) { coverage[i] = rgba[i * 4] }
    return coverage
  }
}
