import LabanCore
import XCTest

@testable import LabanApp

final class TerminalInputCaptureMetadataTests: XCTestCase {
  func testEncodedMetadataOmitsEmptyBytes() {
    XCTAssertNil(TerminalInputCaptureMetadata.encodedHex([]))
    XCTAssertNil(TerminalInputCaptureMetadata.encodedLength([]))
  }

  func testEncodedMetadataFormatsLowercaseHexAndLength() {
    let bytes: [UInt8] = [0x00, 0x0f, 0xa0, 0xff]

    XCTAssertEqual(TerminalInputCaptureMetadata.encodedHex(bytes), "000fa0ff")
    XCTAssertEqual(TerminalInputCaptureMetadata.encodedLength(bytes), 4)
  }

  func testModifierNamesUseCaptureVocabularyAndOrder() {
    let names = TerminalInputCaptureMetadata.modifierNames([
      .command, .shift, .capsLock, .alt, .control,
    ])

    XCTAssertEqual(names, ["shift", "control", "option", "command", "capsLock"])
    XCTAssertNil(TerminalInputCaptureMetadata.modifierNames([]))
  }

  func testAppCommandCaptureNamesAreStable() {
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .newTab), "newTab")
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .closeTab), "closeTab")
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .selectTab(index: 3)), "selectTab")
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .copy), "copy")
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .paste), "paste")
    XCTAssertEqual(TerminalInputCaptureMetadata.captureName(for: .find), "find")
    XCTAssertEqual(
      TerminalInputCaptureMetadata.captureName(for: .dumpRenderJournal),
      "dumpRenderJournal")
    XCTAssertEqual(
      TerminalInputCaptureMetadata.captureName(for: .increaseFontSize),
      "increaseFontSize")
    XCTAssertEqual(
      TerminalInputCaptureMetadata.captureName(for: .decreaseFontSize),
      "decreaseFontSize")
    XCTAssertEqual(
      TerminalInputCaptureMetadata.captureName(for: .resetFontSize),
      "resetFontSize")
  }
}
