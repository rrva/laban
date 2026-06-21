import Foundation
import XCTest

@testable import LabanDebug

final class ChineseTrustGateTests: XCTestCase {
  func testTrustGateFixtureEndpointIntegrity() throws {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-trust-gate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixtureRoot = repoRoot.appendingPathComponent("fixtures", isDirectory: true)
    let fixturePath = "cjk/trust-gate.fixture.json"

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "chinese-trust-gate",
      fixtureRootURL: fixtureRoot
    )

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fixtureRoot.appendingPathComponent(fixturePath).path))

    let initialHealth = try json(runtime.health())
    let initialFrame = initialHealth["frame"] as? Int ?? 0
    XCTAssertGreaterThan(initialFrame, 0)

    let loadBody = try JSONSerialization.data(
      withJSONObject: ["action": "load", "path": fixturePath]
    )
    let loadResponse = try json(runtime.fixtureControl(loadBody))
    XCTAssertEqual(loadResponse["ok"] as? Bool, true)
    let loadFrame = loadResponse["frame"] as? Int ?? 0
    XCTAssertGreaterThanOrEqual(loadFrame, initialFrame + 1)

    let stepResponse = try json(
      runtime.fixtureControl(
        try JSONSerialization.data(withJSONObject: ["action": "step", "count": 100]))
    )
    XCTAssertEqual(stepResponse["ok"] as? Bool, true)
    let stepFrame = stepResponse["frame"] as? Int ?? 0
    let stepIndex = stepResponse["stepIndex"] as? Int ?? -1
    let stepCount = stepResponse["stepCount"] as? Int ?? -1
    XCTAssertGreaterThan(stepFrame, loadFrame)
    XCTAssertEqual(stepIndex, stepCount)

    let waitPayload = try JSONSerialization.data(
      withJSONObject: [
        "timeoutMs": 1000,
        "condition": [
          "kind": "textVisible",
          "text": "用户@主机 ~/项目 $ npm run build",
        ],
      ]
    )
    let waitResponse = try json(runtime.wait(waitPayload))
    XCTAssertEqual(waitResponse["ok"] as? Bool, true)

    let atlasResponse = runtime.atlas()
    XCTAssertEqual(atlasResponse.status, 200)
    let atlasBody = try json(atlasResponse)
    XCTAssertNotNil(atlasBody["font"] as? String)
    XCTAssertNotNil((atlasBody["glyphs"] as? [String: Any])?["missing"] as? Int)
    let cjkFont = atlasBody["cjkFont"] as? [String: Any]
    XCTAssertNotNil(cjkFont)
    XCTAssertEqual(cjkFont?["glyphAvailable"] as? Bool, true)
    XCTAssertFalse((cjkFont?["font"] as? String ?? "").isEmpty)
    XCTAssertGreaterThan((cjkFont?["targetCellWidth"] as? NSNumber)?.doubleValue ?? 0, 0)

    let frameCommandsResponse = runtime.frameCommands(query: ["source": "all", "limit": "4000"])
    XCTAssertEqual(frameCommandsResponse.status, 200)
    let frameCommands = try json(frameCommandsResponse)
    let commands = frameCommands["commands"] as? [[String: Any]] ?? []
    XCTAssertGreaterThan(commands.count, 0)
    XCTAssertTrue(commands.contains { $0["source"] as? String == "terminal" })

    let discovery = try json(runtime.discovery())
    let endpoints = discovery["endpoints"] as? [[String: Any]] ?? []
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "GET" && $0["path"] as? String == "/debug/atlas"
      })
    XCTAssertTrue(
      endpoints.contains {
        $0["method"] as? String == "GET" && $0["path"] as? String == "/debug/frame-commands"
      })
    XCTAssertTrue(
      endpoints.contains {
        $0["path"] as? String == "/debug/screenshot"
      })

    let (pngData, screenshotFrame, screenshotWidth, screenshotHeight) =
      try runtime.screenshotBytes()
    XCTAssertGreaterThanOrEqual(screenshotFrame, stepFrame)
    XCTAssertGreaterThan(pngData.count, 0)
    XCTAssertGreaterThan(screenshotWidth, 0)
    XCTAssertGreaterThan(screenshotHeight, 0)

    let writeScreenshotResponse = runtime.writeScreenshotArtifact()
    XCTAssertEqual(writeScreenshotResponse.status, 200)
    let writeScreenshot = try json(writeScreenshotResponse)
    let screenshotPath = writeScreenshot["path"] as? String
    XCTAssertNotNil(screenshotPath)
    if let screenshotPath {
      XCTAssertTrue(FileManager.default.fileExists(atPath: screenshotPath))
    }

    let atlasArtifactPath = artifacts.appendingPathComponent("trust-gate-atlas.json")
    let frameCommandsArtifactPath = artifacts.appendingPathComponent(
      "trust-gate-frame-commands.json")
    try atlasResponse.body.write(to: atlasArtifactPath)
    try frameCommandsResponse.body.write(to: frameCommandsArtifactPath)

    XCTAssertTrue(FileManager.default.fileExists(atPath: atlasArtifactPath.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: frameCommandsArtifactPath.path))
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
