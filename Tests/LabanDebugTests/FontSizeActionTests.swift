import Foundation
import XCTest

@testable import LabanDebug
@testable import LabanRenderer

final class FontSizeActionTests: XCTestCase {

  func testSetFontSizeSwapsAtlasAndReflowsColumns() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let colsBefore = Int(runtime.model.terminalAreaSize.cols)

    let response = runtime.applyAction(
      Data(#"{"action":"setFontSize","pointSize":20}"#.utf8))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(try json(response)["ok"] as? Bool, true)

    let atlas = try json(runtime.atlas())
    XCTAssertEqual(atlas["fontSize"] as? Double, 20)

    let expectedCellWidth = max(1, Int(FontAtlas(pointSize: 20).cellSize.width))
    let cell = atlas["cell"] as? [String: Any]
    XCTAssertEqual(cell?["width"] as? Int, expectedCellWidth)

    // Same window pixels, bigger cells: the grid renegotiates to fewer
    // columns, exactly like a window resize does for the running programs.
    let viewportWidth = runtime.windowWidth - runtime.sidebarWidth
    let colsAfter = Int(runtime.model.terminalAreaSize.cols)
    XCTAssertEqual(colsAfter, max(viewportWidth / expectedCellWidth, 1))
    XCTAssertLessThan(colsAfter, colsBefore)
  }

  func testSetFontSizeClampsToZoomRange() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.applyAction(
      Data(#"{"action":"setFontSize","pointSize":400}"#.utf8))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(
      Double(runtime.fontAtlas.pointSize), Double(FontAtlas.zoomMaximumPointSize))
  }

  func testSetFontSizePreservesActiveFontWhenDefaultsChange() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let activeFontName = runtime.fontAtlas.fontPostScriptName
    let defaults = UserDefaults.standard
    let previousFont = defaults.object(forKey: FontAtlas.userFontKey)
    defaults.set("Helvetica", forKey: FontAtlas.userFontKey)
    defer {
      if let previousFont {
        defaults.set(previousFont, forKey: FontAtlas.userFontKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontKey)
      }
    }
    let defaultsResolved = FontAtlas(pointSize: 20)
    guard defaultsResolved.fontPostScriptName != activeFontName else {
      throw XCTSkip("probe font resolved to the active font")
    }

    let response = runtime.applyAction(
      Data(#"{"action":"setFontSize","pointSize":20}"#.utf8))

    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(Double(runtime.fontAtlas.pointSize), 20)
    XCTAssertEqual(runtime.fontAtlas.fontPostScriptName, activeFontName)
    XCTAssertNotEqual(runtime.fontAtlas.fontPostScriptName, defaultsResolved.fontPostScriptName)
  }

  func testSetFontSizeWithoutPointSizeFails() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }

    let response = runtime.applyAction(Data(#"{"action":"setFontSize"}"#.utf8))
    XCTAssertEqual(response.status, 400)
  }

  func testRuntimeReadsPersistedFontSize() throws {
    // A private, process-unique suite: writing the key to
    // `UserDefaults.standard` would leak into every concurrent test process
    // through the shared `com.apple.dt.xctest.tool` domain.
    let suiteName = "laban-fontsize-\(getpid())-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(20.0, forKey: FontAtlas.userFontSizeKey)

    let (runtime, artifacts) = try makeRuntime(fontDefaults: defaults)
    defer { try? FileManager.default.removeItem(at: artifacts) }

    XCTAssertEqual(Double(runtime.fontAtlas.pointSize), 20)
    XCTAssertEqual(runtime.cellHeight, Int(FontAtlas(pointSize: 20, fontName: nil).cellSize.height))
  }

  func testCommandZoomChordsDriveFontSize() throws {
    let (runtime, artifacts) = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: artifacts) }
    let baseline = Double(runtime.fontAtlas.pointSize)

    var response = runtime.applyAction(
      Data(#"{"action":"key","key":"=","modifiers":["command"]}"#.utf8))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(Double(runtime.fontAtlas.pointSize), baseline + 1)

    response = runtime.applyAction(
      Data(#"{"action":"key","key":"-","modifiers":["command"]}"#.utf8))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(Double(runtime.fontAtlas.pointSize), baseline)

    _ = runtime.applyAction(
      Data(#"{"action":"key","key":"=","modifiers":["command"]}"#.utf8))
    response = runtime.applyAction(
      Data(#"{"action":"key","key":"0","modifiers":["command"]}"#.utf8))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(
      Double(runtime.fontAtlas.pointSize), Double(FontAtlas.defaultTerminalPointSize))
  }

  private func makeRuntime(
    fontDefaults: UserDefaults = .standard
  ) throws -> (HeadlessDebugRuntime, URL) {
    let artifacts = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-debug-fontsize-\(UUID().uuidString)")
    let runtime = try HeadlessDebugRuntime(
      fixtureURL: nil,
      artifactsURL: artifacts,
      tempURL: nil,
      deterministic: true,
      runId: "font-size-tests",
      fontDefaults: fontDefaults
    )
    return (runtime, artifacts)
  }

  private func json(_ response: DebugResponse) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: response.body) as! [String: Any]
  }
}
