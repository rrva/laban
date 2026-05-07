# Agent-Legible Observability

The app should expose enough logs, events, metrics, and traces for agents to
debug behavior without a human watching the UI.

This document defines the shape before an implementation language or telemetry
stack is selected.

## Signals

### Debug Events

Debug events are the first required observability signal. They are exposed by
`GET /debug/events` as defined in `docs/process/dev-process.md` and
`schemas/debug/events.schema.json`.

Events should cover:

- process startup and shutdown
- debug server readiness
- tab create/select/close
- session spawn/exit/failure
- pty read/write errors
- resize
- title changes
- focus reporting
- input actions
- mouse mode changes
- render failures
- screenshot captures
- fixture step transitions

### Structured Logs

Logs should be structured records, not only prose strings. A future
implementation should include at least:

- timestamp
- level
- target/module
- run ID
- event kind
- session ID when applicable
- tab ID when applicable
- message
- bounded error detail when applicable

Secrets and full environment values must be redacted.

### Metrics

Metrics are exposed by `GET /debug/metrics` as defined in
`docs/process/dev-process.md` and `schemas/debug/metrics.schema.json`.
They start as simple local counters and last-frame work summaries; richer
histograms can be added without changing the basic query path.

Useful metrics:

- startup duration
- frames rendered
- screenshot capture duration
- pty bytes read/written
- render cells/glyphs/images per frame
- E2E action duration
- fixture duration
- session spawn failures
- debug endpoint failures

### Traces

Traces are optional before implementation, but the architecture should not make
them hard to add. Critical spans:

- app startup
- session creation
- pty spawn
- frame render
- screenshot capture
- fixture step execution
- debug action handling

## Local Query Requirement

Agents must be able to query observability data from the local run. The first
implementation may satisfy this through debug endpoints and artifact JSON
files. A richer stack can come later.

Minimum acceptable local queries:

- recent events since sequence number
- runtime metrics counters and last-frame work summary
- final state snapshot
- final session snapshot
- final render snapshot
- bounded stdout/stderr logs

## Artifact Requirement

Every failed autonomous E2E run should preserve the latest logs/events/state
needed to explain the failure. See `docs/process/dev-process.md` and
`schemas/artifact-manifest.schema.json`.
