# Dialog-First Session Observe

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current. It changes the control-plane security model, so it is
design-first: Milestone 0 (this document + a fresh-eyes security review of the
Threat Model below) must pass before any implementation milestone starts.

## Purpose / Big Picture

Today an agent running in a Laban tab can, with one approval dialog, read only
low-sensitivity app metadata (`app.state`: tab titles, cwd, process names). To
read the actual terminal, screen text, scrollback, selection, it must have been
launched through `laban agent run -- <agent>`, which redeems a C14 attach
bootstrap and sets `LABAN_AGENT_CONTROL_URL`. That requires foresight nobody
has: you cannot know at launch time that a session will later want agent
control, and the need is reactive (it surfaces when the agent tries).

After this change, the **approval dialog is the primary path and grants the full
own-session read surface**. A user who approves "Allow Codex to read this
session?" gives that code-signed principal, for that one session, the whole
observe family: screen text and scrollback (`terminal.getText`), session detail
(`session.detail`), selection, find, shell-integration phase, scroll indicator,
plus command proposals. "Always Allow" persists it per (principal, session).
`laban agent run` remains only as an optional dialogless path for CI and scripts
that cannot click a dialog; it is no longer required for interactive use and is
no longer the primary path.

The demonstrable result: from a Claude Code started directly in a Laban tab (no
`laban agent run`, no agent-attached launch flag), run:

    laban session get-text --screen --json

Laban shows one dialog naming the code-signed principal, the session, and
"Read this session's screen text and scrollback". Choose "Allow Once" and the
command returns the actual visible grid. Choose "Always Allow" and later reads
in that session, screen text, scrollback, selection, find, succeed with no
further prompt. `laban context --json` returns a real prompt-ready bundle. A
second, different principal, or the same principal in a different session,
prompts again. And no dialog ever grants input, clipboard, tab switching, or
another session's content.

## Progress

- [x] (2026-07-11) Gathered current state: `ControlLazyAttachAllowlist`
  (3 entries), `ControlAttachApprovalRecord` (already carries
  `allowedIntentIDs`/`capabilities`/`maxDataSensitivity`), the
  `.approvedSession` request-exact `ControlTokenConstraint`, invariant I4
  (`testLazyAllowlistExcludesHighSensitivityIntents`), and the CLI split
  (`performSessionRequest` = lazy fallback vs `performAgentProxyRequest` =
  broker-only).
- [x] (2026-07-11) Wrote this design (Milestone 0 deliverable).
- [ ] Milestone 0: fresh-eyes security review of the Threat Model passes.
- [ ] Milestone 1: server, family-scoped lazy grant + constraint. NOT STARTED.
- [ ] Milestone 2: dialog sensitivity wording + persisted-record scope. NOT STARTED.
- [ ] Milestone 3: CLI, session reads use lazy fallback; broker demoted to CI. NOT STARTED.
- [ ] Milestone 4: invariant + parity updates, docs, installed verification. NOT STARTED.
- [ ] Implementation Review Gate passed.

## Definitions

- **Own-session read family** (the exact set this plan makes dialog-grantable):
  the `gui:true`, session-scoped, read-only intents an agent already gets for
  its own session over the broker path:
  `terminal.getText`, `session.detail`, `selection.read`, `find.state`,
  `shellIntegration.state`, `scrollIndicator.state`, `app.state` (redacted to
  the owning session), plus `command.propose` (a user-reviewed suggestion, not
  a read but same observe-only family). This is exactly the set the broker
  session-observe credential already grants; nothing new is exposed, only the
  path to it changes.
- **Family grant**: an approved-session authorization whose constraint is "any
  intent in the own-session read family, for this session", rather than the
  current one-exact-request binding.
- **Sensitivity tier**: `.observeSensitive` reads carrying terminal *content*
  (`terminal.getText` scrollback, `session.detail` grid, `selection.read`) are
  the high tier; `app.state`/`shellIntegration.state`/`scrollIndicator.state`
  are the low tier (metadata). The dialog wording scales to the highest tier the
  grant covers.

## Threat Model (Milestone 0 gate reviews this)

The security question this plan turns on: **is a one-click approval dialog a
strong enough consent to release own-session terminal content?** The shipped
design said no and used the broker/C14 path as a stronger proof. This plan says
yes, and the review must accept or refute each point below.

**Why the dialog is strong consent (the core claim).** The dialog already
shows, all server-derived, not caller-supplied: a code-signing-verified
principal identity (team/bundle/designated-requirement), the exact Laban session
(id suffix, not a spoofable title), and the exact operation. "Always Allow" is
offered only for a stable signed non-generic principal and is keyed to that
signing identity, not to a path or the `laban` helper. This is a real, informed,
revocable, per-principal consent. It is arguably *stronger* than the broker
path, which grants the entire session-observe surface silently the moment
`laban agent run` succeeds, with no per-operation visibility to the user at all.

**What must stay locked regardless (the review verifies each as an invariant):**
- (a) No dialog grant ever includes `.input` (typeText/sendKey/paste/mouse),
  `.clipboard`, tab lifecycle, focus change, or any actuation. The family is
  read-only + propose. `.input`/`.clipboard` stay fixture/headless-only.
- (b) Cross-session stays `403`. A family grant is scoped to the one approved
  session; another session's content is never reachable (contract C12).
- (c) Unsigned / ad-hoc / generic-interpreter / helper principals get
  **Allow Once only**, never "Always Allow". Persisted family grants require a
  stable signed non-generic principal (existing `isPersistable` rule).
- (d) A different principal, or the same principal in a different session, or a
  principal whose live code-signing no longer validates the stored requirement,
  re-prompts (no auto-approve).
- (e) The bundled `laban`/`laban-agent` are never the persisted principal
  (existing chain-derivation rule).
- (f) Deny arms the existing per-(principal, session) cooldown; approval
  rate-limits and one-visible-prompt coalescing are unchanged.

**Residual risks to accept explicitly in the review:**
- Descendants of the granted principal inside the session share its widened read
  scope for the grant lifetime (same accepted residual as today's lazy attach;
  the boundary is the session + the human, Laban cannot distinguish the agent
  from code the agent ran).
- The persisted approval-record HMAC is tamper-evidence, not a boundary (key is
  same-user-readable); authority lives in the live per-request checks
  (code-signing revalidation, session match, family membership), not the record.

## Design

### Server (Milestone 1)

The lazy-attach request path (`LabanControlServerLazyAttach.swift`) currently:
resolves one route+intent, checks `ControlLazyAttachAllowlist.isAllowlisted`,
and on approval mints `.approvedSession` with a request-exact
`ControlTokenConstraint` (method/path/query/bodySHA256/route/intent). Change:

1. Replace the 3-entry `ControlLazyAttachAllowlist` with a
   **family allowlist**: a request whose resolved intent is in the own-session
   read family is eligible. Keep the CLI-command lookup helpers. Non-family
   intents (anything requiring `.input`/`.clipboard`/`.fixture`, cross-session,
   lifecycle) stay `403 lazyRouteNotAllowed` before UI.
2. On approval, mint a **family-scoped** approved authorization: a new
   `ControlTokenConstraint` mode (or a sibling `ControlSessionFamilyGrant`) that
   authorizes any family intent for the approved session, instead of one exact
   request. The policy layer (`LabanControlPolicy.authorize`) accepts a family
   grant when: intent is in the family set, target session == the approved
   session (C12 unchanged, omitted target resolves to own session), and (for
   persisted/Always) the live principal still validates the stored signing
   requirement. Capabilities granted are exactly `{.observe, .observeSensitive,
   .propose}` (never `.input`/`.clipboard`/`.navigate`-of-another-session).
3. Carry the highest data-sensitivity the grant covers into the approval
   request so the dialog can scale wording (Milestone 2).

Keep: peer-cred/uid guard, ancestry/principal derivation, one-shot vs Always
distinction, `409 sessionChanged` pre-dispatch revalidation, all rate limits.

### Dialog + persistence (Milestone 2)

`ControlAttachApprovalPresenter`: the message stays "Allow <principal> to
observe this Laban session?" (already fixed off "control"). Add a **Data** row
that scales to the grant's sensitivity: high tier reads
"This session's screen text, scrollback, and selection" (make it unmistakable
that terminal *content* is included); low tier keeps "Private session
metadata". "Not included" row stays: "No keyboard input, clipboard, tab
switching, or other sessions." `ControlAttachApprovalRecord` already has
`allowedIntentIDs`/`capabilities`/`maxDataSensitivity`; a family grant stores
the full family set + `.observeSensitive` cap + the high sensitivity, keyed to
(principal signing identity, session). Persistence gated by the existing
`isPersistable`.

### CLI (Milestone 3)

Route the session read commands through the lazy-fallback path so they work with
no broker: `session get-text`, `context`, `session current`, `session detail`
change from `performAgentProxyRequest` (broker-only, `requireAgentControlURL`)
to `performSessionRequest` (broker if `LABAN_AGENT_CONTROL_URL` present, else
lazy approved dispatch). `session state`/`scroll`/`propose` already do this.
`laban agent run` and `session proxy` stay broker-only and unchanged; update
their help text to say the broker is now an optional CI/no-dialog path, not a
prerequisite. No menu item is needed (the removed "New Agent-Attached Session"
stays removed; on-demand full observe now comes from the dialog, not a special
tab).

### Invariants + parity (Milestone 4)

Invariant **I4 is deliberately reversed** and must be rewritten, this is the
load-bearing security decision, record it in the Decision Log and have the
review sign it: the lazy-reachable set now MAY include `.observeSensitive`
content reads (the whole point), but the test must now assert the *new* ceiling:
every family-allowlisted intent has `sideEffects.ptyInput == false`, is
`gui:true` and session-scoped, and its `requiredCapability` is in
`{.observe, .observeSensitive, .propose}` (never `.input`, `.clipboard`,
`.fixture`, `.navigate`). Add a positive invariant: a family grant authorizes
exactly the family set and denies any non-family intent, cross-session, and any
`.input`/`.clipboard` intent even for the approved principal/session. Update the
`.propose` gui-allowlist parity if `command.propose` classification is touched
(it should not need to change). Update `docs/process/control-plane-threat-model.md`
in the same commits (per its rules-for-changes).

## Milestones

### Milestone 0: design review. Status: IN REVIEW
A fresh security reviewer reads the Threat Model and either records
"threat model ACCEPTED" with the (a)-(f) locks and the two residuals explicitly
confirmed, or records blocking findings. No implementation starts until (a).

### Milestone 1: family-scoped server grant. Status: NOT STARTED
Family allowlist + family-grant authorization + policy check + sensitivity
carry. Tests (`DialogFirstObserveServerTests`): a family intent (get-text) is
eligible and, once approved, authorizes get-text AND session.detail AND
selection for the session without re-approval; a non-family intent (typeText)
is `403 lazyRouteNotAllowed` before UI; cross-session family intent `403`; a
family grant never authorizes `.input`/`.clipboard`; `409 sessionChanged` on
identity change still fires.

### Milestone 2: dialog wording + persistence. Status: NOT STARTED
Sensitivity-scaled Data row; family record persisted for signed principals
only. Tests: presenter shows the content-inclusive Data row for a high-tier
grant and the metadata row for low-tier; an unsigned principal gets no
Always-Allow; a persisted family record auto-approves later family reads for the
same (principal, session) and re-prompts for a different principal/session.

### Milestone 3: CLI dialog-first. Status: NOT STARTED
get-text/context/current/detail use lazy fallback. Tests: with no
`LABAN_AGENT_CONTROL_URL`, `laban session get-text` reaches lazy approved
dispatch (not an exit-3 broker error); broker-present behavior unchanged;
`laban agent run`/`session proxy` still broker-only; no token in stdout/stderr.

### Milestone 4: invariants, docs, installed proof. Status: NOT STARTED
Rewrite I4 to the new ceiling + positive family invariant; threat-model doc
amended same-commit; operator guide updated (dialog-first primary, broker = CI
option); an installed smoke drives the two-approval get-text flow. `scripts/check`
green.

## Validation and Acceptance

Implementation acceptance (later):

    swift test --disable-sandbox --filter DialogFirstObserveServerTests
    swift test --disable-sandbox --filter ControlPlaneInvariantTests
    swift test --disable-sandbox --filter 'LabanCLITests|CatalogParityTests|LabanAppTests'
    swift run LabanControlGen --check
    ./scripts/check

Behavioral: from a directly-started agent in a tab, `laban session get-text
--screen --json` prompts once, returns real grid on Allow; "Always Allow" makes
later family reads silent; a different principal/session re-prompts; input,
clipboard, tab-switch, and cross-session reads are refused; `laban agent run`
still works with no dialog for CI.

## Decision Log

- Decision: The approval dialog becomes the primary path and grants the full
  own-session read family; `laban agent run` is demoted to an optional
  dialogless CI path, not required and not primary.
  Rationale: the broker's launch-time gating demands foresight nobody has; the
  need for control is reactive. The dialog is strong, informed, revocable,
  per-principal, per-session consent, arguably stronger than an env bootstrap
  that grants the whole surface silently.
  Date/Author: 2026-07-11 / user; plan by Fable.
- Decision: One approval grants the whole read family (not per-intent).
  Rationale: per-intent approval walls the agent behind a burst of dialogs on
  first real use; the family is a single coherent "read this session" capability
  and the record model already supports an intent set.
  Date/Author: 2026-07-11 / user.
- Decision: Invariant I4 is intentionally reversed (lazy MAY now reach
  `.observeSensitive` content) and rewritten to a new ceiling
  (no `.input`/`.clipboard`/`.fixture`, session-scoped, read-only + propose).
  Rationale: this is the security-model change itself; the ceiling that must
  never move is actuation and cross-session, not content.
  Date/Author: 2026-07-11 / Fable; requires Milestone 0 review sign-off.

## Review Gate

- [ ] 0. Fresh security reviewer records "threat model ACCEPTED" (or findings),
  explicitly confirming locks (a)-(f) and the two residuals. Implementation
  gated on this.
- [ ] `rg -n "getText|session.detail|selection.read" Sources/LabanControl/ControlLazyAttachAllowlist.swift`
  or its successor shows the family is reachable, and a policy test proves a
  family grant authorizes every family intent for the session.
- [ ] A test proves a family grant denies `typeText`, `paste`, any
  `.clipboard` intent, and any cross-session intent, even for the approved
  principal/session.
- [ ] Rewritten I4 passes and fails if any `.input`/`.clipboard`/`.fixture` or
  cross-session intent is added to the family (mutate, expect fail, revert).
- [ ] Presenter test: high-tier grant Data row names terminal content; unsigned
  principal has no Always-Allow.
- [ ] CLI test: `laban session get-text` with no broker env reaches lazy
  approved dispatch, not an exit-3 broker error; `laban agent run` unchanged.
- [ ] `docs/process/control-plane-threat-model.md` amended in the same commits;
  `swift run LabanControlGen --check` + `./scripts/check` green.

Review status: NOT REVIEWED (design complete 2026-07-11; Milestone 0 pending).
