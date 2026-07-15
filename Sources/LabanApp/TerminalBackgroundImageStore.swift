import CoreGraphics
import Foundation
import ImageIO
import LabanCore
import UniformTypeIdentifiers

enum TerminalBackgroundImageStoreError: Error, Equatable {
  case managedDirectoryUnavailable
  case unreadableSource
  case invalidImage
  case invalidDimensions
  case invalidOrientation
  case invalidDisplayName
  case encodingFailed
  case publicationFailed
}

struct TerminalBackgroundImageImportResult: Equatable {
  let managedImage: TerminalManagedBackgroundImage
  let sourceFrameCount: Int
  let sourceOrientation: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

struct TerminalResolvedBackgroundImage {
  let managedImage: TerminalManagedBackgroundImage
  let fileURL: URL
  let image: CGImage
}

struct TerminalBackgroundImageResolution {
  let availability: TerminalBackgroundImageAvailability
  let asset: TerminalResolvedBackgroundImage?
}

/// Owns Laban's private, normalized background-image copies. External picker
/// URLs are consumed only for the duration of an import and are never retained
/// in settings, debug state, or this store's public value types.
@MainActor
final class TerminalBackgroundImageStore {
  static let directoryName = "background-images"
  static let managedAssetPrefix = "image-"
  static let stagingPrefix = ".staging-"

  let directoryURL: URL

  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private let fileManager: FileManager
  private let beforeSettingsPublication: () throws -> Void
  private var cachedResolution: CachedResolution?

  convenience init(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    self.init(
      baseURL: PersistenceStore.defaultBaseURL(),
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  init(
    baseURL: URL,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    fileManager: FileManager = .default,
    beforeSettingsPublication: @escaping () throws -> Void = {}
  ) {
    self.directoryURL = baseURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.fileManager = fileManager
    self.beforeSettingsPublication = beforeSettingsPublication
    hardenManagedDirectoryIfPresent()
    cleanupStagingFilesIfPresent()
  }

  /// Imports a picker result. Passing nil represents cancellation and is an
  /// exact no-op: no directory, setting, or notification is created.
  @discardableResult
  func importImage(
    from selectedURL: URL?,
    scaling: TerminalBackgroundImageScaling? = nil
  ) throws -> TerminalBackgroundImageImportResult? {
    guard let selectedURL else { return nil }

    let accessedSecurityScope = selectedURL.startAccessingSecurityScopedResource()
    defer {
      if accessedSecurityScope {
        selectedURL.stopAccessingSecurityScopedResource()
      }
    }

    let decoded = try decodeAndNormalizeFirstFrame(at: selectedURL)
    let displayName = selectedURL.lastPathComponent
    let identifier = Self.managedAssetPrefix + UUID().uuidString.lowercased() + ".png"
    guard
      let managedImage = TerminalManagedBackgroundImage(
        identifier: identifier,
        displayName: displayName)
    else {
      throw TerminalBackgroundImageStoreError.invalidDisplayName
    }

    try ensureManagedDirectory()
    try cleanupStagingFiles()
    let stagingURL = directoryURL.appendingPathComponent(
      Self.stagingPrefix + UUID().uuidString.lowercased() + ".png",
      isDirectory: false)
    let finalURL = directoryURL.appendingPathComponent(identifier, isDirectory: false)
    var published = false
    defer {
      try? fileManager.removeItem(at: stagingURL)
      if !published {
        try? fileManager.removeItem(at: finalURL)
      }
    }

    try encodeManagedPNG(decoded.image, to: stagingURL)
    try setPrivateFilePermissions(at: stagingURL)
    do {
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      try setPrivateFilePermissions(at: finalURL)
    } catch {
      throw TerminalBackgroundImageStoreError.encodingFailed
    }

    do {
      try beforeSettingsPublication()
    } catch {
      throw TerminalBackgroundImageStoreError.publicationFailed
    }

    cacheAvailableImage(managedImage, fileURL: finalURL, image: decoded.image)

    let previous = TerminalTransparencySettings.requestedSettings(defaults: defaults)
    var next = previous
    next.configuration.backdropStyle = .image
    if let scaling {
      next.configuration.backgroundImageScaling = scaling
    }
    next.managedBackgroundImage = managedImage
    TerminalTransparencySettings.setRequestedSettings(
      next,
      defaults: defaults,
      notificationCenter: notificationCenter)
    published = true

    if previous.managedBackgroundImage?.identifier != managedImage.identifier {
      removeManagedFileIfContained(previous.managedBackgroundImage)
    }
    try? cleanupOrphans(keeping: managedImage)

    return TerminalBackgroundImageImportResult(
      managedImage: managedImage,
      sourceFrameCount: decoded.sourceFrameCount,
      sourceOrientation: decoded.sourceOrientation,
      pixelWidth: decoded.image.width,
      pixelHeight: decoded.image.height)
  }

  func resolveManagedImage(
    _ managedImage: TerminalManagedBackgroundImage?
  ) -> TerminalBackgroundImageResolution {
    guard let managedImage else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .none, asset: nil)
    }
    guard fileManager.fileExists(atPath: directoryURL.path) else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .missing, asset: nil)
    }
    guard isTrustedManagedDirectory() else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .invalid, asset: nil)
    }
    guard let fileURL = containedURL(for: managedImage) else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .invalid, asset: nil)
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .missing, asset: nil)
    }
    guard isResolvedFileContained(fileURL), isRegularFile(fileURL), hardenManagedFile(fileURL),
      let fingerprint = fingerprint(for: fileURL)
    else {
      cachedResolution = nil
      return TerminalBackgroundImageResolution(availability: .invalid, asset: nil)
    }
    if let cachedResolution,
      cachedResolution.identifier == managedImage.identifier,
      cachedResolution.fingerprint == fingerprint
    {
      return cachedResolution.resolution
    }
    let resolution: TerminalBackgroundImageResolution
    if let image = decodeManagedPNG(at: fileURL) {
      resolution = TerminalBackgroundImageResolution(
        availability: .available,
        asset: TerminalResolvedBackgroundImage(
          managedImage: managedImage,
          fileURL: fileURL,
          image: image))
    } else {
      resolution = TerminalBackgroundImageResolution(availability: .invalid, asset: nil)
    }
    cachedResolution = CachedResolution(
      identifier: managedImage.identifier,
      fingerprint: fingerprint,
      resolution: resolution)
    return resolution
  }

  func resolveRequestedImage() -> TerminalBackgroundImageResolution {
    resolveManagedImage(
      TerminalTransparencySettings.requestedSettings(defaults: defaults).managedBackgroundImage)
  }

  /// Clears the managed reference and selects None. File deletion follows
  /// settings publication, so a crash cannot leave settings pointing at an
  /// already-deleted asset.
  func removeManagedImage() {
    let previous = TerminalTransparencySettings.requestedSettings(defaults: defaults)
    var next = previous
    next.managedBackgroundImage = nil
    next.configuration.backdropStyle = .none
    TerminalTransparencySettings.setRequestedSettings(
      next,
      defaults: defaults,
      notificationCenter: notificationCenter)
    cachedResolution = nil
    removeManagedFileIfContained(previous.managedBackgroundImage)
    try? cleanupOrphans(keeping: nil)
  }

  /// Removes crash-left staging files and generated managed assets other than
  /// the currently persisted one. Unrelated Application Support files and
  /// unrecognized names are never touched.
  func cleanupOrphans(keeping managedImage: TerminalManagedBackgroundImage?) throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    guard isTrustedManagedDirectory() else {
      throw TerminalBackgroundImageStoreError.managedDirectoryUnavailable
    }
    for child in try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    {
      let name = child.lastPathComponent
      let isStaging = name.hasPrefix(Self.stagingPrefix)
      let isOrphan = Self.isManagedAssetName(name) && name != managedImage?.identifier
      if isStaging || isOrphan {
        try fileManager.removeItem(at: child)
      }
    }
  }

  private struct DecodedSource {
    let image: CGImage
    let sourceFrameCount: Int
    let sourceOrientation: Int
  }

  private struct FileFingerprint: Equatable {
    let size: UInt64
    let modificationDate: Date
    let systemFileNumber: UInt64
  }

  private struct CachedResolution {
    let identifier: String
    let fingerprint: FileFingerprint
    let resolution: TerminalBackgroundImageResolution
  }

  private func decodeAndNormalizeFirstFrame(at sourceURL: URL) throws -> DecodedSource {
    guard
      let source = CGImageSourceCreateWithURL(
        sourceURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary)
    else {
      throw TerminalBackgroundImageStoreError.unreadableSource
    }
    let frameCount = CGImageSourceGetCount(source)
    guard frameCount > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else {
      throw TerminalBackgroundImageStoreError.invalidImage
    }
    guard
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0
    else {
      throw TerminalBackgroundImageStoreError.invalidDimensions
    }
    let orientation =
      (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw TerminalBackgroundImageStoreError.invalidOrientation
    }

    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      image.width > 0,
      image.height > 0
    else {
      throw TerminalBackgroundImageStoreError.invalidImage
    }
    return DecodedSource(
      image: image,
      sourceFrameCount: frameCount,
      sourceOrientation: orientation)
  }

  private func encodeManagedPNG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil)
    else {
      throw TerminalBackgroundImageStoreError.encodingFailed
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [kCGImagePropertyOrientation: 1] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw TerminalBackgroundImageStoreError.encodingFailed
    }
  }

  private func decodeManagedPNG(at url: URL) -> CGImage? {
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetType(source) as String? == UTType.png.identifier,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) == 1,
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0
    else { return nil }
    return CGImageSourceCreateImageAtIndex(
      source,
      0,
      [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
  }

  private func ensureManagedDirectory() throws {
    do {
      if fileManager.fileExists(atPath: directoryURL.path), !isTrustedManagedDirectory() {
        throw TerminalBackgroundImageStoreError.managedDirectoryUnavailable
      }
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: directoryURL.path)
      guard isTrustedManagedDirectory() else {
        throw TerminalBackgroundImageStoreError.managedDirectoryUnavailable
      }
    } catch {
      throw TerminalBackgroundImageStoreError.managedDirectoryUnavailable
    }
  }

  private func setPrivateFilePermissions(at url: URL) throws {
    do {
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path)
    } catch {
      throw TerminalBackgroundImageStoreError.encodingFailed
    }
  }

  private func hardenManagedDirectoryIfPresent() {
    guard fileManager.fileExists(atPath: directoryURL.path), isTrustedManagedDirectory() else {
      return
    }
    try? fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)],
      ofItemAtPath: directoryURL.path)
  }

  private func hardenManagedFile(_ url: URL) -> Bool {
    guard
      let permissions = try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
        as? NSNumber
    else { return false }
    if permissions.intValue & 0o777 == 0o600 { return true }
    return
      (try? fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path)) != nil
  }

  private func containedURL(for managedImage: TerminalManagedBackgroundImage) -> URL? {
    guard Self.isManagedAssetName(managedImage.identifier) else { return nil }
    let candidate = directoryURL.appendingPathComponent(
      managedImage.identifier,
      isDirectory: false
    ).standardizedFileURL
    guard candidate.deletingLastPathComponent() == directoryURL.standardizedFileURL else {
      return nil
    }
    return candidate
  }

  private func isResolvedFileContained(_ fileURL: URL) -> Bool {
    let resolvedRoot = directoryURL.resolvingSymlinksInPath().standardizedFileURL
    return fileURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
      == resolvedRoot
  }

  private func isRegularFile(_ url: URL) -> Bool {
    guard
      let type = try? fileManager.attributesOfItem(atPath: url.path)[.type]
        as? FileAttributeType
    else { return false }
    return type == .typeRegular
  }

  private func fingerprint(for url: URL) -> FileFingerprint? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let size = (attributes[.size] as? NSNumber)?.uint64Value,
      let modificationDate = attributes[.modificationDate] as? Date,
      let systemFileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    else { return nil }
    return FileFingerprint(
      size: size,
      modificationDate: modificationDate,
      systemFileNumber: systemFileNumber)
  }

  private func cacheAvailableImage(
    _ managedImage: TerminalManagedBackgroundImage,
    fileURL: URL,
    image: CGImage
  ) {
    guard let fingerprint = fingerprint(for: fileURL) else {
      cachedResolution = nil
      return
    }
    cachedResolution = CachedResolution(
      identifier: managedImage.identifier,
      fingerprint: fingerprint,
      resolution: TerminalBackgroundImageResolution(
        availability: .available,
        asset: TerminalResolvedBackgroundImage(
          managedImage: managedImage,
          fileURL: fileURL,
          image: image)))
  }

  private func removeManagedFileIfContained(_ managedImage: TerminalManagedBackgroundImage?) {
    guard isTrustedManagedDirectory(),
      let managedImage,
      let url = containedURL(for: managedImage)
    else { return }
    try? fileManager.removeItem(at: url)
  }

  private func cleanupStagingFilesIfPresent() {
    guard fileManager.fileExists(atPath: directoryURL.path), isTrustedManagedDirectory() else {
      return
    }
    try? cleanupStagingFiles()
  }

  private func cleanupStagingFiles() throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    guard isTrustedManagedDirectory() else {
      throw TerminalBackgroundImageStoreError.managedDirectoryUnavailable
    }
    for child in try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
      try fileManager.removeItem(at: child)
    }
  }

  private static func isManagedAssetName(_ name: String) -> Bool {
    guard name.hasPrefix(managedAssetPrefix), name.hasSuffix(".png") else { return false }
    let uuidStart = name.index(name.startIndex, offsetBy: managedAssetPrefix.count)
    let uuidEnd = name.index(name.endIndex, offsetBy: -4)
    return UUID(uuidString: String(name[uuidStart..<uuidEnd])) != nil
  }

  private func isTrustedManagedDirectory() -> Bool {
    guard
      let type = try? fileManager.attributesOfItem(atPath: directoryURL.path)[.type]
        as? FileAttributeType
    else { return false }
    return type == .typeDirectory
  }
}
