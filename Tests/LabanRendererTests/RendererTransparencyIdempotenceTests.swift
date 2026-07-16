import XCTest

@testable import LabanRenderer

final class RendererTransparencyIdempotenceTests: XCTestCase {
  func testAllFiveSelectorsRemainAt179AfterRepeatedFullAndPartialFrames() throws {
    for selection in RendererSelection.allCases {
      let backend = try RendererTransparencyTestSupport.makeBackend(selection)
      var image: TestRGBAImage?
      for _ in 0..<100 {
        image = try RendererTransparencyTestSupport.renderImage(
          backend,
          commands: RendererTransparencyTestSupport.commands(),
          damage: .full)
      }
      RendererTransparencyTestSupport.assertSemanticAlpha(try XCTUnwrap(image))

      for _ in 0..<100 {
        image = try RendererTransparencyTestSupport.renderImage(
          backend,
          commands: RendererTransparencyTestSupport.commands(),
          damage: .partial(yRanges: [DirtyYRange(y: 0, height: 8)]))
      }
      RendererTransparencyTestSupport.assertSemanticAlpha(try XCTUnwrap(image))
    }
  }

  func testBrightFrostedCanvasRemainsEncodedPremultipliedAcrossRepeatedFrames() throws {
    for selection in RendererSelection.allCases {
      let backend = try RendererTransparencyTestSupport.makeBackend(selection)
      var image: TestRGBAImage?
      for _ in 0..<100 {
        image = try RendererTransparencyTestSupport.renderImage(
          backend,
          commands: RendererTransparencyTestSupport.brightFrostedCommands(),
          damage: .full)
      }
      RendererTransparencyTestSupport.assertBrightFrostedCanvas(try XCTUnwrap(image))

      for _ in 0..<100 {
        image = try RendererTransparencyTestSupport.renderImage(
          backend,
          commands: RendererTransparencyTestSupport.brightFrostedCommands(),
          damage: .partial(yRanges: [DirtyYRange(y: 0, height: 8)]))
      }
      RendererTransparencyTestSupport.assertBrightFrostedCanvas(try XCTUnwrap(image))
    }
  }
}
