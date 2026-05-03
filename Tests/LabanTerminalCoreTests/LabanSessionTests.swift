import XCTest
import LabanTerminalCore

final class LabanSessionTests: XCTestCase {

    private func makeFixtureSession(rows: Int32 = 24, cols: Int32 = 80) -> OpaquePointer? {
        var config = LabanLaunchConfig()
        config.fixture_mode = 1
        var size = LabanTerminalSize()
        size.rows = rows
        size.cols = cols
        var session: OpaquePointer?
        let result = laban_session_create(&config, size, &session)
        guard result == 0 else { return nil }
        return session
    }

    func testFixtureCreatePollSnapshotDestroy() {
        guard let session = makeFixtureSession() else {
            XCTFail("laban_session_create returned non-zero")
            return
        }

        XCTAssertEqual(laban_session_poll(session), 0, "poll must return 0 in fixture mode")

        let bytes = Array("hello".utf8)
        let writeResult = bytes.withUnsafeBytes { buf in
            laban_session_write(session,
                buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count)
        }
        XCTAssertEqual(writeResult, 0, "fixture write must succeed")

        var snapshot: UnsafeMutablePointer<LabanSnapshot>?
        XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
        defer { laban_snapshot_destroy(snapshot) }

        guard let snap = snapshot else {
            XCTFail("snapshot is nil")
            return
        }
        XCTAssertGreaterThan(snap.pointee.cell_count, 0)
        let cells = snap.pointee.cells!
        let hCode = UInt32(UInt8(ascii: "h"))
        XCTAssertEqual(cells[0].codepoint, hCode,
            "cell (0,0) should hold 'h' after writing 'hello'")

        var newSize = LabanTerminalSize()
        newSize.rows = 12
        newSize.cols = 40
        XCTAssertEqual(laban_session_resize(session, newSize), 0)

        laban_session_destroy(session)
    }

    func testFixtureResizeChangesSize() {
        guard let session = makeFixtureSession() else {
            XCTFail("laban_session_create returned non-zero")
            return
        }
        defer { laban_session_destroy(session) }

        var newSize = LabanTerminalSize()
        newSize.rows = 12
        newSize.cols = 40
        XCTAssertEqual(laban_session_resize(session, newSize), 0)

        var snapshot: UnsafeMutablePointer<LabanSnapshot>?
        XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
        defer { laban_snapshot_destroy(snapshot) }

        guard let snap = snapshot else {
            XCTFail("snapshot is nil")
            return
        }
        XCTAssertEqual(snap.pointee.rows, 12, "rows should be 12 after resize")
        XCTAssertEqual(snap.pointee.cols, 40, "cols should be 40 after resize")
        XCTAssertEqual(snap.pointee.cell_count, 12 * 40)
    }

    func testFixtureSnapshotDestroyIsSafe() {
        guard let session = makeFixtureSession() else {
            XCTFail("laban_session_create returned non-zero")
            return
        }

        var snapshot: UnsafeMutablePointer<LabanSnapshot>?
        XCTAssertEqual(laban_session_snapshot(session, &snapshot), 0)
        laban_snapshot_destroy(snapshot)
        laban_session_destroy(session)
    }
}
