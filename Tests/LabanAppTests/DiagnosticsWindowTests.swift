import AppKit
import XCTest

@testable import LabanApp

final class DiagnosticsWindowTests: XCTestCase {
  func testThemeSummaryNamesTheAppearance() {
    let dark = DiagnosticsWindowController.themeSummary(appearance: NSAppearance(named: .darkAqua)!)
    XCTAssertTrue(dark.contains("dark mode"), dark)
    let light = DiagnosticsWindowController.themeSummary(appearance: NSAppearance(named: .aqua)!)
    XCTAssertTrue(light.contains("light mode"), light)
  }

  func testDisplaySummaryWithoutAScreen() {
    XCTAssertEqual(DiagnosticsWindowController.displaySummary(for: nil), "No display")
  }
}
