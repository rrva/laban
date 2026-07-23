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
`FrameCommand.source` (`Sources/LabanRenderer/SlugGlyphRenderer.swift:2161` and
`:2336-2337`). Laban's other renderers (`software`, `classic` Metal,
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
  `TerminalSurfaceController.sidebarCommands(hoveredTabId:)`
  (`Sources/LabanCore/TerminalSurfaceController.swift:1225`). No new hover
  plumbing is introduced; the feature only changes what that existing signal
  causes to be drawn.
- Recent-content resolution stays renderer-neutral too:
  `TerminalSurfaceController` resolves the hovered tab's `Session` via
  `AppModel.session(forTab:)` and reads `Session.scrollbackBlock(rowOffset:
  maxRows:)` (`Sources/LabanCore/Session.swift:883`), the same cheap,
  view-independent scrollback accessor `TerminalSelection` and
  `ControlStateProjections` already use. This produces plain `[String]` lines
  with no dependency on any renderer type.
- `FrameCommand.source` (`Sources/LabanRenderer/FrameCommand.swift`) gains one
  new case, `.sidebarPreview`, alongside the existing `.sidebar`/`.terminal`.
  `SidebarProducer` only emits `.sidebarPreview`-tagged commands when the
  caller supplies a resolved `HoverPreview` value; when the effective renderer
  is not Slug or the setting is off, the caller (`sidebarCommands`) never
  constructs one, so no preview commands are emitted at all — non-Slug
  renderers never see the new source case in practice, mirroring ADR 0030's
  "gate at the producer, don't rely on the renderer to ignore it" posture.
- `SlugGlyphRenderer` alone resolves `.sidebarPreview` glyph runs against a
  third `previewFontAtlas`/`previewReferenceFontAtlas` pair, added beside the
  existing `sidebarFontAtlas`/`sidebarReferenceFontAtlas` pair and following
  the identical construction, `reconfigureFonts`, and per-command atlas
  selection pattern.
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
  content resolution, and panel layout math (a `CGRect` plus plain text), never
  glyph rasterization.
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
