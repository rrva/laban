import CoreGraphics
import Foundation
import ImageIO

@testable import LabanRenderer

struct RendererTestSupportError: Error, CustomStringConvertible {
  var description: String
  init(_ description: String) { self.description = description }
}

struct TestRGBAImage {
  var width: Int
  var height: Int
  var bytes: [UInt8]

  func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let offset = (y * width + x) * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
  }
}

struct TestTextAAMetrics {
  var inkMass: Double
  var inkPixels: Int
  var edgePixels: Int
  var edgePixelRatio: Double
  var meanGradient: Double
  var p95Gradient: Double
  var p99Gradient: Double
  var meanEdgeChroma: Double
  var p95EdgeChroma: Double
  var meanCoverageSpread: Double
  var p95CoverageSpread: Double
  var meanMaxChannelGradient: Double
  var meanPartialLuma: Double
}

func decodePNGToRGBA(_ png: Data) throws -> TestRGBAImage {
  guard let source = CGImageSourceCreateWithData(png as CFData, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    throw RendererTestSupportError("failed to decode PNG")
  }
  let width = image.width
  let height = image.height
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  let bitmapInfo =
    CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
  bytes.withUnsafeMutableBytes { raw in
    guard
      let context = CGContext(
        data: raw.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo)
    else { return }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return TestRGBAImage(width: width, height: height, bytes: bytes)
}

func computeTextAAMetrics(
  image: TestRGBAImage,
  crop: CGRect,
  background: UInt32,
  foreground: UInt32
) -> TestTextAAMetrics {
  let bounds = clampedCrop(crop, image: image)
  let bgLum = lumaUInt8(background)
  let fgLum = lumaUInt8(foreground)
  let maxInk = max(1.0, abs(Double(bgLum) - Double(fgLum)))
  let inkDirection = bgLum > fgLum ? 1.0 : -1.0

  func inkAt(x: Int, y: Int) -> Double {
    let p = image.pixel(x: x, y: y)
    let lum = lumaPixel(p)
    return max(0, min(maxInk, (Double(bgLum) - lum) * inkDirection))
  }

  let bgR = UInt8((background >> 24) & 0xFF)
  let bgG = UInt8((background >> 16) & 0xFF)
  let bgB = UInt8((background >> 8) & 0xFF)
  let fgR = UInt8((foreground >> 24) & 0xFF)
  let fgG = UInt8((foreground >> 16) & 0xFF)
  let fgB = UInt8((foreground >> 8) & 0xFF)

  func channelCoverages(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> (
    r: Double, g: Double, b: Double
  ) {
    (
      r: channelCoverage(value: p.r, background: bgR, foreground: fgR),
      g: channelCoverage(value: p.g, background: bgG, foreground: fgG),
      b: channelCoverage(value: p.b, background: bgB, foreground: fgB)
    )
  }

  var inkMass = 0.0
  var inkPixels = 0
  var edgePixels = 0
  var gradients: [Double] = []
  var maxChannelGradients: [Double] = []
  var edgeChromas: [Double] = []
  var coverageSpreads: [Double] = []
  var partialLumas: [Double] = []

  for y in bounds.minY..<bounds.maxY {
    for x in bounds.minX..<bounds.maxX {
      let p = image.pixel(x: x, y: y)
      let ink = inkAt(x: x, y: y)
      let coverage = ink / maxInk
      inkMass += ink
      if coverage > 0.01 {
        inkPixels += 1
        partialLumas.append(Double((Int(p.r) + Int(p.g) + Int(p.b)) / 3))
        let rawChroma = max(Int(p.r), Int(p.g), Int(p.b)) - min(Int(p.r), Int(p.g), Int(p.b))
        edgeChromas.append(Double(rawChroma))
        let coverages = channelCoverages(p)
        let spread = max(coverages.r, coverages.g, coverages.b)
          - min(coverages.r, coverages.g, coverages.b)
        coverageSpreads.append(spread)
        if coverage < 0.85 {
          edgePixels += 1
        }
      }
      if x + 1 < bounds.maxX {
        let gradient = abs(ink - inkAt(x: x + 1, y: y))
        if gradient > 1 {
          gradients.append(gradient)
        }
        let rhs = image.pixel(x: x + 1, y: y)
        let lhsCoverages = channelCoverages(p)
        let rhsCoverages = channelCoverages(rhs)
        let maxChannelGradient = max(
          abs(lhsCoverages.r - rhsCoverages.r),
          abs(lhsCoverages.g - rhsCoverages.g),
          abs(lhsCoverages.b - rhsCoverages.b))
        if maxChannelGradient > 0.005 {
          maxChannelGradients.append(maxChannelGradient * 255.0)
        }
      }
    }
  }

  return TestTextAAMetrics(
    inkMass: inkMass,
    inkPixels: inkPixels,
    edgePixels: edgePixels,
    edgePixelRatio: inkPixels == 0 ? 0 : Double(edgePixels) / Double(inkPixels),
    meanGradient: mean(gradients),
    p95Gradient: percentile(gradients, 0.95),
    p99Gradient: percentile(gradients, 0.99),
    meanEdgeChroma: mean(edgeChromas),
    p95EdgeChroma: percentile(edgeChromas, 0.95),
    meanCoverageSpread: mean(coverageSpreads),
    p95CoverageSpread: percentile(coverageSpreads, 0.95),
    meanMaxChannelGradient: mean(maxChannelGradients),
    meanPartialLuma: mean(partialLumas))
}

func channelCoverage(value: UInt8, background: UInt8, foreground: UInt8) -> Double {
  let bg = Double(background)
  let fg = Double(foreground)
  let range = bg - fg
  guard abs(range) > 0.0001 else { return 0 }
  return max(0, min(1, (bg - Double(value)) / range))
}

func lumaUInt8(_ rgba: UInt32) -> Int {
  let r = (rgba >> 24) & 0xFF
  let g = (rgba >> 16) & 0xFF
  let b = (rgba >> 8) & 0xFF
  return (Int(r) + Int(g) + Int(b)) / 3
}

func lumaPixel(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Double {
  Double((Int(p.r) + Int(p.g) + Int(p.b)) / 3)
}

func clampedCrop(_ crop: CGRect, image: TestRGBAImage) -> CropBounds {
  let minX = max(0, Int(floor(crop.minX)))
  let maxX = min(image.width, Int(ceil(crop.maxX)))
  let minY = max(0, Int(floor(crop.minY)))
  let maxY = min(image.height, Int(ceil(crop.maxY)))
  return CropBounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY)
}

struct CropBounds {
  var minX: Int
  var maxX: Int
  var minY: Int
  var maxY: Int
}

func mean(_ values: [Double]) -> Double {
  values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
  guard !values.isEmpty else { return 0 }
  let sorted = values.sorted()
  let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
  return sorted[index]
}
