import AppKit
import XCTest

@testable import LabanApp

final class TerminalKeyEncoderTests: XCTestCase {
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
