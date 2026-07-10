import Foundation
import LabanCore
import XCTest

/// Covers the proposal lifecycle store and the shared list/get/cancel routing:
/// state transitions, TTL expiry, and session scoping. The router-level
/// (LiveIntentRouter/HeadlessIntentRouter) wiring is covered by the parity and
/// app/debug suites; this exercises the shared LabanCore behavior directly.
final class CommandProposalLifecycleTests: XCTestCase {
  private func store(now: @escaping @Sendable () -> Date) -> CommandProposalStore {
    CommandProposalStore(now: now)
  }

  func testCancelOnlyTransitionsPendingProposals() throws {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    let proposal = try store.submit(command: "git status", purpose: nil, targetSessionID: "A")

    switch store.cancel(id: proposal.id) {
    case .cancelled(let cancelled):
      XCTAssertEqual(cancelled.state, .cancelledByAgent)
    default:
      XCTFail("first cancel of a pending proposal should succeed")
    }

    // Cancelling again is not a silent success: the proposal is already terminal.
    switch store.cancel(id: proposal.id) {
    case .alreadyTerminal(let state):
      XCTAssertEqual(state, .cancelledByAgent)
    default:
      XCTFail("second cancel should report the terminal state")
    }
  }

  func testCancelUnknownProposalIsNotFound() {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    XCTAssertEqual(store.cancel(id: "missing"), .notFound)
  }

  func testPendingProposalExpiresAfterTTL() throws {
    var clock = Date(timeIntervalSince1970: 0)
    let store = store(now: { clock })
    let proposal = try store.submit(command: "echo hi", purpose: nil, targetSessionID: "A")
    XCTAssertEqual(store.proposal(id: proposal.id)?.state, .pendingReview)

    clock = Date(timeIntervalSince1970: CommandProposalStore.pendingReviewTTL + 1)
    XCTAssertEqual(
      store.proposal(id: proposal.id)?.state, .expired,
      "a pending proposal past the TTL is reported expired on read")

    // An expired proposal can no longer be cancelled.
    switch store.cancel(id: proposal.id) {
    case .alreadyTerminal(let state):
      XCTAssertEqual(state, .expired)
    default:
      XCTFail("cancel of an expired proposal should report the terminal state")
    }
  }

  func testListReturnsOnlyOwnSessionNewestFirst() throws {
    var clock = Date(timeIntervalSince1970: 0)
    let store = store(now: { clock })
    let first = try store.submit(command: "a", purpose: nil, targetSessionID: "A")
    clock = Date(timeIntervalSince1970: 10)
    let second = try store.submit(command: "b", purpose: nil, targetSessionID: "A")
    _ = try store.submit(command: "c", purpose: nil, targetSessionID: "B")

    let listA = store.list(targetSessionID: "A")
    XCTAssertEqual(listA.map(\.id), [second.id, first.id], "own session, newest first")
    XCTAssertEqual(store.list(targetSessionID: "B").count, 1)
  }

  func testHandleGetRejectsCrossSessionWith403() throws {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    let proposal = try store.submit(command: "a", purpose: nil, targetSessionID: "A")

    // A caller scoped to session B may not read session A's proposal.
    let body = try JSONEncoder().encode(
      CommandProposalRefRequest(proposalID: proposal.id))
    let response = CommandProposalRouting.handleGet(
      body: body, scopedSessionID: "B", activeSessionID: { nil }, store: store)
    XCTAssertEqual(response.status, 403)
  }

  func testHandleCancelRejectsCrossSessionWith403AndDoesNotMutate() throws {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    let proposal = try store.submit(command: "a", purpose: nil, targetSessionID: "A")

    let body = try JSONEncoder().encode(
      CommandProposalRefRequest(proposalID: proposal.id))
    let response = CommandProposalRouting.handleCancel(
      body: body, scopedSessionID: "B", activeSessionID: { nil }, store: store)
    XCTAssertEqual(response.status, 403)
    XCTAssertEqual(
      store.proposal(id: proposal.id)?.state, .pendingReview,
      "a forbidden cancel must not change the proposal state")
  }

  func testHandleListIsScopedToOwnSession() throws {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    _ = try store.submit(command: "a", purpose: nil, targetSessionID: "A")
    _ = try store.submit(command: "b", purpose: nil, targetSessionID: "B")

    let response = CommandProposalRouting.handleList(
      scopedSessionID: "A", activeSessionID: { nil }, store: store)
    XCTAssertEqual(response.status, 200)
    let decoded = try JSONDecoder().decode(
      CommandProposalListResponse.self, from: response.body)
    XCTAssertEqual(decoded.proposals.count, 1)
    XCTAssertEqual(decoded.proposals.first?.targetSessionID, "A")
  }

  func testHandleCancelOnTerminalProposalReturns409() throws {
    let store = store(now: { Date(timeIntervalSince1970: 0) })
    let proposal = try store.submit(command: "a", purpose: nil, targetSessionID: "A")
    _ = store.cancel(id: proposal.id)

    let body = try JSONEncoder().encode(
      CommandProposalRefRequest(proposalID: proposal.id))
    let response = CommandProposalRouting.handleCancel(
      body: body, scopedSessionID: "A", activeSessionID: { nil }, store: store)
    XCTAssertEqual(response.status, 409)
  }
}
