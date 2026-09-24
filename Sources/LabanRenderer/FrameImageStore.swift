import CoreGraphics
import Foundation

/// Straight-alpha RGBA8 pixels of one image referenced by
/// `FrameCommand.texturedQuad`.
public final class FrameImage: @unchecked Sendable {
  public let width: Int
  public let height: Int
  /// `width * height * 4` bytes, rows top to bottom, straight alpha.
  public let rgba: Data

  private let lock = NSLock()
  private var cachedCGImage: CGImage?

  public init(width: Int, height: Int, rgba: Data) {
    self.width = width
    self.height = height
    self.rgba = rgba
  }

  /// A CGImage over the pixels, built once and reused by CoreGraphics
  /// renderers.
  public var cgImage: CGImage? {
    lock.lock()
    defer { lock.unlock() }
    if let cachedCGImage { return cachedCGImage }
    guard width > 0, height > 0, rgba.count >= width * height * 4,
      let provider = CGDataProvider(data: rgba as CFData),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    cachedCGImage = image
    return image
  }
}

/// Process-wide pixels for `texturedQuad` resource ids.
///
/// Producers (a terminal session publishing Kitty graphics images) put images
/// before emitting commands that reference them and remove them once no frame
/// references them any longer. Renderers only read. Kitty graphics resource
/// ids are libghostty image generation stamps, which are unique across the
/// whole process, so sessions never collide. Thread-safe.
public final class FrameImageStore: @unchecked Sendable {
  public static let shared = FrameImageStore()

  private let lock = NSLock()
  private var images: [UInt64: FrameImage] = [:]

  public init() {}

  public func image(for resourceId: UInt64) -> FrameImage? {
    lock.lock()
    defer { lock.unlock() }
    return images[resourceId]
  }

  public func contains(_ resourceId: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return images[resourceId] != nil
  }

  public func put(_ image: FrameImage, for resourceId: UInt64) {
    lock.lock()
    images[resourceId] = image
    lock.unlock()
  }

  public func remove<S: Sequence>(_ resourceIds: S) where S.Element == UInt64 {
    lock.lock()
    for id in resourceIds { images.removeValue(forKey: id) }
    lock.unlock()
  }

  public var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return images.count
  }
}
