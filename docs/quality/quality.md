# Quality Tracker

This document tracks whether the repository is legible and enforceable enough
for autonomous agents. Update it when a quality dimension materially changes.

## Current Score

Overall: **Planning scaffold only**

The repo has product/process contracts but no runnable implementation yet.
Quality is therefore judged by agent readiness rather than app behavior.

## Dimensions

| Area | Status | Evidence | Gap |
| --- | --- | --- | --- |
| Product scope | Good | `docs/product/mvp.md`, `docs/product/spec.md` | Needs acceptance tests once implementation starts. |
| Agent map | Good | `AGENTS.md` is a small map. | Keep it short as docs grow. |
| ExecPlans | Partial | `PLANS.md`, `execplans/completed/choose-implementation.md`, `execplans/active/swiftpm-libghostty-skeleton.md` | Needs first implementation plan completed against code. |
| Debug harness contract | Good | `docs/process/dev-process.md`, `schemas/debug/` | Needs implementation and contract tests. |
| Headless graphics contract | Good | `docs/process/dev-process.md`, `execplans/active/swiftpm-appkit-software-renderer-mvp.md` | Needs software renderer and offscreen proof. |
| Fixture format | Partial | `schemas/fixture.schema.json`, `fixtures/` | Needs fixture runner after stack selection. |
| Observability | Partial | `docs/process/observability.md` and debug events schema exist. | Needs implementation and query command. |
| Mechanical enforcement | Partial | `./scripts/check` runs `./scripts/lint` (swift format), validates JSON, AGENTS size, ExecPlan sections, and whitespace. `./scripts/check-sanitize` runs `LabanTerminalCoreTests` under Address Sanitizer. `./scripts/dev-index` generates `compile_commands.json` for clangd C diagnostics. | Needs CI and deeper link/schema semantic checks. |
| Architecture boundaries | Planned | Product docs and active SwiftPM ExecPlans define boundaries. | Needs language-specific structural checks after scaffold lands. |
| Drift control | Partial | This document and `tech-debt.md`. | Needs recurring check command. |

## Quality Gates To Add Before Major Implementation

- CI job running `./scripts/check`.
- Markdown link check for repository-local docs.
- Check that `AGENTS.md` stays small and only points to deeper docs.
- Check that every active ExecPlan has `Progress` and `Validation and Acceptance`.
- Check that debug endpoint examples in `docs/process/dev-process.md` match
  schemas.

## Quality Gates To Add After Language Selection

- ~~Formatter and linter.~~ Done: `./scripts/lint` (swift format), `./scripts/format`.
- Unit test command. (`swift test` runs in `./scripts/check`.)
- Headless E2E command.
- Architecture boundary checks.
- Dependency policy checks.
- Artifact collection on E2E failure.

## Updating This File

When an agent adds a new enforcement mechanism, update the relevant row from
"Partial" or "Weak" to the new status and link the command or file that proves
it.
