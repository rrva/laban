import Foundation
import XCTest

@testable import LabanDebug

final class DebugFixtureResolverTests: XCTestCase {
  func testResolveAcceptsNestedRelativePathInsideFixtureRoot() throws {
    let root = tempRoot()
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    let nestedDir = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
    let fixture = nestedDir.appendingPathComponent("case.fixture.json")
    try Data("{}".utf8).write(to: fixture)

    let resolved = try DebugFixtureResolver.resolve("nested/./case.fixture.json", root: root)
    XCTAssertEqual(resolved.standardizedFileURL.path, fixture.standardizedFileURL.path)
  }

  func testResolveRejectsEmptyAbsoluteTraversalAndSymlinkPaths() throws {
    let runRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-fixture-resolver-\(UUID().uuidString)", isDirectory: true)
    let root = runRoot.appendingPathComponent("fixtures", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: runRoot) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = runRoot.appendingPathComponent("outside.fixture.json")
    try Data("{}".utf8).write(to: outside)

    assertResolve("", root: root, throws: .empty)
    assertResolve(outside.path, root: root, throws: .absolute)
    assertResolve("../outside.fixture.json", root: root, throws: .traversal)

    let link = root.appendingPathComponent("link.fixture.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    assertResolve("link.fixture.json", root: root, throws: .symlink("link.fixture.json"))
  }

  private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-fixture-resolver-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("fixtures", isDirectory: true)
  }

  private func assertResolve(
    _ path: String,
    root: URL,
    throws expected: DebugFixturePathError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try DebugFixtureResolver.resolve(path, root: root),
      file: file,
      line: line
    ) { error in
      guard let actual = error as? DebugFixturePathError else {
        XCTFail("expected DebugFixturePathError, got \(error)", file: file, line: line)
        return
      }
      XCTAssertEqual(actual.description, expected.description, file: file, line: line)
    }
  }
}
