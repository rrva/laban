# Worktree Isolation

Agents must be able to run independent app instances from separate git
worktrees without colliding on ports, sockets, temp files, logs, screenshots,
or fixture artifacts.

This is a language-agnostic contract. The eventual command runner can implement
it with shell scripts, package-manager scripts, a task runner, or test tooling.

## Required Inputs

Every runnable mode should accept:

- an artifact directory
- an optional debug-server address with port `0` meaning "choose a free port"
- a temp directory or run ID
- a deterministic mode flag for tests

Example shape:

```sh
run-headless --debug-server=127.0.0.1:0 --artifacts=.artifacts/runs/<run-id> --temp-dir=.tmp/<run-id>
```

## Required Outputs

When the app starts with a debug server, stdout must include exactly one
machine-readable readiness line:

```json
{"debugServer":"http://127.0.0.1:49321","pid":12345,"runId":"abc123"}
```

Agents should parse this line instead of guessing ports.

## Directory Layout

Each isolated run should write only under its requested artifact and temp
directories.

Recommended layout:

```text
.artifacts/
  runs/
    <run-id>/
      manifest.json
      stdout.log
      stderr.log
      debug-state.json
      debug-sessions.json
      debug-render.json
      debug-events.json
      screenshots/
.tmp/
  <run-id>/
```

Generated artifacts should not be committed unless a specific fixture or
golden reference intentionally belongs in the repo.

## Isolation Rules

- Bind debug servers to loopback only.
- Prefer port `0` and report the selected port through the readiness line.
- Do not use global fixed paths for sockets, logs, pids, screenshots, or temp
  files.
- Do not assume only one app instance exists.
- Include the run ID in event logs and artifact manifests.
- Clean temp directories on success; preserve artifacts on failure.

## Agent Workflow

Before running an app instance, an agent should create a unique run ID. If the
implementation does not yet provide a helper, use a timestamp plus short random
suffix.

The agent should stop the launched process before finishing. If a test fails,
it should preserve the artifact directory and include the relevant paths in its
report.
