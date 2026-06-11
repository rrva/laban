import Foundation
import XCTest

@testable import LabanCore

final class TerminalIdentitySettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-identity-tests"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultIdentityIsLaban() {
    XCTAssertEqual(TerminalIdentitySettings.identity(defaults: defaults), .laban)
  }

  func testGarbageValueFallsBackToLaban() {
    defaults.set("warp", forKey: TerminalIdentitySettings.defaultsKey)
    XCTAssertEqual(TerminalIdentitySettings.identity(defaults: defaults), .laban)
  }

  func testRoundTrip() {
    TerminalIdentitySettings.set(.ghosttyCompat, defaults: defaults)
    XCTAssertEqual(TerminalIdentitySettings.identity(defaults: defaults), .ghosttyCompat)
    TerminalIdentitySettings.set(.laban, defaults: defaults)
    XCTAssertEqual(TerminalIdentitySettings.identity(defaults: defaults), .laban)
  }

  func testGhosttyCompatAdvertisesPinnedVersion() {
    let env = TerminalIdentity.ghosttyCompat.environmentOverrides
    XCTAssertEqual(env["TERM_PROGRAM"], "ghostty")
    XCTAssertEqual(env["TERM_PROGRAM_VERSION"], "1.3.1")
  }

  func testLabanIdentityCarriesAVersion() {
    let env = TerminalIdentity.laban.environmentOverrides
    XCTAssertEqual(env["TERM_PROGRAM"], "Laban")
    XCTAssertEqual(env["TERM_PROGRAM_VERSION"]?.isEmpty, false)
  }

  func testIdentityMergeLosesToExplicitLaunchOverrides() {
    let launch = ShellIntegrationLaunch(
      environmentOverrides: ["TERM_PROGRAM": "custom", "ZDOTDIR": "/x"])
    let merged = launch.withTerminalIdentity(.laban)
    XCTAssertEqual(merged.environmentOverrides["TERM_PROGRAM"], "custom")
    XCTAssertEqual(merged.environmentOverrides["ZDOTDIR"], "/x")
    XCTAssertEqual(
      merged.environmentOverrides["TERM_PROGRAM_VERSION"],
      TerminalIdentitySettings.labanVersion)
  }
}
