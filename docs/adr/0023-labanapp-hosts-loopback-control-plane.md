# 23. LabanApp Hosts the Loopback Agent-Control Server

Date: 2026-06-20

## Status

Accepted.

## Context

Laban already has a rich agent-control surface — `DebugHTTPServer`
(`Sources/LabanDebug/`, ~40 loopback routes: state, sessions+grid, screenshot,
actions, wait, events, find, selection, shell-integration) — but it is
instantiated **only** by the headless binary (`laban-agent`, via
`HeadlessDebugRuntime`), which renders offscreen against its *own* `AppModel`.
The GUI users actually run (`LabanApp`) never starts it; it links `LabanDebug`
only for `CaptureRecorder`. So an agent or test cannot inspect or drive the real
window — the live tabs, sessions, and render state — over a Laban-provided
channel. The only such channels into the running GUI today are read-only files
(the always-on `EventLog`; capture/probe artifacts).

Every mature comparator avoids this split. tmux and wezterm have one state
authority (the server / the `Mux`) that both the human frontend and the
programmatic client attach to over the same transport; wezterm's GUI and
`wezterm cli` are both mux clients, with no separate debug binary. kitty/iTerm2
build the scripting API into the one binary users run, gated by config. The
process that owns the real tabs/PTYs/render state should *be* the queryable
fixture.

`AppModel` (`Sources/LabanCore/AppModel.swift`) is already AppKit-free,
internally locked, and shared by both `MainWindowController.makeAndShow` and
`HeadlessDebugRuntime`; only the renderer backend differs (Metal/window vs
software/offscreen). `LabanDebug` is AppKit-free. `MetalReadback.swift`
(`captureMode`, `pngData`) already exists for GUI-truthful frames. So hosting the
server in the GUI is **relocation and unification, not invention**. Phase 0
(`execplans/completed/agent-first-phase0-control-seam.md`, shipped `0a2a230`)
proved the seam: a loopback server hosted inside `LabanApp`, authenticated,
reading and mutating the live `AppModel`, behind `LABAN_CONTROL_SERVER=1`.

AGENTS.md previously required `HeadlessDebugRuntime` to stay in hand-maintained
feature parity with `makeAndShow` ("wire new subsystems into both"). That rule is
unenforced and drifts silently.

## Decision

`LabanApp` hosts the same loopback control server as the headless runtime. There
is **one server, one `IntentCatalog`, and one `IntentRouter` protocol** with two
implementations that mount the same server:

- `LiveIntentRouter` (in `LabanApp`) binds the live `AppModel` +
  `AppSessionCoordinator` + `MetalReadback`.
- `HeadlessIntentRouter` (in `LabanDebug`) drives the offscreen runtime. It is
  **kept**, not retired — it is the deterministic fixture/CI backend.

Every user-meaningful operation is a typed `Intent` (the union of today's
`AppCommand` and `DebugAction` cases); every read is a typed `Query`. The catalog
is the single source of truth from which discovery, the `schemas/` set, the
security policy (ADR 0024), and a future MCP tool list are **generated**.

Target placement (transport-neutral types vs transport):

- **`LabanCore`** — `Intent`/`Query`/`IntentResult`/`QueryResult`/`Capability`/
  `IntentDescriptor`/`IntentCatalog` + the `IntentRouter` protocol. No HTTP, no
  AppKit, no wire framing.
- **`LabanControl`** (new SwiftPM target) — `LabanControlServer` (bind + token +
  Host/Origin), `LabanControlPolicy`, the HTTP↔Intent adapter, the `control.json`
  writer, and catalog→discovery/schema generation. AppKit-free.
- **`LabanApp`** — `LiveIntentRouter`; mounts the server. GUI human adapters
  (`executeAppCommand`, menus, key routes) emit the **same** `Intent`s.
- **`LabanDebug`** — `HeadlessIntentRouter` + `HeadlessDebugRuntime` + fixtures +
  a headless-only `FixtureActionCatalog`; mounts the same server.
- **MCP** (later) — generated from `IntentCatalog` as an out-of-process wrapper
  over the same surface; never a parallel implementation.

Parity is made **structural, not procedural**: the AGENTS.md "wire both by hand"
rule is replaced by "both routers mount the shared server and pass the
**catalog-parity test**" — a test that enumerates `IntentCatalog` and asserts both
routers handle every shared intent, so drift is a CI failure.

Identity and addressing: `Session.ID` (stable, survives tab selection / resize /
view rebuild) is the primary key for terminal I/O intents; `Tab.ID` for
window/tab lifecycle; "active" is a convenience selector that resolves to a
concrete id echoed back in the result. Indices are never keys for anything that
outlives a single request.

Discovery: a long-lived GUI cannot use the headless stdout readiness line, so it
writes a `control.json` (`{url, token, pid, runId}`) discovery file; auth and
tiering are governed by ADR 0024.

The existing `/debug/*` HTTP path namespace is retained through Phase 0–1 for
client continuity; the Phase 2 endpoint re-point reconciles it.

## Consequences

- The app users run becomes inspectable and controllable over loopback; agents
  orient against typed truth instead of scraping pixels or scrollback.
- `HeadlessDebugRuntime` stops being a divergent superset; GUI/headless drift is
  caught by the catalog-parity test rather than manual discipline.
- Phase 1 carves `DebugHTTPServer`/`Debug*Endpoints` out of `LabanDebug` into
  `LabanControl` as the HTTP↔Intent adapter, in reviewable subphases (types →
  new target with a Phase-0-equivalent adapter → incremental endpoint re-point →
  catalog/schema generation + parity test).
- Render/pixel endpoints in the GUI resolve through `MetalReadback`; the headless
  runtime keeps `SoftwareRenderer`. Both consume the shared `[FrameCommand]`
  language (ADR 0017), so the agent surface stays renderer-agnostic.
- A new SwiftPM target (`LabanControl`) is added to the package graph; `LabanApp`
  and `LabanDebug` depend on it.

## Applies To New Code

- A new agent-reachable operation is added **once** to `IntentCatalog` (with a
  `requiredCapability` and schema), not as a hand-written HTTP route, MCP tool, or
  test helper. Discovery, schemas, and policy are generated from the catalog; the
  contract gate fails until a new intent is classified.
- New subsystems that should be agent-visible implement against the
  `IntentRouter` protocol so both the live and headless routers expose them; the
  catalog-parity test guards parity.
- Do not add a second control surface or duplicate control concepts across GUI,
  headless, and MCP. Transport adapters terminate at one router; they do not
  re-implement behavior.
- Terminal-I/O intents key off `sessionId`; lifecycle intents off `tabId`; never
  persist an index.
