# 31. Sidebar Hover Preview Is a Slug-Only Capability

Date: 2026-07-23

## Status

Accepted. Implementation tracked in `execplans/active/sidebar-hover-preview.md`.

## Context

Laban's sidebar lists every open tab, but a tab that is not the active one gives
no view into what it is actually doing beyond the one-line status metadata
`SidebarProducer` already renders (title, branch/command, agent status dot).
Checking on a background tab today requires switching to it, which loses the
place the user was in on the tab they came from.

ADR 0027 added `slugGlyph`: an analytic GPU glyph renderer whose vertex/fragment
shaders resolve glyph curves from `GlyphCurveStore` at a fixed reference point
size (14pt) and rescale them at render time (`pointScale = activeAtlas.pointSize
/ referencePointSize`). Point size is a render-time transform, not a re-bake, so
`SlugGlyphRenderer` already renders two simultaneous font sizes from one shared
curve cache: `fontAtlas` (terminal size) for `.terminal`-sourced glyph runs and
`sidebarFontAtlas` (smaller) for `.sidebar`-sourced ones, chosen per
`FrameCommand.source` via `atlas(for:)`/`referenceAtlas(for:)`
(`Sources/LabanRenderer/SlugGlyphRenderer.swift:2341` and `:2352`). Laban's other renderers (`software`, `classic` Metal,
`vectorGlyph`) bake glyph coverage bitmaps at a fixed size per atlas build; each
additional simultaneous size is a distinct, non-free rasterization and cache
tier for them, not a cheap render-time scale factor.

This makes "render a second, small, live copy of another tab's recent text
next to the sidebar" a capability only Slug offers close to free: a third
`previewFontAtlas` resolves against the *same* reference-size curve cache the
terminal and sidebar atlases already populate, so no new glyph extraction or
texture work is required to add it. On any other renderer, showing a live
miniature would mean baking and maintaining an entirely separate small-size
glyph atlas and raster path with no shared precedent, for a materially worse
result (a scaled bitmap, not crisp vector coverage) — the same shape of
trade-off ADR 0030 made for spinner motion smoothing.

## Decision

The sidebar hover preview (a floating, live, miniature rendering of a
background tab's recent scrollback text, shown while hovering that tab's
sidebar row) is intentionally a Slug-only capability. It is gated on the
**effective** renderer being `slugGlyph`, the persisted setting being enabled,
and the previewed tab existing and not being the active tab.

- Hovered-tab detection is unchanged and renderer-neutral: `hoveredSidebarTabId`
  (`Sources/LabanApp/TerminalBitmapView.swift`) already flows through
  `TerminalSurfaceFrameRequest.hoveredSidebarTabId` into
  `TerminalSurfaceController.makeFrame(_:)`, which passes it to two sibling
  functions: `sidebarCommands(hoveredTabId:)`
  (`Sources/LabanCore/TerminalSurfaceController.swift:1288`, unchanged sidebar
  chrome — tab rows, close-✕, drag indicator) and the private
  `hoverPreviewOverlayCommands(hoveredTabId:...)`
  (`Sources/LabanCore/TerminalSurfaceController.swift:1396`, new — resolves
  and gates the preview panel). No new hover plumbing is introduced; the
  feature only adds a second consumer of that existing signal.
- Recent-content resolution is intentionally **not** renderer-neutral text:
  `hoverPreviewOverlayCommands` resolves the hovered tab's `Session` via
  `AppModel.session(forTab:)`, takes its live `session.snapshot()`
  (`Sources/LabanCore/Session.swift`), and feeds it through `FrameProducer`
  (`Sources/LabanCore/FrameProducer.swift`) — the same cell-reading and
  run-coalescing code the real terminal pane uses every frame — configured
  with the preview's own small cell size and positioned at the panel's
  content rect. `FrameProducer` is reused unmodified (it always emits
  `source: .terminal`); the result is post-processed in plain Swift to
  relabel matching commands to `source: .sidebarPreview`, drop grid rows
  that don't fully fit the panel vertically, and truncate each kept glyph
  run's text to whatever whole preview cells fit horizontally. This choice
  (real per-cell terminal colors via the shared cell-reading code, rather
  than a renderer-neutral plain-`[String]` scrollback dump) was made after
  the first implementation pass shipped monochrome text and user testing
  flagged it as a real gap — see `execplans/active/sidebar-hover-preview.md`'s
  Surprises & Discoveries for the full history. `Session.scrollbackBlock`
  is no longer used by this feature at all.
- `FrameCommand.source` (`Sources/LabanRenderer/FrameCommand.swift`) gains one
  new case, `.sidebarPreview`, alongside the existing `.sidebar`/`.terminal`.
  `hoverPreviewOverlayCommands` only emits `.sidebarPreview`-tagged commands
  when its own guard (`effectiveRendererIsSlug`, `hoverPreviewEnabled`, a
  resolved `hoveredTabId` distinct from the active tab) passes; when the
  effective renderer is not Slug or the setting is off, it returns `[]`
  immediately, so no preview commands are emitted at all — non-Slug
  renderers never see the new source case in practice, mirroring ADR 0030's
  "gate at the producer, don't rely on the renderer to ignore it" posture.
- Because the preview's own opaque background (a `.rect`) and the terminal's
  own glyph text underneath it are both ordinary commands, `SlugGlyphRenderer`'s
  fixed two-phase draw order (every `.rect` from every source draws in one
  earlier phase, then every `.glyphRun` from every source draws in a
  strictly later phase — see `SlugGlyphRenderer.swift`'s `render()`) means
  command ordering alone can never make the panel's background occlude
  another source's glyph text: glyphs always draw after ALL rects,
  regardless of array position. This feature reuses the same occlusion-mask
  mechanism `.preedit` (IME composition) already relies on for exactly this
  problem: `overlayMaskRects` (collected once per frame from `.rect`
  commands tagged `.preedit` or `.sidebarPreview`) makes `appendGlyphRun`
  skip emitting any *other* source's glyph cells that intersect those
  rects, so the terminal's own text is never drawn where the panel sits.

## Content resolution detail: `FrameProducer` reuse (not renderer-specific)

The `session.snapshot()` + `FrameProducer` content path described above is
itself renderer-neutral — `FrameProducer` has no dependency on which
renderer backend is active, and none of this section's mechanics are Slug
capabilities. Content resolution stays in `LabanCore` regardless of which
renderer draws the result; only the drawing (the third `previewFontAtlas`
and the `overlayMaskRects` occlusion described above) is Slug-only.
- `SlugGlyphRenderer` alone resolves `.sidebarPreview` glyph runs against a
  third `previewFontAtlas`/`previewReferenceFontAtlas` pair, added beside the
  existing `sidebarFontAtlas`/`sidebarReferenceFontAtlas` pair and following
  the identical construction and `reconfigureFonts` pattern. Per-command atlas
  selection was refactored from the prior two-way ternary into
  `atlas(for:)`/`referenceAtlas(for:)` helpers (a `switch` with a `default:`
  case, not an exhaustive per-`FrameSource`-case list, so a future case still
  falls through safely) so terminal/sidebar/preview share one selection
  site instead of a ternary growing a third arm. `runFontIdentity`'s
  font-identity cache key was similarly widened from a 1-bit `sidebar: Bool`
  to a 2-bit atlas-kind field so preview's identity cache slot can't collide
  with sidebar's when the two share a point size.
- The preview point size is derived from the terminal's current point size by
  a fixed ratio (`FontAtlas.previewPointSize(forTerminalPointSize:)`), the same
  shape as the existing `FontAtlas.sidebarPointSize(forTerminalPointSize:)`
  derivation, so it stays proportional across live zoom instead of pinned to a
  constant.
- The UI checkbox is disabled when the configured renderer is not Slug, and the
  debug endpoint reports `configured`, `rendererEligible`, `effectiveEnabled`,
  matching the ADR 0030 precedent.

## Consequences

- Users on other renderers see the sidebar exactly as before; hovering a
  background tab is a no-op there rather than a degraded or blurry preview.
- `SlugGlyphRenderer` owns all pixels of the preview panel. The core
  (`TerminalSurfaceController`, `SidebarProducer`) owns hover detection,
  content resolution (real per-cell colors, via `FrameProducer` against the
  hovered tab's live snapshot), and panel layout math (a `CGRect` plus a
  `[FrameCommand]` list), never glyph rasterization.
- Non-Slug renderer files (`SoftwareBackend`, `MetalRenderer`,
  `VectorGlyphRenderer`) require no changes at all: they take no new
  parameters and no new `FrameCommand` fields are added, only one new
  `FrameSource` case they never receive in practice.
- A future decision to bring this preview to another renderer requires a new
  ADR backed by an equally capable substrate: a way to render a second live
  small-size glyph surface without a full separate atlas/raster pipeline per
  size.

## Applies To New Code

Do not add hover-preview state, content-resolution logic, or layout math to
non-Slug renderers. Keep any new `FrameCommand` fields this feature needs
optional and nil/absent by default. Gate emission of `.sidebarPreview` commands
at the producer (`SidebarProducer`/`TerminalSurfaceController`) on the
effective `slugGlyph` renderer and the persisted setting, not on renderer
internals or on non-Slug renderers silently no-oping.
