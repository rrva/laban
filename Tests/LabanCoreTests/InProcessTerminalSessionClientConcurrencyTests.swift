import Foundation
import LabanCore
import XCTest

/// The in-process client mirrors laband's session catalog (parity with
/// laband#44): its lease, snapshot, resize and catalog calls may come from
/// different threads, so a session's fields must not be written while
/// another thread reads or appends to them.
final class InProcessTerminalSessionClientConcurrencyTests: XCTestCase {
  func testConcurrentLeaseTransfersSnapshotsResizesAndListsKeepEveryWrite() throws {
    let client = InProcessTerminalSessionClient()
    let session = try client.createSession(
      TerminalSessionLaunchRequest(
        executable: "/bin/cat",
        argv: ["/bin/cat"],
        cwd: FileManager.default.currentDirectoryPath,
        rows: 24,
        cols: 80
      )
    )
    let sessionId = session.logicalSessionId
    defer { _ = try? client.terminate(sessionId: sessionId) }

    let sizes = [(24, 80), (30, 100), (40, 132)]
    let allowedSizes = Set(sizes.map { "\($0.0)x\($0.1)" })
    let transfersPerThread = 400
    let transferThreads = 4
    let failures = NSMutableArray()
    let failureLock = NSLock()
    func fail(_ message: String) {
      failureLock.lock()
      if failures.count < 20 { failures.add(message) }
      failureLock.unlock()
    }

    DispatchQueue.concurrentPerform(iterations: transferThreads + 3) { worker in
      do {
        switch worker {
        case ..<transferThreads:
          for index in 0..<transfersPerThread {
            _ = try client.transferLease(
              sessionId: sessionId, holderClientId: "client-\(worker)-\(index)")
          }
        case transferThreads:
          for index in 0..<300 {
            let (rows, cols) = sizes[index % sizes.count]
            _ = try client.resize(sessionId: sessionId, rows: rows, cols: cols)
          }
        case transferThreads + 1:
          for _ in 0..<300 {
            _ = try client.snapshot(sessionId: sessionId)
          }
        default:
          for _ in 0..<300 {
            for info in try client.listSessions() where info.logicalSessionId == sessionId {
              if !allowedSizes.contains("\(info.rows)x\(info.cols)") {
                fail("unwritten size \(info.rows)x\(info.cols)")
              }
            }
          }
        }
      } catch {
        fail("worker \(worker): \(error)")
      }
    }

    XCTAssertEqual(failures as? [String], [])
    let info = try XCTUnwrap(
      client.listSessions().first { $0.logicalSessionId == sessionId })
    XCTAssertEqual(
      info.leaseHistory.count, transferThreads * transfersPerThread,
      "every lease transfer must land in the history")
  }
}
