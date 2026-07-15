import LabanCore
import XCTest

@testable import LabanAgent

final class TransparencyArgumentTests: XCTestCase {
  func testBackgroundEffectDefaultsToNone() {
    let args = parseArgs([])

    XCTAssertEqual(args.backgroundEffect, .none)
    XCTAssertNil(args.argumentError)
  }

  func testBackgroundEffectAcceptsExactDocumentedValues() {
    let none = parseArgs(["--background-effect=none"])
    XCTAssertEqual(none.backgroundEffect, .none)
    XCTAssertNil(none.argumentError)

    let systemBlur = parseArgs(["--background-effect=system-blur"])
    XCTAssertEqual(systemBlur.backgroundEffect, .systemBlur)
    XCTAssertNil(systemBlur.argumentError)
  }

  func testBackgroundEffectRejectsUndocumentedSpellings() {
    for spelling in [
      "--background-effect",
      "--background-effect=",
      "--background-effect=blur",
      "--background-effect=systemBlur",
      "--background-effect=SYSTEM-BLUR",
    ] {
      let args = parseArgs([spelling])
      XCTAssertEqual(args.backgroundEffect, .none, spelling)
      XCTAssertEqual(
        args.argumentError,
        "--background-effect must be none or system-blur",
        spelling)
    }
  }

  func testUsageDescribesHeadlessEffectScope() {
    let text = usage()

    XCTAssertTrue(text.contains("--background-effect=MODE"))
    XCTAssertTrue(text.contains("records system-blur but resolves no AppKit material"))
  }
}
