import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// Byte-stability guard for the `/debug` discovery endpoint list: the
/// `ControlRouteCatalog`-derived endpoints must stay identical to the golden
/// captured from the legacy `DebugHTTPServer` route table (method, path,
/// category, summary, query parameters, and legacy schema paths).
final class DiscoveryEndpointParityTests: XCTestCase {
  func testCatalogDiscoveryEndpointsMatchGolden() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let catalog = String(
      data: try encoder.encode(DebugDiscoveryEndpoint.catalog), encoding: .utf8)!

    let goldenURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/discovery-endpoints.golden.json")
    let golden = try String(contentsOf: goldenURL, encoding: .utf8)

    XCTAssertEqual(
      catalog, golden,
      "ControlRouteCatalog discovery endpoints drifted from the byte-stable /debug golden")
  }
}
