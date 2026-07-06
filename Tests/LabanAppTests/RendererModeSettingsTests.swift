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
    UserDefaults.standard.removeObject(forKey: RendererSelection.defaultsKey)
    UserDefaults.standard.removeObject(forKey: VectorSubpixelLayout.defaultsKey)
  }

  override func tearDown() {
    if let oldRendererEnv {
      setenv("LABAN_RENDERER", oldRendererEnv, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    oldRendererEnv = nil
    UserDefaults.standard.removeObject(forKey: RendererSelection.defaultsKey)
    UserDefaults.standard.removeObject(forKey: VectorSubpixelLayout.defaultsKey)
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testRendererMenuPersistsAvailableSelectionAndAppliesLiveMode() throws {
    let defaults = try makeDefaults()
    var applied: [RendererSelection] = []
    let controller = RendererModeMenuController(defaults: defaults) { selection in
      applied.append(selection)
    }

    let parent = controller.makeMenuItem()
    let submenu = try XCTUnwrap(parent.submenu)
    XCTAssertEqual(
      submenu.items.map(\.title),
      [
        L10n.trEn("Software Renderer"),
        L10n.trEn("Classic Metal Renderer"),
        RendererMode.gpuDriven.isAvailableOnCurrentOS
          ? L10n.trEn("GPU-driven Renderer") : L10n.trEn("GPU-driven Renderer (requires macOS 26)"),
        L10n.trEn("Vector Glyph Renderer"),
        L10n.trEn("Slug Glyph Renderer"),
      ])
    XCTAssertEqual(submenu.items[0].state, .off)
    if RendererMode.gpuDriven.isAvailableOnCurrentOS {
      XCTAssertEqual(submenu.items[1].state, .off)
      XCTAssertEqual(submenu.items[2].state, .on)
    } else {
      XCTAssertEqual(submenu.items[1].state, .on)
      XCTAssertEqual(submenu.items[2].state, .off)
    }
    XCTAssertEqual(submenu.items[3].state, .off)
    XCTAssertEqual(submenu.items[4].state, .off)

    controller.selectSoftware(nil)

    XCTAssertEqual(RendererSelection.persisted(defaults: defaults), .software)
    XCTAssertEqual(applied, [.software])
    XCTAssertEqual(submenu.items[0].state, .on)
    XCTAssertEqual(submenu.items[1].state, .off)
    XCTAssertEqual(submenu.items[3].state, .off)
    XCTAssertEqual(submenu.items[4].state, .off)

    let gpuItem = submenu.items[2]
    if #available(macOS 26, *) {
      XCTAssertEqual(gpuItem.title, "GPU-driven Renderer")
      XCTAssertTrue(gpuItem.isEnabled)

      controller.selectGPUDriven(nil)

      XCTAssertEqual(RendererSelection.persisted(defaults: defaults), .gpuDriven)
      XCTAssertEqual(applied, [.software, .gpuDriven])
      XCTAssertEqual(submenu.items[0].state, .off)
      XCTAssertEqual(submenu.items[1].state, .off)
      XCTAssertEqual(gpuItem.state, .on)
      XCTAssertEqual(submenu.items[3].state, .off)
      XCTAssertEqual(submenu.items[4].state, .off)

      controller.selectClassic(nil)

      XCTAssertEqual(RendererSelection.persisted(defaults: defaults), .classic)
      XCTAssertEqual(applied, [.software, .gpuDriven, .classic])
      XCTAssertEqual(submenu.items[0].state, .off)
      XCTAssertEqual(submenu.items[1].state, .on)
      XCTAssertEqual(gpuItem.state, .off)
      XCTAssertEqual(submenu.items[3].state, .off)
      XCTAssertEqual(submenu.items[4].state, .off)
    } else {
      XCTAssertEqual(gpuItem.title, "GPU-driven Renderer (requires macOS 26)")
      XCTAssertFalse(gpuItem.isEnabled)
      XCTAssertEqual(gpuItem.state, .off)
    }

    controller.selectVectorGlyph(nil)

    XCTAssertEqual(RendererSelection.persisted(defaults: defaults), .vectorGlyph)
    XCTAssertEqual(applied.last, .vectorGlyph)
    XCTAssertEqual(submenu.items[0].state, .off)
    XCTAssertEqual(submenu.items[1].state, .off)
    XCTAssertEqual(submenu.items[2].state, .off)
    XCTAssertEqual(submenu.items[3].state, .on)
    XCTAssertEqual(submenu.items[4].state, .off)

    controller.selectSlugGlyph(nil)

    XCTAssertEqual(RendererSelection.persisted(defaults: defaults), .slugGlyph)
    XCTAssertEqual(applied.last, .slugGlyph)
    XCTAssertEqual(submenu.items[0].state, .off)
    XCTAssertEqual(submenu.items[1].state, .off)
    XCTAssertEqual(submenu.items[2].state, .off)
    XCTAssertEqual(submenu.items[3].state, .off)
    XCTAssertEqual(submenu.items[4].state, .on)
  }

  func testRendererSelectionSoftwarePersistsAndUsesSoftwareBackend() throws {
    RendererSelection.set(.software)
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

    XCTAssertEqual(view.rendererSelection, .software)
    XCTAssertFalse(view.usesMetalBackend)
    XCTAssertEqual(RendererSelection.persisted(), .software)
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

    let expected: RendererSelection
    if #available(macOS 26, *) {
      expected = .gpuDriven
    } else {
      expected = .classic
    }
    XCTAssertEqual(view.rendererSelection, expected)
    XCTAssertEqual(RendererSelection.persisted(), expected)
    XCTAssertEqual(model.activeTab?.id, activeTab.id)
    XCTAssertTrue(model.session(forTab: activeTab.id) === activeSession)
  }

  func testRendererSelectionSwitchesBetweenSoftwareAndMetalWithoutReplacingSession() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    RendererSelection.set(.software)
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
    let activeTab = try XCTUnwrap(model.activeTab)
    let activeSession = try XCTUnwrap(model.session(forTab: activeTab.id))

    XCTAssertFalse(view.usesMetalBackend)

    view.applyRendererSelection(.classic)

    XCTAssertTrue(view.usesMetalBackend)
    XCTAssertEqual(view.rendererSelection, .classic)
    XCTAssertEqual(RendererSelection.persisted(), .classic)
    XCTAssertEqual(model.activeTab?.id, activeTab.id)
    XCTAssertTrue(model.session(forTab: activeTab.id) === activeSession)

    view.applyRendererSelection(.software)

    XCTAssertFalse(view.usesMetalBackend)
    XCTAssertEqual(view.rendererSelection, .software)
    XCTAssertEqual(RendererSelection.persisted(), .software)
    XCTAssertEqual(model.activeTab?.id, activeTab.id)
    XCTAssertTrue(model.session(forTab: activeTab.id) === activeSession)
  }

  func testVectorGlyphSwitchPreservesActiveSessionIdentity() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    RendererSelection.set(.classic)
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
    let activeTab = try XCTUnwrap(model.activeTab)
    let activeSession = try XCTUnwrap(model.session(forTab: activeTab.id))

    view.applyRendererSelection(.vectorGlyph)

    XCTAssertEqual(view.rendererSelection, .vectorGlyph)
    XCTAssertEqual(RendererSelection.persisted(), .vectorGlyph)
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
      "a nil AppKit frame probe must stay a nil TerminalSurfaceController hook so payload mode can skip command production"
    )
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
