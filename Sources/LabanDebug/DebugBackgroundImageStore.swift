import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LabanCore
import UniformTypeIdentifiers

enum DebugBackgroundImageStoreError: Error {
  case unreadableSource
  case invalidImage
  case storageUnavailable
}

struct DebugManagedBackgroundImage {
  let identifier: String
  let displayName: String
  let pixelWidth: Int
  let pixelHeight: Int
  let contentDigest: String
  let fileURL: URL
}

/// Headless counterpart of the AppKit managed store. It exists only under the
/// current artifact root and exposes URL-free metadata to debug state.
final class DebugBackgroundImageStore {
  static let directoryName = "background-images"

  let directoryURL: URL
  private(set) var importCount = 0
  private(set) var decodeCount = 0
  private(set) var fileReadCount = 0
  private(set) var managedImage: DebugManagedBackgroundImage?

  init(baseURL: URL) {
    directoryURL = baseURL.appendingPathComponent(Self.directoryName, isDirectory: true)
  }

  func importImage(from sourceURL: URL) throws -> DebugManagedBackgroundImage {
    fileReadCount += 1
    decodeCount += 1
    guard
      let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0
    else {
      throw DebugBackgroundImageStoreError.unreadableSource
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw DebugBackgroundImageStoreError.invalidImage
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw DebugBackgroundImageStoreError.invalidImage
    }

    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: directoryURL.path)
    } catch {
      throw DebugBackgroundImageStoreError.storageUnavailable
    }

    let identifier = "image-\(UUID().uuidString.lowercased()).png"
    let stagingURL = directoryURL.appendingPathComponent(".staging-\(UUID().uuidString).png")
    let finalURL = directoryURL.appendingPathComponent(identifier)
    defer { try? FileManager.default.removeItem(at: stagingURL) }
    guard
      let destination = CGImageDestinationCreateWithURL(
        stagingURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
      throw DebugBackgroundImageStoreError.storageUnavailable
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw DebugBackgroundImageStoreError.storageUnavailable
    }
    do {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: stagingURL.path)
      try FileManager.default.moveItem(at: stagingURL, to: finalURL)
    } catch {
      throw DebugBackgroundImageStoreError.storageUnavailable
    }

    let previous = managedImage
    let next = DebugManagedBackgroundImage(
      identifier: identifier,
      displayName: sourceURL.lastPathComponent,
      pixelWidth: image.width,
      pixelHeight: image.height,
      contentDigest: Self.contentDigest(image),
      fileURL: finalURL)
    managedImage = next
    importCount += 1
    if let previous {
      try? FileManager.default.removeItem(at: previous.fileURL)
    }
    return next
  }

  func removeImage() {
    if let managedImage {
      try? FileManager.default.removeItem(at: managedImage.fileURL)
    }
    managedImage = nil
    guard
      let children = try? FileManager.default.contentsOfDirectory(
        at: directoryURL, includingPropertiesForKeys: nil)
    else { return }
    for child in children where child.lastPathComponent.hasPrefix("image-") {
      try? FileManager.default.removeItem(at: child)
    }
  }

  func resetDiagnostics() {
    importCount = 0
    decodeCount = 0
    fileReadCount = 0
  }

  private static func contentDigest(_ image: CGImage) -> String {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var payload = Data("\(width)x\(height):".utf8)
    payload.append(contentsOf: bytes)
    return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
  }
}
