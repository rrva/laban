import CoreGraphics
import Foundation

// Pixel format: BGRA (byteOrder32Little | premultipliedFirst) — native macOS accelerated format.
// Memory layout per pixel: [B, G, R, A].
// pixel() returns 0xRRGGBBAA by reordering bytes; cgColorFrom() decomposes 0xRRGGBBAA correctly.
// Coordinate system: standard CoreGraphics — (0,0) at bottom-left.
// Producers must convert row→y accordingly.
public final class BitmapSurface {
  public let width: Int
  public let height: Int
  public let bytesPerRow: Int
  private let pixelData: UnsafeMutableRawPointer
  public let context: CGContext

  public init(width: Int, height: Int) {
    precondition(width > 0 && height > 0)
    self.width = width
    self.height = height
    self.bytesPerRow = width * 4
    let byteCount = height * width * 4
    pixelData = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    pixelData.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    context = CGContext(
      data: pixelData,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: bitmapInfo
    )!
  }

  deinit {
    pixelData.deallocate()
  }

  // Returns pixel at CG coordinate (x, y) as 0xRRGGBBAA.
  // CG origin is bottom-left (y=0 is the bottom row).
  // CGBitmapContext stores buffer row 0 at the TOP scanline, so
  // CG y maps to buffer row (height-1-y).
  public func pixel(x: Int, y: Int) -> UInt32? {
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    let bytes = pixelData.assumingMemoryBound(to: UInt8.self)
    let i = (height - 1 - y) * bytesPerRow + x * 4
    return (UInt32(bytes[i + 2]) << 24)  // R
      | (UInt32(bytes[i + 1]) << 16)  // G
      | (UInt32(bytes[i + 0]) << 8)  // B
      | UInt32(bytes[i + 3])  // A
  }

  public var cgImage: CGImage? {
    context.makeImage()
  }
}

// Decompose 0xRRGGBBAA into a deviceRGB CGColor.
// Using the same color space as the BitmapSurface context avoids sRGB→deviceRGB conversion
// artifacts (e.g. pure blue components being silently discarded on some configurations).
public func cgColorFrom(_ rgba: UInt32) -> CGColor {
  let components: [CGFloat] = [
    CGFloat((rgba >> 24) & 0xFF) / 255.0,
    CGFloat((rgba >> 16) & 0xFF) / 255.0,
    CGFloat((rgba >> 8) & 0xFF) / 255.0,
    CGFloat(rgba & 0xFF) / 255.0,
  ]
  return CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components)!
}
