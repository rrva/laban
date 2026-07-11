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
`testApprovedSessionCapabilitiesAreSubsetOfSessionObserve`. The request-exact
`.approvedSession` tier is retained for one-shot callers; the dialog-first path
mints the deliberately broader `.approvedSessionFamily` tier instead (I4a),
which is scoped to the own-session read family rather than one request, and is
still a strict subset of session-observe (review NOTE 4).

**I4: The dialog-first family stays within the read/observe ceiling.** This
invariant was deliberately reversed by the dialog-first design
(`execplans/active/dialog-first-session-observe.md`, security-ACCEPTED
2026-07-11): a one-click approval now MAY reach `.observeSensitive` terminal
content (screen text, scrollback, selection), because the dialog is accepted as
strong enough consent for own-session content. What replaces the old
low-sensitivity ceiling is a read/observe ceiling that must never move: every
member of the own-session read family (`ControlSessionObserveFamily`) resolves
to a catalog descriptor with `sideEffects.ptyInput == false`, `gui == true`, and
a `requiredCapability` in `{observe, observeSensitive, navigate, propose}`,
never `.input`, `.clipboard`, or `.fixture`. The family's `.navigate` reach is
exactly `{terminal.scrollViewport}` (own-session view scroll, review NOTE 1),
matching I7. The boundaries that stay locked, cross-session and actuation, are
enforced independently of the family set (C12 scope check, capability derivation
from the catalog), not by this sensitivity list. A change that drops a family
member, adds one outside the ceiling, or moves the `.navigate` set fails the
test. Tests: `testDialogFirstFamilyStaysWithinTheObserveCeiling`,
`testDialogFirstFamilyNavigateIsExactlyScrollViewport` (server side);
`testTerminalGetTextIsInTheDialogFirstFamilyAndStaysScrollbackSensitivity`
(CLI side).

**I4a (positive family invariant): a family grant authorizes exactly the
family.** A `.approvedSessionFamily` grant for a session authorizes every
own-session read-family intent for that session with no request-exact binding,
and denies any non-family intent, any cross-session target, and any
`.input`/`.clipboard`/`.fixture` intent even for the approved principal and
session. One approval persists as one family record (full family intent set,
`{observe, observeSensitive, navigate, propose}` capabilities, and the
ordering-maximum `dataSensitivity` across the family, `sensitivePrivate`, so a
later scrollback read is not rejected by a lower stored ceiling), keyed to the
signed principal and session. Tests:
`testFamilyGrantAuthorizesEveryFamilyIntentForItsSession`,
`testFamilyGrantDeniesEveryFamilyIntentForAnotherSession`,
`testFamilyGrantDeniesActuationClipboardAndFixtureIntents`
(`DialogFirstObserveServerTests`);
`testFamilyRecordAutoApprovesEveryFamilyIntentForSameSessionAndPrincipal` and
the mismatched-session/principal/signing denials (`DialogFirstFamilyRecordTests`).

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
quiet escalation of a one-click approval. That last defense changed shape with
the dialog-first design: an approval no longer binds to one exact request, it
grants the whole own-session read family for the session (I4a). The escalation
that stays blocked is escalation *out of the family*, to actuation, clipboard,
fixture, or another session, none of which any dialog can grant. The dialog
states the family's content-inclusive scope and its exclusions plainly so the
consent matches the grant.

## Rules for changes

- Adding a route, intent, capability, token tier, or a member to the
  own-session read family (`ControlSessionObserveFamily`): run
  `swift test --filter ControlPlaneInvariantTests` and keep it green. Adding a
  family member is a security decision (it widens what one dialog approval
  grants); it must resolve to a descriptor inside the I4 read/observe ceiling,
  and the decision is recorded in the relevant ExecPlan Decision Log with a
  named reviewer. If a change requires editing an invariant test, that edit is
  itself a security decision under the same rule.
- Adding a fourth trust derivation (for example a cross-session observe
  grant): add its invariants here and to the suite in the same change that
  lands the mechanism.
- Never log token values, bootstrap values, raw Authorization headers, or
  terminal text in audit payloads. The existing no-token-logging tests are the
  enforcement; this document is the statement of intent.
