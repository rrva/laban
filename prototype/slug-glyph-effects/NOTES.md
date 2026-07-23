# slug-glyph-effects prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

How do the per-glyph keystroke-impulse tunings feel in real-time motion, and
which constants are worth carrying into
`execplans/active/per-glyph-animation-channel.md`? Built with `three-slug`
(JSlug's THREE.SlugText GPU text renderer) instead of Laban's own Metal
pipeline, so the loop is edit-shader → reload-browser instead of
edit-Metal → rebuild-Swift-app.

**2026-07-23 update:** live human review of A/B/C found the committed kind-1
squash/stretch motion too subtle — "too little wow." D and E are new,
genuinely different effect *kinds* (not just retuned kind-1 knobs) exploring
higher-impact directions from a round of research on what Slug rendering
specifically enables for terminal glyph effects (color that follows the true
curve shape, not a bounding box; motion computed from real geometry, not a
sprite). Both are prototype-only — they are not part of
`GlyphEffectTimeline.swift`'s contract and would need their own kind number
and Swift/Metal implementation if either earns its way in.

## How to run

```sh
cd prototype/slug-glyph-effects
npm install
npm start
# → http://localhost:8737/?variant=A
```

Open `?variant=A` through `?variant=E` (or use the `‹ ›` pager / Left-Right
arrow keys to cycle at runtime — the URL updates and the page reloads so
state stays shareable).

Controls: `T` type line, `K` keystroke-demo (types a fake shell command char
by char), `B` fire a bell shake, `A` toggle auto-demo, `E` toggle effects
on/off, `M` toggle reduceMotion, `L` **live type** (below). Top-left: a
**duration** slider (below). There is no on-screen status readout by design
(see "HUD removed" below) — the buttons' own labels show their current
on/off state.

### Live typing (`L`, or the "live type…" button)

The scripted demos (`T`/`K`/auto-demo) use canned text and synthetic random
per-key delays (24–60 ms) — useful for a quick look, but not representative
of how the effect feels under an actual person's fingers. Live typing feeds
real `keydown` timing straight into the animation channel: press `L`, then
just type. Each keystroke stamps one cell at the exact moment it fired
(`clockSeconds()` read inside the `keydown` handler, not on a timer).
Backspace removes the last character; Enter flashes the whole submitted line
(reusing `stampLine`, same as the scripted demo's "(ran ...)" line) and
starts a fresh `$ ` prompt. Escape exits back to normal keyboard-shortcut
mode. While live typing is active, all other single-key shortcuts are
suppressed (so `T`/`K`/`B`/etc. type into the line instead of triggering
those actions) — only Escape, Enter, and Backspace are intercepted.

One real bug this surfaced: Backspace called `rebuildGeometry()` but not
`kick()`. If the render loop had already parked (nothing animating),
updating the CPU/GPU buffers with no follow-up `render()` call left the
*canvas* showing the pre-Backspace frame — geometry correct, screen stale.
Fixed by adding `kick()` there too, matching every other geometry-mutating
call site (all of which already had it — this was the one omission, found by
testing the actual interaction path rather than assuming symmetry with
typing).

### Duration slider (top-left)

Tunes how fast every effect plays, live, no reload: drag away from `1.00×`
(normal) toward higher for slower/more visible motion, lower for faster.
Implemented as a single shader-side change — `age = (uTimeSeconds -
aEffect.y) / uDurationMultiplier` — instead of scaling each kind's decay
constant individually. Because every kind's timing derives from that one
`age` value (including kind 2's bell shake, whose decay/omega were
previously baked into the shader as compile-time constants), one line
covers all five variants without per-kind plumbing. The JS-side live/park
detection (`countLive`) divides by the same `uDurationMultiplier` so it
never parks a glyph the GPU is still visibly animating.

## Variants

A/B/C are tunings of kind 1 (keystroke impulse — squash/stretch/tilt, no
color change). D/E are new prototype-only kinds:

| Key | Label | What it is |
|---|---|---|
| A | plan contract | kind 1, exact `GlyphEffectTimeline.swift` constants: scaleX₀ 0.55, scaleY₀ 1.10, tilt₀ 0.07 rad, 130 ms, easeOutBack (c1=1.70158, c3=2.70158) |
| B | subtle | kind 1, scaleX₀ 0.78, scaleY₀ 1.04, tilt₀ 0.025 rad, 110 ms, easeOutCubic (no overshoot) |
| C | punchy showcase | kind 1, scaleX₀ 0.40, scaleY₀ 1.28, tilt₀ 0.12 rad, 170 ms, easeOutBack (c1=2.30, c3=3.30), bell every 4th auto-typed line |
| D | ignition flash | **new kind 3.** Same squash/stretch/tilt mechanism as kind 1 but bigger (scaleX₀ 0.28, scaleY₀ 1.40, tilt₀ 0.18 rad, 170 ms, stronger overshoot c1=2.4/c3=3.4) **plus** the glyph's color flashes from bright white-blue `(1.7,1.7,2.0)` to its true color over the same 170 ms window, synced to the motion |
| E | sweep reveal | **new kind 4, no motion.** A bright accent line `(1.3,1.6,2.0)` wipes left→right across each glyph's own local UV over 240 ms; color is dim (22% brightness) ahead of the sweep and jumps to true color once the sweep passes, with a bright glow riding the sweep edge itself |

Variant A's uniforms are wired straight from `timeline.js`'s exported
constants (not hand-copied), so A *is* `GlyphEffectTimeline.swift`'s current
committed contract — not an approximation of it.

## HUD removed

The prototype originally had a live top-left HUD (display-link state, live
count, last effect kind). Removed on user feedback: a readout that changes
every frame right next to the thing you're trying to visually judge competes
for attention — "only things related to the effect we are prototyping should
change on screen." The control buttons' own labels already show effects/
reduceMotion state, and the bottom variant bar already shows which variant is
active, so nothing was lost. `verify.mjs` still needs a way to detect
parked/live state for its regression check; it now reads a headless-only
`window.__testState()` hook instead of scraping DOM text — nothing renders
from that hook, it exists purely for the automated check.

## D and E: how they work, and what's still unverified

**Kind 3 (ignition flash)** reuses the exact vertex-stage motion code path as
kind 1 (same `easeOutBack` squash/stretch/tilt), just with punchier
per-variant constants — no new vertex branch needed. It *additionally* drives
a new fragment-stage color mix: `mix(uFlashColor, vGlyphColor, p)` using the
same progress `p` as the motion, so the flash and the pop are synced. This
needed a new varying pair (`vEffectAge`, `vEffectKind`) carried from vertex
to fragment, since kind/age were previously vertex-only.

**Kind 4 (sweep reveal)** is fragment-only — no vertex transform at all, kind
4 falls through the vertex `if` untouched. It uses `vTexCoords`, three-slug's
own local glyph UV (already declared by the library's `slug_pars_fragment`,
0..1 across each glyph's quad regardless of any vertex-stage scale/rotate),
to compute a moving sweep position `sweepX = mix(-0.25, 1.25, p)` and blend
color by distance from it. This is the direct implementation of the "gradient
sweep that follows glyph shape exactly" idea — cheap because Slug already
does the hard part (exact per-fragment coverage from the real curve data),
so the effect never has to reason about a bounding box separately from the
glyph shape.

Verified: both new kinds compile without shader errors, render without
console/page errors, visibly change the color of freshly-stamped glyphs
(confirmed via zoomed screenshots — the most recently typed character reads
distinctly brighter/tinted vs. its settled neighbors), and correctly
park/report live-count through the new `isAnimating()` wrapper (`main.js`)
that extends `TL.isAnimating` for these prototype-local kind numbers.

**Not verified, and this is the important gap:** whether either actually
delivers more "wow" than kind 1 in real-time motion. A flash-to-white color
mix and a wipe read very differently in motion than in a static screenshot —
that's exactly the class of judgment a screenshot can't make (see "Not
verified" note in Verdict below). Someone needs to run `npm start`, open
`?variant=D` and `?variant=E`, press `K` a few times, and compare against
`?variant=A`/`?variant=C`.

## Other effect ideas surfaced but not prototyped (time-boxed to two)

From the research pass: outline/stroke hugging the true glyph edge (cheap
with `vTexCoords` + a coverage-based edge test, not yet tried), CRT-style
glow/bloom (would need a real blur — a single quad's fragment shader can
brighten but can't bleed light outside the glyph's own coverage without a
second enlarged draw or a post-process pass, neither of which exist in this
prototype), weight/style morphing (needs two `SlugData` variants and
cross-fading band data — a bigger lift than "quickly"), and decode/glitch
reveal (scrambling then resolving to the true glyph — likely the next thing
worth trying if D/E don't land, since it's closer to "progressively reveal"
than a pure color wipe).

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
