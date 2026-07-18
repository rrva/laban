import Foundation
import XCTest

final class TransparencyTransitionSmokeContractTests: XCTestCase {
  func testVerifierSelfTestPasses() throws {
    let result = try runVerifier(["--self-test"])

    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("self-test passed"), result.output)
  }

  func testIdleContractRejectsPresentDecodeAndFileReadGrowth() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "transparency-transition-verifier-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = directory.appendingPathComponent("before.json")
    let after = directory.appendingPathComponent("after.json")
    let baseline: [String: Any] = [
      "backdropSubviewKind": "image",
      "backdropSubviewCount": 1,
      "rendererPresentCount": 4,
      "backgroundImageDecodeCount": 1,
      "backgroundImageFileReadCount": 1,
    ]
    try writeJSON(baseline, to: before)

    for key in [
      "rendererPresentCount",
      "backgroundImageDecodeCount",
      "backgroundImageFileReadCount",
    ] {
      var advanced = baseline
      advanced[key] = 2 + (baseline[key] as? Int ?? 0)
      try writeJSON(advanced, to: after)

      let result = try runVerifier([
        "idle", before.path, after.path, "image", "1",
      ])

      XCTAssertNotEqual(result.status, 0, "unexpected pass for \(key)")
      XCTAssertTrue(result.output.contains(key), result.output)
    }
  }

  func testRestorationContractCoversEveryRequestedImageField() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "transparency-transition-restore-\(UUID().uuidString)",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let initialURL = directory.appendingPathComponent("initial.json")
    let restoredURL = directory.appendingPathComponent("restored.json")
    let initial: [String: Any] = [
      "requestedOpacity": 0.63,
      "requestedBlur": 0.2,
      "applyToExplicitCellBackgrounds": true,
      "requestedBackdropStyle": "image",
      "backgroundImageScaling": "fit",
      "backgroundImageIdentifier": "image-initial.png",
      "backgroundImagePixelWidth": 1600,
      "backgroundImagePixelHeight": 900,
      "backgroundImageContentDigest": "initial-digest",
    ]
    try writeJSON(initial, to: initialURL)
    XCTAssertEqual(
      try runVerifier(["restore", initialURL.path, initialURL.path]).status,
      0)

    for key in initial.keys {
      var changed = initial
      switch initial[key] {
      case is Bool:
        changed[key] = !(initial[key] as! Bool)
      case is Double:
        changed[key] = 0.72
      case is Int:
        changed[key] = (initial[key] as! Int) + 1
      default:
        changed[key] = "changed"
      }
      try writeJSON(changed, to: restoredURL)

      let result = try runVerifier([
        "restore", initialURL.path, restoredURL.path,
      ])

      XCTAssertNotEqual(result.status, 0, "unexpected pass for \(key)")
      XCTAssertTrue(result.output.contains(key), result.output)
    }
  }

  private func runVerifier(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = repositoryRoot()
      .appendingPathComponent("scripts/verify-transparency-transition-state")
    process.arguments = arguments
    process.currentDirectoryURL = repositoryRoot()
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
    )
  }

  private func writeJSON(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
