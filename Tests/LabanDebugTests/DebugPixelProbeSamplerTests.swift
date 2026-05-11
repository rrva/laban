import XCTest

@testable import LabanDebug

final class DebugPixelProbeSamplerTests: XCTestCase {
  func testPixelProbeSamplesPointsAndRegions() {
    let pixels: [String: UInt32] = [
      "0,0": 0x0000_00FF,
      "1,0": 0x1020_3040,
      "0,1": 0x0000_00FF,
      "1,1": 0xFFFF_FFFF,
    ]
    let sampler = DebugPixelProbeSampler(width: 3, height: 2) { x, y in
      pixels["\(x),\(y)"]
    }

    let response = sampler.response(
      frame: 42,
      request: PixelProbeRequest(
        points: [
          PixelProbePointRequest(x: 1, y: 0),
          PixelProbePointRequest(x: 9, y: 9),
        ],
        regions: [
          PixelProbeRegionRequest(name: "sample", x: 0, y: 0, width: 2, height: 2)
        ])
    )

    XCTAssertEqual(response.frame, 42)
    XCTAssertEqual(response.points[0].rgba, [16, 32, 48, 64])
    XCTAssertEqual(response.points[1].rgba, [0, 0, 0, 0])
    XCTAssertEqual(response.regions[0].name, "sample")
    XCTAssertEqual(response.regions[0].sampledPixels, 4)
    XCTAssertEqual(response.regions[0].nonBackgroundPixels, 2)
    XCTAssertEqual(response.regions[0].averageRgba, [67, 71, 75, 207])
  }

  func testTraceProbesUseOpaqueBlackForMissingPixels() {
    let sampler = DebugPixelProbeSampler(width: 2, height: 2) { x, y in
      (x, y) == (1, 1) ? 0x1122_3344 : nil
    }

    let probes = sampler.traceProbes([
      PixelProbeReq(name: "hit", x: 1, y: 1),
      PixelProbeReq(name: "miss", x: 3, y: 3),
    ])

    XCTAssertEqual(probes[0].name, "hit")
    XCTAssertEqual(probes[0].rgba, [17, 34, 51, 68])
    XCTAssertEqual(probes[1].name, "miss")
    XCTAssertEqual(probes[1].rgba, [0, 0, 0, 255])
    XCTAssertEqual(probes[1].contributors.first?.commandId, "cmd-0")
  }
}
