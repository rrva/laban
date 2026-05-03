# Agent Operating Guide

This document holds the detailed working rules for agents. `AGENTS.md` is the
map; this file is the deeper guidance to open when the task needs engineering
style, workflow, or verification rules.

## Working Style

- Start by getting to a runnable demo. A small ugly demo that exercises real
  terminal behavior is better than a polished shell around fake internals.
- Decompose large work into slices that produce visible or testable progress.
  Avoid long backend-only stretches unless they have fast tests.
- Build only enough of a component to unblock the next demo, then move on.
  Return to harden it when a real workflow exposes the need.
- Become a user of the thing being built: run the app, open a shell, launch a
  fullscreen TUI, resize it, type non-US-layout characters, scroll output, and
  close sessions.
- Treat "how it feels" as part of the requirements. If an interaction is
  technically correct but awkward, distracting, or surprising, keep iterating.

## Architecture

- Keep terminal emulation, pty/process lifecycle, input encoding, rendering,
  and application window/tab state as separate responsibilities.
- Use libghostty as the MVP terminal core. Do not hand-roll VT parsing, color
  parsing, key protocol tables, or mouse protocol behavior.
- Favor a macOS-native app shell with a shared terminal/test core over a
  least-common-denominator GUI.
- Platform-specific code is expected when it improves macOS behavior.
  Isolate it behind a small interface instead of spreading conditional logic
  through unrelated code.
- Keep Swift/AppKit app behavior on one side of a narrow C ABI and C terminal
  core/libghostty ownership on the other.
- Use a unified frame-command renderer with retained renderer-owned resources,
  not a retained scene graph as source of truth.
- Do not create abstractions because they look tidy. Add an abstraction only
  when it preserves ownership boundaries, removes meaningful duplication, or
  lets multiple concrete implementations share a contract.

## Terminal Behavior

- Session identity must be stable across tab selection, view rebuilds, resize,
  and UI refresh.
- A view may display a session; the session owns the pty, child process, input
  encoders, render state, title state, scrollback, and exit state.
- Closing or replacing views must not restart or destroy sessions unless the
  action explicitly closes the session.
- Shell launch, resize, focus reporting, keyboard input, mouse input,
  scrollback, title updates, and exit state are core behavior, not polish.
- Native text input wins over raw modifier interpretation. Layout-specific
  characters must be delivered as text, not as accidental Alt/Super chords.

## Testing and Verification

- Learn how to build and run the project before making architectural changes.
- Prefer targeted tests while iterating. Run broader tests before considering a
  behavior complete.
- Add tests around failure paths, not only success paths. Resource cleanup after
  partial initialization failure is part of the feature.
- If a bug needs a reproduction to understand it, create the reproduction
  before changing the code.
- Do not claim performance improvements without measuring. Avoid pessimizing
  hot paths, but optimize from evidence.
- For UI work, verify with the running app. Screenshots are useful, but they do
  not replace interacting with the feature.

## Agent Workflow

- For vague or large requests, create or update a short plan first. Do not jump
  straight into code when the desired behavior is unclear.
- Keep planning and execution separate for non-trivial work. Once the plan is
  approved or obvious from context, implement in small slices.
- Give yourself a way to verify the work. If no verifier exists, add the
  smallest useful one or clearly report the gap.
- For user-visible terminal behavior, prefer debug-server end-to-end tests from
  `docs/process/dev-process.md` over manual-only verification.
- Treat autonomous verification as the authority. Code is shippable only when
  the relevant tests, debug-state checks, and screenshot artifacts support it.
- Near the end of non-trivial work, ask what might still be missing: cleanup
  paths, tests, native edge cases, accessibility, and stale-state bugs.
- If an agent repeatedly does the wrong thing, update this file, `AGENTS.md`,
  or a project tool so the mistake becomes harder to repeat.

## Changesets

- Keep changesets focused on one behavioral reason.
- Prefer several small commits over one broad mutable commit when work naturally
  separates into lifecycle, input, rendering, UI, docs, or tests.
- Commit messages are single-line and explain why the change exists, not what
  files changed.
- Do not mix speculative refactors with behavior fixes.
- Do not rewrite working code just to match a new style unless it unblocks a
  concrete requirement.

## Documentation

- Capture decisions in files, not only in chat.
- Update `docs/product/mvp.md` when the MVP boundary changes.
- Update `docs/product/spec.md` when product behavior changes.
- Update `docs/process/dev-process.md` when the debug/test harness contract
  changes.
- Keep docs operational and behavior-focused. Avoid aspirational architecture
  documents that cannot guide implementation.

## Quality Bar

A change is not done until the relevant behavior is observable through one of:

- a passing test
- a working local run
- a reproduction that now behaves correctly
- a documented reason why verification is blocked

The MVP is only credible when it can run real shells and terminal programs,
not when the UI resembles a terminal.
