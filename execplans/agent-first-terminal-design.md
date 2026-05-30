# Laban Agent-Control Surface: Decision-Grade Design

**Author:** Chief Architect · **Date:** 2026-05-29 (resolved 2026-05-30) · **Status:** Decided — Phase 0 ready

> Vision restated: *every visible part of the running app is queryable and controllable over a loopback HTTP server; it behaves like a normal terminal for humans and a deterministic test fixture for agents/CI.* The verified central finding: that surface exists and is rich — but it lives in `LabanAgent` (headless), not in `LabanApp` (the GUI users run). The work ahead is **relocation and unification, not invention.**

---

## 0. Resolved decisions (grilling, 2026-05-30) — authoritative; supersedes conflicting detail below

**Fact corrections found while grilling (the body still reflects the pre-grill view in places):**

- **Metal-truthful frames are NOT net-new.** `Sources/LabanRenderer/MetalReadback.swift` already exists (`captureMode`, drawable→CPU blit, `MetalRenderer.pngData`). The work is *wiring it to the server + managing `captureMode`'s per-frame blit cost*, not building readback.
- **The `labpty` wire already carries child `envp`** (`LABPTY_OP_OPEN_SESSION` → `read_envp_array` → `laban_pty_open(..., envp, ...)`). Per-session token env-injection needs **no wire change**, so it does not collide with the ADR-0007 freeze.
- **`AppModel` already lives in `LabanCore` and is AppKit-free** — `HeadlessDebugRuntime` shares it, so there is no "private model" to retire; only the renderer backend (Software/offscreen vs Metal/window) diverges.
- **`LabanApp` already links `LabanDebug`** (for `CaptureRecorder`); hosting a server in the GUI needs instantiation, not a new dependency.
- **ADR 0011 is taken** (alt-screen primary-pen). New ADRs are **0012** (architecture) + **0013** (security).

**Decisions:**

1. **v1 scope = relocation-MVP:** drive + read text/grid/scrollback/process/events. **Selection/cursor/find promotion + Metal-truthful frames are a separate, explicitly-sequenced later pillar** (they touch the AppKit view layer and carry a `captureMode` cost) — not buried inside "move the server."
2. **Three-way target split:** registry types (`Intent`/`Query`/`IntentResult`/`Capability`/`IntentCatalog`/`IntentRouter` protocol) → **`LabanCore`** (no HTTP, no AppKit). `LabanControlServer` + `LabanControlPolicy` + HTTP↔Intent adapter → **new `LabanControl`** target. `HeadlessDebugRuntime` + fixtures + `HeadlessIntentRouter` → stay in **`LabanDebug`**. `LabanApp` and `LabanDebug` both depend on `LabanControl` and mount the same server.
3. **Security posture = token-gated observe-on-by-default.** Server listens by default, but observe requires the token (written to `$runDir/control.json`, mode 0600, env-discoverable). Zero-setup for agents Laban spawned; closed to unauthorized local processes. **Capability tiers `.observe` / `.observeSensitive` (scrollback, process cwd/command, input log, clipboard) / `.control` land in v1.** Host/Origin validation + token are **pulled into Phase 0**.
4. **Token model = single app-scoped token + env-injection in v1.** Per-session scoping deferred (confirmed cheap later — no wire change).
5. **Two catalogs.** Shared `IntentCatalog` (implemented by both routers) = cross-surface user ops. Headless-only `FixtureActionCatalog` (`feedOutput`, `advanceFrames`, `windowFocus`, title-forcing) gated behind a `.fixture` capability the shipped GUI never grants — **`feedOutput`/`advanceFrames` are barred from the live surface** (byte-injection / no-op-live). Relative tab-nav folds into `selectTab(relative:)`.
6. **Lean parity.** Two thin assemblers (`makeAndShow`, `HeadlessDebugRuntime`) each build {shared `AppModel`, their renderer backend, their `IntentRouter`} and mount the **same** `LabanControlServer`; a **catalog-parity test** (enumerate `IntentCatalog`, assert both routers implement every intent) makes drift a CI failure. `HeadlessDebugRuntime` is kept. The AGENTS.md "wire both by hand" hard-rule is replaced by "both mount the shared server + pass the catalog-parity test." No full `AppHost` refactor of `makeAndShow`.
7. **Governance gate.** Before Phase 1 lands: `docs/product/spec.md` entry + **ADR 0012** (LabanApp hosts the loopback control+query server; three-way split; lean parity) + **ADR 0013** (security model). **observe-on-by-default flips ON at the Phase-2 boundary** (when Host/Origin + token + tiers + `control.json` exist); env-gated (`LABAN_CONTROL_SERVER=1`) through Phase 0–1. Verify no `docs/product/mvp.md` regression when writing the ADRs.
8. **MCP = in-house, generated from the catalog** (tool shapes generated, descriptions hand-curated), **pulled to just after the Phase-2 security floor** for early Claude-in-Laban dogfooding. Publish the generated HTTP+schema contract too.

See **§7** for the revised phase plan reflecting these.

---

## 1. Surface inventory

Legend: **Q** = queryable, **C** = controllable, **Agent today?** = reachable by an agent against the running GUI (`LabanApp`) over a Laban-provided channel.

| Surface | What it exposes | Binary | Q | C | Agent today? |
|---|---|---|---|---|---|
| GUI human controls (new/close/select tab, copy, paste, find, scroll, select, mouse-forward, hyperlink, keystroke, drop, export-cast, capture-toggle) | The full human terminal control vocabulary | LabanApp | partial | yes | **no** |
| GUI settings (theme, font, restore-on-launch, backend switch, restart, quit, updates/about/diagnostics, tab reorder, titlebar zoom) | App configuration + window mgmt | LabanApp | no | yes | **no** (some via launch-time `UserDefaults`/env only) |
| `executeAppCommand` / `AppCommand` / `TerminalKeyDescriptor.route` | Single choke point for keyboard-driven app commands | LabanApp | no | yes | no (in-process only) |
| `AppSessionCoordinator` | Tier-agnostic funnel: write/resize/scroll/markRendered/terminate/snapshot/attachRing | LabanApp | yes | yes | no (driven only by AppKit handlers) |
| `DebugHTTPServer` + `Debug*Endpoints` (~40 routes) | state, sessions(+grid), screenshot, render/atlas/pixel-probe/frame-commands/render-trace, actions, wait, find, selection, clipboard, capture, cast, persistence, events, input-log, terminal-log, timing, metrics, errors, snapshot, fixture, discovery, health | **LabanAgent only** | yes | yes | **no** (never instantiated in LabanApp) |
| `HeadlessDebugRuntime` | Backing model for the server: own `AppModel`+`SoftwareRenderer`+`BitmapSurface` | LabanDebug→LabanAgent | yes | yes | no (separate in-memory model, not the live GUI) |
| Bearer-token auth + loopback bind + stdout readiness line | 32-byte hex token, constant-time compare, 127.0.0.1, port 0 → getsockname, readiness JSON to stdout | LabanAgent | — | — | no (token only emitted by agent it launches) |
| `Session` accessors (snapshot grid, viewportState, scrollback, processMetadata, shell-integration/OSC133, selection text) | In-process terminal state over the C ABI | LabanCore | yes | partial | no (HTTP exposure only via agent) |
| `TerminalSessionClient` protocol (inProcess / labpty / laband) | Uniform seam: create/list/attach/write/resize/snapshot/scroll/terminate/transferLease | LabanCore | yes | yes | no (Swift API only) |
| labpty daemon (`LPCT` framed RPC, byte ring) | PTY custody, frozen Phase-1 wire (ADR 0007/0010) | labpty (C) | yes | yes | no (binary socket, no agent client) |
| laband daemon RPC | VT serving, snapshot ring, leases, theme, scroll | laband (Swift) | yes | yes | no (internal IPC) |
| `schemas/debug/*` (32 JSON Schemas) + discovery doc | Route↔schema↔doc contract, `check-debug-contract` gate | repo / served by agent | yes | — | no (served only by agent) |
| Capture/replay (`CaptureRecorder`, asciicast, `manifest`/`event`/`replay-report` schemas) | Durable repro artifacts + deterministic replay | **LabanApp writes** + LabanDebug replays | yes | partial | **yes** (file-based, after human/env trigger) |
| EventLog JSONL (`~/Library/Application Support/Laban/events/`) | Append-only event stream, 7-day retention | LabanApp | yes | no | **yes** (read-only, zero setup) |
| Frame/resize probes (`*-probe.ndjson`) | Per-frame glyph/cursor/geometry + on-screen PNGs | LabanApp | yes | no | **yes** (only if env set at launch) |
| Fixture / debug-script harness, `test-e2e`, `run-debug-script`, `smoke-runtime`, `check` | Deterministic CI gates | LabanAgent (+ smoke touches app) | yes | yes | yes (against agent, not GUI window) |
| labpty/laband wire contract (C headers + TLA+ + CBMC + ADRs) | Safety-critical typed boundary | labpty/laband | — | — | no (not in `schemas/`, not on HTTP) |

**The one-line truth:** every human control surface is in `LabanApp`; the entire query+control plane is in `LabanAgent`. The only Laban-provided channels into the *running GUI* today are read-only files (EventLog always; probes/capture conditionally).

---

## 2. Earns-its-keep verdict

Distinguish **redundant capability** (two ways to do the same user-meaningful thing) from **redundant plumbing** (two construction paths for the same subsystem). Laban has almost no redundant capability; it has one structurally-forked piece of plumbing (`HeadlessDebugRuntime` vs `makeAndShow`).

| Surface | Verdict | Why |
|---|---|---|
| `DebugHTTPServer` + `Debug*Endpoints` route family | **keep, relocate into LabanApp** | The actual agent plane. Misplaced, not redundant. |
| `HeadlessDebugRuntime` (its own AppModel/SoftwareRenderer) | **fold into a shared host** | Redundant *plumbing*: a second construction of subsystems that drift from `makeAndShow`. Capability is needed; the parallel model is not. |
| `POST /debug/actions` + `POST /debug/wait` | **keep — migrate first** | Control + deterministic-sync core; the heart of "deterministic test fixture." |
| Bearer-token + loopback bind | **keep model** | Sound minimum. Constant-time compare, 127.0.0.1. |
| stdout readiness discovery | **retire for GUI, replace with a port/token file** | A line the agent prints only works for a process the agent launched. A long-lived GUI needs an on-disk advertisement. |
| `Session` / `TerminalSessionClient` / `AppSessionCoordinator` seam | **keep** | Tier-agnostic choke point; the natural attach point for a GUI-hosted server. Zero redundancy. |
| labpty + laband daemons | **keep** | Architectural floor (ADR 0006/0007/0010). Control layers *above* them. |
| Render/pixel diagnostics (render, atlas, pixel-probe, frame-commands, render-trace, screenshot) | **keep, needs Metal readback** | Valuable but currently reflect `SoftwareRenderer`, not the GUI's Metal output. Capability kept; GUI-truthfulness is new work. |
| Capture/replay + `CaptureRecorder` GUI use | **keep — already the bridge** | The one LabanDebug component the GUI hosts in-process. Proof the relocation is mechanically possible. |
| EventLog JSONL | **keep** | The only surface that already behaves like the vision against the real app. |
| Frame/resize probes | **keep, weak** | Real render-path observation, but launch-time-gated and write-only. |
| `schemas/debug/*` + `check-debug-contract` | **keep** | The rigor the vision wants. Re-home with the server. |
| labpty/laband wire contract | **keep, bridge into discovery** | Heavily verified but invisible to the agent-facing surface. |
| `render-test` / `render-torture` | **retire from the "agent surface" framing** | Exit-0 stimulus generators, no assertions, not in `check`. Keep as manual aids only. |

---

## 3. Gap analysis vs the vision

The vision says *the GUI app is the fixture*. Verified, the following is **NOT** queryable/controllable over loopback HTTP **from `LabanApp`** today (it is, from `LabanAgent`):

1. **The entire `/debug/*` surface.** `LabanApp` never instantiates `DebugHTTPServer` or `HeadlessDebugRuntime` (grep-confirmed). It links `LabanDebug` solely for `CaptureRecorder`. There is no loopback listener of any kind in the GUI.
2. **Live session/render state.** `Session.snapshot/viewportState/scrollback/processMetadata/shellIntegrationState` are clean in-process accessors, but their only out-of-process exposure is the agent's HTTP layer against the agent's *separate* `AppModel`. Even if the server moved into `LabanApp`, the runtime must be **re-pointed at the live coordinator and model**, not a private headless one.
3. **Render/pixel truth.** All pixel/render endpoints reflect `SoftwareRenderer`/`BitmapSurface`. The GUI renders via `MetalRenderer`. Without a Metal drawable readback, `screenshot`/`pixel-probe`/`render` would not represent what the user sees. (`MetalRenderer.captureMode` already exists for `CaptureRecorder` — the hook is there.)
4. **Selection / find UI state.** These live in `HeadlessDebugRuntime.selectionBySession` / `model.allFindStates` — the *headless mirror*. The GUI's real selection lives in the AppKit view layer with **no out-of-process accessor at all**.
5. **On-demand screenshot.** No GUI equivalent of `GET /debug/screenshot`. GUI PNGs appear only as a side effect of capture mode or the resize probe.
6. **Discovery + token.** No port file, no fixed port, no GUI-side advertisement, no token surfaced by the GUI. An agent that didn't launch the process cannot find the URL or authenticate.
7. **Settings/window capabilities with no agent counterpart anywhere:** theme, font, restore-on-launch toggle, backend switch, restart, tab reorder, hyperlink open. These need *new* intents, not relocation.
8. **Parity is unenforced.** `AGENTS.md` mandates `HeadlessDebugRuntime` ≡ `makeAndShow`, but no test checks it; the two construction paths are hand-duplicated and drift silently (named explicitly in `docs/quality/architecture-deepening-candidates.md`).

What an agent *can* reach against the running GUI today: EventLog JSONL (always), frame/resize probes (if env set at launch), capture/cast artifacts (after a human/env trigger). All file-based, all read-only, none query-by-request, none control.

---

## 4. Comparator lessons

**Architecture — the split Laban has is the one every mature product avoids.**
- **tmux / wezterm:** one state authority (the server / the `Mux`), many client types (human frontend *and* programmatic client) attach to the **same** state over the **same** transport. iTerm2 renders tmux windows natively while tmux owns PTYs. wezterm's GUI and `wezterm cli` are both mux clients — *there is no separate debug binary*. This is the direct refutation of `LabanApp`/`LabanAgent`: put the control surface in the process that owns the real tabs/PTYs/render state.
- **iTerm2 / kitty / VS Code:** the scripting API is built into the one binary users run, gated by config. kitty proves a single binary is simultaneously "normal terminal for humans" and "scriptable fixture."

**API shape to adopt.**
- **Stable IDs, never indices** (tmux `$/@/%`, kitty `--match`, wezterm `pane_id`). Aligns with Laban's hard rule that session identity survives tab churn. Key everything off `sessionId`/`tabId`.
- **Two distinct read primitives:** rendered grid (deterministic assertion) **and** raw pre-render bytes (fidelity/replay). tmux deliberately separates `%output` (verbatim bytes) from `capture-pane` (rendered). Laban already has both halves (`terminal-log` vs snapshot grid) — keep them distinct.
- **Read/write symmetry & input fidelity:** iTerm2 distinguishes `async_send_text` (type into PTY) from `async_inject` (write into screen); wezterm `send-text --no-paste` distinguishes typed vs pasted. Laban must keep "type into PTY" separate from "feed output," and expose control-char injection as first-class (iterm-mcp's `send_control_character` so an agent can Ctrl-C a runaway).
- **Push, not poll:** every rich product has a change stream (iTerm2 notifications, tmux `%`-notifications + format subscriptions). wezterm's *omission* of an external event stream is cited as its weakness. Laban's "queryable event log" should become an SSE/long-poll feed keyed to the same IDs — Laban already has `EventLog` and `GET /debug/events`; expose it as a stream.
- **Semantic command framing:** VS Code's power derives entirely from OSC 633/133 markers (prompt/command/exit/cwd). Laband already parses OSC 133 (`shell-integration/state`). Surface a Warp-Block-equivalent: addressable record per command (text, output range, exit code, cwd, timestamps).
- **Don't ship a second drifting interface:** iTerm2 deprecated AppleScript for the typed protobuf API. Laban already has `schemas/` — make it the single canonical, versioned, ADR-governed surface.

**Security model — the consensus, and what verifiers refuted.**
- **Default-deny, loopback-only, token-authed.** iTerm2: disabled by default, Unix socket, 128-bit `ITERM2_COOKIE`, OS-mediated per-app consent. kitty: off by default; `socket-only`/`password` tiers; per-command `is_cmd_allowed()`.
- **Loopback bind is necessary but NOT sufficient.** CDP/WebDriver: any web page can POST to 127.0.0.1. Required defenses: explicit 127.0.0.1 bind (never 0.0.0.0), strict **Host-header** validation (defeats `127.0.0.1.xip.io` DNS rebinding), **Origin-header** validation on every request and WS upgrade. Safari WebDriver was judged most resilient precisely because it checks both.
- **Split observe from control.** ttyd is read-only until `--writable`. kitty scopes passwords to action lists. A low-trust observer must not be able to drive the terminal.
- **Auth must fail closed.** ttyd's 2017 RCE: a message missing `AuthToken` set `authenticated = true`. CVE-2021-34182: insecure-default RCE. Absence of credential must **deny**.
- **The agent API is a keylogger/exfiltration surface.** A granted iTerm2 client can stream every keystroke and dump every buffer. Gate full keystroke stream / full scrollback dump behind the strongest tier; consider a user-visible "agent attached" indicator.
- **Escape-sequence control is a distinct, severe trust boundary.** iTerm2 CVE-2022-45872 (CVSS 9.8, a DECRQSS reprise of the 2008 xterm bug): query responses (DECRQSS/DSR/title read-back) get written into the PTY *as if typed* and executed by the shell — "as egregious as string-concatenating SQL." OSC 52 clipboard *read* is universally refused; *write* is gated (Windows Terminal `allowClipboardSharing`). Codex CLI: unsanitized `--model`/branch-name/repo-config reflected into the terminal → RCE. **Lesson: do NOT add an in-band escape-sequence control channel; treat all agent/model/tool/repo bytes as untrusted before they reach the VT parser.**

**Claims the verifiers refuted / qualified (so we don't over-rely on them):**
- iTerm2 connection.py uses a Unix socket **by existence-based fallback**, *not* an explicit "default for security" — the source labels the unix path "Experimental," TCP "Legacy," and contains no security rationale for the transport choice. The only documented security rationale is the **cookie/key handshake**, not the socket selection. Takeaway: justify Laban's transport choice on its own merits; don't cite iTerm2's transport as a security precedent — cite its *cookie + per-app-consent* model.
- Everything else (OSC 1337/133 verbs, the Python API request types, notification set, keystroke fields, the auth/override-file model) was verified **supported, high confidence**.

---

## 5. Unified architecture

**One state authority, many thin adapters.** Adopt the tmux/wezterm model: the process that owns the live tabs/PTYs/render state *is* the queryable fixture. For Laban that is `LabanApp`, fronting `AppSessionCoordinator`.

### 5.1 The intent/capability registry (LabanCore)

Introduce a single, AppKit-free registry in `LabanCore`. Every user-meaningful action becomes a typed **Intent**; every read becomes a typed **Query**. Concrete types:

```
LabanCore/Intents/
  Intent                      // enum/struct: tagged, Codable, schema-backed
  IntentResult                // { ok, frame, activeTabId, activeSessionId, error }
  Query                       // tagged Codable read request
  QueryResult                 // Codable read response
  Capability                  // .observe | .control | .clipboard | .escapeControl ...
  IntentCatalog               // [IntentDescriptor]: name, capability, requestSchema, responseSchema
  IntentRouter (protocol)     // route(Intent) -> IntentResult ; query(Query) -> QueryResult
```

`Intent` is the union of today's `AppCommand` cases *plus* the `DebugAction` cases — they describe the same operations (newTab, closeTab, selectTab, copy, paste, find.start/step/stop, scrollViewport, key, typeText, setSelection, mouseWheel, click, resize). Each carries a `Capability`. The `IntentCatalog` is the single source of truth from which discovery, schemas, and the security policy are **generated**, not hand-maintained.

### 5.2 Adapters (thin, emit the same intents)

- **GUI menus / key routes / mouse** → `executeAppCommand` becomes a thin adapter that constructs an `Intent` and hands it to the router. (`executeAppCommand` already funnels keyboard commands to the same core methods — this is a low-risk refactor, not a rewrite.)
- **Debug HTTP** → an adapter that decodes a request body into an `Intent`/`Query` and routes it.
- **Future agent transport (MCP)** → a wrapper that translates MCP tool calls into the same `Intent`/`Query`. Not a parallel implementation.

All adapters terminate at one `IntentRouter` implementation backed by `AppSessionCoordinator` + the live `AppModel`. Tier-agnostic by construction (the router calls `TerminalSessionClient`, which works for inProcess/labpty/laband).

### 5.3 The loopback server, hosted IN LabanApp

New type `LabanControlServer` in `LabanCore` (transport + auth + Host/Origin + routing; no AppKit). It is **mounted by both** `MainWindowController.makeAndShow` *and* `HeadlessDebugRuntime`, against the same `IntentRouter` interface. This makes parity **structural**: there is one server, one router, one catalog; the headless runtime becomes "the same host with no window," not a divergent superset.

```
LabanCore:   IntentRouter, IntentCatalog, LabanControlServer, LabanControlPolicy
LabanApp:    LiveIntentRouter (AppSessionCoordinator + AppModel + Metal readback)  -> mounts LabanControlServer
LabanDebug:  HeadlessIntentRouter (HeadlessDebugRuntime)                            -> mounts LabanControlServer
```

`DebugHTTPServer`'s route table is reframed as the **HTTP adapter** over `IntentRouter`; the existing `Debug*Endpoints` become serializers. Render/pixel/screenshot endpoints in `LabanApp` resolve through a **Metal readback** path (reusing the `MetalRenderer.captureMode` hook); in `LabanDebug` they resolve through `SoftwareRenderer` as today.

### 5.4 Discovery, generated from the registry

`GET /debug` (and `/debug/capabilities`) is **generated** from `IntentCatalog` + `Query` catalog, so the discovery doc, the 32 JSON schemas, and `check-debug-contract` cannot drift from the implementation — adding an intent regenerates discovery and fails the contract gate until a schema exists.

### 5.5 Agent transport choice: raw loopback HTTP + token **now**, MCP wrapper **later**

Make the primitive layer raw loopback HTTP + token (it already exists, it's schema-backed, CI exercises it, and it's debuggable with `curl`). Provide MCP **as a thin out-of-process wrapper** that calls the same HTTP/Intent surface — this matches the surveyed MCP ecosystem (it2mcp/iterm-mcp wrap an existing API rather than being the API) and keeps one canonical, versioned contract per iTerm2's AppleScript lesson. Do **not** make MCP the primitive; do not build two surfaces.

### 5.6 Discovery transport for a long-lived GUI

Replace the stdout readiness line with a **token/port file** under the per-worktree run dir (per `worktree-isolation.md`), mode `0600`, containing `{ url, token, pid, runId }`. The GUI writes it on server start, removes it on quit. Agents read it; no process-launch coupling.

---

## 6. Security model

**Posture: default observe-only, control opt-in, fail closed.** Reuse the existing `debugToken` pattern (32-byte hex, constant-time compare) verbatim; harden the transport and split capabilities.

1. **Bind loopback only.** Explicit `127.0.0.1`/`::1`, never `0.0.0.0`. Keep `nonLoopbackHost` rejection.
2. **Host + Origin validation on every request and WS upgrade.** Reject any `Host` that is not literally `localhost`/`127.0.0.1`/`[::1]` (defeats DNS-rebinding); reject browser cross-origin `Origin`. This is the CDP/WebDriver lesson and is the single most important addition over today's loopback-only stance.
3. **Per-session capability token injected into child env.** On session create, mint a per-session token and inject it into the child process environment (`LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL`), exactly mirroring iTerm2's `ITERM2_COOKIE`-into-launched-scripts model. A child (an agent Laban itself spawned) can authenticate with no prompt; an unrelated local process cannot read the env and is denied.
4. **Capability scoping, fail-closed.** `LabanControlPolicy` maps each `Intent`/`Query` to a required `Capability`. The token grants a capability set. `.observe` (read state/grid/scrollback/events) is separable from `.control` (write/resize/select/scroll/tab) and from `.clipboard`. Missing or unknown capability → `401`/`403`, never grant. The catalog-generated policy means a new intent is **denied by default** until explicitly classified.
5. **High-power reads are privileged.** Full keystroke/input-log stream and full scrollback dump require `.control`-tier (or a dedicated `.audit`) capability, never bare `.observe`. Log every control-tier access to the EventLog.
6. **Escape-sequence control: defer unless nonce-authed.** Do **not** implement an in-band escape-sequence control channel. Never write title/clipboard read-back into the input stream; constrain/disable DECRQSS/DSR replies (CVE-2022-45872 class). Treat all agent/model/tool/repo bytes as untrusted: programmatic "type this" routes through the *same* validation a human keystroke does. If shell-integration command attribution (OSC 633/133) is ever surfaced as authoritative, require a per-session **nonce** on the command-line marker (VS Code's defense) before trusting it; otherwise label it unverified.
7. **OSC 52:** clipboard *write* only behind an explicit off-by-default permission; never implement clipboard *read*.
8. **No-auth dev mode** (for CI) is opt-in, scoped, loud, and obviously off in normal use (kitty's admin-override lesson).
9. **User-visible "agent attached" indicator** when a control-tier client is connected, since the API is a keylogger-equivalent surface.

---

## 7. Concrete path forward

Tracer-bullet, vertical slices. Every phase keeps all surfaces alive (CI green, GUI unchanged for humans). **Revised per §0 resolutions.**

- **Phase 0 — Spike the seam (env-gated; FULLY SPECIFIED BELOW).** One query (`state`) + one control intent (`selectTab`), end-to-end, through a minimal registry + `LabanControlServer` hosted in `LabanApp`, against the live coordinator, behind `LABAN_CONTROL_SERVER=1`. Includes token + Host/Origin from the start. Proves relocation + Metal-free state path + auth.
- **Governance gate** — write `docs/product/spec.md` entry + **ADR 0012** (architecture) + **ADR 0013** (security); verify no `mvp.md` regression. *Lands before Phase 1.*
- **Phase 1 — Registry backbone + carve `LabanControl`.** Extract `Intent`/`Query`/`IntentResult`/`Capability`/`IntentCatalog`/`IntentRouter` into `LabanCore`; define the **two catalogs** (shared `IntentCatalog` + headless-only `FixtureActionCatalog`, with `feedOutput`/`advanceFrames` barred from live). Carve `DebugHTTPServer`/`Debug*Endpoints` out of `LabanDebug` into the new **`LabanControl`** target as the HTTP↔Intent adapter. `executeAppCommand` and the HTTP adapter both emit intents. Generate discovery + schemas from the catalog.
- **Phase 2 — Mount the live server + security floor + flip the default.** `LiveIntentRouter` in `LabanApp`; re-point `Debug*Endpoints` state/sessions/find/selection at the live `AppModel` + `AppSessionCoordinator`. Write `$runDir/control.json` (token/port). Land the security floor: Host/Origin everywhere, single app-scoped token + env-injection, `.observe`/`.observeSensitive`/`.control` tiers, "agent attached" indicator. Add the **catalog-parity test** (retires the hand-wired parity rule). **Flip observe-on-by-default ON.**
- **Phase 3 — MCP front door.** In-house MCP server, tool shapes generated from the catalog + curated descriptions; publish the HTTP+schema contract. Begin Claude-in-Laban dogfooding.
- **Phase 4 — Truthful-fixture pillar (the deferred view-layer work).** Promote selection/cursor/find to first-class live-queryable state (new AppKit-view accessors); wire `MetalReadback` so `screenshot`/`pixel-probe`/`frame-commands` are GUI-truthful — decide `captureMode` sync vs async/queued readback (the perf tradeoff).
- **Phase 5 — Hardening + reach.** New-capability intents with no current agent counterpart: theme, font, restore-toggle, backend switch, **restart**, tab reorder, hyperlink open; GUI capture start/stop/snapshot control. Per-session token scoping (cheap — envp already in wire). SSE/long-poll push stream + Warp-Block-equivalent command records from OSC 133.

### FIRST SLICE (Phase 0), fully specified

**Goal:** an agent hits a loopback HTTP server **hosted inside the running `LabanApp` GUI**, authenticates with a token, **queries** live tab/session state, and issues **one control intent** (`selectTab`), observing the effect — all through the registry seam, all CI-tested.

**Why `selectTab` + `state`:** `selectTab` already exists end-to-end (`executeAppCommand` → `selectTab(at:)`), is reversible, needs no Metal, and its effect (`activeTabId`) is directly observable in `state`. Lowest-risk vertical slice that exercises auth + Host/Origin + registry + live coordinator.

**Types (new, in LabanCore):**
```swift
enum Phase0Intent: Codable { case selectTab(index: Int) }
struct Phase0IntentResult: Codable { let ok: Bool; let frame: Int; let activeTabId: String?; let error: String? }
enum Phase0Query: Codable { case state }
// reuse existing StateResponse for the query result
protocol IntentRouter {
  func route(_ intent: Phase0Intent) -> Phase0IntentResult
  func query(_ query: Phase0Query) -> StateResponse
}
final class LabanControlServer { /* loopback bind, token, Host+Origin check, 2 routes */ }
```

**Live router (LabanApp):** `LiveIntentRouter` holds a weak ref to the controller owning `AppModel`/`AppSessionCoordinator`. `route(.selectTab(i))` dispatches `selectTab(at: i)` on the main actor; `query(.state)` builds the existing `StateResponse` from the live model (no `HeadlessDebugRuntime`).

**Mounting:** `MainWindowController.makeAndShow` constructs `LiveIntentRouter` and starts `LabanControlServer` on `127.0.0.1:0`, writing `{url,token,pid,runId}` to `$runDir/control.json` (mode 0600). Gated behind an env flag (`LABAN_CONTROL_SERVER=1`) for Phase 0 so default human launches are unchanged.

**Routes (only two):**
- `GET  /debug/state`  → `query(.state)` → `StateResponse` (requires valid token; `.observe`).
- `POST /debug/actions` with `{"action":"selectTab","index":N}` → `route(.selectTab(N))` → `Phase0IntentResult` (requires valid token; `.control`).

**Auth/transport (this slice):** 32-byte hex bearer token (reuse `makeBearerToken`/`constantTimeEquals`); bind 127.0.0.1; **reject non-loopback `Host`** and **cross-origin `Origin`** with `403`; missing/invalid token → `401`. Fail closed.

**Test (the gate that makes the slice real):** a new script `scripts/test-control-server-gui` (wired into `scripts/check`) that:
1. builds `./scripts/build-app`; launches the installed bundle **with `LABAN_CONTROL_SERVER=1`** under a watchdog (per the no-GUI-launch rule, via the smoke/headless path that drives the real `LabanApp` window-host code, not `open`);
2. reads `$runDir/control.json` for `{url,token}`;
3. `GET /debug/state` with the token → asserts ≥1 tab and records `activeTabId`;
4. asserts `GET /debug/state` **without** a token → `401`, and **with a forged `Host: evil.com`** → `403`;
5. drives `newTab` via the existing GUI path (or fixture) to get a second tab, then `POST /debug/actions {selectTab:0}`;
6. `GET /debug/state` again → asserts `activeTabId` changed to tab 0.

Plus a `LabanCore`/`LabanApp` unit test: `LiveIntentRouter.route(.selectTab)` mutates `activeTabId`, and `LabanControlServer` returns `401`/`403` for missing-token / bad-Host. This is the first proof that *the app users run* is queryable and controllable over loopback HTTP through the registry seam.

---

## 8. Open questions / decisions needed

> **All eight resolved in §0 (grilling, 2026-05-30).** Summary of dispositions: (1) server home → **new `LabanControl` target** (three-way split; registry stays in `LabanCore`). (2) shipped posture → **token-gated observe-on-by-default**, flipped at the Phase-2 boundary. (3) token model → **single app-scoped + env-injection**; per-session deferred (no wire change needed). (4) Metal readback → deferred to the Phase-4 truthful-fixture pillar; `captureMode` sync-vs-async decided then. (5) `HeadlessDebugRuntime` → **kept** as the offscreen backend; lean parity via shared server + catalog-parity test (no `AppHost` refactor). (6) ADRs → **0012** (architecture) + **0013** (security), before Phase 1 (0011 is taken). (7) "every visible part" → v1 is relocation-MVP; selection/cursor/find promotion is the Phase-4 pillar. (8) MCP → **in-house, generated + curated**, pulled to just after the Phase-2 security floor; contract also published. Original analysis retained below for rationale.

1. **Single shared server target?** Confirm `LabanControlServer`/`IntentRouter`/`IntentCatalog` land in **LabanCore** (AppKit-free, reachable by `LabanApp`, `LabanDebug`, and the daemons) vs a new `LabanControl` target. Recommendation: LabanCore.
2. **Default posture in the shipped GUI:** server **off** until a setting/env enables it (Phase 0 default), or **observe-only on by default** with control opt-in? iTerm2 ships disabled-by-default; recommend off-by-default through Phase 4, observe-on by default only once Host/Origin + capability tokens land.
3. **Per-session token injection vs single app token.** Per-session env injection (iTerm2 model) is stronger but changes child-env plumbing across all three tiers. Acceptable to start with a single app-scoped token (Phase 0–3) and add per-session injection in Phase 4?
4. **Metal readback cost.** Is a synchronous drawable readback acceptable for `screenshot`/`pixel-probe` latency, or do we need an async/queued capture? Affects Phase 3 API shape.
5. **Retire `HeadlessDebugRuntime`'s private model entirely**, or keep it for fixture/deterministic CI runs? Recommendation: keep it as a *router implementation* (fixtures, offscreen determinism), but it must mount the same `LabanControlServer` so parity is structural.
6. **New ADR(s) required.** This establishes durable policy: (a) "LabanApp hosts the loopback control+query server; agent and headless are adapters over one IntentRouter" and (b) "agent control surface security model: loopback + Host/Origin + capability tokens + escape-sequence control deferred." Confirm we write ADR 0012 (+ 0013) before Phase 1 lands. *(Resolved: yes — 0011 is taken by the alt-screen patch.)*
7. **Scope of "every visible part."** Selection/find UI state currently has no out-of-process accessor in the GUI (only the headless mirror). Confirm we promote selection/cursor/find to first-class live-queryable state (the differentiator no comparator offers) — this is net-new work in the AppKit view layer, not relocation.
8. **MCP timing.** Build the MCP wrapper in-house (Phase 7) or publish the HTTP+schema contract and let it be community-wrapped (the it2mcp pattern)? Affects how aggressively we freeze the HTTP contract.