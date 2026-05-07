# Technical Debt And Drift

This file tracks known cleanup work. Keep entries small and actionable. Remove
entries when the debt is paid or no longer relevant.

## Open

### Add CI for repository checks

Problem: `./scripts/check` exists locally but does not run in CI.

Desired outcome: CI runs `./scripts/check` on every push and pull request.

Blocked by: repository hosting and CI provider have not been selected.

## Closed

### Add implementation-selection decision record

Closed: 2026-05-03.

Outcome: `execplans/completed/choose-implementation.md` records the selected
SwiftPM/AppKit/C/libghostty/software-renderer-first stack, rejected
alternatives, and follow-up execution plans.

### Implement baseline observability query path

Closed: 2026-05-07.

Outcome: the headless debug runtime exposes `/debug/events`; app-side logs and
events are recorded through `AppLog` and `EventLog`; capture/replay artifacts
record ordered input, PTY, snapshot, and frame-command evidence.

### Add queryable observability metrics and traces

Closed: 2026-05-07.

Outcome: the headless debug runtime exposes `/debug/metrics`, `/debug/timing`,
and `/debug/render-trace`; diagnostic snapshots include `metrics.json`, and
the E2E gate checks the metrics contract.

### Add repository-local link checker

Closed: 2026-05-07.

Outcome: `./scripts/check-docs` validates repository-local Markdown link
targets under the root docs, schema, fixture, and ExecPlan docs, and
`./scripts/check` runs it before the Swift build/test gates.

### Add debug endpoint contract checker

Closed: 2026-05-07.

Outcome: `./scripts/check-debug-contract` compares the debug endpoints
documented in `docs/process/dev-process.md` with the runtime discovery table,
HTTP router cases, and schema paths, and `./scripts/check` runs it before the
Swift build/test gates.

### Add E2E failure artifact collection

Closed: 2026-05-07.

Outcome: `./scripts/test-e2e` now writes a bounded failure bundle before
tearing down the debug server, including run metadata, environment summary,
debug state, sessions, render state, render trace, events, input and terminal
logs, errors, timing, metrics, a screenshot, stdout/stderr tails, and a
one-shot debug snapshot result.

### Add dependency policy check

Closed: 2026-05-07.

Outcome: `./scripts/check-dependencies` keeps the SwiftPM package free of
external package dependencies unless a future change explicitly documents and
pins one, verifies `scripts/fetch-libghostty-vt` fetches the official Ghostty
repository at the ADR-documented commit, and checks the local libghostty-vt
checkout and static archive/header when `.external/` is present.
