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
    let full = try renderSequence(
      label: "classic-full", initial: frameA, next: frameB, damage: damage)

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

  func testGPUCellPathMatchesClassicForHyperlinkVisuals() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = hyperlinkFrame(seed: 29)

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic-hyperlink", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(label: "gpu-hyperlink", commands: commands, damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-hyperlink-visuals",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
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

  func testGPUCellPathMatchesClassicForTextDecorations() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = decoratedFrame(seed: 13)

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic-decorations", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(label: "gpu-decorations", commands: commands, damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(
        gpu.counts.cellGlyphs, 0,
        "decorated terminal runs must stay on the GPU cell path")
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-text-decorations",
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

  func testGPUCellPayloadAcceptsTextDecorations() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-decorations")
    let decorated = decoratedPayload(seed: 17, includedRows: Array(0..<rows))

    XCTAssertNil(decorated.fallbackReason)
    let counts = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: decorated,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)),
      "decorated payloads must stay GPU-cell compatible")

    XCTAssertEqual(counts.cellGlyphs, rows * cols)
    XCTAssertEqual(counts.glyphs, 0)
    XCTAssertGreaterThan(counts.solids, rows)
  }

  /// IME/dictation preedit must render in the GPU-cell *payload* path too — the
  /// one path that drops non-sidebar glyph runs, so it needs explicit handling.
  /// FrameProducer emits the composition as a `.preedit` background mask + an
  /// underlined glyph run at the cursor; the with-payload builder overwrites the
  /// cells under the caret with those terminal-atlas glyphs. We can't assert
  /// glyph identity through the counts hook (overwriting keeps the cell count
  /// flat), so we assert the path runs without failing closed and that the mask
  /// + underline land as extra solid instances.
  func testGPUCellPayloadRendersPreeditComposition() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-preedit")
    let pl = decoratedPayload(seed: 7, includedRows: Array(0..<rows))
    let surfacePxH = Int(CGFloat(rows) * cellH * scale)

    let base = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: pl, commands: [], damage: .full, surfacePxH: surfacePxH))
    XCTAssertNil(renderer.lastGPUCellPayloadBuildFailure)

    // A composition at the cursor cell (payload row 2, col 3), positioned and
    // shaped exactly as `FrameProducer.appendPreedit` produces it.
    let cursorCol = 3
    let cx = CGFloat(cursorCol) * cellW
    let cy = CGFloat(rows - 1 - 2) * cellH
    let text = "abc"
    let preedit: [FrameCommand] = [
      .rect(
        CGRect(x: cx, y: cy, width: CGFloat(text.count) * cellW, height: cellH),
        color: 0x10_20_30_FF, source: .preedit),
      .glyphRun(
        origin: CGPoint(x: cx, y: cy), text: text,
        foreground: 0xFF_FF_FF_FF, background: 0x10_20_30_FF,
        attributes: [.underline], source: .preedit,
        underlineStyle: .single, underlineColor: nil, hyperlink: nil),
    ]
    let composed = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: pl, commands: preedit, damage: .full, surfacePxH: surfacePxH))

    XCTAssertNil(
      renderer.lastGPUCellPayloadBuildFailure,
      "the GPU-cell payload builder must accept a preedit overlay, not fail closed")
    XCTAssertEqual(
      composed.cellGlyphs, base.cellGlyphs,
      "preedit overwrites the cells under the caret rather than adding new ones")
    XCTAssertGreaterThan(
      composed.solids, base.solids,
      "the preedit background mask + underline must land as extra solid instances")
  }

  func testGPUCellPayloadBuildFailureFailsClosedThenCommandRetryRendersGlyphs() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if #unavailable(macOS 26) {
      throw XCTSkip("GPU cell renderer is gated to macOS 26")
    }

    MetalRenderer.useGPUCellPath = true
    let renderer = try makeRenderer(label: "payload-build-failure")
    var badPayload = payload(seed: 23, changedRow: nil, includedRows: Array(0..<rows))
    badPayload.glyphs[0].text = ""
    badPayload.glyphs[0].scalarValue = nil
    badPayload.glyphs[0].utf8Range = nil

    XCTAssertNil(badPayload.fallbackReason)
    XCTAssertFalse(
      renderer.render(
        [],
        cellPayload: badPayload,
        damage: .full,
        rendererFallbackReason: nil),
      "a supplied payload cannot safely fall back to commands after terminal commands were skipped")
    let failure = try XCTUnwrap(renderer.lastGPUCellPayloadBuildFailure)
    XCTAssertEqual(failure.reason, "missingGlyphText")
    XCTAssertEqual(failure.row, 0)
    XCTAssertEqual(failure.col, 0)
    XCTAssertEqual(failure.utf8ByteCount, badPayload.utf8Bytes.count)

    XCTAssertTrue(
      renderer.render(
        frame(seed: 23, changedRow: nil),
        cellPayload: nil,
        damage: .full,
        rendererFallbackReason: nil),
      "after a payload failure, the command-mode retry must repaint safely")
    renderer.waitForLastFrame()
    XCTAssertGreaterThan(
      renderer.lastInstanceCounts.cellGlyphs,
      0,
      "command-mode retry should rebuild glyphs instead of preserving a blank target")
  }

  func testGPUCellCommandPathRejectsPartialWhenGridGeometryChanges() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if #unavailable(macOS 26) {
      throw XCTSkip("GPU cell renderer is gated to macOS 26")
    }

    MetalRenderer.useGPUCellPath = true
    MetalRenderer.useClassicDamageScoped = true
    let renderer = try makeRenderer(label: "command-geometry-change")
    let surfacePxH = Int(CGFloat(rows) * cellH * scale)

    // A full command-fed GPU-cell build at geometry A (terminal origin x = 0)
    // primes the retained cell cache.
    XCTAssertNotNil(
      renderer.rebuildGPUCellInstancesForTesting(
        commands: frame(seed: 0, changedRow: nil),
        damage: .full,
        surfacePxH: surfacePxH))

    // A partial build whose terminal grid geometry differs (origin shifted by
    // one cell) needs a full cache rebuild; honouring it as a partial scissor
    // update would leave stale geometry-A pixels in the clean rows outside the
    // band. The build must signal requires-full-redraw (nil), mirroring the
    // payload path's fail-closed geometry guard.
    let geometryB = shiftCommandsX(frame(seed: 0, changedRow: 3), by: cellW)
    XCTAssertNil(
      renderer.rebuildGPUCellInstancesForTesting(
        commands: geometryB,
        damage: .partial(yRanges: [dirtyRange(forRow: 3)]),
        surfacePxH: surfacePxH),
      "command-fed GPU-cell partial build must reject a grid geometry change and require a full redraw"
    )
  }

  private func shiftCommandsX(_ commands: [FrameCommand], by dx: CGFloat) -> [FrameCommand] {
    commands.map { command in
      switch command {
      case .rect(let rect, let color, let source):
        return .rect(rect.offsetBy(dx: dx, dy: 0), color: color, source: source)
      case .glyphRun(
        let origin, let text, let fg, let bg, let attrs, let source, let us, let uc, let link):
        return .glyphRun(
          origin: CGPoint(x: origin.x + dx, y: origin.y),
          text: text, foreground: fg, background: bg, attributes: attrs, source: source,
          underlineStyle: us, underlineColor: uc, hyperlink: link)
      default:
        return command
      }
    }
  }

  func testGPUCellPayloadSparseDirtyRowsPreserveCleanRowsInsideDamageUnion() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if #unavailable(macOS 26) {
      throw XCTSkip("GPU cell renderer is gated to macOS 26")
    }

    MetalRenderer.useGPUCellPath = true
    MetalRenderer.useClassicDamageScoped = true
    let renderer = try makeRenderer(label: "sparse-partial-preserves-clean-rows")
    let defaultBg: UInt32 = 0x10_20_30_FF

    // Production appends a full-viewport terminal-area background rect alongside
    // the cell payload (TerminalSurfaceController.makeFrame, when
    // includeTerminalAreaBackground is set), and canSkipTerminalCommands does
    // not remove it. Mirror that here.
    let terminalAreaBackground: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: defaultBg,
        source: .terminal)
    ]

    // Full frame: every row carries a distinct, non-default background.
    let fullPayload = distinctBackgroundPayload(includedRows: Array(0..<rows), defaultBg: defaultBg)
    XCTAssertTrue(
      renderer.render(
        terminalAreaBackground, cellPayload: fullPayload, damage: .full, rendererFallbackReason: nil
      ))
    renderer.waitForLastFrame()
    let expected = try readResult(renderer: renderer, label: "sparse-full")

    // Partial frame: only the first and last rows are dirty. They are
    // non-contiguous, so the damage-union scissor spans the whole surface and
    // includes every clean interior row. Those rows must keep the backgrounds
    // painted by the full frame.
    let partialPayload = distinctBackgroundPayload(
      includedRows: [0, rows - 1], defaultBg: defaultBg)
    let damage = RenderDamage.partial(yRanges: [
      dirtyRange(forRow: 0), dirtyRange(forRow: rows - 1),
    ])
    XCTAssertTrue(
      renderer.render(
        terminalAreaBackground, cellPayload: partialPayload, damage: damage,
        rendererFallbackReason: nil))
    renderer.waitForLastFrame()
    let actual = try readResult(renderer: renderer, label: "sparse-partial")

    XCTAssertEqual(actual.image.bytes.count, expected.image.bytes.count)
    let changedBytes = zip(actual.image.bytes, expected.image.bytes).reduce(into: 0) {
      if $1.0 != $1.1 { $0 += 1 }
    }
    XCTAssertEqual(
      changedBytes, 0,
      "sparse partial payload wiped \(changedBytes) bytes of clean interior rows inside the damage-union scissor"
    )
  }

  private func distinctBackgroundPayload(includedRows: [Int], defaultBg: UInt32)
    -> TerminalCellPayload
  {
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: defaultBg,
      dirtyRows: includedRows)
    for row in includedRows {
      let base = UInt32((row * 29 + 0x40) & 0xFF)
      let bg: UInt32 =
        ((0x40 + base) << 24) | ((0x60 + base) << 16) | ((0x80 + base) << 8) | 0xFF
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
    }
    return payload
  }

  // Regression: a GPU-cell partial-damage frame must be pixel-identical to a full
  // redraw of the same content. The cell-glyph pass draws the *persistent full
  // grid*, clipped only by the damage scissor. When two dirty rows are
  // non-contiguous (Claude Code's spinner far from its updating output line) the
  // union bounding-box scissor spans the clean interior rows between them. Those
  // rows carry no fresh background solid — the payload emits backgrounds only for
  // dirty rows — so re-running the glyph pass over them re-composites their
  // anti-aliased edges onto the loaded target each frame: the text accumulates
  // and the screen shimmers. The fix scissors the glyph pass to each dirty Y
  // range so clean interior rows stay untouched by the load action. Latent in the
  // GPU-cell partial path (238beaf); surfaced once noteOutput stopped forcing full
  // damage on every output tick (10289cf).
  func testGPUCellPartialDamageMatchesFullRedrawWithGappedDirtyRows() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if #unavailable(macOS 26) {
      throw XCTSkip("GPU cell renderer is gated to macOS 26")
    }
    MetalRenderer.useGPUCellPath = true
    MetalRenderer.useClassicDamageScoped = true

    let defaultBg: UInt32 = 0x10_20_30_FF
    let terminalAreaBackground: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: defaultBg,
        source: .terminal)
    ]

    // Two non-contiguous dirty rows leave clean rows between them, so the
    // damage-union scissor spans the gap.
    let dirtyRows = [1, rows - 2]
    let baseSeed = 1
    let changedSeed = 9
    let allRows = Array(0..<rows)

    // Frame A: every row at the base seed.
    let frameA = griddedPayload(
      includedRows: allRows, defaultBg: defaultBg, rowSeed: { _ in baseSeed })
    // Frame B (full reference): only the dirty rows change; clean rows keep the
    // base seed so they are byte-identical to frame A — exactly what a faithful
    // partial frame must reproduce.
    let frameBFull = griddedPayload(
      includedRows: allRows, defaultBg: defaultBg,
      rowSeed: { dirtyRows.contains($0) ? changedSeed : baseSeed })
    // Frame B (partial payload): carries only the dirty rows, as FrameProducer
    // emits a partial frame.
    let frameBPartial = griddedPayload(
      includedRows: dirtyRows, defaultBg: defaultBg, rowSeed: { _ in changedSeed })
    let damage = RenderDamage.partial(yRanges: dirtyRows.map { dirtyRange(forRow: $0) })

    let rPartial = try makeRenderer(label: "gapped-partial")
    XCTAssertTrue(
      rPartial.render(
        terminalAreaBackground, cellPayload: frameA, damage: .full, rendererFallbackReason: nil))
    rPartial.waitForLastFrame()
    XCTAssertTrue(
      rPartial.render(
        terminalAreaBackground, cellPayload: frameBPartial, damage: damage,
        rendererFallbackReason: nil))
    rPartial.waitForLastFrame()
    let partial = try readResult(renderer: rPartial, label: "gapped-partial")

    let rFull = try makeRenderer(label: "gapped-full")
    XCTAssertTrue(
      rFull.render(
        terminalAreaBackground, cellPayload: frameA, damage: .full, rendererFallbackReason: nil))
    rFull.waitForLastFrame()
    XCTAssertTrue(
      rFull.render(
        terminalAreaBackground, cellPayload: frameBFull, damage: .full,
        rendererFallbackReason: nil))
    rFull.waitForLastFrame()
    let full = try readResult(renderer: rFull, label: "gapped-full")

    try assertPixelsEqual(
      expected: full.image,
      actual: partial.image,
      fixture: "gpu-partial-gapped-vs-full",
      expectedPNG: full.png,
      actualPNG: partial.png)
  }

  /// A full-grid cell payload whose per-row glyphs and background colour are
  /// derived deterministically from `rowSeed(row)`, so rows sharing a seed across
  /// two payloads are byte-identical. `includedRows` controls which rows the
  /// payload actually carries (the whole grid for a full frame, the dirty subset
  /// for a partial one).
  private func griddedPayload(
    includedRows: [Int], defaultBg: UInt32, rowSeed: (Int) -> Int
  ) -> TerminalCellPayload {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: defaultBg,
      dirtyRows: includedRows)
    let alpha = defaultBg & 0xFF
    for row in includedRows {
      let seed = rowSeed(row)
      let base = UInt32((seed + row * 17) & 0x1F)
      let bg: UInt32 =
        ((0x20 + base) << 24) | ((0x30 + base) << 16) | ((0x40 + base) << 8) | alpha
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
      for col in 0..<cols {
        let scalar = ascii[(col + row + seed) % ascii.count]
        payload.glyphs.append(
          .init(
            row: row,
            col: col,
            text: String(scalar),
            scalarValue: scalar.unicodeScalars.first?.value,
            foreground: 0xDD_EE_EE_FF,
            background: bg,
            attributes: []))
      }
    }
    return payload
  }

  func testRenderFailureReasonReportsFullRedrawNoContentAndClearsOnSuccess() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if #unavailable(macOS 26) {
      throw XCTSkip("GPU cell renderer is gated to macOS 26")
    }

    MetalRenderer.useGPUCellPath = true
    let renderer = try makeRenderer(label: "render-failure-reason")

    // A payload that cannot build forces a full redraw that produces no
    // content. The frame is dropped, but with a specific, inspectable reason
    // instead of a bare `false`.
    var badPayload = payload(seed: 5, changedRow: nil, includedRows: Array(0..<rows))
    badPayload.glyphs[0].text = ""
    badPayload.glyphs[0].scalarValue = nil
    badPayload.glyphs[0].utf8Range = nil
    XCTAssertFalse(
      renderer.render([], cellPayload: badPayload, damage: .full, rendererFallbackReason: nil))
    XCTAssertEqual(renderer.lastRenderFailureReason, .fullRedrawProducedNoContent)

    // The command-mode retry repaints successfully and clears the reason.
    XCTAssertTrue(
      renderer.render(
        frame(seed: 5, changedRow: nil),
        cellPayload: nil,
        damage: .full,
        rendererFallbackReason: nil))
    renderer.waitForLastFrame()
    XCTAssertNil(renderer.lastRenderFailureReason)
  }

  func testCommandBufferErrorIsRecordedAndQueuesFullRedrawRecovery() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try makeRenderer(label: "cmdbuf-error")
    XCTAssertNil(renderer.lastCommandBufferError)
    XCTAssertFalse(renderer.hasPendingCommandBufferRecoveryForTesting)

    renderer.noteCommandBufferCompletionForTesting(
      status: .error,
      error: NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "GPU hang"]))

    XCTAssertEqual(
      renderer.lastCommandBufferError?.status, Int(MTLCommandBufferStatus.error.rawValue))
    XCTAssertEqual(renderer.lastCommandBufferError?.error, "GPU hang")
    XCTAssertTrue(renderer.hasPendingCommandBufferRecoveryForTesting)
  }

  func testSuccessfulCommandBufferCompletionRecordsNoErrorOrRecovery() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try makeRenderer(label: "cmdbuf-ok")
    renderer.noteCommandBufferCompletionForTesting(status: .completed, error: nil)
    XCTAssertNil(renderer.lastCommandBufferError)
    XCTAssertFalse(renderer.hasPendingCommandBufferRecoveryForTesting)
  }

  func testPendingCommandBufferRecoveryIsConsumedByNextRender() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let renderer = try makeRenderer(label: "cmdbuf-recovery")
    XCTAssertTrue(renderer.render(frame(seed: 1, changedRow: nil), damage: .full))
    renderer.waitForLastFrame()

    // Simulate a GPU command-buffer failure that the off-main completion handler
    // would record.
    renderer.noteCommandBufferCompletionForTesting(status: .error, error: nil)
    XCTAssertTrue(renderer.hasPendingCommandBufferRecoveryForTesting)

    // The next render — even a partial one — must consume the recovery (and force
    // a full repaint), so the flag is cleared afterwards.
    XCTAssertTrue(
      renderer.render(
        frame(seed: 1, changedRow: 3),
        damage: .partial(yRanges: [dirtyRange(forRow: 3)])))
    renderer.waitForLastFrame()
    XCTAssertFalse(
      renderer.hasPendingCommandBufferRecoveryForTesting,
      "the next render must consume the pending GPU-error recovery")
  }

  func testGPUGlyphInkVerticalExtentMatchesSoftwareForTallClusters() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    // The GPU glyph atlas rasterizes each cluster into a tile exactly one cell
    // tall (MetalGlyphAtlas: pixelH = cellHeight * scale) with no vertical slop,
    // so ink above the cell top or below the cell bottom is clipped at raster
    // time. The software renderer draws via CoreText with no per-cell vertical
    // clip. Both GPU paths share this atlas, so the classic command path is a
    // faithful proxy. This guards that tall fallback / combining / emoji /
    // Indic clusters do not lose top/bottom ink on the GPU path relative to
    // software — i.e. that the one-cell tile is tall enough at this metric.
    MetalRenderer.useGPUCellPath = false
    let bg: UInt32 = 0x20_28_30_FF
    let fg: UInt32 = 0xF0_F0_F0_FF
    let row = 3  // middle row: rows 0–2 above and 4–7 below are blank
    let originY = CGFloat(rows - 1 - row) * cellH
    let clusters: [(name: String, text: String)] = [
      ("combining-acute", "e\u{0301}"),
      ("precomposed-acute", "é"),
      ("below-dot", "a\u{0323}"),
      ("keycap", "1\u{FE0F}\u{20E3}"),
      ("devanagari", "क्षि"),
      ("zwj-emoji", "👩\u{200D}💻"),
    ]
    let tolerance = 2

    for cluster in clusters {
      let commands: [FrameCommand] = [
        .rect(
          CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
          color: bg, source: .terminal),
        .glyphRun(
          origin: CGPoint(x: 0, y: originY), text: cluster.text,
          foreground: fg, background: bg, attributes: [], source: .terminal),
      ]
      let gpu = try renderSingle(label: "gpu-\(cluster.name)", commands: commands, damage: .full)
      let sw = try renderSoftware(label: "sw-\(cluster.name)", commands: commands)
      guard let gpuExtent = glyphInkRowExtent(gpu.image, background: bg) else {
        XCTFail("\(cluster.name): GPU produced no ink")
        continue
      }
      guard let swExtent = glyphInkRowExtent(sw.image, background: bg) else {
        XCTFail("\(cluster.name): software produced no ink")
        continue
      }
      XCTAssertLessThanOrEqual(
        abs(gpuExtent.min - swExtent.min), tolerance,
        "\(cluster.name): GPU top ink row \(gpuExtent.min) vs software \(swExtent.min) — atlas clipping ink above the cell?"
      )
      XCTAssertLessThanOrEqual(
        abs(gpuExtent.max - swExtent.max), tolerance,
        "\(cluster.name): GPU bottom ink row \(gpuExtent.max) vs software \(swExtent.max) — atlas clipping ink below the cell?"
      )
    }
  }

  /// The first and last image rows (top-down) that contain at least
  /// `minInkPixels` pixels differing from `background` by more than `threshold`
  /// on any channel. Returns nil when the image is all background.
  private func glyphInkRowExtent(
    _ image: RGBAImage,
    background: UInt32,
    threshold: Int = 40,
    minInkPixels: Int = 2
  ) -> (min: Int, max: Int)? {
    let bgR = Int((background >> 24) & 0xFF)
    let bgG = Int((background >> 16) & 0xFF)
    let bgB = Int((background >> 8) & 0xFF)
    var minRow = Int.max
    var maxRow = -1
    for y in 0..<image.height {
      var inkCount = 0
      for x in 0..<image.width {
        let i = (y * image.width + x) * 4
        let dr = abs(Int(image.bytes[i]) - bgR)
        let dg = abs(Int(image.bytes[i + 1]) - bgG)
        let db = abs(Int(image.bytes[i + 2]) - bgB)
        if max(dr, max(dg, db)) > threshold { inkCount += 1 }
      }
      if inkCount >= minInkPixels {
        minRow = Swift.min(minRow, y)
        maxRow = Swift.max(maxRow, y)
      }
    }
    return maxRow >= 0 ? (minRow, maxRow) : nil
  }

  func testGPUCellPayloadAcceptsTwoCellMetricNarrowSymbols() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-two-cell-metric-symbols")
    let payload = twoCellMetricSymbolPayload()

    let counts = try XCTUnwrap(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: payload,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))
    XCTAssertNil(renderer.lastGPUCellPayloadBuildFailure)
    XCTAssertEqual(counts.cellGlyphs, rows * cols)
  }

  func testGPUCellPayloadMatchesClassicForTwoCellMetricNarrowSymbols() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = twoCellMetricSymbolFrame()
    let payload = twoCellMetricSymbolPayload()

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-two-cell-metric-symbols", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-two-cell-metric-symbols",
      commands: [],
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-two-cell-metric-symbols",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testSoftwareAndMetalUseSameInkBoundsForTwoCellMetricNarrowSymbols() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = twoCellMetricSymbolFrame()
    let software = try renderSoftware(label: "software-two-cell-metric-symbols", commands: commands)

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-two-cell-metric-symbols", commands: commands, damage: .full)

    try assertInkBoundsEqual(
      expected: software.image,
      actual: classic.image,
      crop: 18..<45,
      label: "U+23BF")
    try assertInkBoundsEqual(
      expected: software.image,
      actual: classic.image,
      crop: 54..<81,
      label: "U+21B3")
  }

  func testGPUCellPayloadAcceptsRepresentativeNarrowGlyphEdgeScalars() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-narrow-glyph-edge-scalars")
    var failures: [String] = []
    for scalarValue in representativeNarrowGlyphEdgeScalars() {
      let payload = singleGlyphPayload(
        scalarValue: scalarValue,
        wide: 0,
        attributes: [],
        labelSeed: Int(scalarValue))
      if renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: payload,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)) == nil
      {
        let failure = renderer.lastGPUCellPayloadBuildFailure
        failures.append(
          String(
            format: "U+%04X reason=%@ logicalWidth=%.2f max=%.2f",
            scalarValue,
            failure?.reason ?? "unknown",
            failure?.logicalWidth ?? -1,
            failure?.maxLogicalWidth ?? -1))
      }
    }

    XCTAssertTrue(
      failures.isEmpty,
      "representative narrow symbols must not be rejected by glyph metrics: \(failures.joined(separator: ", "))"
    )
  }

  func testGPUCellPayloadAcceptsStyledNarrowGlyphEdgeScalars() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-styled-narrow-glyph-edge-scalars")
    let attributes: [TextAttributes] = [[], [.bold], [.italic], [.bold, .italic]]
    var failures: [String] = []
    for attrs in attributes {
      for scalarValue in [UInt32(0x23BF), UInt32(0x21B3), UInt32(0xE0B0), UInt32(0xE0B2)] {
        let payload = singleGlyphPayload(
          scalarValue: scalarValue,
          wide: 0,
          attributes: attrs,
          labelSeed: Int(scalarValue) + Int(attrs.rawValue))
        if renderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: [],
          damage: .full,
          surfacePxH: Int(CGFloat(rows) * cellH * scale)) == nil
        {
          let failure = renderer.lastGPUCellPayloadBuildFailure
          failures.append(
            String(
              format: "U+%04X attrs=0x%04X reason=%@ logicalWidth=%.2f max=%.2f",
              scalarValue,
              attrs.rawValue,
              failure?.reason ?? "unknown",
              failure?.logicalWidth ?? -1,
              failure?.maxLogicalWidth ?? -1))
        }
      }
    }

    XCTAssertTrue(
      failures.isEmpty,
      "styled narrow symbols must keep enough ink slop for fallback/bold/italic metrics: \(failures.joined(separator: ", "))"
    )
  }

  func testGPUCellPayloadAcceptsSingleCharacterCombiningEmojiAndFallbackClusters() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-single-character-clusters")
    let clusters: [(text: String, wide: UInt8)] = [
      ("e\u{0301}", 0),
      ("a\u{0308}", 0),
      ("1\u{FE0F}\u{20E3}", 0),
      ("👩\u{200D}💻", 1),
      ("🇸🇪", 1),
      ("🏳️\u{200D}🌈", 1),
      ("क्\u{200D}ष", 1),
      ("क्षि", 1),
    ]
    var failures: [String] = []

    for (text, wide) in clusters {
      XCTAssertEqual(text.count, 1, "\(text) must be one Swift Character for this payload probe")
      let payload = singleClusterPayload(text: text, wide: wide, labelSeed: text.hashValue)
      if renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: payload,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)) == nil
      {
        let failure = renderer.lastGPUCellPayloadBuildFailure
        failures.append(
          "\(text) reason=\(failure?.reason ?? "unknown") logicalWidth=\(failure?.logicalWidth ?? -1) max=\(failure?.maxLogicalWidth ?? -1)"
        )
      }
    }

    XCTAssertTrue(
      failures.isEmpty,
      "single-Character clusters must remain renderable through the payload atlas path: \(failures.joined(separator: ", "))"
    )
  }

  func testGPUCellPayloadReportsShapingRunsAsUnsupportedInsteadOfAmbiguousGlyphs() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-shaping-run-diagnostics")
    for text in ["لا", "مرحبا"] {
      XCTAssertGreaterThan(text.count, 1, "\(text) must be a multi-Character shaping run")
      let payload = singleClusterPayload(text: text, wide: 1, labelSeed: text.hashValue)
      XCTAssertNil(
        renderer.rebuildGPUCellPayloadInstancesForTesting(
          payload: payload,
          commands: [],
          damage: .full,
          surfacePxH: Int(CGFloat(rows) * cellH * scale)),
        "\(text) should not be coerced into one payload glyph")
      let failure = try XCTUnwrap(renderer.lastGPUCellPayloadBuildFailure)
      XCTAssertEqual(failure.reason, "utf8ClusterNotSingleCharacter")
      XCTAssertEqual(failure.textPreview, text)
    }
  }

  func testGPUCellPayloadPartialDirtyRowAcceptsWideInkNarrowSymbols() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-partial-wide-ink-symbols")
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: twoCellMetricSymbolPayload(),
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    let payload = twoCellMetricSymbolPayload(dirtyRows: [3])
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: payload,
        commands: [],
        damage: .partial(yRanges: [dirtyRange(forRow: 3)]),
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))
    XCTAssertNil(renderer.lastGPUCellPayloadBuildFailure)
    XCTAssertEqual(
      renderer.cellGlyphUploadRangesForTesting,
      [((rows - 1 - 3) * cols)..<((rows - 3) * cols)])
  }

  func testGPUCellPayloadMatchesClassicForTextDecorations() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = decoratedFrame(seed: 19)
    let payload = decoratedPayload(seed: 19, includedRows: Array(0..<rows))

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-payload-decorations", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-decorations",
      commands: commands,
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-text-decorations",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadMatchesClassicForProceduralCells() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = proceduralFrame(seed: 23)
    let payload = proceduralPayload(seed: 23, includedRows: Array(0..<rows))

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic-procedural", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-procedural",
      commands: [],
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertEqual(gpu.counts.glyphs, 0)
      XCTAssertGreaterThan(gpu.counts.solids, rows)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-procedural-cells",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadMatchesClassicForHyperlinkVisuals() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = hyperlinkFrame(seed: 31)
    let payload = hyperlinkPayload(seed: 31, includedRows: Array(0..<rows))

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-payload-hyperlink", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-hyperlink",
      commands: [],
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-hyperlink-visuals",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadMatchesClassicForOverlayCommands() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let overlays = overlayCommands()
    let commands = overlayFrame(seed: 37, overlays: overlays)
    let payload = payload(seed: 37, changedRow: nil, includedRows: Array(0..<rows))

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-payload-overlays", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-overlays",
      commands: overlays,
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
      XCTAssertGreaterThan(gpu.counts.cursors, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-overlays",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadMatchesClassicForWideAndClusterGlyphs() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = wideClusterFrame()
    let payload = wideClusterPayload()

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(label: "classic-wide-cluster", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-wide-cluster",
      commands: [],
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-wide-cluster",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPayloadMatchesClassicForFractionalContentYOffset() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let offset: CGFloat = 4.25
    let commands = offsetFrame(seed: 43, contentYOffset: offset)
    var payload = payload(seed: 43, changedRow: nil, includedRows: Array(0..<rows))
    payload.contentYOffset = offset

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-content-y-offset", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(
      label: "gpu-payload-content-y-offset",
      commands: [],
      payload: payload,
      damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-payload-content-y-offset",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
  }

  func testGPUCellPathMatchesClassicForWideAndClusterGlyphs() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let commands = wideClusterFrame()

    MetalRenderer.useGPUCellPath = false
    let classic = try renderSingle(
      label: "classic-wide-cluster-command", commands: commands, damage: .full)

    MetalRenderer.useGPUCellPath = true
    let gpu = try renderSingle(label: "gpu-wide-cluster-command", commands: commands, damage: .full)

    if #available(macOS 26, *) {
      XCTAssertGreaterThan(gpu.counts.cellGlyphs, 0)
      XCTAssertEqual(gpu.counts.glyphs, 0)
    }

    try assertPixelsEqual(
      expected: classic.image,
      actual: gpu.image,
      fixture: "gpu-cell-wide-cluster",
      expectedPNG: classic.png,
      actualPNG: gpu.png)
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

  func testGPUCellPayloadCoalescesContiguousDirtyRowUploads() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-contiguous-upload-ranges")
    let initial = payload(seed: 19, changedRow: nil, includedRows: Array(0..<rows))
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: initial,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    let dirtyRows = [3, 4, 5]
    let next = payload(seed: 20, changedRow: 4, includedRows: dirtyRows)
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: next,
        commands: [],
        damage: .partial(yRanges: dirtyRows.map { dirtyRange(forRow: $0) }),
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    let lowerBottomUpRow = rows - 1 - dirtyRows.max()!
    let upperBottomUpRow = rows - 1 - dirtyRows.min()!
    XCTAssertEqual(
      renderer.cellGlyphUploadRangesForTesting,
      [(lowerBottomUpRow * cols)..<((upperBottomUpRow + 1) * cols)])
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

  func testGPUCellPayloadScaleChangeRequiresFullPayloadRetry() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let renderer = try makeRenderer(label: "payload-scale-invalidation")
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: scale)
    let initial = payload(seed: 41, changedRow: nil, includedRows: Array(0..<rows))
    XCTAssertNotNil(
      renderer.rebuildAndPrepareGPUCellPayloadInstancesForTesting(
        payload: initial,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))

    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: 2)
    let partial = payload(seed: 42, changedRow: 4, includedRows: [4])
    XCTAssertNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: partial,
        commands: [],
        damage: .partial(yRanges: [dirtyRange(forRow: 4)]),
        surfacePxH: Int(CGFloat(rows) * cellH * scale)),
      "stale GPU-cell geometry cannot be rebuilt from a partial payload")

    let full = payload(seed: 42, changedRow: 4, includedRows: Array(0..<rows))
    XCTAssertNotNil(
      renderer.rebuildGPUCellPayloadInstancesForTesting(
        payload: full,
        commands: [],
        damage: .full,
        surfacePxH: Int(CGFloat(rows) * cellH * scale)))
    XCTAssertEqual(renderer.cellGlyphUploadRangesForTesting, [0..<(rows * cols)])
  }

  func testGPUCellCursorOnlyFramePreservesCellCache() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    MetalRenderer.useGPUCellPath = true
    let renderer = try makeRenderer(label: "gpu-cell-cursor-cache")
    guard renderer.effectiveRendererMode == .gpuDriven else {
      throw XCTSkip("gpu-driven renderer is unavailable on this OS")
    }
    let full = payload(seed: 51, changedRow: nil, includedRows: Array(0..<rows))
    XCTAssertTrue(
      renderer.render(
        [],
        cellPayload: full,
        damage: .full,
        rendererFallbackReason: nil),
      "initial full gpu-cell render failed")
    renderer.waitForLastFrame()
    XCTAssertEqual(renderer.activeCellGlyphIndicesForTesting.count, rows * cols)

    XCTAssertTrue(
      renderer.render(
        [.cursor(CGRect(x: cellW, y: cellH, width: cellW, height: cellH), color: 0xFF_00_00_FF)],
        cellPayload: nil,
        damage: .partial(yRanges: []),
        rendererFallbackReason: nil),
      "cursor-only render failed")
    renderer.waitForLastFrame()

    XCTAssertEqual(
      renderer.activeCellGlyphIndicesForTesting.count,
      rows * cols,
      "cursor-only frames must not poison the persistent GPU-cell cache")
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
      let line = String(
        (0..<cols).map { ascii[($0 + row + seed + (changed ? 7 : 0)) % ascii.count] })
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

  private func atlasStressFrame(seed: Int) -> [FrameCommand] {
    let glyphs = (33...126).map { Character(Unicode.Scalar($0)!) }
    var commands: [FrameCommand] = []
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 23) & 0xFF)
      let bg: UInt32 =
        ((0x12 + base) << 24) | ((0x1E + base) << 16) | ((0x2A + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xD8 - UInt32(row * 5)) << 24) | ((0xE8 - UInt32(row * 6)) << 16)
        | ((0xF8 - UInt32(row * 7)) << 8) | 0xFF
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      let line = String((0..<cols).map { glyphs[($0 + row * cols + seed) % glyphs.count] })
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: line,
          foreground: fg,
          background: bg,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private func sizedFrame(seed: Int, frameRows: Int, frameCols: Int) -> [FrameCommand] {
    let glyphs = (33...126).map { Character(Unicode.Scalar($0)!) }
    var commands: [FrameCommand] = []
    for row in 0..<frameRows {
      let y = CGFloat(frameRows - 1 - row) * cellH
      let base = UInt32((seed + row * 17) & 0xFF)
      let bg: UInt32 =
        ((0x16 + base) << 24) | ((0x26 + base) << 16) | ((0x36 + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xE0 - UInt32(row * 7)) << 24) | ((0xD8 - UInt32(row * 5)) << 16)
        | ((0xCC + UInt32(row * 3)) << 8) | 0xFF
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(frameCols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      let line = String(
        (0..<frameCols).map { glyphs[($0 + row * frameCols + seed) % glyphs.count] })
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: line,
          foreground: fg,
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

  private func decoratedFrame(seed: Int) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var commands: [FrameCommand] = []
    for row in 0..<rows {
      let style = decorationStyle(for: row)
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 19) & 0xFF)
      let bg: UInt32 =
        ((0x18 + base) << 24) | ((0x24 + base) << 16) | ((0x34 + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xE0 - UInt32(row * 8)) << 24) | ((0xD0 - UInt32(row * 4)) << 16)
        | ((0xC0 + UInt32(row * 3)) << 8) | 0xFF
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
          foreground: fg,
          background: bg,
          attributes: style.attributes,
          source: .terminal,
          underlineStyle: style.underlineStyle,
          underlineColor: style.underlineColor))
    }
    return commands
  }

  private func hyperlinkFrame(seed: Int) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var commands: [FrameCommand] = []
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 13) & 0xFF)
      let bg: UInt32 =
        ((0x14 + base) << 24) | ((0x20 + base) << 16) | ((0x2E + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xC0 + UInt32(row * 5)) << 24) | ((0xD0 - UInt32(row * 3)) << 16)
        | ((0xF0 - UInt32(row * 2)) << 8) | 0xFF
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
          foreground: fg,
          background: bg,
          attributes: [.underline],
          source: .terminal,
          underlineStyle: .single,
          underlineColor: 0x33_99_FF_FF,
          hyperlink: "https://example.test/\(row)"))
    }
    return commands
  }

  private func proceduralFrame(seed: Int) -> [FrameCommand] {
    let scalars = proceduralScalars()
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_20_30_FF,
        source: .terminal)
    ]
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 23) & 0xFF)
      let bg: UInt32 =
        ((0x18 + base) << 24) | ((0x22 + base) << 16) | ((0x2C + base) << 8) | 0xFF
      commands.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      for col in 0..<cols {
        let scalar = scalars[(row * 7 + col + seed) % scalars.count]
        let fg = proceduralForeground(row: row, col: col, seed: seed)
        for filled in BoxDrawing.proceduralCellElementRects(
          scalar,
          at: CGPoint(x: CGFloat(col) * cellW, y: y),
          cellWidth: cellW,
          cellHeight: cellH,
          foreground: fg)
        {
          commands.append(.rect(filled.rect, color: filled.color, source: .terminal))
        }
      }
    }
    return commands
  }

  private func overlayFrame(seed: Int, overlays: [FrameCommand]) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var backgrounds: [FrameCommand] = []
    var glyphs: [FrameCommand] = []
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH
      let base = UInt32((seed + row * 17) & 0xFF)
      let bg: UInt32 =
        ((0x10 + base) << 24) | ((0x20 + base) << 16) | ((0x30 + base) << 8) | 0xFF
      backgrounds.append(
        .rect(
          CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
          color: bg,
          source: .terminal))
      let line = String((0..<cols).map { ascii[($0 + row + seed) % ascii.count] })
      glyphs.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: y),
          text: line,
          foreground: 0xDD_EE_EE_FF,
          background: bg,
          attributes: [],
          source: .terminal))
    }
    let cursorCommands = overlays.filter {
      if case .cursor = $0 { return true }
      return false
    }
    let nonCursorOverlays = overlays.filter {
      if case .cursor = $0 { return false }
      return true
    }
    return backgrounds + nonCursorOverlays + glyphs + cursorCommands
  }

  private func overlayCommands() -> [FrameCommand] {
    let row2Y = CGFloat(rows - 1 - 2) * cellH
    let row4Y = CGFloat(rows - 1 - 4) * cellH
    let cursorY = CGFloat(rows - 1 - 1) * cellH
    return [
      .selection(
        CGRect(x: 2 * cellW, y: row2Y, width: 6 * cellW, height: cellH),
        color: 0x32_5B_66_80),
      .findMatch(
        CGRect(x: 11 * cellW, y: row2Y, width: 5 * cellW, height: cellH),
        color: 0xDB_B3_2D_4D),
      .findSelected(
        CGRect(x: 4 * cellW, y: row4Y, width: 7 * cellW, height: cellH),
        color: 0xEB_C1_3D_B3),
      .cursor(
        CGRect(x: 18 * cellW, y: cursorY, width: cellW, height: cellH),
        color: 0xAD_BC_BC_FF),
    ]
  }

  private func offsetFrame(seed: Int, contentYOffset: CGFloat) -> [FrameCommand] {
    let ascii = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    var commands: [FrameCommand] = [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_20_30_FF,
        source: .terminal)
    ]
    for row in 0..<rows {
      let y = CGFloat(rows - 1 - row) * cellH + contentYOffset
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
          foreground: 0xDD_EE_EE_FF,
          background: bg,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private func wideClusterFrame() -> [FrameCommand] {
    let bg: UInt32 = 0x18_24_30_FF
    let fg: UInt32 = 0xE6_EE_F6_FF
    let row = 3
    let y = CGFloat(rows - 1 - row) * cellH
    return [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_20_30_FF,
        source: .terminal),
      .rect(
        CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
        color: bg,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 0, y: y),
        text: "中",
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 2 * cellW, y: y),
        text: "👩‍💻",
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 4 * cellW, y: y),
        text: "A",
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
    ]
  }

  private func wideClusterPayload() -> TerminalCellPayload {
    let bg: UInt32 = 0x18_24_30_FF
    let fg: UInt32 = 0xE6_EE_F6_FF
    let row = 3
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: Array(0..<rows))
    payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
    payload.glyphs.append(
      .init(
        row: row,
        col: 0,
        text: "",
        scalarValue: "中".unicodeScalars.first?.value,
        foreground: fg,
        background: bg,
        attributes: [],
        wide: 1))
    let clusterStart = payload.utf8Bytes.count
    payload.utf8Bytes.append(contentsOf: Array("👩‍💻".utf8))
    payload.glyphs.append(
      .init(
        row: row,
        col: 2,
        text: "",
        scalarValue: nil,
        foreground: fg,
        background: bg,
        attributes: [],
        wide: 1,
        utf8Range: clusterStart..<payload.utf8Bytes.count))
    payload.glyphs.append(
      .init(
        row: row,
        col: 4,
        text: "A",
        scalarValue: "A".unicodeScalars.first?.value,
        foreground: fg,
        background: bg,
        attributes: []))
    return payload
  }

  private func twoCellMetricSymbolFrame() -> [FrameCommand] {
    let bg: UInt32 = 0x18_24_30_FF
    let fg: UInt32 = 0xE6_EE_F6_FF
    let row = 3
    let y = CGFloat(rows - 1 - row) * cellH
    return [
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cols) * cellW, height: CGFloat(rows) * cellH),
        color: 0x10_20_30_FF,
        source: .terminal),
      .rect(
        CGRect(x: 0, y: y, width: CGFloat(cols) * cellW, height: cellH),
        color: bg,
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 2 * cellW, y: y),
        text: "⎿",
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 6 * cellW, y: y),
        text: "↳",
        foreground: fg,
        background: bg,
        attributes: [],
        source: .terminal),
    ]
  }

  private func twoCellMetricSymbolPayload(dirtyRows: [Int]? = nil) -> TerminalCellPayload {
    let bg: UInt32 = 0x18_24_30_FF
    let fg: UInt32 = 0xE6_EE_F6_FF
    let row = 3
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: dirtyRows ?? Array(0..<rows))
    payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
    for (offset, scalarValue) in [UInt32(0x23BF), UInt32(0x21B3)].enumerated() {
      payload.glyphs.append(
        .init(
          row: row,
          col: 2 + offset * 4,
          text: "",
          scalarValue: scalarValue,
          foreground: fg,
          background: bg,
          attributes: [],
          wide: 0))
    }
    return payload
  }

  private func representativeNarrowGlyphEdgeScalars() -> [UInt32] {
    [
      // Regression glyphs from the live payload failures.
      0x23BF, 0x21B3,
      // Adjacent terminal UI and arrows likely to fall back to symbol fonts.
      0x23BE, 0x23CC, 0x21B0, 0x21B1, 0x21B2, 0x21B4,
      0x2190, 0x2191, 0x2192, 0x2193, 0x2194, 0x2195,
      0x21D0, 0x21D2, 0x27F5, 0x27F6, 0x27F9,
      // Misc technical/control glyphs used in terminal UIs.
      0x2318, 0x2325, 0x232B, 0x2326, 0x238B, 0x23CE,
      // Box and block glyphs that are often narrow cells but font-dependent.
      0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518,
      0x2588, 0x2591, 0x2592, 0x2593, 0x2800, 0x28FF,
      // Powerline private-use glyphs; may resolve through user/fallback fonts.
      0xE0A0, 0xE0A1, 0xE0A2, 0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3,
      // A small Nerd Font private-use sample.
      0xF013, 0xF054, 0xF07B, 0xF0C9, 0xF120,
    ]
  }

  private func singleGlyphPayload(
    scalarValue: UInt32,
    wide: UInt8,
    attributes: TextAttributes,
    labelSeed: Int
  ) -> TerminalCellPayload {
    let row = 3
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: Array(0..<rows))
    payload.backgroundRuns.append(
      .init(row: row, startCol: 0, colCount: cols, color: edgeProbeBackground(seed: labelSeed)))
    payload.glyphs.append(
      .init(
        row: row,
        col: 4,
        text: "",
        scalarValue: scalarValue,
        foreground: edgeProbeForeground(seed: labelSeed),
        background: edgeProbeBackground(seed: labelSeed),
        attributes: attributes,
        wide: wide))
    return payload
  }

  private func singleClusterPayload(
    text: String,
    wide: UInt8,
    labelSeed: Int
  ) -> TerminalCellPayload {
    let row = 3
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: Array(0..<rows))
    payload.backgroundRuns.append(
      .init(row: row, startCol: 0, colCount: cols, color: edgeProbeBackground(seed: labelSeed)))
    let start = payload.utf8Bytes.count
    payload.utf8Bytes.append(contentsOf: Array(text.utf8))
    payload.glyphs.append(
      .init(
        row: row,
        col: 4,
        text: "",
        scalarValue: nil,
        foreground: edgeProbeForeground(seed: labelSeed),
        background: edgeProbeBackground(seed: labelSeed),
        attributes: [],
        wide: wide,
        utf8Range: start..<payload.utf8Bytes.count))
    return payload
  }

  private func edgeProbeBackground(seed: Int) -> UInt32 {
    let value = UInt32(truncatingIfNeeded: seed)
    let r = UInt32(0x18 + (value & 0x1F))
    let g = UInt32(0x24 + ((value >> 5) & 0x1F))
    let b = UInt32(0x30 + ((value >> 10) & 0x1F))
    return (r << 24) | (g << 16) | (b << 8) | 0xFF
  }

  private func edgeProbeForeground(seed: Int) -> UInt32 {
    let value = UInt32(truncatingIfNeeded: seed)
    let r = UInt32(0xD8 - (value & 0x1F))
    let g = UInt32(0xE0 - ((value >> 5) & 0x1F))
    let b = UInt32(0xF0 - ((value >> 10) & 0x1F))
    return (r << 24) | (g << 16) | (b << 8) | 0xFF
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

  private func decoratedPayload(seed: Int, includedRows: [Int]) -> TerminalCellPayload {
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
      let style = decorationStyle(for: row)
      let base = UInt32((seed + row * 19) & 0xFF)
      let bg: UInt32 =
        ((0x18 + base) << 24) | ((0x24 + base) << 16) | ((0x34 + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xE0 - UInt32(row * 8)) << 24) | ((0xD0 - UInt32(row * 4)) << 16)
        | ((0xC0 + UInt32(row * 3)) << 8) | 0xFF
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
      for col in 0..<cols {
        let scalar = ascii[(col + row + seed) % ascii.count]
        payload.glyphs.append(
          .init(
            row: row,
            col: col,
            text: "",
            scalarValue: scalar.unicodeScalars.first?.value,
            foreground: fg,
            background: bg,
            attributes: style.attributes,
            underlineStyle: style.underlineStyle,
            underlineColor: style.underlineColor))
      }
    }
    return payload
  }

  private func hyperlinkPayload(seed: Int, includedRows: [Int]) -> TerminalCellPayload {
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
      let base = UInt32((seed + row * 13) & 0xFF)
      let bg: UInt32 =
        ((0x14 + base) << 24) | ((0x20 + base) << 16) | ((0x2E + base) << 8) | 0xFF
      let fg: UInt32 =
        ((0xC0 + UInt32(row * 5)) << 24) | ((0xD0 - UInt32(row * 3)) << 16)
        | ((0xF0 - UInt32(row * 2)) << 8) | 0xFF
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
      for col in 0..<cols {
        let scalar = ascii[(col + row + seed) % ascii.count]
        payload.glyphs.append(
          .init(
            row: row,
            col: col,
            text: "",
            scalarValue: scalar.unicodeScalars.first?.value,
            foreground: fg,
            background: bg,
            attributes: [.underline],
            underlineStyle: .single,
            underlineColor: 0x33_99_FF_FF,
            hasHyperlink: true))
      }
    }
    return payload
  }

  private func proceduralPayload(seed: Int, includedRows: [Int]) -> TerminalCellPayload {
    let scalars = proceduralScalars()
    var payload = TerminalCellPayload(
      rows: rows,
      cols: cols,
      origin: .zero,
      cellSize: CGSize(width: cellW, height: cellH),
      contentYOffset: 0,
      defaultBackground: 0x10_20_30_FF,
      dirtyRows: includedRows)
    for row in includedRows {
      let base = UInt32((seed + row * 23) & 0xFF)
      let bg: UInt32 =
        ((0x18 + base) << 24) | ((0x22 + base) << 16) | ((0x2C + base) << 8) | 0xFF
      payload.backgroundRuns.append(.init(row: row, startCol: 0, colCount: cols, color: bg))
      for col in 0..<cols {
        let scalar = scalars[(row * 7 + col + seed) % scalars.count]
        payload.proceduralCells.append(
          .init(
            row: row,
            col: col,
            scalarValue: scalar.value,
            foreground: proceduralForeground(row: row, col: col, seed: seed)))
      }
    }
    return payload
  }

  private func proceduralScalars() -> [Unicode.Scalar] {
    [
      Unicode.Scalar(0x2580)!, Unicode.Scalar(0x2584)!, Unicode.Scalar(0x2588)!,
      Unicode.Scalar(0x258C)!, Unicode.Scalar(0x2590)!, Unicode.Scalar(0x2591)!,
      Unicode.Scalar(0x2593)!, Unicode.Scalar(0x2596)!, Unicode.Scalar(0x259A)!,
      Unicode.Scalar(0x259F)!, Unicode.Scalar(0x25E2)!, Unicode.Scalar(0x25E3)!,
      Unicode.Scalar(0x25E4)!, Unicode.Scalar(0x25E5)!,
    ]
  }

  private func proceduralForeground(row: Int, col: Int, seed: Int) -> UInt32 {
    let r = UInt32((0x70 + seed + row * 11 + col * 3) & 0xFF)
    let g = UInt32((0x90 + seed + row * 5 + col * 7) & 0xFF)
    let b = UInt32((0xB0 + seed + row * 3 + col * 13) & 0xFF)
    return (r << 24) | (g << 16) | (b << 8) | 0xFF
  }

  private func decorationStyle(
    for row: Int
  ) -> (attributes: TextAttributes, underlineStyle: UnderlineStyle, underlineColor: UInt32?) {
    switch row % 8 {
    case 0: return ([.underline], .single, nil)
    case 1: return ([], .double, nil)
    case 2: return ([], .dotted, nil)
    case 3: return ([], .dashed, nil)
    case 4: return ([], .curly, nil)
    case 5: return ([.strikethrough], .none, nil)
    case 6: return ([.overline], .none, nil)
    default: return ([.underline, .strikethrough, .overline], .single, 0x33_99_FF_FF)
    }
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
    try renderSingle(label: label, commands: commands, payload: nil, damage: damage)
  }

  private func renderSingle(
    label: String,
    commands: [FrameCommand],
    payload: TerminalCellPayload?,
    damage: RenderDamage
  ) throws -> RenderResult {
    let renderer = try makeRenderer(label: label)
    XCTAssertTrue(
      renderer.render(
        commands,
        cellPayload: payload,
        damage: damage,
        rendererFallbackReason: nil),
      "\(label): render failed")
    renderer.waitForLastFrame()
    return try readResult(renderer: renderer, label: label)
  }

  private func renderSoftware(label: String, commands: [FrameCommand]) throws -> RenderResult {
    let backend = SoftwareBackend(
      fontAtlas: FontAtlas(pointSize: 14),
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: scale)
    XCTAssertTrue(backend.render(commands, damage: .full), "\(label): software render failed")
    guard let png = backend.pngData else {
      XCTFail("\(label): software renderer did not produce pngData")
      throw TestFailure()
    }
    return RenderResult(
      png: png,
      image: try decodeRGBA(png),
      counts: MetalRenderer.RenderInstanceCounts())
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

  private func renderResizeSequence(
    label: String,
    initial: [FrameCommand],
    initialRows: Int,
    initialCols: Int,
    next: [FrameCommand]
  ) throws -> RenderResult {
    let renderer = try makeRenderer(label: label)
    renderer.resize(
      pixelWidth: Int(CGFloat(initialCols) * cellW * scale),
      pixelHeight: Int(CGFloat(initialRows) * cellH * scale),
      scale: scale)
    XCTAssertTrue(renderer.render(initial, damage: .full), "\(label): initial render failed")
    renderer.waitForLastFrame()
    renderer.resize(
      pixelWidth: Int(CGFloat(cols) * cellW * scale),
      pixelHeight: Int(CGFloat(rows) * cellH * scale),
      scale: scale)
    XCTAssertTrue(renderer.render(next, damage: .full), "\(label): resized render failed")
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
    assertSIMD2BitsEqual(
      expected.originPx, actual.originPx, "\(label) originPx", file: file, line: line)
    assertSIMD2BitsEqual(expected.sizePx, actual.sizePx, "\(label) sizePx", file: file, line: line)
    assertSIMD2BitsEqual(
      expected.uvOrigin, actual.uvOrigin, "\(label) uvOrigin", file: file, line: line)
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
              actual: actualRGBA
            )
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

  private func assertInkBoundsEqual(
    expected: RGBAImage,
    actual: RGBAImage,
    crop: Range<Int>,
    label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let expectedBounds = try XCTUnwrap(
      inkBounds(in: expected, crop: crop),
      "\(label): expected image has no ink",
      file: file,
      line: line)
    let actualBounds = try XCTUnwrap(
      inkBounds(in: actual, crop: crop),
      "\(label): actual image has no ink",
      file: file,
      line: line)
    XCTAssertEqual(
      expectedBounds, actualBounds, "\(label): ink bounds differ", file: file, line: line)
  }

  private func inkBounds(in image: RGBAImage, crop: Range<Int>) -> CGRect? {
    guard image.width > 0, image.height > 0 else { return nil }
    var minX = Int.max
    var minY = Int.max
    var maxX = -1
    var maxY = -1
    let clampedLower = max(0, crop.lowerBound)
    let clampedUpper = min(image.width, crop.upperBound)
    guard clampedLower < clampedUpper else { return nil }
    for y in 0..<image.height {
      for x in clampedLower..<clampedUpper
      where !isTwoCellMetricFixtureBackground(image, x: x, y: y) {
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  private func isTwoCellMetricFixtureBackground(_ image: RGBAImage, x: Int, y: Int) -> Bool {
    let offset = (y * image.width + x) * 4
    let pixel = Array(image.bytes[offset..<(offset + 4)])
    return pixel == [0x10, 0x20, 0x30, 0xFF] || pixel == [0x18, 0x24, 0x30, 0xFF]
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
    guard
      let destination = CGImageDestinationCreateWithData(
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
