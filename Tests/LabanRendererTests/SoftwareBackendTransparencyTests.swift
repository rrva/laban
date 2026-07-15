import XCTest

@testable import LabanRenderer

final class SoftwareBackendTransparencyTests: XCTestCase {
  func testReplaceCanvasIsIdempotentAcrossOneHundredFrames() throws {
    let backend = try RendererTransparencyTestSupport.makeBackend(.software)
    var image: TestRGBAImage?
    for _ in 0..<100 {
      image = try RendererTransparencyTestSupport.renderImage(
        backend,
        commands: RendererTransparencyTestSupport.commands(),
        damage: .full)
    }
    RendererTransparencyTestSupport.assertSemanticAlpha(try XCTUnwrap(image))
  }
}
