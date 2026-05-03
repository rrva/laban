import AppKit
import XCTest

@testable import LabanApp

final class TerminalKeyEncoderTests: XCTestCase {
  func testMousePositionUsesTerminalSurfacePixels() {
    let pos = TerminalMouseInput.surfacePosition(
      viewPoint: NSPoint(x: 360, y: 400),
      boundsHeight: 480,
      sidebarWidth: 200
    )

    XCTAssertEqual(pos.x, 160)
    XCTAssertEqual(pos.y, 80)
  }

  func testMouseSurfaceSizeExcludesSidebar() {
    let size = TerminalMouseInput.surfaceSize(
      boundsWidth: 1000,
      boundsHeight: 480,
      sidebarWidth: 200
    )

    XCTAssertEqual(size.width, 800)
    XCTAssertEqual(size.height, 480)
  }

  func testMouseModifiersUseGhosttyBitOrder() {
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .shift), 1)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .control), 2)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .option), 4)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .command), 8)
    XCTAssertEqual(
      TerminalMouseInput.ghosttyModifierMask(from: [.shift, .control, .option, .command]),
      15
    )
  }

  func testControlCProducedCharacterSendsETX() {
    XCTAssertEqual(
      TerminalKeyEncoder.bytes(
        forControlModifiedCharacters: "\u{3}",
        charactersIgnoringModifiers: "c",
        modifierFlags: .control
      ),
      [0x03]
    )
  }

  func testControlCBaseCharacterFallbackSendsETX() {
    XCTAssertEqual(
      TerminalKeyEncoder.bytes(
        forControlModifiedCharacters: nil,
        charactersIgnoringModifiers: "c",
        modifierFlags: .control
      ),
      [0x03]
    )
  }

  func testCommandCDoesNotBecomeTerminalControlByte() {
    XCTAssertNil(
      TerminalKeyEncoder.bytes(
        forControlModifiedCharacters: nil,
        charactersIgnoringModifiers: "c",
        modifierFlags: [.command, .control]
      )
    )
  }

  func testOptionControlDoesNotBypassNativeTextInput() {
    XCTAssertNil(
      TerminalKeyEncoder.bytes(
        forControlModifiedCharacters: nil,
        charactersIgnoringModifiers: "c",
        modifierFlags: [.option, .control]
      )
    )
  }

  func testOptionLetterSendsEscapePrefixedMeta() {
    XCTAssertEqual(
      TerminalKeyEncoder.bytes(
        forOptionMetaCharactersIgnoringModifiers: "p",
        modifierFlags: .option
      ),
      [0x1B, 0x70]
    )
  }

  func testOptionShiftLetterPreservesCase() {
    XCTAssertEqual(
      TerminalKeyEncoder.bytes(
        forOptionMetaCharactersIgnoringModifiers: "P",
        modifierFlags: [.option, .shift]
      ),
      [0x1B, 0x50]
    )
  }

  func testOptionDigitFallsThroughToNativeTextInput() {
    XCTAssertNil(
      TerminalKeyEncoder.bytes(
        forOptionMetaCharactersIgnoringModifiers: "4",
        modifierFlags: .option
      )
    )
  }

  func testCommandOptionLetterDoesNotBecomeTerminalMeta() {
    XCTAssertNil(
      TerminalKeyEncoder.bytes(
        forOptionMetaCharactersIgnoringModifiers: "p",
        modifierFlags: [.command, .option]
      )
    )
  }

  func testControlBracketSendsEscape() {
    XCTAssertEqual(
      TerminalKeyEncoder.bytes(
        forControlModifiedCharacters: nil,
        charactersIgnoringModifiers: "[",
        modifierFlags: .control
      ),
      [0x1B]
    )
  }

  func testTabBytes() {
    XCTAssertEqual(TerminalKeyEncoder.tabBytes, [0x09])
  }

  func testBacktabBytes() {
    XCTAssertEqual(TerminalKeyEncoder.backtabBytes, [0x1B, 0x5B, 0x5A])
  }
}
