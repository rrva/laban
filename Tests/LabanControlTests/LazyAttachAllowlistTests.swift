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

  func testSessionScrollIsAllowlistedNotPersistable() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "session.scroll")
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.persistable, false)
  }

  func testCommandProposeIsAllowlistedNotPersistable() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "command.propose")
    XCTAssertNotNil(entry)
    XCTAssertEqual(entry?.persistable, false)
  }

  func testSessionRequestIsNotDirectlyAllowlisted() {
    let entry = ControlLazyAttachAllowlist.entry(cliCommand: "session.request")
    XCTAssertNil(entry)
  }

  func testRouteAndIntentLookup() {
    XCTAssertTrue(
      ControlLazyAttachAllowlist.isAllowlisted(method: "GET", path: "/debug/state", intentID: "app.state"))
    XCTAssertFalse(
      ControlLazyAttachAllowlist.isAllowlisted(method: "POST", path: "/debug/actions", intentID: "input.typeText"))
  }
}
