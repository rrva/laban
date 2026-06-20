# Phase 1: Typed Intent Registry + Carve `LabanControl`

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. It is the second executable phase of the program design in
`execplans/agent-first-terminal-design.md` (Phase 1; read §3–§5 there for the
architecture and ADR 0023/0024 for the settled policy). The first phase shipped
as `execplans/completed/agent-first-phase0-control-seam.md` (commit `0a2a230`):
a loopback control server hosted inside the running `LabanApp` GUI.

This phase is large, so it is delivered as four independently-reviewable
milestones (**1A → 1D**). **1A is fully specified below and executable now.**
1B–1D are specified at milestone granularity (scope, end-state, key interfaces,
acceptance); flesh out their Concrete Steps as each lands — that is the expected
living-document workflow, not a gap.

## Purpose / Big Picture

Today Laban has two disconnected control surfaces. The GUI users run (`LabanApp`)
hosts a *tiny* loopback server (Phase 0: two routes — `GET /debug/state`,
`POST /debug/actions {selectTab}`). The headless test binary (`laban-agent`)
hosts a *rich* one — `DebugHTTPServer`, ~50 routes — but against its own
offscreen model. The two share no code: routes, request types, the discovery
document, and the JSON schemas are all hand-maintained, in two places, kept in
sync only by a `check-debug-contract` lint.

After Phase 1, there is **one typed vocabulary and one server implementation**:

- Every operation is a typed `Intent` (an action) or `Query` (a read), defined
  once in `LabanCore`. A single `IntentCatalog` lists them with their capability,
  schemas, risk, and sensitivity.
- A new `LabanControl` SwiftPM target hosts the one HTTP server, whose route
  table is an **HTTP↔Intent adapter**: each route decodes a request into an
  `Intent`/`Query` and calls an injected `IntentRouter`, then serializes the
  result.
- The GUI's `LiveIntentRouter` (against the real `AppModel`) and the headless
  `HeadlessIntentRouter` (against the offscreen runtime) both implement the same
  `IntentRouter` protocol and mount the same server. Parity is a **test**, not a
  hand-discipline.
- The discovery document and the `schemas/` set are **generated from the
  catalog**; the contract gate fails CI if an intent lacks a schema or capability.

You can see each milestone working:

- **1A:** `swift test --filter IntentCatalogTests` passes; `LabanCore` still
  builds AppKit-free. (Pure new vocabulary; no server touched.)
- **1B:** the GUI Phase-0 seam (`GET /debug/state`, `selectTab`) is served by the
  new `LabanControl` target through the `IntentRouter`; `LabanControl` builds with
  **no AppKit dependency**; the Phase 0 tests pass unchanged.
- **1C:** every `DebugHTTPServer` route is served from `LabanControl` via the
  adapter against a `HeadlessIntentRouter`; the existing `LabanDebugTests` E2E
  suite passes unchanged; `DebugHTTPServer` is deleted.
- **1D:** `scripts/check` regenerates `schemas/` + the discovery doc from the
  catalog and fails if any catalog intent lacks a schema or capability.

Throughout, the GUI is unchanged for humans and CI stays green.

## Progress

Milestone 1A — Registry backbone (LabanCore):
- [ ] `Sources/LabanCore/Intents/` added: `Capability`, `DataSensitivity`, `Intent`, `Query`, `IntentResult`, `QueryResult`, `IntentDescriptor`, `IntentCatalog`, `IntentRouter` protocol.
- [ ] `IntentCatalog.shared` seeded with the starter intents/queries (state, tab.select, terminal.typeText, terminal.sendKey) + descriptors.
- [ ] `Tests/LabanCoreTests/IntentCatalogTests.swift` added (well-formedness + uniqueness + fixture-tagging).
- [ ] `swift test --filter IntentCatalogTests` passes; `LabanCore` has no AppKit import.

Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter:
- [ ] `LabanControl` target added to `Package.swift` (deps `["LabanCore"]`); `LabanApp` depends on it.
- [ ] Phase 0 seam relocated from `Sources/LabanApp/Control/` into `LabanControl`, with `LabanControlServer` generalized to a route-table HTTP↔Intent adapter driven by `IntentRouter`.
- [ ] `LiveIntentRouter` (in `LabanApp`) reimplements `IntentRouter` (route/query) for the starter intents; `MainWindowController` mounts the relocated server.
- [ ] Phase 0 automated tests pass against the relocated server; `LabanControl` builds AppKit-free.

Milestone 1C — Re-point the full debug surface through the adapter:
- [ ] Shared request payload structs relocated from `LabanDebug` to `LabanCore`; `DebugAction`↔`Intent` mapping established (exhaustive).
- [ ] `HeadlessIntentRouter` added in `LabanDebug`; `laban-agent` mounts the `LabanControl` server.
- [ ] All ~50 routes ported into `LabanControl`'s route table (incrementally), reading via `Query`/writing via `Intent`; the headless-only `FixtureActionCatalog` (`feedOutput`/`advanceFrames`/`windowFocus`) gated behind `.fixture`.
- [ ] `DebugHTTPServer` deleted; `Tests/LabanDebugTests` pass unchanged; catalog-parity test added.

Milestone 1D — Generate discovery + schemas from the catalog:
- [ ] Catalog→schema + catalog→discovery generator added; `schemas/` and the discovery doc regenerate from `IntentCatalog`.
- [ ] `check-debug-contract` extended to assert catalog↔routes↔schemas consistency and to fail on any intent missing a schema or capability.
- [ ] `scripts/check` green with the generated artifacts committed.

## Context and Orientation

You need no prior Laban knowledge. Key terms and the files where they live:

- **`LabanApp`** — the windowed macOS app target (`Sources/LabanApp/`, AppKit).
- **`LabanCore`** — the AppKit-free model/session library (`Sources/LabanCore/`).
  `AppModel` (`Sources/LabanCore/AppModel.swift`) is the in-memory tab/session
  state; it is internally locked (`withModelLock`). Both the GUI and the headless
  runtime build one.
- **`LabanDebug`** — the AppKit-free library that today holds the HTTP server and
  the offscreen runtime (`Sources/LabanDebug/`).
- **`LabanControl`** — *new in this phase*: an AppKit-free library for the control
  server, the policy, the HTTP↔Intent adapter, the discovery/`control.json`
  writer, and the catalog→schema generator. Depends only on `LabanCore`.
- **Phase 0 seam** (`Sources/LabanApp/Control/`, shipped):
  - `ControlRouter.swift` — `ControlTabState`, `ControlState`,
    `ControlActionResult` (all `Codable`); `protocol ControlRouter { snapshotState() -> ControlState; selectTab(index:) -> ControlActionResult }`.
  - `LiveIntentRouter.swift` — implements `ControlRouter` over a weak `AppModel`,
    hopping mutations to the main thread.
  - `LabanControlServer.swift` — `enum GuardOutcome { ok, unauthorized, forbidden }`;
    `final class LabanControlServer` with `start() throws -> (url:token:)`,
    `stop()`, `static evaluateGuard(host:origin:authorization:token:) -> GuardOutcome`
    (loopback `Host` required, any `Origin` forbidden, bearer token), and a private
    `route(method:path:)` switch. **This server has the correct security but a
    hardcoded two-route switch.**
  - `ControlAdvertisement.swift` — writes/removes `control.json` (`0600`,
    `O_EXCL`-then-`rename`) under `$LABAN_CONTROL_DIR` or app-support.
  - Mounted in `MainWindowController.makeAndShow` (lines ~509–527) behind
    `LABAN_CONTROL_SERVER=1`.
- **`DebugHTTPServer`** (`Sources/LabanDebug/DebugHTTPServer.swift`, ~lines
  59–819) — the rich headless server. Its routes are a declarative array
  `private static let routes: [DebugHTTPRoute]`; each entry is
  `DebugHTTPRoute(method:path:category:summary:requestSchema?:responseSchema?) { runtime, request, headers in ... }`
  where the closure returns an `HTTPResponse`. **This server has the good route
  table but checks only the host *parameter*, not the request `Host`/`Origin`
  headers.** It holds `private let runtime: HeadlessDebugRuntime` and is started
  from `Sources/LabanAgent/main.swift` (~lines 251–257).
- **`HeadlessDebugRuntime`** (`Sources/LabanDebug/HeadlessDebugRuntime.swift`) —
  owns the offscreen `AppModel`, renderer, surface. The route handlers are
  extension methods on it (`state()`, `discovery()`, `applyAction(_:)`,
  `screenshotBytes()`, …) that lock via `withRuntimeLock()`. All writes funnel
  through `DebugRuntimeActions.applyActionUnlocked(_ action: DebugAction)`
  (`Sources/LabanDebug/DebugRuntimeActions.swift`, ~lines 14–73).
- **`DebugAction`** (`Sources/LabanDebug/DebugRuntimeRequests.swift`, ~lines
  8–104) — the `POST /debug/actions` vocabulary: 36 cases including `newTab`,
  `closeTab`, `selectTab`, `setTabTitle`, `moveTab`, `resizeWindow`, `setFontSize`,
  `typeText`, **`feedOutput`**, **`advanceFrames`**, `setClipboardText`,
  `setSelection`, `findStart/Step/Stop`, `copy`, `paste`, `dropFiles`,
  `scrollViewport`, `mouseWheel`, `mouseDrag`, `click`, `key`, **`windowFocus`**,
  `unsupported(String)`. Each case carries a `Codable` request struct
  (`TabTargetActionRequest`, `TextActionRequest`, …) defined in the same file.
- **`AppCommand`** (`Sources/LabanApp/TerminalInputView.swift`, ~lines 7–22) — the
  GUI app-command enum (`newTab`, `closeTab`, `selectTab(index:)`, `copy`,
  `paste`, `find`, font-size cases, …), dispatched by `executeAppCommand(_:)` in
  `Sources/LabanApp/TerminalBitmapView.swift` (~lines 3843–3879). These overlap
  the `DebugAction` set: both describe the same user-meaningful operations.
- **`DebugDiscoveryCatalog`** + `discovery()` (`Sources/LabanDebug/DebugDiscoveryEndpoints.swift`)
  — a hand-curated list of action names, wait conditions, fixture actions, and
  curl examples, assembled into the `GET /debug` response. **Not generated.**
- **`check-debug-contract`** (`scripts/check-debug-contract`, Python; run by
  `scripts/check`) — validates that (1) every `/debug/*` endpoint documented in
  `docs/process/dev-process.md` exists in `DebugHTTPServer.routes`, and (2) every
  `requestSchema`/`responseSchema` path named in the routes exists under
  `schemas/`. It validates consistency only; it does not generate.
- **`schemas/debug/*.schema.json`** — 33 hand-written JSON Schemas.
- **`Package.swift`** — `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`.
  `LabanCore` deps `["LabanTerminalCore","LabanRenderer"]`; `LabanDebug` deps
  `["LabanCore","LabanRenderer","LabanTerminalCore"]`; `LabanApp`/`LabanAgent`/
  `Laband` each depend on `LabanDebug`.
- **`scripts/check`** runs structural/contract/lint gates (incl.
  `check-debug-contract`, smoke-runtime, test-e2e, coverage). **`scripts/test`**
  runs `swift test`. **`scripts/build-app`** builds `.build/laban/Laban.app`.

Architecture this phase realizes (from ADR 0023): one `IntentCatalog`, one
`IntentRouter` protocol with two implementations (`LiveIntentRouter` /
`HeadlessIntentRouter`) mounting one server; transport-neutral types in
`LabanCore`; server/policy/adapter in `LabanControl`. Security (ADR 0024) is
unchanged from Phase 0 and is preserved by reusing `LabanControlServer`'s guard.

---

## Milestone 1A — Registry backbone in `LabanCore` (no endpoint moves)

**Scope.** Add the typed vocabulary and the catalog to `LabanCore`. Touch no
server, no endpoint, no `Package.swift`. Pure, additive, AppKit-free. At the end,
the vocabulary compiles and a test proves the catalog is internally consistent.
Nothing yet *uses* it — that is 1B.

**What exists at the end.** A new `Sources/LabanCore/Intents/` directory with the
type system below, an `IntentCatalog.shared` seeded with a starter set, and
`IntentCatalogTests`.

### Plan of Work (1A)

Add these files under `Sources/LabanCore/Intents/`. Reference skeletons (the
executing agent finalizes exact payload fields):

`Capability.swift`:

    public enum Capability: String, Codable, CaseIterable, Sendable {
      case observe            // non-sensitive live state
      case observeSensitive   // scrollback, grid text, process cwd/cmd, input log, clipboard
      case control            // mutations: type/key/paste, resize/scroll/select, tab/window lifecycle
      case clipboard          // programmatic clipboard write
      case fixture            // headless determinism affordances; the shipped GUI never grants it
    }

`DataSensitivity.swift`:

    public enum DataSensitivity: String, Codable, Sendable {
      case none, nonSensitiveState, visibleText, scrollback, keystrokes, clipboard, screenshot, trace
    }

`Intent.swift` — the tagged ACTION union. Seed it with the starter set only; it
grows one case per ported route in 1C. Each case carries a `Codable` payload.

    public enum Intent: Codable, Sendable, Equatable {
      case tabSelect(TabSelectInput)        // id == "tab.select"
      case terminalTypeText(TypeTextInput)  // id == "terminal.typeText"
      case terminalSendKey(SendKeyInput)    // id == "terminal.sendKey"
      // 1C adds: tabCreate, tabClose, terminalPaste, terminalResize, terminalScroll, … (one per route)

      public var id: String { … }           // stable dotted id, e.g. "tab.select"
    }

    public struct TabSelectInput: Codable, Sendable, Equatable {
      public var tabId: String?            // nil ⇒ resolve by index/active
      public var index: Int?
    }
    public struct TypeTextInput: Codable, Sendable, Equatable {
      public var sessionId: String?        // nil ⇒ active session
      public var text: String
    }
    public struct SendKeyInput: Codable, Sendable, Equatable {
      public var sessionId: String?
      public var key: String
      public var modifiers: [String]
    }

`Query.swift` — the tagged READ union (+ its result), same growth pattern.

    public enum Query: Codable, Sendable, Equatable {
      case state                           // id == "app.state" — tabs + active
      // 1C adds: sessionList, sessionGrid, render, selection, events, …
      public var id: String { … }
    }

    public enum QueryResult: Codable, Sendable {
      case state(TabsState)
      // 1C adds one case per query
    }

    public struct TabsState: Codable, Sendable, Equatable {
      public struct Tab: Codable, Sendable, Equatable {
        public let id: String; public let index: Int
        public let active: Bool; public let sessionId: String?
      }
      public let tabs: [Tab]
      public let activeTabId: String?
    }

`IntentResult.swift`:

    public struct IntentResult: Codable, Sendable, Equatable {
      public let ok: Bool
      public let actedTabId: String?
      public let actedSessionId: String?
      public let eventId: String?
      public let error: IntentError?
      public static func success(actedTabId: String? = nil, actedSessionId: String? = nil, eventId: String? = nil) -> IntentResult
      public static func failure(_ code: String, _ message: String) -> IntentResult
    }
    public struct IntentError: Codable, Sendable, Equatable { public let code: String; public let message: String }

`IntentRouter.swift` — the seam every transport terminates at; generalizes Phase
0's `ControlRouter`.

    public protocol IntentRouter: AnyObject {
      func route(_ intent: Intent) -> IntentResult
      func query(_ query: Query) -> QueryResult
    }

`IntentDescriptor.swift` — the catalog metadata (the expanded model from design
§4.2). Schema refs are strings (relative `schemas/` paths) generated in 1D.

    public struct IntentDescriptor: Codable, Sendable, Equatable {
      public enum Kind: String, Codable, Sendable { case query, action, wait, event }
      public let id: String                  // "tab.select"
      public let kind: Kind
      public let category: String            // "app"|"window"|"tab"|"terminal"|"trace"|"screenshot"|"event"|…
      public let summary: String
      public let requiredCapability: Capability
      public let dataSensitivity: DataSensitivity
      public struct SideEffects: Codable, Sendable, Equatable {
        public var ptyInput = false; public var lifecycle = false
        public var clipboard = false; public var filesystem = false; public var network = false
      }
      public let sideEffects: SideEffects
      public struct Risk: Codable, Sendable, Equatable { public enum Level: String, Codable, Sendable { case none, low, medium, high }; public let level: Level; public let reason: String }
      public let risk: Risk
      public enum Audit: String, Codable, Sendable { case none, metadataOnly, redactedInput, fullInput }
      public let audit: Audit
      public struct Availability: Codable, Sendable, Equatable { public let gui: Bool; public let headless: Bool }
      public let availability: Availability
      public struct Transports: Codable, Sendable, Equatable { public let http: Bool; public let mcp: Bool; public let cli: Bool }
      public let transports: Transports
      public let inputSchema: String?        // generated in 1D
      public let outputSchema: String?
      public let errorSchema: String?
    }

`IntentCatalog.swift` — the source of truth + validation.

    public struct IntentCatalog: Sendable {
      public let descriptors: [IntentDescriptor]
      public func descriptor(id: String) -> IntentDescriptor?
      public var ids: Set<String>
      /// Throws on duplicate ids, empty summary, or (1D) missing schema refs.
      public func validate() throws
      public static let shared: IntentCatalog            // the shared cross-surface catalog
      public static let fixture: IntentCatalog           // headless-only (.fixture) — empty until 1C
    }

Seed `IntentCatalog.shared` with descriptors for the starter set: `app.state`
(query, `.observe`, sensitivity `.nonSensitiveState`), `tab.select` (action,
`.control`, lifecycle), `terminal.typeText` (action, `.control`, `ptyInput=true`,
risk `.medium`, sensitivity `.keystrokes`, audit `.redactedInput`),
`terminal.sendKey` (action, `.control`, `ptyInput=true`).

### Concrete Steps (1A)

All commands run from the repository root.

1. Create the files above under `Sources/LabanCore/Intents/`.
2. Add `Tests/LabanCoreTests/IntentCatalogTests.swift` (see Validation 1A).
3. Build + test:

       swift build
       swift test --filter IntentCatalogTests

   Expect `0 failures`.
4. Confirm AppKit-free:

       grep -rn "import AppKit\|import Cocoa" Sources/LabanCore/Intents || echo "clean"

   Expect `clean`.

### Acceptance (1A)

`swift test --filter IntentCatalogTests` passes and `IntentCatalogTests`:

- asserts `IntentCatalog.shared.validate()` does not throw;
- asserts ids are unique and non-empty, and every starter id resolves;
- asserts every `Intent` starter case's `.id` has a matching descriptor and vice
  versa (so the enum and catalog cannot drift) — drive this from a hardcoded list
  of the starter ids;
- asserts no descriptor with `availability.gui == true` requires `.fixture`.

Each assertion fails if its invariant is broken (e.g., give two descriptors the
same id → `validate()` throws → test fails).

---

## Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter

**Scope.** Create the `LabanControl` target. Relocate the Phase 0 seam into it,
generalizing `LabanControlServer` from a hardcoded two-route switch into a
**declarative route table that decodes into `Intent`/`Query` and calls an injected
`IntentRouter`** (the HTTP↔Intent adapter). Reimplement the GUI's
`LiveIntentRouter` against the `LabanCore` `IntentRouter` protocol. The big
`DebugHTTPServer` in `LabanDebug` is **untouched** this milestone.

**End state.** The running GUI serves the same two Phase-0 routes, now through
`LabanControl` + the catalog seam, with identical behavior and identical security.

**Key moves.**

- `Package.swift`: add
  `.target(name: "LabanControl", dependencies: ["LabanCore"])` after `LabanCore`;
  add `"LabanControl"` to `LabanApp`'s dependencies.
- Move `LabanControlServer.swift`, `GuardOutcome`, and `ControlAdvertisement.swift`
  from `Sources/LabanApp/Control/` to `Sources/LabanControl/`. Keep
  `LiveIntentRouter.swift` in `LabanApp` (it is GUI-specific — it binds
  `AppModel`). Relocate `ControlState`/`ControlTabState`/`ControlActionResult`
  into `LabanCore` (reconcile with 1A's `TabsState`: prefer `TabsState`, delete the
  Phase 0 duplicates).
- Generalize `LabanControlServer`: replace the hardcoded `route(method:path:)`
  switch with a declarative `[ControlRoute]` table (mirror `DebugHTTPRoute`:
  `method`, `path`, optional schema refs, and a handler
  `(IntentRouter, HTTPRequest) -> HTTPResponse`). The server now takes an
  `IntentRouter` (not the narrow `ControlRouter`). Keep `start`/`stop`/
  `evaluateGuard`/token verbatim — the security is already correct.
- The 1B route table has exactly two entries, both as adapter handlers:
  `GET /debug/state` → `router.query(.state)` → JSON; `POST /debug/actions`
  decodes `{"action":"selectTab",…}` → `Intent.tabSelect(…)` →
  `router.route(_)` → JSON.
- `LiveIntentRouter` (LabanApp) now conforms to `IntentRouter`:
  `query(.state)` builds `TabsState` from the live `AppModel`;
  `route(.tabSelect(let i))` does the bounds-checked `model.selectTab` (the exact
  Phase 0 behavior, on the main thread). Other intents return
  `IntentResult.failure("unsupported", …)` until 1C.
- `MainWindowController.makeAndShow` imports `LabanControl`, constructs
  `LiveIntentRouter`, and mounts the relocated `LabanControlServer` (the
  `LABAN_CONTROL_SERVER=1` block is otherwise unchanged).

**Acceptance (1B).**

- `LabanControl` builds and `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl`
  returns nothing.
- The Phase 0 automated tests (relocated to `Tests/LabanControlTests/` or kept in
  `LabanAppTests` with updated imports) pass: the guard matrix, the live
  select-tab round-trip, and the loopback end-to-end (`GET /debug/state` → 200 +
  tabs; no token → 401; forged `Host` → 403; `selectTab` → `activeTabId` changes).
- Manual (operator-launched GUI, per Phase 0): `curl` of the live `control.json`
  still returns state and switches tabs.
- `Sources/LabanApp/Control/` no longer contains the server/advertisement (only
  `LiveIntentRouter.swift` may remain, or it moves to `Sources/LabanApp/`).

---

## Milestone 1C — Re-point the full debug surface through the adapter

**Scope.** Move the entire `DebugHTTPServer` route surface into `LabanControl`'s
route table, route-group by route-group, with every handler going through
`Intent`/`Query` + an `IntentRouter`. Provide the headless implementation
(`HeadlessIntentRouter`). Retire `DebugHTTPServer`. This is the bulk of the carve;
do it **a few route groups per change**, keeping CI green at each step.

**Key moves.**

- Relocate the shared request payload structs (`TabTargetActionRequest`,
  `TextActionRequest`, `ResizeWindowActionRequest`, …) from
  `LabanDebug/DebugRuntimeRequests.swift` into `LabanCore` so `Intent` payloads,
  the adapter, and the headless mapping share one definition.
- Grow `Intent`/`Query`/`QueryResult` + `IntentCatalog.shared` one entry per
  ported route. **Classify fixture-only operations into `IntentCatalog.fixture`
  with `.fixture` capability and `availability.gui == false`:** `feedOutput`,
  `advanceFrames`, `windowFocus`, and title-forcing. The GUI router never grants
  `.fixture`, so these are unreachable on the live surface (design §4.3).
- Add `HeadlessIntentRouter` in `LabanDebug` conforming to `IntentRouter`: it
  translates `Intent`/`Query` into the existing
  `HeadlessDebugRuntime` calls (`applyActionUnlocked(_:)`, `state()`, …). Provide
  an exhaustive `DebugAction ↔ Intent` mapping (a `switch` with no `default`, so a
  new `DebugAction` fails to compile until mapped).
- `laban-agent` (`Sources/LabanAgent/main.swift`) mounts the `LabanControl`
  server with a `HeadlessIntentRouter` instead of constructing `DebugHTTPServer`.
- Port the routes in reviewable groups (suggested order — readers first, then
  actions, then render/diagnostics): health/state/sessions → actions/wait →
  find/selection/shell-integration/clipboard → render/screenshot/atlas/pixel-probe
  → events/journal/input-log/terminal-log/metrics/timing/errors →
  capture/persistence/fixture/cast/artifact. After each group, the corresponding
  `Debug*Endpoints` serializer is reframed as a `QueryResult`/`IntentResult`
  serializer (or moved into `LabanControl`).
- When the last group lands, **delete `DebugHTTPServer.swift`** and the now-unused
  `DebugDiscoveryCatalog` hand-lists (1D regenerates discovery from the catalog).
- Add the **catalog-parity test** (`Tests/.../CatalogParityTests.swift`): enumerate
  `IntentCatalog.shared`; assert both `LiveIntentRouter` and `HeadlessIntentRouter`
  handle every shared intent (no `unsupported`), so GUI/headless drift fails CI.

**Acceptance (1C).**

- `grep -rn "class DebugHTTPServer" Sources` returns nothing (server retired).
- `Tests/LabanDebugTests` (`LabanDebugSmokeTests`, `LabanDebugExploratoryControlTests`)
  pass **unchanged in intent** against the `LabanControl`-hosted server (update
  only construction/imports, not assertions).
- `scripts/check`'s smoke-runtime + test-e2e pass.
- The catalog-parity test fails if either router omits a shared intent (verify by
  temporarily removing one case → test fails → revert).
- A `.fixture`-tier intent (e.g., `feedOutput`) is rejected by the GUI router and
  accepted by the headless one.

---

## Milestone 1D — Generate discovery + schemas from the catalog; contract gate

**Scope.** Make `IntentCatalog` the *source* of the discovery document and the
`schemas/` set, and make the contract gate enforce it. Today these are
hand-written and only lint-checked; after 1D, adding an intent regenerates them
and a missing schema/capability fails CI.

**Key moves.**

- Add a generator (a small executable target `LabanControlGen`, or a `swift run`
  entry, or a method on `IntentCatalog` invoked by a script) that emits, from
  `IntentCatalog.shared` + `.fixture`: (a) each intent's request/response/error
  JSON Schema under `schemas/control/` (derived from the `Codable` payload types —
  use a deterministic encoder so output is stable), and (b) the discovery document
  (`GET /debug` body) listing endpoints, actions, wait conditions, fixture
  actions, capabilities, and examples.
- Wire generation into `scripts/check`: regenerate into a temp dir and `diff`
  against the committed `schemas/` + discovery doc; **fail if they differ**
  (committed artifacts must match the catalog), and **fail if any descriptor lacks
  `inputSchema`/`outputSchema` or a `requiredCapability`**. Extend (or replace)
  `check-debug-contract` accordingly; keep its existing route↔doc↔schema checks.
- Commit the generated `schemas/control/*.json` and discovery doc (they are
  generated artifacts, like `.rpg/graph.json`).

**Acceptance (1D).**

- Running the generator twice is idempotent (no diff on the second run).
- Deleting a generated schema and re-running `scripts/check` fails until
  regenerated.
- Adding a catalog descriptor without a capability fails `scripts/check` with a
  clear message.
- `scripts/check` is green with the generated artifacts committed.

---

## Validation and Acceptance

Per-milestone acceptance is above; each is observable behavior. Overall, Phase 1
is done when:

- one `IntentCatalog` (in `LabanCore`) is the single vocabulary; `Intent`/`Query`
  enums and the catalog cannot drift (covered by tests);
- one server implementation lives in `LabanControl` and is mounted by both the GUI
  (`LiveIntentRouter`) and `laban-agent` (`HeadlessIntentRouter`);
  `grep -rn "class DebugHTTPServer" Sources` is empty;
- `LabanControl` is AppKit-free (`grep` shows no AppKit import);
- the catalog-parity test makes GUI/headless drift a CI failure;
- discovery + `schemas/` are generated from the catalog and gated;
- `Tests/LabanDebugTests` and the Phase 0 GUI tests pass unchanged in intent;
- `./scripts/build-app`, `swift test`, and `./scripts/check` are green.

Run, from the repository root:

    swift test --filter IntentCatalogTests        # 1A
    swift test --filter ControlServerPhase0Tests  # 1B (Phase 0 behavior preserved)
    swift test --filter LabanDebug                 # 1C (full surface preserved)
    swift test --filter CatalogParityTests         # 1C
    ./scripts/check                                 # 1D (+ everything)
    ./scripts/build-app

## Decision Log

- Decision: deliver Phase 1 as milestones 1A–1D, each independently reviewable,
  rather than one change.
  Rationale: carving ~50 routes + a new target in one PR is unreviewable and
  risky; the roadmap (`agent-first-terminal-design.md` §6) prescribes this split.
  Date/Author: 2026-06-20 / Claude.
- Decision: the registry **types** live in `LabanCore`; the **server, policy, HTTP
  adapter, advertisement, and generator** live in the new `LabanControl` target;
  the **live router** stays in `LabanApp`; the **headless router** stays in
  `LabanDebug`.
  Rationale: ADR 0023 (transport-neutral types vs transport); keeps `LabanCore`
  AppKit-free and dependency-light, and lets the daemons reach the types without
  the server.
  Date/Author: 2026-06-20 / Claude.
- Decision: converge the two servers onto Phase 0's `LabanControlServer` (which
  has the correct `Host`/`Origin` security) generalized with `DebugHTTPServer`'s
  declarative route table — not the reverse.
  Rationale: security must not regress; ADR 0024 requires Host/Origin validation,
  which `DebugHTTPServer` lacks. Reuse the audited Phase 0 guard verbatim.
  Date/Author: 2026-06-20 / Claude.
- Decision: grow `Intent`/`Query` + the catalog one entry per ported route in 1C,
  rather than defining all ~50 upfront in 1A.
  Rationale: avoids speculative definitions; each route's port is a small,
  testable change; the catalog stays in lockstep with what is actually served.
  Date/Author: 2026-06-20 / Claude.
- Decision: keep the `/debug/*` HTTP path namespace through Phase 1.
  Rationale: continuity for existing clients and tests; the design (§4.4) defers
  the product `/control` namespace reconciliation to Phase 2.
  Date/Author: 2026-06-20 / Claude.
- Decision: `feedOutput`/`advanceFrames`/`windowFocus` (+ title-forcing) move to a
  headless-only `IntentCatalog.fixture` with `.fixture` capability, barred from the
  live GUI surface.
  Rationale: byte-injection / frame-stepping are test affordances with no honest
  live meaning; ADR 0024 + design §4.3.
  Date/Author: 2026-06-20 / Claude.

## Review Gate

A separate fresh-state agent verifies the following before this plan is marked
done (run from the repository root). Mechanical checks only.

- [ ] `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl Sources/LabanCore/Intents`
      returns nothing (both layers are AppKit-free).
- [ ] `grep -rn "class DebugHTTPServer" Sources` returns nothing after 1C.
- [ ] `swift build` and `swift test` exit 0; `swift test --filter IntentCatalogTests`,
      `ControlServerPhase0Tests`, and `CatalogParityTests` each report >0 tests, 0 failures.
- [ ] In `Package.swift`, `LabanControl` exists with dependencies exactly
      `["LabanCore"]`, and `LabanApp`/`LabanAgent`/`LabanDebug` list `"LabanControl"`.
- [ ] The `DebugAction → Intent` mapping switch has **no** `default` clause
      (exhaustiveness enforced): inspect the mapping file.
- [ ] Catalog-parity is real: temporarily make `LiveIntentRouter` return
      `unsupported` for one shared intent; `CatalogParityTests` fails; revert.
- [ ] 1D generation is idempotent: run the generator twice; the second run
      produces no `git diff` under `schemas/control/`.
- [ ] Deleting one generated schema and running `./scripts/check` fails; restoring
      it passes.
- [ ] `./scripts/check` exits 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- 1A is purely additive; re-running `swift test` is safe and leaves no artifacts.
- Each 1C route-group port is a small, revertible change; if a port breaks a
  `LabanDebugTests` case, revert that group and re-port — the route table and the
  catalog grow together, so a half-ported route is visible as a missing catalog
  entry or a failing parity test.
- 1D generation writes only under `schemas/control/` and the discovery doc; the
  generator is deterministic (stable encoder ordering), so reruns are no-ops. A
  stale generated file is fixed by re-running the generator.
- The new `LabanControl` target adds no runtime behavior until mounted (1B); until
  then the existing servers are untouched, so partial progress never breaks the
  shipped GUI or CI.

## Interfaces and Dependencies

End-state package graph (additions in **bold**):

    LabanCore         deps [LabanTerminalCore, LabanRenderer]   + Sources/LabanCore/Intents/*
    **LabanControl**  deps [LabanCore]                          (server, policy, HTTP↔Intent adapter,
                                                                  ControlAdvertisement, catalog generator)
    LabanDebug        deps [LabanCore, **LabanControl**, LabanRenderer, LabanTerminalCore]
                                                                  (HeadlessIntentRouter, HeadlessDebugRuntime, fixtures)
    LabanApp          deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]
                                                                  (LiveIntentRouter; mounts the server)
    LabanAgent        deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]

Key end-state types: `Intent`, `Query`, `QueryResult`, `IntentResult`,
`Capability`, `DataSensitivity`, `IntentDescriptor`, `IntentCatalog`,
`IntentRouter` (all `LabanCore`); `LabanControlServer` (route-table HTTP↔Intent
adapter), `LabanControlPolicy`, `ControlAdvertisement`, the catalog generator
(all `LabanControl`); `LiveIntentRouter: IntentRouter` (`LabanApp`);
`HeadlessIntentRouter: IntentRouter` (`LabanDebug`).

Dependencies: no new third-party packages. `LabanControl` uses only
`Foundation`/`Darwin`/`LabanCore`.
