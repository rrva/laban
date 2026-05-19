# Fix Claude Resume Wrapper Argument Growth

This ExecPlan is a living document maintained in accordance with `PLANS.md`.

## Purpose / Big Picture

When a user launches Claude Code through a shell wrapper such as `claude-y`, Laban should restore that running Claude session on startup without growing the command line on every restart. The observable result is that repeated quit/relaunch cycles keep the saved Claude argv stable instead of adding one more `--chrome` each time.

## Progress

- [x] Reproduced the bug with a real Claude Code process launched through the user's `claude-y` zsh function.
- [x] Update the Claude resume command so it bypasses shell functions when typed into zsh.
- [x] Make preserved Claude flags idempotent so already-duplicated persisted argv is normalized.
- [x] Add targeted tests around wrapper-launched Claude argv.
- [x] Identified the printed-but-not-started path: it is `.prefillPrompt`, which writes no newline when `agent.wasRunningAtQuit == false`.
- [x] Harden final quit sampling so one transient detector miss cannot demote a known-live agent into the no-newline prefill path.
- [x] Re-run unit tests and the real Claude restart loop.

## Surprises & Discoveries

- Observation: The local `claude-y` function expands to `command claude --chrome --dangerously-skip-permissions "$@"`, and the local `claude` function expands to `command claude --chrome "$@"`.
  Evidence: A real headless persistence loop launched `claude-y`, then ran four in-process relaunches. Saved argv grew from `["claude","--chrome","--dangerously-skip-permissions"]` to `["claude","--chrome","--resume",id,"--chrome","--chrome","--chrome","--dangerously-skip-permissions"]`.
- Observation: A restored tab that shows the resume command but does not start Claude is using `.prefillPrompt`, which intentionally omits the newline.
  Evidence: `RestoreLaunchPlanner.instruction(for:)` returns `.prefillPrompt` whenever persisted `agent.wasRunningAtQuit` is false, and both AppKit and debug restore handlers write that command without appending `\n`.

## Context and Orientation

Claude autoresume is implemented in `Sources/LabanCore/Persistence/AgentSupport.swift`. `ClaudeResumeAdapter.resumeCommand(sessionId:context:)` turns persisted `AgentInfo.argv` into a shell command. `MainWindowController.applyRestoreLaunchPlans(...)` and `HeadlessDebugRuntime.applyRestoreLaunchPlans(...)` write that command into the restored tab's PTY. Because the command is typed into the user's shell, zsh functions can intercept the leading `claude` token before the real executable runs.

`AgentSessionDetector` stores the live Claude argv in `WorkspaceState.windows[].tabs[].agent.argv`. That means any duplicated argv produced by one restore can become input to the next restore.

## Plan of Work

Change only the resume-command generation layer. For Claude, render the command as `command claude --resume <session-id> ...` so shells that support the POSIX-style `command` builtin bypass a user-defined `claude()` function. Keep preserving safe flags such as `--chrome` and `--dangerously-skip-permissions`, but preserve exact no-value flags only once per generated command and treat singleton value options such as `--model`, `--effort`, and `--permission-mode` as last-value-wins. This fixes future restore cycles and lets previously duplicated wrapper argv collapse on the next generated resume command.

Add tests in `Tests/LabanCoreTests/AgentSupportTests.swift` and `Tests/LabanCoreTests/RestorePlannerTests.swift` that assert:

- Claude resume commands start with `command claude --resume`.
- Duplicated `--chrome` entries in observed argv are normalized to one preserved flag.
- Restore planning for a wrapper-launched Claude session generates a command that bypasses the shell function and preserves `--dangerously-skip-permissions`.

## Validation and Acceptance

Run from `/Users/rrj/wrk/laban`:

```sh
rtk swift test --filter AgentSupportTests
rtk swift test --filter RestorePlannerTests
```

Then rerun the real-process exploratory loop:

1. Start `laban-agent` headless with `--persistence-dir`.
2. In the real PTY, `exec zsh -i` and launch `claude-y`.
3. Flush persistence after detector sees Claude.
4. Call `/debug/persistence/relaunch` repeatedly.
5. Confirm saved argv stays stable after the first fixed relaunch and does not gain additional `--chrome` entries.

Acceptance: all targeted tests pass, and the real-process loop no longer shows argv growth across restart cycles.

Validation performed:

```sh
rtk swift test --filter 'AgentSupportTests|RestorePlannerTests|AgentSessionDetectorTests|LabanDebugSmokeTests.testPersistenceFlushRecordsRecentClaudeLogWithoutLiveChild'
# passed: 42 tests

rtk swift format lint --strict Sources/LabanCore/Persistence/AgentSupport.swift Sources/LabanCore/Persistence/AgentSessionDetector.swift Sources/LabanCore/Persistence/AgentObserverHost.swift Tests/LabanCoreTests/AgentSupportTests.swift Tests/LabanCoreTests/RestorePlannerTests.swift Tests/LabanCoreTests/AgentSessionDetectorTests.swift Tests/LabanDebugTests/LabanDebugSmokeTests.swift
# passed
```

Real-process loop performed against `claude-y`:

```text
initial argv: ["claude","--chrome","--dangerously-skip-permissions"]
cycle 1 argv: ["claude","--resume",id,"--chrome","--dangerously-skip-permissions"]
cycle 2 argv: ["claude","--resume",id,"--chrome","--dangerously-skip-permissions"]
cycle 3 argv: ["claude","--resume",id,"--chrome","--dangerously-skip-permissions"]
cycle 4 argv: ["claude","--resume",id,"--chrome","--dangerously-skip-permissions"]
```

`rtk ./scripts/check` was attempted. It passed the early repository checks, then failed in `scripts/lint` on repository-wide Swift formatting errors, including files outside this changeset. The touched Swift files pass strict formatting lint individually.

## Idempotence and Recovery

The code change is deterministic and local to command rendering. If the exploratory loop leaves a debug process running, terminate the `laban-agent` process; its PTY teardown closes the launched Claude process. Temporary artifacts live under `.artifacts/exploratory/`.
