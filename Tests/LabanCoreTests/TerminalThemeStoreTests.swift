import Foundation
import LabanRenderer
import XCTest

@testable import LabanCore

@MainActor
final class TerminalThemeStoreTests: XCTestCase {
  private var roots: [URL] = []

  override func tearDown() {
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }

  func testValidImportProducesManagedTheme() throws {
    let context = try makeContext()
    var notificationCount = 0
    let token = context.notifications.addObserver(
      forName: TerminalThemeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { context.notifications.removeObserver(token) }
    let sourceURL = context.externalURL.appendingPathComponent("custom.laban-theme.json")
    try writeValidTheme(to: sourceURL, name: "Custom Dark")

    let result = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    XCTAssertEqual(result.name, "Custom Dark")
    XCTAssertTrue(result.isDark)
    XCTAssertTrue(result.identifier.hasPrefix(TerminalThemeStore.managedFilePrefix))
    XCTAssertTrue(result.identifier.hasSuffix(".json"))
    XCTAssertFalse(result.identifier.contains("/"))
    XCTAssertEqual(notificationCount, 1)

    let relaunched = TerminalThemeStore(
      baseURL: context.baseURL,
      notificationCenter: context.notifications)
    let themes = try relaunched.allManagedThemes()
    XCTAssertEqual(themes.map(\.name), ["Custom Dark"])

    let resolved = try XCTUnwrap(relaunched.resolveTheme(result))
    XCTAssertEqual(resolved.name, "Custom Dark")
    XCTAssertEqual(resolved.isDark, true)
    XCTAssertEqual(resolved.ansi16.count, 16)
  }

  func testCancelledImportIsNoOp() throws {
    let context = try makeContext()
    var notificationCount = 0
    let token = context.notifications.addObserver(
      forName: TerminalThemeStore.didChangeNotification,
      object: nil,
      queue: nil
    ) { _ in notificationCount += 1 }
    defer { context.notifications.removeObserver(token) }

    XCTAssertNil(try context.store.importTheme(from: nil))
    XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.directoryURL.path))
    XCTAssertEqual(notificationCount, 0)
  }

  func testInvalidVersionFails() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("bad-version.json")
    let theme = validThemeFile(name: "Bad Version")
    var json = try JSONSerialization.jsonObject(with: encode(theme), options: []) as! [String: Any]
    json["version"] = 2
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
      .write(to: sourceURL)

    XCTAssertThrowsError(try context.store.importTheme(from: sourceURL)) { error in
      XCTAssertEqual(error as? TerminalThemeStoreError, .invalidVersion)
    }
  }

  func testMissingNameFails() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("no-name.json")
    var theme = validThemeFile(name: "   ")
    theme.name = "   "
    try encode(theme).write(to: sourceURL)

    XCTAssertThrowsError(try context.store.importTheme(from: sourceURL)) { error in
      XCTAssertEqual(error as? TerminalThemeStoreError, .missingName)
    }
  }

  func testInvalidColorFails() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("bad-color.json")
    var theme = validThemeFile(name: "Bad Color")
    theme.colors.bg0 = "not-a-color"
    try encode(theme).write(to: sourceURL)

    XCTAssertThrowsError(try context.store.importTheme(from: sourceURL)) { error in
      guard case .invalidColor(let key, let value) = error as? TerminalThemeStoreError else {
        XCTFail("unexpected error: \(error)")
        return
      }
      XCTAssertEqual(key, "bg0")
      XCTAssertEqual(value, "not-a-color")
    }
  }

  func testInvalidAnsi16CountFails() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("bad-ansi.json")
    var theme = validThemeFile(name: "Bad ANSI")
    theme.colors.ansi16 = Array(theme.colors.ansi16.dropLast())
    try encode(theme).write(to: sourceURL)

    XCTAssertThrowsError(try context.store.importTheme(from: sourceURL)) { error in
      guard case .invalidAnsi16Count(let count) = error as? TerminalThemeStoreError else {
        XCTFail("unexpected error: \(error)")
        return
      }
      XCTAssertEqual(count, 15)
    }
  }

  func testBundledNameCollisionFails() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("collision.json")
    try writeValidTheme(to: sourceURL, name: "Selenized Dark")

    XCTAssertThrowsError(try context.store.importTheme(from: sourceURL)) { error in
      XCTAssertEqual(error as? TerminalThemeStoreError, .nameCollidesWithBundledTheme)
    }
  }

  func testImportedNameCollisionFails() throws {
    let context = try makeContext()
    let firstURL = context.externalURL.appendingPathComponent("first.json")
    let secondURL = context.externalURL.appendingPathComponent("second.json")
    try writeValidTheme(to: firstURL, name: "My Theme")
    try writeValidTheme(to: secondURL, name: "My Theme")

    _ = try XCTUnwrap(try context.store.importTheme(from: firstURL))

    XCTAssertThrowsError(try context.store.importTheme(from: secondURL)) { error in
      XCTAssertEqual(error as? TerminalThemeStoreError, .nameCollidesWithImportedTheme)
    }
  }

  func testResolveThemeReturnsNilForMissingFile() throws {
    let context = try makeContext()
    let managed = TerminalManagedTheme(
      identifier: TerminalThemeStore.managedFilePrefix + UUID().uuidString.lowercased() + ".json",
      name: "Missing",
      isDark: true)

    XCTAssertNil(context.store.resolveTheme(managed))
  }

  func testRemoveManagedThemeDeletesFile() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("remove-me.json")
    try writeValidTheme(to: sourceURL, name: "Remove Me")
    let result = try XCTUnwrap(try context.store.importTheme(from: sourceURL))
    let fileURL = context.store.directoryURL.appendingPathComponent(result.identifier)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

    try context.store.removeManagedTheme(result)

    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(try context.store.allManagedThemes().isEmpty)
  }

  func testRemoveManagedThemeNamedDeletesMatchingTheme() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("by-name.json")
    try writeValidTheme(to: sourceURL, name: "By Name")
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    try context.store.removeManagedTheme(named: "By Name")

    XCTAssertTrue(try context.store.allManagedThemes().isEmpty)
  }

  func testOrphanCleanupKeepsOnlyReferencedThemes() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("keeper.json")
    try writeValidTheme(to: sourceURL, name: "Keeper")
    let result = try XCTUnwrap(try context.store.importTheme(from: sourceURL))
    let orphanName =
      TerminalThemeStore.managedFilePrefix + UUID().uuidString.lowercased() + ".json"
    let stagingName =
      TerminalThemeStore.stagingPrefix + UUID().uuidString.lowercased() + ".json"
    let unrelatedName = "notes.txt"
    let orphanURL = context.store.directoryURL.appendingPathComponent(orphanName)
    let stagingURL = context.store.directoryURL.appendingPathComponent(stagingName)
    let unrelatedURL = context.store.directoryURL.appendingPathComponent(unrelatedName)
    try encode(validThemeFile(name: "Orphan")).write(to: orphanURL)
    try Data("staging".utf8).write(to: stagingURL)
    try Data("notes".utf8).write(to: unrelatedURL)

    let relaunched = TerminalThemeStore(
      baseURL: context.baseURL,
      notificationCenter: context.notifications)
    try relaunched.cleanupOrphans(keeping: [result])

    XCTAssertTrue(FileManager.default.fileExists(atPath: context.store.directoryURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagingURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
  }

  func testManagedDirectoryAndFileArePrivate() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("private.json")
    try writeValidTheme(to: sourceURL, name: "Private")
    let result = try XCTUnwrap(try context.store.importTheme(from: sourceURL))
    let fileURL = context.store.directoryURL.appendingPathComponent(result.identifier)

    XCTAssertEqual(try permissions(at: context.store.directoryURL), 0o700)
    XCTAssertEqual(try permissions(at: fileURL), 0o600)
  }

  func testAllManagedThemesSortsAlphabetically() throws {
    let context = try makeContext()
    let names = ["Zebra", "Alpha", "Beta"]
    for name in names {
      let sourceURL = context.externalURL.appendingPathComponent("\(name).json")
      var theme = validThemeFile(name: name)
      theme.isDark = false
      try encode(theme).write(to: sourceURL)
      _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))
    }

    let themes = try context.store.allManagedThemes()
    XCTAssertEqual(themes.map(\.name), ["Alpha", "Beta", "Zebra"])
  }

  func testBundledThemeExamplesMatchSwiftConstants() throws {
    let bundled = Theme.allDarkThemes + Theme.allLightThemes
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let examplesDir = repoRoot.appendingPathComponent("schemas/theme/examples")
    for theme in bundled {
      let slug = theme.name.lowercased().replacingOccurrences(of: " ", with: "-")
      let url = examplesDir.appendingPathComponent("\(slug).laban-theme.json")
      let data = try Data(contentsOf: url)
      let file = try JSONDecoder().decode(TerminalThemeFile.self, from: data)
      let resolved = try file.validatedThemeData(bundledNames: [], importedNames: [])
      XCTAssertEqual(
        resolved, theme,
        "JSON example for \(theme.name) drifts from the bundled Swift constant")
    }
  }

  // MARK: Helpers

  private struct Context {
    let baseURL: URL
    let externalURL: URL
    let notifications: NotificationCenter
    let store: TerminalThemeStore
  }

  private func makeContext() throws -> Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "laban-theme-store-tests-\(UUID().uuidString)",
      isDirectory: true)
    roots.append(root)
    let baseURL = root.appendingPathComponent("application-support", isDirectory: true)
    let externalURL = root.appendingPathComponent("external-picker", isDirectory: true)
    try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    let notifications = NotificationCenter()
    return Context(
      baseURL: baseURL,
      externalURL: externalURL,
      notifications: notifications,
      store: TerminalThemeStore(
        baseURL: baseURL,
        notificationCenter: notifications))
  }

  private func validThemeFile(name: String) -> TerminalThemeFile {
    TerminalThemeFile(
      version: 1,
      name: name,
      isDark: true,
      colors: TerminalThemeFile.Colors(
        bg0: "#103C48",
        bg1: "#174956",
        bg2: "#2D5B69",
        fg0: "#ADBCBC",
        fg1: "#CAD8D9",
        dim0: "#72898F",
        red: "#FA5750",
        blue: "#4695F7",
        cursor: "#ADBCBC",
        selectionBg: "#325B6680",
        ansi16: [
          "#174956", "#FA5750", "#75B938", "#DBB32D",
          "#4695F7", "#F275BE", "#41C7B9", "#72898F",
          "#325B66", "#FF665C", "#84C747", "#EBC13D",
          "#58A3FF", "#FF84CD", "#53D6C7", "#CAD8D9",
        ]))
  }

  private func encode(_ file: TerminalThemeFile) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try! encoder.encode(file)
  }

  private func writeValidTheme(to url: URL, name: String) throws {
    try encode(validThemeFile(name: name)).write(to: url)
  }

  private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
  }
}
