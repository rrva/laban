import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import LabanTerminalCore

/// The PNG decoder the terminal core calls for Kitty graphics transmissions
/// (`f=100`). It lives here, not in LabanTerminalCore, so ImageIO and
/// CoreGraphics stay out of the C core (scripts/check-boundaries). The core
/// has already checked the PNG signature and header size; this re-checks the
/// content type because ImageIO sniffs, and decodes only what it also calls a
/// PNG.
enum KittyPNGDecoder {
  /// Registers the decoder process-wide. Idempotent.
  static func install() {
    laban_set_kitty_png_decoder(decode)
  }

  private static let decode: LabanKittyPNGDecoder = { data, dataLength, context, allocate in
    guard let data, let allocate else { return false }
    return decodePNG(data, dataLength, context: context, allocate: allocate)
  }

  private static func decodePNG(
    _ data: UnsafePointer<UInt8>,
    _ dataLength: Int,
    context: UnsafeMutableRawPointer?,
    allocate: LabanKittyPixelAllocator
  ) -> Bool {
    let bytes = Data(
      bytesNoCopy: UnsafeMutableRawPointer(mutating: data), count: dataLength,
      deallocator: .none)
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetType(source) as String? == "public.png",
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      image.width > 0, image.height > 0,
      let width = UInt32(exactly: image.width), let height = UInt32(exactly: image.height),
      let pixels = allocate(context, width, height),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      // CoreGraphics only draws into premultiplied RGBA: draw, then convert
      // to the straight alpha libghostty stores.
      let bitmap = CGContext(
        data: pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue)
    else { return false }
    bitmap.setBlendMode(.copy)
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var buffer = vImage_Buffer(
      data: pixels, height: vImagePixelCount(image.height),
      width: vImagePixelCount(image.width), rowBytes: image.width * 4)
    return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
      == kvImageNoError
  }
}
