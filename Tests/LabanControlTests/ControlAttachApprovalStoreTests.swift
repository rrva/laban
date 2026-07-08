import Foundation
import LabanControl
import LabanCore
import XCTest

final class ControlAttachApprovalStoreTests: XCTestCase {

  func testAddAndRevoke() {
    let defaults = UserDefaults(suiteName: "test-laban-approval-store")!
    defer { defaults.removeSuite(named: "test-laban-approval-store") }
    let store = ControlAttachApprovalStore(defaults: defaults)

    let record = makeRecord(id: "r1", displayName: "Codex", sessionID: "s1")
    store.add(record)
    XCTAssertEqual(store.loadAll().count, 1)

    store.revoke(id: "r1")
    XCTAssertTrue(store.loadAll().first?.isRevoked == true)
  }

  func testFindMatchingRequiresSessionAndShell() {
    let defaults = UserDefaults(suiteName: "test-laban-approval-store")!
    defer { defaults.removeSuite(named: "test-laban-approval-store") }
    let store = ControlAttachApprovalStore(defaults: defaults)

    let record = makeRecord(
      id: "r1",
      displayName: "Codex",
      sessionID: "s1",
      shellIdentityFingerprint: "fingerprint-a",
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"])
    store.add(record)

    let principal = makePrincipal(path: "/Applications/Codex.app/Contents/MacOS/Codex")
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "fingerprint-a",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertEqual(match?.id, "r1")

    let noMatch = store.findMatching(
      principal: principal,
      sessionID: "s2",
      shellIdentityFingerprint: "fingerprint-a",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertNil(noMatch)
  }

  func testFindMatchingRejectsDifferentRouteOrIntent() {
    let defaults = UserDefaults(suiteName: "test-laban-approval-store")!
    defer { defaults.removeSuite(named: "test-laban-approval-store") }
    let store = ControlAttachApprovalStore(defaults: defaults)

    let record = makeRecord(
      id: "r1",
      displayName: "Codex",
      allowedRouteIDs: ["GET /debug/state"],
      allowedIntentIDs: ["app.state"],
      maxDataSensitivity: "nonSensitiveState",
      allowedSideEffectClasses: ["read"])
    store.add(record)

    let principal = makePrincipal()
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "f1",
      routeID: "POST /debug/actions",
      intentID: "command.propose",
      capabilities: Set([.propose]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "write")
    XCTAssertNil(match)
  }

  func testRevokedRecordNotAutoApproved() {
    let defaults = UserDefaults(suiteName: "test-laban-approval-store")!
    defer { defaults.removeSuite(named: "test-laban-approval-store") }
    let store = ControlAttachApprovalStore(defaults: defaults)

    let record = makeRecord(id: "r1", displayName: "Codex")
    store.add(record)
    store.revoke(id: "r1")

    let principal = makePrincipal()
    let match = store.findMatching(
      principal: principal,
      sessionID: "s1",
      shellIdentityFingerprint: "f1",
      routeID: "GET /debug/state",
      intentID: "app.state",
      capabilities: Set([.observe]),
      dataSensitivity: "nonSensitiveState",
      sideEffectClass: "read")
    XCTAssertNil(match)
  }

  // MARK: - Helpers

  private func makeRecord(
    id: String,
    displayName: String,
    sessionID: String = "s1",
    shellIdentityFingerprint: String = "f1",
    allowedRouteIDs: [String] = ["GET /debug/state"],
    allowedIntentIDs: [String] = ["app.state"],
    capabilities: [Capability] = [.observe],
    maxDataSensitivity: String = "nonSensitiveState",
    allowedSideEffectClasses: [String] = ["read"]
  ) -> ControlAttachApprovalRecord {
    ControlAttachApprovalRecord(
      id: id,
      displayName: displayName,
      signing: ControlCodeSigningIdentity(
        designatedRequirement: "req",
        isAdHocOrUnsigned: false),
      sessionID: sessionID,
      shellIdentityFingerprint: shellIdentityFingerprint,
      allowedRouteIDs: allowedRouteIDs,
      allowedIntentIDs: allowedIntentIDs,
      capabilities: capabilities,
      maxDataSensitivity: maxDataSensitivity,
      allowedSideEffectClasses: allowedSideEffectClasses)
  }

  private func makePrincipal(path: String = "/Applications/Codex.app/Contents/MacOS/Codex")
    -> ControlAttachPrincipal
  {
    ControlAttachPrincipal(
      identity: ControlProcessIdentity(
        pid: 100,
        parentPID: nil,
        startTime: Date(),
        uid: 0,
        executablePath: path,
        arguments: [],
        signing: ControlCodeSigningIdentity(
          designatedRequirement: "req",
          isAdHocOrUnsigned: false)),
      isGenericInterpreter: false,
      isPersistable: true,
      helperChain: [])
  }
}
