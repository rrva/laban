import XCTest

@testable import LabanCore

final class TerminalURLCommandTests: XCTestCase {
  private func argv(_ string: String) -> [String]? {
    guard let url = URL(string: string) else { return nil }
    return TerminalURLCommand.argv(for: url)
  }

  func testSSHHostOnly() {
    XCTAssertEqual(argv("ssh://example.com"), ["ssh", "example.com"])
  }

  func testSSHUserAndHost() {
    XCTAssertEqual(argv("ssh://alice@example.com"), ["ssh", "alice@example.com"])
  }

  func testSSHUserHostPort() {
    XCTAssertEqual(
      argv("ssh://alice@example.com:2222"), ["ssh", "-p", "2222", "alice@example.com"])
  }

  func testTelnetHostOnly() {
    XCTAssertEqual(argv("telnet://example.com"), ["telnet", "example.com"])
  }

  func testTelnetHostPort() {
    XCTAssertEqual(argv("telnet://example.com:23"), ["telnet", "example.com", "23"])
  }

  func testUnsupportedSchemeReturnsNil() {
    XCTAssertNil(argv("https://example.com"))
  }

  func testMissingHostReturnsNil() {
    XCTAssertNil(argv("ssh://"))
  }

  func testOptionInjectionHostRejected() {
    XCTAssertNil(argv("ssh://-evil.example.com"))
  }

  func testOptionInjectionUserRejected() {
    XCTAssertNil(argv("ssh://-flag@example.com"))
  }
}
