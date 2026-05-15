import AppKit
import XCTest

@testable import LabanApp

final class TerminalDropTests: XCTestCase {
  func testMaterializesImageAsPngUnderDropDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-drop-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()

    let urls = try TerminalDrop.materializeImages([image], in: root)

    XCTAssertEqual(urls.count, 1)
    XCTAssertEqual(urls.first?.deletingLastPathComponent(), root)
    XCTAssertEqual(urls.first?.pathExtension, "png")
    XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    let data = try Data(contentsOf: urls[0])
    XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
  }

  func testRejectsUnsupportedPasteboard() {
    let pasteboard = NSPasteboard.withUniqueName()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("plain text is not a file drop", forType: .string)

    XCTAssertFalse(TerminalDrop.canRead(pasteboard))
  }

  func testReadsFileURLsFromPasteboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    let fileURL = URL(fileURLWithPath: "/tmp/example image.png")

    XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

    XCTAssertTrue(TerminalDrop.canRead(pasteboard))
    XCTAssertEqual(TerminalDrop.readFileURLs(from: pasteboard), [fileURL])
  }

  func testResolvePrefersFileURLWhenPasteboardAlsoContainsImageData() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    let fileURL = URL(fileURLWithPath: "/tmp/example image.png")
    let data = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      ))

    XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
    XCTAssertTrue(pasteboard.setData(data, forType: .png))

    var result: Result<TerminalDrop.ResolvedDrop, Error>?
    TerminalDrop.resolve(pasteboard) { result = $0 }

    let drop = try XCTUnwrap(result).get()
    XCTAssertEqual(drop.urls, [fileURL])
    XCTAssertEqual(drop.sourceKinds, ["fileURL"])
  }

  func testDetectsPngImagePasteboard() throws {
    let pasteboard = NSPasteboard.withUniqueName()
    let data = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
      ))
    pasteboard.declareTypes([.png], owner: nil)
    XCTAssertTrue(pasteboard.setData(data, forType: .png))

    XCTAssertTrue(TerminalDrop.canRead(pasteboard))
    XCTAssertTrue(TerminalDrop.containsImages(pasteboard))
  }
}
