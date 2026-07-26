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

  /// Selects a CJK preference in the per-process registration domain instead
  /// of `CJKFontSettings.set`, which persists.
  ///
  /// `TerminalCJKFontPolicy` reads this from `UserDefaults.standard`, so these
  /// tests cannot be handed a private suite. Persisting the key made it
  /// visible to every concurrently running test process, which is why
  /// `CJKFontSettingsTests` failed intermittently under `--parallel` despite
  /// touching no shared state of its own. See
  /// `execplans/active/test-userdefaults-isolation.md`.
  fileprivate static func registerPreference(_ preference: CJKFontPreference) {
    UserDefaults.standard.register(defaults: [CJKFontSettings.defaultsKey: preference.rawValue])
  }

  fileprivate static func registerCustom(postScriptName: String) {
    UserDefaults.standard.register(defaults: [
      CJKFontSettings.defaultsKey: CJKFontPreference.custom.rawValue,
      CJKFontSettings.customPostScriptNameKey: postScriptName,
    ])
  }

  func testFallbackOrderPutsUserPreferenceFirst() {
    Self.registerPreference(.sarasaTermSC)
    XCTAssertEqual(TerminalCJKFontPolicy.fallbackOrderDescription[1], "Sarasa Term SC")
    Self.registerPreference(.pingFangSC)
    XCTAssertEqual(TerminalCJKFontPolicy.fallbackOrderDescription[1], "PingFang SC")
  }

  func testPingFangIsAvailableOnMacOS() {
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    XCTAssertTrue(TerminalCJKFontPolicy.isAvailable(.pingFangSC, baseFont: baseFont))
  }

  func testCustomFontIsPreferredInCascade() throws {
    let baseFont = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    guard
      let presetFont = TerminalCJKFontPolicy.resolvedPresetFont(.pingFangSC, baseFont: baseFont)
    else {
      throw XCTSkip("PingFang SC unavailable")
    }
    let postScriptName = CTFontCopyPostScriptName(presetFont) as String
    Self.registerCustom(postScriptName: postScriptName)
    let selected = TerminalCJKFontPolicy.resolvedPreferenceFont(baseFont: baseFont)
    XCTAssertEqual(CTFontCopyPostScriptName(selected ?? baseFont) as String, postScriptName)
  }

  func testUserStatusReportsMissingPreference() {
    Self.registerPreference(.sarasaTermSC)
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
