import Foundation
import LabanTerminalCore

enum SessionError: Error {
    case createFailed
}

final class Session {
    typealias ID = String

    let id: ID
    private var handle: OpaquePointer?
    private(set) var isClosed = false

    init(config: inout LabanLaunchConfig, size: LabanTerminalSize) throws {
        self.id = UUID().uuidString
        var h: OpaquePointer?
        guard laban_session_create(&config, size, &h) == 0, let h else {
            throw SessionError.createFailed
        }
        self.handle = h
    }

    static func fixture(size: LabanTerminalSize) throws -> Session {
        var config = LabanLaunchConfig()
        config.fixture_mode = 1
        return try Session(config: &config, size: size)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let h = handle {
            laban_session_destroy(h)
            handle = nil
        }
    }

    deinit { close() }

    @discardableResult
    func poll() -> Int32 {
        guard !isClosed, let h = handle else { return -1 }
        return laban_session_poll(h)
    }

    @discardableResult
    func resize(_ size: LabanTerminalSize) -> Int32 {
        guard !isClosed, let h = handle else { return -1 }
        return laban_session_resize(h, size)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int32 {
        guard !isClosed, let h = handle else { return -1 }
        if bytes.isEmpty { return 0 }
        return bytes.withUnsafeBytes { buf in
            laban_session_write(h, buf.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count)
        }
    }

    func snapshot() -> UnsafeMutablePointer<LabanSnapshot>? {
        guard !isClosed, let h = handle else { return nil }
        var snap: UnsafeMutablePointer<LabanSnapshot>?
        guard laban_session_snapshot(h, &snap) == 0 else { return nil }
        return snap
    }
}
