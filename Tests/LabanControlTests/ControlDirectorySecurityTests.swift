import Foundation
import LabanControl
import XCTest

final class ControlDirectorySecurityTests: XCTestCase {
  func testRepairsInsecureExistingDirectory() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-ctl-dir-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    try FileManager.default.createDirectory(
      at: dir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    try ControlDirectorySecurity.ensurePrivateDirectory(at: dir)

    let attributes = try FileManager.default.attributesOfItem(atPath: dir.path)
    let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
    XCTAssertEqual(permissions, 0o700)
  }

  func testRejectsSymlinkedDirectory() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-ctl-base-\(UUID().uuidString)", isDirectory: true)
    let target = base.appendingPathComponent("target", isDirectory: true)
    let link = base.appendingPathComponent("link", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: base)
    }
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    XCTAssertThrowsError(try ControlDirectorySecurity.rejectSymlinkDirectory(at: link)) { error in
      XCTAssertEqual(error as? ControlDirectorySecurityError, .symlink)
    }
  }

  func testPrepareSocketPathRejectsRegularFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-ctl-sock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try ControlDirectorySecurity.ensurePrivateDirectory(at: dir)

    let socketPath = dir.appendingPathComponent("control.sock").path
    FileManager.default.createFile(atPath: socketPath, contents: Data("not-a-socket".utf8))

    XCTAssertThrowsError(try ControlDirectorySecurity.prepareSocketPath(socketPath)) { error in
      XCTAssertEqual(error as? ControlDirectorySecurityError, .socketPathNotSocket)
    }
  }
}
