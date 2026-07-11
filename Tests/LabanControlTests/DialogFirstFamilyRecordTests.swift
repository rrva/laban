import Foundation
import LabanCore
import XCTest

@testable import LabanControl

/// Milestone 2 of the dialog-first design
/// (`execplans/active/dialog-first-session-observe.md`): a persisted
/// "Always Allow" record is family-wide, not one-request-wide. One approval
/// auto-approves ANY later family read for the same (principal, session),
/// via `ControlAttachApprovalStore.findMatching`, exactly as
/// `LabanControlServerLazyAttach` now constructs the record (family route
/// set, family intent set, family capabilities, ordering-max sensitivity,
/// family side-effect-class union).
///
/// Reuses the `ControlAttachApprovalStoreTests` pattern: drive the store
/// directly with a hand-built signed principal/record, no server/router
/// scaffolding needed.
final class DialogFirstFamilyRecordTests: XCTestCase {

  private let signer = ControlAttachApprovalRecordHMACSigner(key: Data("test-approval-key".utf8))

  /// NOTE 3 (the ordering trap, fails closed): `app.state` is
  /// `.sensitivePrivate`, which ranks ABOVE `.scrollback` in
  /// `compareSensitivity`. The family's stored ceiling must be the
  /// ordering-max across the family (sensitivePrivate), never a single
  /// member's own tier label, or a scrollback read would be rejected by a
  /// record that stored "scrollback" as its max.
  func testMaxDataSensitivityIsTheOrderingMaximumAcrossTheFamily() {
    let max = ControlSessionObserveFamily.maxDataSensitivity(catalog: .all)
    XCTAssertEqual(max, "sensitivePrivate")
    XCTAssertTrue(
      "scrollback".compareSensitivity(to: max),
      "a scrollback read must be covered by the family's stored ceiling")
  }

  /// A family record, once stored, auto-approves every family intent for the
  /// same (principal, session), not just the intent that was first approved.
  func testFamilyRecordAutoApprovesEveryFamilyIntentForSameSessionAndPrincipal() {
    let (_, store) = makeStore()
    let principal = makePrincipal()
    store.add(makeFamilyRecord(id: "r1", principal: principal, sessionID: "s1"))

    for intentID in ["terminal.getText", "session.detail", "terminal.scrollViewport"] {
      let routeID = familyRouteID(for: intentID, sessionID: "s1")
      let match = store.findMatching(
        principal: principal,
        sessionID: "s1",
        shellIdentityFingerprint: "shell-1",
        routeID: routeID,
        intentID: intentID,
        capabilities: Set([capability(for: intentID)]),
        dataSensitivity: dataSensitivity(for: intentID),
        sideEffectClass: "none")
      XCTAssertEqual(
        match?.id, "r1",
        "a family record must auto-approve \(intentID) for the same (principal, session)")
    }
  }

  func testFamilyRecordDoesNotAutoApproveForADifferentSession() {
    let (_, store) = makeStore()
    let principal = makePrincipal()
    store.add(makeFamilyRecord(id: "r1", principal: principal, sessionID: "s1"))

    let match = store.findMatching(
      principal: principal,
      sessionID: "s2",
      shellIdentityFingerprint: "shell-1",
      routeID: familyRouteID(for: "terminal.getText", sessionID: "s2"),
      intentID: "terminal.getText",
      capabilities: Set([.observeSensitive]),
      dataSensitivity: "scrollback",
      sideEffectClass: "none")
    XCTAssertNil(match, "a different session must re-prompt, never auto-approve")
  }

  func testFamilyRecordDoesNotAutoApproveForAMismatchedPrincipalFingerprint() {
    let (_, store) = makeStore()
    let principal = makePrincipal()
    store.add(makeFamilyRecord(id: "r1", principal: principal, sessionID: "s1"))

    // `stablePrincipalFingerprint` is derived from `signing.designatedRequirement`
    // (falling back to executablePath), not the executable path alone, so a
    // genuinely different principal needs a different designated requirement.
    let otherPrincipal = makePrincipal(designatedRequirement: "different-req")
    let match = store.findMatching(
      principal: otherPrincipal,
      sessionID: "s1",
      shellIdentityFingerprint: "shell-1",
      routeID: familyRouteID(for: "terminal.getText", sessionID: "s1"),
      intentID: "terminal.getText",
      capabilities: Set([.observeSensitive]),
      dataSensitivity: "scrollback",
      sideEffectClass: "none")
    XCTAssertNil(match, "a different principal must re-prompt, never auto-approve")
  }

  func testFamilyRecordDoesNotAutoApproveForAMismatchedSigningRequirement() {
    let (_, store) = makeStore()
    let principal = makePrincipal()
    var record = makeFamilyRecord(id: "r1", principal: principal, sessionID: "s1")
    record.signingRequirement = "different-requirement"
    store.add(record)

    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "shell-1",
      routeID: familyRouteID(for: "terminal.getText", sessionID: "s1"),
      intentID: "terminal.getText",
      capabilities: Set([.observeSensitive]),
      dataSensitivity: "scrollback",
      sideEffectClass: "none")
    XCTAssertNil(match, "a mismatched signing requirement must re-prompt, never auto-approve")
  }

  // MARK: - Helpers

  private func makeStore() -> (UserDefaults, ControlAttachApprovalStore) {
    let suiteName = "test-laban-family-approval-store-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return (defaults, ControlAttachApprovalStore(defaults: defaults, signer: signer))
  }

  private func makePrincipal(
    path: String = "/Applications/Codex.app/Contents/MacOS/Codex",
    designatedRequirement: String = "req"
  ) -> ControlAttachPrincipal {
    ControlAttachPrincipal(
      identity: ControlProcessIdentity(
        pid: 100,
        parentPID: nil,
        startTime: Date(timeIntervalSince1970: 0),
        uid: 0,
        executablePath: path,
        arguments: [],
        signing: ControlCodeSigningIdentity(
          designatedRequirement: designatedRequirement,
          isAdHocOrUnsigned: false)),
      isGenericInterpreter: false,
      isPersistable: true,
      helperChain: [])
  }

  /// Mirrors the family record `LabanControlServerLazyAttach` now persists on
  /// "Always Allow": every field is the family-wide value, not one request's.
  private func makeFamilyRecord(
    id: String,
    principal: ControlAttachPrincipal,
    sessionID: String
  ) -> ControlAttachApprovalRecord {
    ControlAttachApprovalRecord(
      id: id,
      displayName: "Codex",
      signing: ControlCodeSigningIdentity(
        designatedRequirement: "req",
        isAdHocOrUnsigned: false),
      signingRequirement: "req",
      sessionID: sessionID,
      shellIdentityFingerprint: "shell-1",
      allowedRouteIDs: Array(
        Set(
          ControlLazyAttachAllowlist.entries.map {
            $0.routeID.replacingOccurrences(of: "<id>", with: sessionID)
          })
      ).sorted(),
      allowedIntentIDs: Array(ControlSessionObserveFamily.intentIDs),
      capabilities: Array(ControlSessionObserveFamily.capabilities),
      maxDataSensitivity: ControlSessionObserveFamily.maxDataSensitivity(catalog: .all),
      allowedSideEffectClasses: ["none"],
      principalIdentityFingerprint: principal.identity.stablePrincipalFingerprint)
  }

  private func familyRouteID(for intentID: String, sessionID: String) -> String {
    guard let entry = ControlLazyAttachAllowlist.entry(method: "", path: "", intentID: intentID)
    else {
      XCTFail("no allowlist entry for \(intentID)")
      return ""
    }
    return entry.routeID.replacingOccurrences(of: "<id>", with: sessionID)
  }

  private func capability(for intentID: String) -> Capability {
    guard let descriptor = IntentCatalog.all.descriptor(id: intentID) else {
      XCTFail("no catalog descriptor for \(intentID)")
      return .observe
    }
    return descriptor.requiredCapability
  }

  private func dataSensitivity(for intentID: String) -> String {
    guard let descriptor = IntentCatalog.all.descriptor(id: intentID) else {
      XCTFail("no catalog descriptor for \(intentID)")
      return "none"
    }
    return descriptor.dataSensitivity.rawValue
  }
}
