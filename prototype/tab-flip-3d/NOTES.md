# tab-flip-3d prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

The CSS-only `pane-focus-depth` prototype next door proved a one-shot,
settles-flat arrival cue can signal a tab switch without continuous or
per-glyph animation. This prototype asks a follow-up: can the transition
itself be a genuine 3D card flip — the outgoing and incoming tab each
painted on one face of a thin, lit surface that rotates into view — built
with `three-slug` the way the actual JSlug demo does it, instead of a CSS
transform faking depth on flat DOM text?

**2026-07-23 update:** the first version's 560ms flip read as too fast on
live viewing. Default duration is now 1400ms, and both duration and flip
axis (horizontal/Y — page-turn; vertical/X — flip-clock) are live-tunable
via an on-screen gizmo (top-left of the stage) rather than baked-in
constants, so the right feel doesn't have to be guessed at in code.

## How to run

```sh
cd prototype/tab-flip-3d
npm install
npm start
# → http://localhost:8739/
```

Click a sidebar row, or press `1`/`2`/`3`. Sidebar chrome (colors, layout) is
identical to `../pane-focus-depth` — same source, same live-screenshot
sampling; see that prototype's NOTES.md for where those colors came from.

## Based on the actual JSlug demo, not guessed

Cloned `github.com/manthrax/JSlug` and read `demo/main.js` directly rather
than reverse-engineering the live demo page. What carried over:

- **`THREE.PerspectiveCamera`, not orthographic.** The demo uses one so
  `OrbitControls` can fly around; here the camera is fixed, but perspective
  is still load-bearing — an orthographic camera shows zero foreshortening,
  so a Y-axis rotation would look like a rectangle scaling in X, not a card
  turning in space.
- **`THREE.MeshStandardMaterial` on the Slug geometry, not
  `MeshBasicMaterial`.** This is the single biggest difference from the
  other two Slug-based... well, the one other Slug-based prototype
  (`slug-glyph-effects`) here, which stays flat/unlit by design (it's
  testing per-glyph motion, not lighting). PBR material + real lights is
  most of what makes the JSlug demo read as "real" 3D instead of a flat
  image on a hinge — the text visibly shades as it turns.
- **`geometry.addText(...)`**, the library's own convenience layout method
  (which the demo itself uses), not the manual `addGlyph()` loop from
  `slug-glyph-effects`. `addText()` calls `updateBuffers()` internally, so
  the "new glyphs invisible because the GPU buffer was never flagged for
  re-upload" bug documented in that prototype's NOTES.md structurally can't
  happen here — a safer default for a prototype that isn't testing
  per-glyph coloring anyway.

What did **not** carry over: the demo's `SpotLight` + shadow-map pipeline,
`OrbitControls`, the debug cube, and the Star-Wars-crawl/glitch features —
none of that serves a one-shot tab-flip. Lighting here is a plain
`AmbientLight` + one `DirectionalLight` + a small `PointLight` for fill,
enough to get visible shading gradient without shadow-map cost/complexity.

## The flip mechanic

A `hinge` `THREE.Group` holds two child groups, `frontFace` and `backFace`,
each with an opaque backing plane + accent-colored border plane + a Slug
text mesh — a small "card" with `side: THREE.FrontSide` on every material so
only whichever face's normal currently points at the camera renders at all.
Switching tabs:

1. Repopulates `backFace`'s text with the target tab's content.
2. Resets `hinge.rotation` and `backFace.rotation` to identity, then sets
   `backFace.rotation[axis] = Math.PI` — the pre-rotation is applied fresh
   per flip, not once at startup, because axis is now live-tunable (below)
   and must match whatever the hinge is about to animate.
3. Animates `hinge.rotation[axis]` from `0` to `Math.PI` over the current
   duration (`easeInOutCubic`), calling `renderer.render()` every frame.
4. At completion: resets that rotation to `0`, repopulates `frontFace` with
   the target tab's content, renders one final settled frame, and parks (no
   further `requestAnimationFrame` calls) — same idle-park discipline as the
   other two prototypes.

Two 180° rotations around the *same* axis (the child's fixed pre-rotation,
then the hinge's animated one) compose to identity, which is *why* the
incoming face arrives right-side-up instead of mirrored — confirmed by
watching it happen, not just by the math: captured mid-flip frames show
correctly-oriented content emerging well before the rotation completes, for
*both* axes (see the second GIF sent to the user — vertical/X-axis flip,
new content upright, not upside-down).

## Tuning gizmo: duration + axis

Top-left of the stage: a duration slider (300–3000ms, default 1400ms — up
from the first version's fixed 560ms, which read as too fast on live
viewing) and a horizontal/vertical toggle. Both are read fresh at the
*start* of `flipTo()`, not cached, so changing either mid-session — even
while a previous flip is settling — only affects the *next* flip; an
in-flight one always finishes with whatever it started with. This is the
same "live-tunable, no shader/scene rebuild needed" pattern as the duration
slider in `../slug-glyph-effects` (a plain uniform there; here, plain JS
variables read inside the animation loop — no uniforms involved since
nothing here is a per-fragment shader effect).

Verified via direct DOM interaction (moving the slider and reading the
label back) and via live capture: a vertical-axis flip at the new 1400ms
default was recorded end-to-end and sent to the user as a GIF, showing the
card compress to a horizontal hairline at the midpoint (top and bottom
edges meeting, correctly the *other* axis than the original horizontal
flip's vertical hairline) before the new content arrives right-side-up.

## Verified

- Loads and flips with zero console errors, after fixing two real bugs
  found during testing (below).
- **Caught the actual motion, not just endpoints.** A rapid-fire sequence of
  screenshots during one flip captured: the flat starting frame; the card
  reduced to a vertical hairline at the exact edge-on midpoint (both faces
  briefly face-culled — this is the correct signature of a *thin* card
  flip, not an approximation of one); the incoming face emerging at a steep
  angle with visible perspective foreshortening and a real lighting
  gradient across the tilted surface; and several identical fully-settled
  frames confirming a clean stop with no jitter. Exported as a GIF and sent
  to the user directly — this is exactly the kind of thing a written
  description undersells.
- Sidebar and card content switch to all three tabs correctly (tested via
  keyboard `1`/`2`/`3` with waits between presses).
- A second key/click while a flip is in-flight is silently dropped (see
  "Open question" below), confirmed intentional-but-worth-revisiting via a
  deliberate rapid double-press test.

## Bugs found and fixed while building this

1. **Canvas rendered at ~2× the intended size.**
   `renderer.setSize(w, h, false)` — the `false` (`updateStyle`) skips
   setting the canvas's CSS `style.width`/`style.height`. With
   `setPixelRatio(devicePixelRatio)` active, the canvas's *drawing buffer*
   is `dpr × w` by `dpr × h`, and with no CSS override the canvas element
   falls back to displaying at its width/height *attributes* (the
   dpr-scaled buffer size) as CSS pixels — so on this 2×-DPR machine
   everything rendered at roughly double the intended size, cropped by the
   viewport. First screenshot after wiring up the scene showed a few
   giant, clipped characters filling most of the screen; fixed by dropping
   the `false` (`updateStyle` defaults to `true`).
2. **Sidebar lagged the visible card for the entire 560ms flip.** The first
   version called `updateSidebar()` using the `frontIndex` variable, which
   only updates at the *end* of `flipTo()` — so clicking a row highlighted
   nothing new until the animation had already finished. Fixed by passing
   the *target* index into `updateSidebar()` synchronously at the start of
   `flipTo()`, decoupled from when `frontIndex` itself updates.

Neither bug was visible from a single screenshot taken well after the fact
in both cases — the first only shows up as "everything is huge," which
reads as a tuning problem until you check the actual cause; the second only
shows up if you screenshot *during* the transition, which is exactly what
almost didn't happen here.

## Known simplifications (scoped out, not forgotten)

- **No per-glyph color.** Text is single-color (`#dbe4ff`) via `addText()`.
  The ANSI-style coloring in the other two prototypes would need the same
  `aGlyphColor` bolt-on attribute `slug-glyph-effects` built, ported onto a
  `MeshStandardMaterial`'s `onBeforeCompile` (more involved than the flat
  `MeshBasicMaterial` case — the color needs to blend with the *lit* output,
  not just multiply `diffuseColor`).
- **No rounded card corners.** Plain rectangular planes; a real rounded-rect
  would need either extra border geometry or an alpha-masked shader pass.
- **A checkmark character (`✓`, U+2713) rendered as a tofu box** — swapped
  for plain `ok` in the demo text rather than debugging font/codepoint
  coverage, since the actual glyph choice isn't what this prototype tests.

## Open question

A key/click that arrives while a flip is already in-flight is currently
just dropped (`if (flying || index === frontIndex) return;`). That's a safe
default but might feel unresponsive against rapid tab-cycling (e.g. holding
a "next tab" shortcut) — worth deciding whether to queue the latest request,
interrupt the in-flight flip and retarget mid-rotation, or keep the current
drop-and-ignore behavior, before this goes anywhere near real use.
