import XCTest

@testable import LabanApp

final class TerminalQuickLookTests: XCTestCase {
  func testAbsolutePathResolvesWhenItExists() {
    let url = TerminalQuickLook.fileURL(
      for: "/var/log/system.log", workingDirectory: "/home/me",
      fileExists: { $0 == "/var/log/system.log" })
    XCTAssertEqual(url?.path, "/var/log/system.log")
  }

  func testRelativePathResolvesAgainstWorkingDirectory() {
    let url = TerminalQuickLook.fileURL(
      for: "logs/out.txt", workingDirectory: "/Users/me/proj",
      fileExists: { $0 == "/Users/me/proj/logs/out.txt" })
    XCTAssertEqual(url?.path, "/Users/me/proj/logs/out.txt")
  }

  func testRelativePathWithoutWorkingDirectoryIsUnresolved() {
    let url = TerminalQuickLook.fileURL(
      for: "out.txt", workingDirectory: nil, fileExists: { _ in true })
    XCTAssertNil(url)
  }

  func testSurroundingQuotesAreStripped() {
    let url = TerminalQuickLook.fileURL(
      for: "\"/tmp/a b.txt\"", workingDirectory: nil,
      fileExists: { $0 == "/tmp/a b.txt" })
    XCTAssertEqual(url?.path, "/tmp/a b.txt")
  }

  func testTildeExpands() {
    let home = NSHomeDirectory()
    let url = TerminalQuickLook.fileURL(
      for: "~/notes.md", workingDirectory: nil,
      fileExists: { $0 == "\(home)/notes.md" })
    XCTAssertEqual(url?.path, "\(home)/notes.md")
  }

  func testFileURLSchemeResolves() {
    let url = TerminalQuickLook.fileURL(
      for: "file:///tmp/report.pdf", workingDirectory: nil,
      fileExists: { $0 == "/tmp/report.pdf" })
    XCTAssertEqual(url?.path, "/tmp/report.pdf")
  }

  func testNonexistentFileIsNil() {
    XCTAssertNil(
      TerminalQuickLook.fileURL(
        for: "/no/such/path", workingDirectory: "/cwd", fileExists: { _ in false }))
  }

  func testEmptyAndBlankCandidatesAreNil() {
    XCTAssertNil(
      TerminalQuickLook.fileURL(for: "", workingDirectory: "/cwd", fileExists: { _ in true }))
    XCTAssertNil(
      TerminalQuickLook.fileURL(for: "   ", workingDirectory: "/cwd", fileExists: { _ in true }))
  }

  /// End-to-end against the real filesystem: a temp file resolves, a sibling
  /// name that doesn't exist does not.
  func testResolvesRealTempFileRelativeToCwd() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ql-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("hello.txt")
    try "hi".write(to: file, atomically: true, encoding: .utf8)

    let hit = TerminalQuickLook.fileURL(for: "hello.txt", workingDirectory: dir.path)
    XCTAssertEqual(hit?.path, file.path)
    XCTAssertNil(TerminalQuickLook.fileURL(for: "missing.txt", workingDirectory: dir.path))
  }
}
