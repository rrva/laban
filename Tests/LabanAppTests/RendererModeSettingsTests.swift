import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanApp

final class RendererModeSettingsTests: XCTestCase {
  private var suiteNames: [String] = []
  private var oldRendererEnv: String?

  override func setUp() {
    super.setUp()
    oldRendererEnv = getenv("LABAN_RENDERER").map { String(cString: $0) }
    unsetenv("LABAN_RENDERER")
    UserDefaults.standard.removeObject(forKey: RendererMode.defaultsKey)
  }

  override func tearDown() {
    if let oldRendererEnv {
      setenv("LABAN_RENDERER", oldRendererEnv, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    oldRendererEnv = nil
    UserDefaults.standard.removeObject(forKey: RendererMode.defaultsKey)
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testRendererMenuPersistsAvailableSelectionAndAppliesLiveMode() throws {
    let defaults = try makeDefaults()
    var applied: [RendererMode] = []
    let controller = RendererModeMenuController(defaults: defaults) { mode in
      applied.append(mode)
    }

    let parent = controller.makeMenuItem()
    let submenu = try XCTUnwrap(parent.submenu)
    XCTAssertEqual(submenu.items[0].title, "Classic Renderer")
    XCTAssertEqual(submenu.items[0].state, .on)

    let gpuItem = try XCTUnwrap(submenu.items.dropFirst().first)
    if #available(macOS 26, *) {
      XCTAssertEqual(gpuItem.title, "GPU-driven Renderer")
      XCTAssertTrue(gpuItem.isEnabled)

      controller.selectGPUDriven(nil)

      XCTAssertEqual(RendererMode.persisted(defaults: defaults), .gpuDriven)
      XCTAssertEqual(applied, [.gpuDriven])
      XCTAssertEqual(submenu.items[0].state, .off)
      XCTAssertEqual(gpuItem.state, .on)

      controller.selectClassic(nil)

      XCTAssertEqual(RendererMode.persisted(defaults: defaults), .classic)
      XCTAssertEqual(applied, [.gpuDriven, .classic])
      XCTAssertEqual(submenu.items[0].state, .on)
      XCTAssertEqual(gpuItem.state, .off)
    } else {
      XCTAssertEqual(gpuItem.title, "GPU-driven Renderer (requires macOS 26)")
      XCTAssertFalse(gpuItem.isEnabled)
      XCTAssertEqual(gpuItem.state, .off)
    }
  }

  func testRendererModeSwitchPreservesActiveSessionIdentity() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(fontAtlas.cellSize.width),
      cellHeight: Int(fontAtlas.cellSize.height)
    )
    guard view.usesMetalBackend else {
      throw XCTSkip("Metal renderer unavailable")
    }

    let activeTab = try XCTUnwrap(model.activeTab)
    let activeSession = try XCTUnwrap(model.session(forTab: activeTab.id))

    view.applyRendererMode(.gpuDriven)

    let expected: RendererMode
    if #available(macOS 26, *) {
      expected = .gpuDriven
    } else {
      expected = .classic
    }
    XCTAssertEqual(view.rendererMode, expected)
    XCTAssertEqual(RendererMode.persisted(), expected)
    XCTAssertEqual(model.activeTab?.id, activeTab.id)
    XCTAssertTrue(model.session(forTab: activeTab.id) === activeSession)
  }

  func testTerminalViewDoesNotInstallCommandHookWithoutFrameProbe() throws {
    setenv("LABAN_RENDERER", "software", 1)
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(fontAtlas.cellSize.width),
      cellHeight: Int(fontAtlas.cellSize.height)
    )

    XCTAssertNil(
      view.snapshotCommandsHook(captureFrame: 1),
      "a nil AppKit frame probe must stay a nil TerminalSurfaceController hook so payload mode can skip command production")
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "RendererModeSettingsTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
