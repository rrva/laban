import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Pixel-level invariance checks built on `BitmapDiffHarness`.
///
/// Why this layer exists: the existing cell-grid tests
/// (`LabptyPasteRenderingRegressionTests`) compare strings extracted
/// from the snapshot. The user-visible bug was *pixels* differing
/// between the live app and the test grid for the same byte stream —
/// the cell grid alone is not a sufficient oracle. These tests
/// compare the rendered bitmap directly, with failure artifacts
/// (expected.png / actual.png / diff.png) written to `.artifacts/`
/// so a regression has a visible diff, not just a string assertion.
final class BitmapInvarianceTests: XCTestCase {
  // Captured byte stream from a live labpty session (the same fixture
  // the LabptyPasteRenderingRegressionTests use). Stable enough to
  // serve as both input and expected baseline across runs.
  private func capturedBytes() throws -> [UInt8] {
    let url = Bundle.module.url(
      forResource: "labpty-paste-rendering", withExtension: "bin")
    let path = url?.path ?? "Tests/LabanCoreTests/Fixtures/labpty-paste-rendering.bin"
    return [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
  }

  /// Feed the captured byte stream in one chunk vs in 1 KiB chunks.
  /// The rendered bitmap must be identical — chunk boundaries are not
  /// allowed to affect what the user sees. A future regression that
  /// splits a CSI mid-sequence would land here as a visible pixel
  /// diff, with the artifact PNGs showing exactly which row(s) drift.
  func testFeedChunkingDoesNotAffectRender() throws {
    let bytes = try capturedBytes()
    var chunks: [[UInt8]] = []
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 1024, bytes.count)
      chunks.append(Array(bytes[offset..<end]))
      offset = end
    }
    try BitmapDiffHarness.assertBitmapsMatch(
      expected: RenderScenario(name: "blob", feeds: [bytes]),
      actual: RenderScenario(name: "kib-chunks", feeds: chunks),
      label: "chunking-invariance")
  }

  /// Two fresh fixture sessions fed the identical byte stream must
  /// render to identical bitmaps. A failure here would mean the
  /// renderer or VT parser has gained hidden state from somewhere
  /// outside the byte stream (e.g. process-global state, leaked
  /// callbacks, time-of-day dependence). The font atlas, cell metrics,
  /// and theme are deterministic for `FontAtlas()` + the default theme.
  func testTwoSessionsSameStreamRenderIdentically() throws {
    let bytes = try capturedBytes()
    try BitmapDiffHarness.assertBitmapsMatch(
      expected: RenderScenario(name: "session-a", feeds: [bytes]),
      actual: RenderScenario(name: "session-b", feeds: [bytes]),
      label: "session-determinism")
  }

  /// Calling `encodePaste` between feeds must not change the
  /// rendered bitmap — `encodePaste` is encode-only, it does not
  /// touch the local VT, so a session with an encode call in the
  /// middle of its stream must render the same as one without.
  /// This is the load-bearing property of the paste fix: a fixture-
  /// mode local Session in remote-backend mode receives bytes only
  /// from the byte ring, never from paste encoding.
  func testEncodePasteBetweenFeedsDoesNotChangeRender() throws {
    let bytes = try capturedBytes()
    try BitmapDiffHarness.assertBitmapsMatch(
      expected: RenderScenario(name: "no-paste", feeds: [bytes]),
      actual: RenderScenario(
        name: "with-encode-paste",
        feeds: [bytes],
        action: { session in
          _ = session.encodePaste("1\n2\n3\n4")
        }),
      label: "encode-paste-invariance")
  }

  /// Negative control: `writePasteCapturingBytes` in fixture mode
  /// *does* feed the encoded paste into the local VT (the in-process-
  /// backend path). Asserting that the two bitmaps differ pins this
  /// behaviour: if a future change accidentally makes `writePaste`
  /// stop writing to the VT (or `encodePaste` start writing to it),
  /// either this test or `testEncodePasteBetweenFeedsDoesNotChangeRender`
  /// fails — together they fence both directions of the contract.
  func testWritePasteBetweenFeedsDoesChangeRender() throws {
    let bytes = try capturedBytes()
    let expected = try BitmapDiffHarness.render(
      RenderScenario(name: "no-paste", feeds: [bytes]))
    let actual = try BitmapDiffHarness.render(
      RenderScenario(
        name: "with-write-paste",
        feeds: [bytes],
        action: { session in
          _ = session.write(Array("\u{1B}[?2004h".utf8))
          _ = session.writePasteCapturingBytes("1\n2\n3\n4")
        }))
    guard let result = BitmapDiff.compare(expected, actual) else {
      XCTFail("dimensions mismatch")
      return
    }
    XCTAssertGreaterThan(
      result.mismatchedPixels, 0,
      "writePasteCapturingBytes in fixture mode must feed bytes to the local VT — bitmaps should differ")
  }
}
