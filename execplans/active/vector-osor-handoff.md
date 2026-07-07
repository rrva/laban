# Handoff — Vector OSOR text renderer (headless Mac mini → MacBook M2 Max)

Session-transition note. **Source of truth is the ExecPlan:**
`execplans/active/vector-osor-subpixel-scroll.md` (maintained per `PLANS.md`).
This doc just captures where we are and what the hardware switch unblocks.

## Progress

- [x] M0 winding stability completed.
- [x] M1 gamma + text-weight setting completed; the user accepted default text weight `1.0`.
- [x] M2 display robustness completed except automatic scaled-mode detection, which is deferred until on-device display validation.
- [x] M3 subpixel calibration completed except 2D/non-stripe calibration, which is deferred until external non-stripe display validation.
- [ ] M4 sub-pixel-offset glyph caching is next.
- [ ] M5 atlas eviction + per-frame sample budget is pending.
- [ ] M6 smooth sub-pixel scroll plumbing + end-to-end validation is pending.

## Where we are

- Branch: `codex/vector-glyph-renderer`. Pushed to `origin`.
- Goal: bring the vector glyph renderer to a full OSOR pipeline
  (osor.io/text) — Retina-crisp, display-robust, with smooth sub-pixel
  scrolling and opt-in subpixel AA.

### Commits this effort (newest last)
- `af4380d` — numerically stable winding (Vieta + FMA); fixed size-dependent
  garbling of straight strokes (`/ N X …`).
- `55856c3` — the ExecPlan.
- `76a5d19` — M1: gamma-correct linear-light compositing (sRGB target,
  vector-only).
- `deb16d9` — M1: **text weight** is a live user setting (slider; 0 = thin
  geometric, 1 = CoreText-ish; default 1.0).
- `d4db52e` — M2: fringe-safe subpixel auto-policy + effective-layout reporting.
- `1d3e12f` — M3: fringing-metric gate + OSOR extreme-coverage clamp.

### Milestone status
- M0 winding stability — done.
- M1 gamma + text-weight setting — done (user accepted default 1.0).
- M2 display robustness — done **except** automatic scaled-mode detection
  (deferred, see below).
- M3 subpixel calibration — done (overlap/bleed proven; clamp added) **except**
  2D non-stripe calibration (deferred).
- M4 sub-pixel-offset glyph caching — **next**.
- M5 atlas eviction + per-frame sample budget — pending.
- M6 smooth sub-pixel scroll plumbing + end-to-end — pending.

## Working agreement (carry forward)
- **Other renderers are NOT oracles.** Vector may depart from classic/software/
  gpu-driven. Gates assert against ground-truth math, never against another
  renderer.
- **Grayscale is the default**; subpixel AA is opt-in (macOS dropped subpixel
  smoothing in 2018; Retina wants grayscale). See ExecPlan "Display reality".
- **Text weight is a taste setting** (Settings → Text weight slider), default
  1.0. User finds the thin look elegant but shipped default stays 1.0.
- **Pause at each milestone gate for manual visual inspection** before moving on.
  Alert with the macOS `say` command — this now works again on the MacBook (it
  was useless on the headless mini, so reports went to chat only).
- Commit + push per milestone with single-line reason messages. Build/install
  via `./scripts/build-app` and `./scripts/install-app` (the running app is
  single-instance: quit and relaunch yourself; never `open` the bundle).

## What the hardware switch unblocks
On the headless mini there was no display and AppKit display APIs / visuals
couldn't be validated. On the MacBook (14" M2 Max, Liquid Retina XDR, scale 2,
RGB-stripe subpixels) the following become doable:

1. **M2 deferred — scaled-mode detection.** Wire `setDisplayDownsampled` from
   `NSScreen` (compare backing-store pixels to native panel resolution) in
   `TerminalBitmapView.recreateSurface`. Validate by switching System Settings →
   Displays between "Default" and "More Space" and confirming `/debug/render`
   `vectorSubpixelLayout` reports `grayscale` when downsampled. The pure policy
   `VectorSubpixelLayout.effective(...)` is already tested; only the AppKit
   detector + its on-device validation remain.
2. **M3 deferred — 2D / non-stripe subpixel calibration.** Add vertical
   (y-range) fields to the calibration editor and presets for non-stripe panels.
   This is the genuine "beat CoreText" niche (CoreText can't adapt to OLED
   subpixel layouts). Needs an external non-stripe monitor to validate.
3. **Per-gate visual inspection** on the real panel for M4–M6, especially M6
   (smooth sub-pixel scroll must glide, not jump, and stay sharp at rest).

## Next: M4 (sub-pixel-offset glyph caching)
Prereq for smooth scrolling. Plan (detail in ExecPlan):
- Add a quantized sub-pixel offset (OSOR u0.8) to `VectorGlyphMaskAtlas.Key`.
- Bias the accumulate `origin` by the fractional offset so the GPU sample grid
  matches the on-screen phase; place the quad at the true fractional position.
- Static text keeps offset 0 (one cache entry, no regression).
- Gate (headless-capable): extend the size sweep to several fractional phases;
  the accumulate path vs the supersampled oracle must agree (gross-pixel ~0) at
  each phase. Plus a test that two phases produce distinct masks/entries.

## Validation and Acceptance
From repo root `/Users/rrj/wrk/laban`:
- Autonomous gates added this effort:
  `swift test --filter VectorGlyph` (winding, size/phase sweep, gamma, parity),
  `swift test --filter VectorSubpixel` (policy, fringing, layout),
  `swift test --filter VectorTextWeight`, `swift test --filter GlyphCurveStore`.
  Each new gate fails before its milestone's change and passes after.
- Build + install: `./scripts/build-app && ./scripts/install-app`, then quit and
  relaunch Laban; Renderer menu → Vector glyph.
- Don't run two builds against the same `.build/` concurrently (it invalidates
  the ad-hoc signature). Confirm `pgrep -fl "swift build"` is empty first.

## Files (most-touched)
- `Sources/LabanRenderer/VectorGlyphRenderer.swift` — backend, masks, weight,
  effective-layout policy use.
- `Sources/LabanRenderer/VectorGlyphShaders.metal` — winding, accumulate kernel,
  gamma/stem-darkening, extreme clamp.
- `Sources/LabanRenderer/VectorSubpixelLayout.swift` — presets + `effective(...)`
  auto-policy.
- `Sources/LabanRenderer/VectorTextWeightSettings.swift` — text-weight setting.
- `Sources/LabanApp/SettingsWindowController.swift` — Text weight slider.
- `Sources/LabanApp/TerminalBitmapView.swift` — setting observers + resize.
- `Tests/LabanRendererTests/VectorGlyph*Tests.swift`, `VectorSubpixel*Tests.swift`,
  `VectorTextWeightTests.swift` — gates.
