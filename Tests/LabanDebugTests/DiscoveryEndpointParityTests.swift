import Foundation
import LabanCore
import XCTest

@testable import LabanDebug

/// Byte-stability guard for the `/debug` discovery endpoint list: the
/// `ControlRouteCatalog`-derived endpoints the runtime serves must stay
/// identical to the committed, generator-owned `schemas/debug/discovery-endpoints.json`
/// (regenerate with `swift run LabanControlGen --write`). The same file is gated
/// in CI by `LabanControlGen --check`.
final class DiscoveryEndpointParityTests: XCTestCase {
  func testCatalogDiscoveryEndpointsMatchCommittedDoc() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let catalog = String(
      data: try encoder.encode(DebugDiscoveryEndpoint.catalog), encoding: .utf8)!

    let docURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("schemas/debug/discovery-endpoints.json")
    let committed = try String(contentsOf: docURL, encoding: .utf8)

    XCTAssertEqual(
      catalog, committed,
      "ControlRouteCatalog discovery endpoints drifted from schemas/debug/discovery-endpoints.json")
  }
}
