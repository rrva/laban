import Foundation
import LabanTerminalCore

public enum SessionError: Error {
  case createFailed
}

public final class Session {
  public typealias ID = String

  public let id: ID
  private var handle: OpaquePointer?
  public private(set) var isClosed = false

  public init(config: inout LabanLaunchConfig, size: LabanTerminalSize) throws {
    self.id = UUID().uuidString
    var h: OpaquePointer?
    guard laban_session_create(&config, size, &h) == 0, let h else {
      throw SessionError.createFailed
    }
    self.handle = h
  }

  public static func fixture(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    return try Session(config: &config, size: size)
  }

  public static func realShell(size: LabanTerminalSize) throws -> Session {
    var config = LabanLaunchConfig()
    config.fixture_mode = 0
    return try Session(config: &config, size: size)
  }

  public func close() {
    guard !isClosed else { return }
    isClosed = true
    if let h = handle {
      laban_session_destroy(h)
      handle = nil
    }
  }

  deinit { close() }

  @discardableResult
  public func poll() -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_poll(h)
  }

  @discardableResult
  public func resize(_ size: LabanTerminalSize) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    return laban_session_resize(h, size)
  }

  @discardableResult
  public func write(_ bytes: [UInt8]) -> Int32 {
    guard !isClosed, let h = handle else { return -1 }
    if bytes.isEmpty { return 0 }
    return bytes.withUnsafeBytes { buf in
      laban_session_write(h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
    }
  }

  public func snapshot() -> UnsafeMutablePointer<LabanSnapshot>? {
    guard !isClosed, let h = handle else { return nil }
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(h, &snap) == 0 else { return nil }
    return snap
  }
}
