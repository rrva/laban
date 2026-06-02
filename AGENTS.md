# Laban

This repository builds a macOS terminal application. **It is post-MVP**: the
MVP shipped 2026-05-17, so `docs/product/mvp.md` is now a regression contract
(shipped behavior not to break), not a build target — its Non-Goals are the
post-MVP roadmap, not a ban list. New direction lives in `docs/product/spec.md`.

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

- `docs/product/mvp.md` is the regression contract for shipped behavior; its
  non-goals and milestones are historical, superseded by `spec.md`.
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
| `docs/process/formal-specs.md` | You are changing a labpty state machine with a TLA+ spec in `specs/labpty/`, a CBMC proof or trace-conformance harness in `proofs/labpty/`, the MC/DC or mutation-adequacy gates (`coverage-labpty`, `check-{trace,cbmc}-mutants`), or a recent fix needs regression coverage. |
| `docs/process/rpg-graph-maintenance.md` | You are lifting or refreshing the `.rpg` semantic graph (`graph.json`), or wiring it into git worktrees. |

## Project Landmarks
Core maps: `README.md`, `PLANS.md`, `execplans/`, `docs/adr/`, `docs/quality/`.
Product and process truth: `docs/product/`, `docs/process/`, `docs/reference/`.
Debug contracts and data: `schemas/`, `fixtures/`.

## Runtime Artifacts (where to look — don't re-search)

Under `~/Library/Logs/Laban/`:

- **PTY capture** — `captures/appkit-<UTC>/streams/`: `pty-output.bin` (child→terminal), `pty-input.bin` (keys), `terminal-response.bin` (Laban's replies back to the child — **confirm a responder fired here**: CPR/DA/kitty/OSC 10-11). Also `manifest.json`, `frames/`, `snapshots/`. Headless: `/debug` `startCapture` (`docs/process/dev-process.md`).
- **Asciinema cast** — `casts/laban-<UTC>-lastNs.cast` (`LABAN_CAST_DIR` overrides).
- **Main-thread stall stacks** — `~/laban-watchdog/inproc-stall-*.txt`.

## Decision Index

- `docs/adr/0001-libghostty-vt-owns-vt-parsing.md` — libghostty-vt (not GhosttyKit) owns VT parsing; application owns the PTY.
- `docs/adr/0002-pty-launch-uses-openpty-constrained-fork.md` — PTY launch uses parent-side `openpty` and a constrained fork child, not `forkpty` or pure `posix_spawn`.
- `docs/adr/0003-terminal-find-uses-laban-side-scan.md` — terminal find scans Laban snapshots and extracted scrollback until libghostty-vt exposes C search bindings.
- `docs/adr/0004-advance-libghostty-vt-pin.md` — libghostty-vt pin advances to Ghostty `46d54ed6`; new upstream APIs stay behind Laban's existing C boundary unless product scope justifies them.
- `docs/adr/0005-laband-owns-live-session-pty-lifecycle.md` — `laband` owns live PTY/session lifecycle while preserving ADR 0002's `openpty`/fork/process-group invariants.
- `docs/adr/0006-three-tier-session-architecture.md` — three coexisting session tiers (in-process, `laband` multi-client serving, `labpty` upgrade-proof); PTY ownership and VT interpretation split into separate processes with `laband` mode-switched between byte-ring pass-through and authoritative snapshot publishing.
- `docs/adr/0007-labpty-phase1-protocol-freeze.md` — `labpty` Phase 1 freezes the app-direct frame, hello, byte-ring, reconnect, and overflow-degraded-state contracts.
- `docs/adr/0008-labpty-write-input-backpressure-contract.md` — `writeInput` is externally atomic under canonical backpressure: daemon preflight-admits against MAX_INPUT/MAX_CANON and returns `LABPTY_E_INPUT_BACKPRESSURE` rather than silently dropping bytes past the line-discipline limit.
- `docs/adr/0009-agent-session-detector-requires-direct-jsonl-evidence.md` — `AgentSessionDetector` attributes a Claude session id to a tab only from direct openVnodes evidence; cwd-newest fallbacks gate on a per-detector seen-jsonl set so sibling tabs in the same repo cannot inherit each other's sessions.
- `docs/adr/0010-labpty-connected-client-counter.md` — `labpty` tracks attached client connections per session (per-session `uint8` bitmask, `ATTACH`/`DETACH` ops, opener auto-attach, disconnect scrubbed in `client_release`) and surfaces `connected_clients` in the descriptor, replacing the faked `alive ? 1 : 0`; realises the per-reader attachment ADR 0007 reserved and gives orphan detection a real owner signal.
- `docs/adr/0011-libghostty-alt-screen-clear-uses-primary-pen.md` — local patch to vendored libghostty: `switchScreenMode` (mode 1049 enter) copies the primary cursor before erasing, so re-entering the alternate screen clears with the primary/theme pen instead of the previous app's stale SGR background (the btop→top black flash); carried as `patches/libghostty-vt-0001-*.patch` applied by `scripts/fetch-libghostty-vt`, to be upstreamed.
- `docs/adr/0012-laban-side-osc-host-responder.md` — Laban-side raw-stream scanner (`Sources/LabanTerminalCore/osc_host.c`) answers `OSC 10/11` default fg/bg colour queries (so Codex matches its theme) and surfaces `OSC 9` desktop notifications (native banner + tab badge; `HeadlessDebugRuntime` records `agent.notification` for parity). Extends the observe-only `osc133.c`/`tab_status.c` pattern to *answer* sequences libghostty parses but its VT-only API does not deliver — chosen over patching vendored libghostty.
- `docs/adr/0013-rpg-graph-committed-generated-artifact.md` — the `.rpg/graph.json` semantic graph is a committed, generated artifact owned canonically by `main`; lifted with a cheap small model (Haiku subagents, never Opus/paid credits) at quiescent checkpoints, and treated as generated in git (`merge=ours -diff linguist-generated`). How-to: `docs/process/rpg-graph-maintenance.md`.
- `docs/adr/0014-osc52-clipboard-bridge.md` — extends the ADR 0012 `osc_host.c` side channel to OSC 52: a program's `OSC 52 ; c ; <base64>` *write* lands on `NSPasteboard` (so a coding agent reached over SSH can copy to the host clipboard), and an `OSC 52 ; c ; ?` *read* is answered on the PTY only when opted in (`osc52ReadEnabled`, default off — write-on/read-opt-in, matching xterm `allowWindowOps`). Base64 + size-cap live in the pure `OSC52Clipboard` (LabanCore); the C core only buffers bytes (lazy 256 KiB `osc52_buf`) and frames the reply.
- `docs/adr/0015-osc7-working-directory-bridge.md` — extends the ADR 0012 `osc_host.c` side channel to OSC 7: a shell's `OSC 7 ; file://<host>/<path>` report is adopted as the session's authoritative cwd (preferred over `proc_pidinfo` in `laban_session_process_metadata`, so new-tab-cwd / tab path / restore pick it up via the existing metadata sync) — but only when the host is local (empty / `localhost` / local hostname), so a remote SSH shell's path is ignored. Observe-only on the wire; a `cwd.osc7` debug event gives headless parity.
- `docs/adr/0016-gpu-driven-cell-renderer.md` — keeps the damage-scoped classic renderer as the default while retaining a macOS-26-only, user-selectable GPU-driven cell renderer; records the frame-command contract boundary, payload/persistent-buffer architecture, and the M5 Metal 4 no-go.

Write a new ADR when a change establishes durable architectural policy, reverses a previously settled decision, or sets an adapter boundary. Number it sequentially in `docs/adr/`, follow the existing file's structure (Status, Context, Decision, Consequences, Applies To New Code), and add a one-line entry here with the path and summary.

## Worktree Setup

Git worktrees do not clone `.external/`; if missing, symlink it from the main repo:
`ln -s "$LABAN_MAIN_REPO/.external" .external`. It holds shared vendored libs.

`.rpg/graph.json` is a committed, generated artifact owned by `main`; in feature
worktrees run `git update-index --skip-worktree .rpg/graph.json` so local graph
re-syncs stay out of commits. See `docs/process/rpg-graph-maintenance.md`.

## Hard Rules

- The project must be autonomously verifiable. User-visible terminal behavior needs tests, debug-state checks, screenshot artifacts, or capture/replay artifacts.
- The debug/headless harness in `docs/process/dev-process.md` is product infrastructure, not optional polish.
- `HeadlessDebugRuntime` stays in feature parity with `MainWindowController.makeAndShow`. Wire new subsystems into both and expose HTTP endpoints. Move shared types from `LabanApp` down to `LabanCore` (no AppKit deps) so `LabanDebug` can reach them.
- Terminal session identity must survive tab selection, view rebuilds, resize, and UI refresh.
- Native text input wins over raw modifier interpretation.
- Keep changesets focused on one behavioral reason.
- Git commits are atomic. Commit messages are single-line reason statements: why the change exists, not what changed. Bad: `Update plans`. Good: `Agents need bounded execution shards`.
