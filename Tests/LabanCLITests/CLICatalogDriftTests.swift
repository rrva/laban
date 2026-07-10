import Foundation
import LabanCore
import XCTest

@testable import LabanCLI

/// Proves the CLI command surface and `IntentCatalog` stay in sync. The CLI is
/// handwritten for ergonomic command grouping (`session ...`, `wait ...`)
/// rather than generated 1:1 from the catalog, so this test is the parity
/// mechanism the Decision Log in
/// `execplans/active/agent-control-production-broker-and-cli.md` calls for:
/// every catalog-backed command must name a real intent id, and every
/// `LabanCommand` case must appear in the mapping table at all.
final class CLICatalogDriftTests: XCTestCase {
  func testEveryCommandCaseHasAMappingEntry() {
    for command in LabanCLICatalog.oneOfEachCommand {
      let label = LabanCLICatalog.label(for: command)
      XCTAssertNotNil(
        LabanCLICatalog.commandBacking[label],
        "LabanCommand case '\(label)' has no entry in LabanCLICatalog.commandBacking")
    }
    XCTAssertEqual(
      LabanCLICatalog.oneOfEachCommand.count, LabanCLICatalog.commandBacking.count,
      "oneOfEachCommand and commandBacking have drifted apart; a case was added to one "
        + "but not the other")
  }

  func testEveryCatalogBackedCommandNamesARealIntentID() {
    let catalogIDs = IntentCatalog.all.ids
    for (label, backing) in LabanCLICatalog.commandBacking {
      switch backing {
      case .intent(let id):
        XCTAssertTrue(
          catalogIDs.contains(id),
          "command '\(label)' names catalog intent '\(id)', which does not exist in "
            + "IntentCatalog.all")
      case .intents(let ids):
        for id in ids {
          XCTAssertTrue(
            catalogIDs.contains(id),
            "command '\(label)' names catalog intent '\(id)', which does not exist in "
              + "IntentCatalog.all")
        }
      case .rawEscape, .clientOnly:
        continue
      }
    }
  }

  func testTerminalGetTextRemainsBrokerOnlyAndOutOfLazyAttachAllowlist() {
    // terminal.getText is dataSensitivity .scrollback; the Milestone 2c
    // decision log requires it stay broker-path only, never reachable
    // through the one-shot lazy-attach approval path. This mirrors invariant
    // I4 in ControlPlaneInvariantTests.swift from the CLI side, so a future
    // CLI change that starts routing session get-text through
    // performSessionRequest (the dual-path helper with lazy-attach fallback)
    // fails here instead of silently loosening the sensitivity boundary.
    guard let descriptor = IntentCatalog.all.descriptor(id: "terminal.getText") else {
      XCTFail("terminal.getText intent is missing from IntentCatalog.all")
      return
    }
    XCTAssertEqual(descriptor.dataSensitivity, .scrollback)
  }
}
