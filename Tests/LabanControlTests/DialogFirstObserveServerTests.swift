import LabanCore
import XCTest

@testable import LabanControl

/// Milestone 1 of the dialog-first design
/// (`execplans/active/dialog-first-session-observe.md`): the family-scoped
/// session-observe grant. One approval authorizes the whole own-session read
/// family for the approved session, without request-exact binding, while the
/// ceiling (no actuation, no clipboard, no fixture, no cross-session) still
/// holds. These drive `LabanControlPolicy.authorize` directly with a
/// `.approvedSessionFamily` tier, exactly as the invariant suite drives the
/// other tiers.
final class DialogFirstObserveServerTests: XCTestCase {
  private func familyTier(session: String) -> ControlTokenTier {
    .approvedSessionFamily(
      sessionID: session,
      approvalID: "approval-1",
      capabilities: Array(ControlSessionObserveFamily.capabilities))
  }

  private func authorize(
    _ intentID: String,
    tier: ControlTokenTier,
    targetSession: String?
  ) -> Bool {
    LabanControlPolicy.authorize(
      intentID: intentID,
      catalog: .all,
      granted: LabanControlPolicy.grants(for: tier),
      targetSession: targetSession,
      tokenScope: LabanControlPolicy.tokenScope(for: tier),
      tokenTier: tier,
      // Deliberately mismatched request fields: a family grant must NOT bind
      // on method/path/body, so authorization must not depend on them.
      method: "GET",
      path: "/irrelevant",
      query: "",
      bodySHA256: nil)
  }

  func testFamilyGrantAuthorizesEveryFamilyIntentForItsSession() {
    let tier = familyTier(session: "s1")
    for intentID in ControlSessionObserveFamily.intentIDs {
      // Explicit own-session target and omitted target (resolves to own) both
      // authorize, for every family member, with no request-exact binding.
      XCTAssertTrue(
        authorize(intentID, tier: tier, targetSession: "s1"),
        "family grant must authorize \(intentID) for its own session")
      XCTAssertTrue(
        authorize(intentID, tier: tier, targetSession: nil),
        "family grant must authorize \(intentID) with an omitted (own) target")
    }
  }

  func testFamilyGrantDeniesEveryFamilyIntentForAnotherSession() {
    let tier = familyTier(session: "s1")
    for intentID in ControlSessionObserveFamily.intentIDs {
      XCTAssertFalse(
        authorize(intentID, tier: tier, targetSession: "s2"),
        "family grant must deny \(intentID) for a different session (C12)")
    }
  }

  func testFamilyGrantDeniesActuationClipboardAndFixtureIntents() {
    let tier = familyTier(session: "s1")
    // Representative non-family intents from each forbidden class. Each exists
    // in the catalog but is outside the family and requires a capability the
    // family grant never holds.
    let forbidden = [
      "terminal.typeText",  // .input actuation
      "terminal.sendKey",  // .input actuation
      "clipboard.paste",  // .input actuation on clipboard family
      "clipboard.read",  // .observeSensitive clipboard content
      "fixture.feedOutput",  // .fixture
    ]
    for intentID in forbidden {
      guard IntentCatalog.all.descriptor(id: intentID) != nil else { continue }
      XCTAssertFalse(
        ControlSessionObserveFamily.contains(intentID),
        "\(intentID) must not be a family member")
      XCTAssertFalse(
        authorize(intentID, tier: tier, targetSession: "s1"),
        "family grant must deny \(intentID) even for its own session")
    }
  }

  func testFamilyCapabilitySetNeverIncludesInputClipboardOrFixture() {
    let caps = ControlSessionObserveFamily.capabilities
    XCTAssertFalse(caps.contains(.input), "family ceiling must never grant .input")
    XCTAssertFalse(caps.contains(.clipboard), "family ceiling must never grant .clipboard")
    XCTAssertFalse(caps.contains(.fixture), "family ceiling must never grant .fixture")
    XCTAssertEqual(
      caps, [.observe, .observeSensitive, .navigate, .propose],
      "family ceiling is exactly the observe/navigate/propose set")
  }

  func testEveryFamilyIntentIsGuiReadOrProposeInTheCatalog() {
    for intentID in ControlSessionObserveFamily.intentIDs {
      guard let descriptor = IntentCatalog.all.descriptor(id: intentID) else {
        XCTFail("family intent \(intentID) has no catalog descriptor")
        continue
      }
      XCTAssertFalse(
        descriptor.sideEffects.ptyInput,
        "family intent \(intentID) must not write PTY input")
      XCTAssertTrue(
        ControlSessionObserveFamily.capabilities.contains(descriptor.requiredCapability),
        "family intent \(intentID) requires \(descriptor.requiredCapability), outside the ceiling")
    }
  }

  func testRequestExactApprovedSessionStillBindsToOneRequest() {
    // Regression: the family grant must not have weakened the existing
    // one-shot .approvedSession request-exact binding.
    let tier = ControlTokenTier.approvedSession(
      sessionID: "s1",
      approvalID: "a1",
      capabilities: [.observeSensitive],
      constraint: ControlTokenConstraint(
        method: "GET",
        path: "/debug/state",
        query: "",
        bodySHA256: nil,
        resolvedRouteID: "GET /debug/state",
        resolvedIntentID: "app.state"))

    // Exact match authorizes.
    XCTAssertTrue(
      LabanControlPolicy.authorize(
        intentID: "app.state", catalog: .all,
        granted: LabanControlPolicy.grants(for: tier),
        targetSession: "s1", tokenScope: LabanControlPolicy.tokenScope(for: tier),
        tokenTier: tier, method: "GET", path: "/debug/state", query: "", bodySHA256: nil))
    // A different intent under the same constraint is denied (still request-exact).
    XCTAssertFalse(
      LabanControlPolicy.authorize(
        intentID: "session.detail", catalog: .all,
        granted: LabanControlPolicy.grants(for: tier),
        targetSession: "s1", tokenScope: LabanControlPolicy.tokenScope(for: tier),
        tokenTier: tier, method: "GET", path: "/debug/state", query: "", bodySHA256: nil))
  }
}
