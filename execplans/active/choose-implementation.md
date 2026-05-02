# Choose The Initial Implementation Stack

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The repository has product requirements, autonomous test-harness contracts, and
prototype lessons, but no programming language or app stack. After this plan is
complete, a future agent will know what stack to scaffold first, why it was
chosen, what alternatives were rejected, and how to verify the decision without
relying on chat history.

The user-visible outcome is not a terminal app yet. The outcome is a durable
implementation decision and a scaffold plan that can be executed by a fresh
agent.

## Progress

- [ ] Read `AGENTS.md`, `docs/product/mvp.md`, `docs/product/spec.md`,
  `docs/process/dev-process.md`, and
  `docs/reference/prototype-implementation-notes.md`.
- [ ] Define the decision criteria from the MVP and debug harness.
- [ ] Compare at least three credible implementation stacks.
- [ ] Choose one stack for the first runnable scaffold.
- [ ] Record rejected alternatives and why they lost.
- [ ] Update repository docs with the chosen command names and constraints.
- [ ] Add a follow-up ExecPlan for the first runnable scaffold.

## Context and Orientation

This repo is intentionally language-agnostic. The MVP is a desktop terminal app
with one window, vertical tabs, one independent shell session per tab, correct
terminal input/output behavior, and autonomous headless E2E testing.

Important files:

- `docs/product/mvp.md` defines what the first app must do.
- `docs/product/spec.md` defines long-term behavior beyond the MVP.
- `docs/process/dev-process.md` defines required debug endpoints, screenshot
  capture, headless mode, fixture mode, and artifact collection.
- `docs/reference/prototype-implementation-notes.md` captures lessons from a
  working prototype but does not mandate architecture.
- `schemas/` contains implementation-neutral contracts that the chosen stack
  must eventually serve or validate.

Key terms:

- "Terminal core" means the code that owns the pty, child process, terminal
  parser/state, input encoders, render state, scrollback, title, and exit
  status.
- "Headless mode" means the app runs without a visible OS window but still
  renders into an inspectable offscreen surface.
- "Debug server" means the local loopback HTTP interface described in
  `docs/process/dev-process.md`.

## Decision Criteria

The chosen stack must be judged against these criteria:

1. Terminal correctness: can use a proven terminal core rather than hand-rolled
   VT parsing.
2. Native text input: can correctly handle platform text input and
   layout-specific characters.
3. Headless graphics: can render into an offscreen surface and produce PNG
   screenshots in CI.
4. Agent legibility: code, tests, schemas, and debug state are easy for agents
   to inspect and modify.
5. Small first scaffold: can produce a runnable demo quickly without hiding
   ownership boundaries.
6. Failure-path testability: can test partial initialization failure and cleanup.
7. Future production path: can grow toward multi-window, panes, persistence,
   accessibility, and packaging.

## Candidate Stacks To Compare

The executing agent may add more, but must compare at least these:

### Native app shell with shared terminal core

Example shape: platform-native UI shell, a small terminal core behind a C ABI
or equivalent FFI boundary, and a renderer boundary that can be backed by a
native renderer or offscreen test renderer.

Why it is credible: aligns with native input requirements and keeps terminal
session ownership explicit.

Risk: FFI and renderer boundaries can slow the first scaffold if overbuilt.

### Single-language systems app

Example shape: one systems language owns pty, terminal core integration,
windowing, rendering, debug server, and tests.

Why it is credible: simple ownership and fewer language boundaries.

Risk: native text input and production UI integration may be weaker depending
on toolkit.

### Webview or browser-hosted shell with native helper

Example shape: native or local helper owns pty and terminal core, browser UI
owns tabs and rendering/debug interaction.

Why it is credible: headless screenshots and agent-driven UI tests are easier.

Risk: terminal rendering/input behavior may drift from native terminal
expectations, and webview constraints may become product constraints.

## Plan of Work

1. Read the repository docs listed in Context and Orientation.
2. Turn the Decision Criteria into a small comparison table.
3. For each candidate, explain how it satisfies or fails:
   - pty/session ownership
   - terminal core integration
   - native text input
   - headless rendering
   - debug server
   - fixture mode
   - CI viability
4. Choose the first stack.
5. Record the decision in the Decision Log with a clear rationale.
6. Update `README.md` intended commands if the choice makes command names more
   concrete.
7. Add a new follow-up ExecPlan under `execplans/active/` for scaffolding the
   first runnable app.

## Validation and Acceptance

This plan is complete when:

- `Progress` is fully checked.
- The Decision Log names one chosen stack and at least two rejected
  alternatives.
- `README.md` and `AGENTS.md` still point to correct docs.
- A follow-up scaffold ExecPlan exists in `execplans/active/`.
- `git diff --check` exits 0.

No app build is expected from this plan.

## Idempotence and Recovery

This plan only changes Markdown files. It is safe to revise repeatedly. If a
later agent disagrees with the chosen stack before implementation starts, update
the Decision Log with the reversal and why the previous criteria were
insufficient.
