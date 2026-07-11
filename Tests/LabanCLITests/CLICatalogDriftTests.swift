import Foundation
import LabanControl
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

  func testTerminalGetTextIsInTheDialogFirstFamilyAndStaysScrollbackSensitivity() {
    // Reversal of the old "stays broker-only" contract, deliberately: per
    // execplans/active/dialog-first-session-observe.md (Milestone 1, the
    // I4 rewrite in Milestone 4), terminal.getText is now a lazy-attach
    // family member so `session get-text` can reach the approval dialog
    // without a broker. What must never move is the sensitivity
    // classification and family membership itself: a regression that drops
    // terminal.getText from the family, or reclassifies its data
    // sensitivity, would silently widen or narrow the dialog-first surface
    // without anyone noticing. This test is the CLI-side half of that
    // ceiling check (the server-side half is
    // ControlPlaneInvariantTests.swift's rewritten I4).
    XCTAssertTrue(
      ControlSessionObserveFamily.contains("terminal.getText"),
      "terminal.getText must stay a member of the own-session read family")
    guard let descriptor = IntentCatalog.all.descriptor(id: "terminal.getText") else {
      XCTFail("terminal.getText intent is missing from IntentCatalog.all")
      return
    }
    XCTAssertEqual(descriptor.dataSensitivity, .scrollback)
  }
}
