# Choose The Initial Implementation Stack

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The repository has product requirements, autonomous test-harness contracts, and
prototype lessons. Several load-bearing stack decisions are already settled:
the product shell is AppKit-first, libghostty is mandatory, the first terminal
core is C behind a narrow C ABI, and the renderer uses unified frame commands
with Metal plus deterministic software/offscreen backends. After this plan is
complete, a future agent will know the remaining scaffold choices, why they
were chosen, what alternatives were rejected, and how to verify the decision
without relying on chat history.

The user-visible outcome is not a terminal app yet. The outcome is a durable
implementation decision and a scaffold plan that can be executed by a fresh
agent.

## Progress

- [ ] Read `AGENTS.md`, `docs/product/mvp.md`, `docs/product/spec.md`,
  `docs/process/dev-process.md`, and
  `docs/reference/prototype-implementation-notes.md`.
- [ ] Record the settled stack constraints from the interview.
- [ ] Define remaining decisions from the MVP and debug harness.
- [ ] Compare credible scaffold/build/test layouts within the settled stack.
- [ ] Choose the first runnable scaffold shape.
- [ ] Record rejected alternatives and why they lost.
- [ ] Update repository docs with the chosen command names and constraints.
- [ ] Add a follow-up ExecPlan for the first runnable scaffold.

## Context and Orientation

This repo is intentionally language-agnostic but not product-platform
agnostic. The MVP is a macOS terminal app with one window, vertical tabs, one
independent shell session per tab, correct terminal input/output behavior, and
autonomous headless E2E testing.

Cross-platform code is allowed when it helps terminal-core reuse, CI, fixtures,
schemas, or headless rendering. It must not replace the macOS product shell or
weaken native macOS input, window, menu, accessibility, or packaging behavior.

Settled constraints:

- Product shell: macOS-native, AppKit-first.
- Terminal core: libghostty mandatory.
- Core language: C first, exposed to Swift through a narrow C ABI.
- Swift owns windows, tabs, menus, app lifecycle, and app-level debug protocol.
- C core owns PTY lifecycle, libghostty terminal state, encoders, render
  snapshots, title, scrollback, resize, and exit state.
- C core does not own HTTP, JSON, artifacts, or debug-server concerns.
- Renderer: unified frame-command system, Metal preferred for the real macOS
  backend, deterministic software/offscreen backend required for tests.
- Renderer commands include support for textured quads/resource IDs even though
  Kitty graphics display is deferred.
- Headless mode supports fixture sessions and controlled real-shell smoke
  sessions; fixtures are the primary CI gate.
- UI: custom explicit vertical sidebar model/layout/hit testing; no native tab
  control owns tab state.
- MVP font/theme: JetBrains Mono, fixed Selenized Light.

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

The remaining scaffold choices must be judged against these criteria:

1. Terminal correctness: uses libghostty rather than hand-rolled VT parsing.
2. Native macOS text input: can correctly handle macOS text input and
   layout-specific Option characters.
3. Native macOS app behavior: supports expected macOS window, menu, focus,
   accessibility, and packaging paths.
4. Headless graphics: can render into an offscreen surface and produce PNG
   screenshots in CI.
5. Agent legibility: code, tests, schemas, and debug state are easy for agents
   to inspect and modify.
6. Small first scaffold: can produce a runnable demo quickly without hiding
   ownership boundaries.
7. Failure-path testability: can test partial initialization failure and cleanup.
8. Future production path: can grow toward multi-window, panes, persistence,
   accessibility, and packaging.

## Candidate Scaffold Shapes To Compare

The executing agent may add more, but must compare at least these:

### Swift package plus C target

Example shape: SwiftPM package with AppKit executable target, C terminal-core
target, test targets, and scripts wrapping build/run commands.

Why it is credible: simple for agents, easy Swift/C interop, fast scaffold.

Risk: `.app` bundling, resources, and Metal integration may need custom build
steps.

### Xcode project with Swift and C targets

Example shape: native Xcode project owns the app bundle, Swift/AppKit target,
C terminal-core target, resources, and test schemes.

Why it is credible: most native path for macOS app bundle, resources, menus,
Metal, and signing later.

Risk: project-file churn can be harder for agents than package manifests.

### Hybrid: SwiftPM libraries generated into thin Xcode app

Example shape: SwiftPM packages own core app modules and tests; a thin Xcode
app target owns bundling and native app integration.

Why it is credible: keeps most logic agent-friendly while preserving a native
macOS app bundle path.

Risk: two build entrypoints can drift unless scripts/checks keep them aligned.

## Plan of Work

1. Read the repository docs listed in Context and Orientation.
2. Turn the settled constraints and remaining criteria into a small comparison
   table.
3. For each candidate scaffold shape, explain how it satisfies or fails:
   - pty/session ownership
   - terminal core integration
   - macOS-native app behavior
   - macOS text input
   - headless rendering
   - debug server
   - fixture mode
   - CI viability
   - agent-editable project files
4. Choose the first scaffold shape.
5. Record the decision in the Decision Log with a clear rationale.
6. Update `README.md` intended commands if the choice makes command names more
   concrete.
7. Add a new follow-up ExecPlan under `execplans/active/` for scaffolding the
   first runnable app.

## Validation and Acceptance

This plan is complete when:

- `Progress` is fully checked.
- The Decision Log names one chosen scaffold shape and at least two rejected
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
