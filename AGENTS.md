# Laban

This repository builds a macOS terminal application. The MVP described in
`docs/product/mvp.md` shipped on 2026-05-17; that document is now the
regression contract. New product direction lives in `docs/product/spec.md`.

This file is the map. Keep it small. Open the deeper documents only when the
task matches them.

## First Moves

1. Start from the user's task and the files already in front of you.
2. Check `docs/product/mvp.md` as a regression contract — never break a
   behavior required there.
3. Check `docs/product/spec.md` before expanding product scope.
4. For non-trivial or cross-boundary work, create or update an ExecPlan using
   `PLANS.md`.

## Source Of Truth

- `docs/product/mvp.md` is the regression contract for shipped behavior.
- `docs/product/spec.md` is the long-term direction; new scope flows through it.
- Bug fixes, polish, performance, and refactors that preserve MVP behavior
  do not need spec.md approval.
- Do not add product behavior outside the product docs unless the user asks
  for it or it is required to keep an MVP behavior working.

## Read This When

| Open | When |
| --- | --- |
| `docs/product/mvp.md` | You are checking whether a change risks breaking shipped behavior. |
| `docs/product/spec.md` | You are expanding product scope or need long-term direction. |
| `docs/process/dev-process.md` | You are implementing or changing debug hooks, headless mode, screenshots, capture/replay artifacts, fixtures, CI E2E tests, or autonomous verification. |
| `docs/process/worktree-isolation.md` | You are adding run commands, artifact directories, temp dirs, debug ports, or multi-worktree execution support. |
| `docs/process/observability.md` | You are adding logs, debug events, metrics, traces, or failure artifacts. |
| `docs/reference/prototype-implementation-notes.md` | You need prototype lessons, known pitfalls, or reusable terminal-core behavior. |
| `docs/process/agent-operating-guide.md` | You need detailed engineering style, verification, changeset, or documentation rules. |
| `PLANS.md` | You are creating or updating an ExecPlan, or an existing ExecPlan has a Review Gate. |
| `execplans/` | The task names a plan, changes a planned feature, crosses major boundaries, or needs design history. |
| `schemas/` | You are changing debug endpoints, fixture formats, artifact metadata, or typed contracts. |
| `docs/quality/` | You are tracking drift, test gaps, debt, or quality gates. |
| `docs/adr/` | A change touches the terminal library, PTY ownership, rendering architecture, SwiftPM target boundaries, or a decision that looks previously settled. |

## Project Landmarks

```text
AGENTS.md                              Small map for agents.
PLANS.md                               ExecPlan rules for long-running work.
README.md                              Human and agent project entrypoint.
docs/product/mvp.md                    Current MVP behavior and non-goals.
docs/product/spec.md                   Long-term product behavior.
docs/process/dev-process.md            Agent-driven debug, capture/replay, and headless test harness.
docs/process/agent-operating-guide.md  Detailed working rules for agents.
docs/process/worktree-isolation.md     Isolated run contract for agent worktrees.
docs/process/observability.md          Logs, events, metrics, and trace contract.
docs/reference/                        Non-binding references and prototype lessons.
docs/quality/                          Quality score, debt, and drift tracking.
schemas/                               JSON schemas for debug contracts and fixtures.
fixtures/                              Fixture format notes and examples.
execplans/                             Active and completed ExecPlans.
```

## Decision Index

- `docs/adr/0001-libghostty-vt-owns-vt-parsing.md` — libghostty-vt (not GhosttyKit) owns VT parsing; application owns the PTY.
- `docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md` — PTY launch uses parent-side `openpty` and a constrained fork child, not `forkpty` or pure `posix_spawn`.
- `docs/adr/0003-terminal-find-uses-laban-side-scan.md` — terminal find scans Laban snapshots and extracted scrollback until libghostty-vt exposes C search bindings.

Write a new ADR when a change establishes durable architectural policy, reverses a previously settled decision, or sets an adapter boundary. Number it sequentially in `docs/adr/`, follow the existing file's structure (Status, Context, Decision, Consequences, Applies To New Code), and add a one-line entry here with the path and summary.

## Worktree Setup

Git worktrees do not clone `.external/`. If missing, symlink it from the
main repo: `ln -s "$LABAN_MAIN_REPO/.external" .external`. `.external/`
holds vendored libs (`libghostty-vt`) shared across worktrees.

## Hard Rules

- The project must be autonomously verifiable. User-visible terminal behavior
  needs tests, debug-state checks, screenshot artifacts, or capture/replay
  artifacts.
- The debug/headless harness in `docs/process/dev-process.md` is product
  infrastructure, not optional polish.
- `HeadlessDebugRuntime` stays in feature parity with
  `MainWindowController.makeAndShow`. Wire new subsystems into both and
  expose HTTP endpoints. Move shared types from `LabanApp` down to
  `LabanCore` (no AppKit deps) so `LabanDebug` can reach them.
- Terminal session identity must survive tab selection, view rebuilds, resize,
  and UI refresh.
- Native text input wins over raw modifier interpretation.
- Keep changesets focused on one behavioral reason.
- Git commits are atomic. Commit messages are single-line reason statements:
  why the change exists, not what changed. Bad: `Update plans`. Good:
  `Agents need bounded execution shards`.
