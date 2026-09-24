# 35. Kitty Graphics Rendering

Date: 2026-09-24

## Status

Accepted. Supersedes rule 2 of ADR 0004's "Applies To New Code" (Kitty
graphics helpers stay unbound); builds on ADR 0034's pin, whose libghostty-vt
implements the complete protocol.

## Context

Programs show inline images through the Kitty graphics protocol (`ESC _ G`).
These include image viewers, plotting libraries, file managers, and agent
multiplexers such as herdr that forward images to their host terminal.
libghostty-vt parses the protocol, stores images, tracks placements, evicts
and answers queries. Laban drew none of it, and because the library enables
the protocol by default, Laban acknowledged images it never showed.

The design had to respect the following:

- ADR 0004: Swift never holds borrowed libghostty pointers.
- LabanRenderer cannot depend on LabanCore.
- Capture replay re-renders frames in a fresh process through the software
  renderer.
- Metal renderers draw in fixed batches rather than in command order.

## Decision

- **Terminal core owns image state**
  (`Sources/LabanTerminalCore/kitty_graphics.c`).
  - A process-wide gate (`laban_set_kitty_graphics_enabled`) fixes each
    session's support at creation. Disabled sessions set libghostty's storage
    limit to 0, so they store nothing and answer nothing.
  - Hosts apply `KittyGraphicsSettings` (default on; the
    `LabanKittyGraphicsEnabled` user default and the `LABAN_KITTY_GRAPHICS`
    environment variable can turn it off) at startup. `laband` forces it off.
  - Enabled sessions get a 64 MB per-screen limit, and the direct,
    shared-memory and temporary-file mediums. The plain file medium stays off.
  - An ImageIO decoder, installed once, turns PNGs into straight-alpha RGBA.
- **Snapshots carry placements, not pixels.** `LabanSnapshot` gains owned,
  sorted `LabanImagePlacement` records (viewport cell position, pixel size and
  offsets, crop, layer, image generation) and the cell pixel size.
  `laban_session_kitty_image_copy` copies one image's pixels as owned RGBA,
  keyed by its generation. Any change to the visible placement set forces full
  damage until rendered.
- **Pixels reach renderers through `FrameImageStore`** (LabanRenderer), keyed
  by libghostty's image generation stamp. The stamp is unique across the
  process, so new pixels always arrive under a new id. `KittyImagePublisher`,
  called from `Session.snapshot()`, copies each generation once and retires
  ids that go unreferenced.
- **One draw command.** `FrameCommand.texturedQuad` carries the destination
  rect, image crop, resource id and `ImageLayer`. `FrameProducer` emits each
  layer at its place in the command stream: below-background after the
  terminal fill, below-text after cell backgrounds, above-text after text.
  Images also ride `overlayCommands` on the cell-payload path.
- **Every renderer draws it.**
  - The software renderer draws in stream order.
  - `MetalRenderer` and `SlugGlyphRenderer` resolve quads through a
    per-renderer `KittyImageTextureCache`. They interleave the layers with
    their background batches at a split index recorded where the first
    below-background quad appears, and sample with UVs clamped to the crop so
    linear filtering never blends in pixels outside it.
  - Slug's translucent path has its own linear-light image pipeline.
- **Captures carry pixels.** Frames that reference images save each image
  once as `images/image-<id>.rgba`, and renderer replay loads them.

## Consequences

- Images work in every selectable renderer, in the headless runtime, and in
  capture/replay. Fixtures can assert them with cell-positioned pixel probes.
- Slug draws the cursor with the background batch, so an above-text image
  placed over the cursor covers it. `MetalRenderer` keeps its cursor on top.
- Animated images show a single frame, and Unicode-placeholder placements
  (tmux) are not drawn. The public C API has neither an animation tick nor
  placeholder resolution; execplans/active/kitty-graphics-rendering.md
  Milestone 4 covers adding them.
- Tier 2 `laband` viewers show no images until its snapshot ring carries
  them; that extension falls under ADR 0006.

## Applies To New Code

1. Only `LabanTerminalCore` touches `ghostty_kitty_graphics_*` and
   `GhosttyKittyGraphics*` handles.
2. Every selectable renderer (`RendererSelection.selectableCases`) draws
   `.texturedQuad` in all three `ImageLayer`s through `FrameImageStore`; a
   `case .texturedQuad: break` there is a bug. The retired
   `VectorGlyphRenderer` (ADR 0033) is exempt.
3. Keep `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE` false unless a new ADR
   accepts the local-file-read exposure.
4. Key image caches by resource id (image generation). Never compare pixels
   or dimensions to detect changes.
5. Frame-level image behavior changes need a pixel-probe fixture or
   `KittyImageParityTests` coverage across every selectable renderer.
