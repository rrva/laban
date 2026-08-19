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
    let script = command.arguments.dropFirst().first ?? ""
    // Waits on the old pid before relaunching, so the successor never overlaps.
    XCTAssertTrue(script.contains("kill -0 \"$old_pid\""), script)
    XCTAssertTrue(script.contains("/usr/bin/open"), script)
    // The wait is bounded so a stuck termination cannot hang the relaunch.
    XCTAssertTrue(script.contains("-lt 100"), script)
    // No `-n`: the force-new-instance flag is what made two instances overlap
    // and fight over the daemon socket / workspace.json (BUG-04). Must stay gone.
    XCTAssertFalse(script.contains(" -n "), script)
    // The open must run only after the wait loop, not concurrently.
    let killIndex = script.range(of: "kill -0 \"$old_pid\"")?.lowerBound
    let openIndex = script.range(of: "/usr/bin/open")?.lowerBound
    XCTAssertNotNil(killIndex)
    XCTAssertNotNil(openIndex)
    if let killIndex, let openIndex {
      XCTAssertTrue(killIndex < openIndex, "open must follow the wait loop")
    }
    XCTAssertEqual(command.arguments.dropFirst(2).first, "laban-relaunch")
    XCTAssertEqual(command.arguments.dropFirst(3).first, "4242")
    XCTAssertEqual(command.arguments.dropFirst(4).first, "/Applications/Laban.app")
  }

  func testRelaunchPassesBundlePathWithSpacesAsArgument() {
    let command = AppDelegate.relaunchCommand(
      pid: 1,
      bundlePath: "/Users/user/My Apps/Laban.app"
    )
    XCTAssertEqual(command.arguments.dropFirst(4).first, "/Users/user/My Apps/Laban.app")
  }

  func testRelaunchPassesSingleQuoteInBundlePathAsArgument() {
    let command = AppDelegate.relaunchCommand(
      pid: 1,
      bundlePath: "/Users/user/o'brien/Laban.app"
    )
    XCTAssertEqual(command.arguments.dropFirst(4).first, "/Users/user/o'brien/Laban.app")
  }

  func testRelaunchForwardsLaunchArgumentsAfterBundlePath() {
    let command = AppDelegate.relaunchCommand(
      pid: 1,
      bundlePath: "/Applications/Laban.app",
      launchArguments: ["--scroll-debug", "--terminal-backend", "detached", "--name=has spaces"]
    )

    XCTAssertEqual(
      Array(command.arguments.dropFirst(5)),
      ["--args", "--scroll-debug", "--terminal-backend", "detached", "--name=has spaces"])
  }
}
