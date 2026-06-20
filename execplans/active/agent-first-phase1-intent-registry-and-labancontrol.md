# Phase 1: Typed Intent Registry + Carve `LabanControl`

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. It is the second executable phase of the program design in
`execplans/agent-first-terminal-design.md` (Phase 1; read §3–§5 there and ADR
0023/0024). Phase 0 shipped as
`execplans/completed/agent-first-phase0-control-seam.md` (commit `0a2a230`).

Delivered as four independently-verifiable milestones (**1A → 1D**); every
milestone has concrete steps and behavioral acceptance, so the plan is
self-contained and executable end to end per `PLANS.md`.

**Read "Cross-cutting design contracts" (C1–C8) before any milestone.** They are
the rules that keep the carve from breaking compile, wire, binary, schema,
security, and headless-launch contracts.

## Purpose / Big Picture

Today Laban has two disconnected control surfaces. The GUI users run (`LabanApp`)
hosts a *tiny* loopback server (Phase 0: `GET /debug/state`, `POST /debug/actions
{selectTab}`). The headless binary (`laban-agent`) hosts a *rich* one —
`DebugHTTPServer`, **45 routes** — against its own offscreen model. They share no
code; routes, request types, discovery, and schemas are hand-maintained twice.

After Phase 1, there is **one typed input vocabulary and one server**:

- Every operation is a typed `Intent` (action) or `Query` (read), defined once in
  `LabanCore`, listed in one `IntentCatalog` (capability, schema, sensitivity,
  surface availability) plus a `ControlRouteCatalog` (the HTTP method/path
  binding). A separate headless-only `IntentCatalog.fixture` holds test ops.
- A new `LabanControl` target hosts the one server. Its route table is an
  **HTTP↔Intent adapter**: it decodes the body into a typed `Intent`/`Query`,
  **checks availability/capability metadata by the resulting intent id**, then
  asks an injected `IntentRouter` to execute — and the **router returns a
  `ControlResponse` it encoded itself** (so each router owns its exact legacy wire
  shape and binary body).
- The GUI's `LiveIntentRouter` and the headless `HeadlessIntentRouter` implement
  the same `IntentRouter` and mount the same server. Parity is a **test**, scoped
  to the operations both actually implement.
- Discovery + `schemas/debug/*` are **generated** from the catalogs via
  hand-authored `SchemaNode` definitions (no reflection); the contract gate fails
  CI if an intent lacks a schema or capability.

**The wire is byte-stable.** Existing clients and `LabanDebugTests` see identical
responses — same JSON fields (incl. the GUI vs headless `/debug/actions`
differences and the mouse-specific shape), same `image/png`/`x-asciicast` bodies
and headers, same `/debug` discovery doc and schema paths, same
`laban-agent --debug-server=host:port` readiness JSON.

## Progress

Milestone 1A — Registry backbone (LabanCore):
- [ ] `Sources/LabanCore/Intents/` added: `Capability`, `DataSensitivity`, `Intent`, `Query`, `ControlResponse`, `ControlArtifact`, `ArtifactRequest`, `IntentDescriptor` (incl. `availability` + `SchemaNode` refs), `IntentCatalog`, `IntentRouter`, `SchemaNode`, `JSONSchemaProviding`. All `public` with `public init`; AppKit-free.
- [ ] `IntentCatalog.shared`/`.fixture` seeded with the starter set; descriptors carry capability + availability + hand-authored `SchemaNode`s.
- [ ] `Tests/LabanCoreTests/IntentCatalogTests.swift` (well-formedness, uniqueness, availability/fixture tagging, schema-node presence).
- [ ] `swift test --filter IntentCatalogTests` passes; no AppKit import in `Sources/LabanCore/Intents`.

Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter (wire-preserving, dual-surface server):
- [ ] `LabanControl` target (deps `["LabanCore"]`); `LabanApp` depends on it; `Tests/LabanControlTests` added.
- [ ] Phase 0 server relocated into `LabanControl`, **public**, generalized to a route-table adapter; gains `start(host:port:) -> DebugReadiness` plus the GUI ephemeral path; limits raised to 64 KiB/4 MiB.
- [ ] `LiveIntentRouter` conforms to `IntentRouter` (returns `ControlResponse` encoding the exact `ControlState`/`ControlActionResult` JSON); adapter checks availability by intent id before dispatch.
- [ ] Phase 0 tests pass against the relocated server; `LabanControl` AppKit-free.

Milestone 1C — Re-point the full debug surface through the adapter:
- [ ] **All** request body payloads used by relocated handlers (action + non-action: `WaitRequest`/`WaitCondition`, `RenderTraceRequest`/`PixelProbeReq`, `CaptureStartRequest`, fixture/persistence inputs, …) made **public `Codable, Sendable, Equatable` + `JSONSchemaProviding`** and relocated to `LabanCore`; exhaustive `DebugAction → Intent` map (no `default`).
- [ ] `ControlRouteCatalog` (public static HTTP bindings, incl. per-route body→intent resolver for `/debug/actions`) added; the adapter resolves the intent id, checks availability for the **current surface**, then dispatches.
- [ ] `HeadlessIntentRouter` (LabanDebug) returns `ControlResponse` encoding each route's existing DTO — `ActionResult`, and `MouseActionResult { …, mouseTracking, sent }` for mouse actions; binary via `ControlArtifact`. `laban-agent` mounts the server with `surface: .headless`.
- [ ] `availability` populated **conservatively**: `gui:true` only where `LiveIntentRouter` actually implements the op; everything else `headlessOnly`. Parity test enumerates only `gui && headless`.
- [ ] `check-debug-contract` rewritten to read `ControlRouteCatalog`/`IntentCatalog` **before** `DebugHTTPServer.swift` is deleted; all 45 routes ported; `DebugHTTPServer.swift` deleted; `Tests/LabanDebugTests` pass unchanged.

Milestone 1D — Generate discovery + schemas from the catalogs:
- [ ] Generator walks `ControlRouteCatalog` + `IntentCatalog`, emits deterministic schemas under **`schemas/debug/`** (stable paths) from `SchemaNode`s, and regenerates the `/debug` discovery doc byte-identically in structure.
- [ ] `scripts/check` regenerate-and-diff gate; fails on any descriptor missing a `SchemaNode` or `requiredCapability`. Generated artifacts committed; `scripts/check` green.

## Context and Orientation

(Define-every-term, name-every-file, as `PLANS.md` requires.)

- **`LabanApp`** — windowed macOS app (`Sources/LabanApp/`, AppKit). **`LabanCore`**
  — AppKit-free model library; `AppModel` is internally locked (`withModelLock`).
  **`LabanDebug`** — AppKit-free library holding the HTTP server + offscreen
  runtime today. **`LabanControl`** — *new*: AppKit-free, depends only on
  `LabanCore`; holds the server, HTTP↔Intent adapter, route catalog, advertisement,
  and generator.
- **Phase 0 seam** (`Sources/LabanApp/Control/`, `internal` today):
  `ControlRouter.swift` (`ControlTabState`, `ControlState`, `ControlActionResult
  { ok, activeTabId, error }`, `protocol ControlRouter`); `LiveIntentRouter.swift`;
  `LabanControlServer.swift` (`GuardOutcome`, server with `func start() throws ->
  (url, token)` — **ephemeral loopback only**, `maxHeaderBytes = 16*1024`,
  `maxBodyBytes = 1024*1024`, 5 s `SO_RCVTIMEO`; correct `Host`/`Origin` guard);
  `ControlAdvertisement.swift` (`0600` `O_EXCL`→`rename`). Mounted in
  `MainWindowController.makeAndShow` (~509–527) behind `LABAN_CONTROL_SERVER=1`.
- **`DebugHTTPServer`** (`Sources/LabanDebug/DebugHTTPServer.swift`): 45 routes in
  `DebugHTTPRoute` records (`method`, `path`, `category`, `summary`, query params,
  optional `requestSchema`/`responseSchema`; handler
  `(HeadlessDebugRuntime, HTTPRequest, headers) -> HTTPResponse`).
  `public func start(host: String, port: UInt16) throws -> DebugReadiness` (line
  542); `maxHeaderBytes = 64*1024`, `maxBodyBytes = 4*1024*1024`. Holds
  `private let runtime: HeadlessDebugRuntime`; started in
  `Sources/LabanAgent/main.swift` (~251–257) for `--debug-server=host:port`.
- **`DebugReadiness`** (`DebugModels.swift:46`, already `public`):
  `{ debugServer: String; debugToken: String; pid: Int32; runId: String }` — the
  readiness JSON `laban-agent` prints. Reuse verbatim.
- **`DebugAction`** (`DebugRuntimeRequests.swift:8-36`): **28** `internal Decodable`
  cases (incl. fixture-only `feedOutput`, `advanceFrames`, `windowFocus`), each
  with an `internal` request struct. **Non-action** `internal Decodable` request
  structs live in the same file (`WaitRequest`/`WaitCondition` 279-297,
  `RenderTraceRequest`/`PixelProbeReq` 299-312, `CaptureStartRequest` 251-254, …),
  alongside several `Encodable` response structs.
- **Legacy wire result DTOs (must be byte-stable):**
  - GUI `/debug/actions` → `ControlActionResult { ok, activeTabId, error }`; GUI
    `/debug/state` → `ControlState`.
  - Headless `/debug/actions` → **`ActionResult { ok, frame, activeTabId,
    activeSessionId, error }`** (`DebugModels.swift:189`), **except mouse actions**
    → **`MouseActionResult { ok, frame, activeTabId, activeSessionId, mouseTracking,
    sent, error }`** (`DebugModels.swift:225`). Headless `/debug/state` →
    `StateResponse`.
  - `GET /debug/screenshot` → `image/png` + `X-App-Frame`/`X-App-Size`;
    `GET /debug/cast/recent` → `application/x-asciicast` + headers.
- **`check-debug-contract`** (`scripts/check-debug-contract`, always run by
  `scripts/check`): regexes `DebugHTTPServer.swift` to check documented endpoints
  (`docs/process/dev-process.md`) are present and that referenced schema paths
  exist under `schemas/`. Presence check; not a generator. **Reads
  `DebugHTTPServer.swift` directly** — so deleting that file breaks it unless it is
  rewritten first.
- **Discovery** is assembled by hand (`DebugDiscoveryCatalog` +
  `DebugDiscoveryEndpoints.swift`) and references `schemas/debug/*.schema.json` (33
  hand-written schemas).
- `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. `LabanCore` deps
  `["LabanTerminalCore","LabanRenderer"]`; `LabanDebug` deps `["LabanCore",
  "LabanRenderer","LabanTerminalCore"]`; `LabanApp`/`LabanAgent`/`Laband` depend on
  `LabanDebug`.

---

## Cross-cutting design contracts (read first)

**C1 — The router returns the wire response; it owns its DTOs.** `IntentRouter`'s
legs return `ControlResponse` (below), which the router builds by encoding its own
existing wire DTO. This (a) keeps `LabanControl` dependent only on `LabanCore`
(the GUI DTOs stay in `LabanApp`, the headless DTOs in `LabanDebug` — neither is
imported by `LabanControl`), and (b) lets each route emit its exact legacy shape:
GUI `/debug/actions` → `ControlActionResult`; headless → `ActionResult`, **but
mouse actions → `MouseActionResult`** (extra `mouseTracking`, `sent`). No response
DTO is relocated; no single `IntentResult` shape is imposed on all actions.

**C2 — One response type, JSON and binary.** `public struct ControlResponse {
status: Int; contentType: String; headers: [String:String]; body: Data }`
(LabanCore), with `.json(_:Encodable, status:)` and `.binary(_:Data,
contentType:headers:status:)`. Binary routes (`screenshot`→`image/png`,
`cast`→`x-asciicast`) are produced by the `artifact(_)` leg and pass through
verbatim (content-type + headers preserved).

**C3 — Explicit public access + request-payload relocation.** Everything crossing
the new module boundary is `public` with an explicit `public init`: the relocated
`LabanControlServer`/`init`/`start`/`stop`, `GuardOutcome`, `ControlAdvertisement`,
and every LabanCore type. **All HTTP request body payloads decoded by the adapter**
(action *and* non-action) are relocated to `LabanCore` as `public Codable,
Sendable, Equatable` (+ `JSONSchemaProviding`). Mechanical gate: no `Decodable`
request body type used by `LabanControl` remains `internal` to `LabanDebug`. Tests
use `@testable import` only where a non-public seam is genuinely needed.

**C4 — Schemas from a hand-authored DSL, emitted into the existing namespace.**
Each payload conforms to `JSONSchemaProviding { static var jsonSchema: SchemaNode }`
(a small object/string/integer/number/boolean/array/optional/enum DSL in LabanCore).
The descriptor stores the `SchemaNode`s directly (not fill-later strings); the
generator computes ref paths and emits **into `schemas/debug/`** (the existing
namespace, so the discovery doc's schema paths stay byte-stable) with deterministic
sorted-key JSON. No reflection; no third-party packages.

**C5 — Capability is classified, not enforced, in Phase 1.** The server keeps Phase
0's single opt-in bearer token (off unless `LABAN_CONTROL_SERVER=1`; loopback +
`Host`/`Origin` guard reused verbatim). ADR 0024 token tiers are **Phase 2**.
Descriptors carry `requiredCapability`/`availability` as metadata; fixture/
headless-only ops are kept off the live surface **structurally** (see C6/C8), not by
token auth.

**C6 — Availability is checked per resolved intent, not per path.** `/debug/actions`
is one path multiplexing 28 actions to different intent ids (incl. fixture-only).
So the adapter, per request: matches `ControlRouteCatalog` (method+path) → uses the
route's **`resolveIntentId(HTTPRequest) -> String?`** (for `/debug/actions`, reads
the `action` field) → looks up the descriptor → **rejects (404
`{"error":"unavailable on \(surface)"}`) if `availability` excludes the current
surface** → only then decodes the full typed `Intent` and dispatches. Acceptance
includes `POST /debug/actions {"action":"feedOutput"}` rejected on `.gui` **before**
`LiveIntentRouter` runs.

**C7 — One server, two surfaces, max-compatible limits.** The relocated server must
serve both: the GUI (ephemeral port 0 → `control.json`) and `laban-agent`
(`--debug-server=host:port`). Add `public func start(host: String, port: UInt16)
throws -> DebugReadiness` (reuse the `DebugReadiness { debugServer, debugToken, pid,
runId }` shape verbatim) alongside the GUI ephemeral path (which maps the same
readiness into `control.json`). Raise limits to the headless maximum
(`maxHeaderBytes = 64*1024`, `maxBodyBytes = 4*1024*1024`) so large debug requests
keep working. Keep the loopback bind, token, guard, and `SO_RCVTIMEO` from Phase 0.

**C8 — Conservative GUI availability.** Mark `availability.gui == true` **only** for
operations `LiveIntentRouter` actually implements in Phase 1 (`app.state`,
`tab.select`, `terminal.typeText`, `terminal.sendKey`, and the few `AppCommand`-
backed ops it wires). Everything else (sessions detail, find, selection, render,
screenshot, capture, persistence, journal, logs, metrics, …) is `headlessOnly`
(`gui:false`) until a later phase names its GUI source of truth and acceptance test.
This bounds Phase 1's GUI scope and keeps the parity test (over `gui && headless`)
small.

---

## Milestone 1A — Registry backbone in `LabanCore` (no endpoint moves)

**Scope.** Add the typed vocabulary, `ControlResponse`/`ControlArtifact`, the schema
DSL, and the catalog to `LabanCore`. Touch no server, no `Package.swift`. Pure,
additive, AppKit-free, all-`public`.

### Plan of Work (1A)

Files under `Sources/LabanCore/Intents/` (skeletons; all `public` + `public init`):

    public enum Capability: String, Codable, CaseIterable, Sendable { case observe, observeSensitive, control, clipboard, fixture }
    public enum DataSensitivity: String, Codable, Sendable { case none, nonSensitiveState, visibleText, scrollback, keystrokes, clipboard, screenshot, trace }

    public indirect enum SchemaNode: Sendable {           // C4 — hand-authored schema DSL
      case object(properties: [String: SchemaNode], required: [String])
      case string(enumValues: [String]?); case integer; case number; case boolean
      case array(SchemaNode); case optional(SchemaNode)
      public func toJSONSchema() -> [String: Any]          // deterministic; 1D serializes sorted-keys
    }
    public protocol JSONSchemaProviding { static var jsonSchema: SchemaNode { get } }

    public struct ControlResponse: Sendable {              // C1/C2 — the universal wire result
      public var status: Int; public var contentType: String
      public var headers: [String: String]; public var body: Data
      public static func json<T: Encodable>(_ v: T, status: Int = 200) -> ControlResponse
      public static func binary(_ b: Data, contentType: String, headers: [String:String] = [:], status: Int = 200) -> ControlResponse
      public static func error(_ status: Int, _ code: String, _ message: String) -> ControlResponse
    }
    public struct ControlArtifact: Sendable { public let contentType: String; public let headers: [String:String]; public let body: Data; public init(…) }
    public struct ArtifactRequest: Sendable { public let id: String; public let params: [String:String]; public init(…) }

    public enum Intent: Sendable, Equatable {              // grows one case per ported route in 1C
      case tabSelect(TabSelectInput); case terminalTypeText(TypeTextInput); case terminalSendKey(SendKeyInput)
      public var id: String { … }
    }
    public struct TabSelectInput: Codable, Sendable, Equatable, JSONSchemaProviding {
      public var tabId: String?; public var index: Int?; public init(tabId: String? = nil, index: Int? = nil)
      public static var jsonSchema: SchemaNode { .object(properties: ["tabId": .optional(.string(enumValues: nil)), "index": .optional(.integer)], required: []) }
    }
    public struct TypeTextInput: Codable, Sendable, Equatable, JSONSchemaProviding { public var sessionId: String?; public var text: String; public init(…); public static var jsonSchema: SchemaNode { … } }
    public struct SendKeyInput: Codable, Sendable, Equatable, JSONSchemaProviding { … }

    public enum Query: Sendable, Equatable { case state; public var id: String { "app.state" } }

    public protocol IntentRouter: AnyObject {              // C1 — every leg returns ControlResponse
      func route(_ intent: Intent) -> ControlResponse
      func query(_ query: Query) -> ControlResponse
      func artifact(_ request: ArtifactRequest) -> ControlResponse?   // nil ⇒ unsupported here
    }

    public struct IntentDescriptor: Sendable {             // design §4.2 + availability + SchemaNodes
      public enum Kind: String, Sendable { case query, action, wait, event, artifact }
      public let id: String; public let kind: Kind; public let category: String; public let summary: String
      public let requiredCapability: Capability; public let dataSensitivity: DataSensitivity
      public struct SideEffects: Sendable { public var ptyInput=false; public var lifecycle=false; public var clipboard=false; public var filesystem=false; public var network=false; public init() {} }
      public let sideEffects: SideEffects
      public struct Risk: Sendable { public enum Level: String, Sendable { case none, low, medium, high }; public let level: Level; public let reason: String }
      public let risk: Risk
      public enum Audit: String, Sendable { case none, metadataOnly, redactedInput, fullInput }; public let audit: Audit
      public struct Availability: Sendable, Equatable { public let gui: Bool; public let headless: Bool; public init(gui: Bool, headless: Bool) }
      public let availability: Availability
      public struct Transports: Sendable { public let http: Bool; public let mcp: Bool; public let cli: Bool }
      public let transports: Transports
      public let inputSchema: SchemaNode?; public let outputSchema: SchemaNode?; public let errorSchema: SchemaNode?   // C4 — nodes, not fill-later strings
      public func inputSchemaRef() -> String? { inputSchema == nil ? nil : "schemas/debug/\(id).input.schema.json" }   // ref computed from id
      public init(…)
    }

    public struct IntentCatalog: Sendable {
      public let descriptors: [IntentDescriptor]
      public func descriptor(id: String) -> IntentDescriptor?; public var ids: Set<String>
      public func sharedIds() -> Set<String>                 // availability.gui && availability.headless
      public func validate() throws                          // dup ids, empty summary, missing SchemaNode (1D)
      public static let shared: IntentCatalog; public static let fixture: IntentCatalog
      public init(_ descriptors: [IntentDescriptor])
    }

Seed `.shared`: `app.state` (`.observe`, `availability(gui:true, headless:true)`),
`tab.select` (`.control`, lifecycle, gui+headless), `terminal.typeText`
(`.control`, ptyInput, risk `.medium`, sensitivity `.keystrokes`, audit
`.redactedInput`, gui+headless), `terminal.sendKey`. `.fixture` empty until 1C.

### Concrete Steps (1A)

1. Create the files. 2. Add `Tests/LabanCoreTests/IntentCatalogTests.swift`.
3. `swift build && swift test --filter IntentCatalogTests` → `0 failures`.
4. `grep -rn "import AppKit\|import Cocoa" Sources/LabanCore/Intents || echo clean` → `clean`.

### Acceptance (1A)

`IntentCatalogTests`: `validate()` doesn't throw; ids unique/non-empty; each
starter `Intent`/`Query` id has a descriptor and vice versa (hardcoded list → drift
fails); no `availability.gui` descriptor requires `.fixture`; every `.fixture`
descriptor has `availability.gui == false`; each starter payload's
`jsonSchema.toJSONSchema()` is a non-empty object.

---

## Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter

**Scope.** Create `LabanControl`; relocate the Phase 0 server (public, C3),
generalize it into a route-table adapter that returns `ControlResponse` (C1/C2) and
checks availability per intent id (C6), and that serves **both surfaces** (C7).
Reimplement `LiveIntentRouter` against `IntentRouter`. `DebugHTTPServer` untouched.

### Concrete Steps (1B)

1. **`Package.swift`:** add `.target(name: "LabanControl", dependencies:
   ["LabanCore"])`; append `"LabanControl"` to `LabanApp.dependencies`; add
   `.testTarget(name: "LabanControlTests", dependencies: ["LabanControl","LabanCore"])`.
2. **Relocate** `LabanControlServer.swift`, `GuardOutcome`, `ControlAdvertisement.swift`
   to `Sources/LabanControl/`, all `public` with `public init` (C3). Keep the
   bind/token/guard/`SO_RCVTIMEO` bodies; **raise `maxHeaderBytes`→`64*1024`,
   `maxBodyBytes`→`4*1024*1024`** (C7).
3. **Generalize the server (C1/C6/C7):**
   - `public struct ControlRoute { method; path; resolveIntentId: (HTTPRequest) -> String?; handler: (IntentRouter, HTTPRequest) -> ControlResponse }`; a `public static let routes: [ControlRoute]` (the **ControlRouteCatalog**).
   - `public init(router: IntentRouter, surface: Surface, catalog: IntentCatalog)` (`Surface` = `.gui`/`.headless`).
   - `public func start(host: String, port: UInt16) throws -> DebugReadiness` (headless) **and** the GUI ephemeral `start() -> (url, token)` that maps the same readiness into `control.json`.
   - Per request, after the guard: match a route, call `resolveIntentId`, look up the descriptor, and **reject `404` if `!availability.permits(surface)`** before invoking `handler`.
4. **1B route table (2 routes):** `GET /debug/state` (resolveIntentId → `"app.state"`;
   handler → `router.query(.state)`); `POST /debug/actions` (resolveIntentId reads
   `action`; for `"selectTab"` → `"tab.select"`; handler decodes
   `Intent.tabSelect` and calls `router.route`).
5. **`LiveIntentRouter`** (stays in `LabanApp`) conforms to `IntentRouter`:
   `query(.state)` → `ControlResponse.json(ControlState(…))` from the live `AppModel`;
   `route(.tabSelect)` → bounds-checked `model.selectTab` on main, then
   `ControlResponse.json(ControlActionResult(ok:…, activeTabId:…, error:nil))` —
   **the exact Phase 0 GUI shape** (C1); `artifact(_)` → `nil`; unknown intents →
   `ControlResponse.error(400,"unsupported",…)`.
6. **Mount:** `MainWindowController.makeAndShow` imports `LabanControl`, builds
   `LiveIntentRouter`, starts the server with `surface: .gui` (ephemeral), writes
   `control.json` (unchanged behavior).
7. Move `ControlServerPhase0Tests` to `Tests/LabanControlTests/`.
8. `swift build && swift test --filter ControlServerPhase0Tests`; `./scripts/build-app`.

### Acceptance (1B)

`LabanControl` AppKit-free (grep). Phase 0 tests pass: guard matrix; `GET
/debug/state` → 200 with **identical** `ControlState` JSON; no token → 401; forged
`Host` → 403; `selectTab` → `ControlActionResult.ok == true`, `activeTabId` changes.
Operator GUI still serves `control.json` and switches tabs. A `start(host:port:)`
unit test returns a `DebugReadiness` with a non-empty `debugServer`/`debugToken`.

---

## Milestone 1C — Re-point the full debug surface through the adapter

**Scope.** Move all 45 routes into the `ControlRouteCatalog`, every handler going
through `Intent`/`Query`/`ControlArtifact` + `IntentRouter` and returning the exact
legacy `ControlResponse` (C1, incl. `ActionResult` vs `MouseActionResult`). Relocate
**all** request payloads (C3). Populate availability conservatively (C8). Rewrite the
contract checker before deleting `DebugHTTPServer` (CI green throughout).

### Concrete Steps (1C)

1. **Relocate all request payloads** (action + non-action) from
   `DebugRuntimeRequests.swift` to `LabanCore`, `public Codable, Sendable,
   Equatable` + `JSONSchemaProviding` (C3). Mechanical gate: no `Decodable` request
   body used by `LabanControl` remains `internal` to `LabanDebug`.
2. **Exhaustive `DebugAction → Intent`** mapping in `LabanDebug` (a `switch` with no
   `default`). Fixture-only cases → `IntentCatalog.fixture` ids
   (`availability.gui == false`).
3. **`HeadlessIntentRouter`** (LabanDebug) returns `ControlResponse` per route: it
   encodes the **existing** DTO — `ActionResult` for most actions,
   `MouseActionResult` for `mouseWheel`/`mouseDrag`/`click` (C1), `StateResponse`
   for state, etc.; `artifact(_)` wraps `runtime.screenshotBytes()` (`image/png` +
   `X-App-*`) and cast bytes (`x-asciicast`) (C2). `laban-agent` mounts the server
   with `surface: .headless` via `start(host:port:)` and prints the `DebugReadiness`
   (C7) — **replacing** `DebugHTTPServer` construction.
4. **`ControlRouteCatalog`** gains every route (method, path, query params,
   `resolveIntentId`, `SchemaNode` refs). For `/debug/actions`, `resolveIntentId`
   maps the `action` string to the intent id (incl. fixture ids).
5. **Availability (C8):** `gui:true` only for the ops `LiveIntentRouter` implements;
   all render/pixel/atlas/screenshot/capture/persistence/sessions-detail/find/
   selection/journal/logs/metrics → `gui:false` (headlessOnly) this phase; fixture
   ops → `.fixture`, `gui:false`. The server's per-intent availability check (C6)
   rejects them on `.gui`.
6. **Port in reviewable groups** (readers → actions → find/selection/shell/clipboard
   → render/screenshot/atlas/pixel → events/journal/logs/metrics → capture/
   persistence/fixture/cast/artifact). Each ported route grows `Intent`/`Query` +
   the catalogs; each group keeps `swift test` green.
7. **Rewrite `check-debug-contract` BEFORE deleting `DebugHTTPServer.swift`**: point
   it at `ControlRouteCatalog` + `IntentCatalog` (documented endpoints ↔ route ids ↔
   schema refs). Land in the same change as the last group so `scripts/check` never
   goes red.
8. **Delete `DebugHTTPServer.swift`** + the dead `DebugDiscoveryCatalog` hand-lists.
   Add `CatalogParityTests`: enumerate `IntentCatalog.shared.sharedIds()`; assert
   both routers return a non-error `ControlResponse` for each (no
   `"unsupported"`/`4xx-unimplemented`). Only `gui && headless` ids are enumerated.

### Acceptance (1C)

`grep -rn "class DebugHTTPServer" Sources` empty. `LabanDebugTests` pass with
assertions unchanged: same JSON fields, **`MouseActionResult.mouseTracking`/`sent`
preserved**, same `image/png` + `x-asciicast` bodies/headers,
`laban-agent --debug-server=127.0.0.1:0` still emits a `DebugReadiness` line.
`scripts/check` (rewritten `check-debug-contract`, smoke-runtime, test-e2e) green.
Parity test fails if either router drops a shared intent. `feedOutput` rejected on
`.gui`, accepted on `.headless`; a `gui:false` render route rejected on `.gui`
before dispatch.

---

## Milestone 1D — Generate discovery + schemas from the catalogs

**Scope.** Make the catalogs the *source* of `schemas/debug/*` and the discovery doc
(C4), preserving the existing schema namespace + discovery structure, and gate it.

### Concrete Steps (1D)

1. Add `LabanControlGen` (executable, deps `["LabanControl"]`). Walk
   `ControlRouteCatalog` (for endpoints/paths/methods/query-params/examples →
   discovery) **and** `IntentCatalog`/`.fixture` (for actions/capabilities + each
   descriptor's `SchemaNode`s). Emit, **under `schemas/debug/`** (stable paths),
   `<id>.input.schema.json` / `.output` / `.error` via
   `SchemaNode.toJSONSchema()` serialized with `.sortedKeys` (deterministic).
   Regenerate the `/debug` discovery doc with the **same structure/paths** as today.
2. Reconcile generated schemas against the committed hand-written `schemas/debug/*`:
   adjust the `SchemaNode`s until the generated output matches (or accept the
   generated form and update any content-asserting test). The discovery *response*
   stays byte-stable (same endpoints + schema paths).
3. Wire into `scripts/check`: regenerate to a temp dir and `diff` against committed
   artifacts (**fail on diff**); `IntentCatalog.validate()` **fails if any
   descriptor lacks an input/output `SchemaNode` or a `requiredCapability`**.
4. Commit the generated artifacts (generated, like `.rpg/graph.json`).

### Acceptance (1D)

Generator idempotent (second run → no `git diff`). Deleting a generated schema →
`scripts/check` fails. Adding a descriptor with no `SchemaNode`/capability →
`scripts/check` fails with a clear message. The `/debug` discovery response is
unchanged (same endpoint list + `schemas/debug/*` paths). `scripts/check` green.

---

## Validation and Acceptance

Per-milestone acceptance above. Overall, from the repo root:

    swift test --filter IntentCatalogTests        # 1A
    swift test --filter ControlServerPhase0Tests  # 1B — Phase 0 GUI wire + dual-surface server
    swift test --filter LabanDebug                 # 1C — full surface, ActionResult/MouseActionResult, binary, readiness preserved
    swift test --filter CatalogParityTests         # 1C
    ./scripts/check                                 # contract checker green THROUGHOUT; 1D generation gated
    ./scripts/build-app

…all pass, and: one input vocabulary (`IntentCatalog`) + one route table
(`ControlRouteCatalog`); one server in `LabanControl` (deps `["LabanCore"]` only,
AppKit-free) mounted by GUI (`surface:.gui`, ephemeral→`control.json`) and
`laban-agent` (`surface:.headless`, `start(host:port:)`→`DebugReadiness`);
`grep -rn "class DebugHTTPServer" Sources` empty; every legacy JSON shape (incl. the
GUI vs headless `/debug/actions` difference and `MouseActionResult`), binary body,
and the `/debug` discovery doc are byte-stable; surface-unavailable intents rejected
before dispatch; schemas+discovery generated into `schemas/debug/` and gated.

## Decision Log

- Decision: four self-contained, independently-reviewable milestones with concrete
  steps each. Rationale: `PLANS.md` end-to-end executability; 45-route carve is
  unreviewable in one PR. Date/Author: 2026-06-20 / Claude.
- Decision (ADR 0023 placement): registry types in `LabanCore`; server/adapter/route
  catalog/generator in `LabanControl`; live router in `LabanApp`; headless router in
  `LabanDebug`. Date/Author: 2026-06-20 / Claude.
- Decision (C1, review-2): the `IntentRouter` returns `ControlResponse` and each
  router encodes its **own** wire DTO. Rationale: the GUI DTOs (`LabanApp`) and
  headless DTOs (`LabanDebug`) cannot both be imported by `LabanControl` (deps
  `["LabanCore"]` only), and `/debug/actions` is not uniform — mouse actions return
  `MouseActionResult`, not `ActionResult`. This avoids relocating response DTOs and
  preserves per-action shapes. Date/Author: 2026-06-20 / Claude.
- Decision (C6, review-2): availability is checked on the **resolved intent id**
  (after a per-route `resolveIntentId`), not the path, because `/debug/actions`
  multiplexes 28 actions (incl. fixture-only) onto one path. Date/Author: 2026-06-20.
- Decision (C7, review-2): the relocated server serves both surfaces — add
  `start(host:port:) -> DebugReadiness` for `laban-agent` and keep the GUI ephemeral
  path; raise limits to 64 KiB/4 MiB. Keeping Phase 0's 16 KiB/1 MiB / ephemeral-only
  bodies "verbatim" would break `--debug-server=host:port` and large debug requests.
  Date/Author: 2026-06-20 / Claude.
- Decision (C4/C8 + P0-4/P0-5, review-2): the descriptor stores `SchemaNode`s (not
  fill-later ref strings); the generator walks `ControlRouteCatalog` + `IntentCatalog`
  and emits into the existing `schemas/debug/` namespace so the discovery doc stays
  byte-stable; `availability.gui` is set conservatively (only where `LiveIntentRouter`
  implements the op) to bound Phase 1 and keep the parity test small. Date/Author:
  2026-06-20 / Claude.
- Decision (C3 scope, review-2): relocate **all** request body payloads (action +
  non-action) to `LabanCore` as public `Codable`, not just the 28 action structs.
  Date/Author: 2026-06-20 / Claude.
- Decision (C5): Phase 1 retains Phase 0's single opt-in token; ADR 0024 tiers are
  Phase 2; fixture/headless gating is structural. Date/Author: 2026-06-20 / Claude.
- Decision: keep the `/debug/*` path namespace through Phase 1 (design §4.4).
  Date/Author: 2026-06-20 / Claude.

## Review Gate

A fresh-state agent verifies (mechanical checks; from repo root):

- [ ] `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl Sources/LabanCore/Intents` → nothing; `LabanControl` deps in `Package.swift` are exactly `["LabanCore"]`.
- [ ] `grep -rn "class DebugHTTPServer" Sources` → nothing (after 1C).
- [ ] Per-intent availability: a test issues `POST /debug/actions {"action":"feedOutput"}` on a `.gui` server and asserts `404` **without** `LiveIntentRouter` being invoked (e.g., a spy router records no call).
- [ ] Mouse wire preserved: a headless mouse-action test asserts the response JSON contains `mouseTracking` and `sent` (i.e., `MouseActionResult`, not `ActionResult`).
- [ ] Dual surface: a `start(host:port:)` test returns a `DebugReadiness`; `laban-agent --debug-server=127.0.0.1:0` emits a readiness line; limits are `64*1024`/`4*1024*1024`.
- [ ] `DebugAction → Intent` `switch` has no `default`; relocated request structs are `public … Codable` (grep: no `Decodable` request body used by `LabanControl` is `internal` in `LabanDebug`).
- [ ] No reflection: `grep -rni "Mirror(\|\.reflect" Sources/LabanControl Sources/LabanCore/Intents` → nothing.
- [ ] 1D: generator idempotent (run twice → no `git diff`); schemas land under `schemas/debug/`; the `/debug` discovery response's endpoint list + schema paths are unchanged vs the pre-1D commit; deleting one schema → `./scripts/check` fails.
- [ ] `./scripts/check` exits 0; no third-party package added.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- 1A is additive; `swift test` reruns are safe.
- Each 1C group is small and revertible; a half-ported route surfaces as a missing
  catalog entry or a failing parity/`LabanDebugTests` case. The contract checker is
  rewritten before the deletion, so a revert never strands CI.
- 1D writes only under `schemas/debug/` + the discovery doc and is deterministic;
  reruns are no-ops.
- `LabanControl` adds no runtime behavior until mounted (1B); the shipped GUI and CI
  are untouched until then.

## Interfaces and Dependencies

End-state package graph (additions **bold**):

    LabanCore         deps [LabanTerminalCore, LabanRenderer]   + Sources/LabanCore/Intents/* + ALL relocated public request payloads
    **LabanControl**  deps [LabanCore]                          server (route-table adapter, ControlResponse, ControlRouteCatalog,
                                                                  start(host:port:)->DebugReadiness + GUI ephemeral), advertisement, policy
    LabanDebug        deps [LabanCore, **LabanControl**, LabanRenderer, LabanTerminalCore]   HeadlessIntentRouter (encodes ActionResult/MouseActionResult/…), runtime, fixtures
    LabanApp          deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   LiveIntentRouter; mounts (surface:.gui)
    LabanAgent        deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   mounts (surface:.headless)
    **LabanControlGen** (exe, 1D)  deps [LabanControl]          deterministic schema + discovery generator

Key end-state types: `Intent`, `Query`, `ControlResponse`, `ControlArtifact`,
`ArtifactRequest`, `Capability`, `DataSensitivity`, `IntentDescriptor`
(SchemaNodes + `Availability`), `IntentCatalog`, `IntentRouter`, `SchemaNode`,
`JSONSchemaProviding`, all relocated request payloads (all `LabanCore`, `public`);
`LabanControlServer` (route-table adapter, dual-surface), `ControlRoute`/
`ControlRouteCatalog`, `ControlAdvertisement`, `LabanControlPolicy`, the generator
(`LabanControl`); `LiveIntentRouter`/`HeadlessIntentRouter: IntentRouter`. No
third-party packages; `LabanControl` uses only `Foundation`/`Darwin`/`LabanCore`;
`DebugReadiness` reused verbatim for `laban-agent` compatibility.
