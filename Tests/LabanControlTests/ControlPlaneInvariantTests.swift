import Foundation
import LabanControl
import LabanCore
import XCTest

@testable import LabanControl

/// One suite a security reviewer checks: each test proves an invariant from
/// `docs/process/control-plane-threat-model.md` (I1-I7) that must hold across
/// all three control-plane trust derivations (C14 direct attach, broker
/// process tree, lazy approval principal) at once. A change that adds a
/// route, token tier, capability, or allowlist entry must keep this suite
/// green; see that document's "Rules for changes" section.
///
/// I6 (`testNoBearerTokenEnvironmentKeysInChildEnvBuilder`) lives in
/// `Tests/LabanAgentTests/ControlPlaneInvariantEnvTests.swift` instead of
/// here: the child-environment builder (`ChildLauncher`) is defined in the
/// `LabanAgent` module, and `LabanControlTests` only depends on
/// `LabanControl`/`LabanCore` (see `Package.swift`), so it cannot
/// `@testable import LabanAgent`. That file documents the same deviation.
///
/// The `Fake*`/`Invariant*` fixtures below are this file's own private
/// copies of the process-tree/signing/delegate fixture pattern established
/// in `ControlAttachPrincipalTests.swift` and `LazyAttachPrincipalPersistenceTests.swift`.
/// They are intentionally not shared across files (each of those files
/// already declares its own `private` fixtures of the same shape, and
/// widening them to file-shared visibility collided with other tests'
/// same-named fixtures elsewhere in this target).
final class ControlPlaneInvariantTests: XCTestCase {

  // MARK: - I1: No live tier can actuate.

  func testNoLiveTierGrantsInputOrClipboard() {
    let actuationCapabilities: Set<Capability> = [.input, .clipboard]

    // The two tiers the server grants automatically (never caller-supplied)
    // must never include an actuation capability.
    XCTAssertTrue(
      LabanControlPolicy.grants(for: .appObserve).isDisjoint(with: actuationCapabilities))
    XCTAssertTrue(
      LabanControlPolicy.grants(for: .sessionObserve(sessionID: "s1"))
        .isDisjoint(with: actuationCapabilities))

    // `.fixture` is a deliberate exception: it is the headless-fixture-runtime
    // token, never reachable on the live GUI/production surface, so it is not
    // part of "no live tier" and is allowed to grant `.input` for fixture
    // injection tests.

    // Every entry in the lazy allowlist (the only way an `approvedSession`
    // token gets minted) must resolve to a catalog descriptor whose required
    // capability is one of the non-actuating capabilities. This is the
    // "asserted at the minting path" half of I1: the allowlist itself can
    // never point at an actuation capability, regardless of what the
    // `ControlTokenTier.approvedSession` enum case could structurally hold.
    let nonActuatingCapabilities: Set<Capability> = [
      .observe, .observeSensitive, .navigate, .propose,
    ]
    for entry in ControlLazyAttachAllowlist.entries {
      guard let descriptor = IntentCatalog.all.descriptor(id: entry.intentID) else {
        XCTFail("lazy allowlist entry \(entry.cliCommand) has no catalog descriptor")
        continue
      }
      XCTAssertTrue(
        nonActuatingCapabilities.contains(descriptor.requiredCapability),
        "\(entry.cliCommand) resolves to \(descriptor.requiredCapability), which is not a "
          + "permitted lazy-allowlist capability")
      XCTAssertFalse(actuationCapabilities.contains(descriptor.requiredCapability))
    }
  }

  func testLazyMintingCannotProduceActuationCapabilities() {
    // Mirror exactly what the lazy-attach minting path does: it builds an
    // `approvedSession` tier whose `capabilities` array is
    // `[descriptor.requiredCapability]` for the resolved intent. Prove that
    // for every allowlisted entry, the resulting granted set is exactly that
    // one capability (no widening) and never contains `.input`/`.clipboard`.
    for entry in ControlLazyAttachAllowlist.entries {
      guard let descriptor = IntentCatalog.all.descriptor(id: entry.intentID) else {
        XCTFail("lazy allowlist entry \(entry.cliCommand) has no catalog descriptor")
        continue
      }
      let mintedTier = ControlTokenTier.approvedSession(
        sessionID: "s1",
        approvalID: "a1",
        capabilities: [descriptor.requiredCapability],
        constraint: ControlTokenConstraint(
          method: entry.method,
          path: entry.path,
          query: "",
          bodySHA256: nil,
          resolvedRouteID: entry.routeID,
          resolvedIntentID: entry.intentID))
      let granted = LabanControlPolicy.grants(for: mintedTier)
      XCTAssertEqual(granted, [descriptor.requiredCapability])
      XCTAssertFalse(granted.contains(.input))
      XCTAssertFalse(granted.contains(.clipboard))
    }
  }

  // MARK: - I2: Session scope holds on every path (contract C12).

  func testSessionScopeDeniesCrossSessionOnAllTiers() {
    // One descriptor per privileged capability, matching an IntentCatalog id.
    let cases: [(intentID: String, capability: Capability)] = [
      ("app.state", .observeSensitive),
      ("terminal.scrollViewport", .navigate),
      ("command.propose", .propose),
    ]

    for testCase in cases {
      // sessionObserve: broadly granted, but scope must still deny another session.
      let sessionObserveTier = ControlTokenTier.sessionObserve(sessionID: "s1")
      XCTAssertFalse(
        LabanControlPolicy.authorize(
          intentID: testCase.intentID,
          catalog: .all,
          granted: LabanControlPolicy.grants(for: sessionObserveTier),
          targetSession: "s2",
          tokenScope: LabanControlPolicy.tokenScope(for: sessionObserveTier),
          tokenTier: sessionObserveTier,
          method: "GET",
          path: "/irrelevant",
          query: "",
          bodySHA256: nil),
        "\(testCase.intentID) must deny a cross-session target on sessionObserve")

      // approvedSession: same denial, and it must happen before any
      // constraint-field comparison (the request below deliberately does not
      // match a real constraint, proving scope is checked independent of it).
      let approvedTier = ControlTokenTier.approvedSession(
        sessionID: "s1",
        approvalID: "a1",
        capabilities: [testCase.capability],
        constraint: ControlTokenConstraint(
          method: "GET",
          path: "/debug/whatever",
          query: "",
          bodySHA256: nil,
          resolvedRouteID: "GET /debug/whatever",
          resolvedIntentID: testCase.intentID))
      XCTAssertFalse(
        LabanControlPolicy.authorize(
          intentID: testCase.intentID,
          catalog: .all,
          granted: LabanControlPolicy.grants(for: approvedTier),
          targetSession: "s2",
          tokenScope: LabanControlPolicy.tokenScope(for: approvedTier),
          tokenTier: approvedTier,
          method: "GET",
          path: "/debug/whatever",
          query: "",
          bodySHA256: nil),
        "\(testCase.intentID) must deny a cross-session target on approvedSession")
    }
  }

  func testOmittedTargetResolvesToOwnSessionNotActiveTab() {
    // The policy layer has no notion of "active tab" at all: its only
    // fallback for an omitted target is the credential's own session
    // (`targetSession ?? ownSessionID`). Proving that omission authorizes
    // (rather than denies) demonstrates the fallback resolves to the
    // caller's own session; the live-server contract that no other fallback
    // (like an active tab) is consulted upstream of this call is COMMIT 3's
    // concern in `Sources/LabanApp/Control/LiveIntentRouter.swift`.
    let cases: [(intentID: String, capability: Capability)] = [
      ("app.state", .observeSensitive),
      ("terminal.scrollViewport", .navigate),
      ("command.propose", .propose),
    ]
    for testCase in cases {
      let tier = ControlTokenTier.sessionObserve(sessionID: "s1")
      XCTAssertTrue(
        LabanControlPolicy.authorize(
          intentID: testCase.intentID,
          catalog: .all,
          granted: LabanControlPolicy.grants(for: tier),
          targetSession: nil,
          tokenScope: LabanControlPolicy.tokenScope(for: tier),
          tokenTier: tier,
          method: "GET",
          path: "/irrelevant",
          query: "",
          bodySHA256: nil),
        "\(testCase.intentID) with an omitted target must resolve to the credential's own "
          + "session, not be denied")
    }
  }

  // MARK: - I3: approvedSession is strictly narrower than sessionObserve.

  func testApprovedSessionConstraintBindsEveryRequestField() {
    let baselineConstraint = ControlTokenConstraint(
      method: "GET",
      path: "/debug/state",
      query: "",
      bodySHA256: nil,
      resolvedRouteID: "GET /debug/state",
      resolvedIntentID: "app.state")
    let tier = ControlTokenTier.approvedSession(
      sessionID: "s1", approvalID: "a1", capabilities: [.observeSensitive],
      constraint: baselineConstraint)
    let granted = LabanControlPolicy.grants(for: tier)

    func authorize(
      intentID: String = "app.state",
      method: String = "GET",
      path: String = "/debug/state",
      query: String = "",
      bodySHA256: String? = nil,
      tokenTier: ControlTokenTier = tier
    ) -> Bool {
      LabanControlPolicy.authorize(
        intentID: intentID,
        catalog: .all,
        granted: granted,
        targetSession: "s1",
        tokenScope: .session("s1"),
        tokenTier: tokenTier,
        method: method,
        path: path,
        query: query,
        bodySHA256: bodySHA256)
    }

    XCTAssertTrue(authorize(), "an exact match on every field must authorize")

    XCTAssertFalse(authorize(method: "POST"), "a differing method must be denied")
    XCTAssertFalse(authorize(path: "/debug/other"), "a differing path must be denied")
    XCTAssertFalse(authorize(query: "a=1"), "a differing query must be denied")
    XCTAssertFalse(authorize(bodySHA256: "deadbeef"), "a differing body hash must be denied")

    let staleRouteTier = ControlTokenTier.approvedSession(
      sessionID: "s1", approvalID: "a1", capabilities: [.observeSensitive],
      constraint: ControlTokenConstraint(
        method: "GET", path: "/debug/state", query: "", bodySHA256: nil,
        resolvedRouteID: "GET /debug/other-route", resolvedIntentID: "app.state"))
    XCTAssertFalse(
      authorize(tokenTier: staleRouteTier),
      "a constraint whose resolvedRouteID disagrees with the live method/path must be denied")

    let staleIntentTier = ControlTokenTier.approvedSession(
      sessionID: "s1", approvalID: "a1", capabilities: [.observeSensitive],
      constraint: ControlTokenConstraint(
        method: "GET", path: "/debug/state", query: "", bodySHA256: nil,
        resolvedRouteID: "GET /debug/state", resolvedIntentID: "terminal.scrollViewport"))
    XCTAssertFalse(
      authorize(tokenTier: staleIntentTier),
      "a constraint whose resolvedIntentID disagrees with the requested intent must be denied")
  }

  func testApprovedSessionCapabilitiesAreSubsetOfSessionObserve() {
    let sessionObserveGrants = LabanControlPolicy.grants(for: .sessionObserve(sessionID: "s1"))

    // Every capability an approvedSession token could carry for an
    // allowlisted (server-mintable) route must already be inside what
    // sessionObserve grants.
    for entry in ControlLazyAttachAllowlist.entries {
      guard let descriptor = IntentCatalog.all.descriptor(id: entry.intentID) else {
        XCTFail("lazy allowlist entry \(entry.cliCommand) has no catalog descriptor")
        continue
      }
      let approvedTier = ControlTokenTier.approvedSession(
        sessionID: "s1", approvalID: "a1", capabilities: [descriptor.requiredCapability],
        constraint: ControlTokenConstraint(
          method: entry.method, path: entry.path, query: "", bodySHA256: nil,
          resolvedRouteID: entry.routeID, resolvedIntentID: entry.intentID))
      let approvedGrants = LabanControlPolicy.grants(for: approvedTier)
      XCTAssertTrue(
        approvedGrants.isSubset(of: sessionObserveGrants),
        "\(entry.cliCommand)'s approvedSession capabilities \(approvedGrants) exceed "
          + "sessionObserve's \(sessionObserveGrants)")
    }

    // Capabilities sessionObserve never grants at all (fixture, input,
    // clipboard) are a fortiori not a subset, which is the general shape of
    // "the user approves one operation; the authority is that operation":
    // an approvedSession minted for one of these would already violate I1,
    // and would also violate this invariant independently.
    XCTAssertFalse(sessionObserveGrants.contains(.input))
    XCTAssertFalse(sessionObserveGrants.contains(.clipboard))
    XCTAssertFalse(sessionObserveGrants.contains(.fixture))
  }

  // MARK: - I4: The lazy allowlist stays low-sensitivity.

  func testLazyAllowlistExcludesHighSensitivityIntents() {
    let excludedSensitivities: Set<DataSensitivity> = [
      .scrollback, .keystrokes, .clipboard, .screenshot, .trace,
    ]
    for entry in ControlLazyAttachAllowlist.entries {
      guard let descriptor = IntentCatalog.all.descriptor(id: entry.intentID) else {
        XCTFail("lazy allowlist entry \(entry.cliCommand) has no catalog descriptor")
        continue
      }
      XCTAssertFalse(
        descriptor.sideEffects.ptyInput,
        "\(entry.cliCommand) (\(entry.intentID)) writes PTY input; lazy allowlist entries must not")
      XCTAssertFalse(
        excludedSensitivities.contains(descriptor.dataSensitivity),
        "\(entry.cliCommand) (\(entry.intentID)) has dataSensitivity "
          + "\(descriptor.dataSensitivity), which one-click lazy approval must not reach")
    }
  }

  // MARK: - I5: A transport helper is never the trusted principal.

  func testHelperNeverSelectedAsPrincipal() {
    // Bundled helpers at the near end of the chain (closest to the request),
    // in front of a non-generic signed principal, in front of the shell.
    // Principal derivation must skip every bundled-helper entry and land on
    // the non-generic principal, never a helper.
    func identity(_ pid: pid_t, path: String, signing: ControlCodeSigningIdentity? = nil)
      -> ControlProcessIdentity
    {
      ControlProcessIdentity(pid: pid, startTime: Date(), executablePath: path, signing: signing)
    }

    let chains: [[ControlProcessIdentity]] = [
      // laban helper is the immediate peer.
      [
        identity(400, path: "/Applications/Laban.app/Contents/MacOS/laban"),
        identity(200, path: "/Applications/Codex.app/Contents/MacOS/Codex"),
        identity(100, path: "/bin/zsh"),
      ],
      // laban-agent helper is the immediate peer.
      [
        identity(400, path: "/Applications/Laban.app/Contents/MacOS/laban-agent"),
        identity(200, path: "/Applications/Codex.app/Contents/MacOS/Codex"),
        identity(100, path: "/bin/zsh"),
      ],
      // Both bundled helpers appear in the chain, flanking the principal.
      [
        identity(500, path: "/Applications/Laban.app/Contents/MacOS/laban"),
        identity(400, path: "/Applications/Laban.app/Contents/MacOS/laban-agent"),
        identity(200, path: "/Applications/Codex.app/Contents/MacOS/Codex"),
        identity(100, path: "/bin/zsh"),
      ],
      // Only bundled helpers and the shell: no persistable principal exists,
      // so derivation must fall through to the shell (still never a helper).
      [
        identity(200, path: "/Applications/Laban.app/Contents/MacOS/laban"),
        identity(100, path: "/bin/zsh"),
      ],
    ]

    for entries in chains {
      let chain = ControlAttachProcessChain(entries: entries)
      guard let principal = chain.principal else {
        XCTFail("expected a principal to be derivable from \(entries.map(\.executablePath))")
        continue
      }
      for helperBasename in ControlAttachConstants.bundledHelpers {
        XCTAssertNotEqual(
          principal.identity.executableBaseName, helperBasename,
          "principal derivation must never select the bundled helper \(helperBasename)")
      }
      XCTAssertFalse(
        ControlAttachPrincipal.isBundledHelper(principal.identity),
        "resolved principal must never be classified as a bundled helper")
    }
  }

  func testNonPersistablePrincipalCannotCreateRecord() throws {
    // Representative case (full sweep across generic/unsigned/ad-hoc
    // principals already lives in LazyAttachPrincipalPersistenceTests):
    // even a "malicious" delegate answering alwaysAllowSignedIdentity for a
    // generic-interpreter principal must not persist an approval record, and
    // the effective decision must degrade to allowOnce or deny.
    let peerPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    let shellPID: pid_t = 50
    let shellIdentity = ControlProcessIdentity(
      pid: shellPID, startTime: Date(timeIntervalSince1970: 1000), executablePath: "/bin/zsh")
    let peerIdentity = ControlProcessIdentity(
      pid: peerPID, startTime: Date(timeIntervalSince1970: 2000),
      executablePath: "/usr/local/bin/node")
    let tree = InvariantFakeProcessTreeInspector(tree: [
      peerPID: (parent: shellPID, identity: peerIdentity),
      shellPID: (parent: 1, identity: shellIdentity),
    ])

    let suiteName = "test-laban-invariant-suite-nonpersistable-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      defaults.removeSuite(named: suiteName)
    }
    let approvalStore = ControlAttachApprovalStore(
      defaults: defaults,
      signer: ControlAttachApprovalRecordHMACSigner(key: Data("test-invariant-key".utf8)))
    let server = LabanControlServer(
      router: InvariantSpyRouter(),
      surface: .headless,
      processTreeInspector: tree,
      codeSigningInspector: InvariantSigningByPIDInspector(signingByPID: [:]),
      approvalStore: approvalStore)
    let start = try server.start()
    defer { server.stop() }
    server.registerAttachShellPID(sessionID: "s1", shellPID: shellPID)
    // The server holds `approvalDelegate` weakly, so the delegate must be kept
    // alive in a local for the duration of the request; an inline instance
    // would deallocate before the approval completes and the request would
    // time out (status -1) instead of exercising the persistence guard.
    let delegate = InvariantFakeApprovalDelegate(decision: .alwaysAllowSignedIdentity)
    server.setApprovalDelegate(delegate)

    let intendedRequest: [String: Any] = [
      "clientRequestID": "550e8400-e29b-41d4-a716-446655440099",
      "cliCommand": "session.state",
      "intendedRequest": [
        "method": "GET",
        "path": "/debug/state",
        "query": "",
        "bodyBase64": NSNull(),
        "bodySHA256": NSNull(),
      ],
    ]
    let payload = try JSONSerialization.data(withJSONObject: intendedRequest, options: [])
    let (status, body) = try ControlUDSClient.request(
      socketPath: start.socketPath,
      method: "POST",
      path: LabanControlServer.lazyAttachRequestPath,
      token: start.appObserveToken,
      body: payload,
      timeout: 5)

    XCTAssertTrue(
      server.approvalStore.loadAll().isEmpty,
      "a non-persistable principal must never end up with a persisted approval record")
    if status == 200 {
      let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      XCTAssertEqual(json?["approval"] as? String, "once")
    } else {
      XCTAssertEqual(status, 403)
    }
  }

  // MARK: - I7: The GUI catalog floor.

  func testGuiCatalogFloorHasNoActuationAndExactAllowlists() {
    let guiDescriptors = IntentCatalog.all.descriptors.filter(\.availability.gui)

    let actuationOffenders = guiDescriptors.filter {
      $0.requiredCapability == .input || $0.requiredCapability == .clipboard
    }
    XCTAssertEqual(
      actuationOffenders.map(\.id).sorted(), [],
      "no gui:true descriptor may require .input or .clipboard")

    let guiNavigateIDs = Set(
      guiDescriptors.filter { $0.requiredCapability == .navigate }.map(\.id))
    XCTAssertEqual(guiNavigateIDs, ["terminal.scrollViewport"])

    let guiProposeIDs = Set(
      guiDescriptors.filter { $0.requiredCapability == .propose }.map(\.id))
    XCTAssertEqual(guiProposeIDs, ["command.propose"])
  }
}

private final class InvariantSpyRouter: IntentRouter {
  func route(_ intent: Intent) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: Query) -> ControlResponse { .json(["ok": true]) }
  func query(_ query: LegacyDebugQueryInput) -> ControlResponse { .json(["ok": true]) }
  func artifact(_ request: ArtifactRequest) -> ControlResponse? { nil }
}

/// Local copy of the fake process-tree fixture pattern from
/// `LazyAttachPrincipalPersistenceTests.swift` (kept private/file-scoped
/// there, so not directly reusable across files without a name collision).
private struct InvariantFakeProcessTreeInspector: ControlProcessTreeInspecting {
  let tree: [pid_t: (parent: pid_t?, identity: ControlProcessIdentity)]

  func parentPID(of pid: pid_t) -> pid_t? { tree[pid]?.parent }
  func identity(for pid: pid_t) -> ControlProcessIdentity? {
    var identity = tree[pid]?.identity
    identity?.parentPID = tree[pid]?.parent
    return identity
  }
}

/// Local copy of the signing-by-PID fixture pattern from
/// `LazyAttachPrincipalPersistenceTests.swift`.
private struct InvariantSigningByPIDInspector: ControlCodeSigningInspecting {
  let signingByPID: [pid_t: ControlCodeSigningIdentity]

  func signingIdentity(
    forLivePID pid: pid_t, startTime: Date, auditToken: Data?
  ) -> ControlCodeSigningIdentity? {
    signingByPID[pid]
  }

  func validatesLivePID(
    _ pid: pid_t, startTime: Date, auditToken: Data?, against requirement: String
  ) -> Bool {
    signingByPID[pid]?.designatedRequirement == requirement
  }
}

/// Local copy of the fake approval delegate fixture pattern from
/// `LazyAttachPrincipalPersistenceTests.swift`.
private final class InvariantFakeApprovalDelegate:
  ControlAttachApprovalDelegate, @unchecked Sendable
{
  let decision: ControlAttachApprovalDecision
  init(decision: ControlAttachApprovalDecision) { self.decision = decision }
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  ) {
    completion(decision)
  }
}
