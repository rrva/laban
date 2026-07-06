import CoreGraphics
import CryptoKit
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// M2 damage-aware rendering correctness gate for
/// execplans/active/slug-render-loop-perf-and-aa-quality.md.
///
/// Every test compares a `SlugGlyphRenderer` driven with `.partial` damage
/// against a *fresh* renderer given the same final content and rendered with
/// `.full` damage, hashing `pngData`. Byte-identical hashes prove partial
/// (scissored, per-ring-slot-accumulated) rendering produces exactly the same
/// pixels as a full redraw would — the plan's stated acceptance bar.
final class SlugGlyphDamageTests: XCTestCase {
  private let cols = 20
  private let rows = 8
  private let scale: CGFloat = 2
  private let pointSize: CGFloat = 14

  private func makeFontAtlas() -> FontAtlas { FontAtlas(pointSize: pointSize) }

  private func makeRenderer(
    layout: VectorSubpixelLayout, cellSize: (width: CGFloat, height: CGFloat)
  ) throws
    -> SlugGlyphRenderer
  {
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: makeFontAtlas(),
        pixelWidth: Int(CGFloat(cols) * cellSize.width * scale),
        pixelHeight: Int(CGFloat(rows) * cellSize.height * scale),
        scale: scale))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    renderer.setSubpixelLayout(layout)
    return renderer
  }

  /// Renders `.full` once, then `.partial(yRanges: [])` `ringDepth - 1` more
  /// times with the same content, so every ring slot has been through its
  /// own one-time cold-start full redraw and is ready to accept genuine
  /// partial updates. Without this, `SlugGlyphRenderer`'s per-slot
  /// "needs a hard full redraw" flags (still set from ring allocation) would
  /// force every slot's *next* use to be full too, masking the partial path
  /// this file means to test.
  private func warmAllRingSlots(
    _ renderer: SlugGlyphRenderer, commands: [FrameCommand], ringDepth: Int = 3
  ) {
    XCTAssertTrue(renderer.render(commands, damage: .full))
    for _ in 1..<ringDepth {
      XCTAssertTrue(renderer.render(commands, damage: .partial(yRanges: [])))
    }
  }

  private func damageForRow(_ row: Int, cellSize: (width: CGFloat, height: CGFloat)) -> RenderDamage
  {
    .partial(yRanges: [DirtyYRange(y: CGFloat(row) * cellSize.height, height: cellSize.height)])
  }

  private func asciiText() -> [String] {
    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let doubled = ascii + ascii + ascii
    var lines: [String] = []
    lines.reserveCapacity(rows)
    for row in 0..<rows {
      let start = (row * 7) % ascii.count
      let from = doubled.index(doubled.startIndex, offsetBy: start)
      lines.append(String(doubled[from...].prefix(cols)))
    }
    return lines
  }

  private func mutatedLine(_ original: String, seed: Int) -> String {
    var chars = Array(original)
    guard !chars.isEmpty else { return original }
    let ascii = (0x21...0x7E).map { Character(UnicodeScalar($0)!) }
    for i in chars.indices {
      chars[i] = ascii[(i + seed) % ascii.count]
    }
    return String(chars)
  }

  /// `origin.y = row * cellSize.height` places array index 0 at the bottom
  /// of the surface (y-up CG points), matching `damageForRow`'s convention
  /// directly (no top/bottom flip needed between the two).
  private func frameCommands(
    text: [String], cellSize: (width: CGFloat, height: CGFloat), bgColor: UInt32 = 0x1010_10ff
  ) -> [FrameCommand] {
    var commands: [FrameCommand] = [
      .rect(
        CGRect(
          x: 0, y: 0, width: CGFloat(cols) * cellSize.width, height: CGFloat(rows) * cellSize.height
        ),
        color: bgColor,
        source: .terminal)
    ]
    commands.reserveCapacity(text.count + 1)
    for (row, line) in text.enumerated() {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellSize.height),
          text: line,
          foreground: 0xffff_ffff,
          background: 0x0000_0000,
          attributes: [],
          source: .terminal))
    }
    return commands
  }

  private func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func skipIfNoMetal() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
  }

  // MARK: - Byte-identical partial vs. full

  func testPartialRedrawOfOneRowIsByteIdenticalToFullRedraw() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize

    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      let textA = asciiText()
      var textB = textA
      textB[2] = mutatedLine(textB[2], seed: 7)

      let partial = try makeRenderer(layout: layout, cellSize: cellSize)
      warmAllRingSlots(partial, commands: frameCommands(text: textA, cellSize: cellSize))
      XCTAssertTrue(
        partial.render(
          frameCommands(text: textB, cellSize: cellSize),
          damage: damageForRow(2, cellSize: cellSize)))
      let partialHash = hash(try XCTUnwrap(partial.pngData))

      let full = try makeRenderer(layout: layout, cellSize: cellSize)
      XCTAssertTrue(full.render(frameCommands(text: textB, cellSize: cellSize), damage: .full))
      let fullHash = hash(try XCTUnwrap(full.pngData))

      XCTAssertEqual(partialHash, fullHash, "layout \(layout.name)")
    }
  }

  // MARK: - Ring-age: accumulation survives ringDepth-1 frames of staleness

  func testConsecutivePartialFramesAccumulateCorrectlyAcrossRingRotation() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize

    for layout in [VectorSubpixelLayout.grayscale, .rgbStripe] {
      var text = asciiText()
      let renderer = try makeRenderer(layout: layout, cellSize: cellSize)
      warmAllRingSlots(renderer, commands: frameCommands(text: text, cellSize: cellSize))

      for step in 0..<6 {
        let row = step % rows
        text[row] = mutatedLine(text[row], seed: step)
        XCTAssertTrue(
          renderer.render(
            frameCommands(text: text, cellSize: cellSize),
            damage: damageForRow(row, cellSize: cellSize)))

        let reference = try makeRenderer(layout: layout, cellSize: cellSize)
        XCTAssertTrue(
          reference.render(frameCommands(text: text, cellSize: cellSize), damage: .full))

        XCTAssertEqual(
          hash(try XCTUnwrap(renderer.pngData)),
          hash(try XCTUnwrap(reference.pngData)),
          "layout \(layout.name) step \(step)")
      }
    }
  }

  // MARK: - Sparse bands: rows between two dirty bands must not be touched

  func testSparseDirtyBandsDoNotRedrawRowsBetweenThem() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize
    guard rows >= 8 else { return XCTFail("test needs at least 8 rows") }

    let textA = asciiText()
    var textB = textA
    textB[1] = mutatedLine(textB[1], seed: 11)
    textB[7] = mutatedLine(textB[7], seed: 13)
    // Row 4 sits strictly between the two dirty bands but also changes in
    // the incoming *command list* — a union-bounding-box scissor (rows
    // 1...7) would pick this up; exact per-band scissoring must not.
    textB[4] = mutatedLine(textB[4], seed: 17)

    let partial = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    warmAllRingSlots(partial, commands: frameCommands(text: textA, cellSize: cellSize))
    let sparseDamage = RenderDamage.partial(yRanges: [
      DirtyYRange(y: CGFloat(1) * cellSize.height, height: cellSize.height),
      DirtyYRange(y: CGFloat(7) * cellSize.height, height: cellSize.height),
    ])
    XCTAssertTrue(
      partial.render(frameCommands(text: textB, cellSize: cellSize), damage: sparseDamage))
    let partialHash = hash(try XCTUnwrap(partial.pngData))

    // Expected: rows 1 and 7 take textB's content, every other row (including
    // row 4, despite textB changing it) stays at textA's content, since only
    // rows 1 and 7 were marked dirty.
    var expectedText = textA
    expectedText[1] = textB[1]
    expectedText[7] = textB[7]
    let expected = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    XCTAssertTrue(
      expected.render(frameCommands(text: expectedText, cellSize: cellSize), damage: .full))
    let expectedHash = hash(try XCTUnwrap(expected.pngData))

    XCTAssertEqual(partialHash, expectedHash)
  }

  // MARK: - Cursor blink correctness

  func testCursorBlinkViaEmptyPartialTogglesExactlyCursorCells() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize
    let text = asciiText()
    let cursorRect = CGRect(
      x: CGFloat(3) * cellSize.width, y: CGFloat(3) * cellSize.height, width: cellSize.width,
      height: cellSize.height)
    let commandsNoCursor = frameCommands(text: text, cellSize: cellSize)
    let commandsWithCursor = commandsNoCursor + [.cursor(cursorRect, color: 0xffff_ffff)]

    let renderer = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    warmAllRingSlots(renderer, commands: commandsNoCursor)

    // Cursor appears: an empty partial (the terminal's own damage tracking
    // sees no textual change) must still redraw exactly the cursor cell.
    XCTAssertTrue(renderer.render(commandsWithCursor, damage: .partial(yRanges: [])))
    let onHash = hash(try XCTUnwrap(renderer.pngData))
    let expectedOn = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    XCTAssertTrue(expectedOn.render(commandsWithCursor, damage: .full))
    XCTAssertEqual(onHash, hash(try XCTUnwrap(expectedOn.pngData)), "cursor on")

    // Cursor disappears: same empty-partial contract, in reverse.
    XCTAssertTrue(renderer.render(commandsNoCursor, damage: .partial(yRanges: [])))
    let offHash = hash(try XCTUnwrap(renderer.pngData))
    let expectedOff = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    XCTAssertTrue(expectedOff.render(commandsNoCursor, damage: .full))
    XCTAssertEqual(offHash, hash(try XCTUnwrap(expectedOff.pngData)), "cursor off")
  }

  // MARK: - Zoom forces full

  func testGestureZoomChangeForcesFullRedraw() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize
    let text = asciiText()
    let commands = frameCommands(text: text, cellSize: cellSize)

    let renderer = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    warmAllRingSlots(renderer, commands: commands)

    renderer.setGestureZoom(1.5, anchor: CGPoint(x: 100, y: 50))
    // Empty partial and no cursor change: without the zoom-change force-full
    // rule this would hit the empty-effective-damage skip path instead.
    XCTAssertTrue(renderer.render(commands, damage: .partial(yRanges: [])))
    let zoomedHash = hash(try XCTUnwrap(renderer.pngData))

    let expected = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    expected.setGestureZoom(1.5, anchor: CGPoint(x: 100, y: 50))
    XCTAssertTrue(expected.render(commands, damage: .full))
    XCTAssertEqual(zoomedHash, hash(try XCTUnwrap(expected.pngData)))
  }

  // MARK: - Empty effective damage: no ring rotation, still reports success

  func testEmptyEffectiveDamageDoesNotRotateRingAndReportsSuccess() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize
    let text = asciiText()
    let commands = frameCommands(text: text, cellSize: cellSize)

    let renderer = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    warmAllRingSlots(renderer, commands: commands)

    var completions = 0
    renderer.onFrameCompleted = { completions += 1 }

    let cursorBefore = renderer.targetRingCursorForTesting
    let ok = renderer.render(commands, damage: .partial(yRanges: []))

    XCTAssertTrue(ok, "empty effective damage must still report success")
    XCTAssertEqual(
      renderer.targetRingCursorForTesting, cursorBefore,
      "empty effective damage must not rotate the ring")
    XCTAssertEqual(completions, 1, "empty effective damage must still call onFrameCompleted")
  }

  // MARK: - Clear color changes

  func testClearColorChangeForcesFullRedraw() throws {
    try skipIfNoMetal()
    let cellSize = makeFontAtlas().cellSize
    let text = asciiText()
    let commandsA = frameCommands(text: text, cellSize: cellSize, bgColor: 0x1010_10ff)
    let commandsB = frameCommands(text: text, cellSize: cellSize, bgColor: 0x2020_20ff)

    let partial = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    warmAllRingSlots(partial, commands: commandsA)

    // Send a frame with no cell damage (yRanges: []) but with a new clear color.
    // This must trigger a full redraw instead of getting skipped.
    XCTAssertTrue(partial.render(commandsB, damage: .partial(yRanges: [])))
    let partialHash = hash(try XCTUnwrap(partial.pngData))

    // Compare with a full redraw renderer given the same frame
    let expected = try makeRenderer(layout: .grayscale, cellSize: cellSize)
    XCTAssertTrue(expected.render(commandsB, damage: .full))
    let expectedHash = hash(try XCTUnwrap(expected.pngData))

    XCTAssertEqual(partialHash, expectedHash, "partial renderer must successfully repaint background after clear color changes")
  }
}
