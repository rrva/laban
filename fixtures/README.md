# Fixtures

Fixtures define deterministic terminal scenarios for autonomous tests. They are
implementation-neutral and validated by `schemas/fixture.schema.json`.

Use fixtures when a test should not depend on the user's shell, dotfiles,
network, prompt theme, local font settings, or wall-clock timing.

## Fixture Shape

Each fixture declares:

- a name and schema version
- an initial terminal size
- ordered steps that write bytes, wait frames, set title, or exit
- expected visible/state outcomes

Fixture steps model the child side of a terminal session. They are not UI
actions. UI actions belong in debug-server E2E tests via `/debug/actions`.

## Examples

- `colored-boxes.fixture.json` - color and box-drawing smoke fixture.
- `find-viewport.json` - repeated literal text for terminal find
  highlight and frame-command checks.
