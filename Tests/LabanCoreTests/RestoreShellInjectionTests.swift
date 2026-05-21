import Foundation
import XCTest

@testable import LabanCore

final class RestoreShellInjectionTests: XCTestCase {

  func testArgvWrapsCommandInLoginInteractiveShellAndExecsBackToShell() {
    let injection = RestoreShellInjection(
      command: "command claude --resume abc",
      shellPath: "/bin/zsh")
    XCTAssertEqual(
      injection.argv,
      [
        "/bin/zsh", "-l", "-i", "-c",
        "command claude --resume abc; exec /bin/zsh -l -i",
      ])
  }

  func testPayloadDropsToLoginInteractiveShellAfterCommandExits() {
    let injection = RestoreShellInjection(
      command: "codex resume xyz -C /tmp",
      shellPath: "/opt/homebrew/bin/fish")
    XCTAssertEqual(
      injection.payload,
      "codex resume xyz -C /tmp; exec /opt/homebrew/bin/fish -l -i")
  }

  func testShellPathWithSpaceIsQuotedInExecTail() {
    let injection = RestoreShellInjection(
      command: "command claude --resume abc",
      shellPath: "/Applications/My Shell/bin/zsh")
    XCTAssertEqual(
      injection.argv,
      [
        "/Applications/My Shell/bin/zsh", "-l", "-i", "-c",
        "command claude --resume abc; exec '/Applications/My Shell/bin/zsh' -l -i",
      ])
  }

  func testExecuteNowInstructionMapsToInjection() {
    let instruction = RestoreLaunchInstruction.executeNow(command: "command claude --resume abc")
    XCTAssertEqual(
      instruction.spawnInjection,
      RestoreShellInjection(command: "command claude --resume abc"))
  }

  func testPrefillPromptInstructionHasNoInjection() {
    XCTAssertNil(
      RestoreLaunchInstruction.prefillPrompt(command: "command claude --resume abc").spawnInjection)
  }

  func testNoPrefillInstructionHasNoInjection() {
    XCTAssertNil(RestoreLaunchInstruction.noPrefill.spawnInjection)
  }

  func testLoginShellPrefersShellEnvironmentVariable() {
    XCTAssertEqual(
      LoginShell.resolvePath(environment: ["SHELL": "/usr/bin/fish"]),
      "/usr/bin/fish")
  }

  func testLoginShellFallsBackWhenShellEnvIsEmpty() {
    // Empty SHELL must not win; resolution falls through to the passwd
    // entry or /bin/sh. Either way it is a non-empty absolute path.
    let resolved = LoginShell.resolvePath(environment: ["SHELL": ""])
    XCTAssertTrue(resolved.hasPrefix("/"), "expected an absolute shell path, got \(resolved)")
    XCTAssertFalse(resolved.isEmpty)
  }
}
