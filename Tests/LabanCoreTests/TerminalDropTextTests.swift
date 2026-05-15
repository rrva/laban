import LabanCore
import XCTest

final class TerminalDropTextTests: XCTestCase {
  func testFormatsSinglePathWithSpacesAndTrailingSpace() {
    XCTAssertEqual(
      TerminalDropText.format(paths: ["/tmp/file with spaces.pdf"]),
      "'/tmp/file with spaces.pdf' "
    )
  }

  func testFormatsSingleQuoteInPath() {
    XCTAssertEqual(
      TerminalDropText.format(paths: ["/tmp/it isn't.png"]),
      "'/tmp/it isn'\\''t.png' "
    )
  }

  func testFormatsMultiplePathsInOrder() {
    XCTAssertEqual(
      TerminalDropText.format(paths: ["/tmp/a.png", "/tmp/file with spaces.pdf"]),
      "'/tmp/a.png' '/tmp/file with spaces.pdf' "
    )
  }

  func testEmptyPathsReturnEmptyText() {
    XCTAssertEqual(TerminalDropText.format(paths: []), "")
    XCTAssertEqual(TerminalDropText.format(paths: [""]), "")
  }
}
