# Headless Debug Runtime Refactors

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress`, `Decision Log`, and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

`HeadlessDebugRuntime` is the automation surface agents use to start Laban,
drive terminal input, inspect state, and collect artifacts without a visible
window. It currently mixes endpoint bodies, JSON request models, logging,
fixture-path security checks, rendering diagnostics, capture control, and
input routing in one large file. After this refactor, the runtime remains the
single debug adapter but its supporting policies live in named modules with
focused tests, making future endpoint and action changes less risky.

## Progress

- [x] Read the MVP and debug-process docs that define the headless debug
  boundary.
- [x] Inspect `Sources/LabanDebug/HeadlessDebugRuntime.swift`,
  `DebugHTTPServer.swift`, `DebugModels.swift`, and focused debug tests.
- [x] Create this ExecPlan for the multi-step runtime breakup.
- [x] Extract debug runtime request/response DTOs from
  `HeadlessDebugRuntime.swift`.
- [x] Extract fixture-path resolution and symlink rejection into a dedicated
  helper with focused tests.
- [x] Run targeted `LabanDebugTests`.
- [x] Commit the first behavior-preserving milestone.
- [x] Extract action dispatch and key-input decoding out of
  `HeadlessDebugRuntime.swift`.
- [x] Split the extracted action dispatch into typed domain command objects.
- [x] Replace the optional-bag `ActionRequest` with tagged, typed action
  payloads while preserving the JSON wire shape.
- [x] Add focused typed-action decoding tests for discriminator routing,
  payload-free actions, unknown actions, and invalid requests.
- [x] Extract event/input/terminal/error log storage and projections.
- [x] Add focused log-store tests for sequence assignment, filtering, terminal
  byte counters, and error projection.
- [x] Investigate intermittent XCTest `SIGTRAP` during fixture reload and fix
  session teardown to stop AppModel reader threads before closing C sessions.
- [x] Extract frame-command list/trace serialization into a focused helper
  with serializer tests.
- [x] Extract render trace and pixel-probe diagnostics into focused builders
  with direct tests.
- [x] Move remaining render endpoint adapters out of `HeadlessDebugRuntime`.
- [x] Extract one-shot diagnostic snapshot writing into an artifact endpoint
  extension and focused writer.
- [x] Move capture status/start/stop/snapshot endpoint adapters and capture
  finalization out of `HeadlessDebugRuntime`.
- [x] Move fixture load/restart/step endpoint adapters and fixture reset helpers
  out of `HeadlessDebugRuntime`.
- [x] Move telemetry/log and selection/clipboard endpoint adapters out of
  `HeadlessDebugRuntime`.
- [x] Move wait endpoint polling and condition checks out of
  `HeadlessDebugRuntime`.
- [x] Move state/session endpoint adapters and grid projection helpers out of
  `HeadlessDebugRuntime`.
- [x] Move screenshot byte and artifact endpoint adapters out of
  `HeadlessDebugRuntime`.

## Decision Log

- Decision: Start with request DTOs and fixture-path resolution before action
  dispatch.
  Rationale: These are high-confidence, behavior-preserving extractions. The
  fixture resolver is security-sensitive and deserves direct tests, while DTOs
  do not need to live inside the runtime type. This creates room for later
  action and render extraction without changing the debug HTTP contract.
  Date/Author: 2026-05-11 / Codex

- Decision: Keep log append timing in `HeadlessDebugRuntime` while moving log
  storage and JSON projection into `DebugRuntimeLogStore`.
  Rationale: The runtime still owns behavioral events such as action routing,
  frame rendering, and capture recording. The store owns bounded buffers,
  sequence numbers, terminal byte counters, and response filtering, which are
  pure debug-contract policies.
  Date/Author: 2026-05-11 / Codex

- Decision: Move action dispatch and key-input decoding before changing the
  action request model.
  Rationale: The existing optional-bag action request is easier to replace
  safely once the endpoint adapter is isolated in `DebugRuntimeActions.swift`
  and pure key decoding lives in `DebugRuntimeKeyInput.swift`. This first cut
  preserves every `/debug/actions` wire shape and keeps the typed-payload
  migration as the next behavioral-neutral refactor.
  Date/Author: 2026-05-11 / Codex

- Decision: Decode `/debug/actions` into a tagged `DebugAction` enum with
  per-action payload structs while keeping fields at the existing top-level
  JSON shape.
  Rationale: This removes the large optional-bag request type without breaking
  current debug clients or endpoint-specific validation messages. Unknown
  action names still reach the unsupported-action response path instead of
  becoming generic decode failures.
  Date/Author: 2026-05-11 / Codex

- Decision: Keep `applyActionUnlocked(_:)` as the lock-held dispatcher, but
  move each action family into focused command objects.
  Rationale: The runtime still owns synchronization and shared state. The
  command objects make tab, window, input, clipboard, selection, viewport, and
  mouse behavior independently readable without adding another lifecycle owner
  or changing the debug HTTP contract.
  Date/Author: 2026-05-11 / Codex

- Decision: Route whole-runtime fixture reset and shutdown through
  `AppModel.closeAllSessions()` instead of closing `Session` instances
  directly.
  Rationale: Crash reports for the intermittent XCTest signal 5 showed malloc
  trapping while `ghostty_terminal_new` allocated a replacement fixture
  session. The reset path was calling `Session.close()` directly, bypassing the
  `SessionRunner.stop()` join that must happen before `laban_session_destroy`.
  Stopping every runner before closing C handles removes that use-after-free
  window.
  Date/Author: 2026-05-11 / Codex

- Decision: Move frame-command JSON projection into
  `DebugFrameCommandSerializer`.
  Rationale: The runtime had repeated knowledge of command ids, kind names,
  approximate glyph geometry, RGBA expansion, and list-vs-trace payload shapes.
  A focused serializer makes endpoint behavior easier to test directly and
  keeps future renderer changes from drifting between debug endpoints.
  Date/Author: 2026-05-11 / Codex

- Decision: Move render-trace assembly and pixel-probe sampling into
  `DebugRenderTraceBuilder` and `DebugPixelProbeSampler`.
  Rationale: The runtime should own locking, live session snapshots, and JSON
  endpoint decoding, not the render-diagnostic schema assembly. Focused helpers
  make trace source/range/pixel behavior testable without constructing the full
  headless runtime.
  Date/Author: 2026-05-11 / Codex

- Decision: Move atlas, render-state, frame-command, render-trace, and
  pixel-probe endpoint adapters into `DebugRenderEndpoints`.
  Rationale: Render endpoints share the same state snapshot and lock-held
  access pattern, but they do not need to live inside the main runtime body.
  Keeping them in an extension gives the render diagnostics a bounded home while
  preserving the runtime as the synchronization owner.
  Date/Author: 2026-05-11 / Codex

- Decision: Move one-shot diagnostic snapshot file and manifest writes into
  `DebugArtifactSnapshotWriter`, with the endpoint adapter in
  `DebugArtifactEndpoints`.
  Rationale: Snapshot writing has its own filesystem policy: deterministic
  directory names, sorted file writes, manifest encoding, and error
  classification. Keeping that policy out of the runtime makes artifact
  behavior directly testable while the runtime still supplies live endpoint
  payloads.
  Date/Author: 2026-05-11 / Codex

- Decision: Move capture lifecycle endpoint adapters into
  `DebugCaptureEndpoints`.
  Rationale: Starting, stopping, snapshotting, and interrupted shutdown all
  operate on the same recorder state and capture sinks. Grouping those methods
  keeps recorder lifecycle policy readable without changing ownership of render
  hooks or AppModel capture sinks.
  Date/Author: 2026-05-11 / Codex

- Decision: Move fixture control and reset helpers into
  `DebugFixtureEndpoints`.
  Rationale: Fixture load, restart, step, and reset all share the same fixture
  runner state and model-replacement path. Keeping those methods together makes
  the crash-sensitive teardown/rebuild flow easier to audit.
  Date/Author: 2026-05-11 / Codex

- Decision: Move telemetry/log endpoints into `DebugTelemetryEndpoints` and
  selection/clipboard endpoints into `DebugSelectionEndpoints`.
  Rationale: These endpoint families project already-owned runtime state but do
  not own lifecycle decisions. Keeping their adapters outside the main runtime
  makes the remaining file focus more tightly on synchronization, session
  state, rendering, and request routing.
  Date/Author: 2026-05-11 / Codex

- Decision: Move `/debug/wait` polling and condition checks into
  `DebugWaitEndpoints` while keeping the runtime lock private.
  Rationale: Wait handling is an endpoint adapter with domain-specific
  condition projection. The extraction now uses the runtime's lock wrapper
  rather than exposing the lock itself, preserving a cleaner synchronization
  boundary.
  Date/Author: 2026-05-11 / Codex

- Decision: Move state/session response projection into
  `DebugStateEndpoints`.
  Rationale: State, session list, session detail, grid cells, hyperlink lookup,
  and wide-cell naming are debug JSON projection concerns. Moving them out of
  the main runtime leaves the runtime focused on lifecycle, locking, rendering,
  and action entry while preserving a shared metadata-sync helper for wait and
  state endpoints.
  Date/Author: 2026-05-11 / Codex

- Decision: Move screenshot readback and artifact endpoint adapters into
  `DebugScreenshotEndpoints`.
  Rationale: Screenshot endpoints own PNG readback timing, screenshot counters,
  artifact directory writes, screenshot events, and capture sidecar recording.
  Keeping this file separate makes the remaining runtime body less endpoint
  oriented while preserving the same lock-held surface access.
  Date/Author: 2026-05-11 / Codex

## Context and Orientation

The debug server is local-only product infrastructure. `Sources/LabanDebug`
contains the HTTP listener, response models, capture/replay support, and the
headless runtime:

- `DebugHTTPServer.swift` accepts loopback HTTP requests and routes paths to
  methods on `HeadlessDebugRuntime`.
- `DebugModels.swift` defines shared JSON responses such as state, sessions,
  render diagnostics, fixture control, and capture metadata.
- `HeadlessDebugRuntime.swift` owns the AppModel, offscreen software renderer,
  session lifecycle, debug actions, wait conditions, fixture control, and
  artifact writing.

The first milestone must preserve every endpoint and JSON shape. It only moves
supporting types and path-resolution policy into new files under the same Swift
module.

## Plan of Work

Create `Sources/LabanDebug/DebugRuntimeRequests.swift` for request DTOs that
are decoded by runtime endpoints and action handlers. Use internal Swift types
so `HeadlessDebugRuntime` can keep using them without widening the public API.

Create `Sources/LabanDebug/DebugFixtureResolver.swift` for dynamic fixture
loads. It must reject empty paths, absolute paths, `..` traversal, symlink path
components, and canonical paths escaping the configured fixture root. Update
`HeadlessDebugRuntime.fixtureControl(_:)` to call that helper.

Add focused tests in `Tests/LabanDebugTests` for valid nested relative paths
and the rejected path classes. Keep the existing runtime-level fixture control
tests as end-to-end coverage.

Later milestones should extract action dispatch, log storage, and render
diagnostics one at a time with tests after each step.

## Validation and Acceptance

Run these commands from the repository root:

```sh
swift test --filter LabanDebugTests
git diff --check
```

Acceptance for the first milestone:

- `HeadlessDebugRuntime.swift` no longer declares the debug request DTOs or
  fixture path resolver.
- `HeadlessDebugRuntime.swift` no longer owns bounded event/input/terminal/error
  buffers or response projection for those logs.
- Fixture control still loads a valid relative fixture through the runtime.
- Absolute, traversal, and symlink fixture paths still return HTTP 400 through
  the runtime.
- Focused resolver tests prove the helper accepts nested relative paths and
  rejects unsafe inputs before fixture loading.
- Focused log-store tests prove sequence assignment, filtering, byte counters,
  escaped previews, and error response projection.
- Focused action-decoding tests prove the tagged action model still accepts the
  existing flat JSON wire shape and preserves unsupported-action routing.
- Domain command objects are covered by the existing `/debug/actions` smoke,
  keyboard, title, capture, selection, clipboard, and mouse tests.
- Fixture reload teardown is covered by a repeated restart regression test and
  allocator-scribble stress runs of the same path.
- Frame-command serialization is covered by focused tests for glyph decoration
  payloads, text hiding, trace geometry, and command kind naming.
- Render trace and pixel-probe payload construction are covered by focused
  builder/sampler tests for sources, ranges, truncation, probes, and region
  averaging.
- One-shot diagnostic snapshot writes are covered by focused writer tests for
  directory naming, file creation, and sorted manifest entries plus the existing
  runtime artifact snapshot test.
- Capture endpoint lifecycle behavior remains covered by the existing capture
  tests for disabled status, start conflicts, snapshot bundles, stop manifests,
  rejected names, and interrupted shutdown.
- Fixture endpoint behavior remains covered by resolver tests plus runtime
  fixture load/step/restart, unsafe path, and repeated-restart teardown tests.
- Telemetry/log and selection/clipboard endpoints remain covered by existing
  timing, metrics, input-log, terminal-log, error-log, event, selection, and
  clipboard debug tests.
- Wait endpoint behavior remains covered by debug smoke tests for frame waits,
  background-session text waits, title waits after metadata sync, and HTTP
  wait concurrency.
- State/session endpoint behavior remains covered by debug smoke, title, and
  exploratory-control tests for state shape, session detail, viewport state,
  title metadata, injected workspace metadata, grid detail, and atlas-adjacent
  session diagnostics.
- Screenshot endpoint behavior remains covered by smoke and exploratory-control
  tests for non-empty PNG bytes, screenshot timing, and diagnostic artifact
  bundles.
- `/debug/actions` behavior remains covered by the existing debug smoke,
  keyboard, title, capture, and exploratory-control tests after action dispatch
  moves out of the runtime file.

## Idempotence and Recovery

The first milestone is additive plus source moves. If a test fails, leave the
new helper files in place and fix the call sites; do not revert unrelated
runtime behavior. Since this is a behavior-preserving refactor, any endpoint
response drift should be treated as a bug in the extraction.
