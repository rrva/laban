import Foundation
import LabanCore
import XCTest

@testable import LabanCLI

final class SpawnCommandTests: XCTestCase {
  private func parse(_ args: String...) -> Result<LabanCommand, LabanArgumentError> {
    LabanArgumentParser.parse(args)
  }

  func testNewKeepsEveryWordAfterTheSeparator() {
    XCTAssertEqual(
      parse("new", "--label", "tests", "--no-focus", "--", "npm", "test", "--", "--watch"),
      .success(
        .spawn(
          SpawnOptions(
            placement: "tab", argv: ["npm", "test", "--", "--watch"], label: "tests",
            focus: false))))
  }

  func testNewTakesJSON() {
    XCTAssertEqual(
      parse("new", "--json"), .success(.spawn(SpawnOptions(placement: "tab", json: true))))
  }

  func testSplitDirections() {
    XCTAssertEqual(parse("split"), .success(.spawn(SpawnOptions(placement: "right"))))
    XCTAssertEqual(parse("split", "--down"), .success(.spawn(SpawnOptions(placement: "down"))))
    XCTAssertEqual(
      parse("split", "--down", "--no-focus", "--cwd", "/tmp", "--", "htop"),
      .success(
        .spawn(SpawnOptions(placement: "down", argv: ["htop"], cwd: "/tmp", focus: false))))
  }

  func testRefusesTyposAndEmptyCommands() {
    XCTAssertEqual(parse("new", "--lable", "x"), .failure(.unknownOption("--lable")))
    XCTAssertEqual(parse("new", "--down"), .failure(.unknownOption("--down")))
    XCTAssertEqual(parse("split", "--left"), .failure(.unknownOption("--left")))
    XCTAssertEqual(parse("split", "--right", "--down"), .failure(.unknownOption("--down")))
    XCTAssertEqual(parse("new", "--"), .failure(.missingArgument("COMMAND")))
    XCTAssertEqual(parse("new", "--label"), .failure(.missingArgument("--label")))
    XCTAssertEqual(parse("window", "new"), .failure(.unknownCommand("window")))
  }

  func testRequestBodyResolvesTheDirectoryAgainstTheCaller() throws {
    let body = SpawnCommand.requestBody(
      options: SpawnOptions(placement: "down", argv: ["make"], cwd: "sub/../src"),
      currentDirectory: "/work/repo")
    let request = try JSONDecoder().decode(ControlSpawnRequest.self, from: Data(body.utf8))
    XCTAssertEqual(request.action, "spawnSplit")
    XCTAssertEqual(request.direction, "down")
    XCTAssertEqual(request.cwd, "/work/repo/src")
    XCTAssertEqual(request.argv, ["make"])

    let tab = try JSONDecoder().decode(
      ControlSpawnRequest.self,
      from: Data(
        SpawnCommand.requestBody(
          options: SpawnOptions(placement: "tab"), currentDirectory: "/work/repo"
        ).utf8))
    XCTAssertEqual(tab.action, "spawnTab")
    XCTAssertNil(tab.direction)
    XCTAssertNil(tab.argv, "no argv means the login shell")
    XCTAssertEqual(tab.cwd, "/work/repo", "the caller's directory is the default")
  }

  func testLazyAttachPathPrintsTheNewSessionID() {
    var seenCommand: String?
    let result = LabanCLI.run(
      command: .spawn(SpawnOptions(placement: "right", argv: ["true"])),
      lazyAttachRequest: { cliCommand, method, path, _, _ in
        seenCommand = cliCommand
        XCTAssertEqual(method, "POST")
        XCTAssertEqual(path, "/debug/actions")
        return (200, #"{"ok":true,"placement":"right","sessionID":"S-NEW","tabID":"T1"}"#)
      })
    XCTAssertEqual(seenCommand, "session.spawnSplit")
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "S-NEW")
  }

  func testBareCommandsResolveOnTheCallersPath() {
    let executables: Set<String> = ["/opt/tools/bin/npm", "/work/repo/scripts/build.sh"]
    let exists = { (path: String) in executables.contains(path) }
    XCTAssertEqual(
      SpawnCommand.resolveExecutable(
        "npm", path: "/usr/bin:/opt/tools/bin", directory: "/work/repo", isExecutable: exists),
      "/opt/tools/bin/npm")
    XCTAssertEqual(
      SpawnCommand.resolveExecutable(
        "./scripts/build.sh", path: nil, directory: "/work/repo", isExecutable: exists),
      "/work/repo/scripts/build.sh")
    XCTAssertNil(
      SpawnCommand.resolveExecutable(
        "nope", path: "/usr/bin", directory: "/work/repo", isExecutable: exists))
  }

  func testUnknownCommandExits127WithoutAskingTheApp() throws {
    var asked = false
    let result = try SpawnCommand.perform(
      options: SpawnOptions(placement: "right", argv: ["no-such-tool"]),
      agentProxyRequest: { _, _ in
        asked = true
        return (200, "")
      },
      lazyAttachRequest: { _, _, _, _, _ in
        asked = true
        return (200, "")
      },
      agentProxyURL: nil,
      currentDirectory: "/tmp",
      environmentPath: "/usr/bin",
      isExecutable: { _ in false })
    XCTAssertEqual(result.exitCode, 127)
    XCTAssertEqual(result.stderr, "laban: command not found: no-such-tool")
    XCTAssertFalse(asked)
  }

  func testSendsTheResolvedPath() throws {
    var sentBody: String?
    _ = try SpawnCommand.perform(
      options: SpawnOptions(placement: "tab", argv: ["npm", "test"]),
      agentProxyRequest: { _, _ in (500, "") },
      lazyAttachRequest: { _, _, _, _, body in
        sentBody = body
        return (200, #"{"ok":true,"placement":"tab","sessionID":"S","tabID":"T"}"#)
      },
      agentProxyURL: nil,
      currentDirectory: "/work",
      environmentPath: "/opt/bin",
      isExecutable: { $0 == "/opt/bin/npm" })
    let request = try JSONDecoder().decode(
      ControlSpawnRequest.self, from: Data(try XCTUnwrap(sentBody).utf8))
    XCTAssertEqual(request.argv, ["/opt/bin/npm", "test"])
  }

  func testLabelIsForTabsAndFlagValuesAreNotSwallowed() {
    XCTAssertEqual(
      parse("split", "--label", "x"),
      .failure(.unknownOption("--label (applies to new tabs only)")))
    XCTAssertEqual(
      parse("run", "--down", "--label", "x", "--", "true"),
      .failure(.unknownOption("--label (applies to new tabs only)")))
    XCTAssertEqual(parse("new", "--cwd", "--json"), .failure(.missingArgument("--cwd")))
  }

  func testRefusalNamesTheServerReason() {
    let result = SpawnCommand.result(
      status: 409, body: #"{"error":"not enough room to split this pane"}"#, json: false)
    XCTAssertEqual(result.exitCode, 5)
    XCTAssertEqual(result.stderr, "laban: not enough room to split this pane")
  }
}

final class RunWaitTests: XCTestCase {
  func testRunRequiresACommandAndTakesWait() {
    XCTAssertEqual(
      LabanArgumentParser.parse(["run", "--wait", "--down", "--", "make", "test"]),
      .success(
        .spawn(SpawnOptions(placement: "down", argv: ["make", "test"], wait: true))))
    XCTAssertEqual(
      LabanArgumentParser.parse(["run", "--", "true"]),
      .success(.spawn(SpawnOptions(placement: "tab", argv: ["true"]))))
    XCTAssertEqual(
      LabanArgumentParser.parse(["run", "--wait"]), .failure(.missingArgument("-- COMMAND")))
    XCTAssertEqual(
      LabanArgumentParser.parse(["new", "--wait"]), .failure(.unknownOption("--wait")))
  }

  /// The wrapper really runs the command word for word and records its status.
  func testWrapperRecordsTheExitStatus() throws {
    let waiter = RunWaiter()
    let directory = try waiter.makeStatusDirectory()
    defer { waiter.removeStatusDirectory(directory) }
    let process = Process()
    let argv = RunWaiter.wrappedArgv(
      ["/bin/sh", "-c", "test \"$1\" = 'a b' && exit 3", "x", "a b"], statusDirectory: directory)
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 3)
    XCTAssertEqual(waiter.wait(statusDirectory: directory), .exited(3))
    let mode = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions]
    XCTAssertEqual(mode as? Int, 0o700)
  }

  /// Ctrl-C in the spawned terminal kills the command; the wrapper survives
  /// and records 130 instead of dying with it.
  func testCommandKilledBySignalIsRecordedAs128PlusSignal() throws {
    let waiter = RunWaiter()
    let directory = try waiter.makeStatusDirectory()
    defer { waiter.removeStatusDirectory(directory) }
    let process = Process()
    let argv = RunWaiter.wrappedArgv(
      ["/bin/sh", "-c", "kill -INT $$"], statusDirectory: directory)
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(waiter.wait(statusDirectory: directory), .exited(130))
  }

  func testClosedTerminalWithoutStatusIsReported() {
    var waiter = RunWaiter()
    waiter.readFile = { $0.hasSuffix("/pid") ? "4242" : nil }
    waiter.processIsAlive = { _ in false }
    waiter.sleep = { _ in }
    XCTAssertEqual(
      waiter.wait(statusDirectory: "/x"),
      .failed("the terminal closed before the command finished"))
  }

  func testWrapperThatNeverStartsTimesOut() {
    var clock = Date(timeIntervalSince1970: 0)
    var waiter = RunWaiter()
    waiter.readFile = { _ in nil }
    waiter.now = { clock }
    waiter.sleep = { clock = clock.addingTimeInterval($0 * 100) }
    guard case .failed(let reason) = waiter.wait(statusDirectory: "/x") else {
      return XCTFail("expected a timeout")
    }
    XCTAssertTrue(reason.contains("did not start"))
  }

  func testRunWaitExitsWithTheCommandStatus() throws {
    var sentBody: String?
    var waiter = RunWaiter()
    waiter.readFile = { $0.hasSuffix("/status") ? "7" : nil }
    let result = try SpawnCommand.perform(
      options: SpawnOptions(placement: "tab", argv: ["/usr/bin/make", "test"], wait: true),
      agentProxyRequest: { _, _ in
        XCTFail("no broker in this test")
        return (500, "")
      },
      lazyAttachRequest: { _, _, _, _, body in
        sentBody = body
        return (200, #"{"ok":true,"placement":"tab","sessionID":"S","tabID":"T"}"#)
      },
      agentProxyURL: nil,
      currentDirectory: "/tmp",
      waiter: waiter,
      environmentPath: "/usr/bin",
      isExecutable: { _ in true })
    XCTAssertEqual(result.exitCode, 7)
    let request = try JSONDecoder().decode(
      ControlSpawnRequest.self, from: Data(try XCTUnwrap(sentBody).utf8))
    XCTAssertEqual(Array(request.argv?.prefix(2) ?? []), ["/bin/sh", "-c"])
    XCTAssertEqual(Array(request.argv?.suffix(2) ?? []), ["/usr/bin/make", "test"])
    XCTAssertEqual(request.label, "make", "the tab is named after the real command")
  }
}
