import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalCapabilitySelfTestTests: XCTestCase {
  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
  }

  func testEveryProbePassesWithKittyGraphicsEnabled() throws {
    laban_set_kitty_graphics_enabled(true)
    let results = try XCTUnwrap(TerminalCapabilitySelfTest.run())
    XCTAssertEqual(results.count, 10)
    for result in results {
      XCTAssertEqual(result.status, .passed, "\(result.name): \(result.reply)")
    }
  }

  func testKittyGraphicsReportsDisabledWhenSwitchedOff() throws {
    laban_set_kitty_graphics_enabled(false)
    let results = try XCTUnwrap(TerminalCapabilitySelfTest.run())
    let graphics = try XCTUnwrap(results.first { $0.name.contains("Kitty graphics") })
    XCTAssertEqual(graphics.status, .disabled)
    XCTAssertEqual(graphics.reply, "no reply")
  }

  func testRepliesAreSpelledOut() {
    XCTAssertEqual(TerminalCapabilitySelfTest.visible("\u{1b}[?1;1R"), "ESC [?1;1R")
    XCTAssertEqual(
      TerminalCapabilitySelfTest.visible("\u{1b}]11;rgb:0000/0000/0000\u{07}"),
      "ESC ]11;rgb:0000/0000/0000 BEL")
  }
}
