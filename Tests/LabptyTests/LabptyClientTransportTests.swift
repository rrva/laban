import Darwin
import Foundation
import XCTest

@testable import LabanCore

final class LabptyClientTransportTests: XCTestCase {
  private var tempRoots: [URL] = []

  override func tearDown() {
    for root in tempRoots {
      try? FileManager.default.removeItem(at: root)
    }
    tempRoots.removeAll()
    super.tearDown()
  }

  func testClientRejectsOversizeFrameClaimBeforePayloadRead() throws {
    let server = try FakeLabptyServer(root: temporaryDirectory()) { fd in
      _ = try Self.readFrameRaw(fd: fd)
      var header = [UInt8]()
      header.append(contentsOf: LabptyFrameHeader.magic)
      header.appendUInt16(LabptyFrameHeader.abiMajor)
      header.appendUInt16(LabptyFrameHeader.abiMinor)
      header.appendUInt32(UInt32(LabptyFrameHeader.maxFrameBytes + 1))
      header.appendUInt16(LabptyFrameHeader.responseOperation)
      header.appendUInt16(LabptyErrorCode.ok.rawValue)
      header.appendUInt64(1)
      try Self.writeAllRaw(fd: fd, data: Data(header))
      Thread.sleep(forTimeInterval: 0.3)
    }
    try server.start()
    let client = try LabptyTerminalSessionClient(
      socketPath: server.socketPath,
      rpcTimeoutMilliseconds: 200)
    defer { client.close() }

    XCTAssertThrowsError(try client.hello()) { error in
      XCTAssertEqual(error as? LabptyProtocolError, .oversizeFrame)
    }
  }

  func testClientTimesOutWhenServerDoesNotRespond() throws {
    let server = try FakeLabptyServer(root: temporaryDirectory()) { fd in
      _ = try Self.readFrameRaw(fd: fd)
      Thread.sleep(forTimeInterval: 0.5)
    }
    try server.start()
    let client = try LabptyTerminalSessionClient(
      socketPath: server.socketPath,
      rpcTimeoutMilliseconds: 100)
    defer { client.close() }

    XCTAssertThrowsError(try client.hello())
  }

  func testClientRejectsHelloMissingRequiredCapabilities() throws {
    let server = try FakeLabptyServer(root: temporaryDirectory()) { fd in
      let request = try Self.readFrameRaw(fd: fd)
      let payload = try LabptyHelloResponse(capabilities: [LabptyCapabilities.byteRingV1]).encode()
      let response = try LabptyFraming.encodeResponse(
        sequence: request.header.sequence,
        code: .ok,
        payload: payload)
      try Self.writeAllRaw(fd: fd, data: response)
    }
    try server.start()
    let client = try LabptyTerminalSessionClient(
      socketPath: server.socketPath,
      rpcTimeoutMilliseconds: 200)
    defer { client.close() }

    XCTAssertThrowsError(try client.hello())
  }

  private func temporaryDirectory() throws -> URL {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("lpt-client-\(UUID().uuidString.prefix(8))", isDirectory: true)
    tempRoots.append(root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private static func writeAllRaw(fd: Int32, data: Data) throws {
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.write(fd, base.advanced(by: offset), data.count - offset)
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
  }

  private static func readExactRaw(fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let n = data.withUnsafeMutableBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return Darwin.read(fd, base.advanced(by: offset), count - offset)
      }
      if n == 0 { throw POSIXError(.ECONNRESET) }
      if n < 0 {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      offset += n
    }
    return data
  }

  private static func readFrameRaw(fd: Int32) throws -> LabptyFrame {
    let header = try readExactRaw(fd: fd, count: LabptyFrameHeader.headerByteCount)
    let headerBytes = [UInt8](header)
    let totalLength = Int(
      UInt32(headerBytes[8])
        | (UInt32(headerBytes[9]) << 8)
        | (UInt32(headerBytes[10]) << 16)
        | (UInt32(headerBytes[11]) << 24))
    guard totalLength >= LabptyFrameHeader.headerByteCount,
      totalLength <= LabptyFrameHeader.maxFrameBytes
    else {
      throw LabptyProtocolError.truncatedFrame
    }
    let body = try readExactRaw(fd: fd, count: totalLength - LabptyFrameHeader.headerByteCount)
    return try LabptyFraming.decode(header + body)
  }
}

private final class FakeLabptyServer {
  let socketPath: String
  private let listenFd: Int32
  private let handler: (Int32) throws -> Void

  init(root: URL, handler: @escaping (Int32) throws -> Void) throws {
    self.socketPath = root.appendingPathComponent("fake.sock").path
    self.handler = handler
    listenFd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenFd >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8CString)
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      Darwin.close(listenFd)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      for index in 0..<pathBytes.count {
        ptr.advanced(by: index).pointee = pathBytes[index]
      }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Darwin.bind(listenFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let err = errno
      Darwin.close(listenFd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
    guard Darwin.listen(listenFd, 1) == 0 else {
      let err = errno
      Darwin.close(listenFd)
      throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
    }
  }

  deinit {
    Darwin.close(listenFd)
  }

  func start() throws {
    DispatchQueue.global(qos: .userInitiated).async { [listenFd, handler] in
      let fd = Darwin.accept(listenFd, nil, nil)
      guard fd >= 0 else { return }
      defer { Darwin.close(fd) }
      try? handler(fd)
    }
  }
}

extension Array where Element == UInt8 {
  fileprivate mutating func appendUInt16(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  fileprivate mutating func appendUInt32(_ value: UInt32) {
    for shift in stride(from: 0, through: 24, by: 8) {
      append(UInt8((value >> shift) & 0xFF))
    }
  }

  fileprivate mutating func appendUInt64(_ value: UInt64) {
    for shift in stride(from: 0, through: 56, by: 8) {
      append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
  }
}
