import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

/// M4 gate: sub-pixel-offset glyph caching. A glyph cached for a fractional
/// on-screen position must rasterize at that *phase* (the sample grid biased by
/// the fraction), and distinct quantized phases must be distinct cache entries.
///
/// The production accumulate kernel is driven at several fractional phases and
/// compared against the supersampled CPU oracle with the *same* phase folded
/// into its sample grid: the two must agree (this is the OSOR per-phase raster).
/// A kernel that ignored `subpixelOffset` would disagree grossly at any non-zero
/// phase (a half-pixel mask/oracle mismatch along every stem edge).
final class VectorGlyphPhaseSweepTests: XCTestCase {
  private let curveStore = GlyphCurveStore()

  private let probes: [Character] = ["H", "l", "o", "8", "/", "N"]
  private let pointSizes: [CGFloat] = [16, 20, 24]
  // Device-pixel fractions: axis-x, axis-y, both, and OSOR's thirds.
  private let phases: [CGPoint] = [
    CGPoint(x: 0, y: 0),
    CGPoint(x: 0.25, y: 0),
    CGPoint(x: 0, y: 0.25),
    CGPoint(x: 0.5, y: 0.5),
    CGPoint(x: 1.0 / 3.0, y: 2.0 / 3.0),
  ]

  func testAccumulateMatchesSupersampledOracleAcrossPhases() throws {
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
        guard let glyph = glyph(for: probe, font: font),
          let outline = curveStore.outline(for: glyph, font: font)
        else { continue }

        let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))

        for phase in phases {
          guard
            let resolved = accumulateResolved(
              device: device, queue: queue, rasterizer: rasterizer,
              outline: outline, width: width, height: height, origin: origin,
              scale: scale, subpixelOffset: phase)
          else {
            failures.append("\(probe) @\(Int(pointSize))pt phase\(fmt(phase)): accumulate failed")
            continue
          }

          let cpu = GlyphCurveCPUOracle.rasterizeCoverage(
            outline: outline, width: width, height: height, samplesPerAxis: 8
          ) { x, y, fx, fy in
            CGPoint(
              x: Double(origin.x) + (Double(x) + Double(phase.x) + fx) / Double(scale),
              y: Double(origin.y) + (Double(height - 1 - y) + Double(phase.y) + fy) / Double(scale))
          }

          var maxDelta = 0
          var grossPixels = 0
          for index in 0..<(width * height) {
            let delta = abs(Int(resolved[index]) - Int((cpu[index] * 255).rounded()))
            maxDelta = max(maxDelta, delta)
            if delta > 80 { grossPixels += 1 }
          }
          if grossPixels > 1 {
            failures.append(
              "\(probe) @\(Int(pointSize))pt phase\(fmt(phase)): \(grossPixels) gross px "
                + "(maxΔ \(maxDelta)) [\(width)x\(height)]")
          }
        }
      }
    }

    if !failures.isEmpty {
      XCTFail(
        "Phased accumulate disagrees with oracle on \(failures.count) cases:\n"
          + failures.prefix(60).joined(separator: "\n"))
    }
  }

  /// Two distinct quantized phases of the same glyph must produce *different*
  /// masks (the phase actually moves coverage) — not a snapped/identical bitmap.
  func testDistinctPhasesProduceDistinctMasks() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
      let rasterizer = VectorGlyphScratchRasterizer(device: device),
      let queue = device.makeCommandQueue()
    else {
      throw XCTSkip("no Metal device")
    }

    let scale: CGFloat = 2
    let font = FontAtlas(pointSize: 24, fontName: nil).font
    let glyph = try XCTUnwrap(glyph(for: "H", font: font))
    let outline = try XCTUnwrap(curveStore.outline(for: glyph, font: font))
    let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
    let width = max(1, Int(ceil(bounds.width * scale)))
    let height = max(1, Int(ceil(bounds.height * scale)))
    let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))

    let maskA = try XCTUnwrap(
      accumulateResolved(
        device: device, queue: queue, rasterizer: rasterizer, outline: outline,
        width: width, height: height, origin: origin, scale: scale,
        subpixelOffset: CGPoint(x: 0, y: 0)))
    let maskB = try XCTUnwrap(
      accumulateResolved(
        device: device, queue: queue, rasterizer: rasterizer, outline: outline,
        width: width, height: height, origin: origin, scale: scale,
        subpixelOffset: CGPoint(x: 0.5, y: 0)))

    // Identical seed + sample count: at the same phase the bytes would be
    // bit-identical, so any difference here is the half-pixel phase, not noise.
    var changed = 0
    for i in 0..<(width * height) where abs(Int(maskA[i]) - Int(maskB[i])) >= 16 { changed += 1 }
    XCTAssertGreaterThan(
      changed, width,
      "a half-pixel horizontal phase must shift coverage on a stem-heavy glyph")
  }

  /// The quantized phase is part of the atlas cache identity: distinct phases
  /// reserve distinct entries; the same phase resolves to the same entry.
  func testDistinctPhasesProduceDistinctAtlasEntries() throws {
    let font = FontAtlas(pointSize: 24, fontName: nil).font
    let glyph = try XCTUnwrap(glyph(for: "H", font: font))
    let atlas = VectorGlyphMaskAtlas(width: 256, height: 256)

    func key(offsetX: Int, offsetY: Int) -> VectorGlyphMaskAtlas.Key {
      VectorGlyphMaskAtlas.Key(
        font: ObjectIdentifier(font), glyph: glyph, width: 24, height: 32,
        originX: 0, originY: 0, quantizedOffsetX: offsetX, quantizedOffsetY: offsetY)
    }

    let keyP0 = key(offsetX: 0, offsetY: 0)
    let keyPx = key(offsetX: 128, offsetY: 0)
    XCTAssertNotEqual(keyP0, keyPx, "phase is part of Key identity")

    let entry0 = try XCTUnwrap(atlas.reserve(key: keyP0, width: 24, height: 32, origin: .zero))
    let entryX = try XCTUnwrap(atlas.reserve(key: keyPx, width: 24, height: 32, origin: .zero))
    XCTAssertEqual(atlas.entryCount, 2, "distinct phases occupy distinct slots")
    XCTAssertNotEqual(entry0, entryX)
    XCTAssertFalse(entry0.x == entryX.x && entry0.y == entryX.y, "phases must not share a slot")

    // Re-reserving the same phase is idempotent (one entry, not a new slot).
    let entry0Again = try XCTUnwrap(atlas.reserve(key: keyP0, width: 24, height: 32, origin: .zero))
    XCTAssertEqual(entry0, entry0Again)
    XCTAssertEqual(atlas.entryCount, 2)
  }

  // MARK: - Helpers

  private func glyph(for character: Character, font: CTFont) -> CGGlyph? {
    guard let scalar = character.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max)
    else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else { return nil }
    return glyph
  }

  private func fmt(_ p: CGPoint) -> String {
    "(\(String(format: "%.2f", p.x)),\(String(format: "%.2f", p.y)))"
  }

  private func accumulateResolved(
    device: MTLDevice,
    queue: MTLCommandQueue,
    rasterizer: VectorGlyphScratchRasterizer,
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint,
    scale: CGFloat,
    subpixelOffset: CGPoint
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
        outline: outline, width: width, height: height, origin: origin,
        rasterScale: scale, targetX: 0, targetY: 0, sampleStart: 0, sampleCount: 512,
        seed: 0x9E37_79B9, subpixelLayout: .grayscale, subpixelOffset: subpixelOffset,
        accumTexture: accum, resolvedTexture: resolved, commandBuffer: commandBuffer)
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
