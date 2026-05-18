# Agent-Native Resume Adapters

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current working
tree, then implement safe Claude Code and Codex restore adapters end-to-end.

## Purpose / Big Picture

Laban currently has machinery for workspace restore and agent detection, but
the product direction is changing: restoring terminal output as if it were live
terminal state is misleading. A restored shell can display:

```sh
export FOO=hejsan
echo $FOO
hejsan
```

while the fresh replacement shell no longer has `FOO` defined. That makes the
terminal look more restored than it really is.

The valuable restore behavior is narrower and more truthful: if Laban detects
that a tab was running an agent CLI with its own native session persistence,
Laban should start a fresh shell in the prior working directory and run or
prefill the agent's native resume command. For Claude Code that command is
`claude --resume <session-id>`. For Codex that command is
`codex resume <session-id>`. The adapter must not replay the original argv
wholesale; flags that create new work or change safety posture, such as
Claude's `--worktree` / `-w` or Codex's
`--dangerously-bypass-approvals-and-sandbox`, must be dropped.

After this change, a user can quit while Claude or Codex is running, relaunch
Laban, and see a fresh shell resume the same agent session via that agent's
own persistence model. Ordinary shell tabs remain ordinary fresh shells; Laban
does not pretend shell process state survived.

The generic terminal transcript restore path is retired as a silent product
restore behavior. Historical output may still be useful as an explicitly
labeled diagnostic artifact, for example a "peek into the crash log" view, but
it must not be painted into a fresh terminal in a way that implies process
state, environment variables, shell functions, jobs, or application state were
restored.

## Progress

- [x] (2026-05-17) Captured the revised product direction in this ExecPlan:
  agent-native resume is the product behavior; terminal output-only restore is
  not treated as truthful process restore.
- [x] (2026-05-17) Verified local CLI command shapes with installed tools:
  `claude --help` exposes `-r, --resume [value]`; `codex resume --help`
  exposes `codex resume [SESSION_ID] [PROMPT]`.
- [x] (2026-05-17) Recorded that generic transcript restore is retired as
  silent restore behavior. It can return later only as an explicit diagnostic
  or crash-log inspection surface.
- [x] (2026-05-18) Implemented persisted agent launch context: observed argv,
  safe environment snapshot, cwd, agent kind, session id, and liveness.
- [x] (2026-05-18) Implemented explicit `AgentResumeAdapter` entries for
  Claude and Codex, including shell quoting and dangerous flag filtering.
- [x] (2026-05-18) Routed restore through adapters instead of the old
  `AgentSupport.resumeCommand` string closure. The compatibility helper now
  delegates through adapters.
- [x] (2026-05-18) Removed generic transcript replay from automatic restore
  in production and headless runtime wiring. Transcript rendering remains
  available only as diagnostic/future-pivot infrastructure.
- [x] (2026-05-18) Added tests for safe flag allowlists, dangerous flag drops,
  shell quoting, no generic launch-command resume, and planner behavior.
- [x] (2026-05-18) Added an end-to-end restore test proving a restored Claude
  tab receives native resume while dropping `--worktree`.
- [x] (2026-05-18) Ran focused tests, `./scripts/build-app`, and
  `./scripts/test`.
- [x] (2026-05-18) Fixed the short-lived Claude launcher gap: Claude logs
  modified after detector startup can now be discovered from the shell cwd
  even when no live Claude descendant remains, and app/headless persistence
  flushes force a final observation before writing `workspace.json`.
- [x] (2026-05-18) Tracked a real `claude --chrome` process launched under a
  headless zsh PTY. It remained a direct shell descendant, but the native
  Claude executable path reported a versioned basename (`2.1.143`) while
  argv[0] remained `claude`; the detector now falls back to argv[0] so live
  native Claude descendants are not ignored.

## Decision Log

- Decision: The restore command is canonical per agent, not the original
  process argv with `resume` appended.
  Rationale: Original argv can contain one-shot or side-effecting flags.
  Claude's `--worktree` creates a new git worktree. Replaying it on every app
  restore would create duplicate worktrees. The adapter should start from the
  native resume command and only add allowlisted non-destructive options.
  Date/Author: 2026-05-17 / Codex.

- Decision: Store a small, redacted launch-context snapshot with the detected
  agent, but default to using only cwd and session id.
  Rationale: The user explicitly wants environment variables, cwd, and program
  args persisted, but environment values can contain secrets. Persisting a
  redacted allowlist gives future adapters data without writing tokens to disk.
  Date/Author: 2026-05-17 / Codex.

- Decision: Claude and Codex use separate adapter implementations even though
  both produce strings.
  Rationale: Their resume syntax and dangerous flags differ. Keeping a
  per-agent adapter prevents accidental policy bleed, for example treating
  Claude's `--resume` as if it were Codex's `resume` subcommand.
  Date/Author: 2026-05-17 / Codex.

- Decision: Generic transcript restore is not part of automatic workspace
  restore.
  Rationale: Output-only restore can make false claims about live process
  state. A shell prompt displaying old `export FOO=hejsan` output does not mean
  the relaunched shell has `FOO` set. Transcript data may be retained for an
  explicit diagnostic or crash-log peek, but not silently replayed into a new
  terminal session.
  Date/Author: 2026-05-17 / Codex.

- Decision: Claude logs discovered from shell cwd without a live Claude
  descendant are persisted as inactive agents.
  Rationale: A short-lived launcher or re-parented Claude integration can still
  create a valid native Claude session, but Laban did not observe an agent
  process alive under the tab at quit time. Persisting `wasRunningAtQuit=false`
  keeps restore truthful by pre-filling native resume instead of silently
  starting a duplicate session.
  Date/Author: 2026-05-18 / Codex.

- Decision: Agent process identity may be recognized from argv[0] when the
  executable-path basename is not the user-facing CLI name.
  Rationale: Claude's native build can exec a versioned binary under
  `~/.local/share/claude/versions/`, so libproc reports the executable basename
  as `2.1.143` while the process argv remains `claude ...`. Matching only the
  executable basename causes Laban to ignore a real live Claude descendant.
  Date/Author: 2026-05-18 / Codex.

## Context and Orientation

The relevant code lives in `Sources/LabanCore/Persistence/`.

`WorkspaceState.swift` defines the JSON state written to disk. It contains
`TabState`, which already stores each tab's working directory (`cwd`) and an
optional `AgentInfo`. `AgentInfo` currently stores only:

- `name`: `.claude` or `.codex`
- `sessionId`: the UUID extracted from the agent's JSONL session log
- `jsonlPath`: the path to that JSONL file
- `wasRunningAtQuit`: whether the agent process was still alive when Laban
  last observed it

`AgentSupport.swift` is the current per-agent capability table. It has
`AgentSupport.claude()` and `AgentSupport.codex()` entries with binary names,
JSONL path extractors, and a `resumeCommand` closure. The current closure is
too weak for this work because it cannot inspect or filter argv/env.

`AgentSessionDetector.swift` polls the child process tree below a terminal's
shell process. It finds `claude` or `codex` by executable basename, scans the
process's open `.jsonl` file descriptors, and extracts the session id via
`AgentSupport.extractSessionId`. Its `ProcessIntrospector` protocol currently
provides only:

```swift
func children(of parent: pid_t) -> [(pid: pid_t, basename: String)]
func openVnodePaths(of pid: pid_t) -> [String]
```

It must grow enough process metadata to capture argv and a safe environment
snapshot for the detected agent process.

`RestoreLaunchPlanner.swift` currently decides whether to execute, prefill, or
do nothing. It calls `support.resumeCommand(agent.sessionId)`. This should
become adapter-driven.

`MainWindowController.swift` applies restore launch instructions after tabs
are recreated. It writes `command + "\n"` to execute immediately, or `command`
without a newline to prefill. That wiring can stay; the command builder behind
the planner changes.

Any existing path that injects persisted terminal transcript bytes or rendered
screen content during ordinary workspace restore must be removed from the
silent restore flow. If the transcript storage remains, treat it as diagnostic
data with explicit UI or debug-endpoint labeling, not as terminal state.

Tests exist in:

- `Tests/LabanCoreTests/AgentSupportTests.swift`
- `Tests/LabanCoreTests/AgentSessionDetectorTests.swift`
- `Tests/LabanCoreTests/RestorePlannerTests.swift`
- `Tests/LabanCoreTests/PersistenceRoundTripTests.swift`

## Source Findings

The local installed Claude CLI reports:

```text
Usage: claude [options] [command] [prompt]
-r, --resume [value]  Resume a conversation by session ID, or open interactive picker with optional search term
-w, --worktree [name] Create a new git worktree for this session
```

The local installed Codex CLI reports:

```text
Usage: codex resume [OPTIONS] [SESSION_ID] [PROMPT]
[SESSION_ID]  Conversation/session id (UUID) or thread name
--last        Continue the most recent session without showing the picker
```

Therefore the explicit native resume command shapes are:

```sh
claude --resume <session-id>
codex resume <session-id>
```

Do not use `claude resume <session-id>`; it is not the installed Claude Code
syntax in this environment.

Claude Code JSONL logs can contain top-level metadata events such as
`permissionMode`, plus assistant records with `advisorModel`, `cwd`, and
`sessionId`. Laban uses those fields only to construct Claude-native resume
metadata when no live Claude descendant is present; it does not replay terminal
transcript output or infer generic shell commands.

In this environment, a real `claude --chrome` launched from a zsh PTY stayed in
the descendant tree:

```text
zsh -> claude --chrome --chrome --dangerously-skip-permissions
```

The process was still easy to miss because libproc's executable path resolved
to a native versioned binary under `~/.local/share/claude/versions/2.1.143`.
Detector code therefore uses the executable basename first and argv[0] second.

## Plan of Work

### 1. Extend persisted agent metadata

In `Sources/LabanCore/Persistence/WorkspaceState.swift`, add optional fields to
`AgentInfo` so existing `workspace.json` files still decode:

```swift
public var argv: [String]?
public var env: [String: String]?
public var cwd: String?
```

Keep the current initializer source-compatible by adding parameters with
default `nil` values. `cwd` duplicates `TabState.cwd` intentionally: it records
the agent process's observed working directory at detection time, while
`TabState.cwd` is the shell/tab working directory. The restore planner should
prefer `agent.cwd`, then fall back to `tab.cwd`.

Environment persistence must be conservative. Add a helper that stores only
known-safe names and redacts all values that look secret. Suggested initial
allowlist:

```text
TERM
COLORTERM
LANG
LC_ALL
LC_CTYPE
CLAUDE_CONFIG_DIR
CODEX_HOME
```

Never persist values for names containing these case-insensitive fragments:

```text
TOKEN
SECRET
PASSWORD
PASS
KEY
AUTH
COOKIE
AWS_
GITHUB_
OPENAI_
ANTHROPIC_
```

If a name is both allowlisted and secret-looking, drop it. Do not write a
redacted placeholder for secrets; absence is clearer and safer.

### 2. Capture argv/env/cwd from detected agent processes

In `Sources/LabanCore/Persistence/AgentSessionDetector.swift`, extend
`ProcessIntrospector` with process metadata methods:

```swift
func arguments(of pid: pid_t) -> [String]
func environment(of pid: pid_t) -> [String: String]
func currentWorkingDirectory(of pid: pid_t) -> String?
```

Update `LibprocIntrospector` to implement them.

For argv/env, use the macOS `sysctl` `KERN_PROCARGS2` buffer for same-user
processes. The buffer begins with an argument count, followed by the executable
path, null padding, null-terminated argv strings, then null-terminated
environment strings. If parsing fails, return an empty array/dictionary; agent
restore must still work from session id and cwd alone.

For cwd, use `proc_pidinfo` with process vnode path information if available.
If reliable cwd extraction is not practical in this codebase, return `nil` and
document the discovery in this ExecPlan under `Surprises & Discoveries`; the
planner will fall back to `TabState.cwd`.

Update `AgentSessionDetector.findAgent(in:)` so when it returns `AgentInfo`, it
includes:

- `argv`: the observed argv from `introspector.arguments(of:)`
- `env`: the sanitized env dictionary
- `cwd`: the observed cwd or nil

Update test mock types in `AgentSessionDetectorTests` and
`AgentObserverHostTests` to satisfy the new protocol methods.

### 3. Replace resume closure with adapters

In `Sources/LabanCore/Persistence/AgentSupport.swift`, introduce a concrete
adapter type. Keep it small and testable:

```swift
public protocol AgentResumeAdapter {
  var name: AgentName { get }
  func resumeCommand(sessionId: String, context: AgentLaunchContext) -> String
}

public struct AgentLaunchContext: Equatable {
  public var cwd: String
  public var argv: [String]
  public var env: [String: String]
}
```

The adapter returns a shell command string because
`MainWindowController.applyRestoreLaunchPlans` writes to an interactive shell.
Add a single shell-quoting helper that wraps arguments safely:

```swift
ShellCommand.quote("a b") == "'a b'"
ShellCommand.quote("a'b") == "'a'\\''b'"
```

Build commands from arrays and quote every argument. Do not concatenate raw
session ids, paths, or values directly into shell text.

Update `AgentSupport` to carry an adapter instead of a raw
`resumeCommand: (String) -> String` closure, or add an adapter alongside the
old closure and then remove the closure once call sites are updated. The final
state should have one command-building path.

### 4. Claude adapter policy

Create `ClaudeResumeAdapter`.

Base command:

```swift
["claude", "--resume", sessionId]
```

Allowed argv options from the original Claude process:

- `--model <model>`
- `--effort <low|medium|high|xhigh|max>`
- `--add-dir <dir...>` repeated or multi-value. Preserve only path values that
  are non-empty.
- `--permission-mode <mode>` only when mode is `default`, `acceptEdits`,
  `auto`, `dontAsk`, or `plan`. Drop `bypassPermissions`.

Explicitly drop at least:

- `-w`, `--worktree`, and `--worktree=<name>`
- `--fork-session`
- `-c`, `--continue`
- `--session-id`
- `-r`, `--resume` from original argv; the adapter supplies the new resume id
- `-p`, `--print`
- `--dangerously-skip-permissions`
- `--allow-dangerously-skip-permissions`
- `--permission-mode bypassPermissions`
- `--tmux`
- positional prompt text

If parsing encounters an unknown option, skip that option and its value only
when the option is known to take a value from the help output; otherwise skip
just the option. Do not fail restore because of an unknown flag. Add tests for
unknown options so the behavior is deterministic.

### 5. Codex adapter policy

Create `CodexResumeAdapter`.

Base command:

```swift
["codex", "resume", sessionId]
```

Always include cwd using Codex's native `-C` option:

```swift
["-C", context.cwd]
```

Allowed argv options from the original Codex process:

- `-m`, `--model <model>`
- `-p`, `--profile <profile>`
- `-s`, `--sandbox <read-only|workspace-write>`; drop `danger-full-access`
- `-a`, `--ask-for-approval <untrusted|on-request>`; drop `never` and
  deprecated `on-failure`
- `--add-dir <dir>` repeated
- `--search`
- `--no-alt-screen`

Explicitly drop at least:

- `resume`, `fork`, `exec`, `review`, or any original subcommand token; the
  adapter supplies `resume`
- `--last`
- `--all`
- `--include-non-interactive`
- `--dangerously-bypass-approvals-and-sandbox`
- `--remote`
- `--remote-auth-token-env`
- `--oss`
- `--local-provider`
- positional prompt text

Do not carry over an original prompt argument. A restore resumes the session;
it should not also send a fresh prompt unless the user types one.

### 6. Route restore through adapters

In `Sources/LabanCore/Persistence/RestoreLaunchPlanner.swift`, build an
`AgentLaunchContext` from:

- `cwd`: `tab.agent?.cwd ?? tab.cwd`
- `argv`: `tab.agent?.argv ?? []`
- `env`: `tab.agent?.env ?? [:]`

Ask the registry entry's adapter for the command. Preserve the current
execute-vs-prefill rule:

- `agent.wasRunningAtQuit == true` -> `.executeNow(command:)`
- `agent.wasRunningAtQuit == false` -> `.prefillPrompt(command:)`
- no agent or unknown agent -> `.noPrefill`

Do not use `tab.processStatus` to decide agent liveness.

### 7. Retire silent transcript replay

Find the code path that uses persisted raw transcripts or rendered terminal
snapshots during workspace restore. Remove it from automatic tab recreation.
After relaunch:

- agent tabs may run or prefill a native agent resume command;
- non-agent shell tabs must start as fresh shells in the restored cwd;
- no old transcript bytes, screen cells, prompts, command echoes, or sentinel
  characters are injected into the live terminal.

Keep transcript persistence only if another explicit feature still consumes it,
such as debug capture, crash investigation, or future user-initiated "peek"
UI. Any such retained path must be named and documented as historical output,
not restore.

### 8. Tests

Add or update tests before implementation where practical.

In `Tests/LabanCoreTests/AgentSupportTests.swift` or a new
`AgentResumeAdapterTests.swift`, cover:

- Claude base command is `claude --resume <uuid>`.
- Claude preserves `--model sonnet`, `--effort high`, and safe
  `--permission-mode plan`.
- Claude drops `--worktree`, `-w`, `--fork-session`,
  `--dangerously-skip-permissions`, and `--permission-mode
  bypassPermissions`.
- Claude quotes session ids and path args defensively. UUIDs normally need no
  quoting, but tests should prove the command builder is not raw string
  concatenation.
- Codex base command is `codex resume <uuid> -C <cwd>` or
  `codex resume <uuid> --cd <cwd>`; choose one and use it consistently.
- Codex preserves `--model`, `--profile`, `--sandbox workspace-write`,
  `--ask-for-approval on-request`, `--search`, and `--no-alt-screen`.
- Codex drops `--dangerously-bypass-approvals-and-sandbox`,
  `--sandbox danger-full-access`, `--ask-for-approval never`, `--last`, and
  original prompt text.

In `Tests/LabanCoreTests/RestorePlannerTests.swift`, add cases where `AgentInfo`
has argv/env/cwd and verify the planner returns the adapter-filtered command.

In `Tests/LabanCoreTests/PersistenceRoundTripTests.swift`, extend
`testWorkspaceStateRoundTripPreservesAgentInfo` to assert optional argv/env/cwd
round-trip.

In `Tests/LabanCoreTests/AgentSessionDetectorTests.swift`, update mock
introspection so a detected agent carries argv/env/cwd into `AgentInfo`.

Add or update restore tests so multiple quit/relaunch cycles of a plain zsh tab
with initial input `echo hej` do not accumulate old prompts, command echoes,
NUL-looking sentinels, percent signs, or any other transcript artifacts.
Assert that the live restored terminal comes from the fresh shell, not from
persisted transcript replay.

## Concrete Steps

Run commands from the repository root:

```sh
cd /Users/rrj/wrk/laban/.claude/worktrees/jaunty-brewing-tower
```

1. Confirm CLI command shapes if the installed CLIs may have changed:

```sh
rtk claude --help
rtk codex resume --help
```

Expected relevant output:

```text
claude: -r, --resume [value]
codex: Usage: codex resume [OPTIONS] [SESSION_ID] [PROMPT]
```

2. Add optional fields to `AgentInfo`, then run:

```sh
rtk swift test --filter PersistenceRoundTripTests/testWorkspaceStateRoundTripPreservesAgentInfo
```

3. Add adapter types and shell quoting helper, then run:

```sh
rtk swift test --filter AgentSupportTests
rtk swift test --filter AgentResumeAdapterTests
```

Use whichever test target name exists after adding the adapter tests.

4. Update `RestoreLaunchPlanner` to call adapters, then run:

```sh
rtk swift test --filter RestorePlannerTests
```

5. Update detector process metadata capture and mocks, then run:

```sh
rtk swift test --filter AgentSessionDetectorTests
rtk swift test --filter AgentObserverHostTests
```

6. Run the focused persistence and restore set:

```sh
rtk swift test --filter 'AgentSupportTests|AgentResumeAdapterTests|AgentSessionDetectorTests|AgentObserverHostTests|RestorePlannerTests|PersistenceRoundTripTests'
```

7. Run repository verification:

```sh
rtk git diff --check
rtk ./scripts/build-app
rtk ./scripts/test
```

## Validation and Acceptance

The change is acceptable when all of the following are true:

- `RestoreLaunchPlanner` returns `claude --resume <id>` for a Claude agent
  with no argv, and never returns `claude resume <id>`.
- If a Claude `AgentInfo.argv` contains `["claude", "--worktree", "foo",
  "--model", "sonnet"]`, the generated command contains `--model sonnet` and
  does not contain `--worktree` or `foo`.
- If a Codex `AgentInfo.argv` contains `["codex",
  "--dangerously-bypass-approvals-and-sandbox", "--model", "gpt-5.2"]`, the
  generated command contains `codex resume <id>` and `--model gpt-5.2`, and
  does not contain `dangerously-bypass`.
- If Codex cwd is `/Users/rrj/wrk/laban`, the generated command includes
  Codex's cwd flag (`-C '/Users/rrj/wrk/laban'` if using `-C`).
- Agent environment persistence does not write secret-looking names or values
  into `workspace.json`.
- Existing workspaces without `argv`, `env`, or agent `cwd` still decode.
- Plain shell tabs do not receive historical transcript output during
  automatic workspace restore.
- Repeated relaunch cycles after an initial `echo hej` do not mutate terminal
  contents by adding extra leading characters, old prompts, `%` markers, NUL
  sentinels, or duplicated output.
- Full `rtk ./scripts/test` exits 0.

Manual acceptance:

1. Start Laban in a real zsh shell.
2. Start Claude Code in one tab with a safe flag and a dangerous worktree flag:

   ```sh
   claude --model sonnet --worktree throwaway
   ```

3. Start Codex in another tab with a safe flag and a dangerous bypass flag:

   ```sh
   codex --model gpt-5.2 --dangerously-bypass-approvals-and-sandbox
   ```

4. Wait for Laban to detect agent sessions, then quit and relaunch.
5. Observe that the Claude tab resumes with `claude --resume <id>` and any
   allowlisted safe flags, but does not create another worktree. Observe that
   the Codex tab resumes with `codex resume <id>` and safe flags only, with no
   dangerous bypass flag.

If the exact manual commands are too invasive because they start real external
agent sessions, use unit tests as the required acceptance and record that
manual validation was skipped.

Manual validation status: skipped on 2026-05-18. The same behavior is covered
by unit tests and `WorkspaceRestoreEndToEndTests` using mock argv/env/cwd data
so no real Claude/Codex sessions, worktrees, or dangerous bypass modes are
created during verification.

## Idempotence and Recovery

The schema change is additive: new `AgentInfo` fields must be optional, so
older `workspace.json` files decode and new files can be read by current code.
If process argv/env introspection fails, the adapter must still generate a base
resume command from `sessionId` and cwd fallback. That makes the feature safe
to retry on systems where macOS denies process argument inspection.

Do not delete user worktrees or session logs during testing. Tests must use
mock argv/env/cwd data. Manual tests that involve `--worktree` should run in a
throwaway repository or be replaced with adapter unit tests.

## Review Gate

A fresh reviewer must verify the following before this ExecPlan is considered
complete:

- [x] `rtk rg -n "claude resume" Sources Tests` returns no matches except in
  negative test names or explanatory comments that explicitly say the form is
  wrong.
- [x] `rtk rg -n "worktree|dangerously-bypass|bypassPermissions" Tests/LabanCoreTests`
  shows tests asserting those flags are dropped.
- [x] `rtk swift test --filter 'AgentSupportTests|AgentResumeAdapterTests|RestorePlannerTests'`
  exits 0.
- [x] Restore tests prove generic transcript replay is absent from automatic
  workspace restore for non-agent shell tabs.
- [x] `rtk ./scripts/test` exits 0.

Review status: IMPLEMENTED AND SELF-VERIFIED on 2026-05-18.
