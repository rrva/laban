import Foundation
import LabanControl
import LabanCore
import XCTest

final class LazyAttachAllowlistTests: XCTestCase {

  func testSessionStateIsAllowlistedAndPersistable() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "session.state")
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.method, "GET")
    XCTAssertEqual(entry?.path, "/debug/state")
    XCTAssertEqual(entry?.intentID, "app.state")
    XCTAssertEqual(entry?.persistable, true)
  }

  func testSessionScrollIsInTheDialogFirstFamily() {
    // session.scroll maps to terminal.scrollViewport, a family member (kept so
    // own-session scroll keeps working, review NOTE 1). It is reachable through
    // a family grant; persistability is per-principal, not per-entry.
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "session.scroll")
    XCTAssertNotNil(entry)
    XCTAssertTrue(ControlSessionObserveFamily.contains("terminal.scrollViewport"))
  }

  func testCommandProposeIsInTheDialogFirstFamily() {
    // Dialog-first (Milestone 1): persistability is decided per principal via
    // isPersistable, not per-entry, so the whole family grant persists as one
    // unit. command.propose is a family member reachable through a family grant.
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "command.propose")
    XCTAssertNotNil(entry)
    XCTAssertTrue(ControlSessionObserveFamily.contains("command.propose"))
  }

  func testSessionRequestIsNotDirectlyAllowlisted() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "session.request")
    XCTAssertNil(entry)
  }

  func testNotificationTestIsExactAndNeverPersistable() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "notifications.test")
    XCTAssertEqual(entry?.method, "POST")
    XCTAssertEqual(entry?.path, "/debug/notifications/test")
    XCTAssertEqual(entry?.intentID, "notifications.test")
    XCTAssertEqual(entry?.persistable, false)
    XCTAssertFalse(ControlSessionObserveFamily.contains("notifications.test"))
    XCTAssertTrue(
      ControlLazyAttachAllowlist.isAllowlisted(
        method: "POST",
        path: "/debug/notifications/test",
        intentID: "notifications.test"))
  }

  func testWindowScreenshotIsExactPersistableAndOutsideFamily() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "window.screenshot")
    XCTAssertEqual(entry?.method, "GET")
    XCTAssertEqual(entry?.path, "/debug/window-screenshot")
    XCTAssertEqual(entry?.intentID, "window.screenshot")
    XCTAssertEqual(entry?.persistable, true)
    XCTAssertFalse(ControlSessionObserveFamily.contains("window.screenshot"))
    XCTAssertTrue(
      ControlLazyAttachAllowlist.isAllowlisted(
        method: "GET", path: "/debug/window-screenshot", intentID: "window.screenshot"))
  }

  func testRouteAndIntentLookup() {
    XCTAssertTrue(
      ControlLazyAttachAllowlist.isAllowlisted(
        method: "GET", path: "/debug/state", intentID: "app.state"))
    XCTAssertFalse(
      ControlLazyAttachAllowlist.isAllowlisted(
        method: "POST", path: "/debug/actions", intentID: "input.typeText"))
  }
}
