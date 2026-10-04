import AppKit
import XCTest

@testable import LabanApp

/// The window-close and quit flow of close confirmation (spec §28).
final class QuitConfirmationTests: XCTestCase {
  private func neverAsked() -> Bool {
    XCTFail("must not ask")
    return true
  }

  func testIdleQuitTerminatesWithoutPresenting() {
    let quit = QuitConfirmation()
    let reply = quit.shouldTerminate(
      asks: { false }, present: { _ in XCTFail("must not present") }, reply: { _ in })
    XCTAssertEqual(reply, .terminateNow)
  }

  func testSynchronousAnswers() {
    let quit = QuitConfirmation()
    XCTAssertEqual(
      quit.shouldTerminate(asks: { true }, present: { $0(true) }, reply: { _ in XCTFail() }),
      .terminateNow)
    XCTAssertEqual(
      quit.shouldTerminate(asks: { true }, present: { $0(false) }, reply: { _ in XCTFail() }),
      .terminateCancel)
  }

  func testSheetAnswerRepliesLater() {
    let quit = QuitConfirmation()
    var pending: ((Bool) -> Void)?
    var replies: [Bool] = []
    let reply = quit.shouldTerminate(
      asks: { true }, present: { pending = $0 }, reply: { replies.append($0) })
    XCTAssertEqual(reply, .terminateLater)
    XCTAssertEqual(replies, [])
    pending?(false)
    XCTAssertEqual(replies, [false], "cancelling the sheet must release the pending quit")
  }

  func testConfirmedWindowCloseQuitsWithoutAskingAgain() {
    let quit = QuitConfirmation()
    var closed = 0
    var pending: ((Bool) -> Void)?
    XCTAssertFalse(
      quit.windowShouldClose(asks: { true }, present: { pending = $0 }, close: { closed += 1 }))
    pending?(true)
    XCTAssertEqual(closed, 1)
    XCTAssertEqual(
      quit.shouldTerminate(asks: neverAsked, present: { _ in }, reply: { _ in }), .terminateNow)
  }

  func testCancelledWindowCloseKeepsWindowAndLaterQuitAsks() {
    let quit = QuitConfirmation()
    var pending: ((Bool) -> Void)?
    XCTAssertFalse(
      quit.windowShouldClose(
        asks: { true }, present: { pending = $0 }, close: { XCTFail("must not close") }))
    pending?(false)
    var asked = false
    _ = quit.shouldTerminate(
      asks: {
        asked = true
        return false
      }, present: { _ in }, reply: { _ in })
    XCTAssertTrue(asked)
  }

  func testIdleWindowClosesImmediately() {
    let quit = QuitConfirmation()
    XCTAssertTrue(
      quit.windowShouldClose(
        asks: { false }, present: { _ in XCTFail() }, close: { XCTFail() }))
  }

  /// A confirmed quit is consumed once; it never skips a later, unrelated quit.
  func testConfirmationIsConsumedByOneQuit() {
    let quit = QuitConfirmation()
    quit.noteQuitConfirmed()
    XCTAssertEqual(
      quit.shouldTerminate(asks: neverAsked, present: { _ in }, reply: { _ in }), .terminateNow)
    XCTAssertEqual(
      quit.shouldTerminate(asks: { true }, present: { $0(false) }, reply: { _ in }),
      .terminateCancel)
  }
}
