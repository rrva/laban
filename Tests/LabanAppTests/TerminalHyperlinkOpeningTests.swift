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
      TerminalBitmapView.externalBrowserURL(from: "https://example.com/docs")?.absoluteString,
      "https://example.com/docs")
    XCTAssertNotNil(TerminalBitmapView.externalBrowserURL(from: "HTTP://example.com"))

    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "ftp://example.com/file"))
    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "file:///tmp/example"))
    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "mailto:dev@example.com"))
    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "javascript:alert(1)"))
    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "https://"))
    XCTAssertNil(TerminalBitmapView.externalBrowserURL(from: "example.com"))
  }

  func testOpenExternalHyperlinkUsesInjectedOpener() {
    let opener = RecordingOpener()

    XCTAssertTrue(
      TerminalBitmapView.openExternalHyperlink("https://example.com/docs", using: opener))
    XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs"])

    XCTAssertFalse(
      TerminalBitmapView.openExternalHyperlink("file:///tmp/example", using: opener))
    XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/docs"])
  }

  func testHoverCursorStyleUsesPointingHandForExternalHyperlinks() {
    XCTAssertEqual(
      TerminalBitmapView.hoverCursorStyle(externalHyperlinkURI: "https://example.com"),
      .pointingHand)
    XCTAssertEqual(
      TerminalBitmapView.hoverCursorStyle(externalHyperlinkURI: nil),
      .arrow)
  }
}
