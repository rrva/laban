import Darwin
import Foundation
import LabanControl
import XCTest

final class ControlDiscoveryTests: XCTestCase {
  private let sentinel = "SECRET_SENTINEL_DO_NOT_PRINT"

  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("laban-ctl-discovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return url
  }

  private func writeControlFile(
    at fileURL: URL,
    url: String,
    token: String,
    pid: Int,
    runId: String,
    mode: UInt16 = 0o600
  ) throws {
    let payload: [String: Any] = [
      "url": url,
      "token": token,
      "pid": pid,
      "runId": runId,
    ]
    try writeRawControlFile(at: fileURL, payload: payload, mode: mode)
  }

  private func writeRawControlFile(
    at fileURL: URL,
    payload: [String: Any],
    mode: UInt16 = 0o600
  ) throws {
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: nil)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: mode)],
      ofItemAtPath: fileURL.path)
  }

  // MARK: - Success

  func testValidRecord() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    let socketPath = dir.appendingPathComponent("control.sock").path
    try writeControlFile(
      at: file,
      url: socketPath,
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    let record = try ControlDiscovery.read(
      fileURL: file,
      controlDirectory: dir)
    XCTAssertEqual(record.url, socketPath)
    XCTAssertEqual(record.token, sentinel)
    XCTAssertEqual(record.pid, 1234)
    XCTAssertEqual(record.runId, "run-1")
  }

  func testRedactedOutputDoesNotIncludeToken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    let socketPath = dir.appendingPathComponent("control.sock").path
    try writeControlFile(
      at: file,
      url: socketPath,
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    let record = try ControlDiscovery.read(
      fileURL: file,
      controlDirectory: dir)
    let redacted = ControlDiscovery.redacted(record: record, path: file.path)
    XCTAssertTrue(redacted.hasAppObserveToken)
    XCTAssertEqual(redacted.path, file.path)
    XCTAssertEqual(redacted.url, socketPath)
    XCTAssertEqual(redacted.pid, 1234)
    XCTAssertEqual(redacted.runId, "run-1")

    let data = try JSONEncoder().encode(redacted)
    let text = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(text.contains(sentinel))
    XCTAssertFalse(text.contains("token"))
  }

  // MARK: - Field validation

  func testMissingURL() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: "",
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("url"))
    }
  }

  func testMissingToken() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: "",
      pid: 1234,
      runId: "run-1")

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("token"))
    }
  }

  func testMissingRunId() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "")

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("runId"))
    }
  }

  func testMissingPid() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    let payload: [String: Any] = [
      "url": dir.appendingPathComponent("control.sock").path,
      "token": sentinel,
      "pid": 0,
      "runId": "run-1",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    FileManager.default.createFile(atPath: file.path, contents: data, attributes: nil)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: file.path)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("pid"))
    }
  }

  func testMalformedJSON() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try "not json".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: file.path)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .malformedJSON)
    }
  }

  func testAbsentURLKey() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeRawControlFile(
      at: file,
      payload: ["token": sentinel, "pid": 1234, "runId": "run-1"])

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("url"))
    }
  }

  func testAbsentTokenKey() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeRawControlFile(
      at: file,
      payload: [
        "url": dir.appendingPathComponent("control.sock").path, "pid": 1234, "runId": "run-1",
      ])

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("token"))
    }
  }

  func testAbsentRunIdKey() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeRawControlFile(
      at: file,
      payload: [
        "url": dir.appendingPathComponent("control.sock").path, "token": sentinel, "pid": 1234,
      ])

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("runId"))
    }
  }

  func testAbsentPidKey() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeRawControlFile(
      at: file,
      payload: [
        "url": dir.appendingPathComponent("control.sock").path, "token": sentinel, "runId": "run-1",
      ])

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .missingField("pid"))
    }
  }

  func testNonObjectJSONIsMalformed() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try "\"just a string\"".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: file.path)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .malformedJSON)
    }
  }

  // MARK: - File-system security

  func testOpenThenFstatSecureReadAcceptsOwnerOnly() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1",
      mode: 0o600)

    XCTAssertNoThrow(try ControlDiscovery.read(fileURL: file, controlDirectory: dir))
  }

  func testRejectsGroupReadable() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1",
      mode: 0o640)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .insecurePermissions)
    }
  }

  func testRejectsOtherReadable() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1",
      mode: 0o604)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .insecurePermissions)
    }
  }

  func testRejectsGroupWritable() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1",
      mode: 0o620)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .insecurePermissions)
    }
  }

  func testRejectsWorldWritable() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: dir.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1",
      mode: 0o602)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .insecurePermissions)
    }
  }

  func testRejectsSymlink() throws {
    let base = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let realFile = base.appendingPathComponent("real.json")
    let link = base.appendingPathComponent("control.json")
    try writeControlFile(
      at: realFile,
      url: base.appendingPathComponent("control.sock").path,
      token: sentinel,
      pid: 1234,
      runId: "run-1")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: link, controlDirectory: base)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .symlink)
    }
  }

  func testRejectsOversizedFile() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    let big = String(repeating: "x", count: ControlDiscovery.maxControlFileBytes + 1)
    try big.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: 0o600)],
      ofItemAtPath: file.path)

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(
        error as? ControlDiscoveryError,
        .oversized(maxBytes: ControlDiscovery.maxControlFileBytes))
    }
  }

  func testRejectsDirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try FileManager.default.createDirectory(
      at: file,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .notRegularFile)
    }
  }

  // MARK: - Socket path trust

  func testAcceptsTrustedSocketPathInsideControlDirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    let socketPath = dir.appendingPathComponent("control.sock").path
    try writeControlFile(
      at: file,
      url: socketPath,
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    XCTAssertNoThrow(try ControlDiscovery.read(fileURL: file, controlDirectory: dir))
  }

  func testRejectsSocketPathOutsideControlDirectory() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: "/tmp/evil.sock",
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .untrustedSocketPath)
    }
  }

  func testRejectsRelativeSocketPathEscape() throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("control.json")
    try writeControlFile(
      at: file,
      url: "../escape.sock",
      token: sentinel,
      pid: 1234,
      runId: "run-1")

    XCTAssertThrowsError(
      try ControlDiscovery.read(fileURL: file, controlDirectory: dir)
    ) { error in
      XCTAssertEqual(error as? ControlDiscoveryError, .untrustedSocketPath)
    }
  }
}
