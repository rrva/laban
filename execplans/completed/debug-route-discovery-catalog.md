# Consolidate Debug Route Discovery

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The debug HTTP server exposes `/debug` as a capability index for agents, but the
endpoint list and the actual route switch are currently maintained in separate
places. After this change, adding or changing a debug endpoint requires editing
one route entry that contains both its discovery metadata and its handler. A
human or agent can verify the behavior by running the debug contract checker and
by exercising existing discovery tests.

## Progress

- [x] (2026-05-11T20:05:50Z) Confirmed discovery metadata lives in
  `Sources/LabanDebug/DebugDiscoveryEndpoints.swift`, routing lives in
  `Sources/LabanDebug/DebugHTTPServer.swift`, and `scripts/check-debug-contract`
  still scans the old runtime file.
- [x] (2026-05-11T20:05:50Z) Replace the duplicated discovery endpoint list and route switch with a
  single route table in the debug server.
- [x] (2026-05-11T20:05:50Z) Update `/debug` discovery to use the route table.
- [x] (2026-05-11T20:05:50Z) Update `scripts/check-debug-contract` to read the new route table.
- [x] (2026-05-11T20:10:56Z) Run focused validation and record the results.

## Decision Log

- Decision: Use the HTTP route table as the source of truth instead of keeping a
  separate discovery catalog and generating routes from discovery metadata.
  Rationale: route handlers need server-specific response details such as PNG
  content type and HTTP headers, while discovery only needs endpoint metadata.
  Keeping both in one route entry removes drift without forcing discovery models
  to know about HTTP implementation details.
  Date/Author: 2026-05-11 / Codex

## Context and Orientation

`Sources/LabanDebug/DebugHTTPServer.swift` accepts authorized loopback HTTP
requests and dispatches `/debug/...` paths to methods on `HeadlessDebugRuntime`.
Most endpoints return JSON through `DebugResponse`; `GET /debug/screenshot`
returns PNG bytes with frame and size headers.

`Sources/LabanDebug/DebugDiscoveryEndpoints.swift` builds the JSON response for
`GET /debug` and `/debug/capabilities`. It currently has a static endpoint list
separate from the HTTP server route switch.

`scripts/check-debug-contract` compares endpoints documented in
`docs/process/dev-process.md` with the implementation. It currently reads
`Sources/LabanDebug/HeadlessDebugRuntime.swift` for discovery entries, which is
stale after the previous debug runtime refactor.

## Plan of Work

In `Sources/LabanDebug/DebugHTTPServer.swift`, introduce a private route entry
type that stores a `DebugDiscoveryEndpoint`, a matcher, and a handler closure.
Replace the large `switch (method, path)` with a loop over those entries. Keep
the authorization logic and response serialization unchanged. Add an internal
static `discoveryEndpoints` property so the discovery response can list the same
route entries used by the HTTP server.

In `Sources/LabanDebug/DebugDiscoveryEndpoints.swift`, remove the static
endpoint array from `DebugDiscoveryCatalog` and populate the discovery response
from `DebugHTTPServer.discoveryEndpoints`. Keep actions, wait conditions,
fixture actions, and examples in that file.

In `scripts/check-debug-contract`, read endpoint and schema metadata from
`Sources/LabanDebug/DebugHTTPServer.swift`, since the route table is now the
source of truth. Continue comparing documented endpoints and schema paths.

## Validation and Acceptance

Run these commands from the repository root:

```sh
rtk ./scripts/check-debug-contract
rtk swift test --filter LabanDebugExploratoryControlTests
rtk swift test --filter LabanDebugSmokeTests
```

Acceptance:

- `./scripts/check-debug-contract` exits 0 and prints
  `check-debug-contract passed`.
- `/debug` and `/debug/capabilities` still list the same endpoint metadata
  expected by the existing discovery tests.
- Existing HTTP smoke tests still pass, including bearer-token authorization,
  health, screenshot, wait concurrency, and endpoint routing behavior.

Validation results from this implementation:

```sh
rtk ./scripts/check-debug-contract
# check-debug-contract passed

rtk swift test --filter LabanDebugExploratoryControlTests
# Executed 10 tests, with 0 failures

rtk swift test --filter LabanDebugSmokeTests
# Executed 39 tests, with 0 failures

rtk swift format lint --strict Sources/LabanDebug/DebugHTTPServer.swift Sources/LabanDebug/DebugDiscoveryEndpoints.swift
# passed

rtk git diff --check
# passed
```

`rtk ./scripts/lint` was also run. It reported existing style failures in
unmodified test files such as `Tests/LabanDebugTests/DebugFrameCommandSerializerTests.swift`,
`Tests/LabanDebugTests/DebugRuntimeLogsTests.swift`,
`Tests/LabanDebugTests/DebugActionDecodingTests.swift`,
`Tests/LabanDebugTests/DebugRuntimeKeyInputTests.swift`, and
`Tests/LabanAppTests/TerminalResizeAutomationTests.swift`; the changed Swift
files pass strict format lint directly.

## Surprises & Discoveries

- Observation: this worktree did not have `.external/`, so the first Swift test
  run could not find `ghostty/vt/terminal.h`.
  Evidence: the project `AGENTS.md` says worktrees should symlink `.external`
  from `/Users/rrj/wrk/laban/.external` when missing; after creating that
  symlink, the focused Swift tests compiled and passed.

## Outcomes & Retrospective

The debug server now has one route table in
`Sources/LabanDebug/DebugHTTPServer.swift`. Each route entry owns the discovery
metadata and the handler. `GET /debug` and `GET /debug/capabilities` list
`DebugHTTPServer.discoveryEndpoints`, so discovery no longer has a separate
endpoint list. `scripts/check-debug-contract` now validates the route table
directly.

## Idempotence and Recovery

The change is a behavior-preserving refactor. Re-running the validation commands
is safe. If an endpoint goes missing, fix the single route table entry rather
than adding a second endpoint list.
