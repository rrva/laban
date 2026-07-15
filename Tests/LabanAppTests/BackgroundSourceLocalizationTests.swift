import Foundation
import XCTest

final class BackgroundSourceLocalizationTests: XCTestCase {
  private let locales = [
    "zh-Hans", "zh-Hant", "ja", "ko", "fr", "es", "hi", "ru", "de", "pt-BR", "it",
  ]

  private let keys = [
    "Remove Image",
    "Choose an exact background preset. Changing an individual background control shows Custom.",
    "Choose direct transparency, a blurred system backdrop, or a managed local image behind the terminal.",
    "Import a still image into Laban’s private background-image storage.",
    "Delete the managed background image and select None.",
    "Choose how the managed image fills the terminal area.",
    "Choose how much of the themed terminal background covers the selected source. The entire sidebar remains opaque; text, the cursor, and selections remain fully visible. 100% is fully opaque.",
    "Preset:",
    "Background source:",
    "Image scaling:",
    "No image selected.",
    "Image: %@",
    "Image file is missing: %@",
    "Image could not be loaded: %@",
    "Choose Again…",
    "Couldn’t Import Background Image",
    "The selected file could not be imported as a background image. Choose a valid still image and try again.",
    "Choose a Background Image",
    "Choose Image",
    "Opaque",
    "Frosted",
    "Custom",
    "None",
    "System Blur",
    "Image",
    "Fill",
    "Fit",
    "Stretch",
  ]

  func testEveryBackgroundSourceStringHasGeneratedNonFallbackTranslations() throws {
    let strings = try catalogStrings()

    for key in keys {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], "missing key: \(key)")
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any],
        "missing localizations: \(key)")
      for locale in locales {
        let localization = try XCTUnwrap(
          localizations[locale] as? [String: Any],
          "missing \(locale): \(key)")
        let unit = try XCTUnwrap(
          localization["stringUnit"] as? [String: Any],
          "missing unit for \(locale): \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "\(locale): \(key)")
        let value = try XCTUnwrap(
          unit["value"] as? String,
          "missing value for \(locale): \(key)")
        XCTAssertFalse(value.isEmpty, "\(locale): \(key)")
        XCTAssertNotEqual(value, key, "fallback translation for \(locale): \(key)")
      }
    }
  }

  func testStatusFormatTranslationsPreserveObjectPlaceholderExactlyOnce() throws {
    let strings = try catalogStrings()
    for key in ["Image: %@", "Image file is missing: %@", "Image could not be loaded: %@"] {
      let entry = try XCTUnwrap(strings[key] as? [String: Any])
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
      for locale in locales {
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
        let value = try XCTUnwrap(unit["value"] as? String)
        XCTAssertEqual(value.components(separatedBy: "%@").count - 1, 1, "\(locale): \(key)")
      }
    }
  }

  private func catalogStrings() throws -> [String: Any] {
    let url = repositoryRoot()
      .appendingPathComponent("Sources/LabanApp/Resources/Localizable.xcstrings")
    let data = try Data(contentsOf: url)
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try XCTUnwrap(catalog["strings"] as? [String: Any])
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
