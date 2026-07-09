# Control Plane Threat Model: Cross-Path Invariants

The live control plane now has three distinct ways a process can obtain
authority. Each path has its own plan, its own tests, and its own failure
modes. This document states the invariants that must hold across all three at
once, so a change to one path cannot silently break a guarantee that only
another path's tests assert. The invariants are executable: each one names its
test in `Tests/LabanControlTests/ControlPlaneInvariantTests.swift`, and any
change that adds a route, token tier, capability, or allowlist entry must keep
that suite green.

Background contracts live in ADR 0023 (architecture), ADR 0024 (security), and
the three ExecPlans:
`execplans/active/agent-first-phase2-mount-live-and-security-floor.md` (the
observe-first floor), `execplans/active/agent-control-production-broker-and-cli.md`
(the broker and CLI), and
`execplans/active/agent-control-lazy-attach-approval.md` (lazy approval).

## The three trust derivations

1. **C14 direct attach.** Laban mints a single-use `LABAN_SESSION_ATTACH`
   bootstrap for an explicitly agent-attached session. Only the bundled
   `laban-agent` executable, running as a direct child of the registered
   session shell PID, can redeem it, exactly once. The redeeming socket
   connection itself becomes the session-observe credential
   (`connectionTier` in `Sources/LabanControl/LabanControlServer.swift`).
   Trust derives from: executable identity + parent PID + one-shot redemption.

2. **Broker process tree.** `laban agent run -- <agent>` process-replaces into
   `laban-agent`, which redeems C14 (path 1) and then exposes a private proxy
   socket (`LABAN_AGENT_CONTROL_URL`) to the launched child and its
   descendants. Trust derives from: path 1, plus descendant-of-child process
   ancestry checks at the proxy
   (`Sources/LabanAgent/ControlAttachProxyServer.swift`).

3. **Lazy approval principal.** A process already running inside a registered
   session asks for one server-resolved request via
   `POST /control/session/attach/request`. Laban derives the approval
   principal from the verified process chain between the registered shell and
   the connecting helper, shows the user a dialog, and on approval dispatches
   exactly that request under a request-bound `approvedSession` context
   (`Sources/LabanControl/ControlAttachApproval.swift`,
   `ControlTokenTier.approvedSession` in
   `Sources/LabanControl/LabanControlPolicy.swift`). Trust derives from:
   ancestry + code-signing identity + explicit human consent.

## Invariants

**I1: No live tier can actuate.** No credential reachable on the live GUI
surface grants `.input` or `.clipboard`: not app-observe, not session-observe,
not any `approvedSession` the server can mint. Because `approvedSession`
carries a caller-supplied capability array, this invariant is asserted at the
minting path, not only at the policy table: every capability set the lazy
allowlist can produce comes from a catalog descriptor whose
`requiredCapability` is in `{observe, observeSensitive, navigate, propose}`.
Test: `testNoLiveTierGrantsInputOrClipboard`,
`testLazyMintingCannotProduceActuationCapabilities`.

**I2: Session scope holds on every path.** For a session-bound credential
(session-observe or approvedSession), a request targeting another session is
denied for every capability in `{observeSensitive, navigate, propose}`, and an
omitted target resolves to the credential's own session, never the active tab
(contract C12). Test: `testSessionScopeDeniesCrossSessionOnAllTiers`,
`testOmittedTargetResolvesToOwnSessionNotActiveTab`.

**I3: approvedSession is strictly narrower than sessionObserve.** An
approvedSession context never authorizes a request whose method, path, query,
body hash, resolved route, or resolved intent differs from the approved
constraint, and its capability set never exceeds what session-observe grants.
The user approves one operation; the authority is that operation. Test:
`testApprovedSessionConstraintBindsEveryRequestField`,
`testApprovedSessionCapabilitiesAreSubsetOfSessionObserve`.

**I4: The lazy allowlist stays low-sensitivity.** Every entry in
`ControlLazyAttachAllowlist` resolves to a catalog descriptor with
`sideEffects.ptyInput == false` and a `dataSensitivity` outside
`{scrollback, keystrokes, clipboard, screenshot, trace}`. Full terminal text
capture (`terminal.getText` and successors) is broker-path only; extending
one-click approval to scrollback text requires its own security review and a
deliberate edit to this invariant's test. Test:
`testLazyAllowlistExcludesHighSensitivityIntents`.

**I5: A transport helper is never the trusted principal.** Principal
derivation over any process chain never selects the bundled `laban` or
`laban-agent` executables, and never persists an always-allow record for a
generic interpreter, shell, package runner, or unsigned/ad-hoc binary. The
server enforces this independently of the UI: a delegate answering
"always allow" for a non-persistable principal does not create a record.
Test: `testHelperNeverSelectedAsPrincipal`,
`testNonPersistablePrincipalCannotCreateRecord` (plus the existing
`ControlAttachPrincipalTests`).

**I6: No long-lived bearer in any child environment.** The broker child
environment contains `LABAN_AGENT_CONTROL_URL` and never
`LABAN_SESSION_ATTACH` or `LABAN_CONTROL_ATTACH_ENV`; default-on sessions
never receive `LABAN_SESSION_ATTACH` at all (contract C10); the bootstrap that
does exist for explicit opt-in launches is spent on first redemption (contract
C14). Tests: `ChildLauncherTests` environment assertions in
`Tests/LabanAgentTests`, re-asserted at the policy level in the invariant
suite as `testNoBearerTokenEnvironmentKeysInChildEnvBuilder`.

**I7: The GUI catalog floor.** No `gui:true` descriptor requires `.input` or
`.clipboard`; the `gui:true` `.navigate` set is exactly
`{terminal.scrollViewport}` and the `gui:true` `.propose` set is exactly
`{command.propose}`. This already lives in
`Tests/LabanAppTests/CatalogParityTests.swift`; the invariant suite re-asserts
it directly from the catalog so the floor is visible next to the other
invariants. Test: `testGuiCatalogFloorHasNoActuationAndExactAllowlists`.

## Honesty notes (what is not a boundary)

**Approval-record HMAC is tamper evidence, not a boundary.** Persisted
always-allow records are HMAC-signed
(`Sources/LabanControl/ControlAttachApprovalRecordSigner.swift`), but the
signing key lives in a same-user-readable file
(`control-approval-signing.key`, mode 0600, in the Laban control directory).
A local attacker already running as the user can read the key and forge a
record. The HMAC defends against accidental corruption, casual UserDefaults
editing, and records copied between machines or users. The actual boundaries
for auto-approval are the live checks that run per request: code-signing
validation of the live principal process, ancestry revalidation, session shell
identity match, and the route/intent/capability subset checks. A forged record
for a principal that fails those live checks does not authorize anything.

**Same-user is the trust floor for everything here.** UDS peer credentials
reject other users; nothing in this design defends against arbitrary code
already executing as the user with full filesystem access. What the design
does defend against, deliberately, is ambient and accidental authority:
web pages (no TCP listener), other users (peer uid), environment inheritance
into arbitrary child processes (one-shot bootstrap, no bearer in env),
cross-session reads (scope), quiet actuation (no live `.input` grant), and
quiet escalation of a one-click approval (request-bound constraint,
allowlist sensitivity ceiling).

## Rules for changes

- Adding a route, intent, capability, token tier, or allowlist entry: run
  `swift test --filter ControlPlaneInvariantTests` and keep it green. If a
  change requires editing an invariant test, the edit is a security decision;
  record it in the relevant ExecPlan Decision Log and name the reviewer.
- Adding a fourth trust derivation (for example a cross-session observe
  grant): add its invariants here and to the suite in the same change that
  lands the mechanism.
- Never log token values, bootstrap values, raw Authorization headers, or
  terminal text in audit payloads. The existing no-token-logging tests are the
  enforcement; this document is the statement of intent.
