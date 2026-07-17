import Foundation
import LabanRenderer

/// Errors that can occur while reading, validating, or importing a user theme.
public enum TerminalThemeStoreError: Error, Equatable {
  case managedDirectoryUnavailable
  case unreadableSource
  case invalidJSON
  case invalidVersion
  case missingName
  case invalidName
  case nameCollidesWithBundledTheme
  case nameCollidesWithImportedTheme
  case missingColor(String)
  case invalidColor(String, String)
  case invalidAnsi16Count(Int)
  case encodingFailed
}

/// A serializable reference to an imported theme file stored inside Laban's
/// private Application Support directory. The identifier is the file name.
public struct TerminalManagedTheme: Equatable, Sendable, Codable {
  public let identifier: String
  public let name: String
  public let isDark: Bool

  public init(identifier: String, name: String, isDark: Bool) {
    self.identifier = identifier
    self.name = name
    self.isDark = isDark
  }
}

/// On-disk representation of a `laban-theme.json` file. Parsing is lenient
/// about leading `#` or `0x` prefixes, but the validation step that produces
/// `ThemeData` is strict about structure and collisions.
struct TerminalThemeFile: Codable, Equatable {
  var version: Int
  var name: String
  var isDark: Bool
  var colors: Colors

  struct Colors: Codable, Equatable {
    var bg0: String
    var bg1: String
    var bg2: String
    var fg0: String
    var fg1: String
    var dim0: String
    var red: String
    var blue: String
    var cursor: String
    var selectionBg: String
    var ansi16: [String]
  }

  /// Validates the file contents and converts to a renderer-ready theme.
  /// - Parameters:
  ///   - bundledNames: Names of bundled themes that imports may not shadow.
  ///   - importedNames: Names of already-imported themes that imports may not
  ///     shadow (an import may replace itself only through remove-then-import).
  func validatedThemeData(
    bundledNames: Set<String>,
    importedNames: Set<String>
  ) throws -> ThemeData {
    guard version == 1 else {
      throw TerminalThemeStoreError.invalidVersion
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw TerminalThemeStoreError.missingName
    }
    guard Self.isValidName(trimmedName) else {
      throw TerminalThemeStoreError.invalidName
    }
    guard !bundledNames.contains(trimmedName) else {
      throw TerminalThemeStoreError.nameCollidesWithBundledTheme
    }
    guard !importedNames.contains(trimmedName) else {
      throw TerminalThemeStoreError.nameCollidesWithImportedTheme
    }

    let chrome = [
      ("bg0", colors.bg0),
      ("bg1", colors.bg1),
      ("bg2", colors.bg2),
      ("fg0", colors.fg0),
      ("fg1", colors.fg1),
      ("dim0", colors.dim0),
      ("red", colors.red),
      ("blue", colors.blue),
      ("cursor", colors.cursor),
      ("selectionBg", colors.selectionBg),
    ]
    var parsedChrome: [String: UInt32] = [:]
    for (key, raw) in chrome {
      guard let value = Self.parseHexColor(raw) else {
        throw TerminalThemeStoreError.invalidColor(key, raw)
      }
      parsedChrome[key] = value
    }

    guard colors.ansi16.count == 16 else {
      throw TerminalThemeStoreError.invalidAnsi16Count(colors.ansi16.count)
    }
    let ansi16 = try colors.ansi16.enumerated().map { index, raw -> UInt32 in
      guard let value = Self.parseHexColor(raw) else {
        throw TerminalThemeStoreError.invalidColor("ansi16[\(index)]", raw)
      }
      return value
    }

    return ThemeData(
      name: trimmedName,
      isDark: isDark,
      bg0: parsedChrome["bg0"]!,
      bg1: parsedChrome["bg1"]!,
      bg2: parsedChrome["bg2"]!,
      fg0: parsedChrome["fg0"]!,
      fg1: parsedChrome["fg1"]!,
      dim0: parsedChrome["dim0"]!,
      red: parsedChrome["red"]!,
      blue: parsedChrome["blue"]!,
      cursor: parsedChrome["cursor"]!,
      selectionBg: parsedChrome["selectionBg"]!,
      ansi16: ansi16)
  }

  /// Produces a stable, normalized copy of this file for writing into the
  /// managed store. The written copy keeps the user's original order and
  /// formatting intent while guaranteeing that the version field is present.
  func normalized() -> TerminalThemeFile {
    TerminalThemeFile(
      version: 1,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      isDark: isDark,
      colors: colors)
  }

  private static func isValidName(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 255, value != ".", value != ".." else {
      return false
    }
    return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
  }

  /// Parses a hex color string into a 0xRRGGBBAA UInt32. Accepts `#RRGGBB`,
  /// `#RRGGBBAA`, `RRGGBB`, `RRGGBBAA`, `0xRRGGBB`, and `0xRRGGBBAA`.
  /// Six-digit forms are treated as fully opaque.
  static func parseHexColor(_ raw: String) -> UInt32? {
    var sanitized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if sanitized.hasPrefix("#") {
      sanitized.removeFirst()
    } else if sanitized.lowercased().hasPrefix("0x") {
      sanitized.removeFirst(2)
    }
    guard sanitized.count == 6 || sanitized.count == 8 else { return nil }
    guard let value = UInt32(sanitized, radix: 16) else { return nil }
    if sanitized.count == 6 {
      return (value << 8) | 0xFF
    }
    return value
  }
}
