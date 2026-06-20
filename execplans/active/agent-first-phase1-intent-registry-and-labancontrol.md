# Phase 1: Typed Intent Registry + Carve `LabanControl`

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. It is the second executable phase of the program design in
`execplans/agent-first-terminal-design.md` (Phase 1; read §3–§5 there and ADR
0023/0024 for the settled policy). Phase 0 shipped as
`execplans/completed/agent-first-phase0-control-seam.md` (commit `0a2a230`): a
loopback control server hosted inside the running `LabanApp` GUI.

This phase is delivered as four milestones (**1A → 1D**), each independently
verifiable. **Every milestone below has concrete steps and behavioral acceptance
— the plan is self-contained and executable end to end, per `PLANS.md`.** As a
living document it will gain detail (e.g., the exact per-route catalog entries in
1C) as work lands; that is normal revision, not deferred specification.

**Read "Cross-cutting design contracts" before any milestone** — five rules there
prevent the contract regressions a naive carve would cause (wire-shape, binary
responses, access control, schema source, the auth/capability phase boundary).

## Purpose / Big Picture

Today Laban has two disconnected control surfaces. The GUI users run (`LabanApp`)
hosts a *tiny* loopback server (Phase 0: `GET /debug/state`, `POST /debug/actions
{selectTab}`). The headless test binary (`laban-agent`) hosts a *rich* one —
`DebugHTTPServer`, **45 routes** — against its own offscreen model. The two share
no code; routes, request types, the discovery document, and the JSON schemas are
hand-maintained in two places, kept in sync only by a `check-debug-contract` lint.

After Phase 1, there is **one typed vocabulary and one server implementation**:

- Every operation is a typed `Intent` (action) or `Query` (read), defined once in
  `LabanCore`, listed in one `IntentCatalog` with its capability, schemas, risk,
  sensitivity, and **surface availability**.
- A new `LabanControl` SwiftPM target hosts the one HTTP server, whose route table
  is an **HTTP↔Intent adapter**: each route decodes a request, calls an injected
  `IntentRouter`, and serializes the result **into the exact existing wire shape**.
- The GUI's `LiveIntentRouter` and the headless `HeadlessIntentRouter` implement
  the same `IntentRouter` and mount the same server. Parity is a **test**.
- Discovery + `schemas/` are **generated from the catalog** via explicit,
  hand-authored schema definitions (no reflection); the contract gate fails CI if
  an intent lacks a schema or capability.

**The wire is byte-stable.** Existing clients and the `LabanDebugTests` E2E suite
see identical responses (same JSON fields, same `image/png`/`x-asciicast` bodies
and headers) — `IntentResult`/`QueryResult` are *internal domain* types the
adapter maps onto the legacy DTOs. Capability *enforcement* (token tiers, ADR
0024) is **out of scope for Phase 1** (Phase 2); Phase 1 *classifies* capabilities
in the catalog and keeps fixture/headless ops off the live surface structurally.

You can see each milestone working:

- **1A:** `swift test --filter IntentCatalogTests` passes; `LabanCore` builds
  AppKit-free. (Pure new vocabulary; no server touched.)
- **1B:** the GUI Phase-0 seam is served by `LabanControl` through `IntentRouter`,
  returning the **identical** `ControlState`/`ControlActionResult` JSON;
  `LabanControl` builds with no AppKit dependency; Phase 0 tests pass unchanged.
- **1C:** every `DebugHTTPServer` route is served from `LabanControl` via the
  adapter; `LabanDebugTests` pass unchanged (same wire, incl. `image/png` and
  `x-asciicast` bodies); `DebugHTTPServer` is deleted; `scripts/check` stays green.
- **1D:** `scripts/check` regenerates `schemas/` + discovery from the catalog and
  fails on any intent missing a schema or capability.

## Progress

Milestone 1A — Registry backbone (LabanCore):
- [ ] `Sources/LabanCore/Intents/` added: `Capability`, `DataSensitivity`, `Intent`, `Query`, `IntentResult`, `QueryResult`, `ControlArtifact`, `IntentDescriptor` (incl. `availability`), `IntentCatalog`, `IntentRouter`, `SchemaNode`/`JSONSchemaProviding`.
- [ ] All cross-target types are `public` with explicit `public init`s; AppKit-free.
- [ ] `IntentCatalog.shared` + `.fixture` seeded with the starter set; descriptors carry capability + availability + `JSONSchemaProviding` payloads.
- [ ] `Tests/LabanCoreTests/IntentCatalogTests.swift` (well-formedness, uniqueness, fixture/availability tagging, schema-presence-once-1D).
- [ ] `swift test --filter IntentCatalogTests` passes; no AppKit import in `Sources/LabanCore/Intents`.

Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter (wire-preserving):
- [ ] `LabanControl` target in `Package.swift` (deps `["LabanCore"]`); `LabanApp` depends on it; `Tests/LabanControlTests` target added.
- [ ] Phase 0 server relocated into `LabanControl` with **public** API (`LabanControlServer`, `init`, `start`, `stop`, `GuardOutcome`, `ControlAdvertisement`); generalized to a route-table HTTP↔Intent adapter returning `ControlResponse`.
- [ ] `LiveIntentRouter` (LabanApp) conforms to `IntentRouter`; the adapter serializes the **exact** `ControlState` / `ControlActionResult` JSON.
- [ ] Phase 0 tests pass against the relocated server (`@testable import LabanControl` where needed); `LabanControl` AppKit-free.

Milestone 1C — Re-point the full debug surface through the adapter:
- [ ] Shared request payloads converted to **public** `Codable, Sendable, Equatable` and relocated to `LabanCore`; exhaustive `DebugAction ↔ Intent` mapping (no `default`).
- [ ] `HeadlessIntentRouter` (LabanDebug) added; `laban-agent` mounts the `LabanControl` server with `surface: .headless`.
- [ ] `IntentDescriptor.availability` populated per route (shared / headlessOnly / fixtureOnly / guiFuture); the server rejects surface-unavailable routes **before** dispatch.
- [ ] Binary routes (`screenshot`, `cast`, others) flow through `ControlArtifact` → `ControlResponse` (content-type + headers preserved).
- [ ] **`check-debug-contract` rewritten to read the new route table/catalog BEFORE `DebugHTTPServer.swift` is deleted** (CI green throughout).
- [ ] All 45 routes ported; `DebugHTTPServer.swift` deleted; `Tests/LabanDebugTests` pass unchanged; catalog-parity test (over `gui && headless` descriptors) added.

Milestone 1D — Generate discovery + schemas from the catalog:
- [ ] Generator emits deterministic JSON Schemas (from `JSONSchemaProviding`) + the discovery doc from `IntentCatalog`; wired into `scripts/check` as regenerate-and-diff.
- [ ] Gate fails on any descriptor missing `inputSchema`/`outputSchema` or `requiredCapability`.
- [ ] Generated `schemas/control/*.json` + discovery committed; `scripts/check` green.

## Context and Orientation

You need no prior Laban knowledge. Key terms and the files where they live:

- **`LabanApp`** — windowed macOS app (`Sources/LabanApp/`, AppKit). **`LabanCore`**
  — AppKit-free model/session library; `AppModel` (`Sources/LabanCore/AppModel.swift`)
  is the internally-locked (`withModelLock`) tab/session state. **`LabanDebug`** —
  AppKit-free library holding the HTTP server + offscreen runtime today.
  **`LabanControl`** — *new this phase*: AppKit-free library for the server, HTTP↔
  Intent adapter, policy, `control.json` writer, and catalog→schema generator;
  depends only on `LabanCore`.
- **Phase 0 seam** (`Sources/LabanApp/Control/`, shipped, currently `internal`):
  - `ControlRouter.swift` — `ControlTabState`, `ControlState`, `ControlActionResult`
    (`{ ok: Bool; activeTabId: String?; error: String? }`), `protocol ControlRouter`.
  - `LiveIntentRouter.swift` — implements `ControlRouter` over a weak `AppModel`.
  - `LabanControlServer.swift` — `enum GuardOutcome { ok, unauthorized, forbidden }`;
    `final class LabanControlServer` (`start`, `stop`, `static evaluateGuard`, a
    hardcoded two-route switch). **Correct `Host`/`Origin` security; minimal routes.**
  - `ControlAdvertisement.swift` — `0600` `O_EXCL`-then-`rename` `control.json` writer.
  - Mounted in `MainWindowController.makeAndShow` (~lines 509–527) behind
    `LABAN_CONTROL_SERVER=1`.
- **`DebugHTTPServer`** (`Sources/LabanDebug/DebugHTTPServer.swift`) — the headless
  server: **45** routes in `private static let routes: [DebugHTTPRoute]`, each
  `DebugHTTPRoute(method:path:category:summary:requestSchema?:responseSchema?) { runtime, request, headers -> HTTPResponse }`.
  **Rich route table; checks only the host *parameter*, not the request
  `Host`/`Origin` headers.** Holds `private let runtime: HeadlessDebugRuntime`;
  started from `Sources/LabanAgent/main.swift` (~251–257).
- **`DebugAction`** (`Sources/LabanDebug/DebugRuntimeRequests.swift`, lines 8–36) —
  the `/debug/actions` vocabulary: **28** `internal Decodable` cases (newTab,
  closeTab, selectTab, setTabTitle, freezeTabTitle, clearTabTitle, setTabMetadata,
  moveTab, resizeWindow, setFontSize, typeText, **feedOutput**, **advanceFrames**,
  setClipboardText, setSelection, findStart/Step/Stop, copy, paste, dropFiles,
  scrollViewport, mouseWheel, mouseDrag, click, key, **windowFocus**,
  unsupported(String)). Each carries an **`internal` request struct** (17 such
  structs, mostly `Decodable`). Dispatched via
  `DebugRuntimeActions.applyActionUnlocked(_ action: DebugAction) -> DebugResponse`.
- **Legacy wire result DTOs (must be byte-stable):**
  - GUI `POST /debug/actions` → `ControlActionResult { ok, activeTabId, error }`
    (Phase 0); GUI `GET /debug/state` → `ControlState { tabs, activeTabId }`.
  - Headless `POST /debug/actions` → `ActionResult` (`Sources/LabanDebug/DebugModels.swift:189`):
    **`{ ok: Bool; frame: Int; activeTabId: String?; activeSessionId: String?; error: String? }`**
    — note `frame` and `activeSessionId` that the GUI shape lacks.
  - `GET /debug/screenshot` → `image/png` + `X-App-Frame`/`X-App-Size` headers.
    `GET /debug/cast/recent` → `application/x-asciicast` + headers.
- **`AppCommand`** (`Sources/LabanApp/TerminalInputView.swift:7`) — GUI app-command
  enum, dispatched by `executeAppCommand(_:)` (`TerminalBitmapView.swift:~3843`);
  overlaps the `DebugAction` set.
- **`DebugDiscoveryCatalog`** + `discovery()` (`Sources/LabanDebug/DebugDiscoveryEndpoints.swift`)
  — hand-curated action/wait/fixture/example lists assembled into `GET /debug`.
- **`check-debug-contract`** (`scripts/check-debug-contract`, Python; always run by
  `scripts/check`) — checks that endpoints documented in
  `docs/process/dev-process.md` appear in `DebugHTTPServer.routes`, and that
  `requestSchema`/`responseSchema` paths named there exist under `schemas/`. It is
  a presence/consistency check, **not** a full route↔doc↔schema validator, and
  **not** a generator. It reads `DebugHTTPServer.swift` directly by regex.
- **`schemas/debug/*.schema.json`** — 33 hand-written JSON Schemas.
- `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. `LabanCore` deps
  `["LabanTerminalCore","LabanRenderer"]`; `LabanDebug` deps `["LabanCore",
  "LabanRenderer","LabanTerminalCore"]`; `LabanApp`/`LabanAgent`/`Laband` depend on
  `LabanDebug`.

---

## Cross-cutting design contracts (read first)

These five rules apply to every milestone. They exist because the existing surface
has constraints a naive "everything is JSON through one result type" carve would
break.

**C1 — Domain results vs wire DTOs are separate.** `IntentResult` and `QueryResult`
(LabanCore) are *internal domain* shapes. The HTTP adapter (LabanControl) maps them
onto the **exact existing wire DTOs** and must not change field names, order, or
presence:

- GUI `/debug/actions` serializes `ControlActionResult { ok, activeTabId, error }`.
- Headless `/debug/actions` serializes `ActionResult { ok, frame, activeTabId, activeSessionId, error }`.
- GUI `/debug/state` serializes `ControlState`; headless `/debug/state` serializes
  its existing `StateResponse`.

So the adapter is wire-shape-aware per route/surface. A future versioned API change
may unify them; Phase 1 does not. Acceptance asserts the JSON fields are unchanged.

**C2 — Not every response is JSON.** The adapter route handler returns a transport
type, `ControlResponse { status, contentType, headers, body: Data }` (LabanControl).
JSON routes wrap a `QueryResult`/DTO; **binary routes** (`screenshot` → `image/png`,
`cast` → `application/x-asciicast`) return a `ControlArtifact { contentType,
headers, body }` from the router, which the adapter passes through verbatim
(content-type + headers preserved). The `IntentRouter` therefore has three legs:
`route(Intent) -> IntentResult`, `query(Query) -> QueryResult`, and
`artifact(ArtifactRequest) -> ControlArtifact?`.

**C3 — Explicit access control across the module boundary.** Everything used across
targets must be `public` with an explicit `public init` (Swift's memberwise init is
internal). This includes: relocated `LabanControlServer` (+ `init`/`start`/`stop`),
`GuardOutcome`, `ControlAdvertisement`, and every LabanCore payload/result struct.
Request structs relocated from `LabanDebug` (currently `internal Decodable`) become
`public Codable, Sendable, Equatable` with `public init`. Tests use
`@testable import` only where a non-public seam is genuinely needed; otherwise rely
on public API + a test-target dependency.

**C4 — Schemas come from explicit definitions, not reflection.** Swift cannot
reflect a `Codable` type into JSON Schema without macros/third-party libraries (and
this plan adds no third-party packages). So each `Intent`/`Query` payload conforms
to `JSONSchemaProviding { static var jsonSchema: SchemaNode { get } }`, where
`SchemaNode` is a tiny hand-authored schema DSL in LabanCore (object/string/integer/
number/boolean/array/optional/enum). The 1D generator walks the catalog, reads each
payload's `jsonSchema`, and emits **deterministic** JSON (sorted keys). Schemas are
authored, catalog-bound, and machine-emitted — never inferred.

**C5 — Capability is *classified*, not *enforced*, in Phase 1.** Phase 1 keeps Phase
0's single opt-in bearer token (server off unless `LABAN_CONTROL_SERVER=1`; loopback
+ `Host`/`Origin` guard reused verbatim). It does **not** implement ADR 0024 token
tiers (observe/control/sensitive/fixture tokens) — that is Phase 2's "security floor
+ flip." Descriptors carry `requiredCapability` and `availability` as *metadata*.
Fixture/headless-only operations are kept off the live surface **structurally** —
they live in `IntentCatalog.fixture` (not `.shared`), have `availability.gui ==
false`, the GUI router does not implement them, and the server's availability check
(C/availability) rejects them on the GUI surface — **not** by token-tier auth. The
plan must not claim ADR 0024 enforcement.

---

## Milestone 1A — Registry backbone in `LabanCore` (no endpoint moves)

**Scope.** Add the typed vocabulary, the catalog, the schema DSL, and the transport-
neutral result/artifact types to `LabanCore`. Touch no server, no endpoint, no
`Package.swift`. Pure, additive, AppKit-free, all-`public`.

### Plan of Work (1A)

Add files under `Sources/LabanCore/Intents/`. Reference skeletons (finalize fields
during implementation; all types `public` with `public init`):

    // Capability.swift
    public enum Capability: String, Codable, CaseIterable, Sendable {
      case observe, observeSensitive, control, clipboard, fixture
    }
    // DataSensitivity.swift
    public enum DataSensitivity: String, Codable, Sendable {
      case none, nonSensitiveState, visibleText, scrollback, keystrokes, clipboard, screenshot, trace
    }

    // SchemaNode.swift  (C4 — hand-authored schema DSL)
    public indirect enum SchemaNode: Sendable {
      case object(properties: [String: SchemaNode], required: [String])
      case string(enumValues: [String]?)
      case integer, number, boolean
      case array(SchemaNode)
      case optional(SchemaNode)            // nullable
      public func toJSONSchema() -> [String: Any]   // deterministic; 1D serializes sorted-keys
    }
    public protocol JSONSchemaProviding { static var jsonSchema: SchemaNode { get } }

    // Intent.swift  (grows one case per ported route in 1C)
    public enum Intent: Codable, Sendable, Equatable {
      case tabSelect(TabSelectInput)        // id "tab.select"
      case terminalTypeText(TypeTextInput)  // id "terminal.typeText"
      case terminalSendKey(SendKeyInput)    // id "terminal.sendKey"
      public var id: String { … }
    }
    public struct TabSelectInput: Codable, Sendable, Equatable, JSONSchemaProviding {
      public var tabId: String?; public var index: Int?
      public init(tabId: String? = nil, index: Int? = nil) { … }
      public static var jsonSchema: SchemaNode { .object(properties: ["tabId": .optional(.string(enumValues: nil)), "index": .optional(.integer)], required: []) }
    }
    public struct TypeTextInput: Codable, Sendable, Equatable, JSONSchemaProviding { public var sessionId: String?; public var text: String; public init(…); public static var jsonSchema: SchemaNode { … } }
    public struct SendKeyInput: Codable, Sendable, Equatable, JSONSchemaProviding { … }

    // Query.swift
    public enum Query: Codable, Sendable, Equatable { case state; public var id: String { "app.state" } }
    public enum QueryResult: Codable, Sendable { case state(TabsState) }   // grows in 1C
    public struct TabsState: Codable, Sendable, Equatable { public struct Tab: Codable, Sendable, Equatable { public let id: String; public let index: Int; public let active: Bool; public let sessionId: String?; public init(…) }; public let tabs: [Tab]; public let activeTabId: String?; public init(…) }

    // IntentResult.swift  (C1 — DOMAIN result; adapter maps to wire DTOs)
    public struct IntentResult: Sendable, Equatable {
      public let ok: Bool
      public let actedTabId: String?; public let actedSessionId: String?
      public let frame: Int?                 // carried so the headless ActionResult wire shape is reconstructable
      public let eventId: String?; public let error: IntentError?
      public static func success(actedTabId: String? = nil, actedSessionId: String? = nil, frame: Int? = nil, eventId: String? = nil) -> IntentResult
      public static func failure(_ code: String, _ message: String) -> IntentResult
    }
    public struct IntentError: Sendable, Equatable { public let code: String; public let message: String; public init(…) }

    // ControlArtifact.swift  (C2 — binary read result)
    public struct ControlArtifact: Sendable { public let contentType: String; public let headers: [String: String]; public let body: Data; public init(…) }
    public struct ArtifactRequest: Sendable { public let id: String; public let params: [String: String]; public init(…) }

    // IntentRouter.swift  (generalizes Phase 0's ControlRouter; three legs per C2)
    public protocol IntentRouter: AnyObject {
      func route(_ intent: Intent) -> IntentResult
      func query(_ query: Query) -> QueryResult
      func artifact(_ request: ArtifactRequest) -> ControlArtifact?   // nil ⇒ unsupported on this router
    }

    // IntentDescriptor.swift  (design §4.2 + availability, C5)
    public struct IntentDescriptor: Sendable, Equatable {
      public enum Kind: String, Sendable { case query, action, wait, event, artifact }
      public let id: String; public let kind: Kind; public let category: String; public let summary: String
      public let requiredCapability: Capability; public let dataSensitivity: DataSensitivity
      public struct SideEffects: Sendable, Equatable { public var ptyInput=false; public var lifecycle=false; public var clipboard=false; public var filesystem=false; public var network=false; public init() {} }
      public let sideEffects: SideEffects
      public struct Risk: Sendable, Equatable { public enum Level: String, Sendable { case none, low, medium, high }; public let level: Level; public let reason: String }
      public let risk: Risk
      public enum Audit: String, Sendable { case none, metadataOnly, redactedInput, fullInput }; public let audit: Audit
      public struct Availability: Sendable, Equatable { public let gui: Bool; public let headless: Bool; public init(gui: Bool, headless: Bool) }
      public let availability: Availability            // C5 / route-availability matrix
      public struct Transports: Sendable, Equatable { public let http: Bool; public let mcp: Bool; public let cli: Bool }
      public let transports: Transports
      public let inputSchema: String?; public let outputSchema: String?; public let errorSchema: String?   // filled by 1D generation
      public init(…)
    }

    // IntentCatalog.swift
    public struct IntentCatalog: Sendable {
      public let descriptors: [IntentDescriptor]
      public func descriptor(id: String) -> IntentDescriptor?
      public var ids: Set<String>
      public func sharedIds() -> Set<String>            // availability.gui && availability.headless
      public func validate() throws                     // dup ids, empty summary; 1D adds schema-presence
      public static let shared: IntentCatalog
      public static let fixture: IntentCatalog          // .fixture, availability.gui == false
      public init(_ descriptors: [IntentDescriptor])
    }

Seed `.shared` with `app.state` (query, `.observe`, `availability(gui:true,
headless:true)`), `tab.select` (action, `.control`, lifecycle), `terminal.typeText`
(action, `.control`, `ptyInput`, risk `.medium`, sensitivity `.keystrokes`, audit
`.redactedInput`), `terminal.sendKey`. Leave `.fixture` empty (populated in 1C).

### Concrete Steps (1A)

1. Create the files above under `Sources/LabanCore/Intents/`.
2. Add `Tests/LabanCoreTests/IntentCatalogTests.swift` (Validation 1A).
3. `swift build && swift test --filter IntentCatalogTests` → `0 failures`.
4. `grep -rn "import AppKit\|import Cocoa" Sources/LabanCore/Intents || echo clean` → `clean`.

### Acceptance (1A)

`IntentCatalogTests` asserts: `validate()` does not throw; ids unique/non-empty;
every starter `Intent.id`/`Query.id` has a descriptor and vice versa (from a
hardcoded starter-id list, so enum↔catalog drift fails); no `availability.gui`
descriptor requires `.fixture`; every `.fixture`-catalog descriptor has
`availability.gui == false`; each starter payload's `jsonSchema.toJSONSchema()`
produces a non-empty object. Break any invariant → the matching assertion fails.

---

## Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter (wire-preserving)

**Scope.** Create `LabanControl`; relocate the Phase 0 server into it with **public**
API (C3); generalize it into a declarative route-table HTTP↔Intent adapter returning
`ControlResponse` (C2); reimplement `LiveIntentRouter` against `IntentRouter`. The
adapter serializes the **exact** Phase 0 `ControlState`/`ControlActionResult` JSON
(C1). `DebugHTTPServer` is untouched this milestone.

### Concrete Steps (1B)

1. **`Package.swift`:** after `LabanCore`, add
   `.target(name: "LabanControl", dependencies: ["LabanCore"])`; append
   `"LabanControl"` to `LabanApp.dependencies`; add
   `.testTarget(name: "LabanControlTests", dependencies: ["LabanControl", "LabanCore"])`.
2. **Relocate** `LabanControlServer.swift`, `GuardOutcome`, `ControlAdvertisement.swift`
   from `Sources/LabanApp/Control/` to `Sources/LabanControl/`. Make them `public`
   (class, `init`, `start`, `stop`, `evaluateGuard`, the enum, the advertisement
   funcs). Keep `start`/`stop`/`evaluateGuard`/token/socket bodies verbatim — the
   security is correct and must not change.
3. **Generalize the server:** replace the hardcoded `route(method:path:)` switch with
   a declarative `[ControlRoute]` table — `ControlRoute(method, path, descriptorId?,
   handler: (IntentRouter, HTTPRequest) -> ControlResponse)`. Add
   `public struct ControlResponse { status; contentType; headers; body }` with
   `.json(_:)` and `.binary(_:contentType:headers:)` helpers. The server takes a
   `public init(router: IntentRouter, surface: Surface, catalog: IntentCatalog)`
   (`Surface` = `.gui`/`.headless`); on each request, after the guard, it looks up
   the descriptor and **rejects (404 `{"error":"unavailable on \(surface)"}`) if the
   route is not available on this surface** (C5).
4. **1B route table (2 entries, adapter style):**
   `GET /debug/state` → `router.query(.state)` → serialize as the existing
   `ControlState` JSON via `.json`. `POST /debug/actions` → decode `{"action":...}`;
   for `"selectTab"` build `Intent.tabSelect`, call `router.route`, **map
   `IntentResult` → `ControlActionResult { ok, activeTabId, error }` JSON** (C1).
5. **`LiveIntentRouter`** (stays in `LabanApp`) now conforms to `IntentRouter`:
   `query(.state)` builds `TabsState`→ the `ControlState` projection from the live
   `AppModel`; `route(.tabSelect)` does the bounds-checked `model.selectTab` on the
   main thread (exact Phase 0 behavior); `artifact(_)` returns `nil`; all other
   intents → `IntentResult.failure("unsupported", …)`.
6. **Mount:** `MainWindowController.makeAndShow` imports `LabanControl`, builds
   `LiveIntentRouter`, and starts the relocated server with `surface: .gui` (the
   `LABAN_CONTROL_SERVER=1` block otherwise unchanged).
7. Relocate `ControlServerPhase0Tests` to `Tests/LabanControlTests/` (or keep in
   `LabanAppTests` with `import LabanControl`); use `@testable import LabanControl`
   only if a non-public seam is needed.
8. `swift build && swift test --filter ControlServerPhase0Tests` → `0 failures`;
   `./scripts/build-app`.

### Acceptance (1B)

`LabanControl` builds; `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl`
is empty. Phase 0 tests pass: guard matrix; `GET /debug/state` → 200 with the
**identical** `ControlState` JSON; no token → 401; forged `Host` → 403; `selectTab`
→ `ControlActionResult.ok == true` and `activeTabId` changes. Operator-launched GUI
still serves `control.json` and switches tabs. `Sources/LabanApp/Control/` no longer
holds the server/advertisement.

---

## Milestone 1C — Re-point the full debug surface through the adapter

**Scope.** Move all 45 `DebugHTTPServer` routes into `LabanControl`'s table, group by
group, every handler going through `Intent`/`Query`/`ControlArtifact` + an
`IntentRouter`, preserving every wire shape (C1) and binary body (C2). Provide
`HeadlessIntentRouter`. Populate the availability matrix. Rewrite the contract
checker before deleting `DebugHTTPServer`. Retire `DebugHTTPServer`.

### Concrete Steps (1C)

1. **Relocate request payloads:** move the 17 request structs from
   `DebugRuntimeRequests.swift` to `LabanCore`; make them
   `public Codable, Sendable, Equatable` with `public init` and `JSONSchemaProviding`
   (C3/C4). `DebugAction`'s decoder stays in `LabanDebug` but its associated values
   reference the relocated public structs.
2. **Exhaustive mapping:** add `Intent(from: DebugAction)` (or a `DebugAction.asIntent`)
   as a `switch` with **no `default`** (a new `DebugAction` then fails to compile
   until mapped). Fixture-only cases (`feedOutput`, `advanceFrames`, `windowFocus`,
   title-forcing) map into `IntentCatalog.fixture` ids, never `.shared`.
3. **`HeadlessIntentRouter`** (in `LabanDebug`) conforms to `IntentRouter`: `route`
   translates `Intent` → the existing `HeadlessDebugRuntime` calls (via
   `applyActionUnlocked`); `query` → `runtime.state()`/etc.; `artifact` →
   `runtime.screenshotBytes()`/cast bytes wrapped in `ControlArtifact`. Its
   `/debug/actions` mapping serializes **`ActionResult { ok, frame, activeTabId,
   activeSessionId, error }`** (C1), distinct from the GUI's `ControlActionResult`.
4. **`laban-agent`** (`Sources/LabanAgent/main.swift`) mounts the `LabanControl`
   server (`surface: .headless`) with `HeadlessIntentRouter` instead of constructing
   `DebugHTTPServer`.
5. **Availability matrix:** give each ported descriptor an `availability`. Phase-1
   reality: state/sessions/actions/wait/find/selection/shell-integration/clipboard/
   events/journal/logs/metrics → `gui:true, headless:true` (shared). `feedOutput`/
   `advanceFrames`/`windowFocus`/fixture control → `.fixture`, `gui:false`. Render/
   pixel/atlas/screenshot/render-trace/capture/persistence → `gui:false, headless:true`
   for Phase 1 (GUI-truthful Metal readback + GUI capture are deferred to design
   Phase 6); the server rejects these on the `.gui` surface (C5/step server-check).
6. **Binary routes:** `screenshot`, `cast`, and any other non-JSON route resolve
   through `router.artifact(_)` → `ControlArtifact` → `.binary` `ControlResponse`,
   preserving `image/png`/`x-asciicast` content-type and `X-App-*` headers.
7. **Port in reviewable groups** (readers → actions → find/selection/shell/clipboard
   → render/screenshot/atlas/pixel → events/journal/logs/metrics → capture/
   persistence/fixture/cast/artifact). After each group, the matching
   `Debug*Endpoints` serializer becomes a `QueryResult`/`ControlArtifact` builder.
8. **Rewrite `check-debug-contract` BEFORE deleting `DebugHTTPServer`** so
   `scripts/check` never goes red: point it at the new `LabanControl` route table +
   `IntentCatalog` (validate documented endpoints ↔ catalog ids ↔ schema refs).
   Land this in the same change that ports the last group.
9. **Delete `DebugHTTPServer.swift`** and the now-dead `DebugDiscoveryCatalog`
   hand-lists. Add `Tests/.../CatalogParityTests.swift`: enumerate
   `IntentCatalog.shared.sharedIds()`; assert both `LiveIntentRouter` and
   `HeadlessIntentRouter` handle each (no `unsupported`). It enumerates only
   `gui && headless` descriptors, so headless-only routes are not parity-required.

### Acceptance (1C)

`grep -rn "class DebugHTTPServer" Sources` empty. `Tests/LabanDebugTests`
(`LabanDebugSmokeTests`, `LabanDebugExploratoryControlTests`) pass with assertions
unchanged (only construction/imports updated) — same JSON fields, same `image/png`
and `x-asciicast` bodies + headers. `scripts/check` (incl. the rewritten
`check-debug-contract`, smoke-runtime, test-e2e) is green. Catalog-parity test fails
if either router drops a shared intent (verify by temporarily removing a case). A
`.fixture` id (e.g. `feedOutput`) is rejected on the `.gui` surface and accepted on
`.headless`; a `gui:false` render route is rejected on `.gui`.

---

## Milestone 1D — Generate discovery + schemas from the catalog

**Scope.** Make `IntentCatalog` the *source* of `schemas/control/*` and the discovery
doc, via the `JSONSchemaProviding` definitions (C4), and gate it.

### Concrete Steps (1D)

1. Add a generator (small `executableTarget` `LabanControlGen` depending on
   `LabanControl`, run by a script). For each `IntentCatalog.shared` + `.fixture`
   descriptor: emit `schemas/control/<id>.input.json`, `.output.json`, `.error.json`
   from the payload's `SchemaNode.toJSONSchema()`, serialized with
   `JSONSerialization`/`.sortedKeys` (**deterministic**). Fill the descriptor's
   `inputSchema`/`outputSchema`/`errorSchema` ref strings.
2. Emit the discovery document (`GET /debug` body — endpoints, actions, wait
   conditions, fixture actions, capabilities, examples) from the catalog.
3. Wire into `scripts/check`: regenerate to a temp dir and `diff` against committed
   `schemas/control/` + discovery; **fail on any diff** (committed must match the
   catalog) and **fail if any descriptor lacks a schema ref or `requiredCapability`**.
   Extend `IntentCatalog.validate()` to assert schema-ref presence; call it from the
   gate.
4. Commit the generated artifacts (generated, like `.rpg/graph.json`).

### Acceptance (1D)

Generator is idempotent (second run → no `git diff`). Deleting a generated schema →
`scripts/check` fails until regenerated. Adding a descriptor without a capability →
`scripts/check` fails with a clear message. `scripts/check` green with artifacts
committed.

---

## Validation and Acceptance

Per-milestone acceptance is above. Overall, Phase 1 is done when, from the repo root:

    swift test --filter IntentCatalogTests        # 1A
    swift test --filter ControlServerPhase0Tests  # 1B — Phase 0 wire preserved
    swift test --filter LabanDebug                 # 1C — full surface + binary wire preserved
    swift test --filter CatalogParityTests         # 1C
    ./scripts/check                                 # contract-checker green THROUGHOUT; 1D generation gated
    ./scripts/build-app

…all pass, **and**: one `IntentCatalog` is the single vocabulary (enum↔catalog drift
fails tests); one server lives in `LabanControl`, mounted by GUI + `laban-agent`;
`grep -rn "class DebugHTTPServer" Sources` is empty; `LabanControl` + `LabanCore/
Intents` are AppKit-free; legacy JSON shapes (`ControlActionResult`, `ActionResult`
with `frame`/`activeSessionId`, `ControlState`) and binary bodies (`image/png`,
`x-asciicast`) are byte-identical; surface-unavailable routes are rejected; discovery
+ schemas are generated and gated.

## Decision Log

- Decision: deliver Phase 1 as four self-contained, independently-reviewable
  milestones with concrete steps each (not "1A now, the rest later").
  Rationale: `PLANS.md` requires end-to-end executability; the roadmap prescribes the
  1A–1D split; carving 45 routes in one PR is unreviewable.
  Date/Author: 2026-06-20 / Claude.
- Decision: registry **types** in `LabanCore`; **server/adapter/policy/generator** in
  new `LabanControl`; **live router** in `LabanApp`; **headless router** in
  `LabanDebug`. (ADR 0023.)
  Date/Author: 2026-06-20 / Claude.
- Decision (C1): keep transport DTOs separate from domain results; the adapter
  serializes the exact existing wire shapes (`ControlActionResult` for GUI,
  `ActionResult{ok,frame,activeTabId,activeSessionId,error}` for headless), per
  surface, byte-stable. `IntentResult`/`QueryResult` are internal-domain.
  Rationale: "tests pass unchanged" is only true if the wire is unchanged; the GUI
  and headless `/debug/actions` shapes already differ.
  Date/Author: 2026-06-20 / Claude.
- Decision (C2): introduce `ControlResponse` + `ControlArtifact`; `IntentRouter` has
  an `artifact(_)` leg so `screenshot` (`image/png`) and `cast` (`x-asciicast`)
  preserve content-type and headers — JSON-only `QueryResult` cannot model them.
  Date/Author: 2026-06-20 / Claude.
- Decision (C3): everything crossing the new module boundary is `public` with
  explicit `public init`; relocated request structs become `public Codable, Sendable,
  Equatable`; tests use `@testable import` only where unavoidable.
  Rationale: the Phase 0 server and the request structs are `internal` today and will
  not compile from another target after relocation.
  Date/Author: 2026-06-20 / Claude.
- Decision (C4): schemas come from a hand-authored `SchemaNode` DSL +
  `JSONSchemaProviding`, emitted deterministically — not reflected from `Codable`
  (Swift cannot, and no third-party packages are added).
  Date/Author: 2026-06-20 / Claude.
- Decision (C5): Phase 1 retains Phase 0's single opt-in token and does **not**
  implement ADR 0024 token tiers (Phase 2). Capabilities/availability are classified
  metadata; fixture/headless-only ops are kept off the live surface structurally
  (catalog membership + `availability.gui==false` + server availability check + the
  router not implementing them), not by token auth.
  Rationale: the original draft over-claimed ADR 0024 enforcement.
  Date/Author: 2026-06-20 / Claude.
- Decision (P1-8): the `check-debug-contract` rewrite lands in 1C *before*
  `DebugHTTPServer.swift` is deleted, so `scripts/check` (which always runs it) stays
  green at every milestone boundary.
  Date/Author: 2026-06-20 / Claude.
- Decision: per-route availability matrix (shared / headlessOnly / fixtureOnly /
  guiFuture); the server rejects surface-unavailable routes before dispatch; the
  parity test enumerates only `gui && headless` descriptors.
  Rationale: many headless routes (render-trace, pixel-probe, atlas, screenshot,
  capture, persistence) need Metal readback or GUI plumbing deferred to design Phase
  6; they are headless-only in Phase 1, not parity-required.
  Date/Author: 2026-06-20 / Claude.
- Decision: keep the `/debug/*` path namespace through Phase 1; the product
  `/control` namespace is Phase 2 (design §4.4).
  Date/Author: 2026-06-20 / Claude.

## Review Gate

A fresh-state agent verifies the following (mechanical checks; run from repo root):

- [ ] `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl Sources/LabanCore/Intents` → nothing.
- [ ] `Package.swift`: `LabanControl` deps exactly `["LabanCore"]`; `LabanApp`/`LabanAgent`/`LabanDebug` list `"LabanControl"`.
- [ ] `grep -rn "class DebugHTTPServer" Sources` → nothing (after 1C).
- [ ] Wire-shape preserved: `LabanDebugTests` assertions for `/debug/actions` still expect `frame` and `activeSessionId`; the GUI `/debug/actions` test still decodes `ControlActionResult` (no `frame`). Both suites pass.
- [ ] Binary preserved: a screenshot test asserts `Content-Type: image/png` and an `X-App-Frame` header; a cast test asserts `application/x-asciicast`.
- [ ] The `DebugAction → Intent` mapping `switch` has no `default` clause.
- [ ] Access control: relocated `LabanControlServer`/`init`/`start`/`stop`/`GuardOutcome`/`ControlAdvertisement` are `public`; relocated request structs are `public … Codable`.
- [ ] Availability enforced: a request for a `gui:false` route on the `.gui` surface returns the unavailable error before dispatch.
- [ ] Parity real: make `LiveIntentRouter` return `unsupported` for one `gui&&headless` intent → `CatalogParityTests` fails; revert.
- [ ] No reflection: `grep -rni "Mirror(\|reflect" Sources/LabanControl Sources/LabanCore/Intents` → nothing; schemas come from `JSONSchemaProviding`.
- [ ] 1D idempotent: run the generator twice → no `git diff` under `schemas/control/`; delete one schema → `./scripts/check` fails; restore → passes.
- [ ] `./scripts/check` exits 0; no third-party package added to `Package.swift`.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- 1A is additive; `swift test` reruns are safe and leave no artifacts.
- Each 1C route-group port is small and revertible; a half-ported route surfaces as a
  missing catalog entry or a failing parity/`LabanDebugTests` case. The contract
  checker is rewritten before the deletion, so reverting a bad group never strands CI.
- 1D generation writes only under `schemas/control/` + the discovery doc and is
  deterministic (sorted keys), so reruns are no-ops; a stale file is fixed by
  re-running the generator.
- The new `LabanControl` target adds no runtime behavior until mounted (1B); until
  then the shipped GUI and CI are untouched, so partial progress is safe.

## Interfaces and Dependencies

End-state package graph (additions in **bold**):

    LabanCore         deps [LabanTerminalCore, LabanRenderer]    + Sources/LabanCore/Intents/* + relocated public request structs
    **LabanControl**  deps [LabanCore]                           server (route-table HTTP↔Intent adapter, ControlResponse), policy,
                                                                  ControlAdvertisement, catalog→schema generator
    LabanDebug        deps [LabanCore, **LabanControl**, LabanRenderer, LabanTerminalCore]   HeadlessIntentRouter, HeadlessDebugRuntime, fixtures
    LabanApp          deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   LiveIntentRouter; mounts server (surface: .gui)
    LabanAgent        deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   mounts server (surface: .headless)
    **LabanControlGen** (executable, 1D)  deps [LabanControl]    deterministic schema + discovery generator

Key end-state types: `Intent`, `Query`, `QueryResult`, `IntentResult`,
`ControlArtifact`, `ArtifactRequest`, `Capability`, `DataSensitivity`,
`IntentDescriptor` (incl. `Availability`), `IntentCatalog`, `IntentRouter`,
`SchemaNode`, `JSONSchemaProviding` (all `LabanCore`, all `public`);
`LabanControlServer` (public route-table adapter), `ControlResponse`,
`LabanControlPolicy`, `ControlAdvertisement`, the generator (all `LabanControl`);
`LiveIntentRouter: IntentRouter` (`LabanApp`); `HeadlessIntentRouter: IntentRouter`
(`LabanDebug`). No third-party packages; `LabanControl` uses only
`Foundation`/`Darwin`/`LabanCore`.
