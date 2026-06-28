import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

/// M1 gate: the vector backend must composite glyph coverage in linear light
/// (gamma-correct), not lerp in gamma-encoded space. With white-on-black, an AA
/// edge pixel of geometric coverage `c` should read `srgbEncode(c)`, not the raw
/// `c` produced by a gamma-space blend. This is checked against the math itself —
/// the classic renderer is deliberately NOT used as a reference.
final class VectorGlyphGammaTests: XCTestCase {
  private let probe = "Hglo08B/N"

  func testVectorCompositesCoverageInLinearLight() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue(),
      let rasterizer = VectorGlyphScratchRasterizer(device: device)
    else {
      throw XCTSkip("no Metal device available")
    }

    let scale: CGFloat = 2
    let atlas = FontAtlas(pointSize: 32, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 900,
        pixelHeight: 200,
        scale: scale))
    renderer.setSubpixelLayout(.grayscale)

    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 450, height: 100), color: 0x00_00_00_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 8, y: 12),
        text: probe,
        foreground: 0xFF_FF_FF_FF,
        background: 0x00_00_00_FF,
        attributes: [],
        source: .terminal),
    ]
    XCTAssertTrue(renderer.render(commands, damage: .full))
    let image = try decodeRGBA(try XCTUnwrap(renderer.pngData))

    // Output AA edge pixels (white-on-black => R==G==B == composited coverage).
    var outputPartials: [Double] = []
    for i in stride(from: 0, to: image.bytes.count, by: 4) {
      let v = Int(image.bytes[i])
      if v > 4, v < 251 { outputPartials.append(Double(v)) }
    }
    XCTAssertGreaterThan(outputPartials.count, 200, "probe must produce AA edge pixels")

    // Ground-truth AA coverage from the production accumulate path (512 samples,
    // grayscale). The scratch/maskSnapshot path is single-sample (binary) and
    // would have no partial coverage, so it cannot be used here.
    let store = GlyphCurveStore()
    var gammaExpected: [Double] = []
    var naiveExpected: [Double] = []
    for character in probe {
      guard let scalar = character.unicodeScalars.first,
        scalar.value <= UInt32(UInt16.max)
      else { continue }
      var unit = UniChar(scalar.value)
      var glyph = CGGlyph()
      guard CTFontGetGlyphsForCharacters(atlas.font, &unit, &glyph, 1), glyph != 0 else { continue }
      guard let outline = store.outline(for: glyph, font: atlas.font) else { continue }
      let bounds = outline.bounds.integral.insetBy(dx: -1, dy: -1)
      let width = max(1, Int(ceil(bounds.width * scale)))
      let height = max(1, Int(ceil(bounds.height * scale)))
      let origin = CGPoint(x: floor(bounds.minX), y: floor(bounds.minY))
      guard
        let coverage = accumulateCoverage(
          device: device, queue: queue, rasterizer: rasterizer, outline: outline,
          width: width, height: height, origin: origin, scale: scale)
      else { continue }
      // Apply the same stem-darkening the renderer uses (white-on-black at the
      // current weight) so the gate isolates gamma-correctness of compositing.
      let exponent = Double(
        VectorGlyphRenderer.coverageExponent(
          foreground: 0xFF_FF_FF_FF,
          background: 0x00_00_00_FF,
          weight: VectorTextWeightSettings.current()))
      for byte in coverage where byte > 4 && byte < 251 {
        let darkened = pow(Double(byte) / 255, exponent)
        gammaExpected.append(srgbEncode(darkened) * 255)  // linear-light composite
        naiveExpected.append(darkened * 255)  // gamma-space composite
      }
    }
    XCTAssertGreaterThan(gammaExpected.count, 200, "masks must have AA coverage")

    let meanOutput = mean(outputPartials)
    let meanGamma = mean(gammaExpected)
    let meanNaive = mean(naiveExpected)

    // sRGB encoding brightens midtones, so gamma-correct compositing yields a
    // strictly higher mean than the gamma-naive blend.
    XCTAssertGreaterThan(
      meanGamma - meanNaive, 10,
      "probe coverage should expose a meaningful gamma gap (sanity)")
    // Pre-M1 the blend was gamma-naive: meanOutput ~= meanNaive (fails here).
    // Post-M1 it composites in linear light: meanOutput ~= meanGamma (passes).
    XCTAssertGreaterThan(
      meanOutput, meanNaive + 0.5 * (meanGamma - meanNaive),
      "vector edges are not on the gamma-correct side "
        + "(output \(meanOutput), naive \(meanNaive), gamma \(meanGamma))")
    XCTAssertLessThan(
      abs(meanOutput - meanGamma), 14,
      "vector edges should match gamma-correct compositing "
        + "(output \(meanOutput), gamma \(meanGamma))")
  }

  private func accumulateCoverage(
    device: MTLDevice, queue: MTLCommandQueue, rasterizer: VectorGlyphScratchRasterizer,
    outline: GlyphCurveOutline, width: Int, height: Int, origin: CGPoint, scale: CGFloat
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
      let commandBuffer = queue.makeCommandBuffer(),
      rasterizer.encodeAccumulate(
        outline: outline, width: width, height: height, origin: origin, rasterScale: scale,
        targetX: 0, targetY: 0, sampleStart: 0, sampleCount: 512, seed: 0x9E37_79B9,
        subpixelLayout: .grayscale, accumTexture: accum, resolvedTexture: resolved,
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
    return (0..<(width * height)).map { rgba[$0 * 4] }
  }

  private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
  }

  private func srgbEncode(_ c: Double) -> Double {
    c <= 0.003_130_8 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw XCTSkip("failed to decode renderer PNG") }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }
}
