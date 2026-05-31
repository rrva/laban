# Lock Down Debug Server Control

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

The local debug server can drive terminal input, clipboard actions, capture, and fixture loading. After this change, a process that only knows the loopback port cannot use those controls: clients must send a bearer token printed in the one-time readiness JSON. Fixture loads through `/debug/fixture` will also be constrained to a configured fixture root, so a debug request cannot read arbitrary local files by passing absolute paths, `..`, or symlinks.

## Progress

- [x] Read `docs/process/dev-process.md`, `DebugHTTPServer.swift`, `HeadlessDebugRuntime.swift`, and existing debug tests.
- [x] Add bearer-token generation, readiness emission, and request authorization.
- [x] Pin runtime fixture loads to a fixture root and reject path traversal, absolute paths, and symlinks.
- [x] Update scripts, help text, docs, and tests for the token-bearing debug protocol.
- [x] Run focused debug tests, the E2E script, and the full package test suite.

## Outcomes & Retrospective

The debug server now returns `debugToken` in readiness JSON and rejects every `/debug` request without a matching bearer token. Dynamic fixture loads now resolve only under `fixtureRoot` and reject absolute paths, `..`, and symlink components. The debug scripts and E2E harness parse the readiness token and avoid writing the raw token into scenario reports.

## Context and Orientation

`Sources/LabanDebug/DebugHTTPServer.swift` owns the loopback HTTP listener and routes requests into `HeadlessDebugRuntime`. `Sources/LabanDebug/DebugModels.swift` defines the JSON readiness line printed by `Sources/LabanAgent/main.swift`. `HeadlessDebugRuntime.fixtureControl(_:)` implements `POST /debug/fixture`; today it resolves absolute and relative paths directly from the caller. Shell scripts in `scripts/test-e2e` and `scripts/run-debug-script` parse readiness JSON and call debug endpoints.

## Plan of Work

Generate a random token when the HTTP server starts, store it inside `DebugHTTPServer`, include it as `debugToken` in `DebugReadiness`, and require `Authorization: Bearer <token>` for every `/debug` request. Return HTTP 401 with `WWW-Authenticate: Bearer` for missing or invalid tokens.

Add a `fixtureRootURL` to `HeadlessDebugRuntime`, defaulting to `<cwd>/fixtures`, and use it only for dynamic `/debug/fixture` load requests. The trusted initial `--fixture` command-line path remains unchanged. `resolveFixtureURL(_:)` will reject absolute paths, `..`, and symlink components before calling `FixtureRunner.load`.

Update discovery examples, CLI help, E2E scripts, and debug-script runner to propagate the token from readiness JSON. Add tests that unauthenticated HTTP requests fail, authenticated requests work, fixture traversal is rejected, and fixture loads inside a test fixture root still work.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter LabanDebugTests
rtk ./scripts/test-e2e
rtk swift test
```

Acceptance: unauthenticated HTTP calls to `/debug/health` return 401, authenticated calls return 200, fixture loads outside the fixture root return a structured 400 failure, and the full test suite passes. As of this plan update, `LabanDebugTests` passed with 62 tests, `scripts/test-e2e` passed, and `swift test` passed with 285 tests, 2 skipped, and 0 failures.
