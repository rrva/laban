# Build Debug Script Runner

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

After this change, an agent can run a small JSON scenario that starts Laban
headlessly, discovers the debug server, performs actions, waits for terminal
state, and writes screenshots or diagnostic snapshots. This turns the raw
HTTP debug controls into a repeatable exploratory-testing loop without
hand-written `curl` scripts.

The behavior is visible by running:

```sh
./scripts/run-debug-script fixtures/debug-script-basic.scenario.json
```

The command should print the selected debug URL, execute every scenario step,
write `.artifacts/runs/<run-id>/debug-script-report.json`, and exit 0.

## Progress

- [x] Read `PLANS.md`, `docs/process/dev-process.md`, current debug schemas,
  existing scripts, and the debug-control route surface.
- [x] Add a JSON schema and sample scenario for debug scripts.
- [x] Add `scripts/run-debug-script` to execute scenarios against a fresh or
  existing debug server.
- [x] Add E2E coverage that runs the sample scenario.
- [x] Update README, process docs, and schema index.
- [x] Run validation commands and record results.

  - `./scripts/run-debug-script fixtures/debug-script-basic.scenario.json` — all
    six steps passed (`discover`, `wait`, `action`, `wait`, `snapshot`,
    `screenshot`); report written to
    `.artifacts/runs/debug-script-basic-<run-id>/debug-script-report.json`.
  - `./scripts/test-e2e` — passed, including the new debug-script step.
  - `./scripts/check` — passed end to end after `scripts/smoke-runtime` was
    updated to set `LABAN_SKIP_CODESIGN=1`. Without that, the check gate
    previously hung in `codesign` when no interactive keychain was available.

## Decision Log

- Decision: Use JSON scenarios instead of inventing a custom tape language.
  Rationale: The repository already treats JSON schemas as the debug contract,
  and a JSON runner can reuse existing request bodies for `/debug/actions`,
  `/debug/wait`, `/debug/snapshot`, and `/debug/screenshot` without adding a
  parser or new product behavior.
  Date/Author: 2026-05-04 / Codex.

## Context and Orientation

`scripts/run-debug` starts `laban-agent` in headless debug-server mode.
`Sources/LabanDebug/DebugHTTPServer.swift` exposes local-only endpoints such
as `/debug`, `/debug/actions`, `/debug/wait`, `/debug/snapshot`, and
`/debug/screenshot`. `schemas/debug/discovery.schema.json` describes the live
capability index returned by `/debug`.

A debug script is a local JSON file with a `name`, optional launch settings
such as `fixture`, and a list of `steps`. Each step maps to one existing HTTP
endpoint or a small helper operation:

- `discover` calls `GET /debug` and checks expected endpoints/actions.
- `action` posts a body to `/debug/actions`.
- `wait` posts a condition to `/debug/wait`.
- `snapshot` posts to `/debug/snapshot` and records the manifest path.
- `screenshot` captures `GET /debug/screenshot` to a PNG file.
- `get` and `post` call explicit `/debug/...` paths for advanced cases.

## Plan of Work

1. Add `schemas/debug-script.schema.json` for the scenario format and update
   `schemas/README.md`.
2. Add `fixtures/debug-script-basic.scenario.json` that proves discovery,
   visible-text waits, fixture output injection, snapshots, and screenshots.
3. Add executable `scripts/run-debug-script`, implemented with Python 3
   standard-library modules only. It should:
   - build `laban-agent` unless `--no-build` is passed;
   - use `LABAN_AGENT_BIN` when supplied;
   - start a fresh headless debug server unless `--server URL` is supplied;
   - parse the readiness JSON line;
   - execute each scenario step in order;
   - write a JSON report under the run artifact directory;
   - terminate the server it started, even on failure.
4. Extend `scripts/test-e2e` to run the sample scenario through the new
   runner and assert that the report exists and says `ok: true`.
5. Update `README.md` and `docs/process/dev-process.md` with the new runner
   entry point.

## Validation and Acceptance

Run from the repository root:

```sh
./scripts/run-debug-script --no-build fixtures/debug-script-basic.scenario.json
./scripts/test-e2e
./scripts/check
```

Acceptance:

- The sample scenario exits 0 and writes a report with `ok: true`.
- The report includes a successful `discover` step and at least one snapshot
  manifest path.
- `scripts/test-e2e` exercises the runner against `laban-agent`.
- `scripts/check` passes after schema, docs, and script changes.

## Idempotence and Recovery

The runner writes generated files under `.artifacts/` and `.tmp/`, both of
which are ignored by git. Re-running a scenario creates a new run directory
unless the scenario explicitly chooses one. If a step fails, the runner still
writes a report and shuts down the server it started.
