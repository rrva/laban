import CoreGraphics
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// Kitty graphics image quads render the same through every selectable
/// renderer: software, classic, gpuDriven (command and cell-payload paths) and
/// Slug (execplans/active/kitty-graphics-rendering.md, Milestone 3).
final class KittyImageParityTests: XCTestCase {
  private let scale: CGFloat = 2
  private let width: CGFloat = 160  // points
  private let height: CGFloat = 120
  private let defaultBackground: UInt32 = 0x2020_20FF
  private var imageId: UInt64 = 0

  override func setUp() {
    super.setUp()
    imageId = UInt64.random(in: (1 << 62)...(UInt64.max - 1))
    // 2x2 straight RGBA: red, green / blue, white (top row first).
    FrameImageStore.shared.put(
      FrameImage(
        width: 2, height: 2,
        rgba: Data([
          0xFF, 0, 0, 0xFF, 0, 0xFF, 0, 0xFF,
          0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        ])),
      for: imageId)
  }

  override func tearDown() {
    FrameImageStore.shared.remove([imageId])
    super.tearDown()
  }

  /// FrameProducer order: terminal fill, below-background image, explicit
  /// cell backgrounds, below-text image, selection/find/underline solids,
  /// (text), above-text image.
  private var scene: [FrameCommand] {
    func quad(_ rect: CGRect, _ layer: ImageLayer) -> FrameCommand {
      .texturedQuad(
        rect: rect, resourceId: imageId, source: .image, layer: layer,
        sourceRect: CGRect(x: 0, y: 0, width: 2, height: 2))
    }
    return [
      .rect(
        CGRect(x: 0, y: 0, width: width, height: height), color: defaultBackground,
        source: .terminal, compositing: .replace),
      quad(CGRect(x: 0, y: 0, width: 80, height: 40), .belowBackground),
      .rect(
        CGRect(x: 0, y: 0, width: 40, height: 40), color: 0x0000_AAFF, source: .terminal,
        compositing: .replace),
      .rect(
        CGRect(x: 100, y: 0, width: 40, height: 40), color: 0x00AA_00FF, source: .terminal,
        compositing: .replace),
      quad(CGRect(x: 0, y: 60, width: 80, height: 40), .belowText),
      // Selection (like find highlights and underlines) draws over below-text
      // images.
      .selection(CGRect(x: 0, y: 60, width: 20, height: 10), color: 0xFF00_FFFF),
      quad(CGRect(x: 100, y: 0, width: 40, height: 40), .aboveText),
    ]
  }

  /// (x, y) in points with a bottom-left origin, like FrameCommand rects.
  private let probes: [(x: CGFloat, y: CGFloat, rgb: UInt32, what: String)] = [
    (20, 10, 0x0000AA, "below-background image hidden by an explicit cell background"),
    (60, 30, 0x00FF00, "below-background image shows over the default background"),
    (60, 10, 0xFFFFFF, "below-background image, bottom-right quadrant"),
    (20, 90, 0xFF0000, "below-text image, top-left quadrant"),
    (60, 90, 0x00FF00, "below-text image, top-right quadrant"),
    (20, 70, 0x0000FF, "below-text image, bottom-left quadrant"),
    (10, 65, 0xFF00FF, "selection draws over a below-text image"),
    (60, 70, 0xFFFFFF, "below-text image, bottom-right quadrant"),
    (110, 30, 0xFF0000, "above-text image covers an explicit cell background"),
    (130, 10, 0xFFFFFF, "above-text image, bottom-right quadrant"),
    (150, 110, 0x202020, "outside every image"),
  ]

  func testEveryRendererDrawsTheSameImages() throws {
    let software = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 14), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
      scale: scale)
    XCTAssertTrue(software.render(scene, damage: .full))
    assertProbes(try XCTUnwrap(software.pngData), renderer: "software")

    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    assertProbes(try metal(gpuDriven: false), renderer: "classic")
    if RendererMode.gpuDriven.isAvailableOnCurrentOS {
      assertProbes(try metal(gpuDriven: true), renderer: "gpuDriven commands")
      assertProbes(try metalPayload(), renderer: "gpuDriven payload")
    }
    assertProbes(try slug(), renderer: "slugGlyph")
    // Translucent Slug composites into a linear rgba16Float working target
    // with its own image pipeline; the scene is opaque, so pixels match.
    assertProbes(try slug(translucent: true), renderer: "slugGlyph translucent")
  }

  func testPartialDamageRepaintsImagesInsideTheDirtyBand() throws {
    try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
    // A second frame dirtying only the band through the below-text image's
    // lower half must repaint that half from the image, not leave it blank.
    let band = RenderDamage.partial(yRanges: [DirtyYRange(y: 60, height: 20)])
    assertProbes(try metal(gpuDriven: false, then: band), renderer: "classic partial")
    assertProbes(try slug(then: band), renderer: "slugGlyph partial")
  }

  // MARK: - Renderers

  private var pixelWidth: Int { Int(width * scale) }
  private var pixelHeight: Int { Int(height * scale) }

  private func metal(gpuDriven: Bool, then damage: RenderDamage? = nil) throws -> Data {
    let renderer = try XCTUnwrap(MetalRenderer(fontAtlas: FontAtlas(pointSize: 14), scale: scale))
    let previous = MetalRenderer.useGPUCellPath
    MetalRenderer.useGPUCellPath = gpuDriven
    defer { MetalRenderer.useGPUCellPath = previous }
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
    XCTAssertTrue(renderer.render(scene, damage: .full))
    renderer.waitForLastFrame()
    if let damage {
      XCTAssertTrue(renderer.render(scene, damage: damage))
      renderer.waitForLastFrame()
    }
    return try XCTUnwrap(renderer.pngData)
  }

  /// The gpuDriven cell-payload path: backgrounds come from the payload and
  /// images ride the overlay commands, as TerminalSurfaceController sends them.
  private func metalPayload() throws -> Data {
    let renderer = try XCTUnwrap(
      MetalRenderer(fontAtlas: FontAtlas(pointSize: 14), scale: scale, rendererMode: .gpuDriven))
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
    // 16x12 cells of 10x10 pt; rows are top-down, so the bottom row is 11.
    var payload = TerminalCellPayload(
      rows: 12, cols: 16, origin: .zero, cellSize: CGSize(width: 10, height: 10),
      contentYOffset: 0, defaultBackground: defaultBackground, dirtyRows: Array(0..<12))
    for row in 8..<12 {
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: 4, color: 0x0000_AAFF))
      payload.backgroundRuns.append(
        .init(row: row, startCol: 10, colCount: 4, color: 0x00AA_00FF))
    }
    let overlays = scene.filter {
      switch $0 {
      case .texturedQuad, .selection: return true
      default: return false
      }
    }
    XCTAssertTrue(renderer.render(overlays, cellPayload: payload, damage: .full))
    renderer.waitForLastFrame()
    return try XCTUnwrap(renderer.pngData)
  }

  private func slug(then damage: RenderDamage? = nil, translucent: Bool = false) throws -> Data {
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: FontAtlas(pointSize: 14), pixelWidth: pixelWidth, pixelHeight: pixelHeight,
        scale: scale,
        surfaceTransparency: RendererSurfaceTransparency(isOpaque: !translucent)))
    renderer.waitForFrameCompletion = true
    XCTAssertTrue(renderer.render(scene, damage: .full))
    if let damage {
      XCTAssertTrue(renderer.render(scene, damage: damage))
    }
    return try XCTUnwrap(renderer.pngData)
  }

  // MARK: - Probing

  private func assertProbes(
    _ png: Data, renderer: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let pixels = decode(png) else {
      return XCTFail("\(renderer): PNG did not decode", file: file, line: line)
    }
    for probe in probes {
      let x = Int(probe.x * scale)
      let y = pixels.height - 1 - Int(probe.y * scale)
      let i = (y * pixels.width + x) * 4
      let actual = [pixels.bytes[i], pixels.bytes[i + 1], pixels.bytes[i + 2]].map(Int.init)
      let expected = [16, 8, 0].map { Int((probe.rgb >> UInt32($0)) & 0xFF) }
      let delta = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
      XCTAssertLessThanOrEqual(
        delta, 10, "\(renderer): \(probe.what) at (\(probe.x), \(probe.y)) is \(actual)",
        file: file, line: line)
    }
  }

  /// Straight RGBA8 in sRGB, row 0 = top.
  private func decode(_ png: Data) -> (width: Int, height: Int, bytes: [UInt8])? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = CGColorSpace(name: CGColorSpace.sRGB)
    else { return nil }
    let w = image.width
    let h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
          bytesPerRow: w * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    return drawn ? (w, h, bytes) : nil
  }
}
