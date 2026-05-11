import XCTest

@testable import LabanCore
@testable import LabanRenderer

final class ThemePaletteInjectorTests: XCTestCase {
  func testPaletteBytesEncodeAnsiAndDefaultSlots() {
    let text = String(
      decoding: ThemePaletteInjector.paletteBytes(for: Theme.selenizedDark),
      as: UTF8.self)

    XCTAssertTrue(text.hasPrefix("\u{1B}]4;0;#174956\u{07}"))
    XCTAssertTrue(text.contains("\u{1B}]4;15;#cad8d9\u{07}"))
    XCTAssertTrue(text.contains("\u{1B}]10;#adbcbc\u{07}"))
    XCTAssertTrue(text.contains("\u{1B}]11;#103c48\u{07}"))
    XCTAssertTrue(text.contains("\u{1B}]12;#adbcbc\u{07}"))
    XCTAssertEqual(text.filter { $0 == "\u{07}" }.count, 19)
  }
}
