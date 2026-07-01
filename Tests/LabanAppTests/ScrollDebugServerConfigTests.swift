import XCTest

@testable import LabanApp

final class ScrollDebugServerConfigTests: XCTestCase {
  func testCommandLineScrollDebugUsesDefaultPort() throws {
    let config = try XCTUnwrap(
      ScrollDebugServer.Config.fromLaunchArguments(["LabanApp", "--scroll-debug"]))

    XCTAssertEqual(config.port, 8787)
  }

  func testCommandLineScrollDebugCanSpecifyPort() throws {
    let config = try XCTUnwrap(
      ScrollDebugServer.Config.fromLaunchArguments(["LabanApp", "--scroll-debug=8788"]))

    XCTAssertEqual(config.port, 8788)
  }

  func testNoScrollDebugArgumentDisablesScrollDebug() {
    XCTAssertNil(ScrollDebugServer.Config.fromLaunchArguments(["LabanApp"]))
  }
}
