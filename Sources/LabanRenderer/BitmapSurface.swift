import CoreGraphics
import Foundation

// Pixel format: BGRA (byteOrder32Little | premultipliedFirst) — native macOS accelerated format.
// Memory layout per pixel: [B, G, R, A].
// pixel() returns 0xRRGGBBAA by reordering bytes; cgColorFrom() decomposes 0xRRGGBBAA correctly.
// Coordinate system: standard CoreGraphics — (0,0) at bottom-left.
// Producers must convert row→y accordingly.
public final class BitmapSurface {
  private struct Layout {
    var width: Int
    var height: Int
    var bytesPerRow: Int
    var byteCount: Int
  }

  public let width: Int
  public let height: Int
  public let scale: CGFloat
  public let bytesPerRow: Int
  private let pixelData: UnsafeMutableRawPointer
  public let context: CGContext

  public var logicalWidth: CGFloat { CGFloat(width) / scale }
  public var logicalHeight: CGFloat { CGFloat(height) / scale }
  public var logicalSize: CGSize { CGSize(width: logicalWidth, height: logicalHeight) }

  public init(width: Int, height: Int, scale: CGFloat = 1) {
    precondition(scale.isFinite && scale > 0)
    let layout = Self.validLayout(width: width, height: height) ?? Self.fallbackLayout
    let storage = Self.makeStorage(layout: layout) ?? Self.makeFallbackStorage()

    self.width = storage.layout.width
    self.height = storage.layout.height
    self.scale = scale
    self.bytesPerRow = storage.layout.bytesPerRow
    pixelData = storage.pixelData
    context = storage.context
  }

  private static var fallbackLayout: Layout {
    Layout(width: 1, height: 1, bytesPerRow: 4, byteCount: 4)
  }

  private static func validLayout(width: Int, height: Int) -> Layout? {
    guard width > 0, height > 0 else { return nil }
    let row = width.multipliedReportingOverflow(by: 4)
    guard !row.overflow else { return nil }
    let bytes = row.partialValue.multipliedReportingOverflow(by: height)
    guard !bytes.overflow else { return nil }
    return Layout(
      width: width,
      height: height,
      bytesPerRow: row.partialValue,
      byteCount: bytes.partialValue)
  }

  private static func makeStorage(layout: Layout) -> (
    layout: Layout,
    pixelData: UnsafeMutableRawPointer,
    context: CGContext
  )? {
    let pixelData = UnsafeMutableRawPointer.allocate(byteCount: layout.byteCount, alignment: 64)
    pixelData.initializeMemory(as: UInt8.self, repeating: 0, count: layout.byteCount)
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard
      let context = CGContext(
        data: pixelData,
        width: layout.width,
        height: layout.height,
        bitsPerComponent: 8,
        bytesPerRow: layout.bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      )
    else {
      pixelData.deallocate()
      return nil
    }
    return (layout, pixelData, context)
  }

  private static func makeFallbackStorage() -> (
    layout: Layout,
    pixelData: UnsafeMutableRawPointer,
    context: CGContext
  ) {
    let layout = fallbackLayout
    guard let storage = makeStorage(layout: layout) else {
      fatalError("BitmapSurface could not create fallback 1x1 CGContext")
    }
    return storage
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
  guard let color = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: components)
  else {
    assertionFailure("BitmapSurface could not create device RGB color")
    return CGColor(gray: 0, alpha: components[3])
  }
  return color
}
