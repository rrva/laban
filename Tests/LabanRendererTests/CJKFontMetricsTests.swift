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
