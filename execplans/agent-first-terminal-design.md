# Laban Agent-Control Surface — Design v2

**Status:** Active program roadmap. **Supersedes** the 2026-05-29 v1 of this file
(its comparator survey and grilling narrative are preserved verbatim in
Appendix A/B; nothing in the body below depends on reading them).

> **Amendment (2026-06-20): observe-first pivot.** Phase 2 ships an
> *agent-observable* terminal, not an *agent-driven* one. All input/mouse/clipboard
> actuation, cross-tab/whole-app authority, and autonomous "agent drives the
> terminal" are **deferred** to a future **Terminal-Lease / Computer-Use** mode/ADR
> (user picks a target session, short-lived lease, command approval, no
> self-injection, audit + revocation). The §5 token model is amended to two
> **observe** tiers — app-observe (`control.json`, redacted summary) + per-session,
> session-bound session-observe (`.observeSensitive` + benign own-session nav),
> **no app-wide control token** — and `.observeSensitive`/`.navigate`/`.propose` are
> **session-scoped** (cross-tab → 403). Input forms an `.input` capability granted
> only to the test `.fixture` token (headless E2E). Where §5 and the §6 Phase-2
> entry below describe a control token or live input, read them through this
> amendment. Command **proposals** (a reviewed data object, never PTY input)
> replace live typing as Phase 2's assistive feature. See **ADR 0024 Amendment
> (2026-06-20)** and `execplans/active/agent-first-phase2-mount-live-and-security-floor.md`.

This is a **program roadmap**, not an executable ExecPlan. Phase 0 — the first
executable slice — **shipped** as commit `0a2a230` and is archived at
`execplans/completed/agent-first-phase0-control-seam.md`, which remains
**authoritative for what Phase 0 did**. This document must never contradict that
file; where Phase 0 detail is needed here it is summarized and linked, not
restated. Per-phase ExecPlans (when written) are authoritative for their phase.

> **How to read this document.** Sections 1–9 are forward-only and authoritative,
> with **one standing exception**: the 2026-06-20 observe-first **header Amendment**
> supersedes the control-token / live-input placement in §4.2, §5.1, §5.2, and
> Phase 7 — read those sections through it (input is `.input`/fixture-only, the token
> model is two observe tiers, per-session scoping is in Phase 2, live actuation is
> deferred to the Terminal-Lease ADR). Apart from that amendment, every decision is
> stated once, in place.
> Appendices A–C hold rationale, comparator evidence, and the verified surface
> inventory for readers who want the "why."

---

## 1. Thesis (unchanged from v1)

Every visible part of the running Laban GUI should be **queryable and
controllable** by a local program over an **authenticated loopback control
plane**, so that the app a human runs (`LabanApp`) is simultaneously a normal
terminal for people and a deterministic, typed fixture for agents, tests, and CI.

The central finding that shapes the whole effort: **that surface already exists,
but in the wrong process.** A rich HTTP control surface (~40 routes) lives in the
headless binary (`laban-agent`, backed by `HeadlessDebugRuntime`), which renders
offscreen against its *own* `AppModel`. The GUI users actually run never starts
it. The work ahead is therefore **relocation and unification, not invention**:
host one server, in the GUI process, over one router, against the one live model.

## 2. Current reality (verified 2026-06-20)

Plain-language definitions are inline; full evidence is in Appendix C.

- **Targets today** (SwiftPM, `Package.swift`): `LabanTerminalCore` (C VT
  parser), `LabanRenderer` (Metal + software), `LabanCore` (model/session/
  persistence — **AppKit-free**), `LabanDebug` (HTTP server + capture —
  **AppKit-free**), `LabanApp` (the macOS GUI — **AppKit**), `LabanAgent`/
  `Laband`/`Labpty` (headless/daemon executables). There is **no `LabanControl`
  target yet.**
- **The control surface is real and isolated.** `Sources/LabanDebug/DebugHTTPServer.swift`
  is loopback-bound, bearer-token-authed, port-0, with state/sessions(+grid)/
  screenshot/actions/wait/events/find/selection/clipboard/shell-integration/
  capture endpoints and a generated discovery doc. It is instantiated **only** by
  `HeadlessDebugRuntime` (`LabanDebug` → `LabanAgent`). `grep` confirms `LabanApp`
  never constructs it; it links `LabanDebug` solely for `CaptureRecorder`.
- **The live model is already shared and safe to touch.** `AppModel`
  (`Sources/LabanCore/AppModel.swift`) is AppKit-free and internally locked
  (`withModelLock`); both `MainWindowController.makeAndShow` (GUI) and
  `HeadlessDebugRuntime` build one. There is **no "private GUI model"** to
  retire — only the renderer backend differs (Metal/window vs software/offscreen).
- **The session seam exists.** `TerminalSessionClient` (`LabanCore`) is a
  tier-agnostic protocol (inProcess / labpty / laband). `AppSessionCoordinator`
  (`LabanApp`) is the GUI's funnel for write/resize/scroll/snapshot/terminate.
- **Metal-truthful frames are wireable, not net-new.**
  `Sources/LabanRenderer/MetalReadback.swift` already exists (`captureMode`,
  drawable→CPU blit, `pngData`); the work is wiring it to the server and managing
  per-frame blit cost.
- **Semantic substrate exists.** Laban *injects* OSC 133 shell integration
  (`ShellIntegrationOverlay`: zsh `precmd`/`preexec`, bash `PROMPT_COMMAND`),
  reduced into `ShellIntegrationState` (`LabanCore`: `idle`/`atPrompt`/`running`/
  `finished` + `lastExitCode` + `completedCommandCount`). OSC 7 cwd (ADR 0015),
  OSC 52 clipboard write (ADR 0014). This phase state powers the failed-command
  indicator and tab status; **v2 deliberately does not build a higher-level
  command-block object on top of it (see Non-goals, §9).**
- **Phase 0 is specified but unexecuted.** No `LabanControlServer` /
  `IntentRouter` / `IntentCatalog` / `LABAN_CONTROL_SERVER` anywhere in
  `Sources/`. The active Phase 0 plan places its spike under
  `Sources/LabanApp/Control/` (AppKit-free) deliberately, to be relocated in
  Phase 1.

## 3. Corrected architecture (one consistent target map)

v1 contained one genuine inconsistency: §5.3 placed `LabanControlServer` in
`LabanCore` while §0.2 placed it in a new `LabanControl` target. **v2 resolves
this in favor of a new `LabanControl` target.** `LabanCore` holds only
transport-neutral *types*; anything that knows about HTTP, tokens, or wire
framing lives in `LabanControl`.

### 3.1 End-state target placement (authoritative)

| Target | Owns | AppKit? | Depends on |
|---|---|---|---|
| **`LabanCore`** | Registry **types**: `Intent`, `Query`, `IntentResult`, `QueryResult`, `Capability`, `IntentDescriptor`, `IntentCatalog`, and the `IntentRouter` **protocol**. No HTTP, no AppKit, no transport. | No | (unchanged) |
| **`LabanControl`** *(new)* | `LabanControlServer` (loopback bind + token + Host/Origin), `LabanControlPolicy` (intent→capability mapping), the **HTTP↔Intent adapter** (decodes a request into an `Intent`/`Query`, serializes the result), `control.json` advertisement writer, and catalog-driven schema/discovery generation. | No | `LabanCore` |
| **`LabanApp`** | `LiveIntentRouter` (binds the live `AppModel` + `AppSessionCoordinator` + `MetalReadback`); **mounts** `LabanControlServer`. The GUI human adapters (`executeAppCommand`, menus, key routes) emit the **same** `Intent`s. | Yes | `LabanControl`, `LabanCore`, `LabanRenderer`, `LabanDebug` |
| **`LabanDebug`** | `HeadlessIntentRouter` + `HeadlessDebugRuntime` + fixtures + the headless-only `FixtureActionCatalog`; **mounts the same** `LabanControlServer`. | No | `LabanControl`, `LabanCore`, `LabanRenderer`, `LabanTerminalCore` |
| **MCP layer** *(later, Phase 5)* | An MCP server whose tool shapes are **generated from `IntentCatalog`** with hand-curated descriptions; an out-of-process wrapper over the same HTTP/Intent surface, or a `LabanControl`-hosted transport. Never a parallel implementation. | No | `LabanControl` (contract only) |

**The invariant that makes parity structural:** there is **one** `LabanControlServer`,
**one** `IntentCatalog`, and the `IntentRouter` **protocol** has exactly two live
implementations — `LiveIntentRouter` (GUI) and `HeadlessIntentRouter` (offscreen).
Both mount the same server. A **catalog-parity test** (Phase 2) enumerates
`IntentCatalog` and asserts both routers handle every shared intent, turning drift
into a CI failure. This **replaces** the AGENTS.md "wire every subsystem into both
by hand" rule with "both mount the shared server and pass the catalog-parity test."

### 3.2 Adapters terminate at one router

```
GUI menus / key routes / mouse  ─┐
HTTP request (LabanControl)       ├─►  Intent / Query  ──►  IntentRouter
MCP tool call (Phase 5, wrapper) ─┘                         (Live or Headless)
                                                                   │
                                                   AppSessionCoordinator + AppModel
                                                   (tier-agnostic: inProcess/labpty/laband)
```

`executeAppCommand` (today a direct in-process call) becomes a **thin adapter**
that constructs an `Intent` and hands it to the router — a low-risk refactor, not
a rewrite, because it already funnels keyboard commands to the same core methods.

### 3.3 Identity and addressing (a v2 sharpening)

The codebase has three identities; intents must address the right one or agents
will act on the wrong terminal after UI churn:

- **`Session.ID`** (`String`/UUID): the **stable** identity that owns the PTY and
  VT state and **survives tab selection, resize, view rebuild** (an AGENTS.md hard
  rule). **This is the primary key for any intent that reads or writes terminal
  I/O** (`terminal.*`): typed text, grid, scrollback, process context, waits.
- **`Tab.ID`** (`String`): a UI handle that *references* a `sessionId`. It is the
  key for **window/tab lifecycle** intents (`tab.create/select/close`,
  `window.*`).
- **"active"**: a convenience selector. Every intent accepts an explicit id; when
  omitted it resolves against the active tab/session, and the result echoes the
  concrete id it acted on so a caller can pin it thereafter.

Rule: **never key off an index for anything that outlives a single request.**
Indices are accepted only as an ergonomic shorthand (e.g., Phase 0 `selectTab`)
and are resolved to a stable id immediately.

### 3.4 Transport and discovery

- **Transport:** raw **loopback HTTP/1.1 + bearer token** is the primitive layer
  through Phase 1. It already exists, is schema-backed, is exercised by CI, and is
  `curl`-debuggable. A Unix-domain-socket transport was originally dismissed as
  "buys little over loopback+token+Host/Origin" — but the 2026-06-20 competitive
  research (**Appendix D**) **weakens that rationale**: every strong typed-API
  competitor (iTerm2, Wave, kitty) *prefers* a UDS, and a UDS *eliminates* the
  DNS-rebinding / Host-Origin attack class ADR 0024 otherwise hand-rolls a defense
  against, with OS filesystem-permission gating for free. iTerm2's model is the
  likely synthesis (**UDS-primary, TCP-fallback**). The transport is
  **deferrable** — the catalog/router seam is transport-agnostic — so this is a
  §3.4 / Phase-2 reconsideration (open question §8.6), **not a Phase-0/1 blocker**.
- **Discovery (long-lived GUI):** the stdout readiness line that the headless
  agent prints cannot reach a process the agent did not launch, so the GUI writes
  a discovery file **`control.json`** = `{ url, token, pid, runId }`, mode `0600`,
  written atomically *and created `0600` from the first byte* (§5.1 token classes:
  this file's `token` is the **observe-only** credential — control/sensitive
  tokens never land here), under `$LABAN_CONTROL_DIR` or (unset)
  `~/Library/Application Support/Laban/` — same app-support convention as
  `Sources/LabanApp/EventLog.swift`.
  It is removed best-effort on quit; a stale file from a crash is harmless (it
  points at a dead port) and is overwritten next launch.
  *(Note for future readers: the `laband` daemon's `"control-json/v1"` is a wire
  **transport-mode label**, not this file — there is no filename collision.)*

## 4. The Typed Intent Catalog

The catalog is the **single source of truth** from which the discovery document,
the JSON schemas under `schemas/`, the security policy, and (Phase 5) the MCP
tool list are **generated** — never hand-maintained in parallel. Adding an intent
regenerates discovery + schema and fails `check-debug-contract` until classified.

### 4.1 Core types (in `LabanCore`)

```
Intent        // tagged, Codable: the union of today's AppCommand + DebugAction
              // operations (tab.create/select/close, terminal.typeText/sendKey/
              // paste/interrupt/scroll/search/selectRange/resize, window.*, …)
Query         // tagged, Codable read request (state, tab.getState, terminal.*…)
IntentResult  // { ok, actedSessionId?, actedTabId?, eventId?, error? }
QueryResult   // Codable read response (per-query payload)
Capability    // .observe | .observeSensitive | .navigate | .propose | .input | .clipboard | .fixture
              //   .input  = actuation (typeText/sendKey/paste/mouse), fixture/headless-only
              //   .navigate = benign live nav (scrollViewport; tab.select removed — focus-hijack)
              //   .propose  = command.propose (a reviewed suggestion, never PTY bytes)
              //   (.control retired — a future actuation/lease tier is .input + a distinct .execute)
IntentDescriptor   // the metadata record below
IntentCatalog      // [IntentDescriptor], queryable + serializable
IntentRouter (protocol)  // route(Intent) -> IntentResult ; query(Query) -> QueryResult
```

Phase 0 ships a narrow seed of this — `protocol ControlRouter` with
`snapshotState()` + `selectTab(index:)`. **Phase 1 generalizes `ControlRouter`
into `IntentRouter`**; the Phase 0 spike is subsumed, not contradicted.

### 4.2 The expanded `IntentDescriptor` model

Every entry in the catalog carries the full metadata the program needs to
generate transports, enforce safety, and version the surface. (Shown as a Swift
shape plus a YAML rendering of one intent.)

```swift
struct IntentDescriptor {
  let id: String                 // stable dotted identifier, e.g. "terminal.typeText"
  let kind: Kind                 // .query | .action | .wait | .event
  let category: String           // "app" | "window" | "tab" | "terminal" |
                                 //   "trace" | "screenshot" | "event" |
                                 //   "approval" | "policy" | "audit"
  let summary: String            // one human-readable sentence

  // Contracts (schema refs are generated into schemas/ and validated in CI)
  let inputSchema: SchemaRef
  let outputSchema: SchemaRef
  let errorSchema: SchemaRef

  // Authorization
  let requiredCapability: Capability

  // Side-effect classification (drives audit + risk + which transports may carry it)
  struct SideEffects {                 // all default false
    var ptyInput     = false           // bytes reach the child shell
    var lifecycle    = false           // creates/destroys tabs/sessions/windows
    var filesystem   = Possibility.no  // .no | .possible (depends on shell state)
    var network      = Possibility.no
    var clipboard    = false
  }
  let sideEffects: SideEffects

  // Risk (advisory in v1 floor; the Phase 7 broker consumes level + reason)
  struct Risk { let level: Level; let reason: String }   // .none|.low|.medium|.high
  let risk: Risk

  // Audit behavior for the EventLog
  enum Audit { case none, metadataOnly, redactedInput, fullInput }
  let audit: Audit

  // What may LEAK if this intent's output is logged or exposed. Capability says
  // WHO may call; sensitivity says WHAT escapes — it drives redaction, audit
  // verbosity, MCP exposure, and the UI warning surface, independently of tier.
  enum DataSensitivity { case none, nonSensitiveState, visibleText, scrollback,
                              keystrokes, clipboard, screenshot, trace }
  let dataSensitivity: DataSensitivity

  // Where this intent can run, and over which transports it may be exposed
  struct Availability { let gui: Bool; let headless: Bool }
  let availability: Availability
  struct Transports { let http: Bool; let mcp: Bool; let cli: Bool }
  let transports: Transports

  // Execution semantics
  let preconditions: [Precondition]    // e.g. .sessionExists, .shellAtPrompt
  struct Timeout { let defaultMs: Int; let maxMs: Int }   // waits carry real values
  let timeout: Timeout?
  enum Cancellation { case none, cooperative }            // long ops accept a cancel token
  let cancellation: Cancellation

  // Versioning / deprecation
  struct Version { let since: String; let deprecatedSince: String?; let replacement: String? }
  let version: Version
}
```

```yaml
# Generated rendering of one catalog entry
id: terminal.typeText
kind: action
category: terminal
summary: Type UTF-8 text into a terminal session as if a human typed it.
input:  { sessionId: string?, text: string }      # sessionId omitted ⇒ active session
output: { ok: boolean, actedSessionId: string, eventId: string }
error:  { code: string, message: string }
requiredCapability: input        # actuation tier — fixture/headless only (2026-06-20 amendment)
sideEffects: { ptyInput: true, filesystem: possible, network: possible }
risk: { level: medium, reason: "Text may execute commands depending on shell state." }
audit: redactedInput
dataSensitivity: keystrokes
availability: { gui: false, headless: true }   # NOT on the live GUI; deferred to the Terminal-Lease ADR
transports: { http: true, mcp: false, cli: false }
note: headless fixture only until the Terminal-Lease / Computer-Use ADR; on the live surface, command.propose (a reviewed data object) is the Phase-2 equivalent
preconditions: [ sessionExists ]
timeout: null
cancellation: none
version: { since: "0.2" }
```

### 4.3 Two catalogs

- **`IntentCatalog`** (shared) — cross-surface, user-meaningful operations both
  routers implement. The catalog-parity test guards it.
- **`FixtureActionCatalog`** (headless-only) — deterministic test affordances:
  `feedOutput` (inject synthetic child bytes), `advanceFrames`, `windowFocus`,
  title-forcing. Gated behind a `.fixture` capability the **shipped GUI never
  grants**. `feedOutput`/`advanceFrames` are **barred from the live surface**
  (byte-injection / no-op-live). Relative tab navigation folds into
  `tab.select(relative:)` in the shared catalog.

### 4.4 Naming

Catalog ids are stable **`category.verb`** dotted strings (`tab.select`,
`terminal.typeText`, `terminal.waitForText`). Phase 0 ships the bare wire action
`selectTab`; Phase 1 assigns it the canonical id `tab.select` and the HTTP adapter
accepts **both** the bare and dotted forms through the migration so Phase 0
clients keep working.

## 5. Capability and security model

**Posture: token-gated, observe-on-by-default, fail closed.** Reuse the existing
`debugToken` mechanism verbatim (32-byte hex, constant-time compare); harden the
transport and split capabilities. The model has a **floor** (Phase 2) and a
**broker** (Phase 7) — do not conflate them.

### 5.1 Capability tiers

> **Superseded for Phase 2 by the header Amendment (2026-06-20).** The `.control`
> row is **retired and split**: its *actuation* (typeText/sendKey/paste, mouse)
> becomes an `.input` capability that is headless/`.fixture`-only and off the live
> GUI; its benign navigation becomes **`.navigate`** (`scrollViewport` only; `tab.select`
> removed as a focus-hijack/input-redirect vector)
> and `command.propose` becomes its own **`.propose`**. There is no `.control`
> capability in the end-state enum (`observe, observeSensitive, navigate, propose,
> input, clipboard, fixture`). The "Token classes" app-scoped control/sensitive token
> below is **replaced** by two observe tiers (app-observe + agent-attached-only,
> session-bound session-observe), and per-session scoping is **pulled into Phase 2**
> (not Phase 7). The capability *machinery* — catalog-generated deny-by-default
> policy, `dataSensitivity` independent of `requiredCapability` — is unchanged. Read
> the rows below for the machinery, not the capability names / actuation / token
> placement.

| Capability | Grants | Lands |
|---|---|---|
| `.observe` | Non-sensitive live state: tab/window/session lists, dimensions, prompt phase, active ids, events. | Phase 2 floor |
| `.observeSensitive` | Scrollback, visible-grid text, process cwd/command, input log, clipboard summary. (A keylogger/exfiltration surface — separable from `.observe`.) | Phase 2 floor |
| `.control` | Mutations: typeText/sendKey/paste, resize/scroll/select, tab+window lifecycle, interrupt. | Phase 2 floor |
| `.clipboard` | Programmatic clipboard write (OSC 52 write only; read never implemented). | Phase 2/7 |
| `.fixture` | Headless determinism affordances; shipped GUI never grants it. | Phase 1 |

The policy is **generated from the catalog**, so a new intent is **denied by
default** until it is classified with a `requiredCapability`.

**Token classes — which credential carries which tier.** A single token that is
both advertised in a file *and* grants control is unsafe under observe-on-by-
default: `0600` stops other Unix *users*, but **not** an arbitrary same-user
process that knows the path (`~/Library/Application Support/Laban/control.json`).
So tiers map to *different* credentials, not one shared token:

| Token | Delivered via | Grants |
|---|---|---|
| **Observe token** | `control.json` (world-known path, `0600`) | `.observe` only — non-sensitive state |
| **Control/sensitive token** | child-env injection (`LABAN_CONTROL_TOKEN`) into agents Laban spawns | `.control` + `.observeSensitive` |
| **Fixture token** | headless test harness only | `.fixture` |

A same-user process can read the file (so the file token must be low-stakes) but
**cannot read another process's environment** on macOS without debugging
entitlements — so the control/sensitive token rides the child env, not the file.
Both tokens are **app-scoped in v1**; **per-session** scoping is the Phase 7 add.
The "agent attached" indicator is a backstop, not the primary control — the file
token never grants control, so a same-user reader of `control.json` cannot drive
the terminal in the first place.

### 5.2 Transport hardening (the CDP/WebDriver lesson)

1. **Bind loopback only** — explicit `127.0.0.1`/`[::1]`, never `0.0.0.0`.
2. **Validate `Host` on every request** — reject anything not literally
   `localhost`/`127.0.0.1`/`[::1]` (defeats DNS-rebinding).
3. **Reject any request bearing an `Origin` header** — there is no browser
   client; an `Origin` means a web page is calling. (Phase 0 already does 1–3.)
4. **Token required; absence or mismatch ⇒ deny** (401), never a default-allow.
5. **Control/sensitive token injected into child env** (`LABAN_CONTROL_TOKEN` +
   `LABAN_CONTROL_URL`) — the `.control`/`.observeSensitive` credential is **never
   the `control.json` token**; it is delivered only into the env of children
   Laban spawns. An agent Laban launched authenticates with zero prompt; an
   unrelated local process can read the file (observe-only) but cannot read
   another process's env. The `labpty` wire already carries child `envp`, so this
   needs **no wire change** (does not touch the ADR 0007 freeze). **Both tokens
   are app-scoped in v1; per-session scoping is a confirmed-cheap Phase 7 add.**

### 5.3 Standing constraints

- **No in-band escape-sequence control channel.** Never write title/clipboard
  read-backs into the input stream; constrain DECRQSS/DSR replies (the
  CVE-2022-45872 class). Programmatic "type this" routes through the **same**
  validation a human keystroke does. Treat all agent/model/tool/repo bytes as
  untrusted before the VT parser.
- **High-power reads are privileged** — full keystroke stream and full scrollback
  dumps require `.observeSensitive`, never bare `.observe`; every
  `.observeSensitive`/`.navigate`/`.propose` access is logged to the EventLog.
- **User-visible "agent attached" indicator** whenever a privileged
  (`.observeSensitive`/`.navigate`/`.propose`) client is active.
- **No-auth dev mode** (CI only) is opt-in, scoped, and loud.

### 5.4 When the default flips on

Through Phase 0–1 the server is **off unless `LABAN_CONTROL_SERVER=1`**. The
**observe-on-by-default flip happens at the Phase 2 boundary** — but gated on a
**release checklist**, not merely a phase label. Every item must hold before the
default flips:

- [ ] `control.json` grants an **observe-only** token (never `.observeSensitive`/`.navigate`/`.propose`/`.input`).
- [ ] `.observeSensitive` requires the separate env-injected token/scope.
- [ ] `.navigate`/`.propose` (and `.observeSensitive`) require the separate, agent-attached session-observe env token/scope; `.input` is fixture/headless-only.
- [ ] The token file is created `0600` **from the first byte** (not chmod-after-write).
- [ ] `Host` + `Origin` validation rejects malformed/spoofed hosts (tests cover `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`).
- [ ] A visible "agent attached" indicator exists.
- [ ] A user-facing disable switch exists.
- [ ] Audit events persist to the EventLog.
- [ ] No token value is ever logged.

## 6. Phased roadmap

Tracer-bullet vertical slices. Every phase keeps CI green and the GUI unchanged
for humans. Each phase lists **scope**, **files**, **acceptance** (observable
behavior), and **status**.

### Phase 0 — Live control seam spike *(authoritative spec: `execplans/completed/agent-first-phase0-control-seam.md`)*

- **Scope:** one query (`GET /debug/state`) + one control intent
  (`POST /debug/actions {"action":"selectTab","index":N}`) end-to-end through a
  minimal `ControlRouter` + `LabanControlServer` **hosted in the running
  `LabanApp` GUI**, against the live `AppModel`, behind `LABAN_CONTROL_SERVER=1`,
  with token + Host/Origin from the start.
- **Files:** `Sources/LabanApp/Control/{ControlRouter,LiveIntentRouter,LabanControlServer,ControlAdvertisement}.swift`; edits to `MainWindowController.swift` + `AppDelegate.swift`; `Tests/LabanAppTests/ControlServerPhase0Tests.swift`. *(Do not re-specify here; follow the active plan.)*
- **Acceptance:** `swift test --filter ControlServerPhase0Tests` passes (guard
  matrix + live select-tab + loopback round-trip); manual `curl` shows
  `activeTabId` change in the real window; default launches open no socket.
- **Status:** **shipped** (commit `0a2a230`) — hosted in the live GUI behind `LABAN_CONTROL_SERVER=1`, verified against the running app (authed `GET /debug/state` returns the real window; 401/403/404 guards fire), review gate **PASS**.

### Governance gate *(before Phase 1 lands)*

- Add a `docs/product/spec.md` entry (this is new product scope).
- Write **ADR 0023** (architecture: *LabanApp hosts the loopback control+query
  server; one `IntentRouter`; three-way `LabanCore`/`LabanControl`/`LabanDebug`
  split; lean parity via the catalog-parity test*) and **ADR 0024** (security:
  *loopback + Host/Origin + capability tokens; escape-sequence control deferred*).
  **Use 0023/0024 — v1's 0012/0013 are taken (the index runs to 0022).**
- Verify no `docs/product/mvp.md` regression.
- **Acceptance:** both ADRs merged with index entries; `spec.md` names the control
  plane; `scripts/check` green.
- **Status:** **done** (2026-06-20) — ADR 0023 + 0024 written and indexed,
  `spec.md` §24 added, `mvp.md` no-regression confirmed (the control plane is
  additive and env-gated off; `mvp.md` already contemplates the debug server and
  states no no-network guarantee).

### Phase 1 — Registry backbone + carve `LabanControl`

- **Scope:** extract `Intent`/`Query`/`IntentResult`/`QueryResult`/`Capability`/
  `IntentDescriptor`/`IntentCatalog`/`IntentRouter` into `LabanCore` (generalizing
  Phase 0's `ControlRouter`). Define the **two catalogs**. Carve
  `DebugHTTPServer`/`Debug*Endpoints` out of `LabanDebug` into the new
  **`LabanControl`** target, reframed as the **HTTP↔Intent adapter**.
  `executeAppCommand` and the HTTP adapter both emit intents. **Generate**
  discovery + the `schemas/` set + the policy from the catalog.
- **Files (new/moved):** `Sources/LabanControl/**`; `Sources/LabanCore/Intents/**`;
  `Package.swift` (new target + deps); `LabanApp`/`LabanDebug` dependency edits;
  catalog→schema generator wired into `scripts/check` (`check-debug-contract`).
- **Acceptance:** `LabanControl` builds AppKit-free; the generator emits discovery
  + every schema and the contract gate fails if an intent lacks a schema or
  capability; existing headless E2E tests pass unchanged against the carved
  adapter; `feedOutput`/`advanceFrames` are absent from the shared catalog.
- **Subphases (each independently reviewable — the endpoint carve is too large for one PR):**
  | # | Goal |
  |---|---|
  | 1A | Add `LabanCore/Intents` types + `IntentCatalog`; **no endpoint moves**. |
  | 1B | Add the `LabanControl` target with a new HTTP↔Intent adapter for the Phase-0-equivalent routes only. |
  | 1C | Move/re-point existing `Debug*Endpoints` incrementally behind adapter wrappers (a few routes per PR). |
  | 1D | Turn on catalog→discovery/schema generation + the contract gate. |
- **Status:** **shipped** (2026-06-20) — `execplans/completed/agent-first-phase1-intent-registry-and-labancontrol.md`, Review Gate APPROVED. One server (`LabanControl`), one `IntentCatalog`, `LiveIntentRouter`/`HeadlessIntentRouter`; `DebugHTTPServer` deleted; `LabanControlGen` generates + gates the discovery doc.

### Phase 2 — Mount live (observe-first) + security floor + flip the default

*(Recast 2026-06-20 to observe-first — see the header Amendment.)*

- **Scope:** `LiveIntentRouter` in `LabanApp`; re-point the `Debug*Endpoints`
  state/sessions/find/selection at the **live** `AppModel` + `AppSessionCoordinator`
  (not the headless mirror), scoped to the caller's **own session**. Land the
  **security floor**: Host/Origin everywhere, **two observe tiers** (app-observe in
  `control.json` + per-session **session-bound** session-observe via child-env
  injection — **no app-wide control token**), `.observe`/`.observeSensitive`
  **session-scoped** (cross-tab → 403), "agent attached" indicator, disable switch,
  audit. The live surface is **observe + benign own-session navigation only**
  (`scroll` only; `tab.select` removed — focus-hijack); **input/mouse/clipboard actuation and cross-tab are NOT
  on the live surface** — the input family is `.input`, headless/`.fixture`-only.
  Add **command proposals** (reviewed data object, never PTY input) and the
  **catalog-parity test**. **Flip observe-on-by-default ON** behind the §5.4
  checklist.
- **Files:** `Sources/LabanApp/Control/LiveIntentRouter.swift` (own-session observe
  + benign nav; Phase-1 input removed/build-gated); `Sources/LabanControl/{LabanControlPolicy,ControlSecurityObserver,*}`;
  `Sources/LabanCore/Control/Projections/*`; `LabanDebug` `Debug*Endpoints`
  re-pointing; `Tests/.../CatalogParityTests.swift`; `MainWindowController`/
  `AppDelegate` mount edits (per-session token before `AppModel.init`).
- **Acceptance:** an agent reads `control.json` and `curl`s only the **redacted app
  summary** with the app-observe token; a **per-session** env token reads **its own
  session's** sensitive state (`.observeSensitive`) and any other session is refused
  (403); input/mouse/clipboard/cross-tab are unreachable on the live surface
  (404/403); missing token ⇒ 401, bad `Host`/any `Origin` (incl. non-numeric port)
  ⇒ 403; a privileged read lights the indicator; the catalog-parity test fails if
  either router omits a shared intent; the §5.4 checklist + env-secrecy gate pass
  before the default flips. Live input actuation and autonomous driving are deferred
  to the Terminal-Lease ADR.
- **Status:** **planned** — ExecPlan at
  `execplans/active/agent-first-phase2-mount-live-and-security-floor.md` (observe-first;
  milestones 2A–2F; not started).

> Phases 3–4 are the **first-class product pillars** the live-control seam exists
> to enable. They are promoted ahead of MCP and the truthful-fixture work.

### Phase 3 — Event stream pillar

- **Scope:** promote the poll-cursor `/debug/events?since=N` into a **push stream**
  (SSE or long-poll) keyed to stable session/tab ids, with a typed event model
  (`window.*`, `tab.*`, `session.*`, `prompt`, `cwd`, `process`,
  `command.started`, `command.finished`, `selection`, `viewport`,
  `frame.committed`, `intent.{requested,accepted,rejected}`, `screenshot`,
  `capture.*`). Back it with the always-on `EventLog`. (The OSC 133
  prompt-phase transitions and OSC 7 cwd changes become first-class events — the
  same substrate that powers the failed-command indicator, surfaced to clients.)
  A `command.finished` correlates the OSC 133 C→D span and carries `{ sessionId,
  cwd, exitCode, startedAt, endedAt, outputRange, commandText?, confidence }` —
  `commandText` is **nullable** and `confidence` is mandatory (`shellIntegration`
  when overlay markers bound the run, `heuristic` otherwise). These are
  **events, not a stored object or a `commandBlock.*` API** (§9).
  Every event shares one envelope, defined now so emitters cannot improvise:
  `{ seq, runId, sessionId?, tabId?, kind, time, stateVersion }`. **`seq` is a
  monotonic per-run cursor and the primary ordering/replay key — never
  timestamps** (`time` is advisory). `event.getSince(seq)` replays the gap.
- **Files:** `Sources/LabanControl/EventStream*`; `Sources/LabanCore/Events/**`;
  `schemas/control/event*.json`; subscription endpoint in the HTTP adapter.
- **Acceptance:** a client subscribes to its own session; when a command runs there
  (entered by the human, or by the `.fixture` token in headless tests — not by live
  agent input), it receives ordered `prompt`/`process`/`command.finished`/`frame.committed`
  events without polling; the `command.finished` carries the exit code and cwd
  (`confidence: shellIntegration` under the zsh overlay, `commandText: null`
  until a command-line marker exists); events replay from `EventLog` via
  `event.getSince`.
- **Status:** not started.

### Phase 4 — Trace/replay pillar

- **Scope:** elevate the existing `CaptureRecorder` (already used in `LabanApp`)
  into a first-class, agent-exportable **trace bundle**: PTY in/out/response
  bytes, user actions, **intent requests + results**, window/tab/session metadata,
  resize events, screenshots/frame hashes, redaction report, build metadata. Add
  `trace.start/stop/export` intents and CI replay.
- **Files:** `Sources/LabanDebug/CaptureRecorder*` (extend);
  `Sources/LabanControl` trace intents; `schemas/capture/*` extensions;
  `scripts/replay-capture` coverage of intent events.
- **Acceptance:** after a session, `trace.export` writes a bundle whose
  `replay/report.json` shows `terminalReplay: passed`, and the bundle contains the
  intent timeline + redaction report.
- **Status:** not started.

### Phase 5 — MCP front door *(generated from the catalog)*

- **Scope:** an in-house MCP server with tool shapes **generated from
  `IntentCatalog`** (descriptions hand-curated), as an out-of-process wrapper over
  the same HTTP/Intent surface. **Read-only / observe tools (and `command.propose`)
  only**; live actuation tools wait for the Terminal-Lease ADR. Publish the
  HTTP+schema contract too. Begin
  Claude-in-Laban dogfooding. *(MCP needs only the catalog + Phase 2 floor; it may
  be pulled forward for dogfooding once those exist.)*
- **Acceptance:** a generated MCP tool list matches the catalog 1:1; a session-scoped
  MCP client orients (its own session's tabs/active/visible text) with every call
  audited; live driving (typeText/mouse) is **not** in the Phase-2 MCP and returns
  only after the Terminal-Lease ADR.
- **Status:** not started.

### Phase 6 — Truthful-fixture pillar (view-layer work)

- **Scope:** wire `MetalReadback` so `screenshot`/`pixel-probe`/`frame-commands`
  are **GUI-truthful** (decide `captureMode` synchronous vs async/queued readback
  — the perf tradeoff). Promote selection/cursor/find to first-class
  live-queryable state via new AppKit-view accessors (today only the headless
  mirror has them).
- **Acceptance:** a GUI screenshot/pixel-probe reflects the Metal output a human
  sees; `terminal.getSelection` returns the real AppKit selection.
- **Status:** not started.

### Phase 7 — Terminal-Lease / Computer-Use + Safety Broker

*(Recast 2026-06-20: this is the home for the actuation the observe-first pivot
deferred. Per-session token scoping is **no longer** here — it moved into Phase 2.)*

- **Scope:** an explicit, user-granted **terminal-input / terminal-execute lease**
  (the actuation tier): a command classifier + approval UI (`rm -rf`, `git push
  --force`), **no self-injection by default**, cross-session only by a **named** user
  grant, clipboard/paste/secret policies, audit browser/export. New-capability intents
  with no current counterpart: theme, font, restore toggle, backend switch,
  **restart**, tab reorder, hyperlink open; GUI capture control.
- **Acceptance:** a `terminalExecute` lease request for an `rm -rf`-class command
  raises an approval the user must grant; existing **Phase-2 session-observe tokens
  remain read + benign-nav only and cannot execute commands**; the audit browser lists
  every leased action.
- **Status:** not started.

## 7. Acceptance criteria (consolidated)

The program as a whole succeeds when, against the **running `LabanApp` GUI**:

1. A local client discovers the app via `control.json`, authenticates with the
   **observe** token, and is denied without one (401) or with a forged `Host`/any
   `Origin` (403). Sensitive reads and control are refused with the observe token.
2. With its **agent-attached session-observe** token the client reads **its own
   session's** live grid/scrollback/process/prompt/selection/find state keyed off
   stable ids — session-scoped (cross-session → 403) and audited. Live input/mouse
   actuation is **deferred** to the Terminal-Lease ADR; command assistance is via
   `command.propose` (a reviewed data object, never PTY bytes).
3. Waits replace sleeps; events stream without polling.
4. Trace export and MCP tools all derive from the **one** catalog with no
   duplicated definitions.
5. The catalog-parity test makes GUI/headless drift a CI failure.
6. A human sees and can disable what external clients may do.

Per-phase acceptance is in §6 (each is observable behavior, not an internal
attribute).

## 8. Open questions (genuinely remaining)

These are *not* resolved; the resolved-8 from v1 are recorded in Appendix B.

1. **Intent-id migration window.** How long does the HTTP adapter accept both the
   bare Phase 0 action names and the dotted catalog ids before the bare forms are
   removed? (Affects when Phase 0 clients must update.)
2. **Event-stream transport.** SSE vs HTTP long-poll vs **WebSocket** for Phase 3.
   The 2026-06-20 research (Appendix D) finds the typed-catalog leaders push over
   **WebSocket** (Wave, iTerm2) or a text protocol (tmux); *no* terminal pushes
   over loopback HTTP, so HTTP-SSE/long-poll is the unusual choice. Pick at Phase 3
   start, tied to the transport question (§8.6).
3. **Metal readback cost (Phase 6).** Is a synchronous drawable readback
   acceptable for `screenshot`/`pixel-probe` latency, or is an async/queued
   capture required? Decides the Phase 6 API shape.
4. **MCP timing.** Hold MCP at Phase 5, or pull it forward for dogfooding the
   moment the Phase 2 floor + catalog exist? (It is only a generated wrapper.)
5. **Per-session token rollout.** ~~Deferred to Phase 7~~ **Resolved (2026-06-20
   observe-first amendment):** per-session, session-bound tokens are **pulled into
   Phase 2**, agent-attached-only; there is no app-wide control token. (Header
   Amendment; §5.1 superseded note.)
6. **UDS transport (sharpened by Appendix D).** The competitive research supplies
   the "concrete need": iTerm2, Wave, and kitty all prefer a Unix domain socket,
   which sidesteps the whole DNS-rebinding/Host-Origin attack class and adds OS
   permission gating. Re-decide at the Phase-2 boundary: keep loopback-HTTP-only,
   or adopt iTerm2's **UDS-primary + HTTP-for-curl/debug** split? (Sub-question:
   does loopback alone stop DNS-rebinding, or is Host/Origin strictly required —
   the research's sharpest unresolved security point — which drives the must-haves.)

## 9. Non-goals

- A chatbot or agent model inside the terminal. This is **substrate** for external
  agents (Claude Code, Codex, scripts, tests), not an embedded agent.
- **Semantic command-block *objects* / Warp-style blocks.** No stored
  `CommandBlock` model, no `commandBlock.*` query API, and no block-navigation UI
  (decided 2026-06-20). Rationale: Laban's injected OSC 133 captures command
  *boundaries*, exit code, and cwd but **not the command text** (the overlay omits
  the `B` marker and emits a bare `C` with no command-line payload), and bash
  boundaries are weak (its `preexec` is a coarse `DEBUG` trap), so an addressable,
  queryable block product would over-promise. **In scope (Phase 3), explicitly:**
  the `command.started`/`command.finished` **events** (boundaries, exit, cwd,
  output range, mandatory `confidence`, nullable `commandText`) and the
  shell-integration **phase** behind the failed-command indicator. The line held
  is *events, not objects* — clients observe command runs in the stream, but
  nothing stored, queryable, or navigable. Reopen the object/API/UI only if a
  concrete consumer needs the literal command line (which would require a
  `B`/command-line marker, à la VS Code's `OSC 633;E`). **Caveat (2026-06-20
  research, Appendix D):** this is the thinnest-evidenced decision — stored blocks
  are a *human-facing* differentiator competitors ship (Wave's addressable-block
  model; Warp's blocks), the human-ergonomic side was not weighed when the call was
  made, and the foil (Warp) produced **zero verified claims** (a coverage hole).
  The decision stands on the substrate constraint, but a focused Warp/OSC-633 pass
  should pressure-test it before it is treated as settled.
- A replacement for shell integration, a screen-scraping API, a remote-desktop
  protocol, or an unauthenticated debug server.
- Network/remote access, multi-user/team features, or any non-loopback binding.
- MCP-first: MCP is a generated wrapper over a stable HTTP/Intent contract, built
  after the catalog and security floor — never the primitive.
- Re-litigating the resolved decisions in Appendix B without new evidence.

---

## Appendix A — Comparator lessons (historical rationale)

*(Preserved from v1 §4 for the "why." Nothing in §1–9 requires reading this, and
the command-block lesson below was surveyed but ultimately declined — see §9.)*
Key takeaways that shaped the body: **one state authority, many thin clients**
(tmux/wezterm `Mux`; wezterm GUI and `wezterm cli` are both mux clients with no
separate debug binary) — the direct refutation of the `LabanApp`/`LabanAgent`
split; **stable ids, never indices** (tmux `$/@/%`, kitty `--match`, wezterm
`pane_id`); **two read primitives** (rendered grid for assertions vs raw bytes for
fidelity — tmux `capture-pane` vs `%output`); **typed input fidelity** (iTerm2
`async_send_text` vs `async_inject`; first-class control-char injection for
Ctrl-C); **push, not poll** (iTerm2 notifications; wezterm's missing event stream
is its cited weakness); **semantic command framing from OSC 133/633** (VS Code,
Warp blocks) — surveyed and **declined** for Laban (§9); **one canonical versioned
surface** (iTerm2 deprecating AppleScript for the typed protobuf API). Security
consensus: **default-deny, loopback-only, token-authed, fail closed** (iTerm2
`ITERM2_COOKIE` + per-app consent; kitty password tiers; ttyd
read-only-until-`--writable`); **loopback is necessary but not sufficient** — Host
+ Origin validation defeat DNS-rebinding (CDP/WebDriver lesson);
**escape-sequence control is a severe trust boundary** (iTerm2 CVE-2022-45872; OSC
52 read universally refused). Verifier caveat: cite iTerm2's **cookie + per-app-
consent** as the security precedent, **not** its socket-vs-TCP transport choice
(its source labels the unix path "Experimental").

## Appendix B — Resolved decisions (grilling 2026-05-30) and v2 deltas

The eight v1 questions were resolved during a 2026-05-30 grilling; v2 keeps all
eight and records what changed since:

1. v1 scope = relocation-MVP (drive + read). **Kept.**
2. Three-way target split; registry in `LabanCore`. **Kept; v2 fixes the v1 §5.3
   vs §0.2 contradiction by placing the *server* in `LabanControl`, not
   `LabanCore`** (§3.1).
3. Token-gated observe-on-by-default, flipped at the Phase 2 boundary. **Kept** (§5.4).
4. Token model + env-injection. **Refined (2026-06-20 observe-first amendment):**
   "single token" was unsafe for
   observe-on-by-default — a same-user process can read `control.json` despite
   `0600`. v2 split it into a two-tier model; the **2026-06-20 observe-first
   amendment** refines that further: two **observe** tiers (app-observe in the file +
   agent-attached-only, session-bound session-observe in the child env), **no
   app-wide control token**, and **per-session scoping pulled into Phase 2** (not
   Phase 7). Live actuation moves to a future Terminal-Lease ADR. (§5.1 + header
   Amendment.)
5. Two catalogs; `feedOutput`/`advanceFrames` barred from live. **Kept** (§4.3).
6. Lean parity via the catalog-parity test; `HeadlessDebugRuntime` kept. **Kept** (§3.1).
7. Governance gate (spec + ADRs) before Phase 1. **Kept; ADR numbers corrected
   0012/0013 → 0023/0024** (the index has since reached 0022).
8. MCP in-house, generated + curated. **Kept, but re-sequenced:** v2 promotes the
   **event stream and trace/replay to first-class pillars (Phases 3–4) ahead of
   MCP (Phase 5)** and the truthful-fixture work (Phase 6), per the v2 mandate. v1
   had MCP at Phase 3 and these pillars buried at Phase 5. **The v2 mandate's third
   proposed pillar, *semantic command blocks*, was reduced 2026-06-20** to
   command-run *events* in Phase 3 (boundaries/exit/cwd/confidence, nullable
   command text); the stored `CommandBlock` object, `commandBlock.*` API, and
   block UI are dropped — see Non-goals §9.

**Stale-fact corrections folded into the body:** ADR numbering (0023/0024);
`control.json` has no `laband` collision (the daemon's `control-json` is a
transport-mode label); `MetalReadback.swift` confirmed present; OSC 133 is
**injected** by Laban (not merely observed), but omits the `B`/command-line marker.

## Appendix C — Verified surface inventory (2026-06-20)

`DebugHTTPServer` (`Sources/LabanDebug/DebugHTTPServer.swift`, ~40 routes,
loopback + bearer token + port 0) is instantiated **only** by
`HeadlessDebugRuntime` (`LabanDebug` → `LabanAgent`); `LabanApp` never constructs
it (links `LabanDebug` for `CaptureRecorder` only). `AppModel`/
`TerminalSessionClient` are AppKit-free in `LabanCore`; `AppSessionCoordinator`
is the GUI funnel in `LabanApp`. `MetalReadback.swift` (`captureMode`, `pngData`)
exists in `LabanRenderer`. OSC 133 is injected via `ShellIntegrationOverlay`
(zsh/bash/fish) and reduced into `ShellIntegrationState`; OSC 7 cwd (ADR 0015),
OSC 52 write (ADR 0014) exist. No command-block object exists and **none is
planned** (§9). EventLog JSONL (`~/Library/Application Support/Laban/events/`) is
the only surface that already behaves like the vision against the real app
(always-on, read-only). No `LabanControlServer`/`IntentRouter`/`IntentCatalog`/
`LabanControl` target exists in `Sources/` as of this date.

## Appendix D — Competitive research (2026-06-20, primary-source)

A deep-research pass (27 primary sources — official docs, source code, man pages —
→ 124 extracted claims → **24 of 25 confirmed by 3-0 adversarial verification**, 1
refuted) validated the program thesis and surfaced three direction questions.
*Confidence: the six product findings are high (3-0 verified); the gap-analysis
cross-product is analyst synthesis (medium).*

**Thesis validated — the four-pillar combination is an empty cell.** No verified
product combines (a) a typed intent catalog, (b) a push event stream, (c) semantic
command blocks, and (d) an authenticated, capability-scoped server *in the real GUI
app, shared by GUI/headless/MCP*. Each leader holds only 1–2 pillars:

| | Typed API | Push events | Capability scoping | Auth | GUI-hosted | LLM exposure |
|---|---|---|---|---|---|---|
| **tmux** control mode | text (not schema) | **yes** (`%`-notifs, stable `$/@/%` ids, `%begin/%end/%error` framing) | no | **no** | no | — |
| **iTerm2** Python API | **protobuf/typed** | notification path, no documented catalog | per-app only | **yes** (cookie+key, single-use) | **yes** | typed |
| **wezterm** cli | typed actions (`--no-paste`) | **no** (poll; "emit" requested, never shipped) | no | local socket | yes | typed/poll |
| **kitty** `@` | command set | no (poll, JSON `ls`) | **best in field** (`is_cmd_allowed`+consent, password globs, source-gating) | yes | yes | typed/poll |
| **Wave** wshrpc | **yes** (one catalog, code-genned Go→TS, shared FE/BE/AI/CLI) | typed RPC | by block-reference, **not** classification; **no** Host/Origin | yes (JWT over UDS) | yes | typed |
| **iterm-mcp** (dominant MCP) | **no** (scrape+inject, 3 coarse tools) | no | no | none (STDIO) | no | scrape+inject |

Validations of current decisions: stable-id-not-index (universal across products);
one catalog → generated MCP shared across surfaces (**Wave is the sole precedent —
validates the architecture**); capability classification (kitty precedent; iTerm2's
per-app all-or-nothing auth is precisely the gap Laban fills); GUI-as-the-typed-
surface, not a sidecar (iterm-mcp scrape+inject is the anti-pattern Laban beats).

**Three direction questions raised — none block Phase 0/1:**

1. **Transport (§3.4, §8.6).** Every strong typed-API competitor prefers a **Unix
   domain socket**; UDS eliminates the DNS-rebinding/Host-Origin class ADR 0024
   defends. iTerm2 = UDS-primary + TCP-fallback. The §3.4 "UDS buys little"
   rationale is weakened; reconsider at Phase 2 (transport-agnostic, so deferrable).
2. **Command blocks (§9).** The thinnest-evidenced decision: stored blocks are a
   *human-facing* differentiator competitors ship; the foil (Warp) is unverified.
3. **Event-stream transport (§8.2).** Leaders push over **WebSocket** (Wave,
   iTerm2) or text (tmux); none over loopback HTTP.

**Caveats (honesty):** (1) The security CVEs the design cites (CVE-2022-45872
DECRQSS-as-typed; ttyd auth-bypass RCE; OSC 52; CDP/WebDriver Host/Origin) were
**not individually verified this run** — re-cite from NVD/MITRE/specs before
treating as load-bearing. (2) Coverage holes: **Warp**, the **OSC 133/633 specs +
VS Code per-command nonce**, **Ghostty**, and **Terminal-Bench** produced no
surviving voted claims (verification was budget-capped at 25) — a focused second
pass is needed for full pillar-(c)/foil coverage. (3) Correction: Wave's `wsh`
*does* require a Wave-issued JWT (more authenticated than first assumed), but still
publishes no capability-classification or Host/Origin model.

Key primary sources: tmux Control-Mode wiki; iTerm2 `api/library/python/iterm2/
connection.py` + `python-api-auth.html`; kitty `remote-control/` + `boss.py`;
wezterm `cli/` + `send-text`; Wave `wavetermdev/waveterm` + `docs.waveterm.dev/wsh`;
iterm-mcp `README` + `src/index.ts`.
