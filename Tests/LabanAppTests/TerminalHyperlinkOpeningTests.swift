import Foundation
import XCTest

@testable import LabanApp

final class TerminalHyperlinkOpeningTests: XCTestCase {
  private final class RecordingOpener: ExternalURLOpening {
    var opened: [URL] = []

    func open(_ url: URL) -> Bool {
      opened.append(url)
      return true
    }
  }

  func testExternalBrowserURLAcceptsHTTPAndHTTPSOnly() {
    XCTAssertEqual(
      TerminalHyperlinkOpening.browserURL(from: "https://example.com/docs")?.absoluteString,
      "https://example.com/docs")
    XCTAssertNotNil(TerminalHyperlinkOpening.browserURL(from: "HTTP://example.com"))

    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "ftp://example.com/file"))
    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "file:///tmp/example"))
    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "mailto:dev@example.com"))
    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "javascript:alert(1)"))
    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "https://"))
    XCTAssertNil(TerminalHyperlinkOpening.browserURL(from: "example.com"))
  }

  func testOpenExternalHyperlinkUsesInjectedOpener() {
    let opener = RecordingOpener()

    XCTAssertTrue(
      TerminalHyperlinkOpening.open("https://example.com/docs", using: opener))
    XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs"])

    XCTAssertFalse(
      TerminalHyperlinkOpening.open("file:///tmp/example", using: opener))
    XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs"])
  }

  func testHoverCursorStyleUsesPointingHandForExternalHyperlinks() {
    XCTAssertEqual(
      TerminalHyperlinkOpening.hoverCursorStyle(
        externalHyperlinkURI: "https://example.com",
        modifierFlags: .command),
      .pointingHand)
    XCTAssertEqual(
      TerminalHyperlinkOpening.hoverCursorStyle(
        externalHyperlinkURI: "https://example.com",
        modifierFlags: []),
      .arrow)
    XCTAssertEqual(
      TerminalHyperlinkOpening.hoverCursorStyle(externalHyperlinkURI: nil, modifierFlags: .command),
      .arrow)
  }

  func testExternalHyperlinkActivationRequiresCommandClick() {
    XCTAssertTrue(
      TerminalHyperlinkOpening.shouldActivate(
        clickCount: 1,
        modifierFlags: .command))
    XCTAssertFalse(
      TerminalHyperlinkOpening.shouldActivate(
        clickCount: 1,
        modifierFlags: []))
    XCTAssertFalse(
      TerminalHyperlinkOpening.shouldActivate(
        clickCount: 2,
        modifierFlags: .command))
  }
}
