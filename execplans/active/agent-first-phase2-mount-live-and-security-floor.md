# Phase 2: Mount Live + Security Floor + Flip the Default

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. It is the third executable phase of the program in
`execplans/agent-first-terminal-design.md` (Phase 2; read §3.1, §4.2, **§5 in
full**, and §6 "Phase 2" there) and is governed by **ADR 0023** (architecture)
and **ADR 0024** (security). Phase 0 shipped as
`execplans/completed/agent-first-phase0-control-seam.md` (commit `0a2a230`);
Phase 1 shipped as
`execplans/completed/agent-first-phase1-intent-registry-and-labancontrol.md`
(Review Gate APPROVED 2026-06-20).

Delivered as five independently-verifiable milestones (**2A → 2E**). **Read
"Cross-cutting design contracts" (C1–C9) before any milestone** — they encode the
ADR 0024 security floor and the parity rules that keep the live and headless
surfaces identical.

> **Status: DRAFT — REVISED 2026-06-20 after security review (not started).** This
> plan is authored from the program design and the current Phase-1 end state.
> Refine each milestone's Concrete Steps as you execute and discover; keep this
> document self-contained per `PLANS.md`.

## Blocking Corrections (must-fix before implementation)

A 2026-06-20 static security review against the current source (verified file by
file) found contradictions between this plan, ADR 0024, and the shipped code. The
following corrections are **normative** and override any conflicting prose later in
this document. Each is grounded in code that exists today.

1. **Token grant table (ADR 0024 §"Two-tier token model", verified).** `control.json`
   advertises an **observe-only** token. The env-injected control token grants
   `{.observe, .observeSensitive, .control}` — **not** `.clipboard`. `.clipboard` is
   a *separate* tier the control token does **not** imply; no token grants it by
   default in Phase 2. The headless **fixture** token grants
   `{.fixture, .observe, .observeSensitive, .control}` (test-only; `validate()`
   already forbids `.fixture` on the GUI surface) so the headless wire stays
   byte-stable (C9) — `grants(fixture) = {.fixture, .observe}` would `403` existing
   `LabanDebugTests` control flows.

2. **Live `clipboard.read` is OUT of scope.** ADR 0024 §"Standing constraints" is
   "OSC 52 write only; read **never**", and C5 below says the same — yet 2B's draft
   listed `clipboard.read` as a live read. Remove it. Clipboard read is not
   implemented on any surface this phase; a future `.clipboard` opt-in is a separate
   design.

3. **Rich debug DTOs are `.observeSensitive`, not `.observe`.** The existing
   `SessionResponse` (workspace cwd/repo, process `command`/`arguments`/`pid`, agent
   metadata, optional `grid`), `SelectionResponse.text`, `FindStateResponse.needle`,
   and the clipboard DTO (`lastCopyText`/`lastPasteText`) all expose data ADR 0024
   classifies `.observeSensitive`. The observe token (the one in `control.json`, the
   one any same-user process can read) must **not** receive these. Observe-token
   reads are limited to genuinely non-sensitive DTOs (e.g. `app.state`,
   `terminal.modes`, `scrollIndicator.state`) or explicitly redacted variants;
   sensitive reads return `403` with the observe token and `200` with the control
   token. (Corrects 2B's draft acceptance that handed `/debug/sessions`,
   `/debug/selection`, `/debug/find/state` to the observe token.)

4. **Mint credentials BEFORE any session is created/restored.** Today
   `MainWindowController` ensures/restores sessions (~L253 `ensureSessions`, ~L258
   `sweepOrphanedSessions`) **before** it mounts the control server (~L510). A token
   minted at mount time never reaches the initial/restored sessions' env — exactly
   the agent-first case. Fix: mint `ControlCredentials` and bind the server (to learn
   the ephemeral `LABAN_CONTROL_URL`) **above** `ensureSessions`, then inject the
   control token + URL through the **shared** `ShellIntegrationLaunch.environmentOverrides`
   hook — which feeds **all three** backends (in-process `environment:`, laband
   `environmentPatch`, labpty `envp`), not labpty alone. The model exists by ~L107,
   so there is a window between model creation and `ensureSessions`.

5. **`ControlReadiness` stays byte-stable; the control token is never serialized.**
   `ControlReadiness` is `{debugServer, debugToken, pid, runId}` and `laban-agent`
   prints it as one `.sortedKeys` JSON line — adding a field changes that wire and
   would leak the env-only token over stdout. **Do not** add the control token to
   readiness JSON or any world-path file. Headless `debugToken` keeps its current
   authority (so `LabanDebugTests` pass). GUI credential surfacing is internal:
   `start()` returns `ControlCredentials` to the in-process caller; only `observe`
   is written to `control.json`; `control` is handed to the env-injection path.

6. **Deny-by-default is NOT true today — make it true.** The catalog builder helper
   auto-fills `requiredCapability` (`defaultCapability(for:)`: `query/artifact →
   .observe`, `action/wait/event → .control`) and defaults `dataSensitivity` to
   `.nonSensitiveState`; `validate()` checks duplicates/fixture-in-GUI/schemas but
   **not** explicit classification. So a new sensitive query silently becomes
   observe-readable. Remove the implicit capability/sensitivity defaults (or track
   an `explicit` flag) and make `validate()` **fail** unless every descriptor
   declares both `requiredCapability` and `dataSensitivity` explicitly. (Corrects
   C3's claim that the gate "already requires the field".)

7. **Live input must share the human validation path.** `LiveIntentRouter.typeText`
   calls `session.write(Array(text.utf8))` and `sendKey` calls `session.sendKey(...)`
   **directly**, bypassing the `sessionCoordinator.write(...)` + paste-sanitizer +
   `encodeKey`/`encodePaste` path human keystrokes take in `TerminalBitmapView`. For
   laband/labpty backends this can diverge from human input and skip sanitization.
   Route programmatic input through the same coordinator/input-adapter path (C5).

8. **Host-header parsing accepts non-numeric ports (real bug).** `isLoopbackHost`
   splits on `:` and validates only the label, so `localhost:evil`, `127.0.0.1:evil`,
   and `[::1]:evil` are wrongly **accepted** as loopback. Fix the parser to require a
   numeric port (or empty) after the host, and add these to the deny matrix — this is
   a code fix plus tests, not tests alone.

## Purpose / Big Picture

After Phase 1 there is **one server** (`LabanControlServer` in `LabanControl`),
**one route catalog** (`ControlRouteCatalog`), and **one typed vocabulary**
(`IntentCatalog`) mounted by both the GUI (`LiveIntentRouter`, surface `.gui`,
ephemeral → `control.json`, behind `LABAN_CONTROL_SERVER=1`) and `laban-agent`
(`HeadlessIntentRouter`, surface `.headless`). But two gaps remain before an agent
can safely drive the **real app a human is using**:

1. **The GUI serves almost nothing.** `LiveIntentRouter` implements only
   `app.state`, `tab.select`, `terminal.typeText`, `terminal.sendKey`. Every other
   read (`session.list`, `session.detail`, `render.state`, `find.state`,
   `selection.read`, `app.accessibility`, `terminal.modes`, …) is `headlessOnly`
   in the catalog and returns **404 on the GUI surface**. An agent attached to the
   running app cannot observe it.
2. **Capability is classified but not enforced, and there is one token.** The
   server mints a single token; `descriptor.requiredCapability` is metadata only;
   the guard never checks it. `control.json` carries a token that — if it granted
   control — any same-user process could read and then drive the terminal.

Phase 2 closes both:

- **Mount live.** Expand `LiveIntentRouter` to project the live `AppModel` +
  `AppSessionCoordinator` into the **same wire** the headless runtime already
  emits, so the GUI control server answers the observe surface for the real
  window. Shared `AppModel → DTO` projections move to `LabanCore` so both routers
  are byte-identical by construction.
- **Security floor (ADR 0024 §5).** Two credentials, not one: an **observe
  token** in `control.json` (`.observe` only) and a **control/sensitive token**
  injected into the env of children Laban spawns (`.control` + `.observeSensitive`).
  A `LabanControlPolicy` **generated from the catalog** enforces
  `requiredCapability` per request (deny-by-default for unclassified intents).
  Add the "agent attached" indicator, a user-facing disable switch, audit to the
  `EventLog`, and the guarantee that **no token value is ever logged**.
- **Catalog-parity test.** A test that fails if either router omits a shared
  intent or emits a divergent shape for it.
- **Flip the default.** `observe-on-by-default` turns ON — but only once the §5.4
  **release checklist** (nine items, reproduced verbatim in 2E) holds. The GUI is
  unchanged for humans throughout.

**The wire stays byte-stable for everything Phase 1 shipped.** `laban-agent` and
`LabanDebugTests` see identical headless responses; the `/debug` discovery doc and
`schemas/debug/*` paths are unchanged; the only *new* observable behavior is (a)
the GUI now answers the observe surface, (b) capability tiers return `403` where
the credential is insufficient, and (c) the default-on flip in 2E.

## Progress

> All milestones **not started**. Update each item to `[x] (date)` as it lands;
> split partially-done items into "done" / "remaining" per `PLANS.md`.

Milestone 2A — Capability enforcement + two-tier tokens (`LabanControl`):
- [ ] `ControlCredentials { observe, control }` minted in `LabanControlServer.start*` and returned to the in-process caller; `control.json` carries **only** the observe token; the control token is returned for child-env injection (C1). `ControlReadiness` JSON is unchanged — the control token is never serialized (Blocking Correction 5).
- [ ] `LabanControlPolicy` (generated from `IntentCatalog`) resolves a presented bearer token → granted `Set<Capability>` (`control` grants `{.observe,.observeSensitive,.control}`, **no `.clipboard`**); per request, after availability, enforce `descriptor.requiredCapability ∈ granted` → else `403 {"error":"insufficient capability"}` (C2/C3). Unknown intent → deny.
- [ ] Deny-by-default made real (Blocking Correction 6): remove the catalog builder's implicit `requiredCapability`/`dataSensitivity` defaults; `validate()` + `LabanControlGen` fail on any unclassified descriptor.
- [ ] Guard taxonomy preserved: missing/invalid token → `401`; bad `Host`/any `Origin` → `403`; capability-insufficient → `403` (distinct body). **`isLoopbackHost` rejects non-numeric ports** (`localhost:evil` etc., Blocking Correction 8). Token values never logged (C6).
- [ ] `LabanControlTests` (spy router): observe token → `.observe` op `200`, `.observeSensitive`/`.control` op `403` (no router call); control token → both `200`; **`.clipboard` op `403` for both** (no token grants it); missing → `401`; `.fixture` op rejected for both non-fixture tokens.

Milestone 2B — Live observe/control surface in `LiveIntentRouter` (`LabanApp`):
- [ ] Shared `AppModel`/`Session` → DTO projections relocated to `LabanCore` (e.g. `Sources/LabanCore/Control/Projections/*`), public; `HeadlessIntentRouter` re-points to them with **byte-identical** output (headless `LabanDebugTests` unchanged) (C4).
- [ ] `LiveIntentRouter` implements the observe-read family against the live `AppModel` + `AppSessionCoordinator`, each returning the shared DTO. **`clipboard.read` is NOT implemented** (Blocking Correction 2). Reads split by sensitivity (Blocking Correction 3): `.observe` (non-sensitive) — `terminal.modes`, `scrollIndicator.state`, plus the existing `app.state`; `.observeSensitive` — `session.list`, `session.detail`, `find.state` (needle), `selection.read` (text), `app.accessibility`, and `shellIntegration.state` if it exposes cwd. The observe token gets `403` on the `.observeSensitive` set; the control token gets `200`.
- [ ] Catalog availability flips: these ids become `gui:true` with the correct **explicit** `requiredCapability` and `dataSensitivity` (no implicit default); renderer/atlas/pixel-probe/capture/persistence stay `headlessOnly` for Phase 2 with a one-line scope note (deferred GUI source of truth).
- [ ] `.control` ops on the GUI extended where a live source exists (`terminal.scrollViewport`, `terminal.click`/mouse, `tab.*` lifecycle via `AppCommand`) — **routed through the shared `sessionCoordinator`/input-adapter path, not `session.write`/`session.sendKey` directly** (Blocking Correction 7 / C5); port in reviewable groups; each grows both routers' coverage and keeps `swift test` green.

Milestone 2C — Catalog-parity test:
- [ ] `CatalogParityTests`: over every intent with `availability.gui && availability.headless`, assert (a) both surfaces return a non-error response for a representative input, and (b) the response JSON **shape** (sorted keys) matches between surfaces for the pure reads. **Compare at the HTTP-route level**, not the typed router: `HeadlessIntentRouter.route(.tabSelect/.terminalTypeText/.terminalSendKey)` currently returns `501 "not yet ported"` (legacy HTTP action routing still works), so typed-router parity for those would spuriously fail — add typed-router parity only once those headless typed cases are ported. Fails if either surface drops or diverges on a shared intent.
- [ ] Capability/sensitivity completeness: assert every catalog descriptor declares an **explicit** `requiredCapability` and `dataSensitivity` (drives Blocking Correction 6 / the `validate()` change), and that no `gui:true` op exceeds the capability its live router actually enforces.

Milestone 2D — Indicator, disable switch, audit, no-token-logging:
- [ ] `ControlSecurityObserver` boundary (in `LabanControl`, e.g. `protocol ControlSecurityObserver { didAuthorize(intentID:capability:tokenClass:); didDeny(intentID:reason:); didControlActivity() }`): the server calls it; `LabanControl` keeps its `["LabanCore"]`-only deps and never imports app UI/logging internals. `LabanApp` supplies the observer that owns the indicator state and the persistent `EventLog` sink (Review finding #9).
- [ ] "Agent attached" indicator in the GUI, driven by the observer: lights on the first authenticated `.control` request and stays lit for a TTL window (active for N seconds after the last authenticated `.control` activity, plus any open control stream once 3 adds one) — HTTP has no durable "connected" notion, so the indicator is TTL-based, not socket-based.
- [ ] User-facing disable switch (menu item / setting) that stops the server and removes `control.json`.
- [ ] Every `.control`/`.observeSensitive` access emits an audit event via the observer to the always-on `EventLog` (intent id, capability, surface, time, **no token, no payload secrets**).
- [ ] A test greps captured logs for **both** minted token values (observe + control) and asserts **zero** occurrences (C6).

Milestone 2E — Flip observe-on-by-default (release-checklist gate):
- [ ] The §5.4 release checklist (nine items, reproduced in this milestone) is each backed by a passing test or mechanical check.
- [ ] Default mount flips: the GUI starts the server **observe-on** without `LABAN_CONTROL_SERVER=1`; `.control`/`.observeSensitive` still require the env token; the env var becomes an override/disable, not the on-switch.
- [ ] Credential lifecycle (Blocking Correction 4): mint `ControlCredentials` and bind the server (to learn `LABAN_CONTROL_URL`) **before** `ensureSessions`/restore, and inject `LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL` (control tier) through the shared `ShellIntegrationLaunch.environmentOverrides` hook so **all** backends (in-process `environment:`, laband `environmentPatch`, labpty `envp`) carry it — including the initial/restored session. **No wire change** (does not touch the ADR 0007 freeze).
- [ ] `scripts/check` green; the GUI is unchanged for humans (no new windows, no behavior change for a user who never reads `control.json`).

## Context and Orientation

(Define-every-term, name-every-file, per `PLANS.md`. Current symbols verified
against the Phase-1 end state, 2026-06-20.)

- **Targets.** `LabanCore` (AppKit-free model; `AppModel`), `LabanControl` (*the
  one server* — deps `["LabanCore"]`; `LabanControlServer`, `ControlRouteCatalog`,
  `ControlAdvertisement`), `LabanDebug` (headless runtime + `HeadlessIntentRouter`;
  deps include `LabanControl`), `LabanApp` (GUI; `LiveIntentRouter`,
  `AppSessionCoordinator`, mounts the server).
- **`LabanControlServer`** (`Sources/LabanControl/LabanControlServer.swift`):
  `init(router: IntentRouter, surface: Surface, catalog: IntentCatalog = .all,
  readinessRunID: String? = nil)`. `public func start() throws -> (url, token)`
  (GUI ephemeral) and `start(host:port:) throws -> ControlReadiness` (headless).
  One minted `token`; `static func evaluateGuard(host:origin:authorization:token:)
  -> GuardOutcome { ok | unauthorized | forbidden }`. Per request: match
  `ControlRoute` → `resolveIntentID` → `catalog.descriptor(id:)` →
  `availability.permits(surface)` (`404` else) → `route.dispatch`. **No capability
  check today** — 2A adds it after the availability check.
- **`Capability`** (`Sources/LabanCore/Intents/IntentCatalog.swift`): `enum
  Capability: String, Codable, CaseIterable, Sendable { observe, observeSensitive,
  control, clipboard, fixture }`. **`IntentDescriptor`** already carries
  `requiredCapability: Capability` and `dataSensitivity: DataSensitivity` and
  `availability: Availability { gui, headless; func permits(Surface) }`.
- **`ControlAdvertisement`** (`Sources/LabanControl/ControlAdvertisement.swift`):
  `static func write(url:token:pid:runId:) throws` writes `control.json` under
  `~/Library/Application Support/Laban/` via `open(O_WRONLY|O_CREAT|O_EXCL,
  S_IRUSR|S_IWUSR)` → write → `rename(2)` (**`0600` from first byte — keep**); a
  `remove()` deletes it. 2A makes it carry **only the observe token**.
- **GUI mount** (`Sources/LabanApp/MainWindowController.swift` ~510–526): behind
  `LABAN_CONTROL_SERVER == "1"` it builds `LiveIntentRouter(model:)`,
  `LabanControlServer(router:, surface: .gui)`, `server.start()`,
  `ControlAdvertisement.write(...)`, stores `controller.controlServer`. 2E flips
  the env gate to observe-on-by-default; 2D adds the indicator + disable path.
- **`LiveIntentRouter`** (`Sources/LabanApp/Control/LiveIntentRouter.swift`):
  `IntentRouter` over a `weak AppModel`. Implements `query(.state)` →
  `ControlState`; `route(.tabSelect/.terminalTypeText/.terminalSendKey)` →
  `ControlActionResult`; everything else errors. `onMain { }` hops mutations to the
  main thread. 2B expands it to the observe surface.
- **`HeadlessIntentRouter`** (`Sources/LabanDebug/HeadlessIntentRouter.swift`):
  `IntentRouter` over `HeadlessDebugRuntime` (which holds its own `AppModel`
  `model`). Builds the legacy DTOs (`StateResponse`, `SessionResponse`,
  `SelectionResponse`, …) via the `Debug*Endpoints` projections. 2B relocates the
  shared projections to `LabanCore` and re-points this router at them.
- **`AppSessionCoordinator`** (`Sources/LabanApp/AppSessionCoordinator.swift`):
  the GUI's live session lifecycle owner — the live source of truth for
  `session.*` reads (the headless runtime uses its mirror).
- **Legacy read DTOs (byte-stable targets):** `StateResponse`, `SessionsResponse`/
  `SessionResponse`, `SelectionResponse`, `FindStateResponse`,
  `TerminalModesResponse`, accessibility, shell-integration, scroll-indicator —
  defined today in `Sources/LabanDebug/DebugModels.swift`. 2B relocates the ones
  the GUI must also produce to `LabanCore` (C4).
- **`EventLog`** — the always-on in-memory event ring the runtime appends to
  (`appendEvent`). The audit sink for 2D and the substrate Phase 3 promotes to a
  push stream.
- **`schemas/debug/discovery-endpoints.json`** + **`LabanControlGen`** (Phase 1D):
  the generated, gated discovery doc. New 2B/2E intents that change route metadata
  must `swift run LabanControlGen --write` and stay byte-stable in the gate.
- **labpty `envp`** — the spawn wire already carries child environment
  (`Sources/LabanCore/LabptyProtocol.swift`, ADR 0007 freeze); 2E rides it for the
  control token with **no wire change**.

---

## Cross-cutting design contracts (read first)

**C1 — Two credentials, never one.** `control.json` advertises an **observe-only**
token. The `.control`/`.observeSensitive` authority rides a **separate** token
injected into the env (`LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL`) of children
Laban spawns. A same-user process can read the file (observe-only, non-sensitive)
but cannot read another process's env on macOS. **Never** place a control/sensitive
token in any world-path file. (ADR 0024 §"Two-tier token model".)

**C2 — Capability enforced per resolved intent, after availability.** Per request:
guard (Host/Origin/token) → match route → resolve intent id → availability check
(`404` if surface-unavailable) → **capability check**: `descriptor.requiredCapability
∈ grantedCapabilities(presentedToken)` → `403 {"error":"insufficient capability"}`
otherwise → dispatch. The check is on the **resolved id**, so a known intent the
caller can't afford is `403`, not `404`.

**C3 — Policy generated from the catalog; deny by default.** `LabanControlPolicy`
derives the token→capability grants and the per-intent requirement **from
`IntentCatalog`**. An unknown id is **denied**. Adding an intent without classifying
it must fail closed. **This is not the case today** (Blocking Correction 6): the
catalog builder auto-fills `requiredCapability` via `defaultCapability(for:)` and
defaults `dataSensitivity` to `.nonSensitiveState`, and `validate()` does not check
explicit classification — so an unclassified sensitive query silently defaults to
`.observe`. Part of 2A/2C is to remove those implicit defaults (or track an
`explicit` flag) and make `validate()`/`LabanControlGen` **fail** unless every
descriptor declares both fields explicitly.

**C4 — One projection, both surfaces.** The `AppModel`/`Session` → read-DTO
projections the GUI and headless both need move to `LabanCore` (transport-neutral,
AppKit-free) so `LiveIntentRouter` and `HeadlessIntentRouter` emit **byte-identical**
wire by construction. `dataSensitivity` (what may leak) is declared **independently**
of `requiredCapability` (who may call): a `.observe` read may still be
`dataSensitivity: .nonSensitiveState`, while scrollback/grid/keystroke reads are
`.observeSensitive` + the matching sensitivity. Renderer-only reads (real Metal
state, atlas, pixel-probe) have no live GUI projection in Phase 2 and stay
`headlessOnly` with a noted boundary.

**C5 — Programmatic input shares the human validation path; no in-band control.**
`terminal.typeText`/`sendKey`/`paste` route through the **same** sanitizer/VT path
a human keystroke takes (treat all agent/model/tool/repo bytes as untrusted before
the parser). **Today this is violated** (Blocking Correction 7): `LiveIntentRouter`
calls `session.write`/`session.sendKey` directly, while human input flows through
`TerminalBitmapView` → `sessionCoordinator.write(...)` with `sanitizePaste` and
`encodeKey`/`encodePaste`. 2B must re-point programmatic input at that shared
coordinator/input-adapter path. Never write title/clipboard read-backs into the
input stream; constrain DECRQSS/DSR (the CVE-2022-45872 class). OSC 52 **write
only**, behind an explicit opt-in; clipboard **read is never implemented**. (ADR
0024 §"Standing constraints".)

**C6 — `0600`-from-first-byte; never log a token.** `control.json` stays created
`O_CREAT|O_EXCL,0600` → write → `rename` (no chmod-after-write). Logs record the
**URL only**, never a token value; a test greps logs for the minted token and
expects zero hits.

**C7 — High-power reads are privileged; every privileged access is audited.** Full
keystroke stream and full scrollback/grid dumps require `.observeSensitive`, never
bare `.observe`. Every `.control`/`.observeSensitive` access appends an audit event
to the `EventLog`. A `.control`-tier connection lights the user-visible indicator.

**C8 — Default-on is gated by the release checklist, not the phase label.** The
observe-on-by-default flip (2E) lands only when all nine §5.4 items hold, each
backed by a test/mechanical check. Through 2A–2D the server remains behind
`LABAN_CONTROL_SERVER=1`.

**C9 — The human GUI is unchanged; the headless wire is byte-stable.** No new
windows or behavior for a user who never reads `control.json`. `laban-agent` +
`LabanDebugTests` + the `/debug` discovery doc + `schemas/debug/*` stay identical;
the only headless-visible change is the `403` capability tier (which headless
exercises with the control/fixture token, so its existing flows are unaffected).

---

## Milestone 2A — Capability enforcement + two-tier tokens

**Scope.** Make the server mint two tokens, advertise only the observe token, and
enforce `requiredCapability` per request via a catalog-generated
`LabanControlPolicy`. Surface-agnostic; no live-AppModel work yet. The GUI surface
still answers only what `LiveIntentRouter` implements (so most reads remain `404`
by availability until 2B), but the **capability** machinery is in place and tested
with a spy router.

### Plan of Work (2A)

- `public struct ControlCredentials: Sendable { public let observe: String; public
  let control: String }` (LabanControl). The GUI `start()` mints both (32-byte hex,
  as today) and returns `ControlCredentials` to the **in-process** caller;
  `control.json` is written with **`observe` only**; `control` is handed to the
  env-injection path (2E). **`ControlReadiness` is unchanged** — still
  `{debugServer, debugToken, pid, runId}`; the control token is **never** serialized
  into readiness JSON or any world-path file (Blocking Correction 5). Headless
  `start(host:port:)` keeps `debugToken` with its current authority so `laban-agent`
  and `LabanDebugTests` are byte-stable (C9).
- `public struct LabanControlPolicy: Sendable` (LabanControl), built from a
  `IntentCatalog`:
  - `grants(observe) = {.observe}`; `grants(control) = {.observe, .observeSensitive,
    .control}` (**no `.clipboard`**); `grants(fixture) = {.fixture, .observe,
    .observeSensitive, .control}` (headless/tests only; `.fixture`-on-GUI already
    rejected by `validate()`). **No token grants `.clipboard`** — it requires a
    future explicit opt-in (Blocking Correction 1/2). Pure data, no I/O.
  - `func capabilities(forBearer token: String, credentials: ControlCredentials,
    fixtureToken: String?) -> Set<Capability>` (constant-time compares).
  - `func authorize(intentID: String, granted: Set<Capability>) -> Bool` using
    `catalog.descriptor(id:)?.requiredCapability`; unknown id → `false`.
- **Make deny-by-default real** (Blocking Correction 6): drop the implicit
  `defaultCapability(for:)` / `dataSensitivity` defaults in the catalog builder (or
  add an `explicit` marker), and extend `IntentCatalog.validate()` (and the
  `LabanControlGen` gate) to **fail** unless every descriptor declares both
  `requiredCapability` and `dataSensitivity` explicitly.
- **Fix `isLoopbackHost` port parsing** (Blocking Correction 8): after splitting the
  host label, require the remainder to be empty or `:<numeric port>`; reject
  non-numeric ports. `localhost:evil`, `127.0.0.1:evil`, `[::1]:evil` → `forbidden`.
- Server request path (after the `availability.permits` check): compute `granted`
  from the presented bearer token; `guard policy.authorize(intentID:, granted:)
  else return .error(403, "insufficient capability")`.
- Keep `evaluateGuard` for Host/Origin/"is this a valid token at all" (401/403),
  then layer capability (403) on top.

### Acceptance (2A)

`LabanControlTests` (spy router, both surfaces): with the **observe** token a
`.observe` intent returns `200` and a `.control`/`.observeSensitive` intent returns
`403 {"error":"insufficient capability"}` **without invoking the router**; with the
**control** token both return `200`; no token → `401`; forged `Host`/any `Origin`
→ `403`; `localhost:evil`/`127.0.0.1:evil`/`[::1]:evil` (non-numeric port) → `403`.
A `.clipboard` op is rejected for **both** the observe and control tokens (no token
grants `.clipboard`). `control.json` contains the observe token and **not** the
control token (parse the file in the test). Unknown action id: with the **control**
token it reaches the legacy unsupported response; with the **observe** token a
capability `403` is acceptable (the resolved unsupported descriptor is not
`.observe`), so the test asserts per token rather than assuming a single shape.

---

## Milestone 2B — Live observe/control surface in `LiveIntentRouter`

**Scope.** Relocate the shared `AppModel → DTO` projections to `LabanCore` (C4);
re-point `HeadlessIntentRouter` at them byte-identically; implement the observe-read
family in `LiveIntentRouter` against the live `AppModel` + `AppSessionCoordinator`;
flip those intents' catalog availability to `gui:true` with the right
`requiredCapability`. Port `.control` ops where a live source exists, in reviewable
groups.

### Plan of Work (2B)

1. **Relocate projections** (one group per PR): move the pure `AppModel`/`Session`
   read builders from `Sources/LabanDebug/Debug*Endpoints.swift` to
   `Sources/LabanCore/Control/Projections/` as free functions/extensions over
   `AppModel`/`Session`, returning DTOs now also in `LabanCore`. `LabanDebug`
   typealiases the relocated DTOs so headless code compiles unchanged; the headless
   responses stay byte-stable (`LabanDebugTests` + `DiscoveryEndpointParityTests`
   unchanged).
2. **Implement the live reads** in `LiveIntentRouter` (on-main snapshot →
   projection → `ControlResponse.json`): `app.accessibility`, `terminal.modes`,
   `session.list`, `session.detail`, `find.state`, `selection.read`,
   `shellIntegration.state`, `scrollIndicator.state`. **No `clipboard.read`**
   (Blocking Correction 2).
3. **Flip availability** for those ids to `gui:true` and set **explicit**
   `requiredCapability` and `dataSensitivity` per Blocking Correction 3: `.observe`
   only for the non-sensitive reads (`terminal.modes`, `scrollIndicator.state`,
   `app.state`); `.observeSensitive` for everything exposing text/cwd/command/needle
   /selection/grid/a11y content. Keep renderer/atlas/pixel-probe/capture/persistence
   `headlessOnly` (noted boundary; no live source this phase).
4. **`.control` groups:** wire `terminal.scrollViewport`, mouse
   (`terminal.click`/`mouseWheel`/`mouseDrag`), and `tab.*` lifecycle through the
   GUI's existing `AppCommand`/view paths (C5 — same validation as human input). In
   the same pass, **retrofit the existing `terminal.typeText`/`sendKey`** off the
   direct `session.write`/`session.sendKey` calls onto the shared
   `sessionCoordinator.write(...)` + `encodeKey`/`encodePaste`/`sanitizePaste` path
   `TerminalBitmapView` uses, so programmatic and human input are identical across
   in-process/laband/labpty backends (Blocking Correction 7).
5. Each group: `swift run LabanControlGen --write` if route metadata changed;
   `swift test`; `scripts/check`.

### Acceptance (2B)

With the app running behind `LABAN_CONTROL_SERVER=1`: with the **observe** token
from `control.json`, the non-sensitive reads (`/debug/state`, `terminal.modes`,
`scrollIndicator.state`) return the **real window's** live state, shape-identical to
the headless wire for the same model, while the `.observeSensitive` reads
(`/debug/sessions`, `/debug/selection`, `/debug/find/state`, accessibility,
scrollback/grid) return `403`. With the **control** token (env-injected) those same
`.observeSensitive` reads return `200` and are shape-identical to the headless wire.
`clipboard.read` exists on no surface. `LabanDebugTests` pass unchanged (headless
wire byte-stable, driven by the fixture/control token). The `CatalogParityTests`
from 2C cover the new shared ids.

---

## Milestone 2C — Catalog-parity test

**Scope.** A test that fails if the GUI and headless routers diverge on any shared
intent, plus capability/sensitivity completeness.

### Acceptance (2C)

`CatalogParityTests`: for every descriptor with `availability.gui &&
availability.headless`, both surfaces — driven at the **HTTP-route level** (the live
GUI server over a real `AppModel`, the headless server over a runtime) — return a
non-error response for a representative input, and for pure reads the sorted-key JSON
**shape** matches between surfaces. (Typed-router parity for `tabSelect`/`typeText`/
`sendKey` is deferred until the headless typed cases are ported off their `501`
stubs.) A second test asserts every catalog descriptor declares an **explicit**
`requiredCapability` and `dataSensitivity` (no implicit default survives), and that
the set of `gui:true` ids is exactly what `LiveIntentRouter` implements (the Phase-1
conservative invariant, now expanded).

---

## Milestone 2D — Indicator, disable switch, audit, no-token-logging

**Scope.** The user-facing safety surface ADR 0024 requires before default-on.

### Acceptance (2D)

A `.control`-tier authenticated request lights a visible "agent attached" indicator
in the running app (driven by `ControlSecurityObserver`; clears after the TTL window
with no further `.control` activity); a menu/setting **disable switch** stops the
server and removes `control.json` (verified: subsequent `curl` fails to connect and
the file is gone). Every `.control`/`.observeSensitive` request appends an audit
event via the observer to the app-side `EventLog` (assert via `GET /debug/events` or
the journal) carrying intent id + capability + surface + time and **no token/secret**;
`LabanControl` itself does not import the `EventLog`. A test greps all captured
logs/artifacts for **both** minted token strings (observe + control) and asserts
**zero** occurrences.

---

## Milestone 2E — Flip observe-on-by-default (release-checklist gate)

**Scope.** Turn the default on, gated on the §5.4 release checklist, with control
token child-env injection. The GUI is unchanged for humans.

**§5.4 release checklist — every item must hold (each backed by a test/check):**

- [ ] `control.json` grants an **observe-only** token (never `.control`/`.observeSensitive`).
- [ ] `.observeSensitive` requires the separate env-injected token/scope.
- [ ] `.control` requires the separate env-injected token/scope.
- [ ] The token file is created `0600` **from the first byte** (not chmod-after-write).
- [ ] `Host` + `Origin` validation rejects malformed/spoofed hosts (tests cover `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`, and the non-numeric-port cases `localhost:evil`, `127.0.0.1:evil`, `[::1]:evil` that `isLoopbackHost` accepts today — Blocking Correction 8).
- [ ] A visible "agent attached" indicator exists.
- [ ] A user-facing disable switch exists.
- [ ] Audit events persist to the `EventLog`.
- [ ] No token value is ever logged.

### Plan of Work (2E)

- Replace the `LABAN_CONTROL_SERVER == "1"` on-switch with **observe-on-by-default**
  mount (the env var becomes a force-disable / control-tier override). Keep the same
  bind/guard/limits.
- **Reorder the mount** (Blocking Correction 4): mint `ControlCredentials` and bind
  the server above `ensureSessions`/restore in `MainWindowController` (the model
  exists by ~L107; sessions are ensured ~L253 today, after the current ~L510 mount).
- Inject `LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL` (control credential) into
  `ShellIntegrationLaunch.environmentOverrides` (the shared source feeding in-process,
  laband `environmentPatch`, and labpty `envp`) so every spawned session — including
  the first/restored one — receives it. No wire change; does not touch ADR 0007.
- Gate the flip behind the nine checks above (each already landed in 2A–2D).

### Acceptance (2E)

A freshly launched app (no `LABAN_CONTROL_SERVER`) writes `control.json` and answers
**observe** reads for an agent that reads the file; a child Laban spawned (e.g. a
shell) sees `LABAN_CONTROL_TOKEN`/`LABAN_CONTROL_URL` in its env and can perform
`.control`/`.observeSensitive` ops; an unrelated same-user process with only the
file token is limited to `.observe` (others `403`). The disable switch turns it all
off. `scripts/check` green; no human-visible GUI change.

## Validation and Acceptance

From the repo root:

    swift test --filter LabanControlTests          # 2A — capability tiers + two-token guard (spy)
    swift test --filter LiveControlObserve         # 2B — live AppModel reads on .gui (in LabanAppTests)
    swift test --filter LabanDebug                 # 2B — headless wire byte-stable after projection relocation
    swift test --filter CatalogParityTests         # 2C — no router drops/diverges on a shared intent
    swift test --filter ControlSecurityFloor       # 2D — indicator/disable/audit/no-token-logging
    swift test --filter ControlDefaultOn           # 2E — observe-on-by-default + env-token control tier
    ./scripts/check                                 # discovery byte-stable + gated; lint; e2e; coverage
    ./scripts/build-app                             # GUI builds; unchanged for humans

…all pass, and: an agent reading `control.json` observes the **live** app's
**non-sensitive** state with the observe token; `.observeSensitive`/`.control`
(including all text/cwd/command/needle/selection/grid reads) succeed only with the
env-injected token (else `403`); `clipboard.read` exists on no surface; missing
token `401`, bad `Host`/any `Origin` (incl. non-numeric ports) `403`; the
catalog-parity test fails if either surface omits a shared intent; the §5.4 checklist
holds before the default flips; the headless wire + `/debug` discovery + `schemas/`
are byte-stable; no token value appears in any log.

## Decision Log

- Five milestones (2A enforcement+tokens → 2B live surface → 2C parity → 2D
  safety UI/audit → 2E default-on). Security floor (2A) precedes the live surface
  (2B) so no privileged read is reachable before capability is enforced. DRAFT —
  2026-06-20 / Claude.
- (C1/ADR 0024) Two tokens, not one: observe token in `control.json`, control/
  sensitive token via child env. The file token is deliberately low-stakes because
  `0600` does not stop a same-user reader. DRAFT — 2026-06-20 / Claude.
- (C4) Relocate the shared `AppModel → DTO` projections to `LabanCore` rather than
  letting `LiveIntentRouter` import `LabanDebug` DTOs — keeps the byte-identical
  wire a structural property and avoids `LabanApp → LabanDebug` DTO coupling for
  reads. DRAFT — 2026-06-20 / Claude.
- (C8/§5.4) The default-on flip is gated by the nine-item release checklist, not
  the phase label; through 2A–2D the server stays behind `LABAN_CONTROL_SERVER=1`.
  DRAFT — 2026-06-20 / Claude.
- (Security review, verified against source 2026-06-20) Eight blocking corrections
  folded in (see "Blocking Corrections"): `.clipboard` excluded from the control
  grant and from live `clipboard.read`; rich DTOs (`session.*`, `selection`, `find`,
  a11y) reclassified `.observeSensitive` so the file (observe) token cannot read
  them; credentials minted before `ensureSessions` and injected via the shared
  `ShellIntegrationLaunch.environmentOverrides` (all backends, not labpty alone);
  `ControlReadiness` kept byte-stable (control token never serialized); the catalog's
  implicit capability/sensitivity defaults removed so `validate()` truly denies the
  unclassified; programmatic input re-pointed at the human `sessionCoordinator` path;
  and the `isLoopbackHost` non-numeric-port accept-bug fixed. DRAFT — 2026-06-20.
- Fixture (test-only) token grants `{.fixture, .observe, .observeSensitive, .control}`
  — broader than the review's suggested `{.fixture, .observe}` — because the headless
  wire (C9) drives `.control`/`.observeSensitive` ops with it and `validate()` already
  forbids `.fixture` on the GUI surface, so the breadth is test-scoped. `.clipboard`
  is still excluded. DRAFT — 2026-06-20 / Claude.

## Review Gate

A fresh-state agent verifies (mechanical; from repo root) once the plan is
executed:

- [ ] `control.json` contains the observe token and **not** the control token (parse the file written by the GUI mount / `ControlAdvertisement`); `grep` **both** minted tokens across logs/artifacts → zero hits (the observe token appears only inside `control.json` itself, never in a log).
- [ ] `ControlReadiness` is still `{debugServer, debugToken, pid, runId}` (no new field); the control token is never serialized into readiness JSON (grep the encode path; `laban-agent` readiness line byte-stable).
- [ ] Spy-router test proves: observe token + `.control` intent → `403` with no router call; control token + `.control` intent → `200`; `.clipboard` intent → `403` for both tokens; missing token → `401`.
- [ ] Sensitivity split: with the observe token, `session.list`/`selection.read`/`find.state` (and accessibility) → `403`, while `app.state`/`terminal.modes`/`scrollIndicator.state` → `200`; with the control token the `.observeSensitive` set → `200` and is shape-identical to `HeadlessIntentRouter` for the same model. `clipboard.read` is implemented on no surface.
- [ ] Deny-by-default: add a descriptor with no explicit `requiredCapability`/`dataSensitivity`; `IntentCatalog.validate()` / `LabanControlGen --check` **fails** (expect failure; revert).
- [ ] `LiveIntentRouter` programmatic `typeText`/`sendKey` route through `sessionCoordinator.write(...)` (+ paste sanitizer / `encodeKey`), not direct `session.write`/`session.sendKey` (grep the impl).
- [ ] `grep -rn "import LabanDebug" Sources/LabanApp/Control` → nothing for the read path (projections come from `LabanCore`); `LabanControl` deps still exactly `["LabanCore"]` and it imports no app-side `EventLog`.
- [ ] `swift test --filter CatalogParityTests` fails if a `gui:true && headless:true` intent is removed from one surface (mutate one router; expect failure; revert).
- [ ] `0600`-from-first-byte: `ControlAdvertisement` uses `O_CREAT|O_EXCL` with `S_IRUSR|S_IWUSR` and no `chmod` after write (grep the impl).
- [ ] Host/Origin matrix tests include `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`, `localhost:evil`, `127.0.0.1:evil`, `[::1]:evil` → all `403` (the port cases require the `isLoopbackHost` fix).
- [ ] Credential timing: with no `LABAN_CONTROL_SERVER` set, a launched app writes `control.json` and the **initial/restored** session's env carries `LABAN_CONTROL_TOKEN`/`LABAN_CONTROL_URL` (minted before `ensureSessions`); a `.control` op with the file (observe) token → `403`; with the env token → `200`.
- [ ] `./scripts/check` exits 0; `./scripts/build-app` succeeds; `swift run LabanControlGen --check` passes (discovery byte-stable).

Review status: NOT REVIEWED (plan not yet executed).

## Idempotence and Recovery

- 2A is mostly additive (new policy + second token); reverting restores the
  single-token behavior. Two 2A sub-steps are *tightening* rather than additive and
  are effectively irreversible-by-intent: the `isLoopbackHost` port fix (rejects
  hosts wrongly accepted today) and removing the catalog's implicit
  capability/sensitivity defaults. The latter is a hard sequencing prerequisite —
  making `validate()` strict will fail the build until **every existing descriptor**
  is classified explicitly, so do that classification pass first, in the same change
  that flips `validate()` to strict. 2B relocates projections behind typealiases so
  a partial revert never breaks the headless wire; each read group is independently
  revertible. 2C/2D are test/UI additions. **2E is the only behavior-flipping
  milestone** — keep it last, keep the env-var force-disable, and do not flip until
  the nine §5.4 checks are green so the default-on state is always recoverable to
  off.

## Interfaces and Dependencies

End-state additions (**bold**) on the Phase-1 graph:

    LabanCore        + Sources/LabanCore/Control/Projections/* (AppModel→DTO read builders, shared) + relocated read DTOs
    LabanControl     + ControlCredentials, LabanControlPolicy (capability enforcement); control.json carries observe token only
    LabanDebug       HeadlessIntentRouter re-points at LabanCore projections (byte-stable); typealiases relocated DTOs
    LabanApp         LiveIntentRouter expanded to the live observe/control surface; "agent attached" indicator + disable switch; observe-on-by-default mount; child-env control-token injection

No third-party packages; `LabanControl` stays `Foundation`/`Darwin`/`LabanCore`.
The `labpty` wire is unchanged (ADR 0007 freeze): the control token rides the
existing child `envp`.
