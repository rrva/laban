import Foundation
import LabanCore
import LabanRenderer
import XCTest

@testable import LabanApp
@testable import LabanCore

@MainActor
final class ThemeMenuControllerImportTests: XCTestCase {
  private var roots: [URL] = []
  private var previousAppAppearance: NSAppearance?

  override func setUp() {
    super.setUp()
    previousAppAppearance = NSApplication.shared.appearance
  }

  override func tearDown() {
    for key in [
      "LabanThemeDark", "LabanThemeLight", "LabanThemeCurrent", "LabanThemeFollowsSystem",
    ] {
      UserDefaults.standard.removeObject(forKey: key)
    }
    NSApplication.shared.appearance = previousAppAppearance
    Theme.current = Theme.selenizedDark
    Theme.darkVariant = Theme.selenizedDark
    Theme.lightVariant = Theme.selenizedLight
    Theme.followsSystemAppearance = true
    for root in roots {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }

  func testOrderedThemesIncludeImportedThemes() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("imported.json")
    try writeValidTheme(to: sourceURL, name: "Imported Dark", isDark: true)
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    let controller = ThemeMenuController(themeStore: context.store)
    let themes = controller.orderedThemes

    XCTAssertTrue(themes.contains { $0.name == "Imported Dark" })
    XCTAssertTrue(themes.contains { $0.name == Theme.selenizedDark.name })
    XCTAssertTrue(
      themes.firstIndex(where: { $0.name == "Imported Dark" })! > themes.firstIndex(where: {
        $0.name == Theme.selenizedDark.name
      })!)
  }

  func testApplyImportedThemePersistsAndApplies() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("apply.json")
    try writeValidTheme(to: sourceURL, name: "Apply Me", isDark: true)
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    let controller = ThemeMenuController(themeStore: context.store)
    let index = try XCTUnwrap(controller.orderedThemes.firstIndex { $0.name == "Apply Me" })
    controller.applyTheme(at: index)

    XCTAssertEqual(Theme.current.name, "Apply Me")
    XCTAssertFalse(Theme.followsSystemAppearance)
    XCTAssertEqual(UserDefaults.standard.string(forKey: "LabanThemeCurrent"), "Apply Me")
    XCTAssertEqual(UserDefaults.standard.string(forKey: "LabanThemeDark"), "Apply Me")
  }

  func testLoadPersistedChoicesRestoresImportedTheme() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("persist.json")
    try writeValidTheme(to: sourceURL, name: "Persisted", isDark: false)
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    UserDefaults.standard.set("Persisted", forKey: "LabanThemeCurrent")
    UserDefaults.standard.set("Persisted", forKey: "LabanThemeLight")
    UserDefaults.standard.set(false, forKey: "LabanThemeFollowsSystem")

    let controller = ThemeMenuController(themeStore: context.store)
    controller.loadPersistedChoices()

    XCTAssertEqual(Theme.current.name, "Persisted")
    XCTAssertEqual(Theme.lightVariant.name, "Persisted")
    XCTAssertFalse(Theme.followsSystemAppearance)
  }

  func testRemoveImportedThemeFallsBackToBundled() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("remove.json")
    try writeValidTheme(to: sourceURL, name: "Goner", isDark: true)
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    let controller = ThemeMenuController(themeStore: context.store)
    let index = try XCTUnwrap(controller.orderedThemes.firstIndex { $0.name == "Goner" })
    controller.applyTheme(at: index)
    XCTAssertEqual(Theme.current.name, "Goner")

    try context.store.removeManagedTheme(named: "Goner")
    controller.reloadImportedThemes()

    XCTAssertFalse(controller.orderedThemes.contains { $0.name == "Goner" })
    XCTAssertTrue(controller.orderedThemes.contains { $0.name == Theme.selenizedDark.name })
  }

  func testImportedLightThemeAppearsInLightGroup() throws {
    let context = try makeContext()
    let sourceURL = context.externalURL.appendingPathComponent("light.json")
    try writeValidTheme(to: sourceURL, name: "Imported Light", isDark: false)
    _ = try XCTUnwrap(try context.store.importTheme(from: sourceURL))

    let controller = ThemeMenuController(themeStore: context.store)
    let themes = controller.orderedThemes
    let lightGroupStart = try XCTUnwrap(
      themes.firstIndex(where: { !$0.isDark }))

    XCTAssertTrue(
      themes[lightGroupStart...].contains { $0.name == "Imported Light" })
  }

  // MARK: Helpers

  private struct Context {
    let baseURL: URL
    let externalURL: URL
    let store: TerminalThemeStore
  }

  private func makeContext() throws -> Context {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "laban-theme-menu-tests-\(UUID().uuidString)",
      isDirectory: true)
    roots.append(root)
    let baseURL = root.appendingPathComponent("application-support", isDirectory: true)
    let externalURL = root.appendingPathComponent("external-picker", isDirectory: true)
    try FileManager.default.createDirectory(at: externalURL, withIntermediateDirectories: true)
    return Context(
      baseURL: baseURL,
      externalURL: externalURL,
      store: TerminalThemeStore(baseURL: baseURL))
  }

  private func validThemeFile(name: String, isDark: Bool) -> TerminalThemeFile {
    TerminalThemeFile(
      version: 1,
      name: name,
      isDark: isDark,
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

  private func writeValidTheme(to url: URL, name: String, isDark: Bool) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(validThemeFile(name: name, isDark: isDark))
    try data.write(to: url)
  }
}
