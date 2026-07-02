# Laban

This repository builds a macOS terminal application. **It is post-MVP**: the
MVP shipped 2026-05-17, so `docs/product/mvp.md` is now a regression contract
(shipped behavior not to break), not a build target. New direction lives in
`docs/product/spec.md`.

This file is the map. Keep it small. Open deeper documents only when the task
matches them.

## First Moves

1. Start from the user's task and the files already in front of you.
2. Check `docs/product/mvp.md` as a regression contract before risking shipped
   behavior.
3. Check `docs/product/spec.md` before expanding product scope.
4. For non-trivial or cross-boundary work, create or update an ExecPlan using
   `PLANS.md`.

## Source Of Truth

- `docs/product/mvp.md` is the shipped-behavior regression contract; its
  non-goals and milestones are historical and superseded by `spec.md`.
- `docs/product/spec.md` is the long-term direction; new scope flows through it.
- Bug fixes, polish, performance, and refactors that preserve MVP behavior do
  not need spec approval.
- Do not add product behavior outside the product docs unless the user asks for
  it or it is required to keep MVP behavior working.

## Read This When

| Open | When |
| --- | --- |
| `docs/product/mvp.md` | You are checking whether a change risks breaking shipped behavior. |
| `docs/product/spec.md` | You are expanding product scope or need long-term direction. |
| `docs/process/dev-process.md` | You are changing debug hooks, headless mode, screenshots, capture/replay artifacts, fixtures, CI E2E tests, autonomous verification, or renderer perf trace loops. |
| `docs/process/profiling-hiccups.md` | You are capturing/analyzing Metal System Traces and hit empty shader-profiler schemas, xctrace log-archive warnings, or other profiling gotchas. |
| `docs/process/worktree-isolation.md` | You are adding run commands, artifact directories, temp dirs, debug ports, multi-worktree support, or fixing `.external` / `.rpg` worktree setup. |
| `docs/process/observability.md` | You are adding logs, debug events, metrics, traces, or failure artifacts. |
| `docs/process/agent-operating-guide.md` | You need build/install/restart commands, runtime artifact locations, renderer safety rules, verification rules, changeset rules, or self-improvement guidance. |
| `docs/reference/prototype-implementation-notes.md` | You need prototype lessons, known pitfalls, or reusable terminal-core behavior. |
| `PLANS.md` | You are creating or updating an ExecPlan, or an existing ExecPlan has a Review Gate. |
| `execplans/` | The task names a plan, changes a planned feature, crosses major boundaries, or needs design history. |
| `schemas/` | You are changing debug endpoints, fixture formats, artifact metadata, or typed contracts. |
| `docs/quality/` | You are tracking drift, test gaps, debt, or quality gates. |
| `docs/adr/README.md` | A change touches the terminal library, PTY ownership, rendering architecture, SwiftPM target boundaries, or a decision that looks previously settled. |
| `docs/process/formal-specs.md` | You are changing a labpty state machine with a TLA+ spec, CBMC proof, trace-conformance harness, MC/DC or mutation-adequacy gate, or a recent fix needs regression coverage. |
| `docs/process/rpg-graph-maintenance.md` | You are lifting or refreshing the `.rpg` semantic graph (`graph.json`), or wiring it into git worktrees. |

## Project Landmarks

Core maps: `README.md`, `PLANS.md`, `execplans/`, `docs/adr/`, `docs/quality/`.
Product and process truth: `docs/product/`, `docs/process/`, `docs/reference/`.
Debug contracts and data: `schemas/`, `fixtures/`.

## Standing Rules

- User-visible terminal behavior must be autonomously verifiable through tests,
  debug-state checks, screenshots, or capture/replay artifacts.
- The debug/headless harness is product infrastructure. Keep
  `HeadlessDebugRuntime` in feature parity with the visible app path and expose
  shared behavior through loopback debug endpoints.
- Terminal session identity must survive tab selection, view rebuilds, resize,
  and UI refresh. Native text input wins over raw modifier interpretation.
- Renderer work has extra contracts: live setting observers, cached settings and
  glyph metadata, live-scale Metal instance uploads, visual-font cache keys,
  ADR 0026 present-link invariants, and measure-first visual-artifact diagnosis.
  Open `docs/process/agent-operating-guide.md` and relevant ADRs first.
- Keep changesets focused on one behavioral reason. Git commits are atomic, and
  commit messages are single-line reasons, not file-change summaries.
