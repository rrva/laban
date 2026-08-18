# 32. Slug Glyph Renderer Is the Default for New Installs

Date: 2026-08-18

## Status

Accepted. Narrowly reverses the default-off half of ADR 0027 and the "classic
stays the default" half of ADR 0017. Everything else in both ADRs stands: the
renderers remain user-selectable peers, and no renderer is removed.

## Context

ADR 0017 made the damage-scoped classic renderer the default and kept
`gpuDriven` opt-in. ADR 0022 (`vectorGlyph`) and ADR 0027 (`slugGlyph`) each
added a further backend as "default-off", which was the right call while the
analytic text path was unproven: a new renderer that miscomposites text is a
much worse first impression than a conservative one.

That caution has since been paid off. Slug now carries the capabilities the
other backends do not have — spinner motion smoothing (ADR 0030) and the
sidebar hover preview (ADR 0031) are deliberately Slug-only — so the default
renderer was the one backend that could not show what the app actually does.
Its cost model is also the better fit for a terminal that zooms: Slug's glyph
geometry is keyed by visual font identity and glyph id at a fixed reference
point size, with the active size carried as a transform, so fractional zoom
reuses the cached curves instead of re-baking a size-keyed mask atlas.

Leaving it opt-in meant the shipped default was chosen by build order rather
than by merit, and every new install had to be told to go change a menu.

## Decision

`RendererSelection.persisted()` resolves an absent or unparseable preference to
a new `RendererSelection.defaultSelection`, which is `slugGlyph`.

- **New installs only.** A persisted preference always wins. `defaultSelection`
  is the empty-defaults fallback, so an existing install keeps whatever it was
  running, including a deliberate `classic` or `vectorGlyph` choice.
- **Degradation is unchanged.** `makeRendererBackend` still falls back to
  classic on `slugPipelineUnavailable` and to software on `noMetalDevice`, and
  still reports both through `RendererStatus`. Making Slug the default widens
  who reaches that fallback path; it does not change what the path does.
- **No OS gate.** Unlike `gpuDriven` (macOS 26+), Slug's availability is a
  runtime pipeline question, not an OS version one, so `defaultSelection` asks
  `isAvailableOnCurrentOS` and otherwise defers to `RendererMode.defaultMode`.
- **The default lives in one place.** `RendererSelection.defaultSelection` is
  the single expression of it; `RendererMode.defaultMode` continues to answer
  only the narrower classic/gpuDriven question for the legacy mode key, which
  shares the same defaults key.

## Consequences

- A fresh install renders through the analytic path, so Slug-only capabilities
  (ADR 0030, ADR 0031) are reachable without first changing a setting.
- Slug's fallbacks are now on the cold-launch path for machines without a
  working Slug pipeline. The `RendererStatus` fields (`configuredRenderer`,
  `effectiveRenderer`, `fallbackReason`) become the first place to look when a
  new install reports unexpected text rendering, and they already carry that
  information.
- Renderer-parity tests and any test asserting a fresh-defaults renderer must
  pin `slugGlyph`, not `gpuDriven`. `RendererMode.persisted()` still cannot
  parse `slugGlyph` from the shared defaults key and falls back to
  `RendererMode.defaultMode`; that predates this ADR (it is equally true of
  `vectorGlyph`) and is unchanged by it.
- The renderer menu now shows Slug checked on a fresh profile.

## Applies To New Code

Read the default from `RendererSelection.defaultSelection` or
`RendererSelection.persisted()`. Do not re-derive it, and do not assume a
default of `classic`/`gpuDriven` — in particular, do not reach for
`RendererMode.defaultMode` to answer "what renderer does a new install get",
because it can only express the two Metal cell modes. New renderer capabilities
still follow ADR 0030 and ADR 0031: being the default does not make Slug the
place to put behavior that should be renderer-neutral.
