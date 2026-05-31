# Make Debug Server Connections Non-Blocking For Other Clients

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

The debug server is the automation surface for tests and agents. After this change, one slow or long-running client cannot freeze every other debug endpoint, and transient `accept` errors do not silently kill the server. This keeps state, health, and screenshot probes available while a `/debug/wait` request is open or a peer is trickling headers.

## Progress

- [x] Read `DebugHTTPServer.swift` and the runtime wait loop.
- [x] Dispatch accepted sockets to concurrent handlers while keeping one request per connection.
- [x] Bound header/body reads with receive timeouts and wall-clock deadlines.
- [x] Keep accepting after transient `accept` failures while still exiting cleanly after `stop()`.
- [x] Add regression coverage for slow headers and concurrent `/debug/wait` plus health.
- [x] Run focused debug tests.
- [x] Run E2E and the full package suite.

## Outcome

`DebugHTTPServer` now accepts connections on the listen thread and handles each client on a concurrent queue. Client header and body reads have socket receive timeouts plus wall-clock deadlines, and transient `accept` failures no longer shut down the server loop. Regression tests prove an incomplete header and a long `/debug/wait` cannot block an authenticated `/debug/health` probe.

## Context and Orientation

`Sources/LabanDebug/DebugHTTPServer.swift` currently accepts one client and handles it synchronously on the accept thread. `HeadlessDebugRuntime.wait(_:)` can hold a request open until a condition is satisfied or a timeout expires. Because the server is synchronous, a wait request or slow header read prevents later clients from reaching health, state, screenshot, or control endpoints. `accept` also breaks the server loop on any negative return.

## Plan of Work

Add a concurrent `DispatchQueue` for per-connection work. The accept loop should continue immediately after handing a client fd to the queue. Before reading a request, set a small receive timeout on the client socket and enforce a 2 second wall-clock deadline for headers, matching the existing body-read intent. Update `acceptLoop()` to retry `EINTR`, `ECONNABORTED`, `EMFILE`, and `ENFILE` rather than exiting, and break only when the server fd has been closed or a fatal error is encountered.

Add tests that start a real `DebugHTTPServer`, authenticate with the readiness token, open a long `/debug/wait`, and prove `/debug/health` still returns promptly. Add a slow-header socket test that sends an incomplete request and proves a normal authenticated health request still succeeds while that socket is open.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter LabanDebugTests
rtk ./scripts/test-e2e
rtk swift test
```

Acceptance: the new HTTP concurrency tests fail against the old synchronous accept handler, pass after this change, and the full suite remains green.
