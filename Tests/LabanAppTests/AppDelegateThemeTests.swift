import AppKit
import LabanRenderer
import XCTest

@testable import LabanApp

final class AppDelegateThemeTests: XCTestCase {
  private let themeKeys = [
    "LabanThemeDark",
    "LabanThemeLight",
    "LabanThemeCurrent",
    "LabanThemeFollowsSystem",
  ]

  override func tearDown() {
    for key in themeKeys {
      UserDefaults.standard.removeObject(forKey: key)
    }
    Theme.current = Theme.selenizedDark
    Theme.darkVariant = Theme.selenizedDark
    Theme.lightVariant = Theme.selenizedLight
    Theme.followsSystemAppearance = true
    super.tearDown()
  }

  func testInitialThemeCanBePrimedBeforeTerminalSessionCreation() throws {
    Theme.current = Theme.selenizedDark
    Theme.followsSystemAppearance = true

    let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
    AppDelegate.applyTheme(for: lightAppearance)

    XCTAssertEqual(Theme.current, Theme.selenizedLight)
  }

  func testInitialThemePrimingRespectsManualThemeMode() throws {
    Theme.current = Theme.gruvboxDark
    Theme.followsSystemAppearance = false

    let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
    AppDelegate.applyTheme(for: lightAppearance)

    XCTAssertEqual(Theme.current, Theme.gruvboxDark)
  }

  func testManualThemeSelectionPersistsAsCurrentThemeAcrossLaunch() throws {
    Theme.current = Theme.selenizedLight
    Theme.followsSystemAppearance = true
    let controller = ThemeMenuController()
    let items = controller.makeMenuItems()
    let selenizedDarkItem = try XCTUnwrap(
      items.first { item in
        item.action == #selector(ThemeMenuController.selectTheme(_:))
          && item.title == Theme.selenizedDark.name
      })

    controller.selectTheme(selenizedDarkItem)

    XCTAssertFalse(Theme.followsSystemAppearance)
    XCTAssertEqual(Theme.current, Theme.selenizedDark)

    Theme.current = Theme.selenizedLight
    Theme.darkVariant = Theme.dracula
    Theme.lightVariant = Theme.catppuccinLatte
    Theme.followsSystemAppearance = true

    controller.loadPersistedChoices()
    let lightAppearance = try XCTUnwrap(NSAppearance(named: .aqua))
    AppDelegate.applyTheme(for: lightAppearance)

    XCTAssertFalse(Theme.followsSystemAppearance)
    XCTAssertEqual(Theme.current, Theme.selenizedDark)
  }
}
