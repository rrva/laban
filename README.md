# Laban

Laban is a macOS terminal-application project designed for agent-driven
development. The first milestone is a minimal macOS terminal app with vertical
tabs, one independent shell session per tab, correct terminal behavior, and
autonomous headless end-to-end testing.

The first implementation stack is selected. Cross-platform code is welcome
when it supports terminal core reuse, fixtures, schemas, CI, or headless
rendering, but it must not redefine the product as a non-macOS app.

Settled direction:

- macOS-native AppKit-first product shell.
- SwiftPM build with a local developer `.app` bundle script first.
- libghostty is mandatory for the MVP terminal core.
- first terminal core implementation is C behind a narrow C ABI.
- renderer uses unified frame commands; the software/offscreen backend is the
  first complete backend, and a constrained Metal skeleton may appear once
  `LabanRenderer` exists.
- JetBrains Mono and fixed Selenized Light are the MVP font/theme defaults.

## Repository Map

- `AGENTS.md` - small map for agents.
- `PLANS.md` - rules for self-contained ExecPlans.
- `docs/product/mvp.md` - current MVP boundary.
- `docs/product/spec.md` - long-term product behavior.
- `docs/process/dev-process.md` - autonomous debug and test harness contract.
- `docs/process/agent-operating-guide.md` - detailed agent working rules.
- `docs/process/worktree-isolation.md` - isolated run contract for concurrent agents.
- `docs/process/observability.md` - agent-legible logs, events, metrics, and traces.
- `docs/reference/prototype-implementation-notes.md` - non-binding prototype lessons.
- `docs/quality/quality.md` - quality dimensions and current gaps.
- `docs/quality/tech-debt.md` - known debt and cleanup candidates.
- `schemas/` - JSON contracts for debug endpoints, fixtures, and artifacts.
- `fixtures/` - deterministic fixture format and examples.
- `execplans/` - active and completed implementation plans.

## Current State

This repo has a runnable SwiftPM terminal scaffold, a deterministic headless
agent, and a loopback debug server for autonomous exploratory testing. The
current product boundary remains the MVP in `docs/product/mvp.md`; active
implementation work is tracked under `execplans/active/`.

## Current Commands

The stable local commands are shell scripts around SwiftPM:

```sh
./scripts/run-headless
./scripts/run-debug
./scripts/run-debug-script
./scripts/test
./scripts/test-e2e
./scripts/check
```

`./scripts/check` validates JSON files under `schemas/` and `fixtures/`, keeps
`AGENTS.md` map-sized, verifies active ExecPlans have required sections, runs
local documentation, debug-contract, and dependency-policy checks, runs Swift
lint/build/test gates, runs the runtime smoke test, and runs the headless
debug-server E2E gate.

## Debug Control Quickstart

Start the headless debug server:

```sh
./scripts/run-debug
```

The first stdout line is readiness JSON:

```json
{"debugServer":"http://127.0.0.1:49321","pid":12345,"runId":"manual-debug"}
```

Export that URL and ask the running server what it supports:

```sh
export DEBUG_URL=http://127.0.0.1:49321
curl "$DEBUG_URL/debug" | jq
curl "$DEBUG_URL/debug/capabilities" | jq
```

Useful starting points:

```sh
curl "$DEBUG_URL/debug/state" | jq
curl "$DEBUG_URL/debug/render" | jq
curl "$DEBUG_URL/debug/metrics" | jq
curl -X POST "$DEBUG_URL/debug/actions" \
  -H 'Content-Type: application/json' \
  -d '{"action":"typeText","text":"printf \"ok\\n\"\n"}'
curl -X POST "$DEBUG_URL/debug/wait" \
  -H 'Content-Type: application/json' \
  -d '{"timeoutMs":5000,"condition":{"kind":"textVisible","text":"ok"}}'
curl -X POST "$DEBUG_URL/debug/snapshot" -d '{}'
```

The agent binary also advertises the debug-control entry points:

```sh
swift run laban-agent -- --help
```

For repeatable exploratory flows, run a debug script scenario. The runner
starts a headless debug server, executes each step, writes a report, and shuts
the server down:

```sh
./scripts/run-debug-script fixtures/debug-script-basic.scenario.json
```

## Implementation Selection

The stack selection is recorded in
`execplans/completed/choose-implementation.md`. The active umbrella plan is
`execplans/active/swiftpm-appkit-software-renderer-mvp.md`; start execution
with `execplans/active/swiftpm-libghostty-skeleton.md`.

The selected implementation optimizes for:

- native macOS app behavior over cross-platform UI convenience
- AppKit-first shell over webview or generic cross-platform UI
- libghostty-backed terminal behavior through a C ABI
- real terminal behavior over UI mockups
- macOS text input correctness, including layout-specific Option characters
- a frame-command renderer that can be captured headlessly
- agent-legible tests and debug state
- narrow boundaries around terminal session ownership

## Done Means Observable

MVP behavior is not done until an agent can launch the app in headless mode,
drive it through debug actions, query internal state, capture screenshots, and
run the same flow in CI..
