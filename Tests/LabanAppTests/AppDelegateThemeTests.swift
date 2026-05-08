import AppKit
import LabanRenderer
import XCTest

@testable import LabanApp

final class AppDelegateThemeTests: XCTestCase {

  override func tearDown() {
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
}
