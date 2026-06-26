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
- The Slug algorithm (Eric Lengyel) is the numerical-precision SOTA and, as of
  2026, is **no longer patent-encumbered**: US Patent **10,373,352** (granted
  2019) was dedicated to the public domain via a USPTO terminal disclaimer on
  2026-03-17, with MIT-licensed reference shaders published
  (<https://terathon.com/blog/decade-slug.html>). The choice of osor.io's
  resident-atlas + temporal-accumulation recipe over Slug is therefore an
  **architecture-fit** decision (a terminal redraws mostly-static glyphs every
  frame, so a cached accumulation atlas amortizes cost where Slug recomputes
  per-pixel per-frame), **not** a legal one. Slug's reference shaders are prior
  art worth studying, and a direct Slug-style renderer is a credible **future
  (v2)** option — but not the first integration target, because it is a larger
  architectural departure (direct curve rendering rather than atlas-first, more
  shader/data complexity, harder headless/debug/capture integration, less
  incremental migration from current code). (A prior draft cited "US 9,710,310,
  ~2035" — wrong number and term; corrected.)
- No Metal reference implementation of the osor.io recipe exists; that renderer
  is Vulkan/HLSL on Windows. The Metal compute kernel is written from scratch.
- The other SOTA contender, Linebender's vello / vello_hybrid GPU-compute 2D
  path renderers, solve general vector graphics; as of the Linebender Q1 2026
  update the main crate is still alpha (Hybrid ~beta) and glyph caching is in
  early implementation (atlas APIs landed, still maturing). For a terminal's
  workload the resident-curve-atlas approach is simpler and purpose-fit — an
  architecture-fit/maturity judgment, re-verifiable, not a fixed "not
  production-ready" claim.
- Mac specifics that shape the implementation: Apple GPU `simdgroup` is
  32-wide (not the article's 16), enabling the same band scalarization with
  `simd_min`/`simd_max`; Apple-GPU tile shaders are a future optimization
  opportunity the article doesn't use; `CTFontCreatePathForGlyph` provides
  runtime curve extraction superior to the article's offline FreeType bake;
  macOS exposes no arbitrary subpixel-layout API (the article's "A Plea" is
  unresolved), so the layout is user-configurable.

## Decision

**osor-style first, Slug-informed.** Laban's first vector glyph renderer is an
osor-inspired runtime outline rasterizer into a glyph atlas, chosen for
**architectural fit** with the existing renderer/backend/atlas model — not for
Slug patent avoidance (Slug is patent-free). Slug is reference material
(robustness, shader/data-layout, correctness test cases) and a possible future
direct-vector renderer; Vello is a heavy Rust/wgpu general-2D integration not
suited to the first Swift/Metal terminal path; the CoreText raster atlas stays
the baseline/fallback. Ranked by effort-to-impact: (1) osor-style vector-to-atlas
first, (2) Slug-style direct renderer as a studied v2, (3) Vello not first, (4)
CoreText raster atlas baseline. The full comparison table lives in the execplan
(`execplans/active/vector-glyph-renderer.md`, "Architecture decision: osor-style
first, Slug-informed").

Add a fourth, opt-in renderer — `vectorGlyph` — implemented as a new
`RendererBackend` peer (`VectorGlyphRenderer`), not as a third mode inside
`MetalRenderer`.

- The requested-backend type `RendererSelection` gains a `.vectorGlyph` case
  (and moves down to `LabanRenderer` so headless/debug can share it and the
  backend factory without depending on `LabanApp`). The Metal-internal
  `RendererMode` enum (`classic`/`gpuDriven`) is **unchanged** — vector is a
  separate backend, not a Metal mode, and `RendererSelection.vectorGlyph.metalMode`
  is `nil` so it can never be routed into `MetalRenderer`. Vector is **not**
  gated behind `#available(macOS 26, *)`: curve rasterization needs only compute
  + render pipelines available across the full macOS deployment range. The View ▸
  Renderer menu and the Settings popup gain a "Vector Glyph Renderer" item.
- `RendererMode.defaultMode` is unchanged. `vectorGlyph` ships default-off, like
  `gpuDriven` did. Default-enable is deferred to a later, evidence-gated plan.
- The new renderer owns its own `CAMetalLayer`, persistent target, compute +
  render pipelines, and a curve-backed resident atlas with temporal
  accumulation and per-subpixel coverage. Its shaders live in a separate
  `VectorGlyphShaders.metal`; `Shaders.metal` is not edited.
- It consumes `[FrameCommand]` and `TerminalCellPayload` exactly as the other
  backends do. The `[FrameCommand]` contract is not modified and never depends on
  the vector renderer's Metal internals. `HeadlessDebugRuntime` gains parity
  (selectable headless via the shared backend factory; renderer identity and
  fallback reported through the existing `GET /debug/render` status payload —
  there is **no** `/debug/renderer-status` route — and `/debug/screenshot`
  served via offscreen Metal render + readback). Making headless observe vector
  output is explicit work, not automatic: the current debug stack reads pixels
  from a concrete `BitmapSurface`/`SoftwareRenderer`, so the screenshot endpoints
  and the headless runtime are refactored to go through the `RendererBackend`
  protocol (`presentationImage`/`pngData`/`rendererStatus`).
- The existing `classic` and `gpuDriven` content passes in `MetalRenderer`
  (`encodeContentPass`, `encodeGPUCellContentPass`) are not behaviorally
  edited. The vector path is additive.
- Box-drawing / block-element glyphs are pinned to a (0,0) subpixel atlas key
  and rounded cell size so they align to the cell grid and reuse the atlas,
  applying the article's monospaced-editor optimization selectively.

## Consequences

- Users get a crisp, vector-accurate, subpixel-anti-aliased text path on every
  supported macOS version, selectable without restarting their session.
- `classic`/`gpuDriven` remain the default; `vectorGlyph` does not perturb them.
  The fallback cascade is explicit and distinct: vector pipeline fails on a
  device-present machine → classic Metal; **no Metal device at all → software**
  (never classic, which is itself Metal); a single glyph with no usable outline →
  raster/color atlas for that cell only (`ColorGlyphAtlas` for color/bitmap glyphs
  when the Emoji rendering setting is `color`, otherwise the R8 `MetalGlyphAtlas`
  tint path). Each is reported via
  `RendererStatus{configuredRenderer, effectiveRenderer, fallbackReason}`.
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

## Evidence

Implementation evidence as of 2026-06-26 is partial and lives in the ExecPlan
until the M5 gate closes:

- `vectorGlyph` is selectable through the shared backend factory, View renderer
  menu, Settings renderer popup, and `laban-agent --renderer=vectorGlyph`.
  `RendererMode` remains limited to `classic`/`gpuDriven`.
- Focused XCTest coverage now runs in the selected Xcode toolchain
  (`/Applications/Xcode.app/Contents/Developer`, Xcode 26.6). Passing filters
  include `swift test --filter VectorGlyph`, `GlyphCurveStoreTests`,
  `GPUCellParityTests`, `DebugActionDecodingTests`, `LabanDebugSmokeTests`,
  `TerminalBitmapViewSelectionTests`, `TerminalWidthPolicyGuardTests`, and the
  focused preedit smoke. A full `swift test` run is not green in this
  environment due to pre-existing/non-vector failures and pasteboard-dependent
  tests; see the ExecPlan for the failure list.
- Headless vector rendering is observable through `GET /debug/render` and
  `GET /debug/screenshot`. The latest mixed-Unicode fallback smoke reported
  `configuredRenderer == effectiveRenderer == "vectorGlyph"`,
  `rasterFallbackGlyphs == 7`, and `vectorSubpixelLayout == "rgbStripe"`, with
  a readable screenshot at
  `.tmp/vector-headless-raster-fallback-status2/mixed-unicode-status.png`.
- Color emoji fallback is observable in headless vector mode with the
  process-local `laban-agent --emoji-rendering=color` override. The latest color
  smoke reported `effectiveRenderer == "vectorGlyph"`, `emojiRendering.mode ==
  "color"`, and `rasterFallbackGlyphs == 3`, with visible color emoji in
  `.tmp/vector-headless-color-emoji/color-emoji.png`.
- Headless Metal screenshots now work for classic as well as vector because
  `HeadlessDebugRuntime` enables `MetalRenderer.captureMode` for verification
  backends; `testRuntimeClassicRendererScreenshotNonEmpty` pins the classic
  path. Matched headless comparisons between classic and vector frame 131/133
  now cover `fixtures/find-viewport.json`, debug-driven
  `overlay-selection-find`, debug-driven `preedit-inline`,
  `fixtures/colored-boxes.fixture.json`,
  `fixtures/cjk/trust-gate.fixture.json`,
  `fixtures/color-emoji.fixture.json`,
  `fixtures/mixed-fallback.fixture.json`, and
  `fixtures/styled-decorations.fixture.json`;
  `scripts/vector-glyph-parity-matrix` reproduces the run and writes artifacts
  under `.tmp/vector-parity-matrix/<fixture>/`. The eight case metrics were:
  find-viewport `meanAbsRGB 0.2850`, `p95AbsRGB 0`, `p99AbsRGB 0`;
  overlay-selection-find `meanAbsRGB 0.2728`, `p95AbsRGB 0`, `p99AbsRGB 0`;
  preedit-inline `meanAbsRGB 0.3956`, `p95AbsRGB 0`, `p99AbsRGB 1`;
  colored-boxes `meanAbsRGB 0.0906`, `p95AbsRGB 0`, `p99AbsRGB 0`; CJK trust
  gate `meanAbsRGB 0.1136`, `p95AbsRGB 0`, `p99AbsRGB 0`; color emoji
  `meanAbsRGB 0.2467`, `p95AbsRGB 0`, `p99AbsRGB 0`; mixed fallback
  `meanAbsRGB 0.2838`, `p95AbsRGB 0`, `p99AbsRGB 0`; styled decorations
  `meanAbsRGB 0.8979`, `p95AbsRGB 0`, `p99AbsRGB 36`. The styled fixture also
  validates frame-command metadata for underline styles, strikethrough,
  overline, faint, inverse text, and invisible-text omission. The overlay case
  validates that both classic and vector frame-command JSON include `selection`,
  `findMatch`, `findSelected`, and `cursor`. The preedit case validates one
  `.preedit` rect and one `.preedit` glyph run with text `中👩‍💻a` for both
  backends; the vector run reports `rasterFallbackGlyphs == 2`. The color emoji
  case runs both renderers with `--emoji-rendering=color` and validates the
  emoji glyph-run text plus vector `rasterFallbackGlyphs == 3`. The mixed fallback case
  validates ASCII, CJK, emoji/ZWJ, private-use, and box-drawing text with vector
  `rasterFallbackGlyphs == 8`. Every case asserts both classic and vector emit
  sidebar `glyphRun` and `rect` commands.
- `./scripts/install-app` installs the profilable release bundle successfully
  without launching it. The installed bundle at `~/Laban.app` has stamp
  `e37cb91+dirty`, includes `VectorGlyphShaders.metal`, has a sibling
  `~/Laban.app.dSYM`, and passes
  `codesign --verify --deep --strict ~/Laban.app`.
- Debug/control contract checks pass for the new render fields and vector
  subpixel action: `./scripts/check-debug-contract`, `./scripts/check-docs`,
  `./scripts/check-boundaries`, and `swift run LabanControlGen --check`.
- A fresh broad local pass also verifies the current tree outside the missing
  XCTest/Instruments/manual-GUI gates: full `swift build`, `./scripts/test-e2e`,
  `./scripts/check-fd-hygiene`, `./scripts/check-anchors`,
  `./scripts/check-dependencies`, `./scripts/check-model-coverage`,
  `./scripts/fuzz-labpty --check`, `./scripts/lint`, `git diff --check`,
  `bash -n scripts/vector-glyph-parity-matrix`, and
  `scripts/vector-glyph-parity-matrix` pass. The rebuilt
  `.build/laban/Laban.app` passes `codesign --verify --deep --strict`, contains
  the `Vector Glyph Renderer` menu string, bundles `VectorGlyphShaders.metal`,
  and stamps `LABANBuildCommit` as `e37cb91+dirty`. CBMC/TLA/MSan-adjacent
  scripts were run and self-skipped or downgraded as scripted where the local
  toolchain lacks those tools.
- Mechanical review self-checks also pass locally, without satisfying the formal
  fresh-review requirement: `RendererMode.swift` still has no `vectorGlyph`
  case, `RendererSelection.vectorGlyph.metalMode == nil`, vector routing lives
  in the shared `makeRendererBackend(...)` factory used by both `LabanApp` and
  `LabanDebug`, and `LabanDebug` does not import `LabanApp`. Headless runtime
  evidence under `.tmp/vector-review-route/` reported vector configured/effective
  with no fallback, produced a 920×228 screenshot via `/debug/screenshot`, and
  returned 404 for the intentionally absent `/debug/renderer-status` route.
  Evidence under `.tmp/vector-review-subpixel-action/` confirmed the
  `setVectorSubpixelLayout` action updates `/debug/render` to `bgrStripe`.
- That self-check found and fixed one fallback-status edge: when vector pipeline
  creation falls back to a classic `MetalRenderer`, later selecting Classic now
  clears the vector status override instead of reporting stale
  `configuredRenderer == "vectorGlyph"`. `MetalRenderer.clearRendererStatusOverride()`
  and the AppKit selection path cover that reuse case, and
  `testMetalRendererStatusOverrideCanBeClearedWhenReusingFallbackRenderer` pins
  it for the XCTest-capable toolchain.
- Synthetic italic now follows the vector design rather than the raster fallback
  path: the vector mask descriptor shears the outline, `VectorGlyphMaskAtlas.Key`
  includes a `syntheticItalic` discriminator, and synthetic bold remains raster
  fallback. Runtime evidence under `.tmp/vector-style-probe/` shows regular
  ASCII and SGR italic ASCII differ (`meanAbsRGB 0.3077`, `maxAbsRGB 157`,
  `874/209760` changed pixels) while italic ASCII stays
  `effectiveRenderer == "vectorGlyph"` with `rasterFallbackGlyphs == 0`.
- Vector decorations now use the same `TextDecorationLayout` geometry as
  `MetalRenderer` for underline styles, underline color, strikethrough, and
  overline. Runtime evidence under `.tmp/vector-decoration-probe/` shows plain
  and decorated vector runs both stay `effectiveRenderer == "vectorGlyph"` with
  `rasterFallbackGlyphs == 0`, while decoration pixels change
  (`meanAbsRGB 1.2745`, `maxAbsRGB 161`, `4836/209760` changed pixels).
- Headless renderer switching is now externally controllable via
  `POST /debug/actions` with `setRenderer`. `scripts/vector-renderer-switch-smoke`
  reproduces the runtime check and writes
  `.tmp/vector-headless-renderer-switch/<run-id>/` by default, with
  `ARTIFACT_ROOT` available for a stable path; the latest stable-path run shows
  the same active session id before software→vectorGlyph and vectorGlyph→classic
  switches, while `/debug/render` moves through software/software,
  vectorGlyph/vectorGlyph, and classic/classic. This is partial identity
  evidence; AppKit live switching remains a separate M5 gate.
- Subpixel layout is cached on `VectorGlyphRenderer`, persisted as RGB/BGR
  presets or advanced custom JSON in UserDefaults, applied live from Settings
  through a notification, and exposed for debug readback via `/debug/render`.
  Settings intentionally exposes only RGB/BGR presets; arbitrary OLED/editor
  offsets stay in JSON/debug paths until there is a calibration workflow. The
  RGB-vs-BGR fringing artifact is under `.tmp/vector-subpixel-fringing/` with
  mean RGB delta `0.2637`, `p95AbsRGB 0`, and `p99AbsRGB 0`.
- Release trace evidence is recorded from Xcode/Instruments bundles. In the
  attached headless vector trace, `laban.vector.content` reports p50
  0.195542-0.203125 ms and p99 0.218532-0.231455 ms; accumulated glyph work
  reports p50 0.025562 ms and p99 0.030146 ms. The matched classic attach trace
  reports `laban.frame` p50 0.269375 ms and p99 0.326453 ms. Some `xctrace
  record` runs emitted corrupt-log warnings while still producing analyzable
  trace bundles.
- A manual AppKit launch found one real live-window crash after the initial
  autonomous matrix: vector instance batches could exceed Metal's 4 KB
  `setVertexBytes` inline limit, causing an AGX driver abort in
  `setVertexProgramBufferBytes`. Commit `8f9d473` fixes vector instance uploads
  by using retained `MTLBuffer`s above the inline limit and adds
  `VectorGlyphParityTests/testRendererHandlesLiveSizedInstanceBatches`, which
  renders a 160x48 frame with large rect/glyph batches. The hotfix was verified
  with that regression, `swift test --filter VectorGlyph`, `./scripts/lint`,
  `git diff --check`, `./scripts/build-app`, and codesign verification, then
  pushed to `origin/codex/vector-glyph-renderer`.
- Remaining M5 evidence before the ExecPlan can close: manually relaunch the
  installed AppKit app and verify live-shell classic<->vector switching preserves
  the session, then run the formal fresh-agent Review Gate. Until those gates
  are recorded, this ADR remains an accepted opt-in design decision, not a
  default-enable decision.

## Applies To New Code

Any renderer work continues to preserve the `[FrameCommand]` contract first.
GPU-only optimizations may add side-channel resources, but the
software/offscreen/debug/capture paths must not depend on Metal internals. A
new renderer mode or any future default-enable change for `vectorGlyph` must
ship with raw-RGBA parity tests, release-mode timing evidence, and a
session-identity check for live switching — the same standard ADR 0017 sets for
`gpuDriven`.
