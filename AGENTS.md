# Laban

This repository is for building a minimal terminal application from
`docs/product/mvp.md` toward the longer product direction in
`docs/product/spec.md`.

This file is the map. Keep it small. Open the deeper documents only when the
task matches them.

## First Moves

1. Start from the user's task and the files already in front of you.
2. Check `docs/product/mvp.md` before expanding scope.
3. For non-trivial or cross-boundary work, create or update an ExecPlan using
   `PLANS.md`.

## Source Of Truth

- `docs/product/mvp.md` is the current implementation boundary.
- `docs/product/spec.md` is the long-term product behavior.
- If MVP and long-term behavior disagree, implement the MVP first and record
  the deferred behavior.
- Do not add product behavior outside the product docs unless the user asks for
  it or it is required to make the MVP work.

## Read This When

| Open | When |
| --- | --- |
| `docs/product/mvp.md` | You are deciding what belongs in the first usable terminal app. |
| `docs/product/spec.md` | You need long-term product behavior or a question goes beyond MVP scope. |
| `docs/process/dev-process.md` | You are implementing or changing debug hooks, headless mode, screenshots, fixtures, CI E2E tests, or autonomous verification. |
| `docs/process/worktree-isolation.md` | You are adding run commands, artifact directories, temp dirs, debug ports, or multi-worktree execution support. |
| `docs/process/observability.md` | You are adding logs, debug events, metrics, traces, or failure artifacts. |
| `docs/reference/prototype-implementation-notes.md` | You need prototype lessons, known pitfalls, or reusable terminal-core behavior. |
| `docs/process/agent-operating-guide.md` | You need detailed engineering style, verification, changeset, or documentation rules. |
| `PLANS.md` | You are creating or updating an ExecPlan, or an existing ExecPlan has a Review Gate. |
| `execplans/` | The task names a plan, changes a planned feature, crosses major boundaries, or needs design history. |
| `schemas/` | You are changing debug endpoints, fixture formats, artifact metadata, or typed contracts. |
| `docs/quality/` | You are tracking drift, test gaps, debt, or quality gates. |

## Project Landmarks

```text
AGENTS.md                              Small map for agents.
PLANS.md                               ExecPlan rules for long-running work.
README.md                              Human and agent project entrypoint.
docs/product/mvp.md                    Current MVP behavior and non-goals.
docs/product/spec.md                   Long-term product behavior.
docs/process/dev-process.md            Agent-driven debug and headless test harness.
docs/process/agent-operating-guide.md  Detailed working rules for agents.
docs/process/worktree-isolation.md     Isolated run contract for agent worktrees.
docs/process/observability.md          Logs, events, metrics, and trace contract.
docs/reference/                        Non-binding references and prototype lessons.
docs/quality/                          Quality score, debt, and drift tracking.
schemas/                               JSON schemas for debug contracts and fixtures.
fixtures/                              Fixture format notes and examples.
execplans/                             Active and completed ExecPlans.
```

## Hard Rules

- The project must be autonomously verifiable. User-visible terminal behavior
  needs tests, debug-state checks, or screenshot artifacts.
- The debug/headless harness in `docs/process/dev-process.md` is product
  infrastructure, not optional polish.
- Terminal session identity must survive tab selection, view rebuilds, resize,
  and UI refresh.
- Native text input wins over raw modifier interpretation.
- Keep changesets focused on one behavioral reason.
- Git commits are atomic. Commit messages must be single-line reason statements:
  describe why the change exists, not what changed, not which files changed,
  and not the task performed. Bad: `Update plans`. Good: `Because agents need
  bounded execution shards`.
