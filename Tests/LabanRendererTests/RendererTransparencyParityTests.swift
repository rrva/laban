import XCTest

@testable import LabanRenderer

final class RendererTransparencyParityTests: XCTestCase {
  func testAllFiveSelectorsAgreeOnSemanticAlphaProbes() throws {
    for selection in RendererSelection.allCases {
      let backend = try RendererTransparencyTestSupport.makeBackend(selection)
      let image = try RendererTransparencyTestSupport.renderImage(
        backend,
        commands: RendererTransparencyTestSupport.commands(),
        damage: .full)
      RendererTransparencyTestSupport.assertSemanticAlpha(image)
    }
  }
}
