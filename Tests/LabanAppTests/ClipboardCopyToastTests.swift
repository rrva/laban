import AppKit
import XCTest

@testable import LabanApp

final class ClipboardCopyToastTests: XCTestCase {
  func testMessageNamesTheCopiedSize() {
    let message = ClipboardCopyToastView.message(forByteCount: 1_200)
    XCTAssertTrue(
      message.contains(
        ByteCountFormatter.string(fromByteCount: 1_200, countStyle: .file)), message)
    XCTAssertFalse(message.contains("%@"), message)
  }

  @MainActor
  func testShowSetsMessageAndBecomesVisibleWithoutTakingClicks() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let toast = ClipboardCopyToastView(frame: .zero)
    container.addSubview(toast)

    toast.show(byteCount: 5, in: container.bounds)

    XCTAssertFalse(toast.isHidden)
    XCTAssertEqual(toast.message, ClipboardCopyToastView.message(forByteCount: 5))
    XCTAssertEqual(toast.frame.midX, container.bounds.midX, accuracy: 0.5)
    XCTAssertNil(toast.hitTest(NSPoint(x: toast.frame.midX, y: toast.frame.midY)))
  }
}
