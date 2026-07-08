import Darwin
import Foundation
import LabanCore
import XCTest

@testable import LabanAgent

final class ChildLauncherTests: XCTestCase {
  func testPrepareConfigurationSetsProxyURLAndStripsAttachKeys() throws {
    let config = try ChildLauncher.prepareConfiguration(
      command: ["env"],
      inheritedEnvironment: [
        "LABAN_CONTROL_URL": "keep",
        "LABAN_SESSION_ATTACH": "strip",
        "LABAN_CONTROL_ATTACH_ENV": "strip",
        "PATH": "/usr/bin:/bin",
      ],
      agentControlURL: "unix:///proxy.sock")

    XCTAssertEqual(config.argv0, "env")
    XCTAssertEqual(config.arguments, [])
    XCTAssertEqual(config.environment["LABAN_AGENT_CONTROL_URL"], "unix:///proxy.sock")
    XCTAssertEqual(config.environment["LABAN_CONTROL_URL"], "keep")
    XCTAssertNil(config.environment["LABAN_SESSION_ATTACH"])
    XCTAssertNil(config.environment["LABAN_CONTROL_ATTACH_ENV"])
  }

  func testPrepareConfigurationPreservesArguments() throws {
    let config = try ChildLauncher.prepareConfiguration(
      command: ["git", "status", "--short"],
      inheritedEnvironment: [
        "LABAN_CONTROL_URL": "keep",
        "LABAN_SESSION_ATTACH": "strip",
      ],
      agentControlURL: "unix:///proxy.sock")

    XCTAssertEqual(config.argv0, "git")
    XCTAssertEqual(config.arguments, ["status", "--short"])
  }

  func testLaunchResolvesCommandViaPATH() throws {
    let config = try ChildLauncher.prepareConfiguration(
      command: ["env"],
      inheritedEnvironment: [
        "PATH": "/usr/bin:/bin",
        "LABAN_CONTROL_URL": "keep",
        "LABAN_SESSION_ATTACH": "strip",
        "LABAN_CONTROL_ATTACH_ENV": "strip",
      ],
      agentControlURL: "unix:///proxy.sock")

    var pipe: [Int32] = [-1, -1]
    XCTAssertEqual(Darwin.pipe(&pipe), 0)
    defer {
      if pipe[0] >= 0 { Darwin.close(pipe[0]) }
      if pipe[1] >= 0 { Darwin.close(pipe[1]) }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, pipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, pipe[0])

    let pid = try ChildLauncher.launch(config, fileActions: actions)
    Darwin.close(pipe[1])
    pipe[1] = -1

    var status: Int32 = 0
    waitpid(pid, &status, 0)
    XCTAssertEqual(status & 0x7f, 0)
    XCTAssertEqual((status >> 8) & 0xff, 0)

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = Darwin.read(pipe[0], &buffer, buffer.count)
      if n <= 0 { break }
      data.append(contentsOf: buffer[0..<Int(n)])
    }

    let output = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(output.contains("LABAN_AGENT_CONTROL_URL=unix:///proxy.sock"))
    XCTAssertFalse(output.contains("LABAN_SESSION_ATTACH"))
    XCTAssertFalse(output.contains("LABAN_CONTROL_ATTACH_ENV"))
    XCTAssertTrue(output.contains("LABAN_CONTROL_URL=keep"))
  }

  func testLaunchFailsForUnknownCommand() {
    let config = try! ChildLauncher.prepareConfiguration(
      command: ["laban-agent-command-that-does-not-exist-12345"],
      inheritedEnvironment: ["PATH": "/usr/bin:/bin"],
      agentControlURL: "unix:///proxy.sock")

    XCTAssertThrowsError(try ChildLauncher.launch(config)) { error in
      guard case ChildLauncherError.spawnFailed(let code) = error else {
        XCTFail("expected spawnFailed, got \(error)")
        return
      }
      XCTAssertEqual(code, ENOENT)
    }
  }

  func testExitStatusDecodesNormalExit() {
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: 123, status: 0x0500), 5)
  }

  func testExitStatusDecodesSignalDeath() {
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: 123, status: 2), 130)
  }

  func testExitStatusWaitFailure() {
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: -1, status: 0), 1)
  }
}
