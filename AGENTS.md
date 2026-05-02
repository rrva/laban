# Laban

This repository is for building a minimal terminal application from `mvp.md`
toward the longer product direction in `spec.md`.

This file is the map. Keep it small. Open the deeper documents only when the
task matches them.

## First Moves

1. Start from the user's task and the files already in front of you.
2. Check `mvp.md` before expanding scope.
3. For non-trivial or cross-boundary work, create or update an ExecPlan using
   `PLANS.md`.

## Source Of Truth

- `mvp.md` is the current implementation boundary.
- `spec.md` is the long-term product behavior.
- If `mvp.md` and `spec.md` disagree, implement `mvp.md` first and record the
  deferred behavior.
- Do not add product behavior outside `mvp.md` or `spec.md` unless the user asks
  for it or it is required to make the MVP work.

## Read This When

| Open | When |
| --- | --- |
| `mvp.md` | You are deciding what belongs in the first usable terminal app. |
| `spec.md` | You need long-term product behavior or a question goes beyond MVP scope. |
| `dev_process.md` | You are implementing or changing debug hooks, headless mode, screenshots, fixtures, CI E2E tests, or autonomous verification. |
| `impl_notes.md` | You need prototype lessons, known pitfalls, or reusable terminal-core behavior. |
| `docs/agent-operating-guide.md` | You need detailed engineering style, verification, changeset, or documentation rules. |
| `PLANS.md` | You are creating or updating an ExecPlan, or an existing ExecPlan has a Review Gate. |
| `execplans/` | The task names a plan, changes a planned feature, crosses major boundaries, or needs design history. |

## Project Landmarks

```text
AGENTS.md                     Small map for agents.
PLANS.md                      ExecPlan rules for long-running work.
mvp.md                        Current MVP behavior and non-goals.
spec.md                       Long-term product behavior.
dev_process.md                Agent-driven debug and headless test harness.
impl_notes.md                 Non-binding lessons from the prototype.
docs/agent-operating-guide.md Detailed working rules for agents.
execplans/                    Future active and completed ExecPlans.
```

## Hard Rules

- The project must be autonomously verifiable. User-visible terminal behavior
  needs tests, debug-state checks, or screenshot artifacts.
- The debug/headless harness in `dev_process.md` is product infrastructure, not
  optional polish.
- Terminal session identity must survive tab selection, view rebuilds, resize,
  and UI refresh.
- Native text input wins over raw modifier interpretation.
- Keep changesets focused on one behavioral reason.
