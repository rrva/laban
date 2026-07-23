# slug-glyph-effects prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

How do the per-glyph keystroke-impulse tunings feel in real-time motion, and
which constants are worth carrying into
`execplans/active/per-glyph-animation-channel.md`? Built with `three-slug`
(JSlug's THREE.SlugText GPU text renderer) instead of Laban's own Metal
pipeline, so the loop is edit-shader → reload-browser instead of
edit-Metal → rebuild-Swift-app.

## How to run

```sh
cd prototype/slug-glyph-effects
npm install
npm start
# → http://localhost:8737/?variant=A
```

Open `?variant=A`, `?variant=B`, or `?variant=C` (or use the `‹ ›` pager /
Left-Right arrow keys to cycle at runtime — the URL updates and the page
reloads so state stays shareable).

Controls: `T` type line, `K` keystroke-demo (types a fake shell command char
by char), `B` fire a bell shake, `A` toggle auto-demo, `E` toggle effects
on/off, `M` toggle reduceMotion. The HUD (top-left) shows display-link
run/park state, live-effect count, last effect kind, and the active variant.

## Variants

| Key | Label | scaleX₀ | scaleY₀ | tilt₀ | decay | easing | bell px |
|---|---|---|---|---|---|---|---|
| A | plan contract | 0.55 | 1.10 | 0.07 rad | 130 ms | easeOutBack (c1=1.70158, c3=2.70158) | 8 |
| B | subtle | 0.78 | 1.04 | 0.025 rad | 110 ms | easeOutCubic, no overshoot | 5 |
| C | punchy showcase | 0.40 | 1.28 | 0.12 rad | 170 ms | easeOutBack (c1=2.30, c3=3.30) | 14, auto-bell every 4th line |

Variant A's uniforms are wired straight from `timeline.js`'s exported
constants (not hand-copied), so A *is* `GlyphEffectTimeline.swift`'s current
committed contract — not an approximation of it.

## Bug found and fixed: new content was silently invisible

**First verification pass (headless-only, no real browser) reported "zero
errors, all good" and was wrong.** `mcp__claude-in-chrome__*` was
disconnected at first; a throwaway Playwright script checked console errors,
page errors, and HUD `PARKED` state, and all looked clean. But it only ever
screenshotted the *seeded* content — it never actually confirmed new,
dynamically-typed text rendered. When Chrome reconnected and a human-shaped
click-through happened, newly typed/pushed lines were invisible: the HUD
correctly reported `live: N` and cycled through kinds, but zero new pixels
ever appeared, and after a window resize existing text visually detached
from the HUD region.

Root cause, found via `page.evaluate` state inspection: `SlugGeometry`
(`node_modules/three-slug/src/SlugGeometry.js`) has two write paths.
`addGlyph()` writes `aScaleBias`/`aGlyphBandScale`/`aBandMaxTexCoords` on the
**CPU-side** typed arrays but does **not** flag them `needsUpdate` for GPU
re-upload — only the library's own `addText()` convenience method calls the
separate `updateBuffers()` that does that. `main.js`'s `rebuildGeometry()`
calls `geometry.clear()` + `geometry.addGlyph()` directly (needed for the
per-glyph animation/color attributes `addText()` doesn't support) and never
called `updateBuffers()`. Effect: the very first frame uploads correctly
(three.js always uploads on an attribute's first GPU touch regardless of the
flag), then every later `rebuildGeometry()` — from typing, the bell, or a
resize — updates the JS-side array but the GPU buffer stays frozen at
whatever the first frame uploaded. New glyphs point at never-written (zero)
buffer memory → invisible. Existing glyphs on resize keep their *old*
window's screen position while the camera reprojects to the *new* window
size → visible drift, which is what read as "HUD renders over the terminal
text" on resize.

Fix (`main.js`, `rebuildGeometry()`): call `geometry.updateBuffers()`
alongside the existing `aGlyphColor`/`aEffect` `needsUpdate = true` lines.
One call, confirmed via live browser click-through (typing and bell both
render now) and via `node verify.mjs`'s new pixel-diff check (below).

This is the single most important integration lesson from this prototype:
**`three-slug`'s two write paths (`addGlyph` vs `addText`) have different
GPU-upload contracts, and nothing errors or warns when you use the lower-level
one incompletely** — the CPU-side data, `instanceCount`, and HUD/JS state all
look correct while the GPU renders stale or zero geometry. Screenshotting
only the page's initial/seeded state cannot catch this class of bug.

## What was verified

Live browser click-through (`mcp__claude-in-chrome__*`, once reconnected)
plus a headless-Chromium regression script (`verify.mjs`, Playwright,
installed locally as a devDependency — not part of the demo, just this
check):

- All three variants load, the WebGL2 context initializes, and the font
  generates from the bundled `JetBrainsMono-Regular.ttf` (no `#loading`
  overlay stuck).
- Zero console errors, zero page errors, on all three variants.
- Glyphs rasterize with correct per-run colors, **including newly
  typed/pushed lines** (screenshots: `verify-shots/variant-{A,B,C}-
  {idle,typing,bell}.png` — e.g. `Sources` in blue, `main` in magenta,
  prompt `$` in green, matching `main.js`'s `C.*` palette). `verify.mjs` now
  hashes a pixel crop of the row the first demo line lands in, idle vs.
  post-typing, and fails if the hashes are identical — this is the check
  that would have caught the bug above; it did, when sanity-tested against a
  reverted copy of the fix.
- Keystroke-impulse and bell-shake can be live on different cells
  simultaneously and don't clobber each other's per-cell state (confirmed
  live: HUD's `last kind` flips back to `1` after a bell because the
  still-running keystroke-demo loop keeps stamping new characters — this is
  the *entire point* of the per-cell `{kind, start}` channel, and it's easy
  to get wrong).
- The rAF loop parks (HUD → `link: PARKED`) once no cell is animating, for
  all three variants — this is the ADR 0018 idle-park behavior mirrored from
  `TerminalIdlePolicy`/`FrameWakeSource.glyphEffect`, and the prototype
  proves the *timeline math* parks correctly, independent of Laban's actual
  display-link wiring.
- Window resize: attempted via the browser tool's `resize_window`, but in
  this remote/automated Chrome session it only changed the OS window frame
  (`outerWidth`/`outerHeight`), not the page viewport (`innerWidth`/
  `innerHeight` never changed) — so the resize path specifically could not
  be mechanically re-exercised end-to-end after the fix. The fix addresses
  the same root cause (stale GPU buffers vs. recomputed CPU positions) that
  a resize-triggered `rebuildGeometry()` call hits too, so it should resolve
  the reported resize glitch, but this wants a real manual window resize to
  fully confirm.

Not verified: real-time perceived *feel* of the easing curves. That is
inherently a live-motion judgment a static screenshot can't answer — someone
needs to run `npm start`, watch each variant with `K`/`B`/`A`, and fill in
the Verdict section below.

## Where three-slug's API forced divergence from the Metal evaluation math

- **`addGlyph()` vs. `addText()` have different GPU-upload contracts, and
  nothing warns you about it — see "Bug found and fixed" above.** Metal has
  no such split: `SlugGlyphInstance` fields are written and the whole
  instance buffer is one upload per frame, so there's no equivalent
  low-level/convenience-path divide to fall into.
- **Injection is textual splicing, not a first-class hook.** `injectSlug()`
  owns `material.onBeforeCompile`; there's no per-effect extension point, so
  `main.js` wraps the assigned closure and does string `.replace()` on two
  anchor lines (`flat out uvec4 vBandMaxTexCoords;` and the line that assigns
  it) to splice the effect GLSL in after `transformed` is computed but before
  `vector_to_ndc`. This is equivalent to Metal's `slugGlyphMotionVertex`
  running before the NDC projection, but it's anchor-line-fragile — a
  three-slug version bump that reflows `SlugMaterial.js`'s vertex shader
  string would silently stop matching and the effect would just not apply
  (no error, `.replace()` on a missing string is a no-op).
- **The pivot center comes from three-slug's own `aScaleBias.zw`
  (`cx = x + width/2`, `cy = y + height/2`, set in `SlugGeometry.addGlyph`),
  confirmed by reading `node_modules/three-slug/src/SlugGeometry.js` — not
  reconstructed from font metrics.** This matches the Metal side's
  `originPx + sizePx * 0.5` pivot, so the port could reuse the host library's
  own per-glyph center exactly instead of recomputing it, which is a
  meaningfully closer fidelity match than expected going in.
- **No native per-instance "extra" attribute slot.** `SlugGeometry` ships a
  fixed attribute set (`aScaleBias`, band/glyph-scale, etc.); the animation
  channel (`aEffect`: kind + start) and per-glyph color (`aGlyphColor`) are
  bolted on as two more raw `InstancedBufferAttribute`s added directly to the
  geometry after construction, with matching `in` declarations spliced into
  the vertex shader. Laban's Metal path has `effectKind`/`effectStart` as
  named fields in `SlugGlyphInstance` from the start (same struct as
  color/position), so there's no separate attribute-registration step —
  that's a build-system difference (Swift struct vs. runtime
  `setAttribute()` call), not a math one.
- **Color is not a native three-slug attribute either.** Same treatment as
  `aEffect`: `aGlyphColor` is a bolted-on `InstancedBufferAttribute`, spliced
  into the fragment shader at `#include <color_fragment>`. three-slug's own
  material defaults to a single flat `MeshBasicMaterial.color` for the whole
  mesh, so per-glyph coloring (needed here to distinguish prompt/path/status
  colors in the demo output) required the same splice-and-wrap technique as
  the effect channel.
- **`MAX_GLYPHS = 8192`** is a prototype-only fixed instance-count ceiling
  (`SlugGeometry(MAX_GLYPHS)` at construction); Laban's real glyph buffer
  sizing is a separate, already-solved concern and isn't exercised here.

None of the above are blockers for the *feel* question — they're the kind of
integration friction you'd expect wrapping any third-party renderer's
`onBeforeCompile`, and they don't affect whether variant A/B/C's math is
faithfully mirrored (that part is exact, see the constants table above and
the `TL.*` imports in `main.js`).

## Verdict

_(fill in after watching each variant live — not filled in yet)_
