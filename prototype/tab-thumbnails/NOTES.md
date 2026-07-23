# tab-thumbnails prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

Neither the decorative glyph effects nor the two 3D tab-transition
prototypes in this repo rose above "somewhat interesting" — they're all
transition/chrome on top of the terminal, not new capability. This
prototype asks a narrower, sharper question, grounded in Laban's own
product spec (`docs/product/spec.md` §19–20, whose stated rationale for the
Slug renderer is *fidelity* — not decoration): is there a genuinely useful
feature that's exclusive to vector glyph rendering, because a bitmap
terminal cannot do it cheaply at all?

The candidate: a **miniature representation of text that stays perfectly
crisp**, because it's the same analytic curves rasterized smaller — not a
downscaled bitmap screenshot, which is what any bitmap terminal's "tab
thumbnail" would necessarily be (blurry, or expensive to keep re-rendering
at full res just to downscale). Applied to a real, recurring pain point
(ambient awareness of background-tab activity, the thread `tab-peek-3d`
was chasing with an expensive 3D gesture): every sidebar row gets a
small, **permanent**, live strip of that tab's own recent output. No
gesture, no hold-to-reveal, no interaction at all — always visible, always
current.

## How to run

```sh
cd prototype/tab-thumbnails
npm install
npm start
# → http://localhost:8741/
```

Click a sidebar row to switch. Nothing else to do — every row's strip
updates on its own, live, whether it's the current tab or not.

## Deliberately dropped from the last two prototypes

No `PerspectiveCamera`, no lighting, no `MeshStandardMaterial`, no
animation loop at all. This idea isn't about depth or motion — it's about
legibility at small scale, so all of that apparatus would have been noise.
Each canvas uses a flat orthographic camera in 1:1 CSS pixels (the same
simple setup as `../slug-glyph-effects`, not the frustum-fitting math the
tilt/flip prototypes needed), `MeshBasicMaterial`, and
`geometry.addText()` (three-slug's own convenience layout method — calls
`updateBuffers()` internally, so this can't hit the GPU-buffer bug
documented in `../slug-glyph-effects/NOTES.md`). There's no `tick()`/rAF
loop anywhere in this file: nothing transitions, so each canvas just
re-renders once, on demand, whenever its own tab's content actually
changes.

## Design decisions from explicit feedback

- **The strip's aspect ratio does not match the main terminal's, on
  purpose.** Forcing it to match would mean either compressing every row
  of the full terminal into a short wide strip (illegible) or accepting
  visual clutter. Instead each strip shows only the **last 3 lines** —
  "the lower half," the most recent output closest to the live
  prompt/cursor — which is also the actually useful signal ("is this tab
  still running, did it just error, is it back at a prompt"), at a scale
  that's legible for the row's own natural wide-short shape.
- **Muted text color** (`STRIP_TEXT_COLOR = 0x717c94`, well below the main
  view's `0xdbe4ff`) and **truncation to 34 characters** — both aimed
  directly at "might become visually messy." This is meant to read as
  ambient signal you can choose to look at, not something competing for
  attention with the main terminal or the tab name already in the row.
  Confirmed via a zoomed screenshot: text is genuinely crisp and legible
  at 9px, not just "technically rendered" — this is the concrete evidence
  for the core "stays crisp at any scale" claim, not just an assertion.
- **A slightly lighter background per strip** (`0x171822` vs. the sidebar's
  `0x21222b`) gives each strip a contained "little terminal window" feel
  without needing an actual border — consistent with the border-removal
  feedback from `../tab-peek-3d`.

## Verified

- Loads with zero console errors.
- Live updates confirmed two ways: a strip's content had already changed
  by the time of the very first post-load screenshot (background feed
  interval firing on schedule), and a later screenshot after switching
  tabs showed **all three non-current strips continuing to update** while
  the main view showed a different (now-current) tab — this is the actual
  value proposition rendered concretely, not just claimed: you can see
  `tests` accumulated results and `logs` accumulated events without ever
  clicking on them.
- Switching tabs (click a sidebar row) correctly swaps the main view and
  sidebar highlight; the clicked tab's own strip keeps showing its own
  (now partially redundant with the main view, which is fine/expected)
  recent lines.
- Zoomed screenshot of a strip at actual rendered size confirms text is
  crisp, not just present — the specific thing this prototype exists to
  demonstrate.

## Not verified / open questions

- **Only tested at exactly 4 tabs.** More tabs means more strips
  competing for sidebar space and attention — at what count does "ambient"
  tip into "messy" after all? Untested.
- **No per-glyph color** (same scoping decision as the other two
  Slug-based prototypes here) — real terminal output is often
  color-coded (red errors, green pass/fail), which would likely make the
  strips *more* scannable at a glance, not less; worth trying if this
  direction continues.
- **Real-time "does this actually feel ambient or does it feel busy"** is,
  as always, a live-usage judgment a screenshot can only partially
  answer — worth watching for a few minutes with the background feed
  running rather than judging from single frames.
- The main view's font/margin/character-budget constants were carried
  over from `../tab-peek-3d` with only light adjustment, not freshly tuned
  against this prototype's simpler (non-tilted, non-shrunk) full-size
  layout — likely fine, not rigorously checked at every stage width.
