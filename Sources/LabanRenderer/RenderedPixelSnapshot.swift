import CoreGraphics
import Foundation
import Metal

/// One rendered frame's pixels, already copied off the GPU, with the expensive
/// encode still to come.
///
/// `pngData` on every GPU backend used to do four things inside one synchronous
/// accessor: wait for the GPU to finish the frame, copy the whole surface to the
/// CPU, wrap it in a `CGImage`, and deflate a PNG. Per-frame capture calls that
/// accessor from the frame loop, so a full-surface libpng deflate ran on the
/// main thread for every captured frame — main-thread stalls of hundreds of
/// milliseconds, recorded by the stall watchdog as
/// `advanceFrame → pngData → waitUntilCompleted`.
///
/// Splitting the accessor lets a caller pay only the half that has to happen
/// inline — the copy, which must complete before the next frame overwrites the
/// target texture — and move the encode to a background queue.
public struct RenderedPixelSnapshot: Sendable {
  public let width: Int
  public let height: Int
  public let bytesPerRow: Int
  /// Premultiplied-first BGRA8, sRGB-encoded, row 0 = the top scanline.
  public let pixels: Data

  public init(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.pixels = pixels
  }

  /// Encode the frame as PNG bytes. Pure CPU work touching no Metal object, so
  /// it is safe on any thread and is the half worth moving off the main one.
  public func encodePNG() -> Data? {
    let bitmapInfo =
      CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    // Tag sRGB: every backend's readback surface is sRGB-encoded (an
    // `bgra8Unorm_srgb` layer for the vector and slug paths, encoded-sRGB
    // compositing into `bgra8Unorm` for the classic path). A deviceRGB tag
    // mis-tags the bytes as display-native and oversaturates the PNG on
    // wide-gamut panels.
    guard let provider = CGDataProvider(data: pixels as CFData),
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }

  /// Copy a Metal texture's pixels to the CPU. The caller is responsible for
  /// having waited on the GPU work that writes `texture`; this only reads.
  static func read(from texture: MTLTexture) -> RenderedPixelSnapshot? {
    let width = texture.width
    let height = texture.height
    let bytesPerRow = width * 4
    guard width > 0, height > 0 else { return nil }
    var pixels = Data(count: bytesPerRow * height)
    let copied = pixels.withUnsafeMutableBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      texture.getBytes(
        base,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0)
      return true
    }
    guard copied else { return nil }
    return RenderedPixelSnapshot(
      width: width, height: height, bytesPerRow: bytesPerRow, pixels: pixels)
  }
}
