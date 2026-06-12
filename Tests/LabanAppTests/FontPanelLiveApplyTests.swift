import AppKit
import CoreText
import LabanRenderer
import XCTest

@testable import LabanApp

final class FontPanelLiveApplyTests: XCTestCase {
  func testDefaultInstallFontPanelSeedsFromActiveRendererFont() throws {
    let activeAtlas = FontAtlas(pointSize: 14, fontName: nil)
    let descriptor = CTFontCopyFontDescriptor(activeAtlas.font) as NSFontDescriptor
    let activeFont = try XCTUnwrap(NSFont(descriptor: descriptor, size: 14))

    let current = AppDelegate.currentFontForFontPanel(
      activeFont: activeFont,
      persistedName: nil,
      size: 14)

    XCTAssertEqual(current.fontName, activeFont.fontName)
    XCTAssertNotEqual(current.fontName, "Menlo-Regular")
  }

  func testSizeOnlySelectionDoesNotRequireRestart() throws {
    let selected = try XCTUnwrap(NSFont(name: "Menlo", size: 20))

    XCTAssertFalse(
      AppDelegate.fontFamilyChanged(
        activeFontPostScriptName: selected.fontName,
        selectedFont: selected))
  }

  func testDifferentFamilyRequiresRestart() throws {
    let active = try XCTUnwrap(NSFont(name: "Menlo", size: 14))
    let selected = try XCTUnwrap(NSFont(name: "Helvetica", size: 14))
    guard active.fontName != selected.fontName else {
      throw XCTSkip("could not resolve distinct probe fonts")
    }

    XCTAssertTrue(
      AppDelegate.fontFamilyChanged(
        activeFontPostScriptName: active.fontName,
        selectedFont: selected))
  }
}
