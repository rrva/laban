import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class SessionModePersistenceTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testPersistedBackgroundModeOverridesAutomaticLocalFallback() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.labpty, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .inProcess)

    XCTAssertEqual(resolved.backend, .labpty)
    XCTAssertEqual(resolved.source, .userDefault)
  }

  func testPersistedLabandSelectionRemainsDetachedMode() throws {
    let defaults = try makeDefaults()
    defaults.set("laband", forKey: TerminalBackendSettings.defaultsKey)

    let resolved = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .labpty)

    XCTAssertEqual(resolved.backend, .laband)
    XCTAssertEqual(resolved.source, .userDefault)
    XCTAssertEqual(TerminalBackendSettings.persisted(defaults: defaults), .laband)
  }

  func testAutomaticModeDefaultsToBackgroundWhenProvidedByApp() throws {
    let defaults = try makeDefaults()

    let resolved = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .labpty)

    XCTAssertEqual(resolved.backend, .labpty)
    XCTAssertEqual(resolved.source, .automatic)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "SessionModePersistenceTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
