import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class FixtureRunnerTests: XCTestCase {

  private func coloredBoxesURL() -> URL {
    // #filePath resolves to the absolute path of this source file at compile time.
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // LabanCoreTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // project root
      .appendingPathComponent("fixtures/colored-boxes.fixture.json")
  }

  func testFixtureParsing() throws {
    let runner = try FixtureRunner.load(from: coloredBoxesURL())
    XCTAssertEqual(runner.fixture.name, "colored-boxes")
    XCTAssertEqual(runner.fixture.version, 1)
    XCTAssertEqual(runner.fixture.initialSize.cols, 80)
    XCTAssertEqual(runner.fixture.initialSize.rows, 24)
    XCTAssertEqual(runner.fixture.steps.count, 3)
    XCTAssertEqual(runner.fixture.steps[0], .setTitle("Fixture: Colored Boxes"))
    XCTAssertEqual(runner.fixture.expect?.containsText, ["hello mvp"])
  }

  func testUnknownOpThrows() throws {
    let stepJSON = #"{"op": "doesNotExist"}"#.data(using: .utf8)!
    do {
      _ = try JSONDecoder().decode(FixtureStep.self, from: stepJSON)
      XCTFail("expected FixtureError.unknownOp to be thrown")
    } catch FixtureError.unknownOp(let op) {
      XCTAssertEqual(op, "doesNotExist")
    } catch {
      XCTFail("expected FixtureError.unknownOp, got \(error)")
    }
  }

  func testHeadlessRunProducesNonEmptyPNG() throws {
    let runner = try FixtureRunner.load(from: coloredBoxesURL())

    var size = LabanTerminalSize()
    size.rows = Int32(runner.fixture.initialSize.rows)
    size.cols = Int32(runner.fixture.initialSize.cols)
    let model = try AppModel(initialSize: size)

    try runner.apply(to: model)

    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id),
      let snap = session.snapshot()
    else {
      XCTFail("snapshot failed")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let rows = Int(snap.pointee.rows)
    let cols = Int(snap.pointee.cols)

    let fontAtlas = FontAtlas(pointSize: 14)
    let cellSize = fontAtlas.cellSize
    let cellW = Int(cellSize.width)
    let cellH = Int(cellSize.height)
    let sidebarWidth: CGFloat = 200
    let bitmapW = max(Int(sidebarWidth) + cols * cellW, 1)
    let bitmapH = max(rows * cellH, 1)

    let surface = BitmapSurface(width: bitmapW, height: bitmapH)
    let sr = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

    let sp = SidebarProducer(
      sidebarWidth: sidebarWidth, cellWidth: CGFloat(cellW), cellHeight: CGFloat(cellH))
    let fp = FrameProducer(cellWidth: cellW, cellHeight: cellH, originX: sidebarWidth, originY: 0)

    var cmds: [FrameCommand] = []
    cmds += sp.commands(tabs: model.tabs, activeTabId: tab.id, height: CGFloat(bitmapH))
    cmds += fp.commands(from: UnsafePointer(snap))
    sr.render(cmds)

    let pngData = surface.pngData
    XCTAssertNotNil(pngData)
    XCTAssertGreaterThan(pngData?.count ?? 0, 0, "PNG must be non-empty")
  }

  func testStableIDs() throws {
    let runner = try FixtureRunner.load(from: coloredBoxesURL())

    var size = LabanTerminalSize()
    size.rows = Int32(runner.fixture.initialSize.rows)
    size.cols = Int32(runner.fixture.initialSize.cols)
    let model = try AppModel(initialSize: size)

    let tabId = model.tabs[0].id
    let sessionId = model.tabs[0].sessionId

    try runner.apply(to: model)

    XCTAssertFalse(tabId.isEmpty, "tab ID must not be empty")
    XCTAssertFalse(sessionId.isEmpty, "session ID must not be empty")
    XCTAssertEqual(model.activeTab?.id, tabId, "tab ID must not change across fixture run")
    XCTAssertEqual(model.activeTab?.sessionId, sessionId, "session ID must not change")
  }

  func testColoredBoxesContainsHelloMvp() throws {
    let runner = try FixtureRunner.load(from: coloredBoxesURL())

    var size = LabanTerminalSize()
    size.rows = Int32(runner.fixture.initialSize.rows)
    size.cols = Int32(runner.fixture.initialSize.cols)
    let model = try AppModel(initialSize: size)

    try runner.apply(to: model)

    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id),
      let snap = session.snapshot()
    else {
      XCTFail("snapshot failed")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    let text = runner.visibleText(from: UnsafePointer(snap))
    XCTAssertTrue(
      text.contains("hello mvp"),
      "visible text should contain 'hello mvp'; got: \(text.prefix(200))")
  }
}
