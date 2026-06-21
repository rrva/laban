# Phase 2: Mount Live (Observe-First) + Security Floor + Flip the Default

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at the
repository root). Keep `Progress` and `Validation and Acceptance` current as work
proceeds. It is the third executable phase of the program in
`execplans/agent-first-terminal-design.md` (Phase 2; read §3.1, §4.2, **§5 in
full**, and §6 "Phase 2" there) and is governed by **ADR 0023** (architecture) and
**ADR 0024** (security). Phase 0 shipped as
`execplans/completed/agent-first-phase0-control-seam.md` (commit `0a2a230`); Phase 1
shipped as `execplans/completed/agent-first-phase1-intent-registry-and-labancontrol.md`
(Review Gate APPROVED 2026-06-20).

> **Status: DRAFT — REFRAMED 2026-06-20 to observe-first (not started).** An earlier
> draft of this phase mounted a live **agent-driven** control surface (input/mouse/
> clipboard actuation, an app-wide control token). After a security deliberation
> (recorded in the Decision Log) that direction is **deferred**: Phase 2 ships an
> **agent-observable terminal substrate**, not an agent-driven one. The actuation
> layer moves to a future **Terminal-Lease / Computer-Use ADR**. This rewrite
> supersedes the prior actuation-oriented draft; the git history holds it.

## Strategy Pivot (2026-06-20) — read first

**The two products we were conflating:**

| Product | Promise | Security model it demands |
| --- | --- | --- |
| **Agent-observable terminal** (this phase) | "The agent can understand a terminal session truthfully." | Session-scoped reads, audit, indicator, no actuation. |
| **Agent-driven terminal / computer use** (deferred) | "The agent can act *as the user*." | Explicit per-session user lease, command approval, sandbox, no self-injection, no cross-tab. |

**Why observe-first is the right sequencing, not a retreat.** The observe substrate
("see accurately, understand session state, integrate via typed tools") is the layer
the actuation feature needs *underneath it anyway* — shipping it first wastes nothing.
What we defer is exactly the part that is *impersonation*: typing as the user
(arbitrary command execution that also launders past the embedded agent's own
permission model) and reading across tabs (cross-session exfiltration). Those always
require the lease/consent/approval machinery regardless of when they are built. "Trust
by default" (Codex/Claude computer-use) only works **inside an enforced boundary**;
Laban has no boundary between tabs/sessions today, so an app-wide token is ambient
authority by accident.

**What Phase 2 now delivers (observe-first):**
- **Two observe-only token tiers**, no app-wide control token (see "Token & capability
  model"). A same-user process reading `control.json` gets a redacted app summary; an
  agent Laban spawns into a session gets sensitive reads **for its own session only**.
- **Session-scoped truth:** own-session terminal state (prompt/running/finished,
  visible output, cwd/process, exit code, modes, selection, find), byte-identical to
  the headless wire.
- **Benign own-session navigation** (scroll own session, bring own tab to front) — no
  input, no mouse actuation, no clipboard, no destructive tab lifecycle, no cross-tab.
- **Command proposals:** an agent proposes the exact next command as a **data object**
  the user reviews and runs — never bytes into a tty. This recovers most of the
  "agent helps me drive my terminal" value with zero PTY-input risk.
- The full **security floor** (ADR 0024): capability enforcement, two-credential model,
  `0600` token file, Host/Origin validation, deny-by-default classification, audit,
  indicator, disable switch, no-token-logging, and the gated default-on flip.

**Deferred to a future Terminal-Lease / Computer-Use ADR (NOT in Phase 2):**
- All input actuation — `terminal.typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/
  `mouseDrag` (stay **headless/fixture-only** for E2E; never on the live GUI surface).
- Any cross-tab / whole-app sensitive read or control by an env token.
- Clipboard read/write on the live surface; destructive/lifecycle tab ops.
- Autonomous "agent drives the terminal" mode — which, when built, is a distinct
  product mode: user picks the target session, short-lived **lease**, visible
  indicator, command approval/classifier, no self-injection, audit + revocation.

**Roadmap the substrate enables (beyond Phase 2):** a read-only **MCP front door**
generated from the catalog; the **event push stream** (already Phase 3 in the program —
`EventLog` promoted to push); full **trace/replay** export. Phase 2 keeps the
architecture that makes these cheap (one catalog, one policy, router-parity, generated
discovery).

> **Amendments owed (not done in this plan; flagged for approval):** ADR 0024's token
> model (app-wide control token → two observe tiers + deferred lease) and the program
> doc `agent-first-terminal-design.md` (actuation recast as a future lease mode) must
> be updated to match. spec.md notes the product-scope shift. Do these after this plan
> is approved.

## Purpose / Big Picture

After Phase 1 there is **one server** (`LabanControlServer` in `LabanControl`), **one
route catalog** (`ControlRouteCatalog`), and **one typed vocabulary** (`IntentCatalog`)
mounted by both the GUI (`LiveIntentRouter`, surface `.gui`) and `laban-agent`
(`HeadlessIntentRouter`, surface `.headless`). Two gaps remain:

1. **The GUI serves almost nothing.** `LiveIntentRouter` implements only `app.state`,
   `tab.select`, `terminal.typeText`, `terminal.sendKey`; every other read is
   `headlessOnly` and `404`s on the GUI. An agent attached to the running app cannot
   observe it.
2. **Capability is classified but not enforced, and there is one token.** The server
   mints a single token; `descriptor.requiredCapability` is metadata the guard never
   checks; `control.json`'s token, if it granted authority, would let any same-user
   process drive the terminal.

Phase 2 closes both **for the observe surface only**:

- **Mount live (observe).** Expand `LiveIntentRouter` to project the live `AppModel` +
  `AppSessionCoordinator` into the **same wire** the headless runtime emits, scoped to
  the caller's **own session**. Shared `AppModel → DTO` projections move to `LabanCore`
  so both routers are byte-identical by construction.
- **Security floor (ADR 0024 §5, observe-first variant).** Two **observe** credentials:
  an **app-observe** token in `control.json` (redacted `app.stateSummary` only) and a
  **session-observe** token injected per-session into the env of children Laban spawns
  (`.observeSensitive` + benign nav, **scoped to that session**). A `LabanControlPolicy`
  **generated from the catalog** enforces `requiredCapability` *and* session scope per
  request (deny-by-default). Add the "agent attached" indicator, a disable switch,
  audit to the `EventLog`, and the guarantee that **no token value is ever logged**.
- **Command proposals.** A typed data exchange: the agent proposes a command; the user
  reviews and runs it. No PTY input.
- **Catalog-parity test** + **flip the default** behind the §5.4 release checklist.

**The headless wire stays byte-stable for everything Phase 1 shipped.** `laban-agent`,
`LabanDebugTests`, the `/debug` discovery doc, and `schemas/debug/*` are unchanged. The
only *new* observable behavior is: (a) the GUI answers the **own-session observe**
surface; (b) capability/scope tiers return `403`; (c) input/mouse/clipboard/cross-tab
return `404`/`403` on the GUI (deliberately removed from the live surface); (d) the
default-on flip in 2F.

## Token & Capability Model

**Capabilities** (`Capability` in `Sources/LabanCore/Intents/IntentCatalog.swift`):
`observe, observeSensitive, control, clipboard, fixture` — Phase 2 also keeps
**`input`** (added for the actuation family, used **only** on the headless/fixture
path). On the live GUI surface, `control` shrinks to **benign own-session navigation
only**.

**Tokens (two observe-derived tokens; no app-wide control token):**

| Token | Where it lives | Grants | Scope |
| --- | --- | --- | --- |
| **app-observe** | `control.json` (`0600`) | `.observe` (redacted `app.stateSummary`) | whole-app but **non-sensitive** |
| **session-observe** | env of an **agent-attached session only** (per-session; var `LABAN_SESSION_OBSERVE_TOKEN`) | `.observeSensitive` + benign own-session navigation (`.control`: scroll/select own tab) | **its own session only** |
| **fixture** | headless tests only (`laban-agent`/`LabanDebug`) | all incl. `.input` | whole-app (test-only; `validate()` bars `.fixture` on `.gui`) |

`.clipboard` is granted to **no token**; `.input` only to the fixture token. The
session token is **observe-derived** (it also grants benign own-session navigation),
not a control token. No live GUI token grants `.input`, `.clipboard`, cross-session,
or destructive tab ops. The headless wire stays fixture-driven, so C9 holds.

**Agent-attached injection only — no ambient token in normal shells (C10).** The
session-observe token is injected **only** into sessions
explicitly marked/launched **agent-attached** — never into a normal user shell. A
normal shell tab inherits at most `LABAN_CONTROL_URL` (discovery), never a
session-observe token, so an arbitrary child process in a normal tab (npm scripts,
test binaries, `curl | sh`, editor plugins, REPL/background jobs) can read **nothing**
sensitive — it cannot reach own-session scrollback/grid/cwd/process/selection/find/
accessibility. Default-on grants the machine *discovery* (the app-observe file) and
grants sensitive observation **only** to explicitly agent-attached sessions.

**Preallocated session identity (C11).** A session-observe token
must carry the real `sessionID`, but `Session.init` generates its own id today and the
env is composed before the `Session` exists. So introduce a `SessionLaunchContext {
sessionID, tabID?, isAgentAttached, environmentOverrides, sessionObserveToken? }`:
`AppModel`/the session registry **preallocates `sessionID`** before invoking the
session factory; the launch paths (`Session.realShell`/`parserOnly`, laband, labpty)
accept the preallocated id (`Session.init` no longer always self-generates it); the
token is minted from that id **before envp composition** and injected **only** when
`isAgentAttached`. Without this, an implementer mints a token with the wrong/late id or
falls back to app-wide scope.

**Session scoping + active-session fallback (the core invariant).** The policy
enforces, for `.observeSensitive`/`.control`, `targetSession ∈ tokenScope` —
cross-session → `403`. **For a session-bound token an omitted target `sessionID`
resolves to the token's own session, never the app's active tab** (otherwise a focus
change would leak another tab through a legacy active-session route). Whole-app reads
(`session.list`, rich `app.state`) are **redacted to the owning session** for a
session-bound token. A whole-app token (fixture, or a future explicit grant) + omitted
target → legacy active-session behavior; the app-observe token → redacted app summary
only. This closes the cross-tab read breakout: an agent in tab A cannot read tab B's
selection/scrollback/cwd/find-needle.

## Progress

> All milestones **not started**. Update each item to `[x] (date)` as it lands; split
> partially-done items into "done"/"remaining" per `PLANS.md`.

Milestone 2A — Capability + scope enforcement, two observe tiers (`LabanControl`):
- [ ] Two start paths: GUI `start()` mints an **app-observe** token (→ `control.json`) and a **session-observe minter** (per-session, session-bound); returns them to the in-process caller. Headless `start(host:port:)` keeps `debugToken` (fixture-class, whole-app) so `laban-agent`/`LabanDebugTests` are byte-stable. **`ControlReadiness` unchanged** (`{debugServer, debugToken, pid, runId}`); no sensitive token serialized into readiness JSON or any world-path file.
- [ ] `LabanControlPolicy` (generated from `IntentCatalog`): `grants(appObserve)={.observe}`; `grants(sessionObserve)={.observe,.observeSensitive,.control}` (benign nav only); `grants(fixture)={.fixture,.observe,.observeSensitive,.control,.input}`. No token grants `.clipboard`; only fixture grants `.input`. `authorize(intentID:, granted:, targetSession:, tokenScope:)` checks `requiredCapability ∈ granted` **and**, for `.observeSensitive`/`.control`, `targetSession ∈ tokenScope`. `targetSession` is derived per C12 (session-bound token + omitted target → the token's **own** session, never the active tab; whole-app token → legacy active-session). Unknown id → deny.
- [ ] Deny-by-default made real: remove the catalog builder's implicit `requiredCapability`/`dataSensitivity` defaults (or track `explicit`); `IntentCatalog.validate()` + `LabanControlGen --check` **fail** unless every descriptor declares both explicitly.
- [ ] Guard taxonomy: missing/invalid token → `401`; bad `Host`/any `Origin` → `403`; capability-insufficient → `403`; cross-session sensitive read → `403`. **`isLoopbackHost` rejects non-numeric ports** (`localhost:evil`, `127.0.0.1:evil`, `[::1]:evil`). Token values never logged.
- [ ] `LabanControlTests` (spy router): app-observe token → `.observe` `200`, `.observeSensitive`/`.control` `403` (no router call); session-observe token → own-session `.observeSensitive` `200`, **other-session `403`**; `.input`/`.clipboard` rejected for all non-fixture tokens (policy-level assertion); missing → `401`; forged `Host`/any `Origin`/non-numeric port → `403`. `control.json` contains the app-observe token only.

Milestone 2B — Live session-scoped observe surface (`LabanApp`):
- [ ] Shared `AppModel`/`Session` → DTO projections relocated to `Sources/LabanCore/Control/Projections/*` (public); `HeadlessIntentRouter` re-points to them **byte-identically** (headless `LabanDebugTests` + `DiscoveryEndpointParityTests` unchanged). `LabanDebug` typealiases relocated DTOs.
- [ ] `LiveIntentRouter` implements the **own-session** observe family against the live `AppModel`/`AppSessionCoordinator`: `app.accessibility`, `terminal.modes`, `session.detail`, `find.state`, `selection.read`, `shellIntegration.state`, `scrollIndicator.state`, plus rich `app.state` and `session.list` **redacted to the owning session**. Each returns the shared DTO. Sensitivity split (explicit classification): the trigger for `.observeSensitive` is **terminal content** (grid/scrollback text, selection, find needle, accessibility text, keystroke log); `.observe` covers `terminal.modes`, `scrollIndicator.state`, and the whole-app `app.stateSummary` (which now also carries per-tab title/cwd/repo/process metadata — `ps`-equivalent, 2026-06-20). The rich `session.detail`/`app.state` DTOs stay `.observeSensitive` + session-scoped because they **also** carry content (grid), even though their process-metadata subset is separately available via the summary.
- [ ] Benign own-session navigation only under `.control`: `terminal.scrollViewport` and `tab.select` (bring own tab to front). **No input/mouse/clipboard, no destructive tab lifecycle, no cross-tab.** The input-actuation family stays `headlessOnly` + `.input`; remove/build-gate the Phase-1 `LiveIntentRouter.typeText`/`sendKey` so input lives only in `LabanDebug`.
- [ ] Catalog availability flips: own-session observe ids → `gui:true` with explicit `requiredCapability`/`dataSensitivity`; renderer/atlas/pixel-probe/capture/persistence stay `headlessOnly` (noted boundary). `swift run LabanControlGen --write` if route metadata changed; `swift test`; `scripts/check`.

Milestone 2C — Catalog-parity + classification completeness:
- [ ] `CatalogParityTests` at the **HTTP-route level**: over every `availability.gui && availability.headless` intent, both surfaces return a non-error response for a representative input and pure reads' sorted-key JSON **shape** matches. Fails if either surface drops/diverges on a shared intent.
- [ ] Completeness invariants: every descriptor declares explicit `requiredCapability` + `dataSensitivity`; **no `gui:true` descriptor requires `.input` or `.clipboard`**; the set of `gui:true` ids is exactly what `LiveIntentRouter` implements (own-session observe + benign nav).
- [ ] **`.control` hard allowlist** (positive test, not just the `.input`/`.clipboard` ban): the set of `gui:true` descriptors requiring `.control` equals **exactly** `{tab.select, terminal.scrollViewport, command.propose}` — the test fails if `tab.close`/`session.kill`/`restart`/`detach`/`tab.new` (or any other op) ever becomes a `gui:true` `.control` descriptor.

Milestone 2D — Indicator, disable switch, audit, no-token-logging:
- [ ] `ControlSecurityObserver` boundary in `LabanControl` (`didAuthorize/didDeny/didPrivilegedActivity`); `LabanControl` keeps `["LabanCore"]`-only deps and never imports app UI/logging internals. `LabanApp` supplies the observer owning indicator state + the persistent `EventLog` sink.
- [ ] "Agent attached" indicator lights on any successful **privileged** request (`.observeSensitive` or benign `.control`) — TTL-based (HTTP has no durable "connected").
- [ ] User-facing disable switch (menu/setting) stops the server and removes `control.json`.
- [ ] Every privileged access emits an audit event via the observer to the `EventLog` (intent id, capability, surface, session, time — **no token, no payload secrets**).
- [ ] A test greps logs and non-token artifacts for **both** minted tokens → **zero** hits; `control.json` parsed separately (it holds the app-observe token only).

Milestone 2E — Command proposals:
- [ ] A typed `command.propose` exchange: the agent submits a proposed command (text + rationale + target session) as a **data object**; Laban surfaces it to the user (review UI), who runs or dismisses it. **Never** written to a PTY by Laban. Requires session-observe scope for its target session; audited; lights the indicator.
- [ ] DTO + schema added to the catalog/discovery (gated, byte-stable via `LabanControlGen`); covered by `LiveIntentRouter`/`HeadlessIntentRouter` parity.

Milestone 2F — Flip observe-on-by-default (release-checklist gate):
- [ ] The §5.4 release checklist (nine items + the env-secrecy gate, reproduced below) each backed by a passing test/mechanical check.
- [ ] Default mount flips: GUI starts the server **observe-on** without `LABAN_CONTROL_SERVER=1`; the env var becomes a force-disable, not the on-switch. `.observeSensitive` still requires the per-session env token.
- [ ] Credential lifecycle: bind the server early (`LiveIntentRouter` via a **late-bound model provider**) and merge **`LABAN_CONTROL_URL` only** into the shared `ShellIntegrationLaunch.environmentOverrides`. The **session-observe token is per-session, session-bound, and injected ONLY into agent-attached sessions** (C10): normal/default/restored shells get **no** session-observe token. Use a `SessionLaunchContext` with a **preallocated `sessionID`** (C11) so the token is minted from the real id before envp composition; gate injection on `isAgentAttached`. If the first/default session is itself agent-attached (launch flag), the server must be bound before it spawns; the common case (default = normal shell, no token) has no such race. Across all backends (in-process `environment:`, laband `environmentPatch`, labpty `envp`). **No wire change** (does not touch the ADR 0007 freeze).
- [ ] `scripts/check` green; the GUI is unchanged for humans (no new windows, no behavior change for a user who never reads `control.json`).

## Cross-cutting design contracts (read first)

**C1 — Two observe credentials, never a control token.** `control.json` advertises an
**app-observe** token (redacted `.observe` only). Sensitive reads ride a **separate,
per-session, session-bound** token injected into the env of children Laban spawns.
**No** token grants input, clipboard, cross-tab, or destructive control on the live
surface. Never place a sensitive token in a world-path file. (ADR 0024 §"Two-tier
token model", amended to observe-only for Phase 2.)

**C2 — Capability + scope enforced per resolved intent, after availability.** Guard
(Host/Origin/token) → match route → resolve intent id → availability (`404` if
surface-unavailable) → **capability** (`requiredCapability ∈ granted`, else `403`) →
**scope** (for `.observeSensitive`/`.control`, `targetSession ∈ tokenScope`, else
`403`). Checks are on the resolved id; a known intent the caller can't afford is `403`,
not `404`.

**C3 — Policy generated from the catalog; deny by default.** `LabanControlPolicy`
derives grants and per-intent requirements **from `IntentCatalog`**. Unknown id →
denied. The catalog's implicit capability/sensitivity defaults are removed and
`validate()`/`LabanControlGen` **fail** on any unclassified descriptor — so a new
sensitive read cannot silently become observe-readable.

**C4 — One projection, both surfaces.** The `AppModel`/`Session` → read-DTO
projections move to `LabanCore` (AppKit-free) so `LiveIntentRouter` and
`HeadlessIntentRouter` emit **byte-identical** wire. `dataSensitivity` (what may leak)
is declared independently of `requiredCapability` (who may call) and `scope` (whose
session). Renderer-only reads have no live GUI projection in Phase 2 and stay
`headlessOnly`.

**C5 — No actuation on the live surface; no in-band control.** The live GUI surface
serves **observe + benign own-session navigation only**. Input actuation
(`typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/`mouseDrag`) is `headlessOnly` +
`.input`, granted only to the fixture token, build-gated out of the release GUI where
feasible — a TIOCSTI-class primitive deferred to the lease ADR. Command proposals are a
**data object**, never PTY bytes. Never write title/clipboard read-backs into the input
stream; constrain DECRQSS/DSR (CVE-2022-45872 class); OSC 52 write-only behind opt-in;
**no live OS-host clipboard read** (the headless `/debug/clipboard` diagnostic is a
debug-runtime read, not OS clipboard, and stays headless-only).

**C6 — `0600`-from-first-byte; never log a token.** `control.json` is created
`O_CREAT|O_EXCL,0600` → write → `rename` (no chmod-after-write). Logs record the URL
only; a test greps logs for both minted tokens and expects zero hits.

**C7 — Every privileged access is audited; the indicator reflects the risk boundary.**
Every `.observeSensitive`/benign-`.control` access appends an audit event to the
`EventLog`. The "agent attached" indicator lights on any privileged access (privileged
**reads** included — the risk boundary is sensitive observation, not just mutation).

**C8 — Default-on is gated by the release checklist, not the phase label.** The
observe-on-by-default flip (2F) lands only when all nine §5.4 items **plus the
env-secrecy gate** hold, each backed by a test/mechanical check. Through 2A–2E the
server stays behind `LABAN_CONTROL_SERVER=1`.

**C9 — The human GUI is unchanged; the headless wire is byte-stable.** No new windows
or behavior for a user who never reads `control.json`. `laban-agent` + `LabanDebugTests`
+ the `/debug` discovery doc + `schemas/debug/*` stay identical (driven by the fixture
token, which retains whole-app + `.input`). The GUI-visible changes are the deliberate
removal of actuation from the live surface and the new own-session observe reads.

**C10 — No ambient sensitive authority; session-observe is agent-attached-only.** The
session-observe token is injected **only** into sessions explicitly marked
agent-attached, never into a normal user shell. A normal tab's child processes inherit
at most `LABAN_CONTROL_URL` and can read nothing sensitive. Default-on grants discovery
(the app-observe file), not sensitive env authority to every process. **Env-secrecy
fallback:** if the §5.4 env-secrecy gate cannot be proven on the supported macOS/SIP
matrix, do **not** inject session-observe tokens into default-on sessions at all
(sensitive observation then requires an explicit, non-env credential path).

**C11 — Preallocated session identity.** `sessionID` is allocated **before** the
session factory runs (a `SessionLaunchContext`); launch paths accept the preallocated
id and `Session.init` no longer always self-generates it; the session-observe token is
minted from that id before envp composition and injected only when `isAgentAttached`.
A token never carries a wrong/late id and never silently falls back to app-wide scope.

**C12 — Scoped tokens never fall back to the active tab.** For a session-bound token,
an omitted target `sessionID` resolves to the **token's own** session, not the app's
active tab; an explicit other target → `403`. Only a whole-app token (fixture / future
explicit grant) gets legacy active-session behavior. This prevents focus changes from
turning a legacy "active session" route into a cross-tab read.

## Milestone detail

### 2A — Capability + scope enforcement, two observe tiers
**Scope.** Mint two observe tiers, advertise only the app-observe token, enforce
`requiredCapability` + session scope via a catalog-generated `LabanControlPolicy`.
Surface-agnostic; tested with a spy router. **Acceptance:** the spy-router matrix in
Progress holds; `control.json` carries the app-observe token and **not** any sensitive
token (parse it); unknown action id reaches the legacy unsupported path with the
fixture token, while a non-fixture token may legitimately `403` it first (assert per
token).

### 2B — Live session-scoped observe surface
**Scope.** Relocate projections to `LabanCore` (C4); implement the own-session observe
family in `LiveIntentRouter`; flip availability; remove Phase-1 GUI input. **Acceptance.**
With the app behind `LABAN_CONTROL_SERVER=1`: a **session-observe** token reads its own
session's `.observeSensitive` state `200` (shape-identical to the headless wire) and any
**other** session `403`; the app-observe token gets `403` on all `.observeSensitive`
reads and `200` only on redacted/non-sensitive ones. `terminal.typeText`/`sendKey`/
`paste`/`click`/`mouseWheel`/`mouseDrag` are `gui:false` (live server `404`s; absent
from / build-gated out of the release GUI). `LabanDebugTests` pass unchanged.

**`app.stateSummary` exact key allowlist** (this read is reachable by any same-user
process that finds `control.json`, so its shape is locked by a snapshot test that fails
when a new key appears). The boundary is **process/workspace metadata is allowed,
terminal *content* is not** — the allowed fields are already same-user-visible via
`ps`/`lsof`/proc APIs, so they grant no capability a local process lacks; the
forbidden fields are terminal-internal content the OS does not otherwise expose.
**Allowed:** `schema`/`version`; `runID`; `readiness`; `inputActuation: "unavailable"`;
`crossSessionSensitiveReads: "denied"`; `windowCount`/`tabCount`/`sessionCount`; active
**opaque per-run** ids; `callerOwnedSessionID` (if known); coarse booleans (`focused`,
`scrollable`, `shellIntegrationAvailable`); **per-tab titles; cwd/repo/workspace;
process command/args/pid** (2026-06-20 decision — `ps`-equivalent). **Forbidden:**
terminal text/grid/scrollback; selected text; find needle; clipboard data;
accessibility text; keystroke/input log; agent metadata; any id stable across
launches. (Caveat carried for review: process args may contain secrets and titles may
carry remote-session strings — both already `ps`-visible except remote-set titles.)

For a session-bound token, `session.list`/rich `app.state` are **schema-identical to
the headless wire but content-filtered/redacted by scope** (own session only) — not
byte-identical.

### 2C — Catalog-parity + completeness
**Acceptance.** `CatalogParityTests` (HTTP-route level) green; mutating one surface to
drop a shared intent fails it. A completeness test asserts every descriptor is
explicitly classified, **no `gui:true` descriptor requires `.input`/`.clipboard`**, and
the `gui:true` `.control` set equals **exactly** `{tab.select, terminal.scrollViewport,
command.propose}` (a positive allowlist — fails if `tab.close`/`session.kill`/etc.
sneaks in).

### 2D — Indicator, disable switch, audit, no-token-logging
**Acceptance.** A privileged request lights a visible "agent attached" indicator
(clears after TTL); a disable switch stops the server and removes `control.json`
(verified: `curl` fails, file gone); every privileged access appends an audit event
(intent/capability/surface/session/time, no token/secret) asserted via `GET
/debug/events` (if `log.events` is itself classified) or the in-process journal hook;
`LabanControl` imports no app-side `EventLog`. A test greps logs and non-token
artifacts for both minted tokens → zero; `control.json` parsed separately.

### 2E — Command proposals
**Exact response shape (both surfaces):**

    { "ok": true, "proposalID": "...", "targetSessionID": "...",
      "state": "pendingReview", "writtenToPTY": false }

- **GUI:** records the proposal, shows the review UI, **never** writes PTY bytes. Any
  "Run" affordance in Phase 2 **copies/shows** the command for the human to run
  manually — it does **not** call terminal input (no `command.propose` path may reach
  `session.write`/`sessionCoordinator.write`).
- **Headless:** records the proposal in the deterministic debug journal/event log,
  returns the **same** shape, never writes PTY bytes (keeps `CatalogParityTests`
  unambiguous).
- Requires session-observe scope for `targetSessionID` (cross-session → `403`);
  classified `.control` and in the `.gui` `.control` allowlist (2C); audited; lights
  the indicator.

**Acceptance.** An agent with session-observe scope for tab N submits `command.propose`
and gets the shape above with `writtenToPTY:false`; a test asserts no PTY write occurs
on either surface; the user runs or dismisses it; cross-session propose → `403`.
Discovery/schema byte-stable via `LabanControlGen`.

### 2F — Flip observe-on-by-default (release-checklist gate)
**§5.4 release checklist — every item must hold (each backed by a test/check):**
- [ ] `control.json` grants an **observe-only** token (never sensitive/control/input).
- [ ] `.observeSensitive` requires the separate per-session env-injected token/scope.
- [ ] No live token grants `.input`/`.clipboard`/cross-tab/destructive control.
- [ ] The token file is created `0600` **from the first byte** (not chmod-after-write).
- [ ] `Host` + `Origin` validation rejects malformed/spoofed hosts (`[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`, and the non-numeric-port cases `localhost:evil`, `127.0.0.1:evil`, `[::1]:evil`).
- [ ] A visible "agent attached" indicator exists.
- [ ] A user-facing disable switch exists.
- [ ] Audit events persist to the `EventLog`.
- [ ] No token value is ever logged.

**Additional release gate (plan-added; fold into ADR 0024 §5.4).** On the supported
macOS/SIP matrix, a sibling same-user process cannot recover the per-session token from
a spawned child via `ps -Eww -p <pid>`, `sysctl`/proc APIs, Activity Monitor,
crash/`sysdiagnose` artifacts, or project logs. If unprovable, env-token delivery is
**defense-in-depth, not a boundary**: do **not** inject session-observe tokens into
default-on sessions at all (C10 fallback) — sensitive observation then requires an
explicit, non-env credential path deferred with the lease ADR.

**Acceptance.** A freshly launched app (no `LABAN_CONTROL_SERVER`) writes `control.json`
and answers redacted app-summary reads for a file-token reader; the **initial/default/
restored** session's env carries its own session-bound token + `LABAN_CONTROL_URL`
(minted before `shellLaunch` composition / `AppModel.init`); that token reads its own
session's sensitive state `200` and any other session `403`; all input/mouse/clipboard/
cross-tab → `404`/`403`. The disable switch turns it off. `scripts/check` green; no
human-visible GUI change.

## Validation and Acceptance

From the repo root:

    swift test --filter LabanControlTests       # 2A — capability + scope tiers (spy)
    swift test --filter LiveControlObserve       # 2B — live own-session reads on .gui (LabanAppTests)
    swift test --filter LabanDebug               # 2B — headless wire byte-stable after relocation
    swift test --filter CatalogParityTests        # 2C — parity + no-gui-actuation invariant
    swift test --filter ControlSecurityFloor      # 2D — indicator/disable/audit/no-token-logging
    swift test --filter CommandProposals          # 2E — propose is a data object, never PTY input
    swift test --filter ControlDefaultOn          # 2F — observe-on-by-default + session-scoped env token
    ./scripts/check                               # discovery byte-stable + gated; lint; e2e; coverage
    ./scripts/build-app                           # GUI builds; unchanged for humans

…all pass, and: an agent reading `control.json` observes only the **redacted app
summary**; a per-session env token reads **its own session's** sensitive state (others
`403`); input/mouse/clipboard/cross-tab are unreachable on the live surface
(`404`/`403`); missing token `401`, bad `Host`/any `Origin` (incl. non-numeric ports)
`403`; the catalog-parity test fails if either surface omits a shared intent; the §5.4
checklist + env-secrecy gate hold before the default flips; the headless wire + `/debug`
discovery + `schemas/` are byte-stable; no token value appears in any log.

## Carried-over hardening (from the four review rounds)

These hard-won specifics survive the reframe and must hold: `0600`-from-first-byte
token file (C6); `isLoopbackHost` numeric-port fix + the full deny matrix; deny-by-
default via explicit classification + `validate()` failure; `ControlReadiness`
byte-stability (no sensitive token serialized); projections relocated to `LabanCore`
for a byte-identical headless wire; HTTP-route-level parity (headless typed
`tabSelect`/`typeText`/`sendKey` are `501` stubs); `ControlSecurityObserver` boundary so
`LabanControl` never imports the app `EventLog`; the session-observe token is
**agent-attached-only** and minted from a **preallocated `sessionID`** (C10/C11) — the
default session is a normal shell with no token (so no `AppModel.init` timing race);
the race applies only if the first session is itself agent-attached, handled by the
early bind + late-bound model provider; env-secrecy release gate (with the C10
no-inject fallback).

## Decision Log

- (Strategy pivot, 2026-06-20 / user) **Phase 2 ships observe-first, not agent-driven.**
  Deliberated the "agent drives terminal" vision vs. its risks (input = arbitrary
  command execution that launders past the embedded agent's own permission model;
  app-wide token = cross-tab sandbox breakout; "trust by default" only holds inside an
  enforced boundary, which Laban lacks between tabs). Chose conservative: observe +
  benign own-session nav + command proposals; defer all actuation + cross-tab to a
  future Terminal-Lease / Computer-Use ADR. Grounded in Codex's sandbox×approval split
  and Claude Code's host-enforced permission model.
- (2026-06-20 / user) **Drop the app-wide control token; two observe tiers.**
  `control.json` = app-observe (redacted summary). Sensitive reads = a **per-session,
  session-bound** token (only `LABAN_CONTROL_URL` is shared). No live token grants
  input/clipboard/cross-tab/destructive control.
- (2026-06-20 / user) **`.observeSensitive` reads are session-scoped** (chosen over
  whole-app-documented): cross-session → `403`; `session.list`/rich `app.state`
  redacted to the owning session; fixture token whole-app (test-only). Closes the
  read-side cross-tab breakout.
- (2026-06-20 / user) **Input actuation is off the main executable**; the `.input`
  capability + `headlessOnly` availability keep it on the fixture/headless path only,
  build-gated out of the release GUI where feasible. Mouse ops are part of the family.
- (Security review, rounds 1–4, verified against source 2026-06-20) Folded-in
  hardening: `0600` token file; `isLoopbackHost` port fix; deny-by-default; rich DTOs
  (incl. `app.state` via `StateResponse`) are `.observeSensitive`; `ControlReadiness`
  byte-stable; clipboard family kept as a headless diagnostic (not removed, C9);
  `ControlSecurityObserver` boundary; credential mint before `AppModel.init`;
  env-secrecy gate. (See git history for the prior actuation-oriented draft.)
- (Security review round 5, 2026-06-20) Tightened the token model further:
  **(C10) session-observe is agent-attached-only** — a normal shell gets no
  sensitive env token, so arbitrary child processes (npm/test/`curl | sh`/editor
  plugins) in a normal tab can read nothing sensitive; default-on grants discovery,
  not ambient sensitive authority. **(C11)** a `SessionLaunchContext` **preallocates
  `sessionID`** before the session factory so the token carries the real id (today
  `Session.init` self-generates it). **(C12)** scoped tokens never fall back to the
  active tab — an omitted target resolves to the token's own session. Plus exact
  specs: `app.stateSummary` key allowlist (snapshot-tested), `command.propose`
  response shape + no-PTY-write on both surfaces, a positive `.gui` `.control`
  allowlist (`{tab.select, scrollViewport, command.propose}`), env-secrecy
  **no-inject** fallback, the `LABAN_SESSION_OBSERVE_TOKEN` rename, and a scrub of the
  stale actuation text in the program roadmap. DRAFT — 2026-06-20 / Claude.

## Review Gate

A fresh-state agent verifies (mechanical; from repo root) once executed:

- [ ] `control.json` contains the app-observe token and **no** sensitive/control/input token; `grep` both minted tokens across logs/non-token artifacts → zero (the app-observe token appears only inside `control.json`).
- [ ] `ControlReadiness` is still `{debugServer, debugToken, pid, runId}` (no new field); no sensitive token serialized.
- [ ] Spy-router: app-observe + `.observeSensitive` → `403` (no router call); session-observe + own-session `.observeSensitive` → `200`, **other session → `403`**; `.input`/`.clipboard` denied for all non-fixture tokens; missing → `401`.
- [ ] `LiveIntentRouter` answers `session.detail`/`selection.read`/`find.state` for the caller's own session against a live `AppModel` (LabanAppTests), shape-identical to `HeadlessIntentRouter`; cross-session → `403`; `session.list`/`app.state` redacted to the owning session.
- [ ] GUI input-actuation absence: `terminal.typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/`mouseDrag` are `availability.gui == false` **and** require `.input` (no GUI token grants it); GUI routes `404` for both tokens; `grep -rn "session.write\|session.sendKey\|sessionCoordinator.write\|encodePaste\|sanitizePaste" Sources/LabanApp/Control` → nothing; release GUI doesn't link the headless input impl; `LabanControlGen --check` fails if any actuation descriptor becomes `gui:true`.
- [ ] `command.propose` is a data object: a test asserts proposing a command does **not** write to the PTY (no `session.write`/coordinator write from the propose path); cross-session propose → `403`.
- [ ] `grep -rn "import LabanDebug" Sources/LabanApp/Control` → nothing for the read path; `LabanControl` deps still exactly `["LabanCore"]` and it imports no app-side `EventLog`.
- [ ] `swift test --filter CatalogParityTests` fails if a `gui:true && headless:true` intent is removed from one surface; completeness test fails if any descriptor is unclassified, any `gui:true` requires `.input`/`.clipboard`, or the `gui:true` `.control` set is not exactly `{tab.select, terminal.scrollViewport, command.propose}` (add `tab.close`/`session.kill` as `gui:true` `.control` → expect failure; revert).
- [ ] `app.stateSummary` snapshot test: the response keys are exactly the allowlist (schema/version, runID, readiness, `inputActuation:"unavailable"`, `crossSessionSensitiveReads:"denied"`, window/tab/session counts, opaque per-run ids, `callerOwnedSessionID?`, coarse booleans, **per-tab titles + cwd/repo/workspace + process command/args/pid**) and **none** of the forbidden keys (terminal text/grid/scrollback, selected text, find needle, clipboard, a11y text, keystroke/input log, agent metadata, launch-stable ids); adding a key fails the snapshot.
- [ ] `0600`-from-first-byte: `ControlAdvertisement` uses `O_CREAT|O_EXCL` + `S_IRUSR|S_IWUSR`, no `chmod` after write (grep).
- [ ] Host/Origin matrix includes `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`, `localhost:evil`, `127.0.0.1:evil`, `[::1]:evil` → all `403`.
- [ ] No ambient token (C10): with observe-on default, a **normal** shell tab's env contains at most `LABAN_CONTROL_URL` (or no Laban env) and **no** `LABAN_SESSION_OBSERVE_TOKEN`; only an explicitly **agent-attached** session's env carries one. A token from agent session A reads A → `200` and B → `403`; the file (app-observe) token gets `403` on all sensitive reads.
- [ ] Preallocated id (C11): the session-observe token carries the session's real `sessionID` (minted from a `SessionLaunchContext` preallocated id before envp composition); `Session.init` accepts an injected id rather than always self-generating.
- [ ] Active-session fallback (C12): for a session-bound token, an omitted target `sessionID` resolves to the token's own session (test `selection.read`/`find.state`/`session.detail`/`scrollIndicator.state`/rich `app.state`); changing the active tab does not let it read another tab; an explicit other target → `403`.
- [ ] Indicator lights on any privileged read; disable switch stops the server and removes the file; env-secrecy gate (`ps -Eww` et al.) holds — **or, if it cannot be proven, no session-observe token is injected into default-on sessions at all** (C10 fallback; sensitive observation then needs a non-env credential path).
- [ ] `./scripts/check` exits 0; `./scripts/build-app` succeeds; `swift run LabanControlGen --check` passes.

Review status: NOT REVIEWED (plan not yet executed).

## Idempotence and Recovery

2A is additive (policy + tiers) except two tightenings: the `isLoopbackHost` port fix
and removing the catalog's implicit classification defaults — the latter is a
prerequisite (make `validate()` strict in the same change that classifies every existing
descriptor explicitly). 2B relocates projections behind typealiases so a partial revert
never breaks the headless wire; each read group is independently revertible. 2C/2D/2E
are test/UI/data-exchange additions. **2F is the only behavior-flipping milestone** —
keep it last, keep the env-var force-disable, and do not flip until the §5.4 + env-
secrecy checks are green. The deferred actuation layer is reversible-by-omission: it
simply is not built on the live surface this phase.

## Interfaces and Dependencies

End-state additions (**bold**) on the Phase-1 graph:

    LabanCore     + Sources/LabanCore/Control/Projections/* (AppModel→DTO read builders, shared) + relocated read DTOs; session-scope types
    LabanControl  + LabanControlPolicy (capability + session-scope enforcement); + ControlSecurityObserver; app-observe + per-session session-observe minter; control.json carries app-observe only
    LabanDebug    HeadlessIntentRouter re-points at LabanCore projections (byte-stable); typealiases relocated DTOs; retains .input/fixture path for E2E
    LabanApp      LiveIntentRouter = own-session observe + benign nav (NO input/mouse/clipboard/cross-tab); ControlSecurityObserver impl (indicator + EventLog audit); disable switch; command-proposal review UI; observe-on-by-default mount; per-session session-observe token injection

No third-party packages; `LabanControl` stays `Foundation`/`Darwin`/`LabanCore`. The
`labpty` wire is unchanged (ADR 0007 freeze): only `LABAN_CONTROL_URL` (shared) and the
per-session token ride the existing child `envp`. All input actuation + cross-tab
authority is **deferred** to a future Terminal-Lease / Computer-Use ADR.
