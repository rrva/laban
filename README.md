# Laban

Laban is a macOS terminal-application project designed for agent-driven
development. The first milestone is a minimal macOS terminal app with vertical
tabs, one independent shell session per tab, correct terminal behavior, and
autonomous headless end-to-end testing.

No implementation language, macOS UI framework, renderer, build system, or
terminal core has been selected yet. Cross-platform code is welcome when it
supports terminal core reuse, fixtures, schemas, CI, or headless rendering, but
it must not redefine the product as a non-macOS app.

Settled direction:

- macOS-native AppKit-first product shell.
- libghostty is mandatory for the MVP terminal core.
- first terminal core implementation is C behind a narrow C ABI.
- renderer uses unified frame commands with Metal and software/offscreen
  backends.
- JetBrains Mono and fixed Selenized Light are the MVP font/theme defaults.

## Repository Map

- `AGENTS.md` - small map for agents.
- `PLANS.md` - rules for self-contained ExecPlans.
- `docs/product/mvp.md` - current MVP boundary.
- `docs/product/spec.md` - long-term product behavior.
- `docs/process/dev-process.md` - autonomous debug and test harness contract.
- `docs/process/agent-operating-guide.md` - detailed agent working rules.
- `docs/process/worktree-isolation.md` - isolated run contract for concurrent agents.
- `docs/process/observability.md` - agent-legible logs, events, metrics, and traces.
- `docs/reference/prototype-implementation-notes.md` - non-binding prototype lessons.
- `docs/quality/quality.md` - quality dimensions and current gaps.
- `docs/quality/tech-debt.md` - known debt and cleanup candidates.
- `schemas/` - JSON contracts for debug endpoints, fixtures, and artifacts.
- `fixtures/` - deterministic fixture format and examples.
- `execplans/` - active and completed implementation plans.

## Current State

This repo is currently a planning and harness-contract repository. The next
step is to choose the implementation stack through an ExecPlan, then add a
runnable scaffold.

## Current Commands

The repository has one language-agnostic check command:

```sh
./scripts/check
```

It validates JSON files under `schemas/` and `fixtures/`, keeps `AGENTS.md`
map-sized, verifies active ExecPlans have required sections, and runs
`git diff --check`.

## Intended Implementation Commands

The implementation should eventually provide stable commands with these
meanings, regardless of the underlying toolchain:

```sh
# Start the app for local interactive development.
run

# Start the app with local debug endpoints enabled.
run-debug

# Start the app headlessly with an offscreen render target.
run-headless

# Run fast unit and core integration tests.
test

# Run autonomous debug-server end-to-end tests.
test-e2e

# Run formatting, linting, schemas, docs, and architecture checks.
check
```

The exact command runner is intentionally undecided until the implementation
language is chosen.

## Implementation Selection

Use `execplans/active/choose-implementation.md` to select the first stack. The
selection should optimize for:

- native macOS app behavior over cross-platform UI convenience
- AppKit-first shell over webview or generic cross-platform UI
- libghostty-backed terminal behavior through a C ABI
- real terminal behavior over UI mockups
- macOS text input correctness, including layout-specific Option characters
- a frame-command renderer that can be captured headlessly
- agent-legible tests and debug state
- narrow boundaries around terminal session ownership

## Done Means Observable

MVP behavior is not done until an agent can launch the app in headless mode,
drive it through debug actions, query internal state, capture screenshots, and
run the same flow in CI.
