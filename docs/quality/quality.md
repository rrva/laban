# Quality Tracker

This document tracks whether the repository is legible and enforceable enough
for autonomous agents. Update it when a quality dimension materially changes.

## Current Score

Overall: **MVP shipped 2026-05-17; enforcement gaps remain on hosted CI and
stale active plans**

The repo has a SwiftPM/AppKit terminal app, a C terminal-core boundary over
libghostty-vt, Metal and software/offscreen render paths, a headless debug
runtime, capture/replay artifacts, and local verification scripts. Every
requirement in `docs/product/mvp.md` is implemented and exercised by
`./scripts/check`. Quality is now judged on regression coverage and
enforcement strength rather than feature completeness.

## Dimensions

| Area | Status | Evidence | Gap |
| --- | --- | --- | --- |
| Product scope | Good | `docs/product/mvp.md`, `docs/product/spec.md`, `README.md`, `Sources/LabanCore/ShellIntegrationOverlay.swift` | OSC 133 shell integration (spec §7) now ships: parsing, zsh/bash/fish injection, and a sidebar phase indicator. Keep deferred features explicit: settings persistence, custom terminfo, and Kitty graphics remain outside MVP. |
| Agent map | Good | `AGENTS.md` is a small map. | Keep it short as docs grow. |
| ExecPlans | Partial | `PLANS.md`, `execplans/completed/choose-implementation.md`, `execplans/completed/pty-launch-lifecycle.md`, active plans under `execplans/active/` | Several active plans are historical umbrella plans and should be retired or refreshed as slices complete. |
| Debug harness contract | Good | `docs/process/dev-process.md`, `schemas/debug/`, `Sources/LabanDebug/`, `Tests/LabanDebugTests/`, `scripts/test-e2e` success coverage, and `scripts/test-e2e` failed-run artifact bundles. | Keep schema examples and endpoint behavior synchronized as debug actions expand. |
| Headless graphics contract | Good | `Sources/LabanDebug/HeadlessDebugRuntime.swift`, `Sources/LabanRenderer/SoftwareRenderer.swift`, `scripts/run-headless`, `scripts/smoke-runtime`, `scripts/test-e2e` | CI still needs to run the full local gate. |
| Fixture format | Good | `schemas/fixture.schema.json`, `fixtures/`, `Sources/LabanCore/FixtureRunner.swift`, `Tests/LabanCoreTests/FixtureRunnerTests.swift` | Expand fixtures when protocol-specific regressions are found. |
| Observability | Good | `docs/process/observability.md`, `GET /debug/events`, `GET /debug/metrics`, `GET /debug/timing`, `POST /debug/render-trace`, `Sources/LabanApp/EventLog.swift`, `Sources/LabanApp/AppLog.swift`, capture timeline artifacts | Keep expanding production AppKit metrics as renderer and shell-integration behavior grows. |
| Mechanical enforcement | Good | `./scripts/check` validates JSON, AGENTS size, ExecPlan sections, whitespace, architecture boundaries, repository-local Markdown links, debug endpoint contract drift, dependency policy, Swift format/build/tests, `LabanTerminalCoreTests` under Address Sanitizer, runtime smoke, and E2E. `./scripts/check-docs`, `./scripts/check-debug-contract`, and `./scripts/check-dependencies` are available as focused policy gates, `./scripts/check-sanitize` remains available as the focused sanitizer gate, `./scripts/test-find-perf` guards terminal-find latency in release mode, and `./scripts/dev-index` generates `compile_commands.json` for clangd C diagnostics. | Needs hosted CI. |
| Architecture boundaries | Good | `Sources/LabanTerminalCore/` exposes the C ABI, `Sources/LabanCore/` owns session/app model wrappers, `Sources/LabanApp/` owns AppKit, `Sources/LabanRenderer/` owns render backends, ADRs in `docs/adr/`, and `./scripts/check-boundaries` blocks forbidden imports across these layers. | Keep the automated check current as new modules or adapter seams are added. |
| Drift control | Partial | This document, `tech-debt.md`, `AGENTS.md`, `PLANS.md`, and `./scripts/check` ExecPlan validation. | Needs regular cleanup of stale active plans and local doc-link checking. |

## Quality Gates To Add Before Major Implementation

- CI job running `./scripts/check`.
- ~~Markdown link check for repository-local docs.~~ Done:
  `./scripts/check-docs` runs in `./scripts/check`.
- ~~Check that debug endpoint examples in `docs/process/dev-process.md` match
  schemas and runtime behavior.~~ Done: `./scripts/check-debug-contract`
  compares documented endpoints with discovery, router coverage, and schema
  paths.
- ~~Import/boundary checks that prevent `Sources/LabanTerminalCore/` from
  depending on AppKit, debug HTTP, or renderer implementation details.~~ Done:
  `./scripts/check-boundaries` runs in `./scripts/check`.

## Quality Gates To Add After Language Selection

- ~~Formatter and linter.~~ Done: `./scripts/lint` (swift format), `./scripts/format`.
- ~~Unit test command.~~ Done: `swift test` runs in `./scripts/check`.
- ~~Headless E2E command.~~ Done: `./scripts/test-e2e` runs in `./scripts/check`.
- ~~Architecture boundary checks.~~ Done: `./scripts/check-boundaries`.
- ~~Dependency policy checks.~~ Done: `./scripts/check-dependencies`
  verifies SwiftPM stays dependency-free and the libghostty-vt pin, source,
  local checkout, and built artifacts match policy.
- ~~Artifact collection on E2E failure.~~ Done: `./scripts/test-e2e`
  writes bounded failure artifacts before teardown.
- ~~Terminal-find performance guard.~~ Done: `./scripts/test-find-perf`
  runs a release-mode benchmark for cold full-history search, cached
  navigation, and pending needle updates.

## Updating This File

When an agent adds a new enforcement mechanism, update the relevant row from
"Partial" or "Weak" to the new status and link the command or file that proves
it.
