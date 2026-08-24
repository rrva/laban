import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import Metal
import XCTest

@testable import LabanApp

/// A cold launch with `.slugGlyph` persisted must show a
/// fast temporary backend immediately (no blank/white window) while the real
/// glyphBackend/slug glyph atlas prewarms in the background, then seamlessly become
/// the real renderer. These tests drive that flow deterministically via
/// `debugPerformColdLaunchSwapSynchronously`. See
/// execplans/active/glyphBackend-glyph-cold-launch-stall.md.
final class ColdLaunchFastBackendTests: XCTestCase {
  private var oldRendererEnv: String?

  override func setUp() {
    super.setUp()
    oldRendererEnv = getenv("LABAN_RENDERER").map { String(cString: $0) }
    unsetenv("LABAN_RENDERER")
    UserDefaults.standard.removeObject(forKey: RendererSelection.defaultsKey)
    TerminalBitmapView.backendFactoryForTesting = nil
  }

  override func tearDown() {
    TerminalBitmapView.backendFactoryForTesting = nil
    UserDefaults.standard.removeObject(forKey: RendererSelection.defaultsKey)
    if let oldRendererEnv {
      setenv("LABAN_RENDERER", oldRendererEnv, 1)
    } else {
      unsetenv("LABAN_RENDERER")
    }
    oldRendererEnv = nil
    super.tearDown()
  }

  /// With `.slugGlyph` persisted, the view immediately shows the fast
  /// temporary backend (classic Metal) while still reporting the user's real
  /// persisted choice (`rendererSelection == .slugGlyph`).
  func testColdLaunchWithSlugGlyphPersistedShowsFastBackendImmediately() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    RendererSelection.set(.slugGlyph)

    let view = try makeView()

    XCTAssertEqual(view.rendererSelection, .slugGlyph)
    XCTAssertEqual(RendererSelection.persisted(), .slugGlyph)
    XCTAssertTrue(
      view.usesMetalBackend,
      "cold launch must show the fast Metal backend first, not the real glyphBackend renderer")
    XCTAssertFalse(
      view.debugBackendEffectiveRenderer == .slugGlyph,
      "the real glyphBackend backend must not be active yet while the prewarm runs")
  }

  /// After the cold-launch prewarm completes (driven synchronously here), the
  /// view swaps to the real glyphBackend renderer.
  func testColdLaunchWithSlugGlyphPersistedEventuallyBecomesSlugGlyph() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    RendererSelection.set(.slugGlyph)

    let view = try makeView()
    XCTAssertEqual(view.rendererSelection, .slugGlyph)

    let didSwap = view.debugPerformColdLaunchSwapSynchronously(scale: 1)
    XCTAssertTrue(didSwap, "a cold-launch swap must have been pending")

    XCTAssertEqual(
      try XCTUnwrap(view.debugBackendEffectiveRenderer), .slugGlyph)
    XCTAssertEqual(view.rendererSelection, .slugGlyph)
    XCTAssertFalse(
      view.usesMetalBackend,
      "the glyphBackend renderer is not a MetalRenderer")
  }

  /// The same cold-launch fast-then-real flow must work for `.slugGlyph`.
  func testColdLaunchWithSlugGlyphPersistedShowsFastBackendThenBecomesSlug() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    RendererSelection.set(.slugGlyph)

    let view = try makeView()
    XCTAssertEqual(view.rendererSelection, .slugGlyph)
    XCTAssertTrue(view.usesMetalBackend)
    XCTAssertFalse(view.debugBackendEffectiveRenderer == .slugGlyph)

    let didSwap = view.debugPerformColdLaunchSwapSynchronously(scale: 1)
    XCTAssertTrue(didSwap)

    XCTAssertEqual(try XCTUnwrap(view.debugBackendEffectiveRenderer), .slugGlyph)
    XCTAssertEqual(view.rendererSelection, .slugGlyph)
  }

  func testColdLaunchSwapKeepsCurrentNonopaqueSurfacePolicy() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    RendererSelection.set(.slugGlyph)
    let view = try makeView()
    let requested = TerminalTransparencyConfiguration(
      backgroundOpacity: 0.7,
      applyToExplicitCellBackgrounds: false,
      backdropStyle: .none)
    let effective = TerminalTransparencyPolicy.resolve(
      requested: requested,
      reduceTransparency: false,
      nativeFullscreen: false,
      supportsBehindWindowBlur: false,
      snapshotBackgroundCapability: .supported,
      headless: false)
    view.applyTransparency(requested: requested, effective: effective, wake: false)
    XCTAssertFalse(view.debugBackendSurfaceIsOpaque ?? true)

    XCTAssertTrue(view.debugPerformColdLaunchSwapSynchronously(scale: 1))

    XCTAssertEqual(view.debugBackendEffectiveRenderer, .slugGlyph)
    XCTAssertFalse(view.debugBackendSurfaceIsOpaque ?? true)
    XCTAssertEqual(view.backgroundCompositingOptionsForTesting.opacity, 179)
  }

  /// A non-glyphBackend/slug persisted selection must take the unchanged path: no
  /// cold-launch deferral, the real backend is constructed directly, and no
  /// cold-launch swap is pending.
  func testColdLaunchWithClassicPersistedDoesNotDefer() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    RendererSelection.set(.classic)

    let view = try makeView()

    XCTAssertEqual(view.rendererSelection, .classic)
    XCTAssertEqual(try XCTUnwrap(view.debugBackendEffectiveRenderer), .classic)
    XCTAssertFalse(
      view.debugPerformColdLaunchSwapSynchronously(scale: 1),
      "a classic cold launch must not defer any swap")
  }

  private func makeView(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> TerminalBitmapView {
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
      cellHeight: Int(fontAtlas.cellSize.height))
    return view
  }
}
