# Slug renderer: text weight via geometric glyph dilation (match CoreText)

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that will
help a fresh contributor.

## Purpose / Big Picture

Laban is a macOS terminal app with several swappable text-rendering backends. One
of them, the "slug" renderer, draws glyphs analytically on the GPU directly from
font outline curves (no pre-rasterized bitmap atlas for ordinary text). There is
a user setting called **text weight** (a slider in Settings) that is meant to
make on-screen text thinner or heavier.

Two problems exist with the slug renderer today, and this plan fixes both so the
user can actually control weight and so the default looks right:

1. At the default weight the slug renderer renders text **too thin** compared to
   the other renderers. The other renderers (called "software", "classic", and
   "gpuDriven" below) all draw glyphs with Apple's CoreText, which applies
   "stem darkening" (a slight thickening so thin strokes do not wash out). The
   slug renderer applies no equivalent thickening, so its text is visibly lighter,
   especially dark text on a light background.
2. The current partial fix (added in a prior session) only **darkens** existing
   antialiased edge pixels using a `pow(coverage, exponent)` curve. Darkening
   cannot widen a stroke: once an edge pixel is fully covered (alpha 1.0) there is
   nothing left to darken. Measurement shows this saturates well below CoreText's
   ink for dark-on-light text. The correct fix, used by FreeType and Adobe's font
   engine, is to **geometrically dilate the glyph outline** (grow the filled shape
   outward by a fraction of a pixel). That genuinely thickens strokes by turning
   on neighboring pixels.

After this change:

- With the slug renderer selected and **text weight at 1.0** (the default), text
  ink closely matches the "software" renderer (true CoreText) across common font
  sizes. "Ink" is defined precisely in Validation below; informally it is how much
  the text darkens the page.
- **Text weight 0.0** gives pure geometric coverage (no thickening, the thinnest,
  most shape-faithful look).
- **Text weight 2.0** gives a clearly heavier look than 1.0.
- The slider responds **live** while the slug renderer is active (it already does
  for the older vector renderer; both must work).

How to see it working: select the slug renderer, open Settings, and drag the
Text weight slider; text should get visibly heavier or lighter immediately, and
at 1.0 it should look about as heavy as the classic/software renderers. The
automated proof is a test that compares slug ink at weight 1.0 against the
software renderer ink and asserts they are within a tolerance (details below).

## Background knowledge you need (no external docs required)

You do not need to read any blog or paper. Everything required is here.

**Renderer backends.** The file
`Sources/LabanRenderer/RendererSelection.swift` defines an enum
`RendererSelection` with cases: `software`, `classic`, `gpuDriven`,
`vectorGlyph`, `slugGlyph`. The factory function `makeRendererBackend(...)` in
that same file builds the chosen backend. For this task:

- `software` = `SoftwareBackend` (`Sources/LabanRenderer/SoftwareBackend.swift`),
  a CPU renderer that draws glyphs with CoreText (`CTFontDrawGlyphs` /
  `CTLineDraw`) into a bitmap. It picks up macOS font smoothing, so it is our
  reference for "what CoreText ink looks like." It exposes rendered pixels via
  its `pngData` property.
- `classic` and `gpuDriven` are both `MetalRenderer`
  (`Sources/LabanRenderer/MetalRenderer.swift`), a GPU renderer that rasterizes
  glyphs into a texture atlas (also via CoreText, so also a CoreText reference).
- `vectorGlyph` = `VectorGlyphRenderer`
  (`Sources/LabanRenderer/VectorGlyphRenderer.swift`), an analytic GPU renderer
  that rasterizes each glyph's coverage in a fragment shader and then applies a
  `pow(coverage, exponent)` darkening for weight. **This plan does not change the
  vector renderer.**
- `slugGlyph` = `SlugGlyphRenderer`
  (`Sources/LabanRenderer/SlugGlyphRenderer.swift`), the analytic GPU renderer
  this plan changes.

**The text weight setting.**
`Sources/LabanRenderer/VectorTextWeightSettings.swift` is a small enum holding the
weight as a `Double` in `0 ... maxWeight`. `defaultWeight` is `1.0`. `maxWeight`
is currently `2.0`. `current()` reads it from `UserDefaults`,
`setCurrent(_:)` writes it and posts a `didChangeNotification`. The Settings UI
slider lives in `Sources/LabanApp/SettingsWindowController.swift` (search for
`vectorTextWeightSlider`). The live-apply observer that tells the active renderer
to refresh lives in `Sources/LabanApp/TerminalBitmapView.swift` (search for
`vectorTextWeightObserver`); it already calls `refreshTextWeight()` on either the
vector or the slug renderer. You do not need to change the observer or the slider
range for this plan; they are already wired.

**How the slug shader computes coverage (the part you will edit).** The Metal
shader source is `Sources/LabanRenderer/VectorGlyphShaders.metal`. The slug path
uses these symbols:

- A per-glyph-instance struct `SlugGlyphInstance` (GPU side) mirrored by a Swift
  struct `SlugGlyphGPUInstance` (in `SlugGlyphRenderer.swift`). The two must stay
  byte-compatible: same field order and sizes.
- A vertex function `slugGlyphVertex` and a fragment function
  `slugGlyphBandFragment`.
- A helper `slugGlyphReferenceCoverage(curves, bands, bandIndices, glyph, sample,
  unitsPerPixel)` that returns a coverage value in `[0,1]` for one sample point.

Inside `slugGlyphReferenceCoverage`, coverage is accumulated from per-edge
contributions. For each curve that crosses the sample row/column, the shader
solves for the crossing position in **device pixels** (a value called `roots`,
already multiplied by `pixelsPerUnit`), then adds or subtracts a term shaped like
`clamp(roots.X + 0.5, 0.0, 1.0)`. The `+ 0.5` centers the coverage ramp on the
pixel. Some terms are **added** to coverage (an edge where the filled region
begins) and some are **subtracted** (an edge where it ends). This is the lever we
use: shifting an additive term's ramp outward by `+d` pixels and a subtractive
term's ramp by `-d` pixels grows the filled region by `d` pixels on every side.
That is geometric dilation, done analytically and almost for free, without
moving any vertices or rebuilding any geometry.

There is also an unused experimental "Spike" code path in the same shader file
(`SlugSpikeInstance`, `slugGlyphVertexSpike`, and functions ending in `Spike`).
**Do not touch the Spike path.** It is not used by `SlugGlyphRenderer`.

**Current (to-be-removed) darkening.** In a prior session the slug instance got a
`coverageExponent` field and the fragment applied `pow(coverage, exponent)`. The
exponent came from `VectorGlyphRenderer.coverageExponent(foreground:background:
weight:)`. This plan **removes that from the slug path** and replaces it with
geometric dilation. Leave `VectorGlyphRenderer.coverageExponent` itself in place;
the vector renderer still uses it.

**Why darkening is not enough (measured).** Using the older `pow` approach, the
slug renderer's ink as a fraction of the software (CoreText) renderer's ink, at
16pt and 2x backing scale, grayscale, was:

```
darkOnLight: weight0=0.77  weight1=0.886  weight2=0.944   (needs ~weight 4 to reach 1.0, by crushing edges)
lightOnDark: weight0=0.913 weight1=0.952  weight2=0.977
midGray:     weight0=0.891 weight1=0.936  weight2=0.968
```

The dark-on-light case saturates: `pow` cannot reach parity because it only
deepens partial pixels. Geometric dilation reaches parity by actually widening
strokes. (You will re-measure during calibration; these numbers are context, not
acceptance targets.)

**The standard we are approximating (embedded, no external reading needed).**
FreeType and Adobe thicken the **outline**, by an amount that depends on the
on-screen stem width in pixels and tapers to zero for large text (big glyphs do
not need help). Their published curve, expressed as "extra width added per side
vs. stem width", is piecewise linear through these points (units: pixels):

```
stem width <= 0.5 px  -> add 0.40 px
stem width  = 1.0 px  -> add 0.275 px
stem width  = 1.667px -> add 0.275 px
stem width >= 2.333px -> add 0.0  px
```

The darkening is **color-independent** (same geometry regardless of foreground or
background). We do not have per-glyph stem widths handy, so we approximate the
size dependence using on-screen em size (pixels per em) as a proxy: small text
gets full dilation, large display text tapers off. The measured data above shows
CoreText still adds substantial ink even at a 32 px em (the weight0 gap at 16pt@2x
is large), so the taper must stay near full strength through roughly a 48 px em
and only ease off for larger sizes. You will pick the exact constants by
measurement (see Calibration). A single color-independent dilation will not make
every foreground/background case match CoreText exactly, because CoreText itself
differs by case; aim for the best single color-independent fit.

## Progress

- [ ] Shader: add a per-side `dilate` parameter to `slugGlyphReferenceCoverage`
      and apply it sign-correctly to the additive/subtractive coverage terms;
      relax the early-out and bounds-rejection guards by the dilation.
- [ ] Shader: rename the slug instance/vertex-out `coverageExponent` field to
      `dilation`, stop calling `pow`, pass `in.dilation` into every coverage call.
- [ ] Swift: rename `SlugGlyphGPUInstance.coverageExponent` to `dilation` (Float),
      compute per-run dilation in device pixels from weight and on-screen size,
      pass it into the instance, and grow the glyph quad padding by the dilation.
- [ ] Swift: remove the slug path's use of `VectorGlyphRenderer.coverageExponent`
      (leave the vector renderer's copy intact).
- [ ] Calibrate dilation constants by measurement so slug weight 1.0 ink is within
      ~5% of software ink across sizes 9, 11, 14, 18, 24 (scale 2) for all three
      foreground/background cases (best single color-independent fit; no case worse
      than about 0.92 or 1.10).
- [ ] Retarget `SlugWeightCoreTextParityTests` to compare slug weight 1.0 against
      the **software** renderer (within ~12%), and that weight 1.0 is at least as
      close to software as weight 0.
- [ ] Keep all existing slug and vector text-weight tests green.
- [ ] Delete the throwaway calibration probe test file once constants are final.
- [ ] Update the slug text-weight bullet in `AGENTS.md` to describe geometric
      dilation calibrated to the software/CoreText renderer.
- [ ] Build both targets and run the test filters in Validation; all green
      (except one unrelated pre-existing failure, see Surprises).

## Context and Orientation

You are working in a git **worktree** at
`/Users/rrj/wrk/laban.worktrees/slugger`. Two repository rules matter here:

1. The Serena editing MCP tools write to the wrong checkout inside a worktree and
   can corrupt it. **Edit files only with the native file Read/Edit/Write tools.**
   Do not use Serena's symbolic edit tools.
2. Never run two builds at once against this worktree's `.build/` directory: a
   second `swift build` can relink the app binary after the first ad-hoc-signs it
   and cause spurious signature failures. Before any `swift build` or
   `swift test`, run `pgrep -fl "swift build"` and proceed only when it prints
   nothing (or only your own just-launched process).

Build and test commands (run from the worktree root
`/Users/rrj/wrk/laban.worktrees/slugger`):

- Compile a module: `swift build --target LabanRenderer` and
  `swift build --target LabanApp`. You do not need `scripts/build-app` for this
  task (that builds the full app bundle; compiling the two targets is enough to
  prove the code is correct, and the tests exercise the renderer headlessly).
- Run tests by name filter, for example:
  `swift test --filter "SlugGlyphCorrectnessTests"`.

Writing-style rule for this repo: **do not use em-dashes** in code comments,
commit messages, or docs. Rephrase with a colon, parentheses, or two sentences.

Files you will edit:

- `Sources/LabanRenderer/VectorGlyphShaders.metal` (the shader).
- `Sources/LabanRenderer/SlugGlyphRenderer.swift` (the slug renderer Swift side).
- `Tests/LabanRendererTests/SlugWeightCoreTextParityTests.swift` (retarget).
- `AGENTS.md` (one bullet).

Files you will create then delete:

- A temporary calibration test under `Tests/LabanRendererTests/` (see
  Calibration). Delete it when constants are final.

Files you must NOT change:

- `Sources/LabanRenderer/VectorGlyphRenderer.swift` (keep `coverageExponent`).
- The Spike code path in the shader.
- `Sources/LabanApp/TerminalBitmapView.swift` and
  `Sources/LabanApp/SettingsWindowController.swift` (already wired; the observer
  already calls `slug.refreshTextWeight()` and the slider range is already 0..2).

## Plan of Work

### Step 1: Shader coverage dilation

Open `Sources/LabanRenderer/VectorGlyphShaders.metal`. Find
`slugGlyphReferenceCoverage`. It has two blocks: a horizontal block accumulating
`xcov` and a vertical block accumulating `ycov`.

Add a trailing parameter `float dilate` to the function signature. `dilate` is the
per-side dilation in **device pixels** (the same units as `roots`, which are
already in device pixels). Then apply it sign-correctly:

- In the horizontal block:
  - The term that does `xcov += clamp(roots.x + 0.5, 0.0, 1.0)` is additive.
    Change it to `clamp(roots.x + 0.5 + dilate, 0.0, 1.0)`.
  - The term that does `xcov -= clamp(roots.y + 0.5, 0.0, 1.0)` is subtractive.
    Change it to `clamp(roots.y + 0.5 - dilate, 0.0, 1.0)`.
- In the vertical block the signs are mirrored:
  - `ycov -= clamp(roots.x + 0.5, ...)` is subtractive: use `... - dilate`.
  - `ycov += clamp(roots.y + 0.5, ...)` is additive: use `... + dilate`.

Rule of thumb to keep straight: whichever term **adds** to coverage gets
`+ dilate`; whichever **subtracts** gets `- dilate`. Growing both edges of a span
outward widens a stem by about `2 * dilate` pixels total.

Leave the `xwgt` / `ywgt` proximity-weight lines (the
`clamp(1.0 - abs(roots.X) * 2.0, 0.0, 1.0)` expressions) using the **undilated**
roots. They control antialias edge weighting, not fill, and should not move.

Relax the loop early-out so dilation-relevant curves are not skipped. Each block
has a guard like `if (max(max(curve.pN.x, ...)) * pixelsPerUnit.x < -0.5) break;`.
Change the `-0.5` to `-(0.5 + dilate)` in both blocks.

Relax the top-of-function bounds rejection. It currently rejects samples outside
`boundsMin/Max +/- unitsPerPixel`. The dilation in glyph units is
`dilate * unitsPerPixel` (because `unitsPerPixel` is glyph-units per device pixel
and `dilate` is in device pixels). Expand the four comparisons to use
`unitsPerPixel * (1.0 + dilate)` instead of `unitsPerPixel`.

Now update the slug instance plumbing in the same file:

- In struct `SlugGlyphInstance`, rename field `coverageExponent` to `dilation`
  (still a `float`, same position and size).
- In `SlugGlyphVertexOut`, rename `coverageExponent` to `dilation`.
- In `slugGlyphVertex`, copy `instance.dilation` to `out.dilation` (replacing the
  old `coverageExponent` copy).
- In `slugGlyphBandFragment`:
  - Remove the `float exponent = ...` line and all `pow(..., exponent)` wrapping.
  - Pass `in.dilation` as the new `dilate` argument to every
    `slugGlyphReferenceCoverage(...)` call (the grayscale call and the three
    r/g/b subpixel calls), and use the returned coverage directly.

### Step 2: Swift instance field and per-run dilation

Open `Sources/LabanRenderer/SlugGlyphRenderer.swift`.

- In the private struct `SlugGlyphGPUInstance`, rename `var coverageExponent:
  Float = 1` to `var dilation: Float = 0`. The field sits between
  `glyphIndex: UInt32` and the padding fields; a `Float` is 4 bytes like the
  `UInt32` it follows, so the struct layout and the matching `SlugGlyphInstance`
  in the shader stay byte-compatible. Keep the existing padding fields.
- Keep the existing `textWeight` stored property and `refreshTextWeight()`
  method (they read `VectorTextWeightSettings.current()`).
- In `appendGlyphRun(...)`, delete the line that computes
  `let coverageExponent = VectorGlyphRenderer.coverageExponent(...)`. Replace it
  with a per-run dilation in device pixels computed by a new helper (Step 3),
  using the on-screen em size. Pass that value into the
  `SlugGlyphGPUInstance(...)` initializer as `dilation:` (replacing the old
  `coverageExponent:` argument).
- The on-screen pixels-per-em for the active run is
  `activeAtlas.pointSize * scale` (device pixels per em). Do not multiply by
  `gestureZoom`; live pinch-zoom is a transient uniform and geometry is rebaked on
  commit, so per-run dilation should track the committed size only.
- Grow the glyph quad so the dilated shape is not clipped. The code computes
  `localPixelPad = CGFloat(1) / max(pointScale * scale, .ulpOfOne)` (one device
  pixel of padding expressed in glyph units). Change the numerator `1` to
  `(1 + perSideDilatePx)` where `perSideDilatePx` is this run's per-side dilation
  in device pixels. Use the resulting padded `localMin` / `localMax` for both the
  quad size and the instance's `localMin` / `localMax`, exactly as today.
- The `coverageMask(...)` method (a debug/test path) builds a
  `SlugGlyphGPUInstance` directly. Leave its `dilation` at the default `0` so the
  CPU-oracle parity tests (which call `coverageMask`) are unaffected.

### Step 3: The dilation function (parametric, then calibrated)

Add a small function (private static on `SlugGlyphRenderer`, or a helper in
`VectorTextWeightSettings` if you prefer) that maps `(weight, ppemPx)` to a
**per-side** dilation in device pixels, where `ppemPx = pointSize * scale`:

```
perSideDilatePx(weight, ppemPx):
    if weight <= 0: return 0
    amountPx = baseAmountPx * taper(ppemPx)        // full per-side amount at weight 1
    return weight * amountPx
```

`baseAmountPx` is a constant device-pixel amount (start near 0.35 and adjust by
measurement). `taper(ppemPx)` is 1.0 for small/medium text and eases toward a
small floor for large text. A reasonable starting taper:

```
taper(ppemPx) = clamp(1 - (ppemPx - ppemFull) / (ppemNone - ppemFull), minTaper, 1)
```

with starting values `ppemFull = 48`, `ppemNone = 160`, `minTaper = 0.15`. These
are starting points; you will tune `baseAmountPx`, `ppemFull`, `ppemNone`,
`minTaper` during Calibration. Make the final values named Swift constants with a
short comment that says they approximate FreeType/Adobe stem darkening via
geometric dilation and were calibrated to the software (CoreText) renderer. No
em-dashes in the comment.

### Step 4: Calibration (measure, do not guess)

Create a temporary calibration test, for example
`Tests/LabanRendererTests/SlugDilationCalibrationProbe.swift`. It should, for
each point size in {9, 11, 14, 18, 24} at backing scale 2, in grayscale, render
the same text with:

- the software renderer (`SoftwareBackend`), and
- the slug renderer at weight 1.0,

and print the "ink" of each plus the ratio slug/software. Use these three
foreground/background cases:

```
darkOnLight: fg 0x18222AFF, bg 0xF6EEDBFF
lightOnDark: fg 0xFFFFFFFF, bg 0x000000FF
midGray:     fg 0x808080FF, bg 0x202020FF
```

"Ink" = sum over all pixels of `abs(pixelLuma - bgLuma)`, where `luma =
(r+g+b)/3` and `bgLuma` is computed from the background color. Render onto a
surface a few hundred pixels wide so a short probe string (for example
`"Hglo08B/N weight"`) fits.

How to drive each backend headlessly (patterns that already work in this repo;
see the existing `Tests/LabanRendererTests/SlugWeightSoftwareProbe.swift` if it is
still present, and `Tests/LabanRendererTests/SlugGlyphRendererTests.swift`):

- Software: `let b = SoftwareBackend(fontAtlas: FontAtlas(pointSize: s),
  pixelWidth: W, pixelHeight: H, scale: 2)`, then `b.render(commands, damage:
  .full)`, then decode `b.pngData`.
- Slug: `let r = SlugGlyphRenderer(fontAtlas: FontAtlas(pointSize: s), pixelWidth:
  W, pixelHeight: H, scale: 2)`; set `r.waitForFrameCompletion = true`,
  `r.presentsToLayer = false`, `r.setSubpixelLayout(.grayscale)`; set the weight
  via `VectorTextWeightSettings.setCurrent(1.0)` then `r.refreshTextWeight()`;
  `r.render(commands, damage: .full)`; decode `r.pngData`. Save and restore the
  `VectorTextWeightSettings` default at the end of the test so you do not pollute
  other tests' `UserDefaults`.
- Build the `commands` as a background `.rect` filling the text area followed by a
  `.glyphRun(origin:text:foreground:background:attributes:source:)`. Copy the
  exact command shape from an existing slug test.

Run it: `swift test --filter "SlugDilationCalibrationProbe"`. Read the printed
ratios. Adjust `baseAmountPx` and the taper constants, rebuild, rerun. Iterate
until slug weight 1.0 is within about 5% of software across the size sweep for all
three cases as a best single color-independent fit (no case worse than ~0.92 or
~1.10). Expect dark-on-light to be the hardest case.

Sanity checks to confirm the sign is correct before tuning magnitude: with the
probe, also print slug ink at weights 0, 1, 2 for one size and confirm ink
**increases** monotonically with weight. If higher weight reduces ink or visibly
distorts glyphs, the additive/subtractive assignment in Step 1 is flipped; fix it
before continuing.

When the constants are final, **delete the calibration probe file** (and delete
`Tests/LabanRendererTests/SlugWeightSoftwareProbe.swift` if it is still present;
it is a leftover scratch tool, not a real test).

### Step 5: Retarget the parity test

Open `Tests/LabanRendererTests/SlugWeightCoreTextParityTests.swift`. It currently
compares slug weight 1.0 to the **vector** renderer. Change it to compare against
the **software** renderer (true CoreText):

- For each of the three foreground/background cases at one representative size
  (for example 16pt at scale 2, grayscale): assert slug weight 1.0 ink is within
  about 12% of software ink (ratio in `0.88 ... 1.12`).
- Also assert that weight 1.0 is at least as close to software as weight 0 is
  (`abs(inkWeight1 - software) <= abs(inkWeight0 - software) + smallSlack`).
- Update the test's doc comment to say the slug renderer uses geometric dilation
  calibrated to the software (CoreText) renderer, not the vector exponent.

### Step 6: Docs

In `AGENTS.md`, find the bullet under "Hard Rules" that currently says the slug
renderer reuses the vector renderer's CoreText-calibrated `coverageExponent`.
Replace it with a concise bullet describing the new reality: the slug renderer
thickens text by geometric dilation of its analytic coverage (the FreeType/Adobe
stem-darkening approach), color-independent and size-aware, calibrated so weight
1.0 matches the software/CoreText renderer and weight 2.0 is extra heavy; the
vector renderer still uses `coverageExponent`. No em-dashes.

## Concrete Steps

Run all commands from `/Users/rrj/wrk/laban.worktrees/slugger`.

1. Confirm no concurrent build, then compile after each edit batch:

   ```
   pgrep -fl "swift build"        # expect no output (or only your own)
   swift build --target LabanRenderer
   swift build --target LabanApp
   ```

2. Calibrate (Step 4), iterating build + run:

   ```
   swift test --filter "SlugDilationCalibrationProbe"
   ```

   Expected: a table of `software=… slug@1=… ratio=…` lines. Tune constants until
   ratios cluster near 1.0 (within ~5%).

3. After retargeting tests and finalizing constants, run the suites:

   ```
   swift test --filter "SlugGlyphCorrectnessTests"
   swift test --filter "SlugWeightCoreTextParityTests"
   swift test --filter "VectorTextWeightTests"
   ```

   Expected: all pass.

## Validation and Acceptance

Acceptance is behavioral and test-backed.

1. **Build.** `swift build --target LabanRenderer` and
   `swift build --target LabanApp` both succeed with no errors.

2. **Weight changes ink (regression already in the suite).**
   `SlugGlyphCorrectnessTests.testSlugTextWeightThickensRenderedInk` passes:
   slug ink at weight 1 exceeds ink at weight 0. Run:
   `swift test --filter "SlugGlyphCorrectnessTests"` and expect all tests pass,
   including the CPU-oracle parity, geometry-reuse, gesture-zoom, subpixel,
   decoration, gamma, and clear-color tests (these prove dilation did not break
   shape correctness, since `coverageMask` uses dilation 0).

3. **Weight 1.0 matches CoreText (the headline acceptance).**
   `SlugWeightCoreTextParityTests` passes with the retargeted assertions: for each
   foreground/background case, slug weight 1.0 ink is within ~12% of the software
   renderer ink, and weight 1.0 is at least as close to software as weight 0.
   Run: `swift test --filter "SlugWeightCoreTextParityTests"`.

4. **Calibration evidence.** The calibration probe (before you delete it) printed
   slug-weight-1.0 / software ink ratios within ~5% across sizes 9, 11, 14, 18, 24
   at scale 2 for all three cases (best single color-independent fit). Paste the
   final ratio table into Artifacts and Notes below.

5. **Vector renderer untouched.** `VectorTextWeightTests` still passes:
   `swift test --filter "VectorTextWeightTests"`.

6. **Manual (optional but recommended).** Build and install the app
   (`scripts/install-app`), select the slug renderer, and drag the Text weight
   slider in Settings: text should thicken/thin live, and at 1.0 should look about
   as heavy as the classic renderer. Do not launch the app bundle from the shell;
   quit and relaunch Laban yourself to pick up a new build.

There is one known pre-existing, unrelated test failure (see Surprises): do not
treat it as caused by this work, and do not try to fix it here.

## Idempotence and Recovery

All edits are to source files and are safe to re-run: re-applying the same edit is
a no-op once present. The calibration probe is additive and deleted at the end.
If a build fails after the shader edit, the most likely cause is a flipped
additive/subtractive sign or a forgotten rename (`coverageExponent` to
`dilation`) in one of the four shader sites (struct, vertex-out, vertex copy,
fragment calls) or the Swift struct; re-check each against Step 1 and Step 2. If
glyphs render distorted or weight reduces ink, the sign is flipped; swap the
`+ dilate` / `- dilate` assignments.

If you need to confirm the working tree only contains intended changes, run
`git status --porcelain` and `git diff --stat`. Do not commit unless the human
asks; leave changes in the working tree.

## Surprises & Discoveries

- Observation: `pow(coverage, exponent)` darkening saturates for dark-on-light
  text and cannot reach CoreText ink without crushing edges (needs ~weight 4).
  Geometric dilation is required to genuinely thicken strokes.
  Evidence: measured ink ratios at 16pt@2x grayscale, dark-on-light: weight1
  0.886, weight2 0.944 (still below 1.0); see Background.
- Observation: there is a pre-existing, unrelated flaky/failing test,
  `VectorGlyphSizeSweepTests.testGPUWindingMatchesOracleAcrossSizes`, that fails
  on a pristine `HEAD` checkout independent of this work. Ignore it for this plan;
  do not attempt to fix it here.

## Decision Log

- Decision: Use analytic span dilation inside `slugGlyphReferenceCoverage` rather
  than vertex displacement (the Slug "dynamic dilation" technique) or a
  post-coverage curve.
  Rationale: the shader already computes per-edge device-pixel distances, so
  shifting the coverage ramps is nearly free and needs no new per-vertex data,
  no geometry rebuild, and no change to the band/curve buffers. It directly
  widens strokes (real emboldening), which a coverage exponent cannot do.
  Date/Author: 2026-06-30, plan author.

- Decision: Calibrate weight 1.0 against the `software` renderer (CoreText) and
  keep dilation color-independent.
  Rationale: software/classic/gpuDriven all render via CoreText and are the
  user's reference for "normal" weight; FreeType/Adobe stem darkening is also
  color-independent. A single color-independent amount cannot match every
  foreground/background case exactly because CoreText itself differs by case, so
  we target the best single fit.
  Date/Author: 2026-06-30, plan author.

## Review Gate

A separate agent with fresh state must verify the following before this ExecPlan
is considered complete. The executing agent must not mark the plan done until this
gate passes. See "Review gate and review-fix loop" in `PLANS.md`.

- [ ] `grep -n "pow(" Sources/LabanRenderer/VectorGlyphShaders.metal` shows no
      `pow(` inside `slugGlyphBandFragment` (the slug fragment no longer applies a
      coverage exponent). Other shader functions may still use `pow`.
- [ ] `grep -n "coverageExponent" Sources/LabanRenderer/SlugGlyphRenderer.swift`
      returns nothing (the slug instance field is renamed to `dilation` and the
      slug path no longer references the exponent helper).
- [ ] `grep -n "coverageExponent" Sources/LabanRenderer/VectorGlyphRenderer.swift`
      still returns the `coverageExponent` definition (vector path unchanged).
- [ ] `grep -n "dilation" Sources/LabanRenderer/VectorGlyphShaders.metal` shows
      the field in `SlugGlyphInstance` and `SlugGlyphVertexOut` and its use in the
      fragment's coverage calls.
- [ ] From the worktree root, `pgrep -fl "swift build"` is clear, then
      `swift build --target LabanRenderer` and `swift build --target LabanApp`
      both exit 0.
- [ ] `swift test --filter "SlugWeightCoreTextParityTests"` exits 0 and the test
      compares against the software renderer (grep the test file for
      `SoftwareBackend`; expect a hit).
- [ ] `swift test --filter "SlugGlyphCorrectnessTests"` exits 0 (all pass).
- [ ] `swift test --filter "VectorTextWeightTests"` exits 0 (vector path intact).
- [ ] The calibration probe file and any `SlugWeightSoftwareProbe.swift` are
      deleted: `ls Tests/LabanRendererTests/SlugDilationCalibrationProbe.swift
      Tests/LabanRendererTests/SlugWeightSoftwareProbe.swift 2>&1` reports both as
      not found.
- [ ] `AGENTS.md` slug text-weight bullet mentions geometric dilation and the
      software/CoreText calibration: `grep -n "dilation" AGENTS.md` returns a hit
      in that bullet, and no em-dash characters were introduced.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Artifacts and Notes

Record here, when execution runs:

- The final calibrated constants (`baseAmountPx`, `ppemFull`, `ppemNone`,
  `minTaper`, and the per-side dilation formula).
- The final calibration ratio table (slug weight 1.0 / software ink) across sizes
  9, 11, 14, 18, 24 for the three cases.
- The list of files changed and `git diff --stat` output.

## Interfaces and Dependencies

At the end of this plan these must hold:

- Shader `Sources/LabanRenderer/VectorGlyphShaders.metal`:
  - `float slugGlyphReferenceCoverage(constant VectorGlyphCurve*, constant
    SlugGlyphBand*, constant uint*, SlugGlyph, float2 sample, float2
    unitsPerPixel, float dilate)` (note the new trailing `dilate`).
  - `SlugGlyphInstance` and `SlugGlyphVertexOut` have a `float dilation` field
    (no `coverageExponent`).
  - `slugGlyphBandFragment` passes `in.dilation` to each coverage call and applies
    no `pow`.
- Swift `Sources/LabanRenderer/SlugGlyphRenderer.swift`:
  - `SlugGlyphGPUInstance` has `var dilation: Float = 0` (no `coverageExponent`).
  - A documented dilation function mapping `(weight, ppemPx)` to per-side device
    pixels, with named calibrated constants.
  - `refreshTextWeight()` and the `textWeight` property remain.
- The vector renderer and its `coverageExponent` are unchanged.
- `Tests/LabanRendererTests/SlugWeightCoreTextParityTests.swift` compares slug
  weight 1.0 against `SoftwareBackend`.
