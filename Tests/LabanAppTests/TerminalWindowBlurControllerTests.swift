import AppKit
import XCTest

@testable import LabanApp

@MainActor
final class TerminalWindowBlurControllerTests: XCTestCase {
  func testInjectedSetterReceivesClampedRadiusAndWindowNumber() {
    let window = makeWindow()
    var calls: [(windowNumber: Int, radius: Int32)] = []
    let controller = TerminalWindowBlurController { windowNumber, radius in
      calls.append((windowNumber, radius))
      return 0
    }

    XCTAssertTrue(controller.isAvailable)
    XCTAssertTrue(controller.apply(radius: -4, to: window))
    XCTAssertTrue(controller.apply(radius: 20, to: window))
    XCTAssertTrue(controller.apply(radius: 140, to: window))

    XCTAssertEqual(
      calls.map(\.windowNumber),
      [window.windowNumber, window.windowNumber, window.windowNumber])
    XCTAssertEqual(calls.map(\.radius), [0, 20, 100])
    XCTAssertEqual(controller.appliedRadius, 100)
  }

  func testUnavailableControllerReportsFailureWithoutCrash() {
    let controller = TerminalWindowBlurController(setBlurRadius: nil)

    XCTAssertFalse(controller.isAvailable)
    XCTAssertFalse(controller.apply(radius: 20, to: makeWindow()))
    XCTAssertNil(controller.appliedRadius)
  }

  func testFailedSetterReportsFailureAndClearsAppliedDiagnostic() {
    let window = makeWindow()
    var status: Int32 = 0
    let controller = TerminalWindowBlurController { _, _ in status }

    XCTAssertTrue(controller.apply(radius: 20, to: window))
    XCTAssertEqual(controller.appliedRadius, 20)

    status = -1
    XCTAssertFalse(controller.apply(radius: 30, to: window))
    XCTAssertNil(controller.appliedRadius)
  }

  private func makeWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
  }
}
