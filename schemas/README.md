# Schemas

Schemas define implementation-neutral contracts that agents can rely on before
any programming language is chosen.

## Debug Endpoint Schemas

- `debug/state.schema.json` - app/window/tab state snapshot.
- `debug/session.schema.json` - one terminal session state.
- `debug/sessions.schema.json` - session collection response.
- `debug/render.schema.json` - renderer and surface diagnostics.
- `debug/events.schema.json` - bounded debug event response.
- `debug/action.schema.json` - debug control action request.
- `debug/action-result.schema.json` - debug control action response.
- `debug/screenshot-result.schema.json` - screenshot artifact metadata.

## Fixture And Artifact Schemas

- `fixture.schema.json` - deterministic terminal fixture definition.
- `artifact-manifest.schema.json` - failed-run artifact manifest.

These schemas are contracts. Implementations may add fields, but must preserve
the required fields and meanings unless the schema version changes.
