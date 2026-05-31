import AppKit
import Foundation
import LabanCore
import XCTest

@testable import LabanApp

final class SessionModeCLITests: XCTestCase {
  private var suiteNames: [String] = []

  override func tearDown() {
    for suiteName in suiteNames {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    suiteNames = []
    super.tearDown()
  }

  func testPrecedenceChainEndsWithCommandLine() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.laband, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: ["LABAN_TERMINAL_BACKEND": "background"],
      arguments: ["LabanApp", "--local-sessions"],
      defaults: defaults,
      automaticBackend: .labpty)

    XCTAssertEqual(resolved.backend, .inProcess)
    XCTAssertEqual(resolved.source, .commandLine)
  }

  func testEnvironmentOverridesLegacyDisableAndPersistedDefault() throws {
    let defaults = try makeDefaults()
    TerminalBackendSettings.set(.laband, defaults: defaults)

    let resolved = try TerminalBackendSettings.resolve(
      environment: [
        "LABAN_DISABLE_PRODUCT_LABAND": "1",
        "LABAN_TERMINAL_BACKEND": "background",
      ],
      arguments: ["LabanApp"],
      defaults: defaults,
      automaticBackend: .inProcess)

    XCTAssertEqual(resolved.backend, .labpty)
    XCTAssertEqual(resolved.source, .environment)
  }

  func testShortcutFlagsRouteToThreeModes() throws {
    let defaults = try makeDefaults()

    let local = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--local-sessions"],
      defaults: defaults,
      automaticBackend: .labpty)
    XCTAssertEqual(local.backend, .inProcess)

    let background = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--background-sessions"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(background.backend, .labpty)

    let detached = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--detached-sessions"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(detached.backend, .laband)

    let compatibility = try TerminalBackendSettings.resolve(
      environment: [:],
      arguments: ["LabanApp", "--laband-sessions"],
      defaults: defaults,
      automaticBackend: .inProcess)
    XCTAssertEqual(compatibility.backend, .laband)
  }

  func testInvalidBackendNamesAcceptedValues() throws {
    XCTAssertThrowsError(try TerminalSessionBackend.parse("invalidvalue")) { error in
      let text = String(describing: error)
      XCTAssertTrue(text.contains("accepted values"), text)
      XCTAssertTrue(text.contains("in-process"), text)
      XCTAssertTrue(text.contains("labpty"), text)
      XCTAssertTrue(text.contains("laband"), text)
      XCTAssertTrue(text.contains("background"), text)
      XCTAssertTrue(text.contains("detached"), text)
    }
  }

  func testMenuSelectionPersistsBackgroundAndDetachedModes() throws {
    let defaults = try makeDefaults()
    var promptedSelected: TerminalSessionBackend?
    let controller = TerminalBackendMenuController(defaults: defaults) {
      selected, _, _ in
      promptedSelected = selected
    }
    controller.configure(activeBackend: .labpty, launchSource: .automatic)

    let parent = controller.makeMenuItem()
    let submenu = try XCTUnwrap(parent.submenu)
    XCTAssertEqual(
      submenu.items.map(\.title),
      [
        "Local Sessions",
        "Background Sessions",
        "Detached Sessions",
      ])
    XCTAssertEqual(submenu.items[1].state, .on)

    controller.selectDetached(nil)
    XCTAssertEqual(TerminalBackendSettings.persisted(defaults: defaults), .laband)
    XCTAssertEqual(promptedSelected, .laband)
    XCTAssertEqual(submenu.items[2].state, .on)

    controller.selectBackground(nil)
    XCTAssertEqual(TerminalBackendSettings.persisted(defaults: defaults), .labpty)
    XCTAssertEqual(promptedSelected, .laband)
    XCTAssertEqual(submenu.items[1].state, .on)
  }

  private func makeDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UserDefaults {
    let suiteName = "SessionModeCLITests-\(UUID().uuidString)"
    suiteNames.append(suiteName)
    return try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
  }
}
