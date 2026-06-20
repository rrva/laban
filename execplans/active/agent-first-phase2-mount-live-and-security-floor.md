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

> **Status: DRAFT (not started).** This plan is authored from the program design
> and the current Phase-1 end state. Refine each milestone's Concrete Steps as you
> execute and discover; keep this document self-contained per `PLANS.md`.

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
- [ ] `ControlCredentials { observe, control }` minted in `LabanControlServer.start*`; `control.json` carries **only** the observe token; the control token is returned for child-env injection (C1).
- [ ] `LabanControlPolicy` (generated from `IntentCatalog`) resolves a presented bearer token → granted `Set<Capability>`; per request, after availability, enforce `descriptor.requiredCapability ∈ granted` → else `403 {"error":"insufficient capability"}` (C2/C3). Unclassified/unknown intent → deny.
- [ ] Guard taxonomy preserved: missing/invalid token → `401`; bad `Host`/any `Origin` → `403`; capability-insufficient → `403` (distinct body). Token values never logged (C6).
- [ ] `LabanControlTests` (spy router): observe token → `.observe` op `200`, `.observeSensitive`/`.control` op `403` (no router call); control token → both `200`; missing → `401`; `.fixture` op rejected for both non-fixture tokens.

Milestone 2B — Live observe/control surface in `LiveIntentRouter` (`LabanApp`):
- [ ] Shared `AppModel`/`Session` → DTO projections relocated to `LabanCore` (e.g. `Sources/LabanCore/Control/Projections/*`), public; `HeadlessIntentRouter` re-points to them with **byte-identical** output (headless `LabanDebugTests` unchanged) (C4).
- [ ] `LiveIntentRouter` implements the observe-read family against the live `AppModel` + `AppSessionCoordinator`: `app.accessibility`, `terminal.modes`, `session.list`, `session.detail`, `find.state`, `selection.read`, `shellIntegration.state`, `scrollIndicator.state`, `clipboard.read` (read-back), plus the existing `app.state`. Each returns the shared DTO.
- [ ] Catalog availability flips: these ids become `gui:true` with the correct `requiredCapability` (`.observe` vs `.observeSensitive`); renderer/atlas/pixel-probe/capture/persistence stay `headlessOnly` for Phase 2 with a one-line scope note (deferred GUI source of truth).
- [ ] `.control` ops on the GUI extended where a live source exists (`terminal.scrollViewport`, `terminal.click`/mouse, `tab.*` lifecycle via `AppCommand`) — port in reviewable groups; each grows both routers' coverage and keeps `swift test` green.

Milestone 2C — Catalog-parity test:
- [ ] `CatalogParityTests`: over every intent with `availability.gui && availability.headless`, assert (a) both routers return a non-error `ControlResponse` for a representative input, and (b) the response JSON **shape** (sorted keys) matches between surfaces for the pure-observe reads. Fails if either router drops or diverges on a shared intent.
- [ ] Capability/sensitivity completeness: assert every catalog descriptor carries a `requiredCapability` and a `dataSensitivity`, and that no `gui:true` op exceeds the capability its live router actually enforces.

Milestone 2D — Indicator, disable switch, audit, no-token-logging:
- [ ] "Agent attached" indicator in the GUI whenever a `.control`-tier client is connected (lights on first authenticated `.control` request, clears on idle/disconnect).
- [ ] User-facing disable switch (menu item / setting) that stops the server and removes `control.json`.
- [ ] Every `.control`/`.observeSensitive` access emits an audit event to the always-on `EventLog` (intent id, capability, surface, time, **no token, no payload secrets**).
- [ ] A test greps captured logs for the live token value and asserts **zero** occurrences (C6).

Milestone 2E — Flip observe-on-by-default (release-checklist gate):
- [ ] The §5.4 release checklist (nine items, reproduced in this milestone) is each backed by a passing test or mechanical check.
- [ ] Default mount flips: the GUI starts the server **observe-on** without `LABAN_CONTROL_SERVER=1`; `.control`/`.observeSensitive` still require the env token; the env var becomes an override/disable, not the on-switch.
- [ ] Child-env injection: sessions Laban spawns receive `LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL` (control tier) via the existing `labpty` `envp` path — **no wire change** (does not touch the ADR 0007 freeze).
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
`IntentCatalog`**. An intent with no `requiredCapability`, or an unknown id, is
**denied**. Adding an intent without classifying it fails closed (and the
`LabanControlGen`/`IntentCatalog.validate()` gate already requires the field).

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
the parser). Never write title/clipboard read-backs into the input stream;
constrain DECRQSS/DSR (the CVE-2022-45872 class). OSC 52 **write only**, behind an
explicit opt-in; clipboard **read is never implemented**. (ADR 0024 §"Standing
constraints".)

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
  let control: String }` (LabanControl). `start()`/`start(host:port:)` mint both
  (32-byte hex, as today) and return them; `control.json` write takes
  `observe` only; `ControlReadiness`/`(url, token)` continue to surface the
  observe token for back-compat, plus the control token via a new field/return.
- `public struct LabanControlPolicy: Sendable` (LabanControl), built from a
  `IntentCatalog`:
  - `grants(observe) = {.observe}`; `grants(control) = {.observe,
    .observeSensitive, .control, .clipboard}`; `grants(fixture) = {.fixture,
    .observe}` (headless/tests). Pure data, no I/O.
  - `func capabilities(forBearer token: String, credentials: ControlCredentials,
    fixtureToken: String?) -> Set<Capability>` (constant-time compares).
  - `func authorize(intentID: String, granted: Set<Capability>) -> Bool` using
    `catalog.descriptor(id:)?.requiredCapability`; unknown id → `false`.
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
→ `403`. `control.json` contains the observe token and **not** the control token
(parse the file in the test). Unknown action id → still the legacy unsupported
path, not a capability `403` (the resolver runs first).

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
   `shellIntegration.state`, `scrollIndicator.state`, `clipboard.read`.
3. **Flip availability** for those ids to `gui:true` and set/confirm
   `requiredCapability` (`.observe` vs `.observeSensitive` per ADR 0024 §5.1) and
   `dataSensitivity`. Keep renderer/atlas/pixel-probe/capture/persistence
   `headlessOnly` (noted boundary; no live source this phase).
4. **`.control` groups:** wire `terminal.scrollViewport`, mouse
   (`terminal.click`/`mouseWheel`/`mouseDrag`), and `tab.*` lifecycle through the
   GUI's existing `AppCommand`/view paths (C5 — same validation as human input).
5. Each group: `swift run LabanControlGen --write` if route metadata changed;
   `swift test`; `scripts/check`.

### Acceptance (2B)

With the app running behind `LABAN_CONTROL_SERVER=1` and the **observe** token from
`control.json`: `curl` of `GET /debug/sessions`, `/debug/state`,
`/debug/selection`, `/debug/find/state` returns the **real window's** live state,
shape-identical to the headless wire for the same model. `.observeSensitive` reads
(e.g. full scrollback/grid) return `403` with the observe token and `200` with the
control token. `LabanDebugTests` pass unchanged (headless wire byte-stable). The
`CatalogParityTests` from 2C cover the new shared ids.

---

## Milestone 2C — Catalog-parity test

**Scope.** A test that fails if the GUI and headless routers diverge on any shared
intent, plus capability/sensitivity completeness.

### Acceptance (2C)

`CatalogParityTests`: for every descriptor with `availability.gui &&
availability.headless`, both a live `LiveIntentRouter` (over a real `AppModel`) and
a `HeadlessIntentRouter` (over a runtime) return a non-error `ControlResponse` for a
representative input, and for pure-observe reads the sorted-key JSON **shape**
matches between surfaces. A second test asserts every catalog descriptor has a
`requiredCapability` and `dataSensitivity`, and that the set of `gui:true` ids is
exactly what `LiveIntentRouter` implements (the Phase-1 conservative invariant,
now expanded).

---

## Milestone 2D — Indicator, disable switch, audit, no-token-logging

**Scope.** The user-facing safety surface ADR 0024 requires before default-on.

### Acceptance (2D)

A `.control`-tier authenticated request lights a visible "agent attached" indicator
in the running app (and clears when the client goes idle/disconnects); a menu/setting
**disable switch** stops the server and removes `control.json` (verified: subsequent
`curl` fails to connect and the file is gone). Every `.control`/`.observeSensitive`
request appends an audit event to the `EventLog` (assert via `GET /debug/events` or
the journal) carrying intent id + capability + surface + time and **no token/secret**.
A test greps all captured logs/artifacts for the minted token string and asserts
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
- [ ] `Host` + `Origin` validation rejects malformed/spoofed hosts (tests cover `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com`).
- [ ] A visible "agent attached" indicator exists.
- [ ] A user-facing disable switch exists.
- [ ] Audit events persist to the `EventLog`.
- [ ] No token value is ever logged.

### Plan of Work (2E)

- Replace the `LABAN_CONTROL_SERVER == "1"` on-switch with **observe-on-by-default**
  mount (the env var becomes a force-disable / control-tier override). Keep the same
  bind/guard/limits.
- Inject `LABAN_CONTROL_TOKEN` + `LABAN_CONTROL_URL` (control credential) into the
  env of sessions Laban spawns, via the existing `labpty` `envp` path (no wire
  change; does not touch ADR 0007).
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

…all pass, and: an agent reading `control.json` observes the **live** app with the
observe token; `.observeSensitive`/`.control` succeed only with the env-injected
token (else `403`); missing token `401`, bad `Host`/any `Origin` `403`; the
catalog-parity test fails if either router omits a shared intent; the §5.4 checklist
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

## Review Gate

A fresh-state agent verifies (mechanical; from repo root) once the plan is
executed:

- [ ] `control.json` contains the observe token and **not** the control token (parse the file written by the GUI mount / `ControlAdvertisement`); `grep` the minted control token across logs/artifacts → zero hits.
- [ ] Spy-router test proves: observe token + `.control` intent → `403` with no router call; control token + `.control` intent → `200`; missing token → `401`.
- [ ] `LiveIntentRouter` answers `session.list`/`selection.read`/`find.state` against a live `AppModel` (test in `LabanAppTests`), shape-identical to `HeadlessIntentRouter` for the same model.
- [ ] `grep -rn "import LabanDebug" Sources/LabanApp/Control` → nothing for the read path (projections come from `LabanCore`); `LabanControl` deps still exactly `["LabanCore"]`.
- [ ] `swift test --filter CatalogParityTests` fails if a `gui:true && headless:true` intent is removed from one router (mutate one router; expect failure; revert).
- [ ] `0600`-from-first-byte: `ControlAdvertisement` uses `O_CREAT|O_EXCL` with `S_IRUSR|S_IWUSR` and no `chmod` after write (grep the impl).
- [ ] Host/Origin matrix tests include `[::1]evil`, `127.0.0.1.evil.com`, `localhost.evil.com` → all `403`.
- [ ] With no `LABAN_CONTROL_SERVER` set, a launched app writes `control.json` and answers an observe read (default-on); a `.control` op with the file token → `403`.
- [ ] `./scripts/check` exits 0; `./scripts/build-app` succeeds; `swift run LabanControlGen --check` passes (discovery byte-stable).

Review status: NOT REVIEWED (plan not yet executed).

## Idempotence and Recovery

- 2A is additive (new policy + second token); reverting restores the single-token
  behavior. 2B relocates projections behind typealiases so a partial revert never
  breaks the headless wire; each read group is independently revertible. 2C/2D are
  test/UI additions. **2E is the only behavior-flipping milestone** — keep it last,
  keep the env-var force-disable, and do not flip until the nine §5.4 checks are
  green so the default-on state is always recoverable to off.

## Interfaces and Dependencies

End-state additions (**bold**) on the Phase-1 graph:

    LabanCore        + Sources/LabanCore/Control/Projections/* (AppModel→DTO read builders, shared) + relocated read DTOs
    LabanControl     + ControlCredentials, LabanControlPolicy (capability enforcement); control.json carries observe token only
    LabanDebug       HeadlessIntentRouter re-points at LabanCore projections (byte-stable); typealiases relocated DTOs
    LabanApp         LiveIntentRouter expanded to the live observe/control surface; "agent attached" indicator + disable switch; observe-on-by-default mount; child-env control-token injection

No third-party packages; `LabanControl` stays `Foundation`/`Darwin`/`LabanCore`.
The `labpty` wire is unchanged (ADR 0007 freeze): the control token rides the
existing child `envp`.
