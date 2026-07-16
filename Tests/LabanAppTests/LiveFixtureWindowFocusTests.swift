import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class LiveFixtureWindowFocusTests: XCTestCase {
  @MainActor
  func testTrueOrdersThroughMainActorHandlerAndFalseIsRejected() {
    let router = LiveIntentRouter(model: nil)
    var handlerCalls = 0
    router.bindFixtureWindowFocusHandler {
      MainActor.preconditionIsolated()
      handlerCalls += 1
      return true
    }

    XCTAssertEqual(
      router.route(action(#"{"action":"windowFocus","focused":true}"#)).status,
      200)
    XCTAssertEqual(handlerCalls, 1)

    XCTAssertEqual(
      router.route(action(#"{"action":"windowFocus","focused":false}"#)).status,
      400)
    XCTAssertEqual(handlerCalls, 1, "focused=false must never order or hide the live window")

    XCTAssertEqual(
      router.route(action(#"{"action":"windowFocus","focused":"true"}"#)).status,
      400)
    XCTAssertEqual(handlerCalls, 1)
  }

  @MainActor
  func testMissingOrFailedLiveHandlerFailsClosed() {
    let unbound = LiveIntentRouter(model: nil)
    XCTAssertEqual(
      unbound.route(action(#"{"action":"windowFocus","focused":true}"#)).status,
      503)

    let missingWindow = LiveIntentRouter(model: nil)
    missingWindow.bindFixtureWindowFocusHandler { false }
    XCTAssertEqual(
      missingWindow.route(action(#"{"action":"windowFocus","focused":true}"#)).status,
      503)
  }

  private func action(_ body: String) -> Intent {
    .legacyDebugAction(
      LegacyDebugActionInput(
        intentID: "fixture.windowFocus",
        action: "windowFocus",
        body: Data(body.utf8)))
  }
}
