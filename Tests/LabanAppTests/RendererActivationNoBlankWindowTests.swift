import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class RendererActivationNoBlankWindowTests: XCTestCase {
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

  func testFirstVectorActivationNeverInstallsBlankLayer() throws {
    let harness = BackendHarness()
    let classic = ControlledBackend(selection: .classic)
    let vector = ControlledBackend(selection: .vectorGlyph)
    harness.enqueue(classic)
    harness.enqueue(vector)
    TerminalBitmapView.backendFactoryForTesting = harness.makeBackend
    RendererSelection.set(.classic)

    let view = try makeView()
    XCTAssertTrue(view.layer === classic.layer)

    view.applyRendererSelection(.vectorGlyph)

    XCTAssertEqual(view.rendererSelection, .vectorGlyph)
    XCTAssertEqual(RendererSelection.persisted(), .vectorGlyph)
    XCTAssertEqual(view.debugPendingRendererSwapSelection, .vectorGlyph)
    XCTAssertTrue(view.layer === classic.layer)
    XCTAssertEqual(vector.renderCount, 1)
    XCTAssertEqual(vector.renderedDamages, [.full])

    vector.completeFrame()
    drainMainQueue()

    XCTAssertNil(view.debugPendingRendererSwapSelection)
    XCTAssertTrue(view.layer === vector.layer)
  }

  func testRendererSwapAbandonsStalePendingSwapOnRapidReselection() throws {
    let harness = BackendHarness()
    let classic = ControlledBackend(selection: .classic)
    let vector = ControlledBackend(selection: .vectorGlyph)
    let slug = ControlledBackend(selection: .slugGlyph)
    harness.enqueue(classic)
    harness.enqueue(vector)
    harness.enqueue(slug)
    TerminalBitmapView.backendFactoryForTesting = harness.makeBackend
    RendererSelection.set(.classic)

    let view = try makeView()

    view.applyRendererSelection(.vectorGlyph)
    XCTAssertEqual(view.debugPendingRendererSwapSelection, .vectorGlyph)
    XCTAssertTrue(view.layer === classic.layer)

    view.applyRendererSelection(.slugGlyph)
    XCTAssertEqual(view.rendererSelection, .slugGlyph)
    XCTAssertEqual(view.debugPendingRendererSwapSelection, .slugGlyph)
    XCTAssertTrue(view.layer === classic.layer)

    vector.completeFrame()
    drainMainQueue()
    XCTAssertEqual(view.debugPendingRendererSwapSelection, .slugGlyph)
    XCTAssertTrue(view.layer === classic.layer)

    slug.completeFrame()
    drainMainQueue()

    XCTAssertNil(view.debugPendingRendererSwapSelection)
    XCTAssertTrue(view.layer === slug.layer)
  }

  func testRendererSwapFallsBackImmediatelyWhenFirstRenderFails() throws {
    let harness = BackendHarness()
    let classic = ControlledBackend(selection: .classic)
    let vector = ControlledBackend(selection: .vectorGlyph, renderResult: false)
    harness.enqueue(classic)
    harness.enqueue(vector)
    TerminalBitmapView.backendFactoryForTesting = harness.makeBackend
    RendererSelection.set(.classic)

    let view = try makeView()

    view.applyRendererSelection(.vectorGlyph)

    XCTAssertNil(view.debugPendingRendererSwapSelection)
    XCTAssertTrue(view.layer === vector.layer)
    XCTAssertEqual(view.rendererSelection, .vectorGlyph)
    XCTAssertEqual(vector.renderCount, 1)
    XCTAssertEqual(vector.renderedDamages, [.full])
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
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    return view
  }

  private func drainMainQueue(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expectation = expectation(description: "main queue drained")
    DispatchQueue.main.async {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }
}

final class FrameProducerTransparencyTests: XCTestCase {
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

  func testCurrentRendererFirstSettingsChangeFrameUsesNewTransparencyRequest() throws {
    let harness = BackendHarness()
    let classic = ControlledBackend(selection: .classic)
    harness.enqueue(classic)
    TerminalBitmapView.backendFactoryForTesting = harness.makeBackend
    RendererSelection.set(.classic)
    let view = try makeView()

    view.advanceFrame()
    let framesBeforeSettingsChange = classic.renderedCommandFrames.count
    XCTAssertGreaterThan(framesBeforeSettingsChange, 0, "test must establish an opaque frame first")

    applyNonopaqueTransparency(to: view)
    XCTAssertEqual(
      classic.renderedCommandFrames.count,
      framesBeforeSettingsChange,
      "wake: false must leave the changed frame pending until the caller advances")

    view.advanceFrame()

    XCTAssertFalse(classic.surfaceTransparency.isOpaque)
    XCTAssertFalse(classic.layer.isOpaque)
    let firstChangedFrame = try XCTUnwrap(
      classic.renderedCommandFrames.dropFirst(framesBeforeSettingsChange).first)
    for source in [FrameSource.terminal, .sidebar] {
      XCTAssertTrue(
        firstChangedFrame.contains { command in
          guard case .rect(_, let color, let commandSource, .replace) = command else {
            return false
          }
          return commandSource == source && (color & 0xFF) == 179
        },
        "the current renderer's first post-change frame must use alpha 179 for \(source)")
    }
  }

  func testWarmRendererSwapFirstFrameUsesCurrentTransparencyRequest() throws {
    let harness = BackendHarness()
    let classic = ControlledBackend(selection: .classic)
    let slug = ControlledBackend(selection: .slugGlyph)
    harness.enqueue(classic)
    harness.enqueue(slug)
    TerminalBitmapView.backendFactoryForTesting = harness.makeBackend
    RendererSelection.set(.classic)
    let view = try makeView()
    applyNonopaqueTransparency(to: view)

    view.applyRendererSelection(.slugGlyph)

    XCTAssertFalse(classic.surfaceTransparency.isOpaque)
    XCTAssertFalse(slug.surfaceTransparency.isOpaque)
    XCTAssertFalse(slug.layer.isOpaque)
    XCTAssertEqual(view.backgroundCompositingOptionsForTesting.opacity, 179)
    XCTAssertEqual(slug.renderCount, 1)
    XCTAssertTrue(
      slug.renderedCommandFrames.last?.contains(where: { command in
        guard case .rect(_, let color, let source, let compositing) = command else { return false }
        return (source == .terminal || source == .sidebar)
          && compositing == .replace
          && (color & 0xFF) == 179
      }) == true,
      "the hidden warm-up frame must use the current effective compositing options")

    slug.completeFrame()
    drainMainQueue()
    XCTAssertTrue(view.layer === slug.layer)
    XCTAssertFalse(view.debugBackendSurfaceIsOpaque ?? true)
  }

  private func applyNonopaqueTransparency(to view: TerminalBitmapView) {
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
    view.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
    return view
  }

  private func drainMainQueue(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expectation = expectation(description: "main queue drained")
    DispatchQueue.main.async {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)
  }
}

private final class BackendHarness {
  private var queued: [RendererSelection: [ControlledBackend]] = [:]

  func enqueue(_ backend: ControlledBackend) {
    queued[backend.selection, default: []].append(backend)
  }

  func makeBackend(
    selection: RendererSelection,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas
  ) -> RendererBackend {
    if var backends = queued[selection], !backends.isEmpty {
      let backend = backends.removeFirst()
      queued[selection] = backends
      return backend
    }
    return ControlledBackend(selection: selection)
  }
}

private final class ControlledBackend: RendererBackend {
  let selection: RendererSelection
  let layer = CALayer()
  private let renderResult: Bool
  private var pixelWidth = 1
  private var pixelHeight = 1
  private var scale: CGFloat = 1
  var renderCount = 0
  var renderedDamages: [RenderDamage] = []
  var renderedCommandFrames: [[FrameCommand]] = []
  var onFrameCompleted: (() -> Void)?
  var waitForFrameCompletion = false
  private(set) var surfaceTransparency = RendererSurfaceTransparency(isOpaque: true)

  init(selection: RendererSelection, renderResult: Bool = true) {
    self.selection = selection
    self.renderResult = renderResult
  }

  func setSurfaceTransparency(_ transparency: RendererSurfaceTransparency) {
    surfaceTransparency = transparency
    layer.isOpaque = transparency.isOpaque
  }

  @discardableResult
  func render(_ commands: [FrameCommand], damage: RenderDamage) -> Bool {
    renderCount += 1
    renderedDamages.append(damage)
    renderedCommandFrames.append(commands)
    return renderResult
  }

  @discardableResult
  func resize(pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> Bool {
    let changed =
      self.pixelWidth != pixelWidth || self.pixelHeight != pixelHeight || self.scale != scale
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.scale = scale
    return changed
  }

  var surfaceWidth: Int { pixelWidth }
  var surfaceHeight: Int { pixelHeight }
  var surfaceScale: CGFloat { scale }
  var presentationLayer: CALayer? { layer }
  var presentationImage: CGImage? { nil }
  var pngData: Data? { nil }
  var rendererStatus: RendererStatus {
    RendererStatus(
      configuredRenderer: selection.rawValue,
      effectiveRenderer: selection.rawValue)
  }

  func completeFrame() {
    onFrameCompleted?()
  }
}
