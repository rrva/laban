import AppKit
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp
@testable import LabanCore

/// Sidebar visibility is window chrome, so it lives in View — where macOS puts
/// it (Finder ▸ View ▸ Show Sidebar, ⌃⌘S) — rather than in Settings. It is
/// deliberately in exactly one place in the UI: two controls over one boolean is
/// a stale-checkmark bug waiting to happen.
final class SidebarMenuToggleTests: XCTestCase {

  /// `setupMenuBar()` installs into the shared `NSApplication`, so the menu
  /// assertions share one setup that restores the app's menus afterwards —
  /// the pattern `TerminalKeyInputTests` uses. Calling it per test method
  /// re-registers the windows/help menus and traps.
  func testViewMenuCarriesTheSidebarToggleWithThePlatformShortcut() throws {
    let app = NSApplication.shared
    let oldMainMenu = app.mainMenu
    let oldWindowsMenu = app.windowsMenu
    let oldHelpMenu = app.helpMenu
    defer {
      app.mainMenu = oldMainMenu
      app.windowsMenu = oldWindowsMenu
      app.helpMenu = oldHelpMenu
    }

    MenuCommands.setupMenuBar()
    let viewMenu = try XCTUnwrap(app.mainMenu?.item(withTitle: "View")?.submenu)
    let item = try XCTUnwrap(
      viewMenu.items.first {
        $0.action == #selector(TerminalBitmapView.toggleSidebarVisible(_:))
      },
      "View must offer a sidebar toggle")

    XCTAssertEqual(item.title, "Show Sidebar")
    // ⌃⌘S is what Finder uses for the same action.
    XCTAssertEqual(item.keyEquivalent, "s")
    XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .control])

    // …and it must not collide with anything else in View (full screen is ⌃⌘F).
    let chords = viewMenu.items
      .filter { !$0.keyEquivalent.isEmpty }
      .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
    XCTAssertEqual(
      chords.count, Set(chords).count, "two View items share a key chord: \(chords)")
  }

  /// Validation drives the checkmark, so it always reflects the live setting
  /// rather than a copy that can drift out of step with it.
  func testValidationChecksTheItemFromTheLiveSetting() throws {
    let view = try makeTerminalView()
    let item = NSMenuItem(
      title: "Show Sidebar",
      action: #selector(TerminalBitmapView.toggleSidebarVisible(_:)),
      keyEquivalent: "")
    defer { SidebarVisibilitySettings.setVisible(true) }

    SidebarVisibilitySettings.setVisible(true)
    XCTAssertTrue(view.validateMenuItem(item))
    XCTAssertEqual(item.state, .on)

    SidebarVisibilitySettings.setVisible(false)
    _ = view.validateMenuItem(item)
    XCTAssertEqual(item.state, .off)
  }

  func testToggleFlipsTheSetting() throws {
    let view = try makeTerminalView()
    defer { SidebarVisibilitySettings.setVisible(true) }

    SidebarVisibilitySettings.setVisible(true)
    view.toggleSidebarVisible(nil)
    XCTAssertFalse(SidebarVisibilitySettings.visible)
    view.toggleSidebarVisible(nil)
    XCTAssertTrue(SidebarVisibilitySettings.visible)
  }

  /// Launching with the sidebar already hidden must not draw a sidebar that
  /// hit-testing ignores: the drawn width and the hit-test width start equal.
  func testLaunchingWithTheSidebarHiddenDrawsNoSidebar() throws {
    defer { SidebarVisibilitySettings.setVisible(true) }
    SidebarVisibilitySettings.setVisible(false)

    let widths = try makeTerminalView().sidebarWidthsForTesting
    XCTAssertEqual(widths.hitTest, 0)
    XCTAssertEqual(widths.drawn, 0)
  }

  private func makeTerminalView() throws -> TerminalBitmapView {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let fontAtlas = FontAtlas(pointSize: 14)
    return TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: FontAtlas(pointSize: 11),
      cellWidth: Int(fontAtlas.cellSize.width),
      cellHeight: Int(fontAtlas.cellSize.height))
  }
}
