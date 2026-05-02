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

Blocked by: command runner has not been selected.

### Add implementation-selection decision record

Problem: the repo intentionally has no language/runtime choice yet. Once chosen,
that decision should be durable and discoverable.

Desired outcome: the implementation-selection ExecPlan records the decision and
adds an ADR or equivalent decision note.

Blocked by: `execplans/active/choose-implementation.md` has not been executed.

### Implement observability contract

Problem: `docs/process/observability.md` defines logs, events, metrics, and
traces, but no app or local query command exists yet.

Desired outcome: a stable local command or debug endpoint lets agents query the
observability signals for an isolated run.

Blocked by: implementation stack and runtime model are not selected.

## Closed

(none yet)
