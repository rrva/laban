import Foundation
import XCTest

final class TransparencyLocalizationTests: XCTestCase {
  func testCommittedCatalogMatchesGeneratorOutput() throws {
    let repositoryRoot = repositoryRoot()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["python3", "scripts/gen-localizable-xcstrings.py", "--check"]
    process.currentDirectoryURL = repositoryRoot
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    process.waitUntilExit()

    let transcript = String(
      decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 0, transcript)
    XCTAssertTrue(transcript.contains("verified"), transcript)
  }

  func testTransparencyStringsAreLocalizedInEverySupportedLocale() throws {
    let keys = [
      "Background opacity:",
      "Background opacity",
      "Background opacity: %lld percent",
      "Choose how much of the default terminal background is visible. The sidebar remains opaque; text, the cursor, selections, and images remain fully visible. 100% is fully opaque.",
      "Apply opacity to colored cell backgrounds",
      "Also applies the selected opacity to background colors set by terminal programs, including inverse video.",
    ]
    let locales = [
      "zh-Hans", "zh-Hant", "ja", "ko", "fr", "es", "hi", "ru", "de", "pt-BR", "it",
    ]

    let repositoryRoot = repositoryRoot()
    let catalogURL =
      repositoryRoot.appendingPathComponent("Sources/LabanApp/Resources/Localizable.xcstrings")
    let data = try Data(contentsOf: catalogURL)
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let catalogStrings = try XCTUnwrap(catalog["strings"] as? [String: Any])

    for key in keys {
      let entry = try XCTUnwrap(catalogStrings[key] as? [String: Any], "missing key: \(key)")
      let localizations = try XCTUnwrap(
        entry["localizations"] as? [String: Any], "missing localizations: \(key)")

      for locale in locales {
        let localization = try XCTUnwrap(
          localizations[locale] as? [String: Any], "missing \(locale): \(key)")
        let unit = try XCTUnwrap(
          localization["stringUnit"] as? [String: Any],
          "missing unit for \(locale): \(key)")
        XCTAssertEqual(unit["state"] as? String, "translated", "\(locale): \(key)")
        let value = try XCTUnwrap(
          unit["value"] as? String, "missing value for \(locale): \(key)")
        XCTAssertFalse(value.isEmpty, "\(locale): \(key)")
        XCTAssertNotEqual(value, key, "untranslated \(locale): \(key)")
      }
    }

    XCTAssertEqual(Set(catalogStrings.keys).intersection(keys).count, keys.count)
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
