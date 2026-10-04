import AppKit
import LabanCore
import XCTest

@testable import LabanApp

final class PasteEventClipboardTests: XCTestCase {
  func testScreenshotTIFFIsOfferedAsPNGAlongsideText() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let rep = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    pasteboard.declareTypes([.tiff, .string], owner: nil)
    pasteboard.setData(rep.tiffRepresentation, forType: .tiff)
    pasteboard.setString("caption", forType: .string)

    let items = PasteEventClipboard.items(from: pasteboard)

    XCTAssertEqual(items.map(\.mime), ["image/png", "text/plain"])
    XCTAssertEqual(
      Array(items[0].data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "image must be PNG-encoded")
    XCTAssertEqual(items[1].data, Data("caption".utf8))
  }

  func testEmptyPasteboardOffersNothing() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    XCTAssertEqual(PasteEventClipboard.items(from: pasteboard), [])
  }

  func testCapKeepsEarlierRepresentations() {
    let big = Session.PasteEventItem(
      mime: "image/png", data: Data(count: PasteEventClipboard.maxTotalBytes))
    let text = Session.PasteEventItem(mime: "text/plain", data: Data("x".utf8))
    XCTAssertEqual(PasteEventClipboard.capped([big, text]).map(\.mime), ["image/png"])
  }

  func testTextIsSanitizedLikeEveryOtherPaste() {
    let items = PasteEventClipboard.items(text: "a\u{1b}]0;pwned\u{07}b\n")
    XCTAssertEqual(items.first?.data, Data("a]0;pwnedb\n".utf8))
  }
}
