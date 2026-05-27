import AppKit
import LabanCore
import XCTest

@testable import LabanApp

final class TerminalBackendSettingsTests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testCommandLineBackendOverridesEnvironmentAndDefaults() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.laband, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: ["LABAN_TERMINAL_BACKEND": "laband"],
      arguments: ["LabanApp", "--local-sessions"],
      defaults: defaults,
      automaticBackend: .laband)

    XCTAssertEqual(resolved.backend, .inProcess)
    XCTAssertEqual(resolved.source, .commandLine)
  }

  func testCommandLineBackendAcceptsEqualsFormAndAliases() throws {
    let defaults = try makeDefaults()

    let local = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--terminal-backend=local"],
      defaults: defaults,
      automaticBackend: .laband)
    XCTAssertEqual(local.backend, .inProcess)

    let background = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--terminal-backend", "background"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(background.backend, .labpty)

    let backgroundAlias = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--background-sessions"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(backgroundAlias.backend, .labpty)

    let detached = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--terminal-backend", "detached"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(detached.backend, .laband)

    let detachedAlias = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--detached-sessions"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(detachedAlias.backend, .laband)
  }

  func testEnvironmentBackendOverridesPersistedDefault() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.inProcess, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: ["LABAN_TERMINAL_BACKEND": "background"],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .inProcess)

    XCTAssertEqual(resolved.backend, .labpty)
    XCTAssertEqual(resolved.source, .environment)
  }

  func testPersistedBackendOverridesAutomaticDefault() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.laband, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .inProcess)

    XCTAssertEqual(resolved.backend, .laband)
    XCTAssertEqual(resolved.source, .userDefault)
  }

  func testMissingSettingUsesAutomaticBackend() throws {
    let defaults = try makeDefaults()

    let resolved = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .labpty)

    XCTAssertEqual(resolved.backend, .labpty)
    XCTAssertEqual(resolved.source, .automatic)
  }

  func testLegacyDisableFlagForcesLocalSessions() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.laband, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: ["LABAN_DISABLE_PRODUCT_LABAND": "1"],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .laband)

    XCTAssertEqual(resolved.backend, .inProcess)
    XCTAssertEqual(resolved.source, .legacyDisableFlag)
  }

  func testMenuSelectionPersistsBackendAndPromptsForRestart() throws {
    let defaults = try makeDefaults()
    var promptedSelected: TerminalSessionBackend?
    var promptedActive: TerminalSessionBackend?
    var promptedSource: TerminalBackendLaunchSource?
    let controller = TerminalBackendMenuController(defaults: defaults) {
      selected, active, source in
      promptedSelected = selected
      promptedActive = active
      promptedSource = source
    }
    controller.configure(activeBackend: .inProcess, launchSource: .automatic)

    let item = controller.makeMenuItem()
    let submenu = try XCTUnwrap(item.submenu)
    XCTAssertEqual(submenu.items[0].title, "Local Sessions")
    XCTAssertEqual(submenu.items[1].title, "Background Sessions")
    XCTAssertEqual(submenu.items[2].title, "Detached Sessions")
    XCTAssertEqual(submenu.items[0].state, .on)
    XCTAssertEqual(submenu.items[1].state, .off)
    XCTAssertEqual(submenu.items[2].state, .off)

    controller.selectBackground(nil)

    XCTAssertEqual(TerminalBackendSettings.persisted(defaults: defaults), .labpty)
    XCTAssertEqual(submenu.items[0].state, .off)
    XCTAssertEqual(submenu.items[1].state, .on)
    XCTAssertEqual(submenu.items[2].state, .off)
    XCTAssertEqual(promptedSelected, .labpty)
    XCTAssertEqual(promptedActive, .inProcess)
    XCTAssertEqual(promptedSource, .automatic)

    controller.selectDetached(nil)

    XCTAssertEqual(TerminalBackendSettings.persisted(defaults: defaults), .laband)
    XCTAssertEqual(submenu.items[0].state, .off)
    XCTAssertEqual(submenu.items[1].state, .off)
    XCTAssertEqual(submenu.items[2].state, .on)
    XCTAssertEqual(promptedSelected, .laband)
    XCTAssertEqual(promptedActive, .inProcess)
    XCTAssertEqual(promptedSource, .automatic)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "TerminalBackendSettingsTests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
