import CoreGraphics
import XCTest

@testable import LabanApp

final class TerminalResizeAutomationTests: XCTestCase {
  func testConfigurationRequiresResizeAutomationFlag() {
    XCTAssertNil(TerminalResizeAutomation.configuration(environment: [:]))
    XCTAssertNil(
      TerminalResizeAutomation.configuration(environment: ["LABAN_RESIZE_AUTOMATION": "0"]))
  }

  func testConfigurationUsesMillisecondDelaysAndAutoQuitFlag() {
    let config = TerminalResizeAutomation.configuration(
      environment: [
        "LABAN_RESIZE_AUTOMATION": "1",
        "LABAN_RESIZE_START_DELAY_MS": "250",
        "LABAN_RESIZE_CAPTURE_DELAY_MS": "12.5",
        "LABAN_RESIZE_AUTO_QUIT": "1",
        "LABAN_RESIZE_STEPS": "800x600",
      ])

    XCTAssertEqual(config?.startDelaySeconds, 0.25)
    XCTAssertEqual(config?.settleDelaySeconds, 0.0125)
    XCTAssertEqual(config?.autoQuit, true)
    XCTAssertEqual(config?.steps, [CGSize(width: 800, height: 600)])
  }

  func testConfigurationUsesDelayFallbacksForInvalidValues() {
    let config = TerminalResizeAutomation.configuration(
      environment: [
        "LABAN_RESIZE_AUTOMATION": "1",
        "LABAN_RESIZE_START_DELAY_MS": "soon",
        "LABAN_RESIZE_CAPTURE_DELAY_MS": "later",
        "LABAN_RESIZE_STEPS": "800x600",
      ])

    XCTAssertEqual(config?.startDelaySeconds, 0.5)
    XCTAssertEqual(config?.settleDelaySeconds, 0.035)
    XCTAssertEqual(config?.autoQuit, false)
  }

  func testStepsParseCaseInsensitiveDimensionsAndSkipInvalidEntries() {
    let steps = TerminalResizeAutomation.steps(from: "800X600,bad,0x20,1200x900")

    XCTAssertEqual(
      steps,
      [
        CGSize(width: 800, height: 600),
        CGSize(width: 1200, height: 900),
      ])
  }

  func testStepsFallBackWhenNothingValidIsProvided() {
    XCTAssertEqual(
      TerminalResizeAutomation.steps(from: "bad,0x20"),
      [
        TerminalResizeAutomation.fallbackStep
      ])
  }
}
