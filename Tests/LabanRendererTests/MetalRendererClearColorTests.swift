import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

/// Regression for the alt-screen "black flash": a full redraw (resize, or an
/// alternate-screen swap such as quitting btop and starting top) cleared the
/// render target to pure black, which flashed black under a themed terminal
/// wherever the draw did not immediately cover. The clear must instead use the
/// terminal's own default background (from the background rect the FrameProducer
/// always emits).
final class MetalRendererClearColorTests: XCTestCase {

  func testFullRedrawClearsToTerminalBackgroundNotBlack() {
    let cream: UInt32 = 0xFBF3_DBFF  // 251,243,219
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 10, height: 10), color: 0xECEC_ECFF, source: .sidebar),
      .rect(CGRect(x: 10, y: 0, width: 100, height: 100), color: cream, source: .terminal),
    ]
    let c = MetalRenderer.fullRedrawClearColor(commands)
    XCTAssertEqual(c.red, 251.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(c.green, 243.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(c.blue, 219.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(c.alpha, 1.0, accuracy: 0.001)
    XCTAssertFalse(
      c.red == 0 && c.green == 0 && c.blue == 0,
      "full-redraw clear must use the terminal background, not black")
  }

  func testIntentionalBlackTerminalBackgroundIsRespected() {
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 100, height: 100), color: 0x0000_00FF, source: .terminal)
    ]
    let c = MetalRenderer.fullRedrawClearColor(commands)
    XCTAssertEqual(c.red, 0, accuracy: 0.001)
    XCTAssertEqual(c.green, 0, accuracy: 0.001)
    XCTAssertEqual(c.blue, 0, accuracy: 0.001)
    XCTAssertEqual(c.alpha, 1.0, accuracy: 0.001)
  }

  func testNoTerminalRectFallsBackToFirstRect() {
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 10, height: 10), color: 0x112233_FF, source: .sidebar)
    ]
    let c = MetalRenderer.fullRedrawClearColor(commands)
    XCTAssertEqual(c.red, Double(0x11) / 255.0, accuracy: 0.001)
    XCTAssertEqual(c.green, Double(0x22) / 255.0, accuracy: 0.001)
    XCTAssertEqual(c.blue, Double(0x33) / 255.0, accuracy: 0.001)
  }

  func testNoRectsFallsBackToBlack() {
    let c = MetalRenderer.fullRedrawClearColor([])
    XCTAssertEqual(c.red, 0, accuracy: 0.001)
    XCTAssertEqual(c.green, 0, accuracy: 0.001)
    XCTAssertEqual(c.blue, 0, accuracy: 0.001)
  }
}
