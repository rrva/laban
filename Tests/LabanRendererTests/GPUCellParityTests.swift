import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest

@testable import LabanRenderer

final class GPUCellParityTests: XCTestCase {
  private let rows = 8
  private let cols = 32
  private let cellW: CGFloat = 9
  private let cellH: CGFloat = 19
  private let scale: CGFloat = 1

  override func tearDown() {
    MetalRenderer.useClassicDamageScoped = true
    MetalRenderer.useGPUCellPath = false
    super.tearDown()
  }

  func testRendererModeDefaultsToClassicAndGatesGPUAvailability() {
    let suiteName = "GPUCellParityTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(RendererMode.persisted(defaults: defaults), .classic)

    RendererMode.set(.gpuDriven, defaults: defaults)
    if #available(macOS 26, *) {
      XCTAssertEqual(RendererMode.persisted(defaults: defaults), .gpuDriven)
    } else {
      XCTAssertEqual(RendererMode.persisted(defaults: defaults), .classic)
    }
  }

  func testClassicDamageScopedMatchesFullRebuildForOneDirtyRow() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let frameA = frame(seed: 0, changedRow: nil)
    let frameB = frame(seed: 0, changedRow: 3)
    let damage = RenderDamage.partial(yRanges: [dirtyRange(forRow: 3)])

    MetalRenderer.useClassicDamageScoped = false
    let full = try renderSequence(label: "classic-full", initial: frameA, next: frameB, damage: damage)

    MetalRenderer.useClassicDamageScoped = true
    let scoped = try renderSequence(
      label: "classic-damage-scoped",
      initial: frameA,
      next: frameB,
      damage: damage)

    XCTAssertLessThan(
      scoped.counts.glyphs,
      full.counts.glyphs,
      "damage-scoped rebuild should build only the glyphs inside the dirty-scissor union")
    try assertPixelsEqual(
      expected: full.image,
      actual: scoped.image,
      fixture: "classic-damage-one-row",
      expectedPNG: full.png,
      actualPNG: scoped.png)
  }

  func testGPUCellOriginRecordsMatchClassicGlyphInstancesForPlainText() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = frame(seed: 5, changedRow: nil)
    let renderer = try makeRenderer(label: "origin-parity")
    let classic = renderer.classicTerminalGlyphRecordsForTesting(
      commands: commands,
      surfacePxH: Int(CGFloat(rows) * cellH * scale))
    guard
      let gpu = renderer.gpuCellGlyphRecordsForTesting(
        commands: commands,
        surfacePxH: Int(CGFloat(rows) * cellH * scale))
    else {
      XCTFail("plain text should be supported by the GPU cell builder")
      return
    }

    XCTAssertEqual(gpu.count, classic.count)
    for (index, pair) in zip(classic, gpu).enumerated() {
      assertRecordBitPatternsEqual(pair.0, pair.1, label: "glyph \(index)")
    }
  }

  func testGPUCellPathRejectsUnsupportedTerminalGlyphFeatures() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "unsupported-glyph")
    let commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: cellH),
        color: 0x10_20_30_FF,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 0, y: 0),
        text: "unsupported",
        foreground: 0xFF_FF_FF_FF,
        background: 0x10_20_30_FF,
        attributes: [.underline],
        source: .terminal,
        underlineStyle: .single),
    ]

    XCTAssertFalse(
      renderer.gpuCellPathSupportedForTesting(
        commands: commands,
        surfacePxH: Int(cellH * scale)),
      "M2 must fall back to classic for decorated terminal glyph runs")
  }

  func testGPUCellPathMatchesClassicForPlainText() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = frame(seed: 11, changedRow: nil)

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpuRequested = try renderSingle(label: "gpu-requested", commands: commands, damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpuRequested.counts.cellGlyphs, 0)
      XCTAssertEqual(gpuRequested.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpuRequested.image,
      fixture: "gpu-cell-plain-text",
      expectedPNG: classic.png,
      actualPNG: gpuRequested.png)
  }

  func testGPUCellPathMatchesClassicForColorSafeAttributes() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    // faint/inverse/blink are colour/visibility-safe: FrameProducer bakes them
    // into fg/bg before emission, so both paths read the same per-run colour and
    // the cell path must render them (M4 slice 1) instead of falling back.
    let commands = attributedFrame(seed: 9)

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic-attrs", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(label: "gpu-attrs", commands: commands, damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(
        gpu.counts.cellGlyphs, 0,
        "colour-safe attributed runs must render through the GPU cell path")
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-color-safe-attrs",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadAcceptsColorSafeAttributes() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-color-safe")
    var faint = payload(seed: 41, changedRow: nil, includedRows: Array(0..<rows))
    faint.glyphs = faint.glyphs.map {
      var glyph = $0
      glyph.attributes = [.faint, .blink]
      return glyph
    }

    XCTAssertNil(
      faint.fallbackReason,
      "faint/blink payloads stay GPU-cell compatible after M4 slice 1")
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: faint,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)),
      "the GPU cell builder must accept colour-safe attributed payloads")
  }

  func testGPUCellPayloadPatchesOnlyDirtyRows() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-dirty-row")
    let initial = payload(seed: 17, changedRow: nil, includedRows: Array(0..<rows))
    let fullCounts = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: initial,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    XCTAssertEqual(fullCounts.cellGlyphs, rows * cols)
    XCTAssertEqual(renderer.cellGlyphUploadRangesForTesting, [(0..<(rows * cols))])

    let next = payload(seed: 17, changedRow: 4, includedRows: [4])
    let patchCounts = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: next,
        commands: [],
        damage: .partial(yRanges: [dirtyRange(forRow: 4)]),
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    XCTAssertEqual(patchCounts.cellGlyphs, rows * cols)
    let bottomUpRow = rows - 1 - 4
    XCTAssertEqual(
      renderer.cellGlyphUploadRangesForTesting,
      [(bottomUpRow * cols)..<((bottomUpRow + 1) * cols)])
    XCTAssertEqual(patchCounts.glyphs, 0)
  }

  func testGPUCellPayloadClearsDirtyRowWhenPatchIsSparse() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-sparse-row")
    let initial = payload(seed: 31, changedRow: nil, includedRows: Array(0..<rows))
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: initial,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))
    XCTAssertEqual(renderer.activeCellGlyphIndicesForTesting.count, rows * cols)

    var sparse = payload(seed: 32, changedRow: 4, includedRows: [4])
    sparse.glyphs = Array(sparse.glyphs.prefix(1))
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: sparse,
        commands: [],
        damage: .partial(yRanges: [dirtyRange(forRow: 4)]),
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    XCTAssertEqual(renderer.activeCellGlyphIndicesForTesting.count, (rows - 1) * cols + 1)
  }

  func testGPUCellRemoteFallbackReportsClassicStatus() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    MetalRenderer.useGPUCellPath = true
    let renderer = try makeRenderer(label: "remote-fallback-status")
    XCTAssertTrue(
      renderer.render(
        frame(seed: 23, changedRow: nil),
        cellPayload: nil,
        damage: .full,
        rendererFallbackReason: "remoteSnapshotPayloadIncomplete"))
    renderer.waitForLastFrame()

    XCTAssertEqual(renderer.rendererStatus.configuredRenderer, RendererMode.gpuDriven.rawValue)
    XCTAssertEqual(renderer.rendererStatus.effectiveRenderer, RendererMode.classic.rawValue)
    XCTAssertEqual(renderer.rendererStatus.fallbackReason, "remoteSnapshotPayloadIncomplete")
    XCTAssertGreaterThan(renderer.lastInstanceCounts.glyphs, 0)
    XCTAssertEqual(renderer.lastInstanceCounts.cellGlyphs, 0)
  }

  private func frame(seed: Int, changedRow: Int?) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var commands: [FrameCommand] = []
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let changed = changedRow == row
      let base = UInt32((seed + row * 17) & 0xFF)
      let bg: UInt32 =
        changed
        ? 0x22_66_AA_FF
        : ((0x10 + base) << 24) | ((0x20 + base) << 16) | ((0x30 + base) << 8) | 0xFF
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      let line = String((0..<cols).map { ascii[($0 + row + seed + (changed ? 7 : 0)) % ascii.count] })
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: line,
          foreground: changed ? 0xFF_FF_00_FF : 0xDD_EE_EE_FF,
          background: bg,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private func attributedFrame(seed: Int) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    // Cycle colour/visibility-safe attribute combinations across rows. Both the
    // classic and GPU-cell paths read the run's pre-resolved colour, so any
    // value renders identically — the point is that the attribute bits no longer
    // force a fallback.
    let attributeCycle: [TextAttributes] = [
      [], [.faint], [.bold, .faint], [.inverse], [.blink], [.bold, .italic, .faint], [.italic], [],
    ]
    var commands: [FrameCommand] = []
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 17) & 0xFF)
      let bg: UInt32 =
        ((0x10 + base) << 24) | ((0x20 + base) << 16) | ((0x30 + base) << 8) | 0xFF
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      let line = String((0..<cols).map { ascii[($0 + row + seed) % ascii.count] })
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: line,
          foreground: 0xCC_DD_EE_FF,
          background: bg,
          attributes: attributeCycle[row % attributeCycle.count],
          source: .terminal))
    }
    return commands
  }

  private func payload(
    seed: Int,
    changedRow: Int?,
    includedRows: [Int]
  ) -> TerminalCellPayload {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: includedRows)
    for row in includedRows {
      let changed = changedRow == row
      let base = UInt32((seed + row * 17) & 0xFF)
      let bg: UInt32 =
        changed
        ? 0x22_66_AA_FF
        : ((0x10 + base) << 24) | ((0x20 + base) << 16) | ((0x30 + base) << 8) | 0xFF
      payload.backgroundRuns.append(
        .init(row: row, startCol: 0, colCount: cols, color: bg))
      for col in 0..<cols {
        let scalar = ascii[(col + row + seed + (changed ? 7 : 0)) % ascii.count]
        let text = String(scalar)
        payload.glyphs.append(
          .init(
            row: row,
            col: col,
            text: text,
            scalarValue: scalar.unicodeScalars.first?.value,
            foreground: changed ? 0xFF_FF_00_FF : 0xDD_EE_EE_FF,
            background: bg,
            attributes: []))
      }
    }
    return payload
  }

  private func dirtyRange(forRow row: Int) -> DirtyYRange {
    DirtyYRange(y: CGFloat(rows - 1 - row) * cellH, height: cellH)
  }

  private func makeRenderer(label: String) throws -> MetalRenderer {
    let fontAtlas = FontAtlas(pointSize: 14)
    guard let renderer = MetalRenderer(fontAtlas: fontAtlas, scale: scale) else {
      XCTFail("\(label): MetalRenderer.init returned nil")
      throw TestFailure()
    }
    renderer.captureMode = true
    renderer.waitForFrameCompletion = true
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: scale)
    return renderer
  }

  private func renderSingle(
    label: String,
    commands: [FrameCommand],
    damage: RenderDamage
  ) throws -> RenderResult {
    let renderer = try makeRenderer(label: label)
    XCTAssertTrue(renderer.render(commands, damage: damage), "\(label): render failed")
    renderer.waitForLastFrame()
    return try readResult(renderer: renderer, label: label)
  }

  private func renderSequence(
    label: String,
    initial: [FrameCommand],
    next: [FrameCommand],
    damage: RenderDamage
  ) throws -> RenderResult {
    let renderer = try makeRenderer(label: label)
    XCTAssertTrue(renderer.render(initial, damage: .full), "\(label): initial render failed")
    renderer.waitForLastFrame()
    XCTAssertTrue(renderer.render(next, damage: damage), "\(label): update render failed")
    renderer.waitForLastFrame()
    return try readResult(renderer: renderer, label: label)
  }

  private func readResult(renderer: MetalRenderer, label: String) throws -> RenderResult {
    guard let png = renderer.pngData else {
      XCTFail("\(label): renderer did not produce pngData")
      throw TestFailure()
    }
    return RenderResult(
      png: png,
      image: try decodeRGBA(png),
      counts: renderer.lastInstanceCounts)
  }

  private struct RenderResult {
    var png: Data
    var image: RGBAImage
    var counts: MetalRenderer.RenderInstanceCounts
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  private struct TestFailure: Error {}

  private func assertRecordBitPatternsEqual(
    _ expected: GPUCellGlyphRecord,
    _ actual: GPUCellGlyphRecord,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertSIMD2BitsEqual(expected.originPx, actual.originPx, "\(label) originPx", file: file, line: line)
    assertSIMD2BitsEqual(expected.sizePx, actual.sizePx, "\(label) sizePx", file: file, line: line)
    assertSIMD2BitsEqual(expected.uvOrigin, actual.uvOrigin, "\(label) uvOrigin", file: file, line: line)
    assertSIMD2BitsEqual(expected.uvSize, actual.uvSize, "\(label) uvSize", file: file, line: line)
    assertSIMD4BitsEqual(expected.color, actual.color, "\(label) color", file: file, line: line)
    XCTAssertEqual(expected.flags, actual.flags, "\(label) flags", file: file, line: line)
  }

  private func assertSIMD2BitsEqual(
    _ expected: SIMD2<Float>,
    _ actual: SIMD2<Float>,
    _ label: String,
    file: StaticString,
    line: UInt
  ) {
    XCTAssertEqual(expected.x.bitPattern, actual.x.bitPattern, "\(label).x", file: file, line: line)
    XCTAssertEqual(expected.y.bitPattern, actual.y.bitPattern, "\(label).y", file: file, line: line)
  }

  private func assertSIMD4BitsEqual(
    _ expected: SIMD4<Float>,
    _ actual: SIMD4<Float>,
    _ label: String,
    file: StaticString,
    line: UInt
  ) {
    XCTAssertEqual(expected.x.bitPattern, actual.x.bitPattern, "\(label).x", file: file, line: line)
    XCTAssertEqual(expected.y.bitPattern, actual.y.bitPattern, "\(label).y", file: file, line: line)
    XCTAssertEqual(expected.z.bitPattern, actual.z.bitPattern, "\(label).z", file: file, line: line)
    XCTAssertEqual(expected.w.bitPattern, actual.w.bitPattern, "\(label).w", file: file, line: line)
  }

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw TestFailure()
    }
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: bitmapInfo)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RGBAImage(width: width, height: height, bytes: bytes)
  }

  private func assertPixelsEqual(
    expected: RGBAImage,
    actual: RGBAImage,
    fixture: String,
    expectedPNG: Data,
    actualPNG: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    guard expected.width == actual.width, expected.height == actual.height else {
      writeArtifacts(fixture: fixture, expectedPNG: expectedPNG, actualPNG: actualPNG, diff: nil)
      XCTFail(
        "\(fixture): dimensions differ expected \(expected.width)x\(expected.height), actual \(actual.width)x\(actual.height)",
        file: file,
        line: line)
      return
    }
    guard expected.bytes == actual.bytes else {
      var first: (x: Int, y: Int, expected: [UInt8], actual: [UInt8])?
      var differingPixels = 0
      var maxDelta = 0
      var diff = [UInt8](repeating: 0, count: expected.width * expected.height * 4)
      for pixel in 0..<(expected.width * expected.height) {
        let offset = pixel * 4
        let expectedRGBA = Array(expected.bytes[offset..<(offset + 4)])
        let actualRGBA = Array(actual.bytes[offset..<(offset + 4)])
        if expectedRGBA != actualRGBA {
          differingPixels += 1
          if first == nil {
            first = (
              x: pixel % expected.width,
              y: pixel / expected.width,
              expected: expectedRGBA,
              actual: actualRGBA)
          }
          for channel in 0..<4 {
            maxDelta = max(
              maxDelta,
              abs(Int(expected.bytes[offset + channel]) - Int(actual.bytes[offset + channel])))
          }
          diff[offset + 0] = 255
          diff[offset + 1] = 0
          diff[offset + 2] = 255
          diff[offset + 3] = 255
        } else {
          diff[offset + 3] = 255
        }
      }
      let diffPNG = makePNG(width: expected.width, height: expected.height, rgba: diff)
      writeArtifacts(
        fixture: fixture,
        expectedPNG: expectedPNG,
        actualPNG: actualPNG,
        diff: diffPNG)
      let firstText =
        first.map {
          "first diff (\($0.x), \($0.y)) expected \($0.expected) actual \($0.actual)"
        } ?? "first diff unavailable"
      XCTFail(
        "\(fixture): \(firstText); differing pixels \(differingPixels); max channel delta \(maxDelta)",
        file: file,
        line: line)
      throw TestFailure()
    }
  }

  private func writeArtifacts(
    fixture: String,
    expectedPNG: Data,
    actualPNG: Data,
    diff: Data?
  ) {
    let env = ProcessInfo.processInfo.environment
    let base = URL(fileURLWithPath: env["LABAN_ARTIFACTS"] ?? ".artifacts", isDirectory: true)
      .appendingPathComponent("GPUCellParityTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    try? expectedPNG.write(to: base.appendingPathComponent("\(fixture).expected.png"))
    try? actualPNG.write(to: base.appendingPathComponent("\(fixture).actual.png"))
    if let diff {
      try? diff.write(to: base.appendingPathComponent("\(fixture).diff.png"))
    }
  }

  private func makePNG(width: Int, height: Int, rgba: [UInt8]) -> Data? {
    var bytes = rgba
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    var image: CGImage?
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: bitmapInfo)
      else { return }
      image = context.makeImage()
    }
    guard let image else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }
}
