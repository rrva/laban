# Phase 0: Loopback Control Seam Inside the Running Laban GUI

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(at the repository root). Keep `Progress` and `Validation and Acceptance`
current as work proceeds. It is the first executable slice of the program
design in `execplans/agent-first-terminal-design.md` (read that for the
multi-phase context; this file is self-contained for the Phase 0 work).

## Purpose / Big Picture

Today the Laban macOS terminal app (`LabanApp`, the windowed program a person
launches) cannot be inspected or driven by a program over the network. A rich
HTTP control surface exists, but only inside a *separate* headless binary
(`laban-agent`) that renders offscreen — not inside the GUI the user actually
runs. So an agent cannot ask the running window "what tabs are open?" or tell
it "switch to tab 0."

After this change, when the GUI is launched with the environment variable
`LABAN_CONTROL_SERVER=1`, it starts a tiny HTTP server bound to loopback
(`127.0.0.1`, on a random free port), writes its address and a secret token to
a file, and answers two authenticated requests against the **live** window:

- `GET /debug/state` → the live list of tabs and which one is active.
- `POST /debug/actions` with `{"action":"selectTab","index":N}` → switches the
  active tab in the running window.

You can see it working: launch the app with the variable set, `curl` the state,
`POST` a `selectTab`, `curl` state again, and observe `activeTabId` change (and
the window visibly switch tabs). Default launches (without the variable) are
completely unchanged — no socket is opened.

This is a deliberately small spike. It proves the load-bearing seam — *a server
hosted in the GUI process, authenticated, mutating and reading the live
`AppModel`* — that later phases generalize into a full intent registry. It is
**off by default** and gated behind the environment variable precisely so it
can land before the security model (capability tiers, the flip to
on-by-default) exists.

## Context and Orientation

You need no prior Laban knowledge. Definitions of every term used below:

- **Loopback / `127.0.0.1`**: the local-only network address. A socket bound
  here is reachable only by processes on the same machine, never the network.
- **`LabanApp`**: the SwiftPM executable target for the windowed macOS app.
  Source under `Sources/LabanApp/`. Built into a bundle at
  `.build/laban/Laban.app` by `./scripts/build-app`.
- **`AppModel`** (`Sources/LabanCore/AppModel.swift`, class `AppModel`): the
  app's in-memory state — the list of tabs and which is active. It is
  AppKit-free and **internally locked** (every accessor takes an internal
  lock via `withModelLock`), so reading/mutating it from another thread is
  safe. Relevant members:
  - `public var tabs: [Tab]` — current tabs (a `Tab` has `id: String`,
    `isActive: Bool`, `sessionId: String?`).
  - `public var activeTab: Tab?` — the active tab.
  - `public func selectTab(_ tabId: Tab.ID)` — make a tab active (this is the
    exact call the GUI keyboard path ends in; see below).
  - `public func createTab() throws -> Tab` — append a new tab (used by tests).
- **`MainWindowController`** (`Sources/LabanApp/MainWindowController.swift`):
  builds and shows the window. Its `static func makeAndShow(...)` constructs
  the `AppModel` (assigned to local `let model`) and an
  `AppSessionCoordinator`, builds the controller, and returns it. Near the end
  it sets `controller.sessionCoordinator = sessionCoordinator` (around line
  307). The controller stores `private(set) var model: AppModel?` and
  `private(set) var sessionCoordinator: AppSessionCoordinator?`.
- **The GUI tab-switch path** (for fidelity): a keyboard tab switch runs
  `TerminalBitmapView.selectTab(at:)` →
  `selectTabPreservingSelection(id)` → `model.selectTab(id)` plus a render
  invalidation. So `model.selectTab(id)` is the authoritative state change; it
  calls `notifyWorkspaceMutation()` which the app already observes to refresh.
  Phase 0 calls `model.selectTab` directly (see Decision Log); routing through
  the keyboard path is a later phase.
- **Existing server, for reference only** (`Sources/LabanDebug/DebugHTTPServer.swift`):
  the headless server. Its `start(host:port:)` (line ~501) shows the exact
  pattern to mirror — bind `127.0.0.1`, `listen`, `getsockname` to discover the
  port chosen for port `0`, `makeBearerToken()` (line ~772), and
  `constantTimeEquals` (line ~761). **Do not call into it**; it is wired to the
  headless runtime. Phase 0 writes its own minimal server so the spike has no
  coupling. NOTE: that server checks the *host parameter* but does **not**
  validate the request `Host`/`Origin` headers — Phase 0 adds that.
- **`scripts/check`** runs structural/contract/lint gates (and requires every
  `execplans/active/*.md` to contain `## Progress` and `## Validation and
  Acceptance`). It does **not** run tests. **`scripts/test`** runs `swift test`.
- **`scripts/build-app`** builds and ad-hoc-signs `.build/laban/Laban.app`.

New code in this plan lives under a new directory
`Sources/LabanApp/Control/`. It is AppKit-free and will relocate to a dedicated
`LabanControl` SwiftPM target in Phase 1; for this spike it stays in `LabanApp`
to avoid target wiring.

## Plan of Work

Add four new files and make two small edits.

1. **`Sources/LabanApp/Control/ControlRouter.swift`** — the seam types and
   protocol. `ControlTabState`, `ControlState`, `ControlActionResult`
   (all `Codable`), and `protocol ControlRouter` with `snapshotState() ->
   ControlState` and `selectTab(index:) -> ControlActionResult`.

2. **`Sources/LabanApp/Control/LiveIntentRouter.swift`** — a `ControlRouter`
   holding a `weak var model: AppModel?`. `snapshotState()` reads
   `model.tabs`/`model.activeTab`; `selectTab(index:)` bounds-checks then calls
   `model.selectTab(tabs[index].id)`. Mutation hops to the main thread (AppKit
   correctness); reads are safe either way because `AppModel` is internally
   locked.

3. **`Sources/LabanApp/Control/LabanControlServer.swift`** — a minimal HTTP/1.1
   loopback server mirroring `DebugHTTPServer`'s bind/token pattern. Exposes:
   - `func start() throws -> (url: String, token: String)` — bind
     `127.0.0.1:0`, `listen`, `getsockname` for the port, mint a 32-byte hex
     token, spawn an accept loop on a background `Thread`.
   - A pure, unit-testable guard:
     `static func evaluateGuard(host:origin:authorization:token:) ->
     GuardOutcome` returning `.forbidden` (bad/missing `Host`, or any `Origin`
     present), `.unauthorized` (bad/missing bearer token), or `.ok`.
   - Routing: `GET /debug/state` → `router.snapshotState()`; `POST
     /debug/actions` with `{"action":"selectTab","index":N}` →
     `router.selectTab(index:)`. Everything else → `404`.

4. **`Sources/LabanApp/Control/ControlAdvertisement.swift`** — writes/removes
   `control.json` (`{url, token, pid, runId}`, mode `0600`, written atomically)
   under `$LABAN_CONTROL_DIR` or, if unset, the app-support dir
   `~/Library/Application Support/Laban/` (same convention as
   `Sources/LabanApp/EventLog.swift`).

5. **Edit `Sources/LabanApp/MainWindowController.swift`**: add
   `var controlServer: LabanControlServer?`; near the end of `makeAndShow`
   (right after `controller.sessionCoordinator = sessionCoordinator`), if
   `ProcessInfo.processInfo.environment["LABAN_CONTROL_SERVER"] == "1"`, build a
   `LiveIntentRouter(model: model)`, start a `LabanControlServer`, write
   `control.json`, and retain the server on the controller. Wrap in `do/catch`
   and log failures via `AppLog.app.error` — a server failure must never block
   the window.

6. **Edit the app teardown** (`applicationWillTerminate` in
   `Sources/LabanApp/AppDelegate.swift`): best-effort `ControlAdvertisement.remove()`.

7. **Add `Tests/LabanAppTests/ControlServerPhase0Tests.swift`** — see
   Validation and Acceptance.

## Concrete Steps

All commands run from the repository root `/Users/rrj/wrk/laban`.

1. Create the four new files and apply the two edits described in Plan of Work.
   Reference implementations:

   `Sources/LabanApp/Control/ControlRouter.swift`:

       import Foundation

       public struct ControlTabState: Codable {
         public let id: String
         public let index: Int
         public let active: Bool
         public let sessionId: String?
       }

       public struct ControlState: Codable {
         public let tabs: [ControlTabState]
         public let activeTabId: String?
       }

       public struct ControlActionResult: Codable {
         public let ok: Bool
         public let activeTabId: String?
         public let error: String?
       }

       /// The seam every control transport terminates at. Phase 0 has one
       /// query (state) and one control intent (selectTab).
       public protocol ControlRouter: AnyObject {
         func snapshotState() -> ControlState
         func selectTab(index: Int) -> ControlActionResult
       }

   `Sources/LabanApp/Control/LiveIntentRouter.swift`:

       import Foundation
       import LabanCore

       /// Routes control requests against the live AppModel the GUI renders
       /// from. Server callbacks arrive on a background thread; mutations hop
       /// to the main thread for AppKit correctness. Reads are safe off-main
       /// because AppModel is internally locked.
       final class LiveIntentRouter: ControlRouter {
         private weak var model: AppModel?
         init(model: AppModel) { self.model = model }

         func snapshotState() -> ControlState {
           onMain {
             guard let model = self.model else {
               return ControlState(tabs: [], activeTabId: nil)
             }
             let tabs = model.tabs
             let states = tabs.enumerated().map { i, t in
               ControlTabState(id: t.id, index: i, active: t.isActive,
                               sessionId: t.sessionId)
             }
             return ControlState(tabs: states, activeTabId: model.activeTab?.id)
           }
         }

         func selectTab(index: Int) -> ControlActionResult {
           onMain {
             guard let model = self.model else {
               return ControlActionResult(ok: false, activeTabId: nil,
                                          error: "model released")
             }
             let tabs = model.tabs
             guard index >= 0, index < tabs.count else {
               return ControlActionResult(ok: false,
                 activeTabId: model.activeTab?.id,
                 error: "index \(index) out of range 0..<\(tabs.count)")
             }
             model.selectTab(tabs[index].id)
             return ControlActionResult(ok: true,
               activeTabId: model.activeTab?.id, error: nil)
           }
         }

         private func onMain<T>(_ body: @escaping () -> T) -> T {
           if Thread.isMainThread { return body() }
           return DispatchQueue.main.sync(execute: body)
         }
       }

   `Sources/LabanApp/Control/LabanControlServer.swift` — mirror the bind/accept
   pattern at `Sources/LabanDebug/DebugHTTPServer.swift:501-560`. Required
   behavior (a reference skeleton; keep the guard logic exactly as specified):

       import Darwin
       import Foundation

       enum GuardOutcome: Equatable { case ok, unauthorized, forbidden }

       final class LabanControlServer {
         private let router: ControlRouter
         private var fd: Int32 = -1
         private var token: String = ""
         private var thread: Thread?
         init(router: ControlRouter) { self.router = router }

         /// Bind 127.0.0.1:0, listen, discover the port, mint a token, and
         /// start accepting on a background thread. Returns the base URL and
         /// token to advertise.
         func start() throws -> (url: String, token: String) {
           // ... socket()/bind(127.0.0.1, port 0)/listen/getsockname exactly
           // as DebugHTTPServer.start does. Set self.token = Self.makeToken().
           // Spawn a Thread running acceptLoop(). Return
           // ("http://127.0.0.1:<port>", token).
         }

         /// Pure guard used by both the live path and unit tests.
         static func evaluateGuard(host: String?, origin: String?,
                                   authorization: String?, token: String)
           -> GuardOutcome {
           // Any Origin header present => a browser is calling => forbid.
           if let origin, !origin.isEmpty { return .forbidden }
           guard isLoopbackHost(host) else { return .forbidden }
           guard let authorization,
                 authorization.lowercased().hasPrefix("bearer "),
                 constantTimeEquals(String(authorization.dropFirst(7)), token)
           else { return .unauthorized }
           return .ok
         }

         static func isLoopbackHost(_ host: String?) -> Bool {
           guard let host, !host.isEmpty else { return false } // Host required
           // strip ":port"; accept 127.0.0.1, localhost, [::1]
           if host.hasPrefix("[") {
             return host.hasPrefix("[::1]")
           }
           let h = host.split(separator: ":").first.map(String.init) ?? host
           return h == "127.0.0.1" || h == "localhost"
         }

         static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
           let x = Array(a.utf8), y = Array(b.utf8)
           if x.count != y.count { return false }
           var diff: UInt8 = 0
           for i in x.indices { diff |= x[i] ^ y[i] }
           return diff == 0
         }

         static func makeToken() -> String {
           var g = SystemRandomNumberGenerator()
           return (0..<32).map { _ in String(format: "%02x",
             UInt8.random(in: 0...255, using: &g)) }.joined()
         }

         // acceptLoop(): per connection, read until "\r\n\r\n", parse the
         // request line ("METHOD PATH HTTP/1.1") and headers (Host, Origin,
         // Authorization, Content-Length); read Content-Length more bytes for
         // the body. Then:
         //   let outcome = Self.evaluateGuard(host:..., origin:...,
         //                  authorization:..., token: self.token)
         //   .forbidden    -> 403 {"error":"forbidden"}
         //   .unauthorized -> 401 {"error":"missing or invalid bearer token"}
         //   .ok -> route:
         //     GET  /debug/state    -> 200 JSON of router.snapshotState()
         //     POST /debug/actions  -> decode {"action","index"};
         //        action=="selectTab" -> 200 JSON of router.selectTab(index:)
         //        else -> 400 {"error":"unsupported action"}
         //     otherwise -> 404 {"error":"not found"}
         // Close the connection after each response (Connection: close).
       }

   `Sources/LabanApp/Control/ControlAdvertisement.swift`:

       import Foundation

       enum ControlAdvertisement {
         static func directory() -> URL {
           if let dir = ProcessInfo.processInfo.environment["LABAN_CONTROL_DIR"],
              !dir.isEmpty {
             return URL(fileURLWithPath: dir, isDirectory: true)
           }
           let base = FileManager.default.urls(for: .applicationSupportDirectory,
             in: .userDomainMask).first
             ?? URL(fileURLWithPath: NSHomeDirectory())
           return base.appendingPathComponent("Laban", isDirectory: true)
         }
         static func write(url: String, token: String, pid: Int32,
                           runId: String) throws {
           let dir = directory()
           try FileManager.default.createDirectory(at: dir,
             withIntermediateDirectories: true)
           let file = dir.appendingPathComponent("control.json")
           let payload = ["url": url, "token": token,
                          "pid": String(pid), "runId": runId]
           let data = try JSONSerialization.data(withJSONObject: payload,
             options: [.sortedKeys])
           try data.write(to: file, options: .atomic)
           try? FileManager.default.setAttributes(
             [.posixPermissions: 0o600], ofItemAtPath: file.path)
         }
         static func remove() {
           try? FileManager.default.removeItem(
             at: directory().appendingPathComponent("control.json"))
         }
       }

   `MainWindowController` mount block (after
   `controller.sessionCoordinator = sessionCoordinator`):

       if ProcessInfo.processInfo.environment["LABAN_CONTROL_SERVER"] == "1" {
         do {
           let router = LiveIntentRouter(model: model)
           let server = LabanControlServer(router: router)
           let info = try server.start()
           let runId = ProcessInfo.processInfo.environment["LABAN_RUN_ID"]
             ?? "gui-\(ProcessInfo.processInfo.processIdentifier)"
           try ControlAdvertisement.write(url: info.url, token: info.token,
             pid: ProcessInfo.processInfo.processIdentifier, runId: runId)
           controller.controlServer = server
           AppLog.app.info("control server: \(info.url)")
         } catch {
           AppLog.app.error("control server failed: \(String(describing: error))")
         }
       }

2. Build:

       ./scripts/build-app

   Expect it to end with `build-app: .build/laban/Laban.app/Contents/MacOS/LabanApp`
   and no `error:` lines.

3. Run the automated tests:

       swift test --filter ControlServerPhase0Tests

   Expect `0 failures`.

4. Run the structural gate:

       ./scripts/check

   Expect `check` to pass (this plan supplies the required `## Progress` and
   `## Validation and Acceptance` headings).

5. Manual GUI verification — see Validation and Acceptance, "Manual".

## Validation and Acceptance

### Automated (runs in `swift test`, no WindowServer needed)

Add `Tests/LabanAppTests/ControlServerPhase0Tests.swift` with these cases.
Construct an `AppModel` with two tabs like so:

    let model = try AppModel()            // starts with one tab
    _ = try model.createTab()             // now two tabs
    let router = LiveIntentRouter(model: model)

1. `testGuardMatrix` — call `LabanControlServer.evaluateGuard` directly:
   - `evaluateGuard(host: "127.0.0.1:5", origin: nil, authorization: "Bearer T", token: "T")` == `.ok`
   - `evaluateGuard(host: "127.0.0.1:5", origin: nil, authorization: nil, token: "T")` == `.unauthorized`
   - `evaluateGuard(host: "127.0.0.1:5", origin: nil, authorization: "Bearer X", token: "T")` == `.unauthorized`
   - `evaluateGuard(host: "evil.com", origin: nil, authorization: "Bearer T", token: "T")` == `.forbidden`
   - `evaluateGuard(host: nil, origin: nil, authorization: "Bearer T", token: "T")` == `.forbidden`
   - `evaluateGuard(host: "127.0.0.1:5", origin: "http://evil.com", authorization: "Bearer T", token: "T")` == `.forbidden`

2. `testLiveRouterSelectTabChangesActiveTab` — with the two-tab `model`/`router`:
   - `router.snapshotState().tabs.count` == 2.
   - Pick the non-active index `i` (the one whose `active == false`).
   - `let r = router.selectTab(index: i)` → `r.ok == true`,
     `r.activeTabId == model.tabs[i].id`.
   - `router.snapshotState().activeTabId == model.tabs[i].id`.

3. `testLiveRouterRejectsOutOfRange` — `router.selectTab(index: 99).ok == false`
   and `.error != nil`; `activeTabId` unchanged.

4. `testEndToEndOverLoopback` — start a real server over a live router:
   - `let server = LabanControlServer(router: router); let info = try server.start()`.
   - `GET <info.url>/debug/state` with header `Authorization: Bearer <info.token>`
     via `URLSession` → HTTP 200; decode `ControlState`; assert 2 tabs.
     (URLSession sets `Host: 127.0.0.1:<port>`, so the guard passes.)
   - `GET` the same with **no** `Authorization` header → HTTP 401.
   - `POST <info.url>/debug/actions` body `{"action":"selectTab","index":0}`
     with the token → HTTP 200; `ControlActionResult.ok == true`.
   - `GET /debug/state` again → `activeTabId` equals tab 0's id.

Acceptance: `swift test --filter ControlServerPhase0Tests` reports all cases
passing; each of cases 1–4 fails if the corresponding behavior is absent (e.g.,
delete the `Origin` check and `testGuardMatrix` fails; bind without the token
check and case 4's 401 assertion fails).

### Manual (real GUI, on a Mac with a window session)

Quit any running Laban first (so the single-instance lock is free), then:

    rm -rf /tmp/labanctl
    LABAN_CONTROL_DIR=/tmp/labanctl LABAN_CONTROL_SERVER=1 \
      ~/Laban.app/Contents/MacOS/LabanApp &
    # wait ~2s for the window, then:
    URL=$(jq -r .url   /tmp/labanctl/control.json)
    TOK=$(jq -r .token /tmp/labanctl/control.json)
    curl -s -H "Authorization: Bearer $TOK" "$URL/debug/state" | jq

Expected (one tab initially):

    { "tabs": [ { "id": "…", "index": 0, "active": true, "sessionId": "…" } ],
      "activeTabId": "…" }

Press Cmd+T in the window to open a second tab, then:

    curl -s -X POST -H "Authorization: Bearer $TOK" \
      -H "Content-Type: application/json" \
      -d '{"action":"selectTab","index":0}' "$URL/debug/actions" | jq
    curl -s -H "Authorization: Bearer $TOK" "$URL/debug/state" | jq -r .activeTabId

Expected: the `POST` returns `{"ok":true,...}`, the **window visibly switches to
the first tab**, and the final `activeTabId` is tab 0's id. Also confirm the
guards: `curl -s "$URL/debug/state"` (no token) prints the 401 JSON, and
`curl -s -H "Authorization: Bearer $TOK" -H "Host: evil.com" "$URL/debug/state"`
prints the 403 JSON. Kill the app with `kill %1` when done.

> The operator (human) launches the app here. Per project rule, an agent must
> not `open`/launch the GUI itself (it spawns a windowless instance and grabs
> the single-instance lock).

## Progress

- [ ] `Sources/LabanApp/Control/ControlRouter.swift` added.
- [ ] `Sources/LabanApp/Control/LiveIntentRouter.swift` added.
- [ ] `Sources/LabanApp/Control/LabanControlServer.swift` added (bind/token/accept + `evaluateGuard`).
- [ ] `Sources/LabanApp/Control/ControlAdvertisement.swift` added.
- [ ] `MainWindowController.makeAndShow` mounts the server behind `LABAN_CONTROL_SERVER=1`; `controlServer` property added.
- [ ] `AppDelegate.applicationWillTerminate` removes `control.json` (best effort).
- [ ] `Tests/LabanAppTests/ControlServerPhase0Tests.swift` added (cases 1–4).
- [ ] `./scripts/build-app` succeeds.
- [ ] `swift test --filter ControlServerPhase0Tests` passes.
- [ ] `./scripts/check` passes.
- [ ] Manual GUI verification transcript captured in Artifacts.

## Decision Log

- Decision: Phase 0 server lives in `Sources/LabanApp/Control/`, not a new
  `LabanControl` target.
  Rationale: keep the spike free of SwiftPM target wiring; Phase 1 relocates it
  (the code is already AppKit-free to make that mechanical).
  Date/Author: 2026-05-30 / Claude.
- Decision: the router calls `AppModel.selectTab` directly rather than routing
  through the keyboard path (`executeAppCommand`).
  Rationale: `model.selectTab` is the authoritative state change and fires
  `notifyWorkspaceMutation`; full keyboard-path fidelity is Phase 1/2 work
  (making `executeAppCommand` emit intents). The spike's acceptance is a live
  state change, which this satisfies.
  Date/Author: 2026-05-30 / Claude.
- Decision: any `Origin` header present → `403`.
  Rationale: this API has no browser client; rejecting all `Origin`-bearing
  requests is the simplest defense against browser/DNS-rebinding access while
  loopback + token guard everything else. Curl/agents send no `Origin`.
  Date/Author: 2026-05-30 / Claude.
- Decision: expose a minimal `ControlState`, not the headless `StateResponse`.
  Rationale: `StateResponse` carries `frame`/`window`/find fields that only the
  offscreen runtime computes; the spike must not couple to it.
  Date/Author: 2026-05-30 / Claude.
- Decision: keep paths `/debug/state` and `/debug/actions` (from the design
  doc's Phase 0 spec) even though this is a new server.
  Rationale: continuity with the committed design; Phase 2 reconciles the path
  namespace when the debug endpoints are re-pointed at the live router.
  Date/Author: 2026-05-30 / Claude.
- Decision: moved `agent-first-terminal-design.md` from `execplans/active/` to
  `execplans/`.
  Rationale: `scripts/check` requires `## Progress` + `## Validation and
  Acceptance` on every `execplans/active/*.md`; the design doc is a program
  roadmap, not an executable plan, so it belongs outside `active/`.
  Date/Author: 2026-05-30 / Claude.

## Review Gate

A separate agent with fresh state must verify the following before this plan is
marked done. Run from the repository root.

- [ ] `swift test --filter ControlServerPhase0Tests` exits 0 and reports ≥4
      tests, 0 failures.
- [ ] Guard matrix is real: in `ControlServerPhase0Tests.swift`, confirm
      assertions exist for all six `evaluateGuard` rows (ok / unauthorized×2 /
      forbidden×3) listed under Validation case 1.
- [ ] Default-off: `grep -n 'LABAN_CONTROL_SERVER' Sources/LabanApp/MainWindowController.swift`
      shows the server is started only inside an `== "1"` guard, and
      `grep -rn 'LabanControlServer(' Sources/LabanApp` shows no construction
      outside that guard or the test target.
- [ ] `grep -rn 'Origin' Sources/LabanApp/Control/LabanControlServer.swift`
      shows the `Origin`-present → `.forbidden` rule.
- [ ] `control.json` is written `0600` and atomically: confirm
      `.posixPermissions: 0o600` and `options: .atomic` in
      `ControlAdvertisement.swift`.
- [ ] `./scripts/build-app` exits 0 and prints the final
      `build-app: .../LabanApp` line.
- [ ] `./scripts/check` exits 0.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Idempotence and Recovery

- Re-running the steps is safe: the server binds an ephemeral port (`0`), so
  repeated launches never collide; `control.json` is rewritten atomically.
- If `start()` throws (e.g., bind failure), the `do/catch` logs and the window
  still comes up normally — recovery is "launch again."
- On app exit, `control.json` is removed best-effort; a stale file from a crash
  is harmless (it points at a dead port) and is overwritten on next launch.
- Tests use ephemeral ports and their own `AppModel`; they leave no artifacts.

## Interfaces and Dependencies

End-state types (all new, in `Sources/LabanApp/Control/`):

    public struct ControlTabState: Codable { id: String; index: Int; active: Bool; sessionId: String? }
    public struct ControlState: Codable { tabs: [ControlTabState]; activeTabId: String? }
    public struct ControlActionResult: Codable { ok: Bool; activeTabId: String?; error: String? }
    public protocol ControlRouter: AnyObject {
      func snapshotState() -> ControlState
      func selectTab(index: Int) -> ControlActionResult
    }
    final class LiveIntentRouter: ControlRouter   // init(model: AppModel)
    enum GuardOutcome: Equatable { case ok, unauthorized, forbidden }
    final class LabanControlServer {
      init(router: ControlRouter)
      func start() throws -> (url: String, token: String)
      static func evaluateGuard(host: String?, origin: String?, authorization: String?, token: String) -> GuardOutcome
    }
    enum ControlAdvertisement { static func write(url:token:pid:runId:) throws; static func remove() }

Dependencies: only `Foundation`/`Darwin`/`LabanCore` (for `AppModel`) and
`LabanApp`'s existing `AppLog`. No new SwiftPM dependencies, no new target.
`MainWindowController` gains `var controlServer: LabanControlServer?`.

## Artifacts and Notes

(Capture the manual transcript here once run — the `curl` state/select/state
sequence showing `activeTabId` changing — as the evidence the live GUI seam
works.)
