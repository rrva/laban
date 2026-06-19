# 22. Vector (Curve) Glyph Renderer Is an Opt-In Peer Beside Classic/GPU-Driven

Date: 2026-06-19

## Status

Accepted. Implementation tracked in
`execplans/active/vector-glyph-renderer.md`.

## Context

Laban's three renderers (`software`, `classic`, `gpuDriven`) all rasterize
glyphs the same way: CoreText draws an alpha mask once, the mask is uploaded to
an R8 atlas (`MetalGlyphAtlas`), and the atlas is sampled at a single fixed
subpixel position. This caps text quality at the baked resolution, has no real
subpixel anti-aliasing, and re-rasterizes from scratch on every size or
subpixel-position change. On non-stripe OLED panels (Samsung QD-OLED, LG WOLED)
the single-sample approach produces visible color fringing.

The technique described at <https://osor.io/text> offers an alternative: keep
the raw Bézier curves that define each glyph, send them to the GPU, and
rasterize at runtime into a resident atlas, accumulating coverage samples across
frames ("temporal accumulation") so static text converges to high-quality
anti-aliasing at near-zero per-frame cost, with per-R/G/B subpixel coverage.
Terminals are an ideal workload — almost all text is static for many frames.

On macOS the curve data is available at runtime via `CTFontCreatePathForGlyph`,
so Laban can run the whole pipeline on-device with no offline bake (unlike the
article, which uses FreeType offline).

ADR 0017 established the regime for adding renderer modes: a new mode ships
opt-in and default-off, preserves the `[FrameCommand]` contract, keeps the
software/offscreen/debug/capture paths free of Metal internals, and earns any
default-enable decision only with raw-RGBA parity tests and release-mode timing
evidence. This ADR extends that regime to the vector-glyph path.

Research (June 2026) confirmed the technique is mature and that this is
greenfield in the terminal space:

- The winding-number method is canonical (lineage: Dobbie → GreenLightning →
  Wallace → Lague). osor.io's contribution is the engineering recipe (runtime
  curve extraction → resident atlas → temporal accumulation → subpixel AA),
  which is the de-facto SOTA for this family.
- No terminal ships GPU curve rasterization today. Ghostty (Laban's terminal
  core) and kitty/WezTerm/Alacritty all use CPU-rasterized alpha-mask atlases —
  the model Laban's `MetalGlyphAtlas` already follows.
- The Slug algorithm (numerical-precision SOTA) is patent-encumbered (US
  9,710,310, ~2035 term); the patent-safe path is temporal accumulation +
  tolerance, which is what this renderer uses.
- No Metal reference implementation exists; osor.io's renderer is Vulkan/HLSL
  on Windows. The Metal compute kernel is written from scratch.
- The other SOTA contender, Linebender's vello/sparse-strips GPU-compute 2D
  path renderers, solve general vector graphics but have an open glyph-caching
  gap and are not production-ready — overkill for a terminal's workload.
- Mac specifics that shape the implementation: Apple GPU `simdgroup` is
  32-wide (not the article's 16), enabling the same band scalarization with
  `simd_min`/`simd_max`; Apple-GPU tile shaders are a future optimization
  opportunity the article doesn't use; `CTFontCreatePathForGlyph` provides
  runtime curve extraction superior to the article's offline FreeType bake;
  macOS exposes no arbitrary subpixel-layout API (the article's "A Plea" is
  unresolved), so the layout is user-configurable.

## Decision

Add a fourth, opt-in renderer — `vectorGlyph` — implemented as a new
`RendererBackend` peer (`VectorGlyphRenderer`), not as a third mode inside
`MetalRenderer`.

- `RendererMode` gains a `.vectorGlyph` case. It is **not** gated behind
  `#available(macOS 26, *)`: curve rasterization needs only compute + render
  pipelines available across the full macOS deployment range. `RendererSelection`
  and the View ▸ Renderer menu gain a "Vector Glyph Renderer" item.
- `RendererMode.defaultMode` is unchanged. `vectorGlyph` ships default-off, like
  `gpuDriven` did. Default-enable is deferred to a later, evidence-gated plan.
- The new renderer owns its own `CAMetalLayer`, persistent target, compute +
  render pipelines, and a curve-backed resident atlas with temporal
  accumulation and per-subpixel coverage. Its shaders live in a separate
  `VectorGlyphShaders.metal`; `Shaders.metal` is not edited.
- It consumes `[FrameCommand]` and `TerminalCellPayload` exactly as the other
  backends do. The software/offscreen/debug/capture-replay paths and the
  `[FrameCommand]` contract are not modified and never depend on the vector
  renderer's Metal internals. `HeadlessDebugRuntime` gains parity (selectable
  headless, `/debug/screenshot` and `/debug/renderer-status` work through it).
- The existing `classic` and `gpuDriven` content passes in `MetalRenderer`
  (`encodeContentPass`, `encodeGPUCellContentPass`) are not behaviorally
  edited. The vector path is additive.
- Box-drawing / block-element glyphs are pinned to a (0,0) subpixel atlas key
  and rounded cell size so they align to the cell grid and reuse the atlas,
  applying the article's monospaced-editor optimization selectively.

## Consequences

- Users get a crisp, vector-accurate, subpixel-anti-aliased text path on every
  supported macOS version, selectable without restarting their session.
- The classic and GPU-driven renderers remain the default and fallback paths;
  `vectorGlyph` does not perturb them.
- The vector renderer must reach feature parity with `classic` (box drawing,
  wide/CJK/ZWJ clusters, decorations, overlays, image quads, sidebar, preedit)
  and pass the ADR-0017-style gate (raw-RGBA parity, release timing, session-
  identity live switching) before it can be considered for default-enable.
- A new resource surface (curve buffers, RGBA accumulation atlas, compute
  pipeline) is owned solely by `VectorGlyphRenderer`; it does not leak into the
  shared renderer contract.
- Subpixel layout is user-configurable (RGB stripe default, plus custom for
  OLED); macOS exposes no arbitrary subpixel-structure API, so the "ideal"
  automatic layout from the article's "A Plea" remains out of reach.

## Applies To New Code

Any renderer work continues to preserve the `[FrameCommand]` contract first.
GPU-only optimizations may add side-channel resources, but the
software/offscreen/debug/capture paths must not depend on Metal internals. A
new renderer mode or any future default-enable change for `vectorGlyph` must
ship with raw-RGBA parity tests, release-mode timing evidence, and a
session-identity check for live switching — the same standard ADR 0017 sets for
`gpuDriven`.
