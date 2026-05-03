import CoreGraphics
import Foundation
import ImageIO

public enum PNGEncoder {
  public static func encode(_ image: CGImage) -> Data? {
    let buffer = NSMutableData()
    guard
      let dest = CGImageDestinationCreateWithData(
        buffer as CFMutableData,
        "public.png" as CFString,
        1,
        nil
      )
    else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return buffer as Data
  }
}

extension BitmapSurface {
  public var pngData: Data? {
    guard let image = cgImage else { return nil }
    return PNGEncoder.encode(image)
  }
}
