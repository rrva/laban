import AppKit
import LabanRenderer
import XCTest

@testable import LabanApp

final class TerminalFindChipViewThemeTests: XCTestCase {
  func testFindChipAdaptsToThemeChange() {
    let prior = Theme.current
    defer { Theme.apply(prior) }

    Theme.apply(Theme.gruvboxDark)
    let chip = TerminalFindChipView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    chip.layoutSubtreeIfNeeded()

    let chrome = chip.themeChromeForTesting()
    XCTAssertEqual(chrome.counterText, Self.themedNSColor(Theme.gruvboxDark.fg0))
    XCTAssertEqual(chrome.searchText, Self.themedNSColor(Theme.gruvboxDark.fg1))
    XCTAssertEqual(chrome.searchBackground, Self.themedNSColor(Theme.gruvboxDark.bg1))
    XCTAssertTrue(
      Self.cgColorsEqual(
        chrome.background, Self.themedCGColor(Theme.gruvboxDark.bg2, alpha: 0.94)))
    XCTAssertTrue(
      Self.cgColorsEqual(
        chrome.border, Self.themedCGColor(Theme.gruvboxDark.dim0, alpha: 0.55)))
  }

  func testFindChipUpdatesWhenThemeChanges() {
    let prior = Theme.current
    defer { Theme.apply(prior) }

    Theme.apply(Theme.selenizedDark)
    let chip = TerminalFindChipView(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
    chip.layoutSubtreeIfNeeded()

    Theme.apply(Theme.catppuccinLatte)
    let chrome = chip.themeChromeForTesting()
    XCTAssertEqual(chrome.counterText, Self.themedNSColor(Theme.catppuccinLatte.fg0))
    XCTAssertEqual(chrome.searchText, Self.themedNSColor(Theme.catppuccinLatte.fg1))
    XCTAssertTrue(
      Self.cgColorsEqual(
        chrome.background, Self.themedCGColor(Theme.catppuccinLatte.bg2, alpha: 0.94)))
  }

  private static func themedNSColor(_ rgba: UInt32) -> NSColor {
    NSColor(
      red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
      green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
      blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
      alpha: 1)
  }

  private static func themedCGColor(_ rgba: UInt32, alpha: CGFloat) -> CGColor {
    CGColor(
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      components: [
        CGFloat((rgba >> 24) & 0xFF) / 255.0,
        CGFloat((rgba >> 16) & 0xFF) / 255.0,
        CGFloat((rgba >> 8) & 0xFF) / 255.0,
        alpha,
      ])!
  }

  private static func cgColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    guard let lhs, let rhs, let lc = lhs.components, let rc = rhs.components else {
      return lhs == nil && rhs == nil
    }
    guard lc.count == rc.count else { return false }
    for i in 0..<lc.count where abs(lc[i] - rc[i]) > 0.001 { return false }
    return true
  }
}
