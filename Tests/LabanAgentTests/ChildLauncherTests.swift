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

  func testLaunchPreservesStdinToStdoutBytesUnmodified() throws {
    // The broker must not consume, buffer, or transform a child's stdio: bytes
    // written to the child's stdin must arrive on its stdout byte-for-byte.
    let config = try ChildLauncher.prepareConfiguration(
      command: ["cat"],
      inheritedEnvironment: ["PATH": "/bin:/usr/bin"],
      agentControlURL: "unix:///proxy.sock")

    var stdinPipe: [Int32] = [-1, -1]
    var stdoutPipe: [Int32] = [-1, -1]
    XCTAssertEqual(Darwin.pipe(&stdinPipe), 0)
    XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
    defer {
      for fd in [stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1]] where fd >= 0 {
        Darwin.close(fd)
      }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_addclose(&actions, stdinPipe[1])
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])

    let pid = try ChildLauncher.launch(config, fileActions: actions)

    // The parent only needs the write end of stdin and the read end of
    // stdout; the child owns the other two descriptors after spawn.
    Darwin.close(stdinPipe[0])
    stdinPipe[0] = -1
    Darwin.close(stdoutPipe[1])
    stdoutPipe[1] = -1

    // Cover the full byte range, including NUL and newline, to prove the
    // stdio path is a raw byte passthrough rather than a line-oriented or
    // text-aware wrapper.
    let payload = Data((0...255).map { UInt8($0) })
    try payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var sent = 0
      while sent < raw.count {
        let n = Darwin.write(stdinPipe[1], base.advanced(by: sent), raw.count - sent)
        if n < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        sent += n
      }
    }
    Darwin.close(stdinPipe[1])
    stdinPipe[1] = -1

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = Darwin.read(stdoutPipe[0], &buffer, buffer.count)
      if n <= 0 { break }
      output.append(contentsOf: buffer[0..<Int(n)])
    }

    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, 0)
    } while result == -1 && errno == EINTR
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: result, status: status), 0)

    XCTAssertEqual(output, payload, "child stdout did not match stdin byte-for-byte")
  }

  func testLaunchKeepsStderrSeparateFromStdout() throws {
    // The broker proxies a single child; stdout and stderr must stay on their
    // own streams rather than being merged or swapped.
    let config = try ChildLauncher.prepareConfiguration(
      command: ["/bin/sh", "-c", "printf 'stdout-bytes'; printf 'stderr-bytes' 1>&2"],
      inheritedEnvironment: ["PATH": "/bin:/usr/bin"],
      agentControlURL: "unix:///proxy.sock")

    var stdoutPipe: [Int32] = [-1, -1]
    var stderrPipe: [Int32] = [-1, -1]
    XCTAssertEqual(Darwin.pipe(&stdoutPipe), 0)
    XCTAssertEqual(Darwin.pipe(&stderrPipe), 0)
    defer {
      for fd in [stdoutPipe[0], stdoutPipe[1], stderrPipe[0], stderrPipe[1]] where fd >= 0 {
        Darwin.close(fd)
      }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
    posix_spawn_file_actions_addclose(&actions, stderrPipe[0])

    let pid = try ChildLauncher.launch(config, fileActions: actions)
    Darwin.close(stdoutPipe[1])
    stdoutPipe[1] = -1
    Darwin.close(stderrPipe[1])
    stderrPipe[1] = -1

    func readAll(_ fd: Int32) -> Data {
      var data = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(contentsOf: buffer[0..<Int(n)])
      }
      return data
    }

    let stdoutData = readAll(stdoutPipe[0])
    let stderrData = readAll(stderrPipe[0])

    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, 0)
    } while result == -1 && errno == EINTR
    XCTAssertEqual(ChildLauncher.exitStatus(waitResult: result, status: status), 0)

    XCTAssertEqual(String(data: stdoutData, encoding: .utf8), "stdout-bytes")
    XCTAssertEqual(String(data: stderrData, encoding: .utf8), "stderr-bytes")
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
