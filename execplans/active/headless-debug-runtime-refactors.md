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
- [ ] Commit the first behavior-preserving milestone.
- [ ] Extract action dispatch into smaller action handlers.
- [ ] Extract event/input/terminal/error log storage and projections.
- [ ] Extract render diagnostics and frame-command serialization.

## Decision Log

- Decision: Start with request DTOs and fixture-path resolution before action
  dispatch.
  Rationale: These are high-confidence, behavior-preserving extractions. The
  fixture resolver is security-sensitive and deserves direct tests, while DTOs
  do not need to live inside the runtime type. This creates room for later
  action and render extraction without changing the debug HTTP contract.
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
- Fixture control still loads a valid relative fixture through the runtime.
- Absolute, traversal, and symlink fixture paths still return HTTP 400 through
  the runtime.
- Focused resolver tests prove the helper accepts nested relative paths and
  rejects unsafe inputs before fixture loading.

## Idempotence and Recovery

The first milestone is additive plus source moves. If a test fails, leave the
new helper files in place and fix the call sites; do not revert unrelated
runtime behavior. Since this is a behavior-preserving refactor, any endpoint
response drift should be treated as a bug in the extraction.
