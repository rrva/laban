import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class FrameProducerTransparencyTests: XCTestCase {
  private let defaultBackground: UInt32 = 0x11_22_33_FF
  private let explicitBackground: UInt32 = 0xCC_22_11_FF
  private let inverseBackground: UInt32 = 0x22_44_CC_FF

  func testRemoteCanvasInheritedAndExplicitBackgroundSemantics() throws {
    let producer = FrameProducer(
      cellWidth: 8,
      cellHeight: 16,
      backgroundCompositingOptions: TerminalBackgroundCompositingOptions(
        opacity: 128,
        applyToExplicitCellBackgrounds: false))
    let commands = producer.commands(from: snapshot())

    let terminalRects = commands.compactMap { command -> (CGRect, UInt32, FrameCompositingMode)? in
      guard case .rect(let rect, let color, .terminal, let compositing) = command else {
        return nil
      }
      return (rect, color, compositing)
    }
    XCTAssertEqual(terminalRects.first?.1, withAlpha(defaultBackground, 128))
    XCTAssertEqual(terminalRects.first?.2, .replace)
    XCTAssertTrue(
      terminalRects.contains { $0.1 == explicitBackground && $0.2 == .replace },
      "explicit backgrounds must remain opaque and use replace")
    XCTAssertTrue(
      terminalRects.contains { $0.1 == inverseBackground && $0.2 == .replace },
      "inverse backgrounds must remain opaque and use replace")

    let glyphBackgroundPairs: [(String, UInt32?)] = commands.compactMap { command in
      guard case .glyphRun(_, let text, _, let background, _, .terminal, _, _, _, _) = command
      else { return nil }
      return (text, background)
    }
    let glyphBackgrounds = Dictionary(uniqueKeysWithValues: glyphBackgroundPairs)
    XCTAssertEqual(glyphBackgrounds["D"], withAlpha(defaultBackground, 128))
    XCTAssertEqual(glyphBackgrounds["E"], explicitBackground)
    XCTAssertEqual(glyphBackgrounds["I"], inverseBackground)
  }

  func testExplicitThemeEqualBackgroundStillEstablishesOpaquePixels() {
    var value = snapshot()
    value.cells[1].backgroundRGBA = defaultBackground

    let commands = FrameProducer(
      backgroundCompositingOptions: TerminalBackgroundCompositingOptions(
        opacity: 96,
        applyToExplicitCellBackgrounds: false)
    ).commands(from: value)

    XCTAssertTrue(commands.contains { command in
      guard case .rect(let rect, let color, .terminal, .replace) = command else { return false }
      return rect.origin.x == 8 && color == defaultBackground
    })
  }

  func testExplicitBackgroundOptInUsesEffectiveAlpha() {
    let commands = FrameProducer(
      backgroundCompositingOptions: TerminalBackgroundCompositingOptions(
        opacity: 77,
        applyToExplicitCellBackgrounds: true)
    ).commands(from: snapshot())

    let colors = commands.compactMap { command -> UInt32? in
      guard case .rect(_, let color, .terminal, .replace) = command else { return nil }
      return color
    }
    XCTAssertTrue(colors.contains(withAlpha(explicitBackground, 77)))
    XCTAssertTrue(colors.contains(withAlpha(inverseBackground, 77)))
  }

  func testPreeditBackingRemainsOpaqueAndSourceOver() {
    let commands = FrameProducer(
      cellWidth: 8,
      cellHeight: 16,
      backgroundCompositingOptions: TerminalBackgroundCompositingOptions(
        opacity: 64,
        applyToExplicitCellBackgrounds: true)
    ).commands(from: snapshot(), preedit: "中", preeditCaretCells: 2)

    let preeditRect = commands.first { command in
      if case .rect(_, _, .preedit, _) = command { return true }
      return false
    }
    guard case .rect(_, let color, .preedit, let compositing)? = preeditRect else {
      return XCTFail("expected preedit backing rectangle")
    }
    XCTAssertEqual(color & 0xFF, 0xFF)
    XCTAssertEqual(compositing, .sourceOver)
  }

  func testRectDefaultRemainsSourceOverForSemanticCallers() {
    let command = FrameCommand.rect(.zero, color: 0xFFFF_FFFF, source: .chrome)
    guard case .rect(_, _, _, let compositing) = command else {
      return XCTFail("expected rectangle")
    }
    XCTAssertEqual(compositing, .sourceOver)
  }

  private func snapshot() -> LabandSnapshotResponse {
    let explicit = UInt16(LABAN_CELL_FLAG_EXPLICIT_BACKGROUND)
    return LabandSnapshotResponse(
      logicalSessionId: "transparency",
      incarnationId: "1",
      rows: 1,
      cols: 3,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: false,
      visibleText: "DEI",
      cells: [
        LabandSnapshotCell(
          row: 0, col: 0, text: "D", flags: 0,
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: defaultBackground),
        LabandSnapshotCell(
          row: 0, col: 1, text: "E", flags: explicit,
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: explicitBackground),
        LabandSnapshotCell(
          row: 0, col: 2, text: "I",
          flags: explicit | UInt16(LABAN_CELL_FLAG_INVERSE),
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: inverseBackground),
      ],
      defaultBackgroundRGBA: defaultBackground)
  }

  private func withAlpha(_ color: UInt32, _ alpha: UInt8) -> UInt32 {
    (color & 0xFFFF_FF00) | UInt32(alpha)
  }
}
