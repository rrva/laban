# Agent Control Lazy Attach Approval

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds. This plan extends the production broker
work in `execplans/active/agent-control-production-broker-and-cli.md`; it keeps
that broker path as the deterministic launch path and adds an approval-driven
path for agents that were already started inside a Laban tab without the broker.

## Purpose / Big Picture

After the production broker plan, the correct way to start a controlling agent is
`laban agent run -- <agent>`. That path is secure and testable, but it is not the
workflow users naturally try. A user can open an agent-attached Laban tab, type
`codex`, and reasonably expect that Codex can later run `laban session
state --json`. Today that fails: Codex inherited `LABAN_SESSION_ATTACH`, but
`laban-agent` is launched by Codex's tool runner rather than as a direct child of
the tab shell, so the C14 direct-child check returns `401`.

After this change, a same-user process that is a descendant of the Laban tab's
registered shell can request one approved control-plane operation at the moment
it first needs it. Laban derives the real approval principal from the process
chain between the tab shell and the `laban` helper, shows a user-visible approval
dialog naming that principal, the session, and the server-derived operation, and
then dispatches the approved request. Future requests from the same trusted
signed app may be auto-approved only when the user chose the session-scoped
always-allow option and the request stays within the stored capability set. Users
can still use `laban agent run -- <agent>` for the clean broker-first path; lazy
approved dispatch is a safer recovery path for already-running agents, not a
replacement for the broker.

The demonstrable result is: start an agent-attached Laban tab, run `codex`
directly, and then from inside Codex run
`/Users/rrj/Laban.app/Contents/MacOS/laban session state --json`. Laban prompts
"Allow Codex to observe this Laban session?". Choosing "Allow Once" makes the
command return the attached session state without exposing token values. Choosing
"Deny" makes the command fail with a clear denial diagnostic. Choosing "Always
Allow This App" is available only for a stable signed, non-generic approval
principal and makes later descendant requests from that principal succeed without
another prompt, while still showing the agent-attached indicator and audit log
entries. The bundled `laban` CLI may transport the request, but it is never the
identity persisted by "Always Allow".

## Progress

- [x] (2026-07-08) Read `PLANS.md`,
  `execplans/active/agent-control-production-broker-and-cli.md`,
  `docs/process/controlling-agent-control-plane.md`, and the current control
  server, CLI launcher, security observer, indicator, settings, and command
  proposal presenter code.
- [x] (2026-07-08) Confirmed the motivating live failure: a shell in an
  agent-attached tab had `LABAN_CONTROL_URL` and `LABAN_SESSION_ATTACH`, but
  `laban agent run -- true` from Codex failed with
  `attachRedeemFailed(status: 401)` because the redeeming `laban-agent` was a
  descendant of Codex's tool runner, not a direct child of the tab shell.
- [x] (2026-07-08) Folded in external ChatGPT-5.5 Pro plan review: the approval
  principal must be derived from the process chain and must not be the `laban`
  helper; lazy attach must use approved one-shot dispatch or a single-use
  request-bound lease, never broad `.sessionObserve` authority; the prompt must
  display server-derived capability and sensitivity; process identities must
  include start time to reject PID reuse; approval queueing, timeout, and broker
  compatibility must be explicit.
- [x] (2026-07-09) Milestone 1: Add process identity, descendant matching, and
  approval records without changing authority yet. Landed as
  `Sources/LabanControl/ControlProcessIdentity.swift`,
  `ControlAttachApproval.swift`, `ControlAttachApprovalStore.swift`,
  `ControlAttachApprovalRecordSigner.swift`, `ControlLazyAttachAllowlist.swift`,
  and `ControlCodeSigning.swift`, covered by `ControlAttachAncestryTests`,
  `ControlAttachPrincipalTests`, `ControlAttachApprovalStoreTests`,
  `LazyAttachAllowlistTests`, and `LazyAttachPersistedApprovalScopeTests`.
- [x] (2026-07-09) Milestone 2: Add a live-GUI approved dispatch path that
  executes one server-resolved request after user approval. Landed as the
  `POST /control/session/attach/request` route in
  `Sources/LabanControl/LabanControlServer.swift` and
  `ControlTokenTier.approvedSession` in
  `Sources/LabanControl/LabanControlPolicy.swift`, covered by
  `LazyAttachApprovedRequestTests`.
- [x] (2026-07-09) Milestone 3: Teach session-scoped CLI commands to fall back
  to lazy attach when `LABAN_AGENT_CONTROL_URL` is missing. Landed as
  `Sources/LabanCLI/LazyAttachClient.swift`, wired into the session state,
  request, scroll, and propose commands (session proxy stays broker-only), with
  exit codes 3/4/5/6 mapped through `lazyAttachExitCode` in
  `Sources/LabanCLI/LabanCLI.swift`, covered by `LazyAttachCLITests` including
  `testSessionCommandsIgnoreLABANSessionAttach`.
- [x] (2026-07-09) Milestone 4: Add the approval dialog, settings surface,
  revocation, audit, indicator, and operator documentation. Landed as
  `Sources/LabanApp/Control/ControlAttachApprovalPresenter.swift` (the AppKit
  sheet), the approvals list and revoke buttons in
  `Sources/LabanApp/SettingsWindowController.swift`
  (`makeApprovalsListView`, around line 862), and the
  `control.attach.{requested,approved,denied,revoked,autoApproved}` audit
  events in `Sources/LabanApp/Control/ControlSecurityCoordinator.swift`,
  covered by `ControlSecurityAuditTests`. The operator guide
  (`docs/process/controlling-agent-control-plane.md`) already had the lazy
  attach section from this milestone; the broker-first recommended-workflow
  section and the revocation subsection are being added in this same
  documentation-reconciliation change.
- [x] (2026-07-09) Milestone 5: Add installed-bundle end-to-end coverage for
  direct-Codex lazy attach and for the existing broker-first path. Both
  installed smoke scripts exist: `scripts/test-installed-agent-lazy-attach` and
  `scripts/test-installed-control-broker`. Manual installed acceptance (the
  numbered steps in this milestone's plan section) was dogfooded rather than
  scripted, per the existing Surprises & Discoveries entries below.
- [x] (2026-07-09) Dogfooded GUI restart while Codex remained alive under
  labpty. Confirmed the app-observe token was republished and direct C14 became
  stale as intended, but lazy attach failed before approval because restored
  live sessions were not re-registered as shell ancestors in the new GUI control
  server. Fixed shell identity registration to cover non-pending restored
  sessions without minting a bootstrap.
- [x] (2026-07-09) Dogfooded the redesigned lazy-attach approval sheet in an
  installed app build. Fixed the AppKit accessory sizing regression that clipped
  detail rows outside the alert, then confirmed "Always Allow" made a repeated
  private session-state read return without reopening the sheet.
- [ ] Review Gate passed. (First fresh-state review ran 2026-07-09 against
  commit ccc847d and FAILED with 7 findings; see the Review findings list
  under the Review Gate section.)
- [x] (2026-07-09) Closed all 7 test-coverage findings from the 2026-07-09
  fresh-state review (commit ccc847d), building on the already-landed
  ancestry-boundary fix (commit `ab53168`). Every change is a test-only
  addition plus three additive, behavior-preserving test seams: an injectable
  `lazyAttachApprovalTimeout` constructor parameter on `LabanControlServer`, a
  DEBUG-only `onApprovedTokenMintedForTesting` closure fired at both
  approved-token mint sites, and a `ControlAttachApprovalPresenter
  .buttonTitles(for:)` extraction so button presence/order is unit-testable
  without driving `NSAlert`. No production behavior changed and no real
  defect was found. New tests per finding:
  1. PID reuse by start-time mismatch:
     `ControlAttachAncestryTests.testSwappedShellIdentityAfterRegistrationFailsEligibility`
     (ancestry layer) and
     `LazyAttachServerRevalidationTests.testSwappedPeerIdentityDuringApprovalFailsPreDispatchRevalidationWith409`
     (pre-dispatch revalidation), both using a new mutable fake process tree
     that swaps an identity behind a PID mid-test.
  2. One-shot reuse:
     `LazyAttachApprovedRequestTests.testMismatchedBodySHA256IsDenied` and
     `testCompletedAllowOnceDispatchIsNotReplayable`.
  3. Presenter rendering:
     `ControlAttachApprovalPresenterTests` (6 tests covering present for a
     signed non-generic principal; absent for zsh, python3, a package runner,
     an unsigned/ad-hoc binary, and the bundled laban helper) plus
     `ControlAttachPrincipalTests.testPrincipalCannotPersistForPackageRunner`.
  4. Server persistence keyed to principal, not helper peer:
     `LazyAttachPrincipalPersistenceTests.testPersistedRecordIsKeyedToPrincipalNotHelperPeer`.
  5. Malicious delegate cannot force persistence:
     `LazyAttachPrincipalPersistenceTests.testMaliciousDelegateCannotPersistForGenericOrUnsignedPrincipals`
     (node, python, zsh, bash, laban, laban-agent, unsigned, ad-hoc) and
     `testMaliciousDelegateCannotPersistForRawSessionRequestRoute`.
  6. CLI exit codes and server statuses:
     `LazyAttachCLITests.testSessionChangedMapsToExitCode5` and
     `testRateLimitedMapsToExitCode5`, plus
     `LazyAttachServerRevalidationTests.testApprovalTimeoutIsInjectableAndProduces408`
     and `testSwappedPeerIdentityDuringApprovalFailsPreDispatchRevalidationWith409`
     (409 sessionChanged), enabled by the new injectable
     `lazyAttachApprovalTimeout` constructor parameter.
  7. Secret-scan:
     `ControlSecurityAuditTests.testApprovedTokenNeverLeaksIntoResponseOrAudit`
     (using the new `onApprovedTokenMintedForTesting` seam) and
     `testDownstreamResponseSentinelDoesNotLeakIntoAuditPayloads`.
  Full validation:
  `CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" SWIFT_MODULE_CACHE_PATH="$PWD/.build/swift-module-cache" swift test --disable-sandbox --filter 'LabanControlTests|LabanCLITests|LabanAppTests'`
  (700 tests, 0 failures) and `./scripts/lint` (exit 0). Review Gate
  checkboxes and the Review findings list are left untouched; a fresh
  re-review should update them.

## Decision Log

- Decision: Keep `laban agent run -- <agent>` as the preferred launch path and
  add lazy attach as an additional path.
  Rationale: The broker-first path is deterministic, avoids dialogs in CI, and
  gives long-lived agents `LABAN_AGENT_CONTROL_URL`. Lazy attach solves the
  common "I already started Codex directly" workflow without weakening the
  broker path.
  Date/Author: 2026-07-08 / Codex.

- Decision: Lazy attach eligibility is "same uid and descendant of the
  registered session shell", not "any process with the environment variable".
  Rationale: `LABAN_SESSION_ATTACH` can leak through environment inheritance.
  Process ancestry ties the request back to the visible Laban tab while allowing
  real tool-runner trees such as `zsh -> node -> codex -> tool zsh -> laban`.
  Date/Author: 2026-07-08 / Codex.

- Decision: The approval principal is derived from the process chain between the
  registered session shell and the peer helper. The bundled `laban` CLI and
  `laban-agent` binaries are transport helpers and must never be the identity
  shown to the user or persisted by "Always Allow This App for This Session".
  Rationale: For a direct Codex workflow, the UDS peer is usually `laban`, not
  Codex. Trusting the helper would confuse the user and grant unrelated
  descendants access through the same helper.
  Date/Author: 2026-07-08 / Codex.

- Decision: "Always Allow This App for This Session" is available only for a stable signed,
  non-generic attach principal. Unsigned binaries, ad-hoc-signed binaries,
  scripts, shells, generic interpreters, package-manager runners, build/tool
  wrappers, and bundled Laban helpers are allow-once only.
  Rationale: Persisting trust for generic hosts such as `node`, `python`, `zsh`,
  `bash`, `npx`, `npm`, `pnpm`, `yarn`, `bun`, `deno`, `uv`, `pipx`, `ruby`,
  `perl`, `java`, `osascript`, `swift`, or `xcrun` would trust arbitrary future
  scripts rather than the agent the user intended.
  Date/Author: 2026-07-08 / Codex.

- Decision: Lazy attach uses approved one-shot dispatch as the preferred
  primitive. A returned token is allowed only as an implementation fallback, and
  then it must be single-use, request-bound, and consumed on the first
  authorization attempt. Lazy attach must not mint broad
  `ControlTokenTier.sessionObserve(sessionID:)` authority.
  Rationale: A reusable 60-second session bearer can be replayed for other
  own-session operations. The user approves one specific operation, so the
  authority must be bound to that operation.
  Date/Author: 2026-07-08 / Codex.

## Context and Orientation

The live control plane is HTTP over a Unix domain socket. A Unix domain socket is
a local file-system-like endpoint that same-machine processes can connect to; no
TCP port is opened. `control.json` advertises the socket path and an
`app-observe` bearer token. `app-observe` can read redacted app metadata such as
tabs and process titles, but it must not read terminal content.

C14 attach is the existing session credential flow. Laban mints a one-shot
`LABAN_SESSION_ATTACH` bootstrap for an eligible agent-attached session. The
current implementation in `Sources/LabanControl/LabanControlServer.swift`
redeems that bootstrap only when the connecting peer process is the verified
`laban-agent` executable and its immediate parent PID equals the registered
session shell PID. On success, the socket connection itself becomes the
session-observe credential. A session-observe credential may read sensitive
own-session state and may create command proposals, but it still must not inject
live PTY input, mutate the clipboard, switch tabs, or control other apps.

The production broker plan added `laban agent run -- <command>` in
`Sources/LabanCLI/AgentLauncher.swift`. That CLI process-replaces itself with
the sibling bundled `laban-agent`, which redeems C14 and launches the real agent
with `LABAN_AGENT_CONTROL_URL`. Descendants then run session commands through a
private proxy. This path works only if the user starts the agent through
`laban agent run` before the agent process exists.

The lazy attach path in this plan is for the opposite order: the user already
started the agent directly. The CLI cannot retroactively wrap the parent agent
with the broker, and it must not print or persist C14 bootstraps. Instead, a
session command such as `laban session state --json` asks the live GUI to
approve and dispatch one server-resolved request. The preferred implementation
does not return a bearer token to the CLI. If implementation constraints require
a token, it must be single-use, bound to the exact approved request, and consumed
on the first authorization attempt.

Relevant files:

- `Sources/LabanControl/LabanControlServer.swift` owns the live control socket,
  peer credential checks, C14 bootstrap redemption, token registration, request
  routing, and security observer callbacks.
- `Sources/LabanControl/LabanControlPolicy.swift` defines token tiers and which
  capabilities each tier grants.
- `Sources/LabanControl/ControlSecurityObserver.swift` defines audit and
  security callbacks used by the app.
- `Sources/LabanCore/Intents/IntentCatalog.swift` defines capabilities such as
  `observe`, `observeSensitive`, `navigate`, and `propose`.
- `Sources/LabanCore/Persistence/AgentSessionDetector.swift` already contains a
  `ProcessIntrospector` abstraction for process children, argv, environment,
  file descriptors, and cwd. Reuse or mirror this style for testable process
  ancestry and identity instead of scattering raw `sysctl` calls through the
  app.
- `Sources/LabanCLI/AgentProxyClient.swift` and
  `Sources/LabanCLI/LabanCLI.swift` own session command routing and diagnostics.
- `Sources/LabanApp/Control/ControlSecurityCoordinator.swift` logs sanitized
  control events and drives the TTL-based "Agent" indicator.
- `Sources/LabanApp/Control/ControlAgentAttachedIndicator.swift` renders the
  visible agent-attached pill.
- `Sources/LabanApp/Control/CommandProposalReviewPresenter.swift` is the closest
  existing AppKit pattern for presenting a control-plane sheet on the key window.
- `Sources/LabanApp/SettingsWindowController.swift`,
  `Sources/LabanCore/Control/ControlServerSettings.swift`, and
  `Sources/LabanApp/AgentAttachedSessionSettings.swift` show current
  UserDefaults-backed settings patterns.
- `docs/process/controlling-agent-control-plane.md` is the operator-facing guide
  that must be updated after behavior changes.

Definitions used in this plan:

- "Requester" means the process that connects to Laban and asks for lazy attach.
  For a CLI invocation from Codex, the requester is the `laban` CLI process.
- "Peer helper" means the process that connects to the Laban control socket. For
  lazy CLI requests this is usually the bundled `laban` executable. The peer
  helper is not automatically the app the user is approving.
- "Registered session shell" means the shell PID that Laban recorded for the tab
  session, such as the tab's `zsh` process.
- "Descendant" means the requester is the shell itself or a child, grandchild, or
  deeper child found by walking parent PIDs from the requester up toward PID 1.
- "Attach process chain" means the verified same-uid process chain from the
  registered session shell to the peer helper. Each process identity in the chain
  includes pid, process start time or birth time, uid, executable path, and a
  code-signing summary when available.
- "Attach principal" means the non-helper process in the attach process chain
  that best represents the app or agent requesting access. The approval UI and
  persisted approvals are based on this principal, not on the bundled `laban`
  helper.
- "Signed identity" means a stable macOS code-signing identity, preferably a
  designated requirement or equivalent stable tuple of team identifier, bundle
  identifier, signing identifier, and code directory hash.
- "Generic interpreter" means a shell, interpreter, package runner, build
  runner, or script host that can execute arbitrary user code, including but not
  limited to `sh`, `zsh`, `bash`, `fish`, `python`, `python3`, `node`, `npm`,
  `npx`, `pnpm`, `yarn`, `bun`, `deno`, `uv`, `pipx`, `ruby`, `perl`, `php`,
  `java`, `osascript`, `swift`, and `xcrun`.
- "Approved request" means a single server-resolved control-plane request that
  was approved by the user or by a matching persisted principal approval. The
  approved request is bound to method, normalized path, query, body hash, target
  session, resolved route, resolved intent, exact capability set, peer process
  identity, principal identity, and expiry.
- "Persisted approval" means a local UserDefaults record that permits future
  auto-approval for a stable signed non-generic principal only when all of the
  following match: the current principal satisfies the stored signing
  requirement; the principal is still a same-user descendant of a registered
  session shell; the approval scope matches the current session; the resolved
  route ID is in the stored allowed route set; the resolved intent ID is in the
  stored allowed intent set; the requested capability set is a subset of the
  stored capability set; the requested data sensitivity is no greater than the
  stored maximum; and the requested side-effect class is in the stored allowed
  side-effect set. Persisted approval is not a bearer credential and is not
  capability-only.
- "Lease" means an implementation fallback only: a temporary bearer token created
  after approval. Lazy attach should prefer server-side approved dispatch. If a
  lease is used, it must be single-use, request-bound, non-persisted, and never
  printed.

## Compatibility With Broker-First Production Control

This plan does not replace the production broker/proxy path. `laban agent run --
<command>` remains the deterministic and preferred way to run an agent with
long-lived session control and `LABAN_AGENT_CONTROL_URL`.

Lazy approved dispatch is only a recovery path for one-shot session commands when
an agent was already started directly inside an agent-attached Laban tab. The CLI
lazy path must not:

- read or redeem `LABAN_SESSION_ATTACH`,
- call `redeemAttachBootstrap`,
- start a hidden `laban-agent` broker,
- expose `session proxy`, or
- provide streaming long-lived control.

The existing broker Review Gate remains valid except that session CLI commands
may, when `LABAN_AGENT_CONTROL_URL` is absent, call the new approved lazy
dispatch endpoint using app-observe discovery and user approval.

## Plan of Work

### Milestone 1: Identity, Ancestry, and Trust Records

At the end of this milestone, the codebase can answer four questions in tests:
"What process is asking?", "Is it descended from this exact live session shell?",
"Which process in that chain is the approval principal?", and "Do we already
trust that principal for these capabilities?" No control authority changes yet.

Add a testable process identity layer. Prefer a new file such as
`Sources/LabanControl/ControlProcessIdentity.swift` if it can avoid AppKit and
Security framework dependencies; otherwise split pure ancestry into
`LabanControl` and code-signing inspection into `LabanApp`. The pure types should
include:

```swift
public struct ControlProcessIdentity: Equatable, Sendable {
  public var pid: pid_t
  public var parentPID: pid_t?
  public var startTime: Date?
  public var uid: uid_t
  public var executablePath: String?
  public var arguments: [String]
  public var signing: ControlCodeSigningIdentity?
}

public struct ControlCodeSigningIdentity: Codable, Equatable, Sendable {
  public var teamIdentifier: String?
  public var bundleIdentifier: String?
  public var signingIdentifier: String?
  public var designatedRequirement: String?
  public var codeHash: String?
  public var isAdHocOrUnsigned: Bool
}
```

Add a small process-tree helper with an injectable interface:

```swift
public protocol ControlProcessTreeInspecting: Sendable {
  func parentPID(of pid: pid_t) -> pid_t?
  func identity(for pid: pid_t) -> ControlProcessIdentity
}
```

The production implementation can use the same kernel calls already present in
`LabanControlServer.parentPID(of:)` and `ControlProcessInfo.executablePath(for:)`.
Tests must use a fake tree.

For lazy attach security decisions, process `startTime` is required. A process
identity with `startTime == nil` may be used for display or diagnostics, but it
is not eligible for registered shell identity creation, descendant eligibility,
peer identity revalidation, principal identity binding, approved dispatch, or
request-bound lease binding. Never treat two missing start times as equal.
Missing shell, peer, or principal start time fails closed with HTTP `403` and
code `processIdentityUnavailable`.

Add a code-signing inspection protocol in `LabanControl` so the control server,
not only the AppKit UI, can validate persistence decisions:

```swift
public protocol ControlCodeSigningInspecting: Sendable {
  func signingIdentity(forLivePID pid: pid_t, startTime: Date) -> ControlCodeSigningIdentity?
  func validatesLivePID(_ pid: pid_t, startTime: Date, against requirement: String) -> Bool
}
```

The production implementation may live in a macOS-specific file and use
Security.framework. Tests use fakes. Code-signing identity for approval and
matching must be obtained from the live process identified by pid plus start
time, using macOS code-signing APIs for the running code object where available.
Path-based static validation is a display fallback only and must not by itself
authorize persisted approvals. Persisted matching uses the stored designated
requirement or equivalent requirement validation. `codeHash` is stored for
audit/debugging and may be used for unsigned/ad-hoc allow-once display, but it is
not the primary stable key for signed app updates. If the implementation cannot
validate the current live principal against the stored signing requirement,
auto-approval fails closed and the user is prompted again.

Extend `LabanControlServer` so registered shell identities live independently of
single-use bootstraps. Today `registerAttachShellPID(sessionID:shellPID:)`
updates bootstrap entries. Add a durable in-memory map:

```swift
private var attachShellIdentitiesBySessionID: [String: RegisteredAttachShellIdentity] = [:]
```

Each registered shell identity records:

- `sessionID`,
- optional tab/window generation if available,
- shell pid,
- shell process start time or birth time,
- shell uid,
- shell executable path,
- `registeredAt`.

Update `registerAttachShellPID` to populate that map and keep the existing
bootstrap update. Add unregister/cleanup when the session closes, when the tab is
no longer agent-attached, when the app disables control, and when the server
stops.

An ancestry check is valid only if:

- the peer uid matches the server uid,
- the registered shell process is still live,
- the registered shell pid has the same start time as the recorded shell,
- the peer is a descendant of that exact shell process,
- exactly one registered session shell appears in the peer ancestry, and
- every inspected process identity is read fresh during the request.

If the requester is descended from zero sessions, it is ineligible. If it is
descended from more than one session, return a protocol error and require a more
specific request; ambiguity should not silently pick the active tab.

Add `ControlAttachProcessChain` and `ControlAttachPrincipal`. The process chain
resolver walks from the peer helper toward the registered shell and records pid,
start time, uid, executable path, bundle metadata if available, and code-signing
summary.

Principal selection rules:

1. The bundled `laban` CLI and `laban-agent` helper are skipped as transport
   helpers.
2. Generic interpreters and shell/package runners are never persistable
   principals.
3. Prefer the nearest non-generic stable signed app or binary between the shell
   and the helper.
4. If no stable signed non-generic principal exists, the request can still be
   shown as "Allow Once", but "Always Allow This App for This Session" is unavailable.
5. The prompt shows both the principal and a short helper chain summary, for
   example `Codex -> laban helper`.
6. Persisted approvals are keyed to the principal signing identity, never to the
   helper identity.

Add approval record types. A persisted record should contain no bearer tokens and
no terminal content:

```swift
public enum ControlAttachApprovalScope: Codable, Equatable, Sendable {
  case currentRegisteredSession
  // A future plan may add allAgentAttachedSessions after explicit UX review.
}

public struct ControlAttachApprovalRecord: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var id: String
  public var displayName: String
  public var bundleIdentifier: String?
  public var signing: ControlCodeSigningIdentity
  public var scope: ControlAttachApprovalScope
  public var sessionID: String
  public var shellIdentityFingerprint: String
  public var allowedRouteIDs: [String]
  public var allowedIntentIDs: [String]
  public var capabilities: [Capability]
  public var maxDataSensitivity: String
  public var allowedSideEffectClasses: [String]
  public var createdAt: Date
  public var lastUsedAt: Date?
  public var revokedAt: Date?
}
```

Use UserDefaults for MVP persistence only after validating that the record is
small, token-free, and revocable. Store records under a Laban-specific key such
as `LabanControlAttachApprovalRecordsV1`. The settings surface may move to a
file later, but this plan should not introduce a database.

Persisted approval matching requires:

- the current principal signature validates,
- the current principal satisfies the stored signing requirement,
- the current principal is not a generic interpreter/helper,
- the approval scope matches the current session,
- the current registered shell identity matches `shellIdentityFingerprint`,
- the resolved route ID is in `allowedRouteIDs`,
- the resolved intent ID is in `allowedIntentIDs`,
- the requested capability set is a subset of the stored capability set,
- the requested data sensitivity is no greater than the stored maximum,
- the requested side-effect class is in the stored allowed side-effect classes,
  and
- the peer remains a same-user descendant of the registered session shell.

For MVP, persisted approvals are session-scoped. An "Always Allow" record
applies only while the same registered session shell identity remains live. It
expires when the session closes or the registered shell identity changes. The UI
button text is `Always Allow This App for This Session`. A future plan may add
global app approvals; if global approvals are added, the prompt and Settings UI
must explicitly say `Always Allow This App for Future Agent-Attached Laban
Sessions`.

Unsigned binaries, ad-hoc-signed binaries, scripts, generic interpreters,
package runners, shells, and the bundled Laban helpers may only be approved once.
They are never persisted by path plus hash in UserDefaults.

An "Always Allow" created from `laban session state --json` allows future
`GET /debug/state` / `app.state` lazy requests only. It does not allow
`session scroll`, `command.propose`, raw `session request` to another route,
logs, clipboard diagnostics, terminal byte-flow diagnostics, screenshots,
artifacts, fixture routes, or any route with a different intent ID.

Acceptance for Milestone 1:

- Unit tests prove descendant matching across direct child, grandchild, and
  tool-runner chains.
- Unit tests prove non-descendants and ambiguous descendants are rejected.
- Unit tests prove PID reuse is rejected by process start-time mismatch.
- Unit tests prove missing shell start time, missing peer start time, or missing
  principal start time makes lazy attach ineligible and does not fall back to
  PID-only matching.
- Unit tests prove stale shell registration is removed on session close.
- Unit tests prove the attach principal is Codex or another real agent/app in a
  `shell -> agent -> tool -> laban` chain, not the bundled `laban` helper.
- Unit tests prove unsigned, ad-hoc, shell, generic interpreter, package runner,
  and bundled Laban helper identities cannot produce persisted always-allow
  records.
- Unit tests prove an always-allow record created for `GET /debug/state` does not
  auto-approve any other route or intent sharing `.observeSensitive`.
- Existing C14 direct-child redemption tests still pass unchanged.

### Milestone 2: Approved Dispatch Endpoint

At the end of this milestone, a same-user descendant process can ask for lazy
attach over the live control socket, the app can approve or deny it through an
injectable delegate, and approval dispatches exactly one server-resolved request.
No reusable session bearer is returned to the CLI in the preferred
implementation.

Add a new internal route in `LabanControlServer`, for example:

```http
POST /control/session/attach/request
```

This route is not a general debug endpoint and should not appear as a broad
capability in the public discovery document until the UX and docs are complete.
It requires:

- same-uid peer credentials from the Unix domain socket,
- an `app-observe` token from secure `control.json` discovery,
- peer pid/start-time identity from `peerPID(clientFD:)` and process
  introspection,
- exactly one registered session shell ancestor, and
- a JSON body describing the intended request, not the security summary.

Add `ControlLazyAttachAllowlist`. Lazy approved dispatch supports only this MVP
allowlist:

| CLI command | Method/path | Required route/intent | Persistable |
| --- | --- | --- | --- |
| `laban session state --json` | `GET /debug/state` | `app.state` | yes, exact route/intent only |
| `laban session scroll --rows N --json` | `POST /debug/actions` action `scrollViewport` | `terminal.scrollViewport` | no for MVP unless a later edit adds a separate exact route/intent grant |
| `laban propose --purpose ...` | `POST /debug/actions` action `propose` | `command.propose` | no for MVP unless a later edit adds a separate exact route/intent grant |

`laban session request METHOD PATH` remains broker-only unless the resolved
method, path, route, and intent appear in `ControlLazyAttachAllowlist`.
Unsupported lazy routes fail before UI with HTTP `403` and code
`lazyRouteNotAllowed`. Raw `session request` may use lazy approved dispatch only
when the resolved route and intent are present in `ControlLazyAttachAllowlist`.
"Always Allow" is disabled for raw `session request` unless the route/intent pair
is one of the built-in typed commands.

Request body shape:

```json
{
  "clientRequestID": "uuid",
  "cliCommand": "session.state",
  "intendedRequest": {
    "method": "GET",
    "path": "/debug/state",
    "query": "",
    "body": null,
    "bodySHA256": null
  }
}
```

`cliCommand` is diagnostics-only and untrusted. It must not be shown as the
security summary unless it matches the server-resolved route and intent. If
`intendedRequest.body` is present, the server computes SHA-256 over the exact
request body bytes and rejects mismatched `bodySHA256` before showing UI. If
`body` is null, `bodySHA256` must be null.

The server resolves the route and intent before approval. It derives:

- target session,
- route ID,
- intent ID,
- required capability set,
- data sensitivity,
- side-effect class, and
- display summary.

The UI displays only server-derived capability, data sensitivity, side-effect
class, target session, and route summary. A caller-provided reason is optional,
length-limited, rendered as untrusted text, and never used for authorization,
principal identity, or audit identity.

If approved, the server internally dispatches the intended request under an
approved-session authorization context and returns the downstream status/body to
the CLI. Unsupported routes are rejected before showing UI. Lazy approved
dispatch does not support `session proxy`, live PTY input, clipboard reads or
writes, tab switching, global app state, or any route outside the explicitly
allowed session CLI/proposal subset.

Response body on approval:

```json
{
  "ok": true,
  "sessionID": "3A2039C5-04C1-4AA4-A513-525BDB71B6A3",
  "approval": "once",
  "downstreamStatus": 200,
  "downstreamBody": "{...raw response body...}"
}
```

`/control/session/attach/request` returns HTTP `200` only when approval and
dispatch transport succeed. The downstream HTTP status is carried in
`downstreamStatus`; the CLI maps its own exit code from the approval status first
and the downstream status second.

The server must never log terminal text, app-observe tokens,
`LABAN_SESSION_ATTACH`, raw Authorization headers, or caller-provided reason
text. Audit logs may include approval ID, principal display name, signing
fingerprint, session ID suffix, route ID, intent ID, capability names, approval
mode, and timestamp.

Introduce an approval delegate in `LabanControl`:

```swift
public enum ControlAttachApprovalDecision: Equatable, Sendable {
  case allowOnce
  case alwaysAllowSignedIdentity
  case deny
}

public protocol ControlAttachApprovalDelegate: AnyObject, Sendable {
  func requestControlAttachApproval(
    _ request: ControlAttachApprovalRequest,
    completion: @escaping @Sendable (ControlAttachApprovalDecision) -> Void
  )
}
```

`LabanControlServer` owns the protocol and a weak delegate. `LabanApp` implements
the delegate in Milestone 4. Tests can inject a deterministic delegate.

Do not block the main thread. The server can block the worker handling this one
request on a semaphore or condition variable with a 30-second timeout, because the
requester is waiting for a command response, but the delegate must call into
AppKit asynchronously on the main queue.

Lazy approval requests are bounded and coalesced:

- at most one visible lazy approval prompt per session,
- at most one pending request per principal/session/capability tuple,
- at most eight pending lazy approval requests globally,
- duplicate matching requests within a two-second window are coalesced or
  rejected with `429`,
- pending requests are cancelled on session close, app shutdown, timeout, or
  detectable client disconnect.

HTTP status mapping:

- `200` approved,
- `403` with code `userDenied` when the user denies,
- `408` with code `approvalTimeout` when no answer arrives before the 30-second
  approval timeout,
- `409` with code `sessionChanged` when session or process identity changed
  during approval,
- `429` with code `approvalRateLimited` when pending/rate limits are exceeded.

Immediately before dispatching the approved request, the server revalidates the
peer process identity, ancestry, shell process identity, session liveness,
requested route, body hash, and capability set. If any value changed, the
request fails with `409 sessionChanged`.

Do not use `.sessionObserve(sessionID:)` for lazy attach. Add an approved-session
authorization context with the minimum capabilities required for the approved
request:

```swift
approvedSession(sessionID:approvalID:capabilities:constraint:)
```

The policy layer authorizes an approved-session context only when the target
session matches, the requested capability is in the approved set, and the current
request satisfies the approved request constraint.

When adding `ControlTokenTier.approvedSession(...)`, update every switch over
`ControlTokenTier`: `LabanControlPolicy.grants(for:)`,
`LabanControlPolicy.tokenScope(for:)`, `LabanControlPolicy.authorize(...)`,
`ControlRouteCatalog` route resolution for `/debug/state`,
`LabanControlServer.sessionID(from:)`, `LabanControlServer.legacyQueryInput(...)`,
and `LabanControlServer.reportAuthorize(...)` / deny context where needed. For
`/debug/state`, `.approvedSession` resolves to `app.state`, not
`app.stateSummary`, but only when the approved constraint matches the current
request. `legacyQueryInput` must set `scopedSessionID` to the approved session
and use session-observe redaction semantics without granting unrelated
session-observe authority.

The server and `ControlAttachApprovalStore` validate every
`.alwaysAllowSignedIdentity` decision independently of the UI. If the delegate
returns `.alwaysAllowSignedIdentity` for a non-persistable principal,
non-persistable route, raw `session request`, generic interpreter,
unsigned/ad-hoc process, script, package runner, build wrapper, or bundled Laban
helper, the server does not persist the record. It treats the decision as
`allowOnce` only if the one-shot request itself is otherwise eligible; otherwise
it denies with `403 approvalNotPersistable`. Tests must prove a malicious or fake
delegate returning `.alwaysAllowSignedIdentity` cannot create a persisted record
for non-persistable identities or non-persistable operations.

If implementation constraints require returning a lease token instead of
server-side dispatch, the token must be single-use, non-persisted, and
request-bound. The lease record contains approval ID, session ID, peer pid and
peer process start time, principal identity fingerprint, HTTP method, normalized
path, query, body SHA-256, resolved route ID, resolved intent ID, exact required
capability set, and expiry timestamp. The token is consumed on the first
authorization attempt, including failed attempts. It cannot authorize any request
whose method, path, query, body hash, session, route, intent, or capability set
differs from the approved request. Lazy attach must not mint or reuse
`.sessionObserve(sessionID:)`.

Acceptance for Milestone 2:

- A fake delegate returning `allowOnce` dispatches the descendant session's
  `/debug/state` request and returns the downstream body.
- An approval for `session state` cannot be reused for `session scroll`,
  `command.propose`, another body, another session, or a second request.
- A fake delegate returning `deny` returns a denial without minting a token.
- A timed-out delegate returns a clear timeout response.
- A stale session/process identity returns `409 sessionChanged`.
- Rate-limited duplicate requests return `429 approvalRateLimited`.
- A non-allowlisted route or action returns `403 lazyRouteNotAllowed` before UI.
- A fake delegate returning `.alwaysAllowSignedIdentity` for a non-persistable
  identity or operation cannot create a persisted record.
- Sensitive values do not appear in audit payloads, stdout/stderr test fixtures,
  or thrown error descriptions.

### Milestone 3: CLI Lazy Attach Fallback

At the end of this milestone, existing session-scoped CLI commands work in two
ways:

1. If `LABAN_AGENT_CONTROL_URL` exists, they continue to use the broker proxy.
2. If it is missing, they request lazy approved dispatch for the command
   currently being run.

Modify `Sources/LabanCLI/AgentProxyClient.swift` and
`Sources/LabanCLI/LabanCLI.swift` so session commands do not immediately fail
when `LABAN_AGENT_CONTROL_URL` is absent. The CLI should:

1. Read `control.json` with the existing secure discovery code.
2. Send `POST /control/session/attach/request` with the app-observe token.
3. Include the intended request envelope so the server can resolve the route,
   intent, capability, sensitivity, and target session before prompting.
4. Print the downstream approved request output to stdout and human diagnostics to
   stderr.

Keep exit codes stable:

- `0` success,
- `2` usage error,
- `3` unavailable control plane or auth setup failure,
- `4` approval timeout,
- `5` user denied, capability denied, process not eligible, or session changed,
- `6` malformed response or protocol mismatch.

Update the missing-env diagnostic. Today it says:

```text
LABAN_AGENT_CONTROL_URL is not set; try `laban agent run -- <command>`
```

After this milestone, session commands should only show that as fallback advice
when lazy attach is unavailable or denied. A good denial diagnostic is:

```text
laban: session control denied: this process is not a descendant of an
agent-attached Laban shell. Start agents with `laban agent run -- <agent>`.
```

When lazy attach is available and waiting for the user, stderr may say:

```text
laban: waiting for Laban approval to observe this session...
```

Do not print process environment values, bearer tokens, bootstrap values, or raw
authorization headers.

Commands covered in this milestone:

```sh
laban session state --json
laban session request METHOD PATH [--body JSON] [--json]
laban session scroll --rows N --json
laban propose --purpose TEXT -- COMMAND [ARG ...]
```

`laban session request METHOD PATH` is broker-only unless the resolved route and
intent are present in `ControlLazyAttachAllowlist`. `laban session proxy` remains
broker-only in this milestone, because it is a long-lived stream. It should keep
the existing `LABAN_AGENT_CONTROL_URL` requirement and print:

```text
laban: session proxy requires broker mode; restart the agent with
`laban agent run -- <agent>` for long-lived session control.
```

Document tmux/screen limitations: descendant-of-shell lazy approval may not work
for process trees that escape the tab shell ancestry through a long-lived
external daemon, such as some `tmux` or `screen` layouts. The fallback is
`laban agent run -- <agent>`.

Acceptance for Milestone 3:

- CLI tests prove broker-present behavior is unchanged.
- CLI tests prove broker-missing behavior requests lazy approved dispatch and
  returns the downstream response for the intended command.
- CLI tests prove `laban session request` is broker-only unless the route/intent
  pair is allowlisted.
- CLI tests prove denial, timeout, ineligible process, sessionChanged,
  approvalRateLimited, and malformed approval response map to the documented exit
  codes.
- Tests prove no token value appears in stdout or stderr.
- Tests prove session command implementation files never call
  `redeemAttachBootstrap`, read `LABAN_SESSION_ATTACH`, or start a hidden
  `laban-agent` broker.
- `laban agent run -- <command>` remains unchanged and still strips
  `LABAN_SESSION_ATTACH` from child environment.

### Milestone 4: App Approval UX, Settings, Revocation, Audit, and Docs

At the end of this milestone, lazy attach is visible and controllable by the
user. Laban presents an approval sheet, records safe audit events, shows the
agent-attached indicator while privileged control is active, and exposes a way to
revoke persisted approvals.

Add `Sources/LabanApp/Control/ControlAttachApprovalPresenter.swift`. Follow the
AppKit pattern in `CommandProposalReviewPresenter`: present as a sheet on the
owning Laban window/session when possible, not merely the current key window. If
the owning window is unavailable, fall back to `runModal()`. The dialog should be
concise and concrete:

```text
Allow Codex to observe this Laban session?

Principal: Codex
Helper chain: Codex -> laban helper
Path: /Applications/Codex.app/Contents/MacOS/Codex
Session: c2yt (session ...D27)
Operation: Read current session state
Data: private session metadata; no keyboard input, clipboard, or tab switching

[Allow Once] [Always Allow This App for This Session] [Deny]
```

The prompt must use server-derived route, intent, capability, sensitivity, target
session, and side-effect text. It must not display caller-provided `reason` as
the primary security summary.

If the attach principal is unsigned, ad-hoc signed, a script, a generic shell,
an interpreter, a package runner, a build/tool wrapper, or a bundled Laban
helper, omit or disable "Always Allow This App for This Session" and explain that only "Allow
Once" is available. Examples of non-persistable principals include `sh`, `zsh`,
`bash`, `fish`, `python`, `python3`, `node`, `npm`, `npx`, `pnpm`, `yarn`, `bun`,
`deno`, `uv`, `pipx`, `ruby`, `perl`, `php`, `java`, `osascript`, `swift`,
`xcrun`, `laban`, and `laban-agent`. If the principal is a stable signed
non-generic app bundle such as Codex.app, allow persistence by its signing
requirement.

Add `ControlAttachApprovalStore` in an appropriate module. It should:

- load and save persisted records through UserDefaults,
- never store tokens or terminal content,
- treat revoked records as denied,
- update `lastUsedAt` when an always-allow record is used,
- support a test-only in-memory defaults instance.

Add settings UI in `SettingsWindowController` under the existing control server
and agent-attached settings. Keep this small. A simple "Manage Agent Approvals"
button may open an `NSAlert` or small window listing app display name,
capabilities, created date, and a revoke button. A full permissions management
table is not required for MVP, but revocation is required before shipping
"Always Allow".

Wire `ControlSecurityCoordinator` to log:

- `control.attach.requested`,
- `control.attach.approved`,
- `control.attach.denied`,
- `control.attach.revoked`,
- `control.attach.autoApproved`,
- `control.privileged` for commands that use approved lazy dispatch or a fallback
  single-use request-bound lease.

Audit payloads must include no terminal text, no token values, no raw argv beyond
the display-safe process name/path needed for accountability, no full executable
path by default, no caller-provided reason text, and no environment variables.
Use session id suffix, route id, intent id, signing fingerprint, and capability
names rather than terminal content.

Update `docs/process/controlling-agent-control-plane.md` with:

- broker-first recommended workflow,
- lazy attach recovery workflow for already-running agents,
- exact expected diagnostics for denial, timeout, and ineligible process,
- security rules for "Always Allow This App for This Session",
- revocation instructions,
- the fact that `session proxy` remains broker-only.

Acceptance for Milestone 4:

- Unit or debug-hook tests cover the presenter rendering for signed and unsigned
  requesters, generic interpreters, package runners, and bundled Laban helpers.
- Settings tests or focused controller tests prove records can be revoked and
  revoked records are not auto-approved.
- Audit tests prove approval events contain no tokens, terminal text, full paths,
  or caller-provided reason text.
- A manual run shows the "Agent" indicator during an approved lazy attach
  command.
- Documentation includes copy-pasteable commands for both `laban agent run --
  codex` and direct `codex` followed by lazy approval.

### Milestone 5: Installed-Bundle End-to-End Verification

At the end of this milestone, the installed app bundle proves both workflows:
the strict broker-first path and the direct-agent lazy attach path.

Add or extend installed smoke scripts. Prefer new scripts named:

```sh
scripts/test-installed-agent-lazy-attach
scripts/test-installed-control-broker
```

The lazy attach script should be idempotent and safe. It may need a small helper
mode in the app or test harness to auto-deny/auto-allow approval decisions for
CI, because CI cannot click an AppKit dialog. If such a hook is added, it must be
available only under an explicit test flag or DEBUG build setting and must not be
active in normal installed builds.

Installed-bundle smoke must verify:

- `codesign --verify --deep --strict "$APP"`,
- code-signing metadata for `$APP/Contents/MacOS/laban`,
- code-signing metadata for `$APP/Contents/MacOS/laban-agent`,
- `ControlProcessInfo.defaultExpectedAgentExecutablePath` resolves to the
  installed helper,
- lazy approval uses the installed `laban` helper as transport but does not
  persist approval for that helper,
- persisted approval matching succeeds or fails according to the principal
  signing identity, not according to the helper identity.

Manual installed acceptance:

1. Build and install the app bundle.
2. Start Laban with an agent-attached tab.
3. In the tab, run `codex` directly, not through `laban agent run`.
4. From Codex, run:

   ```sh
   "$HOME/Laban.app/Contents/MacOS/laban" session state --json
   ```

5. Choose "Allow Once".
6. Observe JSON session state for the same tab and no token output.
7. Repeat, choose "Deny", and observe exit code `5` plus a human denial
   diagnostic.
8. If using a signed Codex app, choose "Always Allow This App for This Session", run the command
   again, and observe no second prompt plus an audit entry and visible indicator.
9. Revoke the approval in Settings and verify the next command prompts again.

Broker-first acceptance remains:

```sh
"$HOME/Laban.app/Contents/MacOS/laban" agent run -- codex
```

Inside that Codex session:

```sh
"$HOME/Laban.app/Contents/MacOS/laban" session state --json
```

This should use `LABAN_AGENT_CONTROL_URL` without presenting the lazy approval
dialog.

## Concrete Steps

Use this repository root:

```sh
cd /Users/rrj/.cursor/worktrees/laban/c2yt
```

Recommended implementation order:

1. Add pure process identity and ancestry helpers plus unit tests.
2. Extend `LabanControlServer` with registered shell identity storage and
   cleanup.
3. Add attach process chain, attach principal, approval record/store types, and
   tests.
4. Add the approved dispatch route and approved-session authorization context.
5. Add fake-delegate server tests for allow, deny, timeout, non-descendant,
   ambiguity, PID reuse, sessionChanged, rate limiting, and no-secret logging.
6. Update CLI session commands to use lazy approved dispatch when proxy env is
   absent.
7. Add AppKit approval presenter and settings/revocation UI.
8. Update docs.
9. Add installed smoke scripts or explicit manual installed verification notes.
10. Run targeted tests after each milestone and update `Progress` with results.

Do not rewrite unrelated control routes or terminal behavior. Do not add live PTY
input, keyboard injection, mouse injection, clipboard mutation, tab switching, or
cross-session terminal content access.

## Validation and Acceptance

Targeted checks during implementation:

```sh
swift test --disable-sandbox --filter LabanControlTests
swift test --disable-sandbox --filter LabanCLITests
swift test --disable-sandbox --filter LabanAppTests
swift build --disable-sandbox --product laban
swift build --disable-sandbox --product laban-agent
swift build --disable-sandbox --product LabanApp
./scripts/lint
git diff --check
```

If SwiftPM module-cache failures occur in this managed worktree, retry with:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
SWIFT_MODULE_CACHE_PATH="$PWD/.build/swift-module-cache" \
swift test --disable-sandbox --filter LabanCLITests
```

Behavioral acceptance:

- From a broker-first session, `laban session state --json` succeeds without a
  dialog because `LABAN_AGENT_CONTROL_URL` is present.
- From a direct-agent session descended from an agent-attached Laban tab,
  `laban session state --json` opens an approval dialog and succeeds after
  "Allow Once".
- From a non-descendant same-user process, the same command fails with exit `5`
  and a diagnostic that explains it is not descended from an agent-attached
  Laban shell.
- Denying the dialog fails with exit `5`.
- Letting the dialog time out fails with exit `4`.
- "Always Allow This App for This Session" is shown only for stable signed,
  non-generic principals, can be revoked, and never stores bearer tokens or
  helper identity as the trusted principal.
- Approved requests are session-scoped, route-bound, body-bound, and cannot
  target another session or be replayed for another operation.
- Persisted approvals are route/intent-bound and session-scoped; an approval for
  `GET /debug/state` does not auto-approve any other `.observeSensitive` route.
- Missing shell, peer, or principal process start time fails closed with
  `processIdentityUnavailable`.
- Audit logs and CLI output contain no `LABAN_SESSION_ATTACH`, app-observe token,
  lease token, raw Authorization header, terminal text payload, or
  caller-provided reason text.
- The "Agent" indicator appears during approved lazy attach activity.

## Surprises & Discoveries

- Observation: Restarting Laban while an agent-attached Codex process survived
  under labpty republished `control.json` with a new app-observe token, and
  direct C14 failed with the expected stale-bootstrap HTTP 401. However,
  `laban session state --json` failed immediately with
  `notDescendantOfRegisteredSession` instead of reaching approval.
  Evidence: the restored active tab reported shell PID `7742`, and the OS tree
  still had `labpty -> zsh(7742) -> node codex -> codex -> tool process`; the
  failure was caused by the new GUI control server not repopulating
  `attachShellIdentitiesBySessionID` for restored live sessions.

- Observation: `NSAlert` did not size the approval details correctly when the
  accessory view only had Auto Layout constraints. The sheet rendered narrow and
  the detail rows overlapped the message/title area.
  Evidence: the installed build showed clipped rows until the accessory stack
  was given an explicit frame width and fitting height; after reinstall and
  restart, the same approval prompt rendered as a bounded centered sheet.

- Observation: this ExecPlan's `Progress` checkboxes lagged the implementation.
  Documentation reconciliation on 2026-07-09 confirmed the feature landed and
  merged (PR #9 and follow-up fixes, commits `d1a77c3` through `aa9ce89`) and
  updated Milestones 1 through 5 to checked with file/test-suite evidence. The
  Review Gate stays unchecked and Review status stays NOT REVIEWED, because a
  fresh-state review of the landed code has not run yet.

- Observation: `resolveUniqueShellSessionAncestor` walked from the peer PID all
  the way to PID 1, requiring every ancestor (including those above an already
  matched registered shell) to be same-uid and identity-resolvable. When Laban
  or a test process runs under a root-owned `login` process, the walk hit that
  ancestor and returned nil even though a valid registered shell had already
  matched further down the chain, so lazy attach was dead whenever Laban's own
  ancestry contained a non-same-uid process. Evidence: the fresh-state reviewer
  reported `ControlDefaultOnTests.testNonPendingShellRegistrationRestoresLazyAttachAncestry`
  failing deterministically in login-hosted environments (2026-07-09). Fix: the
  same-uid and identity-resolvable requirement still covers every hop from the
  peer up to and including the matched shell; on the first ancestor above that
  point whose identity is unavailable or non-same-uid, the walk now stops and
  returns the already-matched shell instead of failing the whole resolution,
  since ancestors past a privilege boundary cannot extend or invalidate a
  same-uid chain that already closed. A boundary encountered before any match
  still fails closed, and the second-match ambiguity check within the same-uid
  chain is unchanged.

## Idempotence and Recovery

All added tests and scripts must be safe to run repeatedly. Approval records
should be revocable from Settings and should not require deleting UserDefaults by
hand. Test-only approval hooks must be gated behind explicit DEBUG/test flags and
must not silently enable approvals in normal GUI runs.

If a lazy approved dispatch command fails after approval but before dispatching
the downstream request, the CLI should ask again on the next command rather than
retrying stale approval state. If the implementation fallback uses a lease, the
CLI must discard it after one use or any failure. If the user denies, do not
cache denial permanently unless the user explicitly revokes or changes a stored
approval. If the process tree is ambiguous, fail closed and include enough
non-secret diagnostic detail to debug which sessions matched.

## Review Gate

A separate fresh-state reviewer must verify the following before this ExecPlan is
considered complete. The executing agent must not mark the plan done until this
gate passes.

- [x] `rg -n "redeemAttachBootstrap|LABAN_SESSION_ATTACH"
  Sources/LabanCLI/AgentProxyClient.swift Sources/LabanCLI/LabanCLI.swift`
  returns no hits in session command execution or lazy fallback code. Hits are
  allowed only in `AgentLauncher.swift` and only for `laban agent run`
  preflight/help text that never prints the value. (Verified 2026-07-09: no
  hits, rg exit 1.)
- [x] `rg -n "lazy.*sessionObserve|sessionObserve.*lazy|lease.*sessionObserve"
  Sources Tests` returns no production match. (Verified 2026-07-09: no hits,
  rg exit 1.)
- [x] `rg -n "switch tokenTier|case \\.appObserve|case \\.sessionObserve"
  Sources/LabanControl` has been reviewed, and tests cover every
  `ControlTokenTier` switch after adding `.approvedSession`. (Verified
  2026-07-09: switches in `LabanControlPolicy.grants/tokenScope/authorize`,
  `ControlRouteCatalog` `/debug/state` resolve and dispatch, and
  `LabanControlServer.sessionID(from:)` / `legacyQueryInput` all handle
  `.approvedSession` explicitly with no `default` over the tier; covered by
  `ApprovedSessionTokenTierSwitchTests` (4 tests),
  `ApprovedSessionStateRedactionTests` (2 tests), and end-to-end dispatch in
  `LazyAttachApprovedRequestTests.testAllowOnceDispatchesAndReturnsDownstream`.)
- [x] `swift test --disable-sandbox --filter ControlAttachAncestryTests` exits
  0. (7 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter ControlAttachPrincipalTests` exits
  0. (6 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter ControlAttachApprovalStoreTests`
  exits 0. (8 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter LazyAttachApprovedRequestTests`
  exits 0. (4 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter LazyAttachAllowlistTests` exits 0.
  (5 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter LazyAttachCLITests` exits 0.
  (7 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter LazyAttachPersistedApprovalScopeTests`
  exits 0. (2 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter ControlSecurityAuditTests` exits 0.
  (3 tests, 0 failures.)
- [x] `swift test --disable-sandbox --filter LazyAttachCLITests/testSessionCommandsIgnoreLABANSessionAttach`
  exits 0. (1 test, 0 failures.)
- [ ] Tests prove PID reuse is rejected by process start-time mismatch.
- [x] Tests prove missing process start time fails closed and does not fall back
  to PID-only matching.
  (`ControlAttachAncestryTests.testMissingShellStartTimeFailsClosed` and
  `testMissingPeerStartTimeFailsClosed`: PIDs match, start time is nil,
  eligibility is rejected.)
- [x] Tests prove stale shell registration is removed on session close.
  (`ControlAttachAncestryTests.testStaleShellRegistrationRemovedOnSessionClose`;
  the app-side call site is
  `ControlSessionLaunchCoordinator.swift:99`.)
- [ ] Tests prove a state approval cannot be reused for scroll, propose, another
  body, another session, or a second request.
- [x] Tests prove an always-allow record for `GET /debug/state` does not
  auto-approve any other route or intent sharing `.observeSensitive`.
  (`LazyAttachPersistedApprovalScopeTests.testStateApprovalDoesNotAutoApproveScroll`,
  `ControlAttachApprovalStoreTests.testFindMatchingRejectsDifferentRouteOrIntent`,
  and `LazyAttachApprovedRequestTests.testNonAllowlistedRouteReturns403BeforeUI`
  which proves `clipboard.read`, another `.observeSensitive` intent, cannot be
  lazily dispatched at all.)
- [x] Tests prove every non-allowlisted route/action is rejected before UI with
  `lazyRouteNotAllowed`.
  (`LazyAttachApprovedRequestTests.testNonAllowlistedRouteReturns403BeforeUI`
  asserts 403 `lazyRouteNotAllowed` and that the delegate was never prompted;
  `LazyAttachAllowlistTests.testRouteAndIntentLookup` covers the negative
  lookup path.)
- [ ] Tests prove "Always Allow This App for This Session" is hidden for unsigned, ad-hoc, shell,
  generic interpreter, package runner, and bundled Laban helper principals.
- [ ] Tests prove "Always Allow This App for This Session" is shown only for a stable signed
  non-generic principal and is keyed to that principal, not to the Laban CLI
  helper.
- [ ] Tests prove a fake delegate returning `.alwaysAllowSignedIdentity` for
  `node`, `python`, `zsh`, `bash`, `laban`, `laban-agent`, unsigned binaries,
  ad-hoc binaries, and raw `session request` cannot create a persisted record.
- [ ] Tests prove approval timeout, denial, rate limiting, and `sessionChanged`
  errors map to the documented CLI exit codes.
- [ ] Installed smoke verifies app/helper code signing and prints
  `LAZY_ATTACH_INSTALLED_SMOKE_OK`. UNBLOCKED (2026-07-09, later the same
  day): after the ancestry privilege-boundary fix (`ab53168`), a fresh
  `scripts/build-app` + `scripts/install-app` at `3782a3f` made
  `scripts/test-installed-agent-lazy-attach` print
  `LAZY_ATTACH_INSTALLED_SMOKE_OK` (exit 0) in the same login-hosted
  environment that previously failed;
  `scripts/test-installed-control-broker` also printed
  `CONTROL_BROKER_INSTALLED_SMOKE_OK`. Left unchecked for the fresh
  re-review to confirm. Original blocked record follows.
  ENVIRONMENT-BLOCKED (2026-07-09): the
  signing-verification half ran (codesign verify passed, both helper
  metadata blocks printed, expected agent path matched), but the harness
  half failed with `LAZY_ATTACH_INSTALLED_SMOKE_FAIL: first direct-agent
  lazy attach request failed: rejected`; the harness result file shows
  `laban: denied: {"error":"notDescendantOfRegisteredSession"}` exit 5.
  Root cause is the review shell's ancestry: the ancestry walk in
  `LabanControlServer.resolveUniqueShellSessionAncestor` continues past the
  matched registered shell up to PID 1 and fails closed on the root-owned
  `login` process that hosts this reviewer's iTerm2 shell (verified with
  `ps -o pid,ppid,uid,comm` up the chain: `login` runs as uid 0). The same
  failure reproduced against both `~/Laban.app` (built at 5dfeab3+dirty)
  and a fresh `scripts/build-app` bundle from this tree, sandboxed and
  unsandboxed, so it is hosting-environment-dependent, not a regression in
  the commit under review. Already tracked as the standing task
  "Investigate ancestry walk failing under non-same-uid ancestors
  (login-hosted shells)". Not counted as a gate failure, but the smoke has
  not been observed printing `LAZY_ATTACH_INSTALLED_SMOKE_OK` in this
  environment.
- [ ] Secret-scan fixtures prove logs/errors/audit do not contain lease tokens,
  app-observe tokens, `LABAN_SESSION_ATTACH`, raw Authorization headers,
  terminal text, or caller-provided reason text.
- [x] `./scripts/lint` exits 0. (Verified 2026-07-09.)
- [x] `git diff --check` exits 0. (Verified 2026-07-09.)

### Review findings

Fresh-state review, 2026-07-09, commit `ccc847d`. HEAD at review time was
`35d32e0`, two commits ahead of `ccc847d`, but `git diff --stat ccc847d..HEAD`
touches only `docs/` and `execplans/`; all reviewed Sources, Tests, and
scripts are identical to `ccc847d`. Test commands were run with the
module-cache workaround documented in Validation and Acceptance.

1. PID reuse by start-time mismatch is untested at the ancestry layer. The
   defenses exist in code
   (`Sources/LabanControl/LabanControlServer.swift:1627` compares the
   recorded shell start time against the freshly read identity, and
   `Sources/LabanControl/LabanControlServer.swift:1733` compares the peer
   start time during pre-dispatch revalidation), but no test exercises
   either mismatch branch: every `FakeProcessTreeInspector` in
   `Tests/LabanControlTests/ControlAttachAncestryTests.swift` and
   `Tests/LabanControlTests/LazyAttachPersistedApprovalScopeTests.swift`
   holds an immutable `let tree`, so the identity read at
   `registerAttachShellPID` time always equals the identity read at
   eligibility time. The only start-time-mismatch test is
   `ControlProcessIdentityAndSigningTests.testStartTimeMismatchFailsClosed`
   (`Tests/LabanControlTests/ControlProcessIdentityAndSigningTests.swift:63`),
   which covers the code-signing inspector, not shell or peer identity
   binding. A mutable fake tree that swaps the identity behind a PID after
   registration would close this.
2. The one-shot reuse item is only partially proven. Covered: scroll
   (`LazyAttachPersistedApprovalScopeTests.testStateApprovalDoesNotAutoApproveScroll`),
   another session
   (`testStateApprovalDoesNotAutoApproveOtherSession` and
   `ApprovedSessionStateRedactionTests.testApprovedSessionDifferentSessionIDIsRejectedByPolicy`),
   propose at the store layer
   (`ControlAttachApprovalStoreTests.testFindMatchingRejectsDifferentRouteOrIntent`).
   Not covered: another body (no test sends a mismatched `bodySHA256` or
   authorizes with a different body hash; every test constraint uses
   `bodySHA256: nil` or a hash of the actual body) and a second request (no
   test proves a completed `allowOnce` dispatch cannot be replayed and that
   a second identical request re-prompts;
   `LazyAttachApprovedRequestTests.testRateLimitedDuplicateRequest` only
   covers concurrent duplicates).
3. No test proves the "Always Allow" button is hidden for non-persistable
   principals. `ControlAttachApprovalPresenter` adds the button only when
   `request.canPersist`
   (`Sources/LabanApp/Control/ControlAttachApprovalPresenter.swift:34`),
   but `rg -rln "ControlAttachApprovalPresenter|canPersist" Tests` returns
   no hits: there is no presenter rendering test at all. The underlying
   `ControlAttachPrincipal.isPersistable` logic is tested for a shell
   (`zsh`), a generic interpreter (`python3`), an unsigned/ad-hoc binary,
   and the bundled helper in
   `Tests/LabanControlTests/ControlAttachPrincipalTests.swift`, but no test
   covers a package runner (`npm`, `npx`, `pnpm`, ...) at any layer, and the
   `canPersist`-to-button mapping is unverified. Milestone 4 acceptance
   ("Unit or debug-hook tests cover the presenter rendering ...") was not
   implemented.
4. No test proves "Always Allow" is shown only for a stable signed
   non-generic principal and persisted keyed to that principal. The
   principal-selection half is covered
   (`ControlAttachPrincipalTests.testPrincipalCanPersistForSignedNonGeneric`,
   `testBundledLabanHelperIsNeverPrincipal`), and store matching keys on
   `principalIdentityFingerprint`, but no test drives the server persistence
   path (`Sources/LabanControl/LabanControlServer.swift:1546`) with a
   delegate returning `.alwaysAllowSignedIdentity` and then asserts the
   stored record is keyed to the principal rather than the `laban` helper.
   The only coverage is the installed smoke harness
   (`Sources/LabanAgent/LazyAttachTestHarness.swift`), which skips the
   persistence checks for ad-hoc-signed helpers and is environment-blocked
   here (see the smoke item).
5. The malicious-delegate check has zero coverage: `rg -n "alwaysAllow"
   Tests --glob '*.swift'` returns no hits, so no test returns
   `.alwaysAllowSignedIdentity` for `node`, `python`, `zsh`, `bash`,
   `laban`, `laban-agent`, unsigned binaries, ad-hoc binaries, or raw
   `session request` and asserts no record is persisted. The server-side
   guard exists (`Sources/LabanControl/LabanControlServer.swift:1540`
   downgrades non-persistable always-allow decisions), but Milestone 2
   acceptance explicitly required tests proving a fake delegate cannot
   create such records.
6. CLI exit-code mapping is only half tested. Covered: denial maps to 5
   (`LazyAttachCLITests.testDenialMapsToExitCode5`) and timeout maps to 4
   (`testTimeoutMapsToExitCode4`). Not covered: `sessionChanged` and
   `rateLimited` mapping to 5; `lazyAttachExitCode` handles them
   (`Sources/LabanCLI/LabanCLI.swift:309`), and `LazyAttachClient` raises
   them (`Sources/LabanCLI/LazyAttachClient.swift:104` and `:107`), but
   `rg -n "rateLimited|sessionChanged" Tests/LabanCLITests` returns no
   hits. There is also no server-level test producing `408 approvalTimeout`
   or `409 sessionChanged` (the slow delegate in
   `testRateLimitedDuplicateRequest` is only used to hold a pending slot).
7. The secret-scan item is only partially proven.
   `ControlSecurityAuditTests.testAuditPayloadsContainNoTokens` asserts
   audit payloads contain no `token` substring, no `LABAN_SESSION_ATTACH`,
   no `Authorization`, and not the live app-observe token value, and
   `LazyAttachCLITests.testNoTokenInStderr` plus
   `testSessionCommandsIgnoreLABANSessionAttach` cover CLI stdout/stderr.
   But no fixture scans for a lease/approved-token value (the internal
   token minted at `Sources/LabanControl/LabanControlServer.swift:1409` is
   never asserted absent from responses, errors, or audit), and no fixture
   plants a terminal-text sentinel and proves it stays out of audit
   payloads. Caller-provided reason text is vacuously safe: the request
   parser (`Sources/LabanControl/LabanControlServer.swift:1245`) accepts no
   reason field, so nothing can leak; noting this for completeness rather
   than as a gap.

Review status: FAILED (2026-07-09, commit ccc847d): 7 findings, see Review
findings. Items 4 through 12 (test-suite runs), the three grep checks, lint,
and `git diff --check` all passed; the installed smoke is
environment-blocked, not failed.
