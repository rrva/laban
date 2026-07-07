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

> **Status: IN PROGRESS — REFRAMED 2026-06-20 to observe-first; execution started
> 2026-07-06.** An earlier
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
- **Benign own-session navigation** (scroll own session) — no input, no mouse
  actuation, no clipboard, no focus change, no destructive tab lifecycle, no cross-tab.
- **Command proposals:** an agent proposes the exact next command as a **data object**
  the user reviews and runs — never bytes into a tty. This recovers most of the
  "agent helps me drive my terminal" value with zero PTY-input risk.
- The full **security floor** (ADR 0024): capability enforcement, two-credential model,
  `0600` token file, UDS peer-credential guard, deny-by-default classification,
  audit, indicator, disable switch, no-token-logging, and the gated default-on flip.

**Deferred to a future Terminal-Lease / Computer-Use ADR (NOT in Phase 2):**
- All input actuation — `terminal.typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/
  `mouseDrag` (stay **headless/fixture-only** for E2E; never on the live GUI surface).
- Any cross-tab / whole-app sensitive read or control by an ambient env credential.
- Clipboard read/write on the live surface; destructive/lifecycle tab ops.
- Autonomous "agent drives the terminal" mode — which, when built, is a distinct
  product mode: user picks the target session, short-lived **lease**, visible
  indicator, command approval/classifier, no self-injection, audit + revocation.

**Roadmap the substrate enables (beyond Phase 2):** a first-class **`laban` CLI**
generated from the catalog (the primary external adapter; MCP is a deferred/optional
second wrapper); the **event push stream** (already Phase 3 in the program — `EventLog`
promoted to push); full **trace/replay** export. Phase 2 keeps the architecture that
makes these cheap (one catalog, one policy, router-parity, generated discovery).

**CLI / consumer credential model (no daemon, no certs).** The natural consumer is a
**long-lived agent** (Claude Code, a sidecar) — it opens the UDS, performs the C14
one-shot attach **once**, and **holds that connection** for its lifetime; that held
connection *is* the session-observe credential. **No separate helper/daemon and no
certificates** (UDS peer-cred carries the auth). The stateless **`laban` CLI** then
does **app-observe reads** (the `control.json` token, every invocation) and
`command.propose` (an interactive call may perform its own fresh one-shot attach). A
*fully session-capable stateless CLI* (repeated own-session sensitive reads without a
long-lived holder) is **deferred** — when needed it's either a small per-session helper
or a `0600` per-session credential file (which trades C14's single-use property for
"same-user-readable," the same trust level as `control.json`). Phase 2 does not build
either; it only ensures the substrate supports the long-lived-agent pattern.

> **Amendments status (done 2026-06-20):** ADR 0024 (token model → two observe tiers
> + deferred lease; Amendment section), the program doc `agent-first-terminal-design.md`
> (header amendment + §6 Phase 2 recast + §4.1/§4.2/§5.1/Phase-3/5/7/§8/App-B scrub),
> and spec.md §24 (observe-first scope note) are all amended to match this plan. No
> amendment is outstanding.

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
Phase 2 **renames `control` → `navigate`** (it no longer means "drive the terminal" —
only benign own-session navigation) and **adds `propose`** (command proposals) and
**`input`** (the actuation family, used **only** on the headless/fixture path). The
end-state enum is `observe, observeSensitive, navigate, propose, input, clipboard,
fixture` — **no `control`** (the name is retired; a future actuation/lease tier would
be `input` + a distinct `execute`, never the vague `control`).

**Tokens (two observe-derived tokens; no app-wide control token):**

| Token | Where it lives | Grants | Scope |
| --- | --- | --- | --- |
| **app-observe** | `control.json` (`0600`) | `.observe` (redacted `app.stateSummary`) | whole-app **activity metadata** (no terminal content) |
| **session-observe** | obtained by an **explicit env-bootstrap opt-in agent-attached session only** via a **one-shot attach handshake** — env carries a single-use bootstrap (`LABAN_SESSION_ATTACH`) redeemed once for a connection-bound credential (C14); **not** a long-lived env bearer; default-on sessions never receive it | `.observeSensitive` + `.navigate` (own-session **view scroll** only) + `.propose` (command proposals) | **its own session only** |
| **fixture** | headless tests only (`laban-agent`/`LabanDebug`) | all incl. `.input` | whole-app (test-only; `validate()` bars `.fixture` on `.gui`) |

`.clipboard` is granted to **no token**; `.input` only to the fixture token. The
session token is **observe-derived** (it also grants benign own-session navigation),
not a control token. No live GUI token grants `.input`, `.clipboard`, cross-session,
or destructive tab ops. The headless wire stays fixture-driven, so C9 holds.

**Explicit opt-in attach only — no ambient token in normal/default shells (C10).** The
session-observe credential is never injected into env. Default-on sessions inherit at
most `LABAN_CONTROL_URL` (discovery), never `LABAN_SESSION_ATTACH`. Only an explicitly
agent-attached development/E2E launch with `LABAN_CONTROL_ATTACH_ENV=1` receives the
single-use attach bootstrap, and that bootstrap redeems into a connection-bound
session-observe credential. An arbitrary child process in a normal/default tab (npm
scripts, test binaries, `curl | sh`, editor plugins, REPL/background jobs) can read
**nothing** sensitive — it cannot reach own-session scrollback/grid/cwd/process/
selection/find/accessibility. Default-on grants the machine *discovery* (the
app-observe file), not sensitive env authority.

**Preallocated session identity (C11).** A session-observe token
must carry the real `sessionID`, but `Session.init` generates its own id today and the
env is composed before the `Session` exists. So introduce a `SessionLaunchContext {
sessionID, tabID?, isAgentAttached, environmentOverrides, sessionObserveBootstrap? }`:
`AppModel`/the session registry **preallocates `sessionID`** before invoking the
session factory; the launch paths (`Session.realShell`/`parserOnly`, laband, labpty)
accept the preallocated id (`Session.init` no longer always self-generates it); the
one-shot attach bootstrap is minted from that id **before envp composition** and
injected **only** for explicitly opted-in agent-attached launches. Without this, an
implementer mints a credential with the wrong/late id or falls back to app-wide scope.

**Session scoping + active-session fallback (the core invariant).** The policy
enforces, for `.observeSensitive`/`.navigate`/`.propose`, `targetSession ∈ tokenScope` —
cross-session → `403`. **For a session-bound token an omitted target `sessionID`
resolves to the token's own session, never the app's active tab** (otherwise a focus
change would leak another tab through a legacy active-session route). Whole-app reads
(`session.list`, rich `app.state`) are **redacted to the owning session** for a
session-bound token. A whole-app token (fixture, or a future explicit grant) + omitted
target → legacy active-session behavior; the app-observe token → redacted app summary
only. This closes the cross-tab read breakout: an agent in tab A cannot read tab B's
selection/scrollback/cwd/find-needle.

## Progress

> Reconciled 2026-07-07 after the security-floor branch work through C14/default-on
> hardening. The only unchecked Progress item is the repo-wide `scripts/check` close-out.

Milestone 2A — Capability + scope enforcement, two observe tiers (`LabanControl`):
- [x] (2026-07-07) Two start paths over the **UDS listener** (C16): GUI `start()` mints an **app-observe** token (→ `control.json`) and a **session-observe minter** (per-session, session-bound); returns them to the in-process caller. Headless `start(socketPath:)` (was `start(host:port:)`) keeps `debugToken` (fixture-class, whole-app) so `laban-agent`/`LabanDebugTests` stay byte-stable. **`ControlReadiness` shape unchanged** (`{debugServer, debugToken, pid, runId}`) — `debugServer` now carries the **socket path** instead of a URL; no sensitive token serialized into readiness JSON or any world-path file.
- [x] (2026-07-07) `LabanControlPolicy` (generated from `IntentCatalog`): `grants(appObserve)={.observe}`; `grants(sessionObserve)={.observe,.observeSensitive,.navigate,.propose}`; `grants(fixture)={.fixture,.observe,.observeSensitive,.navigate,.propose,.input}`. No token grants `.clipboard`; only fixture grants `.input`. `authorize(intentID:, granted:, targetSession:, tokenScope:)` checks `requiredCapability ∈ granted` **and**, for `.observeSensitive`/`.navigate`/`.propose`, `targetSession ∈ tokenScope`. `targetSession` is derived per C12 (session-bound token + omitted target → the token's **own** session, never the active tab; whole-app token → legacy active-session). Unknown id → deny.
- [x] (2026-07-07) Deny-by-default made real: remove the catalog builder's implicit `requiredCapability`/`dataSensitivity` defaults (or track `explicit`); `IntentCatalog.validate()` + `LabanControlGen --check` **fail** unless every descriptor declares both explicitly.
- [x] (2026-07-07) **Reclassify the shipped headless clipboard family off `.clipboard`** (which no token grants — `.clipboard` is reserved for a future live OS-host opt-in). The catalog today has `clipboard.setText`/`clipboard.copy`/`clipboard.paste` requiring `.clipboard`, which would be unreachable after enforcement and break headless byte-stability. New classification, all `headlessOnly`, `dataSensitivity: .clipboard`: `clipboard.read` → `.observeSensitive`; `clipboard.setText`/`clipboard.copy` → `.fixture`; `clipboard.paste` → `.input` (`sideEffects.ptyInput: true`). The fixture token grants all of these, so the shipped e2e flows pass; **no Phase-2 descriptor requires `.clipboard`** (assert with a grep gate).
- [x] (2026-07-07) Guard taxonomy (UDS transport, C16): connection rejected unless the **peer uid == owner** (`getpeereid`/`LOCAL_PEERCRED`) and the socket sits in a `0700` user dir; then missing/invalid token → `401`; capability-insufficient → `403`; cross-session sensitive read → `403`. (No `Host`/`Origin`/port checks — obviated by UDS.) Token values never logged.
- [x] (2026-07-07) `LabanControlTests` (spy router): app-observe token → `.observe` `200`, `.observeSensitive`/`.navigate`/`.propose` `403` (no router call); session-observe token → own-session `.observeSensitive` `200`, **other-session `403`**; `.input`/`.clipboard` rejected for all non-fixture tokens (policy-level assertion); missing → `401`; a connection whose **peer uid ≠ owner** is rejected before auth (C16). `control.json` contains the app-observe token only.

Milestone 2B — Live session-scoped observe surface (`LabanApp`):
- [x] (2026-07-07) Shared `AppModel`/`Session` → DTO projections relocated to `Sources/LabanCore/Control/Projections/*` (public); `HeadlessIntentRouter` re-points to them **byte-identically** (headless `LabanDebugTests` + `DiscoveryEndpointParityTests` unchanged). `LabanDebug` typealiases relocated DTOs.
- [x] (2026-07-07) `LiveIntentRouter` implements the **own-session** observe family against the live `AppModel`/`AppSessionCoordinator`: `app.accessibility`, `terminal.modes`, `session.detail`, `find.state`, `selection.read`, `shellIntegration.state`, `scrollIndicator.state`, plus rich `app.state` and `session.list` **redacted to the owning session**. Each returns the shared DTO. Sensitivity split (explicit classification): the trigger for `.observeSensitive` is **terminal content** (grid/scrollback text, selection, find needle, accessibility text, keystroke log); `.observe` covers `terminal.modes`, `scrollIndicator.state`, and the whole-app `app.stateSummary` (which now also carries per-tab title/cwd/repo/process metadata — `ps`-equivalent, 2026-06-20). The rich `session.detail`/`app.state` DTOs stay `.observeSensitive` + session-scoped because they **also** carry content (grid), even though their process-metadata subset is separately available via the summary.
- [x] (2026-07-07) Benign own-session navigation under `.navigate`: **`terminal.scrollViewport` only** (own-session view scroll, which can't redirect input). **`tab.select` is removed** — it mutates UI focus and can hijack/redirect human keystrokes into the agent's tab without `typeText` (adversarial finding); a future user-mediated "request focus" could return as a `.propose`-style op. `command.propose` under its own `.propose` (§2E). **No input/mouse/clipboard, no focus change, no destructive tab lifecycle, no cross-tab.** The input-actuation family stays `headlessOnly` + `.input`; remove/build-gate the Phase-1 `LiveIntentRouter.typeText`/`sendKey` so input lives only in `LabanDebug`.
- [x] (2026-07-07) Catalog availability flips: own-session observe ids → `gui:true` with explicit `requiredCapability`/`dataSensitivity`; renderer/atlas/pixel-probe/capture/persistence stay `headlessOnly` (noted boundary). `swift run LabanControlGen --write` if route metadata changed; `swift test`; `scripts/check`.

Milestone 2C — Catalog-parity + classification completeness:
- [x] (2026-07-07) `CatalogParityTests` at the **HTTP-route level**: over every `availability.gui && availability.headless` intent, both surfaces return a non-error response for a representative input and pure reads' sorted-key JSON **shape** matches. Fails if either surface drops/diverges on a shared intent.
- [x] (2026-07-07) Completeness invariants: every descriptor declares explicit `requiredCapability` + `dataSensitivity`; **no `gui:true` descriptor requires `.input` or `.clipboard`**; the set of `gui:true` ids is exactly what `LiveIntentRouter` implements (own-session observe + benign nav).
- [x] (2026-07-07) **`.navigate`/`.propose` hard allowlists** (positive tests, not just the `.input`/`.clipboard` ban): the `gui:true` `.navigate` set equals **exactly** `{terminal.scrollViewport}` and the `gui:true` `.propose` set equals **exactly** `{command.propose}` — the test fails if **`tab.select`** (focus-hijack), `tab.close`/`session.kill`/`restart`/`detach`/`tab.new`, or any other op ever becomes a `gui:true` `.navigate`/`.propose` descriptor.

Milestone 2D — Indicator, disable switch, audit, no-token-logging:
- [x] (2026-07-07) `ControlSecurityObserver` boundary in `LabanControl` (`didAuthorize/didDeny/didPrivilegedActivity`); `LabanControl` keeps `["LabanCore"]`-only deps and never imports app UI/logging internals. `LabanApp` supplies the observer owning indicator state + the persistent `EventLog` sink.
- [x] (2026-07-07) "Agent attached" indicator lights on any successful **privileged** request (`.observeSensitive`, `.navigate`, or `.propose` — anything beyond app-observe non-sensitive reads) — TTL-based (HTTP has no durable "connected").
- [x] (2026-07-07) **Persistent Settings master toggle** — a native Settings UI preference ("Enable agent control server", e.g. `controlServerEnabled`, persisted across launches) that is the **complete opt-out** for users uneasy about *any* remote-control capability: when **off**, the server **never starts** (it overrides observe-on-by-default and `LABAN_CONTROL_SERVER`), **no `control.json` is written**, and **no attach bootstrap is injected into any session**. The runtime menu "disable" action sets this preference off, stops a running server, and removes `control.json`. (Default: on, per the 2F flip — the toggle is the user's escape hatch, not the default.)
- [x] (2026-07-07) Every privileged access emits an audit event via the observer to the `EventLog` (intent id, capability, surface, session, time — **no token, no payload secrets**).
- [x] (2026-07-07) A test greps logs and non-token artifacts for **both** minted tokens → **zero** hits; `control.json` parsed separately (it holds the app-observe token only).

Milestone 2E — Command proposals:
- [x] (2026-07-07) A typed `command.propose` exchange (capability `.propose`): the agent submits a proposed command (text + rationale + target session) as a **data object**; Laban surfaces it to the user (review UI), who runs or dismisses it. **Never** written to a PTY by Laban. Requires `.propose` + session-observe scope for its target session; audited; lights the indicator.
- [x] (2026-07-07) DTO + schema added to the catalog/discovery (gated, byte-stable via `LabanControlGen`); covered by `LiveIntentRouter`/`HeadlessIntentRouter` parity.

Milestone 2F — Flip observe-on-by-default (release-checklist gate):
- [x] (2026-07-07) The §5.4 release checklist (nine items + the env-secrecy gate, reproduced below) each backed by a passing test/mechanical check. The env-secrecy gate is satisfied by the C10 fallback: release/default-on sessions do **not** inject `LABAN_SESSION_ATTACH`; env bootstrap delivery is explicit opt-in via `LABAN_CONTROL_ATTACH_ENV=1`.
- [x] (2026-07-06) Default mount flips: GUI starts the server **observe-on** without `LABAN_CONTROL_SERVER=1`; the env var becomes a force-disable, not the on-switch. **The persistent Settings master toggle (2D) wins** — if `controlServerEnabled` is off, the server does **not** start despite observe-on-by-default (no `control.json`, no token/bootstrap injection). `.observeSensitive` still requires a connection-bound session credential from the explicit attach path.
- [x] (2026-07-07) Credential lifecycle: bind the server early (`LiveIntentRouter` via a **late-bound model provider**) and merge **`LABAN_CONTROL_URL` only** into the shared `ShellIntegrationLaunch.environmentOverrides`. Release/default-on sessions never receive `LABAN_SESSION_ATTACH`; explicitly opted-in agent-attached E2E/development sessions (`LABAN_CONTROL_ATTACH_ENV=1`) receive a **single-use `LABAN_SESSION_ATTACH` bootstrap** (C14) in their env. Use a `SessionLaunchContext` with a **preallocated `sessionID`** (C11) so the bootstrap is bound to the real id before envp composition; gate injection on `isAgentAttached` plus explicit env opt-in. `laban-agent --control-attach` redeems the bootstrap once for a connection-bound session-observe credential; the server invalidates it on first use and only a direct child of the registered shell PID may redeem. Across all backends (in-process `environment:`, laband `environmentPatch`, labpty `envp`). **No wire change** (does not touch the ADR 0007 freeze).
- [ ] `scripts/check` green; the GUI is unchanged for humans (no new windows, no behavior change for a user who never reads `control.json`).

## Cross-cutting design contracts (read first)

**C1 — Two observe credentials, never a control token.** `control.json` advertises an
**app-observe** token (redacted `.observe` only). Sensitive reads ride a **separate,
per-session, session-bound** credential the agent obtains via a **one-shot attach
handshake** — the agent-attached session's env carries only a single-use bootstrap
(C14), never a long-lived bearer. **No** token grants input, clipboard, cross-tab, or
destructive control on the live surface. Never place a sensitive token in a world-path
file. (ADR 0024 §"Two-tier
token model", amended to observe-only for Phase 2.)

**C2 — Capability + scope enforced per resolved intent, after availability.** Guard
(UDS peer-cred/fs-perms/token, C16) → match route → resolve intent id → availability (`404` if
surface-unavailable) → **capability** (`requiredCapability ∈ granted`, else `403`) →
**scope** (for `.observeSensitive`/`.navigate`/`.propose`, `targetSession ∈ tokenScope`, else
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
Every `.observeSensitive`/`.navigate`/`.propose` access appends an audit event to the
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

**C10 — No ambient sensitive authority; session-observe is explicit opt-in only.** The
session-observe credential is never injected into env. A normal/default tab's child
processes inherit at most `LABAN_CONTROL_URL` and can read nothing sensitive. Default-on
grants discovery (the app-observe file), not sensitive env authority to every process.
**Env-secrecy fallback adopted:** because inherited env cannot be a supported
production secrecy boundary, default-on sessions do **not** receive
`LABAN_SESSION_ATTACH`; the env bootstrap remains only for explicit dev/E2E attach
paths.

**C11 — Preallocated session identity.** `sessionID` is allocated **before** the
session factory runs (a `SessionLaunchContext`); launch paths accept the preallocated
id and `Session.init` no longer always self-generates it; the attach bootstrap is
minted from that id before envp composition and injected only for explicit
agent-attached env-bootstrap opt-in. A credential never carries a wrong/late id and
never silently falls back to app-wide scope.

**C12 — Scoped tokens never fall back to the active tab.** For a session-bound token,
an omitted target `sessionID` resolves to the **token's own** session, not the app's
active tab; an explicit other target → `403`. Only a whole-app token (fixture / future
explicit grant) gets legacy active-session behavior. This prevents focus changes from
turning a legacy "active session" route into a cross-tab read.

**C13 — Agent-attached lifecycle (the boundary, so define it).** Since
"agent-attached-only" is now the core security boundary, its creation/revocation is
specified, not implied: (a) only sessions created through an explicit path — a "New
Agent-Attached Session" command, a launch flag, or a future attach flow — set
`isAgentAttached` and receive the single-use `LABAN_SESSION_ATTACH` bootstrap (C14);
(b) an existing normal
session is **never silently upgraded** (a running process's env cannot be safely
mutated); (c) restored sessions default to **normal** unless their agent-attached
status was explicitly persisted **and** the user setting still allows it; (d) the
disable switch / revoke invalidates **all** session-observe tokens and removes
`control.json`.

**C14 — Session-observe is obtained by a one-shot attach handshake, not a long-lived
env bearer (adversarial finding).** A bearer token placed in the agent-attached
session's env is inherited by every descendant (npm postinstall, test deps,
`curl | sh`, editor plugins), any of which could read it and exfiltrate own-session
scrollback/selection/process state — a supply-chain leak *inside* an opted-in session.
So the env carries only a **single-use bootstrap** (`LABAN_SESSION_ATTACH`) + the URL;
the agent **redeems it once** at an attach endpoint for a **connection-bound**
session-observe credential, and the server **invalidates the bootstrap on first
redemption**. A descendant that reads the env *after* the agent has attached finds a
**spent** bootstrap and cannot obtain a working credential; the live authority is held
on the agent's connection, not in any inheritable variable. (Supersedes the earlier
"env carries the session-observe token" delivery; still rides the existing `envp`, so
no ADR 0007 wire change — only the *value* placed there changes.)

**C15 — `command.propose` has a safe-rendering contract; proving "no PTY write" is not
enough (adversarial finding).** The review/copy path must guarantee the human sees the
exact bytes they would run. Proposal `command`/`purpose` are untrusted: render
byte-exact with visible escaping of control/newline/C1/bidi characters, no ANSI or
rich interpretation, no silent truncation, a length cap, and **copy-text identical to
displayed text** (or an explicit diff). Hidden newlines, Unicode bidi overrides
(Trojan-Source), embedded escape sequences, and display-vs-copy mismatch are an
approval bypass and must be defeated by rendering, not just by "Laban doesn't write the
PTY."

**C16 — Transport is a Unix domain socket, not loopback TCP (2026-06-21 decision;
authoritative — supersedes every `Host`/`Origin`/`isLoopbackHost`/port reference in
this plan and the ADR's loopback-TCP transport).** The control plane binds a **UDS** at
`~/Library/Application Support/Laban/control.sock` inside a `0700` user-owned dir — **no
TCP listener, no network surface**. This eliminates the entire loopback-TCP attack
class (DNS rebinding, browser/CDP CSRF — a web page cannot connect to a UDS, any
cross-host reachability). **HTTP request framing + the JSON/intent wire are retained
over the socket** (HTTP-over-UDS, like `--unix-socket`), so the catalog, policy,
adapters, and **byte-stable response bodies are unchanged** — only the listener and
discovery change. The guard becomes: **filesystem permissions** (`0700` dir) **+
kernel peer-credentials** (`getpeereid`/`LOCAL_PEERCRED` — assert connecting `uid` ==
owner; reject otherwise) **+ the bearer token** (fail-closed). `Host`/`Origin`
validation and the `isLoopbackHost` numeric-port work are **obviated** (no such headers
matter on a same-host UDS; nothing to rebind). **Discovery:** `control.json` advertises
the **socket path** (still `0600`, in the `0700` dir); `LABAN_CONTROL_URL` carries that
path (or a `unix:` URL); `laban-agent` readiness emits the path; the e2e harness uses
`curl --unix-socket`. Peer-cred (pid/uid) additionally hardens the C14 attach handshake
(redeemer pid can be checked). **Scope note:** this **migrates the shipped Phase-0/1
loopback-TCP server** to UDS — it changes `LabanControlServer.start*`, the headless
harness's bind/readiness, and `scripts/test-e2e`; the GUI mount and both surfaces use
the UDS listener.

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
the `gui:true` `.navigate` set equals **exactly** `{terminal.scrollViewport}`
and the `gui:true` `.propose` set equals **exactly** `{command.propose}` (positive
allowlists — fail if `tab.select` (focus-hijack), `tab.close`/`session.kill`/etc. sneaks in).

### 2D — Indicator, disable switch, audit, no-token-logging
**Acceptance.** A privileged request lights a visible "agent attached" indicator
(clears after TTL); a disable switch stops the server and removes `control.json`
(verified: `curl` fails, file gone); the persistent Settings master toggle, set off,
keeps the server from starting at all across a relaunch (no bind, no `control.json`,
no token in any session env); every privileged access appends an audit event
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
  classified `.propose` and in the `.gui` `.propose` allowlist (2C); audited; lights
  the indicator.
- **Safe-rendering contract (C15 — proving "no PTY write" is not enough; the human
  must see the exact bytes they'd run).** Proposal `command` and `purpose` are
  **untrusted input**. The review UI renders the command **byte-exact** with visible
  escaping of control chars / newlines / C1 / Unicode bidi (no ANSI/rich
  interpretation, no silent truncation), enforces a length cap, and guarantees the
  **copied/run text is byte-identical to the displayed text** (or shows an explicit
  diff). Deceptive-payload tests cover hidden `\n`, bidi overrides (Trojan-Source),
  embedded `ESC[`/OSC, over-length, and display-vs-copy mismatch — each must render
  visibly and never auto-run.

**Acceptance.** An agent with session-observe scope for tab N submits `command.propose`
and gets the shape above with `writtenToPTY:false`; a test asserts no PTY write occurs
on either surface; the user runs or dismisses it; cross-session propose → `403`.
Discovery/schema byte-stable via `LabanControlGen`.

### 2F — Flip observe-on-by-default (release-checklist gate)
**§5.4 release checklist — every item must hold (each backed by a test/check):**
- [x] (2026-07-07) `control.json` grants an **observe-only** token (never a privileged token — `.observeSensitive`/`.navigate`/`.propose`/`.input`).
- [x] (2026-07-07) `.observeSensitive` requires a separate connection-bound session credential; default-on env never carries `LABAN_SESSION_ATTACH`, and the one-shot bootstrap exists only for explicit `LABAN_CONTROL_ATTACH_ENV=1` dev/E2E launches.
- [x] (2026-07-07) No live token grants `.input`/`.clipboard`/cross-tab/destructive control.
- [x] (2026-07-07) The token file is created `0600` **from the first byte** (not chmod-after-write).
- [x] (2026-07-07) Transport is a UDS in a `0700` dir (no TCP listener); a connecting peer whose `uid` ≠ owner is rejected (peer-cred), and there is no `Host`/`Origin`/rebinding surface to validate (C16).
- [x] (2026-07-07) A visible "agent attached" indicator exists.
- [x] (2026-07-07) A user-facing disable switch **and a persistent Settings master toggle** (complete opt-out: off ⇒ no server, no `control.json`, no token/bootstrap injection) exist.
- [x] (2026-07-07) Audit events persist to the `EventLog`.
- [x] (2026-07-07) No token value is ever logged.

**Additional release gate (plan-added; fold into ADR 0024 §5.4).** On the supported
macOS/SIP matrix, a sibling same-user process cannot recover the per-session credential from
a spawned child via `ps -Eww -p <pid>`, `sysctl`/proc APIs, Activity Monitor,
crash/`sysdiagnose` artifacts, or project logs. If unprovable, env-token delivery is
**defense-in-depth, not a boundary**: do **not** inject session-observe tokens or
attach bootstraps into default-on sessions at all (C10 fallback, adopted here).
Sensitive observation requires a connection-bound credential obtained from an explicit
attach path.

**Acceptance.** A freshly launched app (no `LABAN_CONTROL_SERVER`) writes `control.json`
and answers redacted app-summary reads for a file-token reader. **Normal
initial/default/restored sessions inherit at most `LABAN_CONTROL_URL` (or no Laban env)
and never the `LABAN_SESSION_ATTACH` bootstrap** (C10). Only an **explicitly
agent-attached** session launched with `LABAN_CONTROL_ATTACH_ENV=1` receives the
single-use `LABAN_SESSION_ATTACH` bootstrap
(bound to a preallocated `sessionID`, C11), which the agent redeems **once** for a
connection-bound session-observe credential (C14); that credential reads its own
session's sensitive state `200` and any other session `403`; a descendant that reads
the env after redemption finds a **spent** bootstrap and cannot attach. All
input/mouse/clipboard/cross-tab → `404`/`403`. The disable
switch turns it off. `scripts/check` green; no human-visible GUI change.

## Validation and Acceptance

From the repo root:

    swift test --filter LabanControlTests       # 2A — capability + scope tiers (spy)
    swift test --filter LiveControlObserve       # 2B — live own-session reads on .gui (LabanAppTests)
    swift test --filter LabanDebug               # 2B — headless wire byte-stable after relocation
    swift test --filter CatalogParityTests        # 2C — parity + no-gui-actuation invariant
    swift test --filter ControlSecurityFloor      # 2D — indicator/disable/audit/no-token-logging
    swift test --filter CommandProposals          # 2E — propose is a data object, never PTY input
    swift test --filter ControlDefaultOn          # 2F — observe-on-by-default + explicit attach bootstrap gate
    ./scripts/check                               # discovery byte-stable + gated; lint; e2e; coverage
    ./scripts/build-app                           # GUI builds; unchanged for humans

…all pass, and: an agent reading `control.json` observes only the **redacted app
summary**; an explicit attach-derived connection-bound session credential reads **its
own session's** sensitive state (others `403`); input/mouse/clipboard/cross-tab are unreachable on the live surface
(`404`/`403`); missing token `401`, a non-owner-uid peer rejected by UDS peer-cred
(C16; no TCP listener at all); the catalog-parity test fails if either surface omits a shared intent; the §5.4
checklist + env-secrecy gate hold before the default flips; the headless wire + `/debug`
discovery + `schemas/` are byte-stable; no token value appears in any log.

## Carried-over hardening (from the four review rounds)

These hard-won specifics survive the reframe and must hold: `0600`-from-first-byte
token file (C6); **UDS transport + peer-cred guard (C16)** — which *replaces* the old
`isLoopbackHost`/Host/Origin hardening (now obviated, no network surface); deny-by-
default via explicit classification + `validate()` failure; `ControlReadiness`
byte-stability (no sensitive token serialized); projections relocated to `LabanCore`
for a byte-identical headless wire; HTTP-route-level parity (headless typed
`tabSelect`/`typeText`/`sendKey` are `501` stubs); `ControlSecurityObserver` boundary so
`LabanControl` never imports the app `EventLog`; the attach bootstrap is
**explicit opt-in agent-attached-only** and minted from a **preallocated `sessionID`**
(C10/C11) — the default session is a normal shell with no bootstrap (so no
`AppModel.init` timing race); the race applies only if the first session is itself
agent-attached with env-bootstrap opt-in, handled by the early bind + late-bound model
provider; env-secrecy release gate (with the C10 no-inject fallback).

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
  sensitive env bootstrap, so arbitrary child processes (npm/test/`curl | sh`/editor
  plugins) in a normal tab can read nothing sensitive; default-on grants discovery,
  not ambient sensitive authority. **(C11)** a `SessionLaunchContext` **preallocates
  `sessionID`** before the session factory so the token carries the real id (today
  `Session.init` self-generates it). **(C12)** scoped tokens never fall back to the
  active tab — an omitted target resolves to the token's own session. Plus exact
  specs: `app.stateSummary` key allowlist (snapshot-tested), `command.propose`
  response shape + no-PTY-write on both surfaces, positive `.gui` `.navigate`/`.propose`
  allowlists (`{tab.select, scrollViewport}` / `{command.propose}`), env-secrecy
  **no-inject** fallback, the attach-bootstrap env naming, and a scrub of the
  stale actuation text in the program roadmap. DRAFT — 2026-06-20 / Claude.
- (2026-06-20 / user) **Renamed the capability `control` → `navigate`; split
  `command.propose` into its own `propose`.** Post-pivot `.control` granted only
  `{tab.select, scrollViewport, command.propose}` — none of which control the
  terminal — so the name invited the exact "can drive the terminal" assumption the
  pivot removed. `.navigate` = benign own-session view scroll (`scrollViewport`;
  `tab.select` removed shortly after — see the adversarial-review entry below);
  `.propose` = `command.propose` (a suggestion, not navigation).
  `control` is **retired** (not reused for the future lease tier — that is `.input` +
  a distinct `execute`). Touches the `Capability` enum, every descriptor's
  `requiredCapability`, the policy grants, and the docs. DRAFT — 2026-06-20 / Claude.
- (2026-06-20 / user) **Persistent Settings master toggle for complete opt-out.** A
  native Settings preference (`controlServerEnabled`) lets a user disable the control
  server **entirely** — off ⇒ no server starts, no `control.json`, no token/bootstrap injection,
  overriding observe-on-by-default and `LABAN_CONTROL_SERVER`. So users uneasy about
  any remote-control capability have a one-switch, persistent guarantee of "nothing is
  listening." The runtime menu disable sets this same preference. DRAFT — 2026-06-20.
- (Adversarial review, 2026-06-20) Three findings accepted, one rejected. **(C14,
  finding 4)** the session-observe credential is no longer a long-lived env bearer
  (descendants of an agent-attached session would inherit it) — the env carries a
  **single-use `LABAN_SESSION_ATTACH` bootstrap** redeemed once for a connection-bound
  credential; chosen over fd/UDS or keeping the bearer. **(finding 2)** `tab.select`
  **removed** from `.navigate` — focus change can redirect human keystrokes into the
  agent's tab (command misdirection without `typeText`); `.navigate` = `{scrollViewport}`
  only; a user-mediated "request focus" can return later as a `.propose`-style op.
  **(C15, finding 3)** `command.propose` gains a **safe-rendering contract** (byte-exact,
  control/newline/bidi escaped, copy==display, deceptive-payload tests) — "no PTY write"
  doesn't prove the human sees the bytes they approve. **(finding 1 — rejected)** the
  `app.stateSummary` field set stands: `cwd`/process are `ps`-equivalent; titles +
  repo/workspace are net-new app-state but accepted per the prior decision (the user
  reaffirmed against the adversarial challenge). DRAFT — 2026-06-20 / Claude.
- (2026-06-21 / user) **Transport switched from loopback TCP to a Unix domain socket
  (C16).** Binds `control.sock` in a `0700` user dir — no network listener — which
  eliminates the loopback-TCP attack class (DNS rebinding, browser/CDP CSRF). Guard
  becomes filesystem perms + kernel **peer-credentials** (uid==owner) + token; the
  `Host`/`Origin`/`isLoopbackHost`/port hardening is **obviated**. HTTP framing + the
  JSON/intent wire are kept over the socket (HTTP-over-UDS), so the catalog/policy/
  adapters and byte-stable response *bodies* are unchanged — only the listener and
  discovery (`control.json` + `LABAN_CONTROL_URL` → socket path; `laban-agent` readiness
  → path; e2e → `curl --unix-socket`) change. Chosen over a named pipe (FIFOs aren't
  connection-oriented on macOS) and over a custom protocol (no security gain vs
  HTTP-over-UDS). **This migrates the shipped Phase-0/1 TCP server** — its own
  non-additive change, revertible to loopback TCP. DRAFT — 2026-06-21 / Claude.
- (2026-06-21 / user) **No daemon, no certs for the credential model.** Dropped the
  proposed per-session helper as the primary path: the **long-lived agent holds the UDS
  connection** (one C14 attach, held for its lifetime) — that held connection *is* the
  session-observe credential. UDS peer-credentials carry the auth, so there are **no
  certificates / no TLS / no SMJobBless privileged-helper** anywhere (and nothing here
  needs elevated privileges). The stateless `laban` CLI does app-observe + `propose`; a
  fully session-capable stateless CLI (small helper or `0600` per-session cred file) is
  deferred, not built in Phase 2. DRAFT — 2026-06-21 / Claude.
- (2026-07-07 / implementation) **Env bootstrap delivery is explicit opt-in; default-on
  uses the C10 fallback.** A same-user inherited environment cannot prove pre-redeem
  secrecy on the supported macOS/SIP matrix, and before first redemption there is no
  server-side PID check that can distinguish the intended agent from an arbitrary
  direct child of the registered shell. Therefore release/default-on sessions never
  receive `LABAN_SESSION_ATTACH`; `LABAN_CONTROL_ATTACH_ENV=1` keeps the env bootstrap
  path available for explicit development/E2E agent-attached launches. Redemption is
  still one-shot, connection-bound, and limited to a direct child of the registered
  shell PID.

## Review Gate

A fresh-state agent verifies (mechanical; from repo root) once executed:

- [ ] `control.json` contains the app-observe token and **no** privileged token (`.observeSensitive`/`.navigate`/`.propose`/`.input`); `grep` both minted tokens across logs/non-token artifacts → zero (the app-observe token appears only inside `control.json`).
- [ ] `ControlReadiness` is still `{debugServer, debugToken, pid, runId}` (no new field); no sensitive token serialized.
- [ ] Spy-router: app-observe + `.observeSensitive` → `403` (no router call); session-observe + own-session `.observeSensitive` → `200`, **other session → `403`**; `.input`/`.clipboard` denied for all non-fixture tokens; missing → `401`.
- [ ] `LiveIntentRouter` answers `session.detail`/`selection.read`/`find.state` for the caller's own session against a live `AppModel` (LabanAppTests), shape-identical to `HeadlessIntentRouter`; cross-session → `403`; `session.list`/`app.state` redacted to the owning session.
- [ ] GUI input-actuation absence: `terminal.typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/`mouseDrag` are `availability.gui == false` **and** require `.input` (no GUI token grants it); GUI routes `404` for both tokens; `grep -rn "session.write\|session.sendKey\|sessionCoordinator.write\|encodePaste\|sanitizePaste" Sources/LabanApp/Control` → nothing; no `LiveIntentRouter` dispatch for the family; `LabanControlGen --check` fails if any actuation descriptor becomes `gui:true`.
- [ ] Mechanical input-out-of-release boundary: `LabanApp` no longer links `LabanDebug` (the shared capture recorder lives in `LabanCore` and `LabanDebug` exposes compatibility aliases). The input-actuation fixture impl lives in a **headless/test-only target not depended on by `LabanApp`**, or behind a **non-release build flag** — verified by: no route registered, no `gui:true` descriptor, no `LiveIntentRouter` dispatch, and **no release-target dependency on the input fixture symbols**.
- [ ] `command.propose` is a data object: a test asserts proposing a command does **not** write to the PTY (no `session.write`/coordinator write from the propose path); cross-session propose → `403`.
- [ ] `command.propose` safe rendering (C15): deceptive-payload tests (hidden `\n`, Unicode bidi override, embedded `ESC[`/OSC, over-length, display-vs-copy mismatch) each render visibly-escaped, byte-exact, with copy-text == displayed-text and no auto-run.
- [ ] `grep -rn "import LabanDebug" Sources/LabanApp` → nothing for the app target; `Package.swift` shows `LabanApp` does not depend on `LabanDebug`; `LabanControl` deps still exactly `["LabanCore"]` and it imports no app-side `EventLog`.
- [ ] `swift test --filter CatalogParityTests` fails if a `gui:true && headless:true` intent is removed from one surface; completeness test fails if any descriptor is unclassified, any `gui:true` requires `.input`/`.clipboard`, the `gui:true` `.navigate` set is not exactly `{terminal.scrollViewport}`, or the `gui:true` `.propose` set is not exactly `{command.propose}` (add `tab.select` or `tab.close` as a `gui:true` `.navigate` → expect failure; revert).
- [ ] No descriptor requires `.clipboard`: `grep -RE "requiredCapability:? \.?clipboard" Sources/LabanCore/Intents` → **zero**. The shipped headless clipboard flows (`clipboard.read`/`setText`/`copy`/`paste`) pass with the fixture token; app-observe/session-observe tokens cannot call them; no `gui:true` clipboard route is advertised.
- [ ] `app.stateSummary` snapshot test: the response keys are exactly the allowlist (schema/version, runID, readiness, `inputActuation:"unavailable"`, `crossSessionSensitiveReads:"denied"`, window/tab/session counts, opaque per-run ids, `callerOwnedSessionID?`, coarse booleans, **per-tab titles + cwd/repo/workspace + process command/args/pid**) and **none** of the forbidden keys (terminal text/grid/scrollback, selected text, find needle, clipboard, a11y text, keystroke/input log, agent metadata, launch-stable ids); adding a key fails the snapshot.
- [ ] `0600`-from-first-byte: `ControlAdvertisement` uses `O_CREAT|O_EXCL` + `S_IRUSR|S_IWUSR`, no `chmod` after write (grep).
- [ ] Transport/peer-cred (C16): the server binds a UDS in a `0700` user dir with no TCP listener (`lsof`/`netstat` shows no control-plane port); a connection from a process whose `uid` ≠ owner is rejected before auth; a same-uid connection with no/invalid token → `401`. (The old `Host`/`Origin`/numeric-port matrix is obviated.)
- [ ] No ambient token (C10): with observe-on default, a **normal** shell tab's env contains at most `LABAN_CONTROL_URL` (or no Laban env) and **no** `LABAN_SESSION_ATTACH` bootstrap; even an agent-attached default-on session receives no bootstrap unless `LABAN_CONTROL_ATTACH_ENV=1` is set. In that explicit opt-in path, after the agent redeems the bootstrap, its connection-bound credential reads session A → `200` and B → `403`; the file (app-observe) token gets `403` on all sensitive reads.
- [ ] One-shot handshake (C14): in the explicit opt-in env path, the shell process itself cannot redeem; only a direct child of the registered shell PID can redeem once. A later direct child/grandchild process in an agent-attached session (e.g. an npm postinstall) that reads the env **after** the agent has attached finds a **spent** `LABAN_SESSION_ATTACH` and cannot obtain a working credential; no long-lived bearer is recoverable from the env.
- [ ] Preallocated id (C11): the attach bootstrap is bound to the session's real `sessionID` (minted from a `SessionLaunchContext` preallocated id before envp composition); the redeemed session-observe credential carries that id; `Session.init` accepts an injected id rather than always self-generating.
- [ ] Active-session fallback (C12): for a session-bound token, an omitted target `sessionID` resolves to the token's own session (test `selection.read`/`find.state`/`session.detail`/`scrollIndicator.state`/rich `app.state`); changing the active tab does not let it read another tab; an explicit other target → `403`.
- [ ] Indicator lights on any privileged read; disable switch stops the server and removes the file; env-secrecy gate (`ps -Eww` et al.) holds — **or, if it cannot be proven, no session-observe token or attach bootstrap is injected into default-on sessions at all** (C10 fallback, adopted here; sensitive observation then needs an explicit attach path).
- [ ] Settings master toggle (`controlServerEnabled`) off ⇒ **complete opt-out**: after a relaunch the UDS is never created (no `control.sock`, connect fails), no `control.json` exists, and no session env carries `LABAN_SESSION_ATTACH`/`LABAN_CONTROL_URL` — even with observe-on-by-default and even if `LABAN_CONTROL_SERVER=1` is set.
- [ ] `./scripts/check` exits 0; `./scripts/build-app` succeeds; `swift run LabanControlGen --check` passes.

Review status: NOT REVIEWED (plan not yet executed).

## Idempotence and Recovery

2A is additive (policy + tiers) except: removing the catalog's implicit classification
defaults — a prerequisite (make `validate()` strict in the same change that classifies
every existing descriptor explicitly). **Transport migration (C16) is the riskiest
non-additive step:** moving the shipped Phase-0/1 loopback-TCP server to a UDS changes
`LabanControlServer.start*`, the headless harness bind/readiness, `control.json`
(URL→socket path), and `scripts/test-e2e` (`curl`→`--unix-socket`) — land it as its own
change with the headless wire (response bodies) held byte-stable and only the
transport/discovery moving; it is revertible to loopback TCP if needed. 2B relocates
projections behind typealiases so a partial revert never breaks the headless wire; each
read group is independently revertible. 2C/2D/2E
are test/UI/data-exchange additions. **2F is the only behavior-flipping milestone** —
keep it last, keep the env-var force-disable, and do not flip until the §5.4 + env-
secrecy checks are green. The deferred actuation layer is reversible-by-omission: it
simply is not built on the live surface this phase.

## Interfaces and Dependencies

End-state additions (**bold**) on the Phase-1 graph:

    LabanCore     + Sources/LabanCore/Control/Projections/* (AppModel→DTO read builders, shared) + relocated read DTOs; session-scope types
    LabanControl  + LabanControlPolicy (capability + session-scope enforcement); + ControlSecurityObserver; app-observe + per-session session-observe minter; control.json carries app-observe only
    LabanDebug    HeadlessIntentRouter re-points at LabanCore projections (byte-stable); typealiases relocated DTOs; retains .input/fixture path for E2E
    LabanApp      LiveIntentRouter = own-session observe + benign nav (NO input/mouse/clipboard/cross-tab); ControlSecurityObserver impl (indicator + EventLog audit); disable switch; command-proposal review UI; observe-on-by-default mount; explicit opt-in per-session attach bootstrap delivery

No third-party packages; `LabanControl` stays `Foundation`/`Darwin`/`LabanCore`. The
`labpty` wire is unchanged (ADR 0007 freeze): `LABAN_CONTROL_URL` (shared) and, only
for explicit `LABAN_CONTROL_ATTACH_ENV=1` agent-attached launches, the single-use
`LABAN_SESSION_ATTACH` bootstrap ride the existing child `envp`. All input actuation +
cross-tab authority is **deferred** to a future Terminal-Lease / Computer-Use ADR.
