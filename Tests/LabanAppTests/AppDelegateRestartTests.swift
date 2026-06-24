import XCTest

@testable import LabanApp

/// Regression for the "Restart Laban" menu quitting instead of relaunching:
/// the bundle sets `LSMultipleInstancesProhibited`, so a plain `open -n` while
/// the old instance is alive is a no-op and the app merely quits (ff96b60 added
/// the key three weeks after the restart feature). The relaunch must defer the
/// `open` until this process has exited.
final class AppDelegateRestartTests: XCTestCase {
  func testRelaunchWaitsForCurrentProcessThenOpensBundle() {
    let command = AppDelegate.relaunchCommand(pid: 4242, bundlePath: "/Applications/Laban.app")
    XCTAssertEqual(command.executable, "/bin/sh")
    XCTAssertEqual(command.arguments.first, "-c")
    let script = command.arguments.last ?? ""
    // Waits on the old pid before relaunching, so the successor never overlaps.
    XCTAssertTrue(script.contains("kill -0 4242"), script)
    XCTAssertTrue(script.contains("/usr/bin/open"), script)
    // The open must run only after the wait loop, not concurrently.
    let killIndex = script.range(of: "kill -0 4242")?.lowerBound
    let openIndex = script.range(of: "/usr/bin/open")?.lowerBound
    XCTAssertNotNil(killIndex)
    XCTAssertNotNil(openIndex)
    if let killIndex, let openIndex {
      XCTAssertTrue(killIndex < openIndex, "open must follow the wait loop")
    }
  }

  func testRelaunchQuotesBundlePathWithSpaces() {
    let command = AppDelegate.relaunchCommand(
      pid: 1,
      bundlePath: "/Users/rrj/My Apps/Laban.app"
    )
    let script = command.arguments.last ?? ""
    XCTAssertTrue(script.contains("'/Users/rrj/My Apps/Laban.app'"), script)
  }

  func testRelaunchEscapesSingleQuoteInBundlePath() {
    let command = AppDelegate.relaunchCommand(
      pid: 1,
      bundlePath: "/Users/rrj/o'brien/Laban.app"
    )
    let script = command.arguments.last ?? ""
    // The lone quote is closed, escaped, and reopened so /bin/sh sees the literal path.
    XCTAssertTrue(script.contains("'/Users/rrj/o'\\''brien/Laban.app'"), script)
  }
}
