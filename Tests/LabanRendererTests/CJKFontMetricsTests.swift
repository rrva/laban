import CoreText
import Metal
import XCTest

@testable import LabanRenderer

final class CJKFontMetricsTests: XCTestCase {
  func testPolicySelectsSystemCJKFontBeforeCoreTextCascade() {
    let fontAtlas = FontAtlas(pointSize: 14, fontName: "Helvetica")
    let diagnostics = fontAtlas.cjkFontDiagnostics

    XCTAssertTrue(diagnostics.glyphAvailable)
    XCTAssertFalse(diagnostics.selectedFontPostScriptName.isEmpty)
    XCTAssertFalse(diagnostics.selectedFamilyName.isEmpty)
    XCTAssertTrue(
      diagnostics.selectedFontPostScriptName.contains("PingFang")
        || diagnostics.selectedFamilyName.contains("PingFang")
        || diagnostics.selectedFontPostScriptName.contains("Noto")
        || diagnostics.selectedFontPostScriptName.contains("Sarasa"),
      "CJK policy should select an explicit CJK candidate, not \(diagnostics.selectedFontPostScriptName)"
    )
    XCTAssertEqual(diagnostics.fallbackOrder.first, "primary terminal font")
    XCTAssertEqual(diagnostics.fallbackOrder.last, "CoreText cascade")
  }

  func testFallbackOrderPutsUserPreferenceFirst() {
    let saved = UserDefaults.standard.string(forKey: CJKFontSettings.defaultsKey)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: CJKFontSettings.defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: CJKFontSettings.defaultsKey)
      }
    }

    CJKFontSettings.set(.sarasaTermSC)
    XCTAssertEqual(TerminalCJKFontPolicy.fallbackOrderDescription[1], "Sarasa Term SC")
    CJKFontSettings.set(.pingFangSC)
    XCTAssertEqual(TerminalCJKFontPolicy.fallbackOrderDescription[1], "PingFang SC")
  }

  func testPingFangIsAvailableOnMacOS() {
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    XCTAssertTrue(TerminalCJKFontPolicy.isAvailable(.pingFangSC, baseFont: baseFont))
  }

  func testCustomFontIsPreferredInCascade() throws {
    let savedPreference = UserDefaults.standard.string(forKey: CJKFontSettings.defaultsKey)
    let savedCustom = UserDefaults.standard.string(forKey: CJKFontSettings.customPostScriptNameKey)
    defer {
      if let savedPreference {
        UserDefaults.standard.set(savedPreference, forKey: CJKFontSettings.defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: CJKFontSettings.defaultsKey)
      }
      if let savedCustom {
        UserDefaults.standard.set(savedCustom, forKey: CJKFontSettings.customPostScriptNameKey)
      } else {
        UserDefaults.standard.removeObject(forKey: CJKFontSettings.customPostScriptNameKey)
      }
    }

    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    guard
      let presetFont = TerminalCJKFontPolicy.resolvedPresetFont(.pingFangSC, baseFont: baseFont)
    else {
      throw XCTSkip("PingFang SC unavailable")
    }
    let postScriptName = CTFontCopyPostScriptName(presetFont) as String
    CJKFontSettings.setCustom(postScriptName: postScriptName)
    let selected = TerminalCJKFontPolicy.resolvedPreferenceFont(baseFont: baseFont)
    XCTAssertEqual(CTFontCopyPostScriptName(selected ?? baseFont) as String, postScriptName)
  }

  func testUserStatusReportsMissingPreference() {
    let saved = UserDefaults.standard.string(forKey: CJKFontSettings.defaultsKey)
    defer {
      if let saved {
        UserDefaults.standard.set(saved, forKey: CJKFontSettings.defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: CJKFontSettings.defaultsKey)
      }
    }

    CJKFontSettings.set(.sarasaTermSC)
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let status = TerminalCJKFontPolicy.userStatus(baseFont: baseFont, cellWidth: 9)
    if TerminalCJKFontPolicy.isAvailable(.sarasaTermSC, baseFont: baseFont) {
      XCTAssertFalse(status.isDegraded)
    } else {
      XCTAssertTrue(status.isDegraded)
      XCTAssertTrue(status.message.contains("Not installed: Sarasa Term SC"))
      XCTAssertTrue(status.message.contains("Using "))
    }
  }

  func testHanziInkTileStaysInsideTwoTerminalCells() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }

    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let cellWidth: CGFloat = 9
    guard
      let atlas = MetalGlyphAtlas(
        device: device,
        cellWidth: cellWidth,
        cellHeight: 19,
        descent: 4,
        scale: 1,
        textureSize: 128)
    else {
      XCTFail("MetalGlyphAtlas.init returned nil")
      return
    }

    let entry = try XCTUnwrap(
      atlas.entry(character: "界", font: baseFont, boldFallback: false, italicFallback: false))
    XCTAssertEqual(entry.logicalOriginX, 0, accuracy: 0.001)
    XCTAssertEqual(entry.logicalWidth, cellWidth * 2, accuracy: 0.001)
    XCTAssertLessThanOrEqual(
      entry.pixelWidth,
      Int((cellWidth * 2).rounded(.up)),
      "CJK atlas entries must not reserve more than the two cells assigned by the terminal core")
  }

  func testCJKMetricPlanScalesDownOversizedFallbacks() throws {
    let plan = TerminalCJKFontPolicy.cjkMetricPlan(
      text: "語",
      cellWidth: 9,
      layoutWidth: 24,
      inkBounds: CGRect(x: 0, y: 0, width: 24, height: 18))

    let unwrapped = try XCTUnwrap(plan)
    XCTAssertEqual(unwrapped.targetWidth, 18, accuracy: 0.001)
    XCTAssertEqual(unwrapped.scaleX, 0.75, accuracy: 0.001)
  }
}
