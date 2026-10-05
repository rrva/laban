import XCTest

@testable import LabanCLI

/// Bug-hunt 2026-10-05 #17 minor: the top-level parser's `default: i += 1`
/// silently keeps unknown flags, so `laban status --jsonn` parses as plain
/// `status` (exit 0, no JSON) while subcommand parsers reject extras.
final class BugHuntVerify2CLITests: XCTestCase {
  func testBug17_TopLevelCommandSilentlyAcceptsMisspelledFlag() {
    let result = LabanArgumentParser.parse(["status", "--jsonn"])
    XCTExpectFailure("bug #17: unknown top-level flag is skipped, not rejected")
    if case .success(let command) = result {
      XCTFail("`status --jsonn` must be rejected; parsed as \(command)")
    }
  }
}
