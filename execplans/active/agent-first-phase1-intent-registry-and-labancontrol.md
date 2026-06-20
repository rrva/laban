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

**Read "Cross-cutting design contracts" (C1–C10) before any milestone.** They are
the rules that keep the carve from breaking compile, module-boundary, wire,
binary, schema, discovery, security, and headless-launch contracts.

## Purpose / Big Picture

Today Laban has two disconnected control surfaces: a *tiny* one in the GUI
(`LabanApp`, Phase 0: `GET /debug/state`, `POST /debug/actions {selectTab}`) and a
*rich* one in the headless binary (`laban-agent` → `DebugHTTPServer`, **45
routes**), each against its own model, sharing no code.

After Phase 1, there is **one typed input vocabulary and one server**:

- Every operation is a typed `Intent` (action) or `Query` (read), defined once in
  `LabanCore`, listed in one `IntentCatalog` (+ a headless-only
  `IntentCatalog.fixture`; `IntentCatalog.all` is the union). Endpoint HTTP
  metadata lives in a separate `ControlRouteCatalog`.
- A new `LabanControl` target (deps **`["LabanCore"]`** only) hosts the one server.
  Its route table is an **HTTP↔Intent adapter**: it resolves the body-derived
  intent id, **checks availability/capability by that id against the current
  surface**, then asks an injected `IntentRouter` to execute — and the **router
  returns a `ControlResponse` it encoded itself** (so each router owns its exact
  legacy wire shape and binary body).
- The GUI's `LiveIntentRouter` and the headless `HeadlessIntentRouter` implement
  the same `IntentRouter` and mount the same server. Parity is a **test**, scoped
  to ops both implement.
- The `/debug` discovery doc and `schemas/debug/*` paths stay **byte-stable**;
  generation (1D) emits discovery from the route catalog and validates schema
  consistency, grandfathering today's hand-written schemas.

**The wire is byte-stable.** Existing clients and `LabanDebugTests` see identical
responses — same JSON fields (GUI `ControlActionResult` vs headless `ActionResult`,
and `MouseActionResult` for mouse), same `.iso8601`/`.sortedKeys` encoding, same
`image/png`/`x-asciicast` bodies+headers, same `/debug` discovery doc + schema
paths, same `laban-agent --debug-server=host:port` readiness JSON.

## Progress

Milestone 1A — Registry backbone (LabanCore):
- [x] (2026-06-20) `Sources/LabanCore/Intents/` added: `Capability`, `DataSensitivity`, `Intent`, `Query`, `ControlResponse` (encoder-pinned), `ControlArtifact`, `ArtifactRequest`, `ControlReadiness`, `SchemaNode` (rich subset) + `JSONSchemaProviding`, `IntentDescriptor` (+ `availability`, `SchemaNode`s), `IntentCatalog` (+ `.shared`/`.fixture`/`.all`), `IntentRouter`, public `ControlEndpointDescriptor`/`HTTPBinding`, internal `ControlRoute`. All public types have `public init`; AppKit-free.
- [x] (2026-06-20) `Tests/LabanCoreTests/IntentCatalogTests.swift` (well-formedness, uniqueness, availability/fixture tagging, schema-node presence route-awareness).
- [x] (2026-06-20) `swift test --filter IntentCatalogTests` passes; no AppKit import in `Sources/LabanCore/Intents`.

Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter:
- [x] (2026-06-20) `LabanControl` target (deps `["LabanCore"]`); `LabanApp` depends on it; **two** test targets: `LabanControlTests` (spy-router adapter tests, no LabanApp dep) and live-router tests kept in `LabanAppTests`.
- [x] (2026-06-20) Phase 0 server relocated into `LabanControl`, public; generalized to the route-table adapter returning `ControlResponse`; gains `start(host:port:) -> ControlReadiness` + GUI ephemeral path; limits 64 KiB/4 MiB; server looks up descriptors in `IntentCatalog.all`, enforces availability by surface.
- [x] (2026-06-20) `LiveIntentRouter` (LabanApp) conforms to `IntentRouter`, returns `ControlResponse` encoding the exact `ControlState`/`ControlActionResult` JSON.
- [x] (2026-06-20) Adapter tests (spy router) + live tests pass; `LabanControl` AppKit-free.

Milestone 1C — Re-point the full debug surface:
- [x] (2026-06-20) 1C-a foundation: request body payloads used by the future adapter (action + non-action) are public `Codable, Sendable, Equatable` + `JSONSchemaProviding` in `LabanCore`, with `LabanDebug` typealiases preserving current compile behavior; exhaustive `DebugAction → Intent` map added with no `default`; action resolver taxonomy covered by tests (malformed/missing action→400, unknown→unsupported intent, known-but-GUI-unavailable fixture action→404 before router call).
- [x] (2026-06-20) 1C-a route metadata: `ControlRouteCatalog` public `HTTPBinding`s cover the 45 legacy `/debug` routes with method/path/query/legacy schema metadata; tests assert route count, no duplicate method/path keys, representative legacy schema paths, and fixed intent ids present in `IntentCatalog.all`.
- [x] (2026-06-20) 1C-b1 JSON-read route family: `ControlHTTPRequest` preserves URL query parameters; `ControlRouteCatalog` dispatches the JSON GET/read-only routes (`/debug`, `/debug/capabilities`, `/debug/health`, state/accessibility/modes, persistence reads, find/shell/scroll reads, sessions list, render/frame/atlas, logs/metrics/errors, selection/clipboard) through `LegacyDebugQueryInput`; `HeadlessIntentRouter` wraps existing `DebugResponse` bodies into `ControlResponse` for those ids; tests cover query propagation and representative headless responses.
- [x] (2026-06-20) 1C-b2 dynamic/binary route family: internal `ControlRoute` matching decodes `/debug/sessions/<id>` path parameters; session detail dispatches through `LegacyDebugQueryInput`; `GET /debug/screenshot` and `GET /debug/cast/recent` dispatch through `ArtifactRequest`; `HeadlessIntentRouter` returns PNG/asciicast `ControlResponse.binary` headers matching the legacy server and preserves cast error JSON; tests cover path/query propagation and screenshot/cast artifact responses.
- [x] (2026-06-20) 1C-b3 non-action POST/control route family: `ControlRouteCatalog` dispatches POST body and no-body routes outside `/debug/actions` through `LegacyDebugControlInput` (`/debug/screenshot`, persistence flush/relaunch/restore select, find start/step/stop, wait, render-trace, pixel-probe, snapshot, fixture, capture start/stop/snapshot) and includes `GET /debug/capture/status`; `HeadlessIntentRouter` delegates to existing runtime methods so legacy JSON/error encoding stays owned by `LabanDebug`; tests cover raw-body dispatch, empty-body dispatch, capture status, and malformed-body runtime errors.
- [x] (2026-06-20) 1C-b4 `/debug/actions` action route family: `LegacyDebugActionInput` carries the raw action body; `dispatchDebugAction` is surface-aware (GUI keeps the Phase-0 typed `selectTab`/`typeText`/`sendKey` decode; headless hands every recognized action's raw body to the router as `.legacyDebugAction`, unknown → `.unsupportedDebugAction`); `HeadlessIntentRouter.route(.legacyDebugAction)` delegates to `runtime.applyAction(body)` so `ActionResult`/`MouseActionResult` stay byte-stable; tests cover headless raw-body routing (mouse + tabId-based shared action not diverted to the GUI index path) and the headless router preserving the `ActionResult` vs `MouseActionResult` wire.
- [x] (2026-06-20) 1C-c cutover: `laban-agent` mounts `LabanControlServer(router: HeadlessIntentRouter, surface: .headless, readinessRunID: runtime.runId)` via `start(host:port:)` → `ControlReadiness`, replacing `DebugHTTPServer` at the mount; `LabanControlServer` gained `readinessRunID` so the readiness JSON keeps `runtime.runId` byte-stable; `DebugReadiness` is now `typealias DebugReadiness = ControlReadiness` (C7); `LabanAgent` deps gain `LabanControl`. `DebugHTTPServer.swift` still present (deleted in the contract-checker step). `scripts/check` `test-e2e` (29 HTTP requests across ~30 routes incl. actions/mouse/find/wait/fixture) green against the new server.
- [x] (2026-06-20) `availability` parity: `LiveIntentRouter` now implements `terminal.typeText` (active session `write`) and `terminal.sendKey` (so the 4 `guiAndHeadless` starters are honestly gui-implemented); key-name → `Key`/`KeyModifiers` parsing promoted to shared `LabanCore.ControlKeyName` (headless `DebugRuntimeKeyInput` delegates, behavior unchanged). `ControlAvailabilityParityTests` (LabanAppTests) asserts the gui-available action set is exactly `{tab.select, terminal.typeText, terminal.sendKey, debug.action.unsupported}` and the live router returns non-error for each real op (and errors on the unsupported fallback); `HeadlessIntentRouterTests` asserts the headless router handles every shared op non-error.
- [ ] `check-debug-contract` rewritten to read `ControlRouteCatalog`/`IntentCatalog` **before** `DebugHTTPServer.swift` deleted; all routes ported; `DebugHTTPServer.swift` deleted; `Tests/LabanDebugTests` pass unchanged.

Milestone 1D — Generate discovery; gate schemas:
- [ ] Generator emits the `/debug` discovery doc from `ControlRouteCatalog`+`IntentCatalog` **byte-stable** (legacy schema paths); validates catalog↔schema consistency **route-aware**; emits new-intent schemas from `SchemaNode`; grandfathers the 33 existing hand-written schemas.
- [ ] `scripts/check` gate fails on a route missing its (route-appropriate) schema or a descriptor missing `requiredCapability`; generated discovery committed; `scripts/check` green.

## Context and Orientation

(Define-every-term, name-every-file, per `PLANS.md`.)

- **`LabanApp`** (AppKit), **`LabanCore`** (AppKit-free model; `AppModel` internally
  locked), **`LabanDebug`** (AppKit-free; HTTP server + offscreen runtime today),
  **`LabanControl`** (*new*; AppKit-free, deps `["LabanCore"]` only).
- **Phase 0 seam** (`Sources/LabanApp/Control/`, `internal`): `ControlState
  { tabs, activeTabId }`, `ControlActionResult { ok, activeTabId, error }`,
  `protocol ControlRouter`, `LiveIntentRouter` (over `AppModel`),
  `LabanControlServer` (`GuardOutcome`; `start() -> (url, token)` **ephemeral
  loopback only**, `maxHeaderBytes=16*1024`, `maxBodyBytes=1024*1024`, 5 s
  `SO_RCVTIMEO`; correct `Host`/`Origin` guard), `ControlAdvertisement` (`0600`
  `O_EXCL`→`rename`). Mounted in `MainWindowController.makeAndShow` (~509–527)
  behind `LABAN_CONTROL_SERVER=1`.
- **`DebugHTTPServer`** (`Sources/LabanDebug/DebugHTTPServer.swift`): 45
  `DebugHTTPRoute`s; `public func start(host: String, port: UInt16) throws ->
  DebugReadiness` (line 542); `maxHeaderBytes=64*1024`, `maxBodyBytes=4*1024*1024`;
  holds `private let runtime: HeadlessDebugRuntime`; started in
  `Sources/LabanAgent/main.swift` (~251–257). The response helper
  `jsonEncode<T>(_:status:)` (`DebugModels.swift:55`) uses **`JSONEncoder` with
  `dateEncodingStrategy = .iso8601` and `outputFormatting = .sortedKeys`**;
  `jsonError(_:status:)` emits `{"error":"<escaped>"}` (default status 400).
- **`DebugReadiness`** (`DebugModels.swift:46`, `public`): `{ debugServer, debugToken,
  pid, runId }` — the readiness JSON `laban-agent` prints. **Lives in LabanDebug**,
  so `LabanControl` cannot import it (see C7).
- **`DebugAction`** (`DebugRuntimeRequests.swift:8-36`): 28 `internal Decodable`
  cases incl. `unsupported(String)` and fixture-only `feedOutput`/`advanceFrames`/
  `windowFocus`; each with an `internal` request struct. Non-action `internal
  Decodable` request structs in the same file (`WaitRequest`/`WaitCondition`
  279-297, `RenderTraceRequest`/`PixelProbeReq` 299-312, `CaptureStartRequest`
  251-254, …) plus several `Encodable` response structs.
- **Legacy wire result DTOs (byte-stable):** GUI `/debug/actions` →
  `ControlActionResult { ok, activeTabId, error }`; GUI `/debug/state` →
  `ControlState`. Headless `/debug/actions` → **`ActionResult { ok, frame,
  activeTabId, activeSessionId, error }`** (`DebugModels.swift:189`), **except mouse
  actions** → **`MouseActionResult { …, mouseTracking, sent, … }`** (`:225`);
  headless `/debug/state` → `StateResponse`. `GET /debug/screenshot` → `image/png`
  + `X-App-*`; `GET /debug/cast/recent` → `application/x-asciicast` + headers.
- **`schemas/debug/*.schema.json`** — 33 hand-written schemas with **route-level
  names** (`action.schema.json`, `action-result.schema.json`, `state.schema.json`,
  `wait.schema.json`, `render-trace-request.schema.json`, …), using JSON Schema
  features beyond a trivial DSL (`$defs`, `$ref`, `oneOf`, `const`,
  `additionalProperties`, constraints, formats). `/debug/actions` is described by a
  single **union** `action.schema.json`, not per-action files.
- **`check-debug-contract`** (`scripts/check-debug-contract`, run by `scripts/check`):
  regexes `DebugHTTPServer.swift` to check documented endpoints exist and referenced
  schema paths exist. Presence check; reads that file directly, so deleting it
  breaks the check unless rewritten first.
- **Discovery** assembled by hand (`DebugDiscoveryCatalog` +
  `DebugDiscoveryEndpoints.swift`), referencing the route-level schema paths above.
- `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. Deps: `LabanCore`
  `["LabanTerminalCore","LabanRenderer"]`; `LabanDebug`
  `["LabanCore","LabanRenderer","LabanTerminalCore"]`; `LabanApp`/`LabanAgent`/
  `Laband` depend on `LabanDebug`.

---

## Cross-cutting design contracts (read first)

**C1 — The router returns the wire response; it owns its DTOs.** `IntentRouter`'s
legs return `ControlResponse`, built by encoding the router's own existing wire
DTO. This keeps `LabanControl` dependent on `LabanCore` only (GUI DTOs stay in
`LabanApp`, headless DTOs in `LabanDebug`; neither imported by `LabanControl`) and
lets each route emit its exact legacy shape: GUI `/debug/actions` →
`ControlActionResult`; headless → `ActionResult`, **but mouse actions →
`MouseActionResult`**. No response DTO is relocated.

**C2 — One response type, JSON+binary, encoder pinned.** `public struct
ControlResponse { status; contentType; headers; body: Data }` (LabanCore).
`.json(_:Encodable,status:)` **must replicate the current debug response encoder —
`JSONEncoder` with `dateEncodingStrategy = .iso8601`, `outputFormatting =
.sortedKeys`** (`jsonEncode`, `DebugModels.swift:55`). `.error(status,message)`
emits the exact `jsonError` body `{"error":"<escaped>"}`. `.binary(_:Data,
contentType:headers:status:)` is used for `screenshot`→`image/png` and
`cast`→`x-asciicast` (content-type + headers preserved verbatim), produced by the
`artifact(_)` leg.

**C3 — Explicit public access + request-payload relocation.** Everything crossing
the new module boundary is `public` with explicit `public init`. **All HTTP request
body payloads decoded by the adapter** (action *and* non-action) relocate to
`LabanCore` as `public Codable, Sendable, Equatable` (+ `JSONSchemaProviding`).
Mechanical gate: no `Decodable` request body used by `LabanControl` remains
`internal` to `LabanDebug`. `HTTPRequest` (or whatever request wrapper appears in a
public signature) is `public`.

**C4 — Schemas: rich DSL for new intents, grandfather the existing 33, byte-stable
paths.** Each payload conforms to `JSONSchemaProviding { static var jsonSchema:
SchemaNode }`. `SchemaNode` is a JSON-Schema *subset large enough to author real
schemas*: object/array/string/integer/number/boolean/optional/enum **plus `defs`,
`ref`, `oneOf`, `const`, `additionalProperties`, string/number/array constraints,
`format`, `pattern`, `examples`**. The **`HTTPBinding` carries the exact existing
schema paths** (`legacyRequestSchemaPath`/`legacyResponseSchemaPath`, e.g.
`schemas/debug/action.schema.json`) so the discovery doc references them **verbatim**
(NOT per-intent-id computed paths). Phase 1 **does not byte-regenerate** the 33
grandfathered hand-written schemas; the catalog *references* them and the gate
*validates* them. `SchemaNode` is the authoring path for **new** intents (emitted +
gated). Schema-required validation is **route-aware**: artifact/binary routes need
no JSON output schema; pure-query routes need no input schema; `/debug/actions` is
covered by the single union `action.schema.json`, not per-action schemas. No
reflection; no third-party packages.

**C5 — Capability classified, not enforced.** Phase 1 keeps Phase 0's single opt-in
bearer token (off unless `LABAN_CONTROL_SERVER=1`; loopback + `Host`/`Origin` guard
verbatim). ADR 0024 token tiers are Phase 2. Descriptors carry `requiredCapability`/
`availability` as metadata; fixture/headless-only gating is structural (C6/C8).

**C6 — Availability checked per resolved intent; unknown ≠ unavailable.** Per
request, after the guard: match a `ControlRouteCatalog` `HTTPBinding` (method+path)
→ call its `resolveIntentId(HTTPRequest) -> Resolution` (for `/debug/actions`, read
`action`). The resolver taxonomy, preserving existing behavior:
- **malformed body / missing `action`** → keep the existing **bad-request** path
  (`400 {"error":…}` via `.error`), not 404.
- **unknown action** (string not in `IntentCatalog.all`) → the **legacy unsupported
  behavior**: dispatch maps to the headless `unsupported(String)` path returning
  `ActionResult(ok:false,…)` (or the GUI's equivalent failure), **not** 404.
- **known but surface-unavailable** (descriptor exists, `availability` excludes the
  surface) → **`404 {"error":"unavailable on \(surface)"}` before dispatch**.
Descriptor lookup uses **`IntentCatalog.all`** (shared + fixture), so `feedOutput`
is *known* on both surfaces and gated by availability (gui:false → 404 on GUI;
headless:true → dispatched). Acceptance: `POST /debug/actions {"action":"feedOutput"}`
→ 404 on `.gui` **before** `LiveIntentRouter` runs; accepted on `.headless`.

**C7 — Readiness type lives below `LabanControl`.** `LabanControl` cannot import
`LabanDebug`, so `start(host:port:)` cannot return `LabanDebug.DebugReadiness`.
Relocate the type: define **`public struct ControlReadiness { debugServer, debugToken,
pid, runId }` in `LabanCore`** (byte-identical JSON — same field names/encoder), and
in `LabanDebug` add `public typealias DebugReadiness = ControlReadiness` so
`laban-agent`'s existing references compile unchanged.

**C8 — Conservative GUI availability.** `availability.gui == true` **only** for ops
`LiveIntentRouter` actually implements in Phase 1 (`app.state`, `tab.select`,
`terminal.typeText`, `terminal.sendKey`, and any `AppCommand`-backed ops it wires).
Everything else is `headlessOnly` until a later phase names its GUI source of truth.

**C9 — Public endpoint metadata is separate from internal handler closures.** Split
the route record: **`public struct HTTPBinding` / `ControlEndpointDescriptor`** holds
pure data (`method`, `path`, `category`, `summary`, `queryParameters`,
`legacyRequestSchemaPath?`, `legacyResponseSchemaPath?`, `examples`, the resolved
intent-id mapping for discovery) — this is what `LabanControlGen` and discovery walk.
**`internal struct ControlRoute`** holds `resolveIntentId` and the handler closures.
The public API must not expose closures; the generator depends only on the metadata.

**C10 — Dual-surface server: start overload + limits.** The relocated server serves both
the GUI (ephemeral port 0 → `control.json`) and `laban-agent`
(`--debug-server=host:port`): add `public func start(host: String, port: UInt16)
throws -> ControlReadiness` alongside the GUI ephemeral `start() -> (url, token)`
(which maps the same readiness into `control.json`). Raise limits to
`maxHeaderBytes = 64*1024`, `maxBodyBytes = 4*1024*1024`. Keep the loopback bind,
token, guard, and `SO_RCVTIMEO`.

---

## Milestone 1A — Registry backbone in `LabanCore` (no endpoint moves)

**Scope.** Add the typed vocabulary, `ControlResponse`/`ControlArtifact`/
`ControlReadiness`, the rich schema DSL, the catalogs, and the public
`HTTPBinding`/internal-`ControlRoute` split to `LabanCore`. Pure, additive,
AppKit-free, public.

### Plan of Work (1A)

Files under `Sources/LabanCore/Intents/` (skeletons; all public + `public init`):

    public enum Capability: String, Codable, CaseIterable, Sendable { case observe, observeSensitive, control, clipboard, fixture }
    public enum DataSensitivity: String, Codable, Sendable { case none, nonSensitiveState, visibleText, scrollback, keystrokes, clipboard, screenshot, trace }

    // C4 — JSON-Schema subset large enough to author the real schemas
    public indirect enum SchemaNode: Sendable {
      case object(properties: [String: SchemaNode], required: [String], additionalProperties: Bool)
      case string(enumValues: [String]?, const: String?, format: String?, pattern: String?)
      case integer(min: Int?, max: Int?); case number(min: Double?, max: Double?); case boolean
      case array(SchemaNode, minItems: Int?); case optional(SchemaNode)
      case oneOf([SchemaNode]); case ref(String); case defs([String: SchemaNode], SchemaNode)
      public var examples: [Any]? { get }                  // attachable
      public func toJSONSchema() -> [String: Any]          // deterministic; 1D serializes sorted-keys
    }
    public protocol JSONSchemaProviding { static var jsonSchema: SchemaNode { get } }

    // C2 — encoder pinned to the legacy debug response encoder
    public struct ControlResponse: Sendable {
      public var status: Int; public var contentType: String; public var headers: [String:String]; public var body: Data
      public static func json<T: Encodable>(_ v: T, status: Int = 200) -> ControlResponse   // JSONEncoder: .iso8601 + .sortedKeys
      public static func binary(_ b: Data, contentType: String, headers: [String:String] = [:], status: Int = 200) -> ControlResponse
      public static func error(_ status: Int, _ message: String) -> ControlResponse          // {"error":"<escaped>"} == jsonError
    }
    public struct ControlArtifact: Sendable { public let contentType: String; public let headers: [String:String]; public let body: Data; public init(…) }
    public struct ArtifactRequest: Sendable { public let id: String; public let params: [String:String]; public init(…) }
    public struct ControlReadiness: Codable, Sendable { public let debugServer: String; public let debugToken: String; public let pid: Int32; public let runId: String; public init(…) }   // C7

    public enum Intent: Sendable, Equatable { case tabSelect(TabSelectInput); case terminalTypeText(TypeTextInput); case terminalSendKey(SendKeyInput); public var id: String { … } }
    public struct TabSelectInput: Codable, Sendable, Equatable, JSONSchemaProviding { public var tabId: String?; public var index: Int?; public init(…); public static var jsonSchema: SchemaNode { … } }
    // TypeTextInput, SendKeyInput similar; 1C relocates all the remaining request payloads here.

    public enum Query: Sendable, Equatable { case state; public var id: String { "app.state" } }

    public protocol IntentRouter: AnyObject {              // C1 — every leg returns ControlResponse
      func route(_ intent: Intent) -> ControlResponse
      func query(_ query: Query) -> ControlResponse
      func artifact(_ request: ArtifactRequest) -> ControlResponse?
    }

    public struct IntentDescriptor: Sendable {            // design §4.2 + availability + SchemaNodes
      public enum Kind: String, Sendable { case query, action, wait, event, artifact }
      public let id: String; public let kind: Kind; public let category: String; public let summary: String
      public let requiredCapability: Capability; public let dataSensitivity: DataSensitivity
      public struct SideEffects: Sendable { public var ptyInput=false; public var lifecycle=false; public var clipboard=false; public var filesystem=false; public var network=false; public init() {} }
      public let sideEffects: SideEffects
      public struct Risk: Sendable { public enum Level: String, Sendable { case none, low, medium, high }; public let level: Level; public let reason: String }
      public let risk: Risk
      public enum Audit: String, Sendable { case none, metadataOnly, redactedInput, fullInput }; public let audit: Audit
      public struct Availability: Sendable, Equatable { public let gui: Bool; public let headless: Bool; public func permits(_ s: Surface) -> Bool }
      public let availability: Availability
      public struct Transports: Sendable { public let http: Bool; public let mcp: Bool; public let cli: Bool }
      public let transports: Transports
      public let inputSchema: SchemaNode?; public let outputSchema: SchemaNode?; public let errorSchema: SchemaNode?   // for NEW intents (C4); grandfathered routes leave these nil and bind via HTTPBinding.legacy*Path
      public init(…)
    }

    public enum Surface: Sendable { case gui, headless }

    // C9 — public endpoint metadata (the generator/discovery walk this; no closures)
    public struct HTTPBinding: Sendable {
      public let method: String; public let path: String; public let category: String; public let summary: String
      public let queryParameters: [String]
      public let legacyRequestSchemaPath: String?; public let legacyResponseSchemaPath: String?   // e.g. "schemas/debug/action.schema.json"
      public let examples: [String]
      public init(…)
    }

    public struct IntentCatalog: Sendable {
      public let descriptors: [IntentDescriptor]
      public func descriptor(id: String) -> IntentDescriptor?; public var ids: Set<String>
      public func sharedIds() -> Set<String>
      public func validate() throws
      public static let shared: IntentCatalog; public static let fixture: IntentCatalog
      public static let all: IntentCatalog                 // C6 — shared + fixture, for server lookup
      public init(_ descriptors: [IntentDescriptor])
    }

Seed `.shared`: `app.state`, `tab.select`, `terminal.typeText`, `terminal.sendKey`
(all `availability(gui:true, headless:true)`, capabilities per design). `.fixture`
empty until 1C.

### Concrete Steps (1A)

1. Create the files. 2. Add `Tests/LabanCoreTests/IntentCatalogTests.swift`.
3. `swift build && swift test --filter IntentCatalogTests` → `0 failures`.
4. `grep -rn "import AppKit\|import Cocoa" Sources/LabanCore/Intents || echo clean` → `clean`.

### Acceptance (1A)

`IntentCatalogTests`: `validate()` doesn't throw; ids unique/non-empty; each
starter id has a descriptor and vice versa; `.fixture` descriptors all have
`availability.gui == false`; `IntentCatalog.all` contains shared ∪ fixture; each
starter payload's `jsonSchema.toJSONSchema()` is a non-empty object;
schema-presence validation is route-aware (a query-only descriptor with no
`inputSchema` passes).

---

## Milestone 1B — `LabanControl` target + Phase-0-equivalent adapter

**Scope.** Create `LabanControl`; relocate the Phase 0 server (public, C3),
generalize it to the route-table adapter (C1/C6/C9) returning `ControlResponse`
(C2), serving both surfaces (C7) and looking up `IntentCatalog.all`. Reimplement
`LiveIntentRouter`. `DebugHTTPServer` untouched.

### Concrete Steps (1B)

1. **`Package.swift`:** add `.target(name: "LabanControl", dependencies:
   ["LabanCore"])`; append `"LabanControl"` to `LabanApp.dependencies`; add
   `.testTarget(name: "LabanControlTests", dependencies: ["LabanControl","LabanCore"])`
   (**no LabanApp dep**).
2. **Relocate** `LabanControlServer.swift`, `GuardOutcome`, `ControlAdvertisement.swift`
   to `Sources/LabanControl/`, public + `public init` (C3). Keep bind/token/guard/
   `SO_RCVTIMEO`; raise limits to 64 KiB/4 MiB (C7).
3. **Generalize the server:** public `init(router: IntentRouter, surface: Surface,
   catalog: IntentCatalog = .all)`; `public func start(host:port:) -> ControlReadiness`
   (headless) + GUI ephemeral `start() -> (url, token)` mapping the same readiness to
   `control.json` (C7); a `public static let routes: [HTTPBinding]` (metadata) with a
   parallel internal `[ControlRoute]` (closures, C9). Per request after the guard:
   match binding → `resolveIntentId` → descriptor from `catalog` → reject `404` if
   `!availability.permits(surface)` (C6) → dispatch.
4. **1B routes (2):** `GET /debug/state` → `router.query(.state)` → `ControlResponse.json(ControlState…)`;
   `POST /debug/actions` (resolver: `action=="selectTab"` → `"tab.select"`) → decode
   `Intent.tabSelect` → `router.route` → `ControlActionResult` JSON (C1/C2).
5. **`LiveIntentRouter`** (LabanApp) conforms to `IntentRouter`, returns
   `ControlResponse` from the live `AppModel` (exact Phase 0 shapes); `artifact` →
   `nil`; unknown intents → `.error(400,"unsupported")`.
6. **Mount:** `MainWindowController.makeAndShow` imports `LabanControl`, builds
   `LiveIntentRouter`, starts the server with `surface: .gui`, writes `control.json`.
7. **Tests, split (C9/P0-2):** *live* tests (exercise `AppModel`/`LiveIntentRouter`/
   GUI DTOs end-to-end) stay in `Tests/LabanAppTests/` (can import both LabanApp +
   LabanControl). *Adapter* tests go in `Tests/LabanControlTests/` using a **spy
   `IntentRouter`** + local JSON decoding (guard matrix, availability rejection,
   route dispatch, `start(host:port:)` returns a `ControlReadiness`) — **no LabanApp
   dependency**.
8. `swift build && swift test`; `./scripts/build-app`.

### Acceptance (1B)

`LabanControl` AppKit-free; deps `["LabanCore"]`. Phase 0 behavior preserved:
`GET /debug/state` → identical `ControlState` JSON; no token → 401; forged `Host` →
403; `selectTab` → `ControlActionResult.ok`, `activeTabId` changes. A
`LabanControlTests` spy-router test asserts a `.gui` request for an unavailable id
returns 404 without invoking the router. `start(host:port:)` returns a
`ControlReadiness` with non-empty `debugServer`/`debugToken`.

---

## Milestone 1C — Re-point the full debug surface

**Scope.** Move all 45 routes into `ControlRouteCatalog` (HTTPBinding + ControlRoute),
every handler through `Intent`/`Query`/`ControlArtifact` + `IntentRouter` returning
the exact legacy `ControlResponse` (incl. `ActionResult` vs `MouseActionResult`).
Relocate all request payloads (C3). Implement the resolver taxonomy (C6). Conservative
availability (C8). Rewrite the contract checker before deleting `DebugHTTPServer`.

### Concrete Steps (1C)

1. **Relocate all request payloads** (action + non-action — `WaitRequest`/
   `WaitCondition`, `RenderTraceRequest`/`PixelProbeReq`, `CaptureStartRequest`,
   persistence/fixture inputs, …) to `LabanCore`, public `Codable, Sendable,
   Equatable` + `JSONSchemaProviding` (C3). Gate: no `Decodable` request body used by
   `LabanControl` stays `internal` in `LabanDebug`.
2. **Exhaustive `DebugAction → Intent`** map in `LabanDebug` (`switch`, no `default`).
   Implement the **resolver taxonomy** (C6): malformed/missing-action → 400; unknown
   action → legacy `ActionResult(ok:false,…)`; known-unavailable → 404. Fixture-only
   actions → `IntentCatalog.fixture` (gui:false).
3. **`HeadlessIntentRouter`** (LabanDebug) returns `ControlResponse` per route:
   `ActionResult` for most actions, **`MouseActionResult` for mouse**, `StateResponse`
   for state, etc.; `artifact(_)` wraps `screenshotBytes()` (`image/png`+`X-App-*`)
   and cast bytes (`x-asciicast`). `laban-agent` mounts via `start(host:port:)` →
   `ControlReadiness`, **replacing** `DebugHTTPServer`.
4. **`ControlRouteCatalog`**: a `public static let bindings: [HTTPBinding]` (incl.
   `legacyRequestSchemaPath`/`legacyResponseSchemaPath` set to the exact existing file
   names, e.g. `schemas/debug/action.schema.json`) + the internal `[ControlRoute]`
   (resolver/handlers).
5. **Availability (C8):** gui:true only where `LiveIntentRouter` implements; render/
   pixel/atlas/screenshot/capture/persistence/sessions-detail/find/selection/journal/
   logs/metrics → `gui:false`; fixture → `.fixture`, gui:false.
6. **Port in reviewable groups**; each grows `Intent`/`Query` + both catalogs, keeps
   `swift test` green.
7. **Rewrite `check-debug-contract` BEFORE deleting `DebugHTTPServer.swift`** to read
   `ControlRouteCatalog.bindings` + `IntentCatalog` (documented endpoints ↔ bindings ↔
   legacy schema paths). Land with the last group.
8. **Delete `DebugHTTPServer.swift`** + the dead `DebugDiscoveryCatalog` hand-lists.
   Add `CatalogParityTests`: over `IntentCatalog.shared.sharedIds()`, assert both
   routers return a non-error `ControlResponse`.

### Acceptance (1C)

`grep -rn "class DebugHTTPServer" Sources` empty. `LabanDebugTests` pass unchanged:
same JSON fields, `MouseActionResult.mouseTracking`/`sent` preserved, `image/png` +
`x-asciicast` bodies/headers, `laban-agent --debug-server=127.0.0.1:0` emits a
`ControlReadiness` line, unknown action still returns `ActionResult(ok:false)` (not
404). `scripts/check` green throughout. Parity test fails if a router drops a shared
intent. `feedOutput` → 404 on `.gui`, accepted on `.headless`.

---

## Milestone 1D — Generate discovery; gate schema consistency

**Scope.** Emit the `/debug` discovery doc from the catalogs (byte-stable, legacy
schema paths); gate catalog↔schema consistency route-aware; author new-intent schemas
via `SchemaNode`; grandfather the 33 existing schemas (validate, don't regenerate).

### Concrete Steps (1D)

1. Add `LabanControlGen` (executable, deps `["LabanControl"]`). It walks
   `ControlRouteCatalog.bindings` (method/path/query/legacy schema paths/examples →
   discovery) + `IntentCatalog`/`.fixture` (actions/capabilities). Emit the `/debug`
   discovery doc with the **same structure + schema paths** as today (the bindings
   carry the legacy paths verbatim, so the doc is byte-stable). For **new** intents
   whose descriptors carry `SchemaNode`s, emit `schemas/debug/<name>.schema.json`
   deterministically (`.sortedKeys`); grandfathered routes keep their hand-written
   files untouched.
2. Wire into `scripts/check`: regenerate the discovery doc to a temp dir and `diff`
   against committed (**fail on diff**); validate **route-aware** that every binding's
   declared legacy schema files exist, every schema is referenced, and every
   descriptor has a `requiredCapability` (`IntentCatalog.validate()`); fail otherwise.
3. Commit the generated discovery doc.

### Acceptance (1D)

The `/debug` discovery response is **byte-identical** to the pre-1D commit (same
endpoints + `schemas/debug/*` paths). Deleting a referenced schema → `scripts/check`
fails. Adding a descriptor with no capability → fails. A new SchemaNode-backed intent
emits a deterministic schema (rerun → no `git diff`). `scripts/check` green.

## Validation and Acceptance

From the repo root:

    swift test --filter IntentCatalogTests        # 1A
    swift test --filter LabanControl               # 1B — adapter (spy) + dual-surface server
    swift test --filter ControlServerPhase0        # 1B — live GUI wire preserved (in LabanAppTests)
    swift test --filter LabanDebug                 # 1C — full surface; ActionResult/MouseActionResult/binary/readiness preserved
    swift test --filter CatalogParityTests         # 1C
    ./scripts/check                                 # contract checker green THROUGHOUT; 1D discovery byte-stable + gated
    ./scripts/build-app

…all pass, and: one input vocabulary + one route catalog; one server in
`LabanControl` (deps `["LabanCore"]`, AppKit-free) mounted by GUI (ephemeral →
`control.json`) and `laban-agent` (`start(host:port:)` → `ControlReadiness`);
`grep -rn "class DebugHTTPServer" Sources` empty; every legacy JSON shape, binary
body, the `/debug` discovery doc + `schemas/debug/*` paths, and the readiness JSON
are byte-stable; unknown vs unavailable actions behave per C6; schemas validated
route-aware.

## Decision Log

- Four self-contained milestones; ADR 0023 placement (types `LabanCore`; server/
  adapter/route-catalog/generator `LabanControl`; live router `LabanApp`; headless
  router `LabanDebug`). 2026-06-20 / Claude.
- (C1) router returns `ControlResponse` encoding its own DTO — `LabanControl` imports
  neither GUI nor headless DTOs, and `/debug/actions` is non-uniform (mouse →
  `MouseActionResult`). 2026-06-20 / Claude.
- (C2, review-3) `ControlResponse.json` pins the legacy encoder (`.iso8601` +
  `.sortedKeys`) and `.error` matches `jsonError`, or wire bytes drift silently.
  2026-06-20 / Claude.
- (C4 + P0-3/P0-4, review-3) the `HTTPBinding` carries the **exact existing
  route-level schema paths** (discovery byte-stable); Phase 1 grandfathers the 33
  hand-written schemas (validate, not regenerate); `SchemaNode` is a realistic
  JSON-Schema subset for authoring **new** intents; schema-presence validation is
  route-aware. 2026-06-20 / Claude.
- (C6 + P1-5/P1-8, review-3) availability is checked on the resolved intent id using
  `IntentCatalog.all` (so fixture ids are *known* and gated, not *unknown*); the
  resolver taxonomy separates malformed (400) / unknown (legacy `ActionResult`
  failure) / unavailable (404). 2026-06-20 / Claude.
- (C7 + P0-1, review-3) relocate the readiness type to `LabanCore` as
  `ControlReadiness`; `LabanDebug` keeps `typealias DebugReadiness = ControlReadiness`
  so `laban-agent` compiles unchanged. `LabanControl` cannot import `LabanDebug`.
  2026-06-20 / Claude.
- (C9 + P1-6, review-3) split public `HTTPBinding` metadata from internal
  `ControlRoute` closures; the generator walks metadata only. 2026-06-20 / Claude.
- (P0-2, review-3) do **not** move the Phase 0 tests wholesale — live-router/AppModel
  tests stay in `LabanAppTests`; `LabanControlTests` uses a spy `IntentRouter` and has
  no `LabanApp` dependency. 2026-06-20 / Claude.
- (C8) conservative GUI availability; (C5) capability classified not enforced
  (ADR 0024 = Phase 2); keep `/debug/*` namespace (design §4.4). 2026-06-20 / Claude.
- (C8, parity) Honored C8's gui:true list by *implementing* `terminal.typeText`/
  `terminal.sendKey` in `LiveIntentRouter` (rather than demoting them to
  `headlessOnly`), keeping the 1A starter-availability test intact. Key-name
  parsing lifted to shared `LabanCore.ControlKeyName` so both surfaces resolve a
  key the same way; the headless router keeps routing actions by raw body
  (`.legacyDebugAction` → `applyAction`), so the parity test exercises each
  surface through its real path, not cross-router typed dispatch. 2026-06-20 / Claude.

## Review Gate

A fresh-state agent verifies (mechanical; from repo root):

- [ ] `grep -rn "import AppKit\|import Cocoa" Sources/LabanControl Sources/LabanCore/Intents` → nothing; `LabanControl` deps in `Package.swift` are exactly `["LabanCore"]`; `grep -rn "import LabanDebug" Sources/LabanControl` → nothing.
- [ ] `ControlReadiness` is defined in `LabanCore`; `LabanDebug` has `typealias DebugReadiness = ControlReadiness`.
- [ ] `LabanControlTests` target deps are `["LabanControl","LabanCore"]` (no `LabanApp`); it uses a spy router.
- [ ] `grep -rn "class DebugHTTPServer" Sources` → nothing (after 1C).
- [ ] Per-intent availability + taxonomy: a spy-router test asserts (a) `feedOutput` on `.gui` → 404 with no router call; (b) an unknown action → `ActionResult(ok:false)` (not 404); (c) malformed body → 400.
- [ ] Mouse wire: a headless mouse-action test asserts the JSON has `mouseTracking` and `sent`.
- [ ] Encoder: `ControlResponse.json` uses `.iso8601` + `.sortedKeys` (grep the impl); `.error` body is `{"error":…}`.
- [ ] Discovery byte-stable: the `/debug` response (endpoints + `schemas/debug/*` paths) is unchanged vs the pre-1D commit (diff); `grep -rn "schemas/control" .` → nothing.
- [ ] `DebugAction → Intent` `switch` has no `default`; no `Decodable` request body used by `LabanControl` is `internal` in `LabanDebug`.
- [ ] No reflection (`grep -rni "Mirror(\|\.reflect" Sources/LabanControl Sources/LabanCore/Intents` → nothing); no third-party package added.
- [ ] `./scripts/check` exits 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- 1A additive; reruns safe. Each 1C group is small/revertible; the contract checker is
  rewritten before the deletion so a revert never strands CI. 1D writes only the
  discovery doc (+ any new SchemaNode schema) deterministically; reruns are no-ops.
  `LabanControl` adds no runtime behavior until mounted (1B).

## Interfaces and Dependencies

End-state package graph (additions **bold**):

    LabanCore         deps [LabanTerminalCore, LabanRenderer]   + Sources/LabanCore/Intents/* (incl. ControlReadiness, ControlResponse, HTTPBinding, IntentCatalog.all) + ALL relocated public request payloads
    **LabanControl**  deps [LabanCore]                          server (route-table adapter, dual-surface start, ControlRoute closures), ControlRouteCatalog, advertisement, policy
    LabanDebug        deps [LabanCore, **LabanControl**, LabanRenderer, LabanTerminalCore]   HeadlessIntentRouter (encodes ActionResult/MouseActionResult/…), runtime; `typealias DebugReadiness = ControlReadiness`
    LabanApp          deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   LiveIntentRouter; mounts (surface:.gui)
    LabanAgent        deps [LabanCore, **LabanControl**, LabanRenderer, LabanDebug, LabanTerminalCore]   mounts (surface:.headless) via start(host:port:)
    **LabanControlGen** (exe, 1D)  deps [LabanControl]          deterministic discovery + new-intent-schema generator (walks HTTPBinding metadata)

No third-party packages; `LabanControl` uses only `Foundation`/`Darwin`/`LabanCore`.
