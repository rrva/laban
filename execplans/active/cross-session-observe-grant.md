# User-Mediated Cross-Session Observe Grant

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds.

**This plan is design-first.** Its first milestone is the design itself plus a
fresh-eyes security review of the threat analysis below. No implementation
milestone may start until that design review has passed (mirroring how the
2026-06-20 observe-first pivot was handled: security deliberation before code).
The implementation milestones are written concretely enough for a novice to
execute later, but every one of them is marked not started.

This plan builds directly on two shipped bodies of work and repeats the context
it needs from them, per PLANS.md self-containment rules:

- `execplans/active/agent-first-phase2-mount-live-and-security-floor.md`
  (the observe-first security model: two token tiers, session scoping,
  UDS transport, the C-numbered contracts referenced below).
- `execplans/active/agent-control-lazy-attach-approval.md`
  (the approval machinery: process identity, ancestry, attach principal,
  signed-identity persistence rules, the approval store and presenter).

## Purpose / Big Picture

Today, an agent attached to a Laban session can read the truth of exactly one
session: its own. Every sensitive read (grid text, scrollback, selection, find
state) is scoped to the agent's session, and a read that names any other
session returns HTTP `403`. That invariant (called C12 in the Phase 2 plan) is
what closed the cross-tab read breakout: an agent in tab A cannot read tab B.

After this change, a human can grant one specific agent read access to one
specific other session, explicitly, visibly, and revocably. Nothing changes by
default: without a grant, cross-session sensitive reads still return `403`.

The demonstrable scenario, end to end:

1. The user has two Laban tabs. Tab A is an agent-attached session running
   Codex (started with `laban agent run -- codex`). Tab B is titled `build`
   and is running a long compile.
2. Codex wants to watch the build. It discovers tab B's session id from the
   redacted app summary (titles and session ids are part of the
   `app.stateSummary` allowlist), then runs:

       laban session observe-grant request --target-session 7F3A...B2 \
         --purpose "watch the build output for errors"

   or, by title (convenience only; see the title-ambiguity rules below):

       laban session observe-grant request --target-title build \
         --purpose "watch the build output for errors"

3. Laban shows an approval sheet on the key window:

       Allow Codex to observe another Laban session?

       Requester:      Codex
       Via:            Requested via broker from within Codex's process
                       tree (exact requester not verifiable)
       From session:   c2yt (session ...D27)
       Target session: build (session ...4B2)
       Target cwd:     ~/wrk/laban
       Target process: ninja
       Data:           Viewport text, selection, find state, and scrollback
                       line counts of the target
       Not included:   No input, no clipboard, no tab switching, no proposals
                       to the target, no other sessions

       [Allow Once]  [Allow While Both Sessions Live]  [Deny]

4. The user chooses "Allow While Both Sessions Live". Codex can now run:

       laban session detail --session 7F3A...B2 --json

   and receive tab B's session detail (including visible grid text), exactly
   the DTO it already gets for its own session. Both tab A and tab B show the
   agent-attached indicator while the grant is active, every cross-session
   read is audited, and the grant appears in Settings with a Revoke button.
5. The user closes tab B (or tab A, or restarts Laban, or clicks Revoke). The
   next cross-session read returns `403` with code `grantExpired` (or
   `grantRevoked`), and Codex must ask again.

Choosing "Allow Once" instead authorizes exactly one server-resolved read of
the target and nothing more; the next read prompts again. Choosing "Deny"
returns `403 userDenied` to the agent with no retry storm (a deny cooldown
applies).

This is the first capability that makes Laban's control plane do something no
other terminal does safely: mediated, scoped, revocable cross-session
observation. It is deliberately sequenced ahead of any Terminal-Lease
actuation work and stays strictly observe-only.

## Progress

- [x] (2026-07-09) Read `PLANS.md`, the Phase 2 security-floor plan, the
  lazy-attach approval plan, the program design doc header amendments and §9
  non-goals, and the shipped approval sources
  (`ControlAttachApproval.swift`, `ControlAttachApprovalStore.swift`,
  `LabanControlPolicy.swift`, `ControlAttachApprovalPresenter.swift`).
- [x] (2026-07-09) Drafted this design plan (this document).
- [x] (2026-07-09) First design review round completed (fresh-state security
  review against commit 35d32e0): item 0 NOT PASSED; three findings and
  eight notes recorded in the Review Gate section (kept there verbatim).
- [x] (2026-07-09) Design revised per that review: all three findings and
  all eight notes folded into the body; orchestrator decisions recorded in
  the Decision Log (entries dated 2026-07-09, Fable orchestrator per
  review). Second review round pending.
- [ ] Design Review Gate item 0 passed (second review round).
- [ ] Milestone 1 (grant model + policy change in `LabanControl`). NOT
  STARTED; gated on the design review.
- [ ] Milestone 2 (request endpoint, target resolution, approval flow). NOT
  STARTED; gated on the design review.
- [ ] Milestone 3 (approval sheet, dual-tab indicator, Settings list,
  revocation, audit). NOT STARTED; gated on the design review.
- [ ] Milestone 4 (CLI verbs + installed end-to-end verification). NOT
  STARTED; gated on the design review.
- [ ] Implementation Review Gate passed.

## Context and Orientation

Assume no prior knowledge. The moving parts, by full path:

- **Control plane.** Laban's GUI runs an HTTP server over a Unix domain
  socket (a local file-system endpoint; no TCP port). The server lives in
  `Sources/LabanControl/LabanControlServer.swift`. Same-user processes
  discover it through `control.json`, which carries the socket path and an
  "app-observe" bearer token that can read only redacted app metadata (tab
  titles, session ids, cwd, process names), never terminal content.
- **Token tiers.** `Sources/LabanControl/LabanControlPolicy.swift` defines
  `ControlTokenTier`: `.appObserve` (redacted summary only),
  `.sessionObserve(sessionID:)` (sensitive reads of exactly one session,
  held as a live socket connection after the one-shot C14 attach handshake),
  `.approvedSession(sessionID:approvalID:capabilities:constraint:)` (a
  one-shot authorization bound to one exact request, created by the
  lazy-attach approval flow), and `.fixture` (headless tests only).
- **Session scoping (C12).** `LabanControlPolicy.authorize(...)` enforces
  that a session-bound credential can only target its own session. An omitted
  target resolves to the credential's own session, never the active tab. An
  explicit other target returns `403`. This plan adds the only exception, and
  it is human-granted.
- **Capabilities.** `Sources/LabanCore/Intents/IntentCatalog.swift` classifies
  every intent with a `requiredCapability` (`observe`, `observeSensitive`,
  `navigate`, `propose`, `input`, `fixture`) and a `dataSensitivity`. The
  sensitive own-session read family relevant here is the set of
  `gui: true` query intents requiring `.observeSensitive`, plus one
  `.observe`-tier state query (`scrollIndicator.state`); the exact grant
  set is listed below.
- **Lazy-attach approval machinery** (all shipped; this plan reuses it):
  - `Sources/LabanControl/ControlProcessIdentity.swift`:
    `ControlProcessIdentity` (pid, parent pid, start time, uid, executable
    path, code-signing summary). Start time is mandatory for security
    decisions; a missing start time fails closed (`403
    processIdentityUnavailable`). This defeats PID reuse.
  - `Sources/LabanControl/ControlAttachApproval.swift`:
    `ControlAttachProcessChain` (the verified same-uid chain from a
    registered session shell to the connecting peer) and
    `ControlAttachPrincipal` (the non-helper, non-generic process in that
    chain that best represents the requesting app; the bundled `laban` and
    `laban-agent` binaries are transport helpers and never the principal;
    generic interpreters like `node`, `python`, `zsh` are never persistable
    principals). Also `RegisteredAttachShellIdentity` (session id + shell
    pid + shell start time + uid), the liveness anchor for a session.
  - `Sources/LabanControl/ControlAttachApprovalStore.swift`: token-free
    approval records in UserDefaults under
    `LabanControlAttachApprovalRecordsV1`, HMAC-signed by
    `ControlAttachApprovalRecordFileSigner`
    (`Sources/LabanControl/ControlAttachApprovalRecordSigner.swift`). HMAC
    is a keyed checksum: it proves a record was written by code holding the
    key file, which is same-user readable, so it is tamper evidence, not a
    security boundary (threat (f) below).
  - `Sources/LabanApp/Control/ControlAttachApprovalPresenter.swift`: the
    AppKit `NSAlert` sheet with labeled detail rows (Operation, Session,
    Requester, Path, Chain, Data, Permission, Scope) and the
    Allow Once / Always Allow / Deny buttons, persistence-gated by
    `ControlAttachApprovalRequest.canPersist`.
  - `Sources/LabanApp/Control/ControlSecurityCoordinator.swift`: appends
    sanitized audit events (`control.attach.requested`, `.approved`,
    `.denied`, `.revoked`, `.autoApproved`, `control.privileged`,
    `control.denied`) to the persistent `EventLog` and arms the TTL-based
    agent-attached indicator via `ControlAgentAttachedIndicatorHost`.
  - `Sources/LabanApp/SettingsWindowController.swift`: the approvals list
    (`makeApprovalsListView`, near line 862) with per-record Revoke buttons.
  - `Sources/LabanControl/ControlLazyAttachAllowlist.swift`: the exact
    (CLI command, method, path, intent) tuples the lazy path may request.
  - The lazy request route `POST /control/session/attach/request` in
    `LabanControlServer.swift`, with error codes
    `processIdentityUnavailable`, `notDescendantOfRegisteredSession`,
    `lazyRouteNotAllowed`, `userDenied`, `approvalTimeout` (`408`),
    `sessionChanged` (`409`), `approvalRateLimited` (`429`).
- **CLI.** `Sources/LabanCLI/LabanCLI.swift` and
  `Sources/LabanCLI/LazyAttachClient.swift` implement `laban session state`,
  `session request`, `session scroll`, `propose`, with broker-first transport
  (`LABAN_AGENT_CONTROL_URL` proxy) and lazy approved dispatch as fallback.
- **Operator guide.** `docs/process/controlling-agent-control-plane.md` is
  the user-facing document that must gain a cross-session grant section when
  this ships.

Definitions used only in this plan:

- **Source session**: the session the requesting agent is attached to (the
  session its credential is bound to). Tab A in the scenario.
- **Target session**: the other session the human grants read access to.
  Tab B in the scenario.
- **Grant**: a tuple (principal, source session, target session) plus
  lifetime state, created only by an explicit human approval, that widens
  the read scope of that principal's source-session credential to also cover
  the target session, for a fixed read-only intent set.
- **Standing grant**: the "Allow While Both Sessions Live" outcome. Lives
  until either session's registered shell identity (pid + start time) goes
  away, until revoked, or until the app restarts, whichever is first.
- **One-shot grant**: the "Allow Once" outcome. Authorizes exactly one
  server-resolved read, dispatched by the server itself under the existing
  `.approvedSession` pattern; nothing is retained afterward.

## Design Constraints (restated as invariants)

These restate the constraints this design must honor. The implementation
Review Gate checks each one mechanically.

- **G1: C12 holds by default.** Without a grant, a cross-session sensitive
  read returns `403` exactly as today. A grant is a narrow, explicit,
  revocable exception recorded per (principal, source session, target
  session). No grant ever widens scope for any other principal, source, or
  target.
- **G2: Observe-only, and less than own-session.** A grant unlocks only the
  fixed read intent set listed in "What a grant unlocks". It never unlocks
  navigation of the target (`terminal.scrollViewport` on the target stays
  `403`), proposals targeting the target (`command.propose` stays `403`),
  input (nothing changes; no live token grants `.input`), clipboard, tab
  lifecycle, or any whole-app read.
- **G3: Lifetime is bounded by both shells and the app run.** A standing
  grant expires when either the source or the target registered session
  shell identity (pid + start time) dies or changes. No grant survives app
  restart, even when the underlying shells survive under labpty (see the
  runID binding in "The grant model"). One-shot grants authorize exactly one
  server-resolved request.
- **G4: Reuse, do not reinvent.** Principal derivation, ancestry rules,
  start-time-mandatory process identity, signed-identity persistence rules
  (generic interpreters and unsigned binaries get Allow Once only),
  token-free HMAC-signed records, the presenter sheet pattern, audit via
  `ControlSecurityCoordinator`, the indicator, and Settings revocation all
  come from the lazy-attach machinery, extended, not duplicated.
- **G5: The dialog shows Laban's identity for the target, never only the
  attacker-influenceable title.** Tab title AND session id suffix AND cwd
  AND foreground process are shown together; the grant binds to the session
  id resolved at approval time and is never re-resolved by title. Only the
  session id suffix is Laban-authoritative; cwd and process name are
  context and are themselves attacker-influenceable (threat (c)).
- **G6: Persisted records are advisory, not authoritative.** Authority lives
  in the control server's in-memory grant table for the current app run.
  UserDefaults records exist for the Settings list and audit continuity; a
  record with no matching in-memory entry grants nothing (threat (f)).
- **G7: The standing invariants document moves in the same change.**
  `docs/process/control-plane-threat-model.md` and
  `Tests/LabanControlTests/ControlPlaneInvariantTests.swift` are amended in
  the same commits that land the mechanisms: I2 gains the grant exception
  with its exact conditions (Milestone 1), I7's gui `.propose` set becomes
  `{command.propose, session.requestObserveGrant}` (Milestone 2), and a new
  invariant I8 states that grants widen only the fixed read set for one
  (principal, source session, target session) tuple and die with either
  shell death, revocation, or runID change (Milestone 1). This follows that
  document's own "Rules for changes" for a fourth trust derivation.

## The Grant Model

### In-memory authority

`LabanControlServer` gains an in-memory table, parallel to the existing
`attachShellIdentitiesBySessionID`:

    private var sessionObserveGrantsByID: [String: ControlSessionObserveGrant] = [:]

with a new pure type in a new file
`Sources/LabanControl/ControlSessionObserveGrant.swift`:

    public struct ControlSessionObserveGrant: Equatable, Sendable {
      public let id: String                       // UUID, the grantID
      public let runID: String                    // control server launch runID
      public let principalFingerprint: String     // ControlProcessIdentity.stablePrincipalFingerprint
      public let principalDisplayName: String
      public let signingRequirement: String       // always non-empty; one-shot
                                                  // grants never construct this type
      public let sourceSessionID: String
      public let sourceShellFingerprint: String   // RegisteredAttachShellIdentity.fingerprint
      public let targetSessionID: String
      public let targetShellFingerprint: String
      public let createdAt: Date
      public var lastUsedAt: Date?
      public var revokedAt: Date?
    }

A grant authorizes a request only when ALL of the following hold at the
moment of authorization (checked fresh per request, which is the TOCTOU
defense, threat (d)):

1. `revokedAt == nil`.
2. `runID` equals the current server run (kills every grant across restart,
   even if labpty kept both shells alive).
3. The source session's current `RegisteredAttachShellIdentity.fingerprint`
   equals `sourceShellFingerprint` and that shell process is live with a
   matching start time.
4. Same for the target session and `targetShellFingerprint`.
5. The requesting credential is bound to `sourceSessionID` (a held
   `.sessionObserve` connection, or an `.approvedSession` dispatch whose
   session is the source).
6. The requesting principal's `stablePrincipalFingerprint` equals
   `principalFingerprint`, and for standing grants the live principal still
   validates against `signingRequirement` via
   `ControlCodeSigningInspecting.validatesLivePID` (fail closed to a fresh
   prompt if validation is unavailable).
7. The resolved intent id is in the grant read set (next section) and the
   explicit target session equals `targetSessionID`.

If checks 2, 3, or 4 fail, the grant is dead: the server removes it from the
table, marks the mirror record expired, emits `control.observeGrant.expired`,
and the request returns `403` code `grantExpired`. If check 1 fails the code
is `grantRevoked`. Failing 5, 6, or 7 simply means "no grant applies" and the
request falls through to the default C12 denial (`403`).

### Persisted mirror (advisory)

A new `ControlSessionObserveGrantStore` in
`Sources/LabanControl/ControlSessionObserveGrantStore.swift` follows
`ControlAttachApprovalStore` exactly: token-free `Codable` records in
UserDefaults under a new key `LabanControlSessionObserveGrantRecordsV1`,
signed and validated with the existing
`ControlAttachApprovalRecordSigning` HMAC signer family (generalize the
signer over a canonical-bytes payload or add a sibling record signer; do not
add a second key file). Records mirror `ControlSessionObserveGrant` fields
plus `schemaVersion`. The store exists so Settings can list grants (including
recently expired ones for user awareness) and so revocation survives a
Settings-window relaunch; it is never consulted for authorization (G6). On
server start, a sweep marks every record whose `runID` differs from the
current run as expired.

## What a Grant Unlocks

A single named constant in `Sources/LabanControl/LabanControlPolicy.swift`
(so the Review Gate can grep it):

    public static let crossSessionObserveGrantIntentIDs: Set<String> = [
      "session.detail",          // viewport grid text, scrollback line counts, cwd, process, exit state
      "selection.read",          // current selection text
      "find.state",              // find needle + match state
      "shellIntegration.state",  // OSC 133 prompt/command phase
      "scrollIndicator.state",   // scroll position indicator
    ]

These are precisely the live-GUI session-scoped observe reads the agent
already has for its own session, applied to the target through the shared
target resolution specified under "One resolved target for policy,
dispatch, and audit" below. Viewport grid text and scrollback LINE COUNTS
(not scrollback text) arrive through `session.detail`
(`GET /debug/sessions/<id>`), which is why no new read intent is needed.

Two clarifications from the first review round (NOTE 7):

- Allow Once needs no Milestone 1 policy change at all: the one-shot
  dispatch rides `.approvedSession(sessionID: TARGET)`, which the shipped
  `LabanControlPolicy.authorize` already accepts via scope
  `.session(TARGET)` plus constraint binding. The `grantedSessions`
  widening exists only for standing grants exercised over a held
  source-session credential.
- `scrollIndicator.state` requires only `.observe`, and the app-observe
  token's `.wholeApp` scope can already read it for any session today. Its
  membership in the grant set is redundant but harmless; it is kept so the
  grant read set matches the own-session observe family one for one.

Deliberate exclusions, each with the reason:

- `app.accessibility`: excluded to keep the MVP read set minimal; its text
  projection substantially overlaps `session.detail`. (The shared target
  resolution below would make it technically feasible; revisit only with a
  concrete consumer.)
- `session.list` and rich `app.state`: whole-app reads that stay redacted to
  the source session. A grant names one target; it never widens enumeration.
- `terminal.scrollViewport` (navigate), `command.propose` (propose): a grant
  is strictly observe. The agent may not scroll, focus, or propose into the
  target session.
- Everything requiring `.input`, `.clipboard`-sensitivity reads, `.fixture`,
  logs, screenshots, capture, persistence: unchanged, ungranted.
- Future read intents (for example a `session.getText` from the planned
  context/get-text work) do NOT join automatically: they must be added to
  `crossSessionObserveGrantIntentIDs` explicitly, which is a reviewed diff.

### Policy-layer change

`LabanControlPolicy.authorize(...)` today denies any explicit
`targetSession` different from the token's own session. The change: the
server passes the set of target session ids currently granted to this
credential's principal for this source session, and the policy allows the
explicit target when it is in that set AND the intent is in the grant read
set. Sketch of the delta (the plan of record; exact code is Milestone 1):

    public static func authorize(
      intentID: String, catalog: IntentCatalog, granted: Set<Capability>,
      targetSession: String?, tokenScope: TokenScope,
      grantedSessions: Set<String> = [],          // NEW, default empty
      tokenTier: ControlTokenTier? = nil,
      method: String? = nil, path: String? = nil, query: String? = nil,
      bodySHA256: String? = nil
    ) -> Bool

    // inside case .session(let ownSessionID):
    let effectiveTarget = targetSession ?? ownSessionID   // C12: omitted target stays OWN session
    if effectiveTarget != ownSessionID {
      guard grantedSessions.contains(effectiveTarget),
            crossSessionObserveGrantIntentIDs.contains(intentID)
      else { return false }
    }

Two properties to preserve verbatim: an omitted target still resolves to the
own session (a grant never changes defaulting, so a focus change still leaks
nothing), and `grantedSessions` defaults to empty (every existing call site
compiles unchanged and stays deny-by-default). The server computes
`grantedSessions` fresh per request by running the seven-point grant check
above; the policy itself stays a pure function.

No new `Capability` enum case is added. Rationale in the Decision Log:
capability answers "which verb", scope answers "whose session"; cross-session
observe is the same verb (`.observeSensitive`) with a human-widened scope, so
modeling it as scope keeps the catalog's classification orthogonal
(requiredCapability x dataSensitivity x scope) and avoids re-classifying every
descriptor.

### One resolved target for policy, dispatch, and audit

The first review round found a target-mismatch class (Review Gate,
FINDING 1): the policy check would resolve the target from the request keys
the server honors (`sessionID`, `sessionId`, `targetSessionID`,
`targetSessionId`), while active-session-shaped projections such as
`ControlStateProjections.selectionResponse` take no session parameter and
read `ctx.scopedSessionID`, which `legacyQueryInput` pins to the SOURCE
session for a `.sessionObserve` credential. With a grant active, a request
naming the target could pass policy, read the SOURCE, and audit a TARGET
read that never happened. The same class hits `find.state`,
`shellIntegration.state`, and `scrollIndicator.state` through the
`targetSessionID`/`targetSessionId` keys.

The fix is structural, adopted over dropping `selection.read` from the set
(Decision Log): the policy-resolved effective target is the single source
of truth for the entire request.

- `LabanControlServer` resolves the effective target once per request (the
  C12 defaulting plus the seven-point grant check), before authorization.
- That one value flows into the dispatch context: `legacyQueryInput`'s
  `scopedSessionID` becomes the granted TARGET when and only when a grant
  authorized an explicit cross-session target. In every other case it stays
  pinned to the credential's own session, byte-identical to today.
- The same value is what `reportAuthorize` and `control.observeGrant.used`
  record. Policy target, dispatch target, and audited target are one
  variable and cannot drift.

Milestone 1 carries a mandatory named test,
`testGrantedReadPayloadSessionEqualsAuditedTarget`: for each of the five
grant intents, dispatch a granted cross-session read and assert the
dispatched payload's session id equals the audited target session id.
(Allow Once is unaffected by the mismatch class: `.approvedSession` is
bound to the TARGET, so `scopedSessionID` already becomes the target on
that path.)

## The Asking Flow

### Typed intent

A new catalog descriptor in
`Sources/LabanCore/Intents/IntentCatalog.swift`:

    descriptor(
      id: "session.requestObserveGrant", category: "session",
      summary: "Ask the user to grant read access to another session.",
      requiredCapability: .propose, dataSensitivity: .nonSensitiveState,
      availability: guiObserve,
      inputSchema: ObserveGrantRequest.jsonSchema)

It is classified `.propose` because, like `command.propose`, it is a
user-mediated request object, never an action. The Phase 2C positive
allowlist test ("the `gui:true` `.propose` set equals exactly
`{command.propose}`") is updated to exactly
`{command.propose, session.requestObserveGrant}`; the `.navigate` allowlist
is untouched.

### Transports

Both existing transports carry the request; both reuse the shipped principal
machinery:

1. **Held broker connection** (`laban agent run -- codex`): the agent's
   long-lived `.sessionObserve` connection posts the intent via
   `POST /debug/actions` with action `requestObserveGrant`. The peer is
   `laban-agent` (a bundled helper, never the principal); the principal is
   derived by inspecting the helper's non-helper child subtree (the agent it
   launched), using the same `ControlAttachPrincipal.isPersistable` rules.
   See Decision Log entry "downward principal step". Attribution limit on
   this transport (first review round, FINDING 2): the broker proxy
   (`Sources/LabanAgent/ControlAttachProxyServer.swift`) accepts any
   descendant of the allowed root pid and forwards requests without
   conveying the requesting descendant's identity, so Laban can verify the
   principal (the brokered agent) but NOT which process below it actually
   asked. The sheet must not render a chain row that implies verification;
   it renders the transport-specific row specified in "The sheet" instead.
   As an explicit non-MVP follow-up, the proxy MAY later forward the
   requesting descendant's pid and start time as display-only enrichment;
   that forwarded identity is never authorization input.
2. **Lazy CLI path** (agent started directly in the tab): a new route
   `POST /control/session/observe-grant/request`, shaped exactly like the
   shipped `POST /control/session/attach/request`: same-uid peer, app-observe
   token, peer identity with mandatory start time, exactly one registered
   source-shell ancestor, upward-chain principal derivation. The lazy request
   body carries the grant ask plus, REQUIRED, one intended read to dispatch
   on Allow Once.

Request body (both transports):

    {
      "clientRequestID": "uuid",
      "target": { "sessionID": "7F3A...B2" },
      "purpose": "watch the build output for errors",
      "intendedRequest": {
        "method": "GET", "path": "/debug/sessions/7F3A...B2",
        "query": "", "body": null, "bodySHA256": null
      }
    }

`target` is either `{ "sessionID": "..." }` or `{ "title": "build" }`.
`purpose` is untrusted display text: length-capped, rendered with the C15
safe-rendering rules (byte-exact, control/newline/bidi characters visibly
escaped, no ANSI interpretation), never used for authorization or audit
identity. `intendedRequest` is required on the lazy transport (Allow Once
must dispatch something) and optional on the held connection (where Allow
Once creates a single-read `.approvedSession` dispatch the same way).

### Target resolution and the title-ambiguity rule

Tab titles are attacker-influenceable: any program in any tab can set its
title via the OSC 0/2 escape sequence, including a remote host. Therefore:

- A `title` selector is resolved by the SERVER against Laban's own session
  registry at request time. Zero matches: `404` code `targetNotFound`. More
  than one match: `409` code `targetAmbiguous` with the count only (no other
  sessions' details are leaked to the requester). Exactly one match: proceed.
- The grant binds to the resolved `sessionID` at approval time and is NEVER
  re-resolved by title. A title change after approval changes nothing.
- The target must not equal the source session (`400` code
  `targetIsOwnSession`), must exist, and must have a registered shell
  identity with a start time (else `403 processIdentityUnavailable`).
- The dialog always shows Laban's own identity for the target: title AND
  session id suffix AND cwd AND foreground process name, so a spoofed title
  cannot stand alone (threat (c)).

### Status codes and error code strings

| Outcome | HTTP | code |
| --- | --- | --- |
| Approved (once), read dispatched | `200` | body carries `downstreamStatus`/`downstreamBody`, as in lazy attach |
| Approved (standing) | `200` | `{ "ok": true, "grantID": "...", "targetSessionID": "...", "expiresWith": "eitherSessionEnds" }` |
| User denied | `403` | `userDenied` |
| No answer in 30 s | `408` | `approvalTimeout` |
| Session/process identity changed during approval | `409` | `sessionChanged` |
| Rate limited / duplicate | `429` | `approvalRateLimited` |
| Denied recently, cooldown active | `429` | `approvalDenyCooldown` |
| Title matches nothing | `404` | `targetNotFound` |
| Title matches several | `409` | `targetAmbiguous` |
| Target is the source | `400` | `targetIsOwnSession` |
| Grant read outside the intent set (later, at read time) | `403` | (plain C12 denial) |
| Grant dead: shell died or restart | `403` | `grantExpired` |
| Grant revoked in Settings | `403` | `grantRevoked` |
| Requester not descendant of source shell (lazy transport) | `403` | `notDescendantOfRegisteredSession` |
| Missing start time anywhere | `403` | `processIdentityUnavailable` |

### Approval semantics

- **Allow Once**: the server dispatches exactly the intended read under an
  `.approvedSession(sessionID: TARGET, approvalID:, capabilities:
  [.observeSensitive], constraint:)` context, reusing the shipped
  `ControlTokenConstraint` binding (method, path, query, bodySHA256, resolved
  route, resolved intent). Immediately before dispatch it re-runs the full
  revalidation (peer identity, ancestry, both shell identities, target
  match); any change is `409 sessionChanged`. Nothing persists. Available to
  every principal, including generic interpreters and unsigned binaries.
- **Allow While Both Sessions Live**: creates the in-memory
  `ControlSessionObserveGrant` plus the advisory mirror record. Offered ONLY
  when the principal is persistable under the shipped rules
  (`ControlAttachPrincipal.isPersistable`: stable signed, non-generic,
  non-helper, non-ad-hoc, with a designated requirement). For a generic
  interpreter, an unsigned binary, a script, or a bundled helper, the button
  is absent and the sheet explains why, exactly as the lazy-attach sheet
  does via `persistenceDisabledReason`. The server independently validates
  the decision: a delegate returning the standing-grant decision for a
  non-persistable principal is downgraded to Allow Once if the one-shot is
  eligible, else denied `403 approvalNotPersistable` (same server-side
  distrust of the UI layer as lazy attach).
- **Deny**: `403 userDenied`, plus a per-(principal, source, target) deny
  cooldown (below).

Prompt coalescing and rate limits extend the shipped lazy-attach rules:

- at most one visible approval prompt per app at a time (grant prompts and
  lazy-attach prompts share the queue),
- at most one pending grant request per (principal, source session, target
  session) tuple,
- duplicate matching requests inside a two-second window coalesce onto the
  pending prompt or return `429 approvalRateLimited`,
- the global pending cap of eight requests is shared with lazy attach,
- after a Deny, further grant requests for the same (principal, source,
  target) return `429 approvalDenyCooldown` for 60 seconds without showing
  UI (threat (a): an agent cannot re-prompt its way past a human),
- pending requests are cancelled on either session closing, app shutdown,
  timeout, or client disconnect.

## Approval UX, Indicator, Audit, Settings

### The sheet

A new `Sources/LabanApp/Control/ControlObserveGrantApprovalPresenter.swift`
follows `ControlAttachApprovalPresenter` exactly (NSAlert, accessory
`NSStackView` with explicit frame sizing per the shipped AppKit fix, sheet on
the key window with `runModal()` fallback). A separate presenter, not a flag
on the existing one, because the row set differs: it adds
"From session", "Target session", "Target cwd", "Target process", and a
"Not included" row, and its middle button is
"Allow While Both Sessions Live". The delegate is a new protocol in
`Sources/LabanControl/ControlAttachApproval.swift`:

    public struct ControlObserveGrantApprovalRequest: Sendable { ... }   // mirrors ControlAttachApprovalRequest,
                                                                         // plus targetSessionDisplay, targetCwd,
                                                                         // targetProcessName, purpose (pre-escaped),
                                                                         // and a transport indicator
                                                                         // (lazyVerifiedChain vs brokerUnverified)
                                                                         // so the presenter picks the right
                                                                         // attribution row (FINDING 2)
    public enum ControlObserveGrantApprovalDecision: Equatable, Sendable {
      case allowOnce
      case allowWhileBothSessionsLive
      case deny
    }
    public protocol ControlObserveGrantApprovalDelegate: AnyObject, Sendable { ... }

The requester attribution row is transport-specific (FINDING 2). On the
lazy CLI transport, where the upward chain walk is live-verified, the sheet
renders the familiar chain row ("Chain: Codex -> laban helper"). On a held
broker connection, where the real requester below the brokered agent is not
verifiable, the sheet must NOT render a chain row that implies
verification; it renders instead:

    Via: Requested via broker from within Codex's process tree
         (exact requester not verifiable)

The "Data:" row states what the grant actually unlocks: "Viewport text,
selection, find state, and scrollback line counts of the target". It must
NOT say "scrollback text", because `session.detail` returns viewport grid
text (capped) plus scrollback line counts only. Callout: if a future
scrollback-text read (for example the planned `session.getText`) ever joins
`crossSessionObserveGrantIntentIDs`, this row's wording MUST change in the
same diff, and existing standing grants must not silently widen (a set
change invalidates active grants; see Milestone 1).

All strings that originate outside Laban (title, purpose, process name,
cwd) are rendered under the C15 safe-rendering contract: byte-exact with
visible escaping of control, newline, C1, and Unicode bidi characters,
length caps, no ANSI interpretation. Only the session id suffix comes from
Laban's own registry and is the one Laban-authoritative anchor; cwd and
process name are contextual hints an attacker can shape (threat (c)). The
same escaping applies to every other surface that renders these strings:
the Settings "Cross-Session Observation" rows and the per-tab badge and
its hover text (NOTE 6), so a crafted title cannot misrender which grant a
Revoke button belongs to.

### Indicator on both tabs

While a standing grant is active, the agent-attached indicator must reflect
it on BOTH sessions' tabs, continuously (not TTL-decayed):

- `ControlSecurityCoordinator` gains grant lifecycle callbacks (new methods
  on `ControlSecurityObserver` with default no-op implementations so
  existing conformers compile): `didObserveGrantCreate`,
  `didObserveGrantUse`, `didObserveGrantExpire`, `didObserveGrantRevoke`.
- On create, the coordinator pins the indicator active (bypassing the
  30-second TTL) and records the pair (source, target); on expire/revoke of
  the last active grant, the TTL behavior resumes.
- Per-tab: both the source and the target tab show a per-tab observation
  badge naming the counterpart ("Observed by Codex (tab c2yt)" on the
  target; "Observing tab build" on the source). Implementation detail is
  Milestone 3; the acceptance is behavioral: with a standing grant active, a
  user looking at EITHER tab can see it, and hovering names the principal
  and the counterpart session.
- Every grant-widened read additionally emits the normal privileged-read
  audit and indicator arming (a grant never makes reads quieter).

### Audit events

Via `ControlSecurityCoordinator` to the persistent `EventLog`, following the
`control.attach.*` naming:

- `control.observeGrant.requested` (principal display name, signing
  fingerprint, source session id suffix, target session id suffix)
- `control.observeGrant.approved` (mode: `once` or `standing`, grantID)
- `control.observeGrant.denied` (reason)
- `control.observeGrant.autoApproved` (grantID; emitted when a standing
  grant satisfies a lazy one-shot request without UI)
- `control.observeGrant.used` (grantID, intent id, target session id suffix;
  every cross-session read, threat (e)). The recorded target is the shared
  policy-resolved effective target, the same value that scoped the
  dispatch, so the audit trail cannot assert a cross-session read that did
  not occur (FINDING 1).
- `control.observeGrant.expired` (grantID, which side died)
- `control.observeGrant.revoked` (grantID)

No payload ever contains tokens, terminal text, full executable paths beyond
the display-safe name, environment values, or the caller-provided purpose
text.

### Settings

`SettingsWindowController` gains a "Cross-Session Observation" list next to
the existing approvals list (`makeApprovalsListView` pattern): one row per
grant record showing principal display name, source and target (title +
id suffix at record time), created date, state (active / expired / revoked),
and a Revoke button for active ones. Revoke removes the in-memory grant
immediately (the very next read gets `403 grantRevoked`) and stamps
`revokedAt` on the mirror record. Titles rendered in these rows are
attacker-influenceable strings recorded at approval time and render under
the C15 escaping rules (see "The sheet"), so a crafted title cannot
misalign a Revoke button with a different grant.

## Threat Analysis

A fresh security reviewer must read this section and either accept it or
record findings in the Review Gate before any implementation milestone
starts.

**(a) Prompt fatigue / dialog spam.** An agent (or a malicious descendant)
could hammer the request endpoint hoping the user clicks Allow to make the
dialogs stop. Mitigations: the shared one-visible-prompt queue; one pending
request per (principal, source, target); two-second dedup window (`429`);
the shared global cap of eight; the 60-second deny cooldown per (principal,
source, target) that returns `429 approvalDenyCooldown` without UI. Residual
risk: a patient agent can re-ask once a minute; the dialog names the
principal each time, and repeated denials are visible in the audit log.
Accepted for MVP; a future escalation (auto-mute after N denials) is noted
as an open follow-up, not built. Queue-sharing residual (NOTE 8), also
accepted for MVP: grant prompts share the single visible-prompt queue and
the global pending cap of eight with lazy-attach prompts, so a flood of
lazy-attach requests can starve grant requests into `429`/timeout, and vice
versa. This fails closed (starvation denies, never approves) and is
user-visible in diagnostics and audit.

**(b) Confused deputy: a compromised child of the agent requests grants.**
Example: a malicious npm postinstall running under Codex requests a grant;
the chain `shell -> codex -> npm -> laban` derives principal = Codex, so the
dialog names Codex, and the user may approve believing Codex asked. Which
chain must hold, explicitly: the requesting peer must be a same-uid process
whose fresh ancestry walk reaches exactly one registered session shell (the
source), every identity in the chain must carry a start time, and the
principal is the nearest non-helper, non-generic, stable process between
shell and peer (upward rule), or the brokered agent child of `laban-agent`
(downward rule, held connection). This is the same attribution limit lazy
attach already accepts: within one session's process tree, Laban cannot
distinguish the agent from code the agent ran. The boundary is the session
and the human; the mitigations are (1) on the lazy CLI transport, the
dialog shows the live-verified chain, so `Codex -> npm -> laban helper` is
visibly different from `Codex -> laban helper`, (2) the grant is
observe-only and revocable, (3) a standing grant binds to the principal
fingerprint AND signing requirement, so a directly spawned unsigned binary
cannot ride a Codex grant, and (4) every use is audited. Mitigation (1)
does NOT exist on the held broker transport (first review round,
FINDING 2): the broker proxy accepts any descendant of the allowed root pid
and forwards requests without conveying the requesting descendant's
identity, so requester attribution below the brokered agent is IMPOSSIBLE
there; a malicious tool subprocess's request and Codex's own request reach
Laban identically. Consequently the sheet must not render a chain row that
implies verification on that transport; it renders "Requested via broker
from within Codex's process tree (exact requester not verifiable)" (see
"The sheet"). A future revision MAY have the proxy forward the requesting
descendant's pid and start time as display-only enrichment; explicitly
non-MVP, and never authorization input. Residual risk accepted and stated,
covering both transports: descendants of the granted principal inside the
source session share its widened read scope for the grant's lifetime, and
on the broker transport the human approves the principal's whole process
tree, not a specific requester.

**(c) Title spoofing to trick the user into granting the wrong tab.** A
program in tab C can set its own title to `build` (OSC title escape) hoping
the user grants tab C instead of tab B, or an attacker-set title can contain
control characters or bidi overrides to misrender the dialog. Mitigations:
title selectors resolving to more than one session fail with
`targetAmbiguous` (never pick one); the dialog shows Laban's own identity
for the resolved target (title + session id suffix + cwd + foreground
process) so a `build`-titled tab whose cwd is `/tmp/evil` and process is
`curl` is visibly wrong; titles and purpose render under the C15
safe-rendering rules (extended to the Settings rows and the per-tab badge
hover text, NOTE 6); and the grant binds to the session id resolved at
approval time, never re-resolved by title, so post-approval title swaps
change nothing. Residual, stated explicitly (NOTE 4): cwd and foreground
process name are ALSO attacker-influenceable (a program in the attacker's
tab can chdir to any readable path and exec a binary named `ninja`), so of
the four rows only the session id suffix is Laban-authoritative, and the
user has no independent way to bind a suffix to a visible tab in the MVP.
The practical harm of a successful misdirection is bounded: the agent
observes attacker-chosen content, which is observed-content injection
toward the agent, a hazard that exists for ANY observed session (a
legitimately granted target can also print manipulative text). It never
grants the attacker's tab any authority. Accepted for MVP; a
future "reveal target tab" affordance (flash or focus-highlight the target
tab from the dialog) is noted as a follow-up, not built.

**(d) TOCTOU between approval and read.** The session behind the dialog may
be replaced (tab closed and reopened, shell exited, PID reused) between the
user's click and the dispatch, or between grant creation and a later read.
Mitigations: immediately before every dispatch or grant-widened
authorization, the server revalidates, fresh: peer identity (pid + start
time), ancestry to the source shell, source shell identity fingerprint,
target shell identity fingerprint, grant liveness, and (for Allow Once) the
exact request constraint. Any mismatch during the approval window returns
`409 sessionChanged`; any mismatch at read time kills the grant and returns
`403 grantExpired`. Start times are mandatory everywhere (PID reuse is
rejected); missing start time fails closed with
`403 processIdentityUnavailable`.

**(e) Exfiltration surface widening.** A grant is a real widening: an agent
that could read one session can now read two, and target-session content may
include secrets. Mitigations: the read set is fixed and small (five query
intents, no logs, no screenshots, no clipboard, no keystroke log); every
cross-session read emits `control.observeGrant.used`; the indicator is
pinned on BOTH tabs for the grant's lifetime so a user working in the
observed tab can see it; the grant list is visible in Settings with one-click
revocation; lifetime is bounded (G3); and the default (no grant) is
unchanged. The design intentionally has no "all sessions" and no
survives-restart option, so the maximum blast radius of one approval is one
session pair for one app run.

**(f) Why the HMAC on records is tamper evidence, not a boundary.** The
grant mirror records (like the lazy-attach approval records) are HMAC-signed
with a key file that is readable by any same-user process
(`ControlAttachApprovalRecordFileSigner`'s key under Application Support).
A same-user attacker can read the key and forge a validly signed record, so
the signature only detects casual corruption and cross-write accidents; it
cannot prove a record came from a human approval. Implication, and the
load-bearing design consequence: persisted grant records are NEVER
authoritative (G6). Authorization consults only the in-memory table, which
is populated exclusively by the approval delegate flow inside the Laban
process and is bound to the current runID. A forged UserDefaults record
grants nothing; at worst it pollutes the Settings list, which the runID
sweep marks expired at next launch. (The same-user attacker who could forge
records could also read the key file, screen-record with OS permission, or
debug the process; the OS same-user model is the outer boundary. Laban's
job is to not add a forgeable persistent authority on top of it, and this
design does not.)

## Explicit Non-Goals

- No all-sessions grant. One grant names exactly one target session.
- No grant that survives app restart, under any option.
- No cross-session navigation, proposals, or input, ever, in this plan.
  Actuation of any kind stays deferred to the Terminal-Lease /
  Computer-Use ADR (program doc §6 Phase 7).
- No auto-grant policy (no "always allow Codex to observe anything", no
  config file that pre-approves grants, no headless auto-approval outside
  the explicitly test-gated hooks).
- No MCP exposure of the grant request or grant-widened reads in this phase.
- No changes to the C14 attach handshake, the broker, or the lazy-attach
  allowlist semantics for own-session operations.

## Milestones

### Milestone 0: Design review (this document is the deliverable). Status: FIRST ROUND DONE, REVISED, SECOND ROUND PENDING

Scope: this plan, reviewed by a fresh-state security reviewer per Review
Gate item 0. No code. Acceptance: the reviewer accepts the threat analysis
or records findings; findings are folded into this document; the Decision
Log records any change of course. Implementation may not start before this
passes. First round (2026-07-09, commit 35d32e0): NOT PASSED with three
findings and eight notes, recorded verbatim in the Review Gate section.
This revision folds all of them in; a second fresh-state round must now run
against the revised text.

### Milestone 1: Grant model and policy (LabanControl). Status: NOT STARTED

Scope: pure types plus policy, no UI, no routes. What exists at the end:
`ControlSessionObserveGrant` and `ControlSessionObserveGrantStore` (files
named above), the `sessionObserveGrantsByID` table with the seven-point
validity check and expiry sweep in `LabanControlServer`, the
`crossSessionObserveGrantIntentIDs` constant, the
`grantedSessions:` parameter threaded through
`LabanControlPolicy.authorize` and its call sites, and the shared target
resolution (FINDING 1): the policy-resolved effective target flows into the
dispatch context, so `legacyQueryInput`'s `scopedSessionID` becomes the
granted target when and only when a grant authorized an explicit
cross-session target, and the audited target is the same value. (Because
`crossSessionObserveGrantIntentIDs` is compiled in and no grant survives
restart, a change to the set can never widen an existing standing grant;
new set, new build, no surviving grants.)

Same-change documentation and invariant-suite amendments (FINDING 3, per
the "Rules for changes" in `docs/process/control-plane-threat-model.md`):
in the same commits that land this milestone, amend that document so I2
gains the grant exception with its exact conditions (an explicit
cross-session target is allowed only when a live in-memory grant matches
the (principal, source session, target session) tuple, the intent is in
`crossSessionObserveGrantIntentIDs`, both registered shell identities are
live with matching start times, and the runID matches; everything else
still denies), and add a new invariant I8: grants widen only the fixed read
set for one (principal, source session, target session) tuple and die with
either shell death, revocation, or runID change. Update
`Tests/LabanControlTests/ControlPlaneInvariantTests.swift` in the same
commits (extend `testSessionScopeDeniesCrossSessionOnAllTiers` for the
grant exception; add an I8 test), naming this review per that document's
rules.

Tests (new suite `CrossSessionObserveGrantPolicyTests` in
`Tests/LabanControlTests/`): deny-without-grant is byte-identical to today
(explicit other target `403`); grant-scoped allow for each of the five
intent ids; a granted target with a non-listed intent (for example
`terminal.scrollViewport`, `command.propose`, `log.terminal`) denies;
omitted target still resolves to own session even with a grant active;
grant for principal P does not widen principal Q; source-shell death,
target-shell death, runID mismatch, and revocation each kill the grant;
mirror records without an in-memory entry grant nothing; and the mandatory
named test `testGrantedReadPayloadSessionEqualsAuditedTarget`: for each of
the five grant intents, dispatch a granted cross-session read and assert
the dispatched payload's session id equals the audited target session id
(this is the FINDING 1 regression test; it must exercise the
query/body target keys `sessionID`, `sessionId`, `targetSessionID`,
`targetSessionId` that `resolveTargetSession` honors).

Acceptance: `swift test --disable-sandbox --filter
CrossSessionObserveGrantPolicyTests` exits 0; `swift test --disable-sandbox
--filter ControlPlaneInvariantTests` exits 0 with the I2/I8 updates; `swift
test --disable-sandbox --filter LabanControlTests` exits 0.

### Milestone 2: Request endpoint, target resolution, approval flow. Status: NOT STARTED

Scope: the `session.requestObserveGrant` catalog descriptor (and the 2C
`.propose` allowlist test update), the
`POST /control/session/observe-grant/request` route and the
`POST /debug/actions` action `requestObserveGrant` on the held connection,
title/sessionID target resolution with the ambiguity codes, the
`ControlObserveGrantApprovalDelegate` protocol with an injectable fake for
tests, Allow Once dispatch via `.approvedSession` with constraint binding
(no `grantedSessions` involvement; the shipped policy already covers this
path, NOTE 7), standing-grant creation with server-side persistability
validation, the coalescing/rate-limit/deny-cooldown rules, and the
downward principal step for broker connections (with the FINDING 2
transport-specific attribution row, never an implied-verified chain).

Same-change documentation and invariant-suite amendments (FINDING 3): in
the same commits that land this milestone, amend
`docs/process/control-plane-threat-model.md` so I7's gui `.propose` set
becomes `{command.propose, session.requestObserveGrant}`, and update
`testGuiCatalogFloorHasNoActuationAndExactAllowlists` in
`Tests/LabanControlTests/ControlPlaneInvariantTests.swift` (and the
`Tests/LabanAppTests/CatalogParityTests.swift` assertion it mirrors) in
those same commits, naming this review per that document's rules.

Tests (`CrossSessionObserveGrantRequestTests`): fake delegate allowOnce
dispatches exactly the intended read against the target and returns the
downstream body; the one-shot cannot be replayed, retargeted, or reshaped
(constraint mismatch fails); deny returns `403 userDenied` and arms the
cooldown (`429 approvalDenyCooldown` inside 60 s); timeout returns `408`;
identity change mid-approval returns `409 sessionChanged`; `targetNotFound`,
`targetAmbiguous` (two tabs titled `build`), `targetIsOwnSession`; a fake
delegate answering allowWhileBothSessionsLive for a generic-interpreter or
unsigned principal creates NO record and NO table entry; missing start time
anywhere returns `403 processIdentityUnavailable`; broker-held connection
derives the brokered agent, not `laban-agent`, as principal; no token,
purpose text, or terminal text appears in any audit payload or error string.

Acceptance: the new suite exits 0; `swift run LabanControlGen --check`
passes after regenerating discovery for the new descriptor.

### Milestone 3: Sheet, dual-tab indicator, Settings, audit. Status: NOT STARTED

Scope: `ControlObserveGrantApprovalPresenter` (AppKit, per the shipped
NSAlert accessory sizing pattern), the C15-safe rendering of title, purpose,
process name, and cwd on the sheet AND on the Settings rows AND on the
per-tab badge hover text (NOTE 6), the transport-specific attribution row
(FINDING 2), the `ControlSecurityObserver` grant callbacks and pinned
indicator behavior, per-tab observation badges on source and target, the
Settings "Cross-Session Observation" list with Revoke, and the seven
`control.observeGrant.*` audit events.

Tests: presenter rendering tests for a persistable principal (three
buttons), a generic interpreter (no standing button, reason shown), and a
title containing `ESC[`, newline, and a bidi override (rendered escaped,
byte-exact, and the dialog also shows id suffix + cwd + process: the
title-spoof dialog content test); a broker-transport rendering test
asserting the sheet contains the "Requested via broker ... (exact requester
not verifiable)" row and NO chain row implying verification; a Settings-row
and badge-hover escaping test with the same hostile title; revocation makes
the next read fail `grantRevoked`; audit tests prove no tokens/paths/
purpose text in payloads; an indicator test proves the pin outlives the
30-second TTL while a grant is active and decays after expiry.

Acceptance: `swift test --disable-sandbox --filter LabanAppTests` includes
the new tests and exits 0; a manual run shows both tabs badged during a
standing grant.

### Milestone 4: CLI verbs and installed end-to-end. Status: NOT STARTED

Scope: `laban session observe-grant request --target-session ID |
--target-title TITLE [--purpose TEXT] [--json]` and `laban session detail
--session ID --json` (mapping to `GET /debug/sessions/<id>`); exit codes
follow the lazy-attach mapping (0 success, 3 unavailable, 4 timeout, 5
denied/ineligible/changed/expired, 6 protocol); stderr progress line
`laban: waiting for Laban approval to observe session ...4B2` while the
sheet is up; an installed smoke script
`scripts/test-installed-observe-grant` (test-gated auto-approve hook, DEBUG
only, per the shipped lazy-attach pattern) that runs the two-tab scenario
and prints `OBSERVE_GRANT_INSTALLED_SMOKE_OK`; and the operator-guide
section in `docs/process/controlling-agent-control-plane.md` (asking flow,
dialog meaning, revocation, lifetime rules).

Acceptance: the manual scenario from Purpose works verbatim on an installed
build; deny and revoke behave as described; `./scripts/check` exits 0.

## Validation and Acceptance

Design phase (now): Review Gate item 0 below is the only check.

Implementation phase (later), from the repo root:

    swift test --disable-sandbox --filter CrossSessionObserveGrantPolicyTests
    swift test --disable-sandbox --filter CrossSessionObserveGrantRequestTests
    swift test --disable-sandbox --filter ControlPlaneInvariantTests
    swift test --disable-sandbox --filter LabanAppTests
    swift run LabanControlGen --check
    ./scripts/lint
    ./scripts/check
    ./scripts/build-app

Behavioral acceptance, phrased as observations:

- With no grant, `laban session detail --session <other-id> --json` from an
  attached agent exits 5 and the server logs a plain `403` denial: identical
  to today.
- After "Allow While Both Sessions Live", the same command returns the
  target's session detail JSON whose session id IS the target's (the
  FINDING 1 payload-session == audited-target property, also asserted by
  `testGrantedReadPayloadSessionEqualsAuditedTarget`); both tabs show the
  observation badge; the EventLog contains `control.observeGrant.approved`
  and one `control.observeGrant.used` per read naming that same target.
- Closing EITHER tab, restarting Laban, or clicking Revoke in Settings makes
  the next read exit 5 with `grantExpired`/`grantRevoked` in the diagnostic.
- After "Allow Once", exactly one read succeeds and the next one prompts
  again.
- Two tabs titled `build` make a title-selector request fail with
  `targetAmbiguous` and no dialog.
- Denying, then immediately re-requesting, returns `429 approvalDenyCooldown`
  with no second dialog inside 60 seconds.
- No token value, purpose text, or terminal text appears in any log or audit
  payload (grep both minted tokens and a sentinel purpose string: zero hits
  outside `control.json`).

## Review Gate

A separate agent (or human) with fresh state must verify these. The
executing agent must not mark this plan done until the gate passes. Item 0
gates all implementation; items 1+ apply once the corresponding milestone
claims completion.

- [x] **0. Design review (NOW, before any implementation).** A fresh
  security reviewer reads the "Threat Analysis" section of this file and
  either (a) records "threat analysis ACCEPTED" with a date here, or (b)
  records concrete findings (threat, scenario, affected section) in this
  section. Implementation milestones may not start until (a) is recorded.
  The reviewer must explicitly confirm each of: the (a)-(f) threats are
  addressed or their residual risk is explicitly accepted in the text; G1
  through G7 are internally consistent with the mechanisms described; the
  five-intent grant read set contains no write, navigate, propose, input,
  or fixture intent. Second round (after the 2026-07-09 revision): also
  confirm the three first-round findings and eight notes recorded below are
  each resolved by the revised body text.
  threat analysis ACCEPTED 2026-07-09, second round (content commit
  3782a3f, fresh-state security review).
- [ ] `rg -n "crossSessionObserveGrantIntentIDs" Sources/LabanControl/LabanControlPolicy.swift`
  shows exactly the set `{session.detail, selection.read, find.state,
  shellIntegration.state, scrollIndicator.state}`; adding any id requiring
  `.navigate`, `.propose`, `.input`, or `.fixture` to the set makes a policy
  test fail (mutate the constant to add `terminal.scrollViewport`, run
  `swift test --filter CrossSessionObserveGrantPolicyTests`, expect failure,
  revert).
- [ ] `rg -n "grantedSessions" Sources/LabanControl/LabanControlPolicy.swift`
  shows the parameter defaults to an empty set, and the own-session
  defaulting line (`targetSession ?? ownSessionID`) is unchanged (C12: an
  omitted target never resolves to a granted or active session).
- [ ] Policy tests: explicit other-session target without a grant `403` for
  every `.observeSensitive` gui intent; with a grant, exactly the five ids
  allow and `terminal.scrollViewport`/`command.propose`/`log.terminal`
  against the target still `403`; a grant for principal P never authorizes
  principal Q (run the suite; all named cases present and green).
- [ ] Expiry tests: killing the source shell, killing the target shell,
  changing either shell's start time (PID-reuse simulation), a runID
  mismatch, and revocation each make the next grant-widened read fail; the
  in-memory entry is removed and the mirror record is stamped.
- [ ] Restart invalidation: a persisted mirror record with a stale `runID`
  is marked expired by the startup sweep and grants nothing even when both
  shell fingerprints still match (labpty-survival case): covered by a named
  test.
- [ ] `rg -n "sessionObserve\(sessionID: *(target|grant)" Sources Tests`
  returns nothing: no code path mints `.sessionObserve` for a target
  session; grant widening rides `grantedSessions` or `.approvedSession`
  only.
- [ ] Forged-record test: a record written directly to
  `LabanControlSessionObserveGrantRecordsV1` (validly HMAC-signed using the
  same signer) with no matching in-memory entry does not authorize any read.
- [ ] Title-spoof dialog content test: a presenter test feeds a target whose
  title is `build\n\u{202E}ESC[2Jevil` and asserts the rendered sheet
  contains the escaped title, the session id suffix, the cwd, and the
  process name rows (all four present), with copy-safe byte-exact rendering.
- [ ] `targetAmbiguous` test: two sessions titled `build` cause the
  title-selector request to return `409 targetAmbiguous` before any
  delegate/UI call.
- [ ] Rate-limit tests: duplicate request inside 2 s `429
  approvalRateLimited`; request after Deny inside 60 s `429
  approvalDenyCooldown` with no delegate call; ninth concurrent pending
  request rejected.
- [ ] Persistability tests: a fake delegate returning
  allowWhileBothSessionsLive for `node`, `zsh`, an unsigned binary, an
  ad-hoc binary, `laban`, and `laban-agent` creates no store record and no
  in-memory grant.
- [ ] Audit no-secret tests: grep the EventLog fixture output for the
  app-observe token, any minted credential, `LABAN_SESSION_ATTACH`, a
  sentinel purpose string, and a sentinel terminal-text string: zero hits;
  `control.observeGrant.used` is emitted once per cross-session read in the
  test scenario.
- [ ] Indicator test: with a standing grant active, the indicator remains
  active past `ControlSecurityCoordinator.privilegedActivityTTL` (30 s) and
  both source and target tabs expose the observation badge state; after
  revocation it decays.
- [ ] The 2C positive allowlist test now asserts the `gui:true` `.propose`
  set equals exactly `{command.propose, session.requestObserveGrant}` and
  the `.navigate` set is still exactly `{terminal.scrollViewport}`.
- [ ] Shared target resolution (FINDING 1): `swift test --disable-sandbox
  --filter
  CrossSessionObserveGrantPolicyTests/testGrantedReadPayloadSessionEqualsAuditedTarget`
  exits 0, and the test body covers all five grant intents and all four
  target keys (`sessionID`, `sessionId`, `targetSessionID`,
  `targetSessionId`); mutate the dispatch wiring so `scopedSessionID` stays
  pinned to the source on a granted request, rerun, expect failure, revert.
- [ ] Broker attribution row (FINDING 2): a presenter test proves that on a
  held broker connection the sheet renders the "Requested via broker from
  within <Principal>'s process tree (exact requester not verifiable)" row
  and renders NO "Chain:" row; on the lazy CLI transport the chain row is
  present. `rg -n "not verifiable" Sources/LabanApp/Control` returns the
  presenter hit.
- [ ] Standing invariants moved in the same change (FINDING 3, Milestone 1):
  `rg -n "I8" docs/process/control-plane-threat-model.md` shows the new
  grant invariant; the I2 text names the grant exception and its conditions
  (live in-memory grant, tuple match, intent set, both shell identities,
  runID); `git log --follow -1 --name-only` for the commit that introduced
  `grantedSessions` also lists `docs/process/control-plane-threat-model.md`
  and `Tests/LabanControlTests/ControlPlaneInvariantTests.swift`; `swift
  test --disable-sandbox --filter ControlPlaneInvariantTests` exits 0.
- [ ] Standing invariants moved in the same change (FINDING 3, Milestone 2):
  `rg -n "session.requestObserveGrant" docs/process/control-plane-threat-model.md`
  shows I7's updated propose set; the commit that adds the
  `session.requestObserveGrant` descriptor also touches that document and
  `ControlPlaneInvariantTests.swift`
  (`testGuiCatalogFloorHasNoActuationAndExactAllowlists` updated).
- [ ] Settings and badge escaping (NOTE 6): a test feeds the hostile title
  from the title-spoof test into a grant record and asserts the Settings row
  string and the badge hover string render it escaped, byte-exact.
- [ ] `swift run LabanControlGen --check` passes; `./scripts/lint` exits 0;
  `./scripts/check` exits 0; `git diff --check` exits 0.

Review status: item 0 PASSED, second round (2026-07-09, content commit
3782a3f, fresh-state security review); threat analysis ACCEPTED.
Items 1+ remain open pending their milestones. The first-round record
below (2026-07-09, commit 35d32e0, item 0 NOT PASSED, three findings,
eight notes) is kept verbatim; the body was revised to fold every finding
and note in, per the Decision Log entries dated 2026-07-09 (Fable
orchestrator per review), and the second round verified each resolution
against the revised text and the cited sources.

Review findings (filled in by the review agent):

Fresh-state security review of item 0, 2026-07-09, against commit 35d32e0.
Confirmations item 0 requires:

- Threats (a) through (f): (a), (d), (e), and (f) are addressed or their
  residual risk is explicitly accepted in the text. (b) is not fully accepted
  as written; its stated mitigation (1) does not exist on the held broker
  transport (FINDING 2). (c) is addressed; see NOTE 4 for an unstated
  residual.
- G1 through G6 internal consistency: fails on two contradictions between
  sections and against the standing invariants document (FINDING 1,
  FINDING 3); otherwise the constraints match the mechanisms described.
- Five-intent grant read set, verified against
  `Sources/LabanCore/Intents/IntentCatalog.swift` (not the plan's claims):
  all five ids exist, all are `kind: .query` with `availability: guiObserve`
  (gui-available); `requiredCapability` is `.observeSensitive` for
  `session.detail`, `selection.read`, `find.state`, `shellIntegration.state`
  and `.observe` for `scrollIndicator.state`; `dataSensitivity` is
  `.visibleText` for `session.detail`, `selection.read`, `find.state` and
  `.nonSensitiveState` for the other two. No write, navigate, propose,
  input, or fixture intent is in the set. PASS.

FINDING 1: Policy target and dispatch target are resolved by different code,
and `selection.read` cannot target another session at all. Scenario: with a
standing grant for TARGET, a source-bound `.sessionObserve` credential sends
`GET /debug/selection?sessionID=TARGET`. The proposed policy check uses
`LabanControlServer.resolveTargetSession` (which reads `sessionID`,
`sessionId`, `targetSessionID`, `targetSessionId` from query and body) and
allows the request, but the dispatched projection
`ControlStateProjections.selectionResponse` takes no session parameter and
reads `ctx.scopedSessionID`, which `legacyQueryInput` pins to the SOURCE
session for a `.sessionObserve` credential. The read returns source-session
data while `reportAuthorize` and the planned `control.observeGrant.used`
event record a cross-session read of TARGET that never happened. The same
mismatch class exists for `find.state`, `shellIntegration.state`, and
`scrollIndicator.state` when the caller uses the
`targetSessionID`/`targetSessionId` keys, which `resolveTargetSession`
honors but the projections ignore. (Allow Once is unaffected because
`.approvedSession` is bound to the TARGET, so `scopedSessionID` becomes the
target.) Affected sections: "What a Grant Unlocks" (the claim that the five
reads are "applied to the target"), "Audit events", Milestone 1. Why the
design as written fails: `selection.read` has exactly the property (an
active-session-shaped projection with no explicit session-target parameter)
that the plan itself uses to exclude `app.accessibility`, so the grant set
contradicts its own exclusion rationale, and the audit trail, a core
threat (e) mitigation, would assert cross-session reads that did not occur.
Fix direction: drop `selection.read` from the MVP set, or specify one shared
target resolver used by both the policy check and the dispatch (for example,
the server passes the policy-resolved target into `legacyQueryInput` as the
scoped read target when a grant authorized it), plus a test asserting the
dispatched payload's session equals the audited target.

FINDING 2: Threat (b) mitigation (1) does not exist on the held broker
connection. Scenario: `laban agent run -- codex` exposes
`LABAN_AGENT_CONTROL_URL` to the agent child and every descendant
(`Sources/LabanAgent/ControlAttachProxyServer.swift` accepts any descendant
of the allowed root pid and forwards requests without conveying the
requesting descendant's identity). A malicious tool subprocess posts
`requestObserveGrant` through the proxy; Laban's UDS peer is `laban-agent`,
and the planned downward principal step attributes the request to the agent
child recorded at broker launch, so the sheet shows
`Chain: Codex -> laban helper` even though npm-postinstall-level code asked.
The threat (b) text claims "the dialog always shows the full helper chain so
`Codex -> npm -> laban helper` is visibly different from
`Codex -> laban helper`"; on this transport that is false, because the
chain Laban can verify never contains the real requester. Affected sections:
"Threat Analysis (b)", "The Asking Flow / Transports" item 1, Decision Log
entry "downward principal step". Why the design as written fails: item 0
requires each threat's residual risk to be explicitly accepted in the text,
and (b)'s acceptance is premised on a chain-display mitigation that one of
the two supported transports cannot deliver, so the accepted residual is
understated. Fix direction: extend the (b) residual acceptance to state that
on a held broker connection requester attribution below the brokered agent
is impossible and the chain row degrades to principal plus helper, or have
the proxy forward the requesting descendant's pid and start time so Laban
can render a live-verified chain (display only, never authorization).

FINDING 3: The design contradicts standing invariants I2 and I7 in
`docs/process/control-plane-threat-model.md` and does not schedule their
amendment. Scenario: I2 states that for a session-bound credential "a
request targeting another session is denied for every capability in
{observeSensitive, navigate, propose}"; the `grantedSessions` widening makes
that statement false for `.observeSensitive` the moment Milestone 1 lands.
I7 states the gui `.propose` set is exactly `{command.propose}`; the
`session.requestObserveGrant` descriptor in Milestone 2 breaks it. That
document's "Rules for changes" section explicitly requires a fourth trust
derivation (naming a cross-session observe grant as its example) to add its
invariants to the document and to the invariant suite in the same change
that lands the mechanism. This plan updates the 2C catalog parity test but
never mentions `control-plane-threat-model.md` or the invariant suite.
Affected sections: Milestones 1 and 2, "Design Constraints" (G1). Why the
design as written fails: the constraints are presented as consistent with
the standing control-plane invariants, but shipping the plan as written
leaves I2 and I7 asserting properties the code no longer has, which is the
cross-path drift that document exists to prevent. Fix direction: add to
Milestones 1 and 2 the matching edits to
`docs/process/control-plane-threat-model.md` (I2 gains the grant exception
with its conditions, I7's propose set gains `session.requestObserveGrant`,
and a new invariant states that grants widen only the five-intent read set
for one principal/source/target pair and die with either shell, revocation,
or runID change) plus the corresponding invariant-suite updates, naming this
review per that document's rules.

NOTE 1: "Context and Orientation" describes the grant family as the
`gui: true` `.observeSensitive` query intents "plus two `.observe`-tier
state queries"; only `scrollIndicator.state` is `.observe`
(`shellIntegration.state` is `.observeSensitive` in the catalog). The count
is one, not two.

NOTE 2: The sheet's "Data:" row says "Visible terminal text and scrollback
of the target", but `session.detail` returns viewport grid text (capped at
2,000 cells) plus scrollback line counts, not scrollback text. Overstating
is the safe direction, but the row should state what the grant actually
unlocks, and must be revisited if a future `session.getText` joins the set.

NOTE 3: `ControlSessionObserveGrant.signingRequirement` is commented "empty
only for one-shot grants", but one-shot grants are never retained in the
table ("Nothing persists"). Drop the comment or state that one-shots never
construct the type.

NOTE 4: Threat (c) presents target cwd and foreground process as anchors,
but both are attacker-influenceable (a program in the attacker's tab can
chdir to any readable path and exec a binary named `ninja`); only the
session id suffix is Laban-authoritative, and the user has no independent
way to bind a suffix to a visible tab. The practical harm of misdirection is
observed-content injection toward the agent, which exists for any observed
session; state this residual explicitly.

NOTE 5: "Transports" item 2 says the lazy request body carries the intended
read "optionally", while the request-body paragraph says `intendedRequest`
"is required on the lazy transport". Align the wording.

NOTE 6: The C15 safe-rendering requirement is stated for the sheet only. The
Settings "Cross-Session Observation" rows and the per-tab badge/hover text
also render attacker-influenceable titles recorded at approval time; extend
C15 (or at least control/bidi escaping) to those surfaces so a crafted title
cannot misrender which grant a Revoke button belongs to.

NOTE 7: `scrollIndicator.state` requires only `.observe`, and the shipped
`authorize` gives app-observe tokens `.wholeApp` scope, so any `control.json`
holder can already read it for any session today; its inclusion in the grant
set is redundant but harmless. Separately, Allow Once needs no Milestone 1
policy change at all: `.approvedSession(sessionID: TARGET)` passes the
shipped `authorize` via scope `.session(TARGET)` plus constraint binding.
The plan is consistent with this but never states it; saying so keeps
Milestone 2's one-shot path from appearing to depend on `grantedSessions`.

NOTE 8: Grant prompts share the single visible-prompt queue and the global
pending cap of eight with lazy attach; a flood of lazy-attach requests can
starve grant requests into `429`/timeout, and vice versa. This fails closed
and is user-visible, acceptable for MVP.

## Decision Log

- Decision: Model cross-session observe as a scope widening
  (`grantedSessions` on the authorize call) rather than a new `Capability`
  enum case such as `crossSessionObserve`.
  Rationale: Capability answers "which verb", scope answers "whose session".
  The verb is unchanged (`.observeSensitive` reads); only the session set
  widens, and only for a fixed intent list. A new capability would force
  dual classification of every read descriptor and blur the Phase 2
  orthogonality of requiredCapability x dataSensitivity x scope. The intent
  allowlist plus the grants set gives the same enforcement with a smaller
  policy diff and a greppable single constant.
  Date/Author: 2026-07-09 / Claude.

- Decision: Grants are authoritative only in the server's in-memory table,
  bound to the control server runID; UserDefaults records are an advisory
  mirror for Settings and audit continuity.
  Rationale: Two independent forcing facts. First, the HMAC key is
  same-user readable, so persisted records are forgeable by any same-user
  process and must not carry authority (threat (f)). Second, "no grant
  survives app restart" cannot be enforced by shell-identity fingerprints
  alone, because labpty keeps shells (same pid, same start time) alive
  across GUI restarts (observed during lazy-attach dogfooding); the runID
  binding kills grants across restart even when both shells survive.
  Date/Author: 2026-07-09 / Claude.

- Decision: Allow Once reuses the shipped `.approvedSession` one-shot
  dispatch bound to the TARGET session with a full `ControlTokenConstraint`,
  rather than minting any short-lived cross-session token.
  Rationale: The user approves one specific read of one specific session; a
  token, however short-lived, is replayable authority broader than what was
  approved. The approved-dispatch pattern already exists, already carries
  request-exact binding (method, path, query, body hash, route, intent), and
  already has the pre-dispatch revalidation and `409 sessionChanged`
  semantics this needs.
  Date/Author: 2026-07-09 / Claude.

- Decision: The standing-grant button reads "Allow While Both Sessions
  Live" and its lifetime is tied to BOTH registered shell identities plus
  the runID, expiring on whichever ends first.
  Rationale: Either endpoint dying changes what the user approved: a new
  shell in the target tab is new content the user never showed the agent,
  and a new source shell may be a different agent. Both-sides expiry keeps
  the mental model "this Codex, watching that build, this run" honest.
  Date/Author: 2026-07-09 / Claude.

- Decision: Title selectors are a request-time convenience only; resolution
  happens server-side against Laban's registry, ambiguity fails closed
  (`targetAmbiguous`), and the grant binds to the resolved session id at
  approval time, never re-resolved.
  Rationale: Titles are attacker-influenceable via OSC escapes from any
  program, including remote hosts. Binding to the id and surfacing Laban's
  own identity for the target (id suffix, cwd, process) in the dialog makes
  a spoofed title insufficient to redirect a grant (threat (c)).
  Date/Author: 2026-07-09 / Claude.

- Decision: Downward principal step for broker-held connections: when the
  UDS peer is the bundled `laban-agent`, the approval principal is derived
  from the agent process it launched (the non-helper child recorded at
  broker launch and revalidated live), not from the helper.
  Rationale: The shipped upward chain walk (shell to peer) covers the lazy
  CLI transport, but on a held broker connection the peer IS the helper and
  the chain from shell to peer contains no agent. Without the downward step,
  every broker-launched agent would be unattributable and standing grants
  would be impossible on the recommended launch path. The helper-is-never-
  the-principal rule is preserved; only the direction of the search extends.
  Date/Author: 2026-07-09 / Claude.

- Decision: `session.requestObserveGrant` is classified `.propose`, and the
  Phase 2C `.propose` positive allowlist grows to exactly
  `{command.propose, session.requestObserveGrant}`.
  Rationale: Like `command.propose`, it is a user-mediated request object
  with no direct effect; the human is the actuator. Adding a new capability
  tier for one intent would weaken the hard-allowlist tests more than
  extending the documented set by one reviewed id.
  Date/Author: 2026-07-09 / Claude.

- Decision: `app.accessibility`, `session.list`, and rich `app.state` are
  excluded from the grant read set for MVP.
  Rationale: `session.list`/`app.state` are whole-app reads; a grant names
  one target and must not become enumeration. `app.accessibility` is
  excluded to keep the MVP set minimal; its text projection substantially
  overlaps `session.detail`. (The original rationale, "no explicit target
  parameter", was superseded by the shared-resolver decision below, which
  makes targeting uniform; the exclusion stands on minimalism.) The five
  included ids cover the stated goal (watch another session's content and
  state) via `session.detail`.
  Date/Author: 2026-07-09 / Claude; rationale updated 2026-07-09 / Fable
  orchestrator per review.

- Decision: FINDING 1 is fixed with a shared target resolver, not by
  dropping `selection.read` from the grant set. The policy-resolved
  effective target is the single source of truth and flows into the
  dispatch context: `legacyQueryInput`'s `scopedSessionID` becomes the
  granted target when and only when a grant authorized an explicit
  cross-session target; the audited target is the same value. Milestone 1
  carries the mandatory named test
  `testGrantedReadPayloadSessionEqualsAuditedTarget` (payload-session ==
  audited-target for each of the five intents), plus a matching mechanical
  Review Gate item.
  Rationale: The mismatch class is not specific to `selection.read`; it
  also hits `find.state`, `shellIntegration.state`, and
  `scrollIndicator.state` via the `targetSessionID`/`targetSessionId` keys
  that `resolveTargetSession` honors but the projections ignore. Dropping
  one intent would leave the class in place; unifying resolution removes it
  for all current and future granted reads and makes the audit trail
  truthful by construction.
  Date/Author: 2026-07-09 / Fable orchestrator per review.

- Decision: FINDING 2 is resolved by honest display, not by proxy
  attribution. Threat (b)'s residual acceptance now states that on a held
  broker connection requester attribution below the brokered agent is
  impossible; the sheet must not render a chain row that implies
  verification and instead renders "Requested via broker from within
  <Principal>'s process tree (exact requester not verifiable)". The proxy
  MAY forward the requesting descendant's pid and start time as
  display-only enrichment in a future revision; recorded as an explicit
  non-MVP follow-up, never authorization input.
  Rationale: The broker proxy forwards requests without conveying the
  requesting descendant's identity, so any chain rendered on that transport
  would be constructed, not verified; a security dialog must not imply
  verification it does not have. Forwarded self-reported identity cannot be
  trusted for authorization even later, which is why the follow-up is
  display-only by decision, not by deferral.
  Date/Author: 2026-07-09 / Fable orchestrator per review.

- Decision: FINDING 3 is resolved by same-change invariant maintenance,
  written into the milestones (and G7): Milestone 1 amends
  `docs/process/control-plane-threat-model.md` I2 (grant exception with its
  exact conditions) and adds invariant I8 (grants widen only the fixed read
  set for one (principal, source session, target session) tuple and die
  with either shell death, revocation, or runID change); Milestone 2 amends
  I7 (gui `.propose` set becomes `{command.propose,
  session.requestObserveGrant}`). The corresponding
  `ControlPlaneInvariantTests` updates land in the same commits, and
  mechanical gate items check the pairing.
  Rationale: That document's own "Rules for changes" names a cross-session
  observe grant as the example of a fourth trust derivation that must add
  its invariants in the same change that lands the mechanism; shipping
  without the amendments would leave I2 and I7 asserting properties the
  code no longer has, the exact cross-path drift the document exists to
  prevent.
  Date/Author: 2026-07-09 / Fable orchestrator per review.

- Decision: All eight first-round review notes are folded into the body:
  the `.observe`-tier count corrected to one (`scrollIndicator.state`,
  NOTE 1); the sheet's Data row states viewport grid text plus scrollback
  line counts, never "scrollback text", with a callout that the row must
  change in the same diff if `session.getText` ever joins the set (NOTE 2);
  the `signingRequirement` comment corrected: one-shot grants never
  construct `ControlSessionObserveGrant` (NOTE 3); threat (c) states
  explicitly that cwd and process name are attacker-influenceable, only the
  session id suffix is Laban-authoritative, and misdirection harm is
  bounded to observed-content injection toward the agent (NOTE 4);
  `intendedRequest` is REQUIRED on the lazy transport and optional on held
  connections, with the Transports wording aligned (NOTE 5); C15 escaping
  extends to the Settings rows and the per-tab badge hover text (NOTE 6);
  the body now states that Allow Once rides `.approvedSession` and needs no
  Milestone 1 policy change, and that `scrollIndicator.state`'s membership
  is redundant but kept for family symmetry (NOTE 7); the shared-queue
  starvation between grant and lazy-attach prompts is recorded in threat
  (a) as accepted for MVP because it fails closed and is user-visible
  (NOTE 8).
  Rationale: Each note was either a factual error against the shipped
  catalog/code or an unstated residual; correcting them in the body keeps
  the plan self-contained and the second review round focused on substance.
  Date/Author: 2026-07-09 / Fable orchestrator per review.

## Idempotence and Recovery

The design phase is trivially idempotent (one file). For implementation:
Milestone 1 is additive plus one focused dispatch change (a default-empty
parameter, new types, and the shared target resolution that lets
`scopedSessionID` carry a granted target); it is revertible by deleting the
new files and the parameter and restoring the pinned `scopedSessionID`
line; deny-by-default is preserved at every intermediate commit because
`grantedSessions` defaults to empty, and with no grant in the table the
shared resolver always yields the own session, so the dispatch change is
behavior-neutral until a grant exists. The same-change threat-model and
invariant-suite edits revert with their mechanisms. Milestone 2's route is
new; removing it restores today's behavior exactly. Milestone 3's observer methods have default no-op implementations
so partial adoption never breaks conformers. If a grant-widened read fails
mid-flight, the CLI reports and the agent re-requests; the server never
retries an approval on the agent's behalf. Revocation and expiry are safe to
run repeatedly (revoking a revoked grant is a no-op). The UserDefaults
mirror can be cleared wholesale without affecting authority (G6).

## Interfaces and Dependencies

End-state additions (all within existing targets; no new packages):

    LabanCore     IntentCatalog: + session.requestObserveGrant descriptor (+ ObserveGrantRequest schema)
    LabanControl  + ControlSessionObserveGrant.swift (grant + store + record types)
                  + crossSessionObserveGrantIntentIDs and grantedSessions in LabanControlPolicy
                  + shared target resolution: policy-resolved target flows into legacyQueryInput's
                    scopedSessionID when a grant authorized it (FINDING 1)
                  + POST /control/session/observe-grant/request route in LabanControlServer
                  + ControlObserveGrantApprovalRequest/Decision/Delegate in ControlAttachApproval.swift
                  + ControlSecurityObserver grant callbacks (default no-op)
    LabanApp      + ControlObserveGrantApprovalPresenter.swift (AppKit sheet, transport-specific
                    attribution row per FINDING 2)
                  ControlSecurityCoordinator: grant audit events + pinned indicator
                  SettingsWindowController: cross-session observation list + revoke (C15-escaped rows)
    LabanCLI      + session observe-grant request / session detail --session verbs
    Tests         ControlPlaneInvariantTests: I2 grant exception + new I8 + I7 propose set,
                    amended in the same commits as their mechanisms (FINDING 3)
    scripts       + test-installed-observe-grant
    docs          docs/process/controlling-agent-control-plane.md: grant section
                  docs/process/control-plane-threat-model.md: I2 amendment, I7 amendment, new I8
                    (same commits as Milestones 1 and 2)

`LabanControl` keeps its `["LabanCore"]`-only dependency rule; all AppKit
and Security-framework work stays in `LabanApp` behind the existing
injectable protocols (`ControlCodeSigningInspecting`,
`ControlObserveGrantApprovalDelegate`). The labpty wire and the C14 attach
handshake are untouched.
