# Technical Debt And Drift

This file tracks known cleanup work. Keep entries small and actionable. Remove
entries when the debt is paid or no longer relevant.

## Open

### Add CI for repository checks

Problem: `./scripts/check` exists locally but does not run in CI.

Desired outcome: CI runs `./scripts/check` on every push and pull request.

Blocked by: repository hosting and CI provider have not been selected.

### Add repository-local link checker

Problem: docs now cross-link through several directories. Broken links would
make the repo less legible to agents.

Desired outcome: a stable `check-docs` or equivalent command fails on broken
repository-local Markdown links.

Blocked by: link-check tooling has not been added to `./scripts/check`.

### Implement observability contract

Problem: `docs/process/observability.md` defines logs, events, metrics, and
traces, but no app or local query command exists yet.

Desired outcome: a stable local command or debug endpoint lets agents query the
observability signals for an isolated run.

Blocked by: implementation has not started.

## Closed

### Add implementation-selection decision record

Closed: 2026-05-03.

Outcome: `execplans/completed/choose-implementation.md` records the selected
SwiftPM/AppKit/C/libghostty/software-renderer-first stack, rejected
alternatives, and follow-up execution plans.
