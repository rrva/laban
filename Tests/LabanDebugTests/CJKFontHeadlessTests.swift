import Foundation
import XCTest

@testable import LabanDebug
@testable import LabanRenderer

final class CJKFontHeadlessTests: XCTestCase {
  private let defaultsKey = CJKFontSettings.defaultsKey

  override func tearDown() {
    UserDefaults.standard.register(defaults: [defaultsKey: CJKFontPreference.pingFangSC.rawValue])
    super.tearDown()
  }

  func testAtlasReportsUpdatedFallbackOrderAfterPreferenceChange() throws {
    let saved = UserDefaults.standard.string(forKey: defaultsKey)
    defer {
      if let saved {
        UserDefaults.standard.register(defaults: [defaultsKey: saved])
      } else {
        UserDefaults.standard.register(defaults: [
          defaultsKey: CJKFontPreference.pingFangSC.rawValue
        ])
      }
    }

    CJKFontSettings.set(.pingFangSC)
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-cjk-headless-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "cjk-headless-preference",
      rendererSelection: .software)

    let initial = try cjkFont(from: runtime.atlas())
    XCTAssertEqual(initial["preference"] as? String, "PingFang SC")
    XCTAssertEqual((initial["fallbackOrder"] as? [String])?[1], "PingFang SC")

    let exp = expectation(forNotification: CJKFontSettings.didChangeNotification, object: nil)
    CJKFontSettings.set(.sarasaTermSC)
    wait(for: [exp], timeout: 1.0)

    let updated = try cjkFont(from: runtime.atlas())
    XCTAssertEqual(updated["preference"] as? String, "Sarasa Term SC")
    XCTAssertEqual((updated["fallbackOrder"] as? [String])?[1], "Sarasa Term SC")
  }

  private func cjkFont(from response: DebugResponse) throws -> [String: Any] {
    XCTAssertEqual(response.status, 200)
    let obj = try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
    return try XCTUnwrap(obj["cjkFont"] as? [String: Any])
  }
}
