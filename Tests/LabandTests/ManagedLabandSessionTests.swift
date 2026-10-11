import LabanCore
import XCTest

@testable import Laband

/// Unit tests for the session-state operations laband's client threads
/// interleave: lease grants that are rolled back after a failed journal
/// append, and snapshots that land after a resize.
final class ManagedLabandSessionTests: XCTestCase {
  private func makeSession() -> ManagedLabandSession {
    ManagedLabandSession(
      logicalSessionId: "s1",
      incarnationId: "i1",
      commandDisplayName: "sh",
      cwd: "/",
      rows: 24,
      cols: 80,
      title: "sh",
      session: nil
    )
  }

  /// Client A's grant is followed by client B's; then A's journal append
  /// fails. Rolling back A must not take B's lease away.
  func testRollingBackASupersededGrantKeepsTheNewerLease() {
    let managed = makeSession()
    let grantA = managed.grantLease(to: "client-a", now: 1, timeoutNs: 1_000)
    let grantB = managed.grantLease(to: "client-b", now: 2, timeoutNs: 1_000)

    managed.rollBackLeaseGrant(grantA)

    let state = managed.current
    XCTAssertEqual(state.lease?.leaseId, grantB.lease.leaseId)
    XCTAssertEqual(state.leaseHolder, "client-b")
    XCTAssertEqual(state.leaseHistory.map(\.leaseId), [grantB.lease.leaseId])
  }

  func testRollingBackTheCurrentGrantRestoresThePriorLease() {
    let managed = makeSession()
    let grantA = managed.grantLease(to: "client-a", now: 1, timeoutNs: 1_000)
    let grantB = managed.grantLease(to: "client-b", now: 2, timeoutNs: 1_000)

    managed.rollBackLeaseGrant(grantB)

    let state = managed.current
    XCTAssertEqual(state.lease?.leaseId, grantA.lease.leaseId)
    XCTAssertEqual(state.leaseHistory.map(\.leaseId), [grantA.lease.leaseId])
  }

  /// A snapshot taken at 24x80 is recorded after a resize to 40x132 was
  /// recorded. The older snapshot must not shrink the recorded size back.
  func testSnapshotTakenBeforeAResizeDoesNotOverwriteTheResizedSize() {
    let managed = makeSession()
    let generationAtSnapshot = managed.current.resizeGeneration
    managed.recordResize(rows: 40, cols: 132)

    let recorded = managed.recordSnapshot(
      title: "vim", rows: 24, cols: 80, childExited: false,
      resizeGeneration: generationAtSnapshot)

    let state = managed.current
    XCTAssertEqual(state.rows, 40)
    XCTAssertEqual(state.cols, 132)
    XCTAssertEqual(recorded.title, "vim", "a stale snapshot still records its title")
  }

  func testSnapshotTakenAfterTheLatestResizeRecordsItsSize() {
    let managed = makeSession()
    managed.recordResize(rows: 40, cols: 132)

    _ = managed.recordSnapshot(
      title: nil, rows: 41, cols: 133, childExited: false,
      resizeGeneration: managed.current.resizeGeneration)

    let state = managed.current
    XCTAssertEqual(state.rows, 41)
    XCTAssertEqual(state.cols, 133)
    XCTAssertEqual(state.title, "sh")
  }
}
