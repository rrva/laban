# Schemas

Schemas define implementation-neutral contracts that agents can rely on before
any programming language is chosen.

## Debug Endpoint Schemas

- `debug/state.schema.json` - app/window/tab state snapshot.
- `debug/session.schema.json` - one terminal session state.
- `debug/sessions.schema.json` - session collection response.
- `debug/render.schema.json` - renderer and surface diagnostics.
- `debug/frame-commands.schema.json` - bounded frame-command dump.
- `debug/render-trace-request.schema.json` - frame trace query request.
- `debug/render-trace.schema.json` - frame trace response.
- `debug/pixel-probe.schema.json` - pixel/region probe request.
- `debug/pixel-probe-result.schema.json` - pixel/region probe response.
- `debug/atlas.schema.json` - glyph atlas and font diagnostics.
- `debug/selection.schema.json` - terminal selection state.
- `debug/clipboard.schema.json` - copy/paste debug summary.
- `debug/input-log.schema.json` - normalized input routing log.
- `debug/terminal-log.schema.json` - bounded terminal byte-flow log.
- `debug/timing.schema.json` - frame and endpoint timing diagnostics.
- `debug/errors.schema.json` - structured warning/error log.
- `debug/events.schema.json` - bounded debug event response.
- `debug/action.schema.json` - debug control action request.
- `debug/action-result.schema.json` - debug control action response.
- `debug/screenshot-result.schema.json` - screenshot artifact metadata.
- `debug/wait.schema.json` - wait condition request.
- `debug/wait-result.schema.json` - wait condition response.
- `debug/fixture-control.schema.json` - fixture control request.
- `debug/snapshot-result.schema.json` - artifact snapshot response.

## Fixture And Artifact Schemas

- `fixture.schema.json` - deterministic terminal fixture definition.
- `artifact-manifest.schema.json` - failed-run artifact manifest.
- `capture/manifest.schema.json` - durable capture artifact manifest.
- `capture/event.schema.json` - ordered capture timeline event envelope.
- `capture/replay-report.schema.json` - deterministic replay result report.

These schemas are contracts. Implementations may add fields, but must preserve
the required fields and meanings unless the schema version changes.
