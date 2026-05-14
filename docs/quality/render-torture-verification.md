# Render Torture Verification Proposal

This note proposes an autonomous verification method for checking whether the
current terminal program renders `scripts/render-torture` correctly.

## Approach

Use the existing headless debug server and renderer diagnostics instead of
desktop automation. The repository already exposes deterministic headless
rendering, debug screenshots, session grid state, frame commands, render
traces, pixel probes, errors, metrics, and capture/replay artifacts.

Add a dedicated verifier, likely `scripts/verify-render-torture`, that:

1. Runs `scripts/render-torture --list`.
2. Executes each section independently with `--only <name> --no-reset`.
3. Captures that section's UTF-8 output bytes.
4. Starts a fresh deterministic headless fixture session with fixed terminal
   dimensions.
5. Feeds the captured bytes through `/debug/actions` using `feedOutput`.
6. Verifies behavior through machine-readable debug endpoints.
7. Writes artifacts and a structured report under `.artifacts/runs/`.

## Assertions

Each section should have expectations in a structured file, for example
`fixtures/render-torture.expected.json`.

The verifier should assert:

- visible text exists for section sentinels
- grid cells have expected attributes, colors, hyperlink data, and wide-cell
  metadata via `/debug/sessions/<id>?includeGrid=true`
- expected glyph runs, background rectangles, underline styles, hyperlinks,
  and cursor commands appear via `/debug/frame-commands`
- sampled pixels match known color blocks via `/debug/pixel-probe`
- `/debug/errors` has no parser or renderer errors
- screenshots are non-empty and saved for diagnosis
- capture/replay passes for renderer-stable sections

## Scope Classification

`scripts/render-torture` intentionally goes beyond the MVP. The verifier should
classify each expectation so failures are actionable.

- `required`: MVP behavior that must pass, such as colors, common glyphs,
  cursor motion, erase behavior, scrolling, title updates, hyperlinks,
  mouse/focus mode state, and throughput stability.
- `diagnostic`: useful renderer coverage that is not currently a release gate.
- `unsupported-known`: behavior outside the MVP that must not crash, corrupt
  later sections, or leave terminal modes stuck.

## Report Shape

The verifier should return nonzero when any `required` expectation fails. It
should write a `report.json` with:

- overall status
- passed, failed, diagnostic, and unsupported-known sections
- expectation failures with endpoint evidence
- screenshot paths
- snapshot paths
- capture/replay report paths

## Why This Is Autonomous

A screenshot alone cannot prove correctness. This method verifies terminal
state, renderer intent, actual pixels, debug logs, and replay stability without
requiring a human to inspect the terminal by eye.

