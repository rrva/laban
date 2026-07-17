import Foundation
import LabanRenderer

/// Owns Laban's private copies of user-imported terminal themes. External
/// picker URLs are consumed only during import and are never retained in
/// settings or debug state.
public final class TerminalThemeStore {
  public static let directoryName = "themes"
  public static let managedFilePrefix = "theme-"
  public static let stagingPrefix = ".staging-"
  public static let didChangeNotification = Notification.Name(
    "LabanTerminalThemeStoreDidChange")

  public let directoryURL: URL

  private let defaults: UserDefaults
  private let notificationCenter: NotificationCenter
  private let fileManager: FileManager

  public convenience init(
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default
  ) {
    self.init(
      baseURL: PersistenceStore.defaultBaseURL(),
      defaults: defaults,
      notificationCenter: notificationCenter)
  }

  public init(
    baseURL: URL,
    defaults: UserDefaults = .standard,
    notificationCenter: NotificationCenter = .default,
    fileManager: FileManager = .default
  ) {
    self.directoryURL = baseURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    self.defaults = defaults
    self.notificationCenter = notificationCenter
    self.fileManager = fileManager
    hardenManagedDirectoryIfPresent()
    cleanupStagingFilesIfPresent()
  }

  /// Imports a picker result. Passing nil represents cancellation and is an
  /// exact no-op: no directory, setting, or notification is created.
  @discardableResult
  public func importTheme(from selectedURL: URL?) throws -> TerminalManagedTheme? {
    guard let selectedURL else { return nil }

    let accessedSecurityScope = selectedURL.startAccessingSecurityScopedResource()
    defer {
      if accessedSecurityScope {
        selectedURL.stopAccessingSecurityScopedResource()
      }
    }

    let data: Data
    do {
      data = try Data(contentsOf: selectedURL)
    } catch {
      throw TerminalThemeStoreError.unreadableSource
    }

    let file: TerminalThemeFile
    do {
      file = try JSONDecoder().decode(TerminalThemeFile.self, from: data)
    } catch {
      throw TerminalThemeStoreError.invalidJSON
    }

    let bundledNames = Self.bundledThemeNames
    let importedNames = Set(try allManagedThemes().map(\.name))
    _ = try file.validatedThemeData(
      bundledNames: bundledNames,
      importedNames: importedNames)

    let normalized = file.normalized()
    let identifier = Self.managedFilePrefix + UUID().uuidString.lowercased() + ".json"
    let managedTheme = TerminalManagedTheme(
      identifier: identifier,
      name: normalized.name,
      isDark: normalized.isDark)

    try ensureManagedDirectory()
    try cleanupStagingFiles()
    let stagingURL = directoryURL.appendingPathComponent(
      Self.stagingPrefix + UUID().uuidString.lowercased() + ".json",
      isDirectory: false)
    let finalURL = directoryURL.appendingPathComponent(identifier, isDirectory: false)
    var published = false
    defer {
      try? fileManager.removeItem(at: stagingURL)
      if !published {
        try? fileManager.removeItem(at: finalURL)
      }
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let outData: Data
    do {
      outData = try encoder.encode(normalized)
    } catch {
      throw TerminalThemeStoreError.encodingFailed
    }
    do {
      try outData.write(to: stagingURL, options: .atomic)
      try setPrivateFilePermissions(at: stagingURL)
      try fileManager.moveItem(at: stagingURL, to: finalURL)
      try setPrivateFilePermissions(at: finalURL)
    } catch {
      throw TerminalThemeStoreError.encodingFailed
    }

    published = true
    notificationCenter.post(name: Self.didChangeNotification, object: nil)
    return managedTheme
  }

  /// All currently imported themes, sorted alphabetically by name.
  public func allManagedThemes() throws -> [TerminalManagedTheme] {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard isTrustedManagedDirectory() else { return [] }
    let children = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])

    var themes: [TerminalManagedTheme] = []
    for child in children {
      let name = child.lastPathComponent
      guard Self.isManagedFileName(name) else { continue }
      guard
        let data = try? Data(contentsOf: child),
        let file = try? JSONDecoder().decode(TerminalThemeFile.self, from: data)
      else { continue }
      themes.append(
        TerminalManagedTheme(
          identifier: name,
          name: file.name.trimmingCharacters(in: .whitespacesAndNewlines),
          isDark: file.isDark))
    }
    return themes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Resolves a managed theme back to a renderer-ready palette. Returns nil if
  /// the file is missing, corrupt, or no longer validates.
  public func resolveTheme(_ managedTheme: TerminalManagedTheme) -> ThemeData? {
    guard let fileURL = containedURL(for: managedTheme) else { return nil }
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    guard isResolvedFileContained(fileURL),
      isRegularFile(fileURL)
    else { return nil }
    guard
      let data = try? Data(contentsOf: fileURL),
      let file = try? JSONDecoder().decode(TerminalThemeFile.self, from: data)
    else { return nil }
    return try? file.validatedThemeData(
      bundledNames: Self.bundledThemeNames,
      importedNames: [])
  }

  /// Deletes the managed theme file. Settings that referenced it by name will
  /// naturally fall back on the next load because the name no longer resolves.
  public func removeManagedTheme(_ managedTheme: TerminalManagedTheme) throws {
    guard let fileURL = containedURL(for: managedTheme) else { return }
    try fileManager.removeItem(at: fileURL)
    notificationCenter.post(name: Self.didChangeNotification, object: nil)
  }

  /// Convenience remove by display name.
  public func removeManagedTheme(named name: String) throws {
    let themes = try allManagedThemes()
    guard let theme = themes.first(where: { $0.name == name }) else { return }
    try removeManagedTheme(theme)
  }

  /// Removes crash-left staging files and generated managed assets other than
  /// the currently persisted set. Unrelated Application Support files and
  /// unrecognized names are never touched.
  public func cleanupOrphans(keeping managedThemes: [TerminalManagedTheme]) throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    guard isTrustedManagedDirectory() else {
      throw TerminalThemeStoreError.managedDirectoryUnavailable
    }
    let keptIdentifiers = Set(managedThemes.map(\.identifier))
    for child in try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    {
      let name = child.lastPathComponent
      let isStaging = name.hasPrefix(Self.stagingPrefix)
      let isOrphan = Self.isManagedFileName(name) && !keptIdentifiers.contains(name)
      if isStaging || isOrphan {
        try fileManager.removeItem(at: child)
      }
    }
  }

  private static var bundledThemeNames: Set<String> {
    Set((Theme.allDarkThemes + Theme.allLightThemes).map(\.name))
  }

  private func ensureManagedDirectory() throws {
    do {
      if fileManager.fileExists(atPath: directoryURL.path), !isTrustedManagedDirectory() {
        throw TerminalThemeStoreError.managedDirectoryUnavailable
      }
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: directoryURL.path)
      guard isTrustedManagedDirectory() else {
        throw TerminalThemeStoreError.managedDirectoryUnavailable
      }
    } catch {
      throw TerminalThemeStoreError.managedDirectoryUnavailable
    }
  }

  private func setPrivateFilePermissions(at url: URL) throws {
    do {
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: url.path)
    } catch {
      throw TerminalThemeStoreError.encodingFailed
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

  private func containedURL(for managedTheme: TerminalManagedTheme) -> URL? {
    guard Self.isManagedFileName(managedTheme.identifier) else { return nil }
    let candidate = directoryURL.appendingPathComponent(
      managedTheme.identifier,
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

  private func cleanupStagingFilesIfPresent() {
    guard fileManager.fileExists(atPath: directoryURL.path), isTrustedManagedDirectory() else {
      return
    }
    try? cleanupStagingFiles()
  }

  private func cleanupStagingFiles() throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    guard isTrustedManagedDirectory() else {
      throw TerminalThemeStoreError.managedDirectoryUnavailable
    }
    for child in try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: nil,
      options: [.skipsSubdirectoryDescendants])
    where child.lastPathComponent.hasPrefix(Self.stagingPrefix) {
      try fileManager.removeItem(at: child)
    }
  }

  private static func isManagedFileName(_ name: String) -> Bool {
    guard name.hasPrefix(managedFilePrefix), name.hasSuffix(".json") else { return false }
    let uuidStart = name.index(name.startIndex, offsetBy: managedFilePrefix.count)
    let uuidEnd = name.index(name.endIndex, offsetBy: -5)
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
