# Laban Agent-Control Surface — Design v2

**Status:** Active program roadmap. **Supersedes** the 2026-05-29 v1 of this file
(its comparator survey and grilling narrative are preserved verbatim in
Appendix A/B; nothing in the body below depends on reading them).

This is a **program roadmap**, not an executable ExecPlan. The single executable
slice in flight is `execplans/active/agent-first-phase0-control-seam.md`, which
is **authoritative for Phase 0**. This document must never contradict that file;
where Phase 0 detail is needed here it is summarized and linked, not restated.

> **How to read this document.** Sections 1–9 are forward-only and authoritative:
> a coding agent can execute any phase from them without reading anything marked
> "historical." There are **no "resolved decisions supersede the text below"
> caveats** anywhere in the body — every decision is stated once, in place.
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
- **Semantic substrate exists.** OSC 133 shell-integration phase
  (`ShellIntegrationState` in `LabanCore`: `idle`/`atPrompt`/`running`/`finished`
  + `lastExitCode` + `completedCommandCount`), OSC 7 cwd (ADR 0015), OSC 52
  clipboard write (ADR 0014). No higher-level **command-block** object yet.
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
| **MCP layer** *(later, Phase 6)* | An MCP server whose tool shapes are **generated from `IntentCatalog`** with hand-curated descriptions; an out-of-process wrapper over the same HTTP/Intent surface, or a `LabanControl`-hosted transport. Never a parallel implementation. | No | `LabanControl` (contract only) |

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
MCP tool call (Phase 6, wrapper) ─┘                         (Live or Headless)
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
  for all phases. It already exists, is schema-backed, is exercised by CI, and is
  `curl`-debuggable. A Unix-domain-socket transport is **not** adopted (it buys
  little over loopback+token+Host/Origin and complicates discovery); revisit only
  if a concrete need appears (tracked in §8).
- **Discovery (long-lived GUI):** the stdout readiness line that the headless
  agent prints cannot reach a process the agent did not launch, so the GUI writes
  a discovery file **`control.json`** = `{ url, token, pid, runId }`, mode `0600`,
  written atomically, under `$LABAN_CONTROL_DIR` or (unset)
  `~/Library/Application Support/Laban/` — exactly as the active Phase 0 plan
  specifies (same app-support convention as `Sources/LabanApp/EventLog.swift`).
  It is removed best-effort on quit; a stale file from a crash is harmless (it
  points at a dead port) and is overwritten next launch.
  *(Note for future readers: the `laband` daemon's `"control-json/v1"` is a wire
  **transport-mode label**, not this file — there is no filename collision.)*

## 4. The Typed Intent Catalog

The catalog is the **single source of truth** from which the discovery document,
the JSON schemas under `schemas/`, the security policy, and (Phase 6) the MCP
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
Capability    // .observe | .observeSensitive | .control | .clipboard | .fixture
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
                                 //   "commandBlock" | "trace" | "screenshot" |
                                 //   "event" | "approval" | "policy" | "audit"
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

  // Risk (advisory in v1 floor; the Phase 8 broker consumes level + reason)
  struct Risk { let level: Level; let reason: String }   // .none|.low|.medium|.high
  let risk: Risk

  // Audit behavior for the EventLog
  enum Audit { case none, metadataOnly, redactedInput, fullInput }
  let audit: Audit

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
requiredCapability: control
sideEffects: { ptyInput: true, filesystem: possible, network: possible }
risk: { level: medium, reason: "Text may execute commands depending on shell state." }
audit: redactedInput
availability: { gui: true, headless: true }
transports: { http: true, mcp: true, cli: true }
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
**broker** (Phase 8) — do not conflate them.

### 5.1 Capability tiers

| Capability | Grants | Lands |
|---|---|---|
| `.observe` | Non-sensitive live state: tab/window/session lists, dimensions, prompt phase, active ids, events. | Phase 2 floor |
| `.observeSensitive` | Scrollback, visible-grid text, process cwd/command, input log, clipboard summary. (A keylogger/exfiltration surface — separable from `.observe`.) | Phase 2 floor |
| `.control` | Mutations: typeText/sendKey/paste, resize/scroll/select, tab+window lifecycle, interrupt. | Phase 2 floor |
| `.clipboard` | Programmatic clipboard write (OSC 52 write only; read never implemented). | Phase 2/8 |
| `.fixture` | Headless determinism affordances; shipped GUI never grants it. | Phase 1 |

The policy is **generated from the catalog**, so a new intent is **denied by
default** until it is classified with a `requiredCapability`.

### 5.2 Transport hardening (the CDP/WebDriver lesson)

1. **Bind loopback only** — explicit `127.0.0.1`/`[::1]`, never `0.0.0.0`.
2. **Validate `Host` on every request** — reject anything not literally
   `localhost`/`127.0.0.1`/`[::1]` (defeats DNS-rebinding).
3. **Reject any request bearing an `Origin` header** — there is no browser
   client; an `Origin` means a web page is calling. (Phase 0 already does 1–3.)
4. **Token required; absence or mismatch ⇒ deny** (401), never a default-allow.
5. **Per-session token injected into child env** (`LABAN_CONTROL_TOKEN` +
   `LABAN_CONTROL_URL`) — an agent Laban itself spawned authenticates with zero
   prompt; an unrelated local process cannot read another process's env. The
   `labpty` wire already carries child `envp`, so this needs **no wire change**
   (does not touch the ADR 0007 freeze). **v1 ships a single app-scoped token;
   per-session injection is a confirmed-cheap Phase 8 add.**

### 5.3 Standing constraints

- **No in-band escape-sequence control channel.** Never write title/clipboard
  read-backs into the input stream; constrain DECRQSS/DSR replies (the
  CVE-2022-45872 class). Programmatic "type this" routes through the **same**
  validation a human keystroke does. Treat all agent/model/tool/repo bytes as
  untrusted before the VT parser.
- **High-power reads are privileged** — full keystroke stream and full scrollback
  dumps require `.observeSensitive`, never bare `.observe`; every
  `.control`/`.observeSensitive` access is logged to the EventLog.
- **User-visible "agent attached" indicator** whenever a `.control`-tier client is
  connected (the API is keylogger-equivalent).
- **No-auth dev mode** (CI only) is opt-in, scoped, and loud.

### 5.4 When the default flips on

Through Phase 0–1 the server is **off unless `LABAN_CONTROL_SERVER=1`**. The
**observe-on-by-default flip happens at the Phase 2 boundary**, once Host/Origin
validation, capability tiers, the app-scoped token, the `control.json`
advertisement, and the "agent attached" indicator all exist. Not before.

## 6. Phased roadmap

Tracer-bullet vertical slices. Every phase keeps CI green and the GUI unchanged
for humans. Each phase lists **scope**, **files**, **acceptance** (observable
behavior), and **status**.

### Phase 0 — Live control seam spike *(authoritative spec: `execplans/active/agent-first-phase0-control-seam.md`)*

- **Scope:** one query (`GET /debug/state`) + one control intent
  (`POST /debug/actions {"action":"selectTab","index":N}`) end-to-end through a
  minimal `ControlRouter` + `LabanControlServer` **hosted in the running
  `LabanApp` GUI**, against the live `AppModel`, behind `LABAN_CONTROL_SERVER=1`,
  with token + Host/Origin from the start.
- **Files:** `Sources/LabanApp/Control/{ControlRouter,LiveIntentRouter,LabanControlServer,ControlAdvertisement}.swift`; edits to `MainWindowController.swift` + `AppDelegate.swift`; `Tests/LabanAppTests/ControlServerPhase0Tests.swift`. *(Do not re-specify here; follow the active plan.)*
- **Acceptance:** `swift test --filter ControlServerPhase0Tests` passes (guard
  matrix + live select-tab + loopback round-trip); manual `curl` shows
  `activeTabId` change in the real window; default launches open no socket.
- **Status:** specified, **unexecuted**.

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
- **Status:** not started.

### Phase 2 — Mount live + security floor + flip the default

- **Scope:** `LiveIntentRouter` in `LabanApp`; re-point the `Debug*Endpoints`
  state/sessions/find/selection at the **live** `AppModel` + `AppSessionCoordinator`
  (not the headless mirror). Land the **security floor**: Host/Origin everywhere,
  single app-scoped token + child-env injection, `.observe`/`.observeSensitive`/
  `.control` tiers, `control.json`, "agent attached" indicator. Add the
  **catalog-parity test**. **Flip observe-on-by-default ON.**
- **Files:** `Sources/LabanApp/Control/LiveIntentRouter.swift` (expanded);
  `Sources/LabanControl/{LabanControlPolicy,*}`; `LabanDebug` `Debug*Endpoints`
  re-pointing; `Tests/.../CatalogParityTests.swift`; `MainWindowController`/
  `AppDelegate` mount edits.
- **Acceptance:** with the app running, an agent reads `control.json`, `curl`s
  live tab/session/grid/scrollback state and drives typeText/select/resize against
  the real window; missing token ⇒ 401, bad `Host`/any `Origin` ⇒ 403; a
  `.control` client lights the indicator; the catalog-parity test fails if either
  router omits a shared intent.
- **Status:** not started.

> Phases 3–5 are the **first-class product pillars** the live-control seam exists
> to enable. They are promoted ahead of MCP and the truthful-fixture work.

### Phase 3 — Event stream pillar

- **Scope:** promote the poll-cursor `/debug/events?since=N` into a **push stream**
  (SSE or long-poll) keyed to stable session/tab ids, with a typed event model
  (`window.*`, `tab.*`, `session.*`, `prompt`, `cwd`, `process`, `selection`,
  `viewport`, `frame.committed`, `intent.{requested,accepted,rejected}`,
  `screenshot`, `capture.*`). Back it with the always-on `EventLog`.
- **Files:** `Sources/LabanControl/EventStream*`; `Sources/LabanCore/Events/**`;
  `schemas/control/event*.json`; subscription endpoint in the HTTP adapter.
- **Acceptance:** a client subscribes, types a command via `terminal.typeText`,
  and receives ordered `prompt`/`process`/`frame.committed` events without
  polling; events replay from `EventLog` via `event.getSince`.
- **Status:** not started.

### Phase 4 — Semantic command blocks pillar

- **Scope:** a first-class **`CommandBlock`** model in `LabanCore`, synthesized
  from OSC 133 transitions (`atPrompt`→`running`→`finished`) + `completedCommandCount`
  + OSC 7 cwd + `lastExitCode` + output byte/screen ranges. Heuristic fallback
  when shell integration is absent, **marked low-confidence**. Expose
  `commandBlock.list/get`, link blocks to output ranges and (when available)
  screenshots/hashes.
- **Files:** `Sources/LabanCore/CommandBlocks/**`; catalog entries +
  `schemas/control/command-block*.json`; serializers in the HTTP adapter.
- **Acceptance:** after running `swift test` in a tab, `commandBlock.list` returns
  a block with command text, cwd, exit status, time span, and output range; a
  block with no OSC 133 evidence is flagged `confidence: heuristic`.
- **Status:** not started.

### Phase 5 — Trace/replay pillar

- **Scope:** elevate the existing `CaptureRecorder` (already used in `LabanApp`)
  into a first-class, agent-exportable **trace bundle**: PTY in/out/response
  bytes, user actions, **intent requests + results**, command blocks, window/tab/
  session metadata, resize events, screenshots/frame hashes, redaction report,
  build metadata. Add `trace.start/stop/export` intents and CI replay.
- **Files:** `Sources/LabanDebug/CaptureRecorder*` (extend);
  `Sources/LabanControl` trace intents; `schemas/capture/*` extensions;
  `scripts/replay-capture` coverage of intent events.
- **Acceptance:** after a session, `trace.export` writes a bundle whose
  `replay/report.json` shows `terminalReplay: passed`, and the bundle contains the
  intent timeline + command blocks + redaction report.
- **Status:** not started.

### Phase 6 — MCP front door *(generated from the catalog)*

- **Scope:** an in-house MCP server with tool shapes **generated from
  `IntentCatalog`** (descriptions hand-curated), as an out-of-process wrapper over
  the same HTTP/Intent surface. Read-only tools first, then `.control` tools
  behind explicit scopes. Publish the HTTP+schema contract too. Begin
  Claude-in-Laban dogfooding. *(MCP needs only the catalog + Phase 2 floor; it may
  be pulled forward for dogfooding once those exist.)*
- **Acceptance:** a generated MCP tool list matches the catalog 1:1; a read-only
  MCP client orients (tabs/active/last command block) and a scoped client drives
  typeText, with every call audited.
- **Status:** not started.

### Phase 7 — Truthful-fixture pillar (view-layer work)

- **Scope:** wire `MetalReadback` so `screenshot`/`pixel-probe`/`frame-commands`
  are **GUI-truthful** (decide `captureMode` synchronous vs async/queued readback
  — the perf tradeoff). Promote selection/cursor/find to first-class
  live-queryable state via new AppKit-view accessors (today only the headless
  mirror has them).
- **Acceptance:** a GUI screenshot/pixel-probe reflects the Metal output a human
  sees; `terminal.getSelection` returns the real AppKit selection.
- **Status:** not started.

### Phase 8 — Safety broker + reach

- **Scope:** the **policy/approval broker** (distinct from the Phase 2 floor):
  risk classification of command content (`rm -rf`, `git push --force`),
  approval-required actions + approval UI, clipboard/paste/secret policies, audit
  browser/export. Per-session token scoping (cheap — `envp` already in the wire).
  New-capability intents with no current counterpart: theme, font, restore toggle,
  backend switch, **restart**, tab reorder, hyperlink open; GUI capture control.
- **Acceptance:** a `.control` client's `rm -rf`-class command raises an approval
  the user must grant; per-session tokens scope a client to one tab; the audit
  browser lists every control-tier action.
- **Status:** not started.

## 7. Acceptance criteria (consolidated)

The program as a whole succeeds when, against the **running `LabanApp` GUI**:

1. A local client discovers the app via `control.json`, authenticates with a
   token, and is denied without one (401) or with a forged `Host`/any `Origin`
   (403).
2. The client reads live windows/tabs/sessions/grid/scrollback/process/prompt
   state keyed off stable ids, and drives typeText/sendKey/select/resize against
   the real window — all typed, capability-scoped, and audited.
3. Waits replace sleeps; events stream without polling.
4. Command blocks, trace export, and MCP tools all derive from the **one** catalog
   with no duplicated definitions.
5. The catalog-parity test makes GUI/headless drift a CI failure.
6. A human sees and can disable what external clients may do.

Per-phase acceptance is in §6 (each is observable behavior, not an internal
attribute).

## 8. Open questions (genuinely remaining)

These are *not* resolved; the resolved-8 from v1 are recorded in Appendix B.

1. **Intent-id migration window.** How long does the HTTP adapter accept both the
   bare Phase 0 action names and the dotted catalog ids before the bare forms are
   removed? (Affects when Phase 0 clients must update.)
2. **Event-stream transport.** SSE vs HTTP long-poll for Phase 3 — SSE is simpler
   for browsers (which we forbid) and adds a streaming code path; long-poll reuses
   the existing request model. Pick at Phase 3 start.
3. **Metal readback cost (Phase 7).** Is a synchronous drawable readback
   acceptable for `screenshot`/`pixel-probe` latency, or is an async/queued
   capture required? Decides the Phase 7 API shape.
4. **Command-block heuristic fidelity (Phase 4).** Without OSC 133, how aggressive
   should prompt-boundary heuristics be, and exactly what `confidence` taxonomy
   does the schema expose?
5. **MCP timing.** Hold MCP at Phase 6, or pull it forward for dogfooding the
   moment the Phase 2 floor + catalog exist? (It is only a generated wrapper.)
6. **Per-session token rollout (Phase 8).** Single app-scoped token is the v1
   floor; confirm per-session env-injection is deferred to Phase 8 and not pulled
   earlier by a multi-agent use case.
7. **UDS transport.** Keep loopback-HTTP-only, or add a Unix-domain-socket
   transport if a concrete consumer needs filesystem-permission gating?

## 9. Non-goals

- A chatbot or agent model inside the terminal. This is **substrate** for external
  agents (Claude Code, Codex, scripts, tests), not an embedded agent.
- A replacement for shell integration, a screen-scraping API, a remote-desktop
  protocol, or an unauthenticated debug server.
- Network/remote access, multi-user/team features, or any non-loopback binding.
- MCP-first: MCP is a generated wrapper over a stable HTTP/Intent contract, built
  after the catalog and security floor — never the primitive.
- Re-litigating the resolved decisions in Appendix B without new evidence.

---

## Appendix A — Comparator lessons (historical rationale)

*(Preserved from v1 §4 for the "why." Nothing in §1–9 requires reading this.)*
Key takeaways that shaped the body: **one state authority, many thin clients**
(tmux/wezterm `Mux`; wezterm GUI and `wezterm cli` are both mux clients with no
separate debug binary) — the direct refutation of the `LabanApp`/`LabanAgent`
split; **stable ids, never indices** (tmux `$/@/%`, kitty `--match`, wezterm
`pane_id`); **two read primitives** (rendered grid for assertions vs raw bytes for
fidelity — tmux `capture-pane` vs `%output`); **typed input fidelity** (iTerm2
`async_send_text` vs `async_inject`; first-class control-char injection for
Ctrl-C); **push, not poll** (iTerm2 notifications; wezterm's missing event stream
is its cited weakness); **semantic command framing from OSC 133/633** (VS Code,
Warp blocks); **one canonical versioned surface** (iTerm2 deprecating AppleScript
for the typed protobuf API). Security consensus: **default-deny, loopback-only,
token-authed, fail closed** (iTerm2 `ITERM2_COOKIE` + per-app consent; kitty
password tiers; ttyd read-only-until-`--writable`); **loopback is necessary but
not sufficient** — Host + Origin validation defeat DNS-rebinding (CDP/WebDriver
lesson); **escape-sequence control is a severe trust boundary** (iTerm2
CVE-2022-45872; OSC 52 read universally refused). Verifier caveat: cite iTerm2's
**cookie + per-app-consent** as the security precedent, **not** its
socket-vs-TCP transport choice (its source labels the unix path "Experimental").

## Appendix B — Resolved decisions (grilling 2026-05-30) and v2 deltas

The eight v1 questions were resolved during a 2026-05-30 grilling; v2 keeps all
eight and records what changed since:

1. v1 scope = relocation-MVP (drive + read). **Kept.**
2. Three-way target split; registry in `LabanCore`. **Kept; v2 fixes the v1 §5.3
   vs §0.2 contradiction by placing the *server* in `LabanControl`, not
   `LabanCore`** (§3.1).
3. Token-gated observe-on-by-default, flipped at the Phase 2 boundary. **Kept** (§5.4).
4. Single app-scoped token + env-injection in v1; per-session deferred. **Kept**
   (now Phase 8, §6).
5. Two catalogs; `feedOutput`/`advanceFrames` barred from live. **Kept** (§4.3).
6. Lean parity via the catalog-parity test; `HeadlessDebugRuntime` kept. **Kept** (§3.1).
7. Governance gate (spec + ADRs) before Phase 1. **Kept; ADR numbers corrected
   0012/0013 → 0023/0024** (the index has since reached 0022).
8. MCP in-house, generated + curated. **Kept, but re-sequenced:** v2 promotes the
   **event stream, command blocks, and trace/replay to first-class pillars
   (Phases 3–5) ahead of MCP (Phase 6)** and the truthful-fixture work (Phase 7),
   per the v2 mandate. v1 had MCP at Phase 3 and these pillars buried at Phase 5.

**Stale-fact corrections folded into the body:** ADR numbering (0023/0024);
`control.json` has no `laband` collision (the daemon's `control-json` is a
transport-mode label); `MetalReadback.swift` confirmed present.

## Appendix C — Verified surface inventory (2026-06-20)

`DebugHTTPServer` (`Sources/LabanDebug/DebugHTTPServer.swift`, ~40 routes,
loopback + bearer token + port 0) is instantiated **only** by
`HeadlessDebugRuntime` (`LabanDebug` → `LabanAgent`); `LabanApp` never constructs
it (links `LabanDebug` for `CaptureRecorder` only). `AppModel`/
`TerminalSessionClient` are AppKit-free in `LabanCore`; `AppSessionCoordinator`
is the GUI funnel in `LabanApp`. `MetalReadback.swift` (`captureMode`, `pngData`)
exists in `LabanRenderer`. OSC 133 (`ShellIntegrationState`), OSC 7 cwd (ADR
0015), OSC 52 write (ADR 0014) exist; no command-block object yet. EventLog JSONL
(`~/Library/Application Support/Laban/events/`) is the only surface that already
behaves like the vision against the real app (always-on, read-only). No
`LabanControlServer`/`IntentRouter`/`IntentCatalog`/`LabanControl` target exists
in `Sources/` as of this date.
