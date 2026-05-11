import Foundation
import XCTest

@testable import LabanDebug

final class DebugArtifactSnapshotWriterTests: XCTestCase {
  func testWriterCreatesSortedManifestAndFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "laban-artifact-writer-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let writer = DebugArtifactSnapshotWriter(
      runId: "run-1",
      frame: 12,
      snapshotsRoot: root,
      createdAt: { Date(timeIntervalSince1970: 0) }
    )

    let result = try writer.write(files: [
      "z.json": Data("z".utf8),
      "a.json": Data("a".utf8),
    ])

    XCTAssertEqual(result.snapshotDirectory.lastPathComponent, "snapshot-000012")
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.snapshotDirectory.appendingPathComponent("a.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: result.snapshotDirectory.appendingPathComponent("z.json").path))

    let manifestData = try Data(contentsOf: result.manifestURL)
    let manifest = try JSONDecoder().decode(DecodedArtifactManifest.self, from: manifestData)
    XCTAssertEqual(manifest.kind, "laban-debug-snapshot")
    XCTAssertEqual(manifest.runId, "run-1")
    XCTAssertEqual(manifest.frame, 12)
    XCTAssertEqual(manifest.files.map(\.name), ["a.json", "z.json"])
    XCTAssertEqual(
      manifest.files.map(\.path),
      [
        result.snapshotDirectory.appendingPathComponent("a.json").path,
        result.snapshotDirectory.appendingPathComponent("z.json").path,
      ])
  }

  private struct DecodedArtifactManifest: Decodable {
    var kind: String
    var runId: String
    var frame: Int
    var files: [DecodedArtifactFile]
  }

  private struct DecodedArtifactFile: Decodable {
    var name: String
    var path: String
  }
}
