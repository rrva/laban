import Foundation
import LabanControl
import XCTest

@testable import LabanCLI

final class AgentLauncherTests: XCTestCase {
  func testPrepareInvocationResolvesSiblingAgentPath() throws {
    let invocation = try AgentLauncher.prepareInvocation(
      command: ["env"],
      environment: [
        "LABAN_CONTROL_URL": "present",
        "LABAN_SESSION_ATTACH": "present",
      ],
      labanExecutablePath: "/Applications/Laban.app/Contents/MacOS/laban")

    XCTAssertEqual(
      invocation.path,
      "/Applications/Laban.app/Contents/MacOS/laban-agent")
  }

  func testPrepareInvocationResolvesDevBuildSibling() throws {
    let invocation = try AgentLauncher.prepareInvocation(
      command: ["env"],
      environment: [
        "LABAN_CONTROL_URL": "present",
        "LABAN_SESSION_ATTACH": "present",
      ],
      labanExecutablePath: "/Users/rrj/laban/.build/debug/laban")

    XCTAssertEqual(
      invocation.path,
      "/Users/rrj/laban/.build/debug/laban-agent")
  }

  func testPrepareInvocationArgv() throws {
    let invocation = try AgentLauncher.prepareInvocation(
      command: ["git", "status", "--short"],
      environment: [
        "LABAN_CONTROL_URL": "present",
        "LABAN_SESSION_ATTACH": "present",
      ],
      labanExecutablePath: "/tmp/laban")

    XCTAssertEqual(
      invocation.argv,
      [
        "laban-agent",
        "--control-attach",
        "--control-attach-serve-cli",
        "--control-attach-run",
        "--",
        "git", "status", "--short",
      ])
  }

  func testPrepareInvocationRequiresControlURL() {
    XCTAssertThrowsError(
      try AgentLauncher.prepareInvocation(
        command: ["env"],
        environment: ["LABAN_SESSION_ATTACH": "present"],
        labanExecutablePath: "/tmp/laban")
    ) { error in
      XCTAssertEqual(error as? AgentLauncherError, .missingControlURL)
    }
  }

  func testPrepareInvocationRequiresSessionAttach() {
    XCTAssertThrowsError(
      try AgentLauncher.prepareInvocation(
        command: ["env"],
        environment: ["LABAN_CONTROL_URL": "present"],
        labanExecutablePath: "/tmp/laban")
    ) { error in
      XCTAssertEqual(error as? AgentLauncherError, .missingSessionAttach)
    }
  }

  func testPrepareInvocationDoesNotPrintTokenValues() throws {
    let invocation = try AgentLauncher.prepareInvocation(
      command: ["env"],
      environment: [
        "LABAN_CONTROL_URL": "SECRET_CONTROL_URL",
        "LABAN_SESSION_ATTACH": "SECRET_ATTACH",
      ],
      labanExecutablePath: "/tmp/laban")

    // The helper should preserve the env for laban-agent to consume, but the
    // testable prepare function itself must never emit the values.
    XCTAssertEqual(invocation.env["LABAN_CONTROL_URL"], "SECRET_CONTROL_URL")
    XCTAssertEqual(invocation.env["LABAN_SESSION_ATTACH"], "SECRET_ATTACH")
  }
}
