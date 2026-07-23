# tab-hover-preview prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

`../tab-thumbnails` proved the core claim (a miniature vector-text
representation stays crisp at any scale, unlike a downscaled bitmap
screenshot) but pays for it with a small permanent strip embedded in every
sidebar row, always visible. This prototype asks the trade-off question
directly: what if the preview costs **zero permanent space** instead,
appearing only on hover — bigger, more legible, no interaction cost when
you're not looking for it, at the price of needing to hover to see it at
all?

## How to run

```sh
cd prototype/tab-hover-preview
npm install
npm start
# → http://localhost:8742/
```

Click a sidebar row to switch. Hover a **background** (non-current) row —
after a short delay, a larger live preview floats out beside it. Move away
and it disappears immediately.

## What changed from `../tab-thumbnails`

- Sidebar rows are back to compact (number + name + one meta line, no
  embedded canvas) — this is the entire point: zero permanent space cost.
- One reused floating `.preview` panel (sized dynamically — see "Realistic
  scale" below) instead of four permanent small canvases. Repositioned via
  `getBoundingClientRect()` to align with whichever row is hovered, clamped
  to stay on-screen near the bottom of the viewport.
- Bigger budget than a row strip could ever afford, even proportionally —
  the same line window and character budget as the main view itself, just
  uniformly smaller. A genuinely *readable* preview, not a squint-worthy
  thumbnail.
- A conventional border + drop shadow on the panel itself (unlike the main
  terminal, which stays borderless per earlier feedback) — a transient
  floating overlay is expected to read as "floating above" the page, which
  a border/shadow is what actually communicates.
- **No preview for the current tab's own row** — redundant with the
  already-visible main view, so hovering it is a no-op.
- 130ms show-delay on hover-in (avoids flashing the panel during a fast
  mouse pass across multiple rows) but hides immediately on hover-out — the
  standard asymmetric-debounce shape for hover UI.
- Same underlying tech as `../tab-thumbnails`: flat orthographic camera in
  1:1 CSS pixels, `MeshBasicMaterial`, `geometry.addText()`, no animation
  loop (only the panel's opacity/transform are CSS-transitioned — nothing
  3D or WebGL-animated).

## Realistic scale (2026-07-23 update)

First version used independently-chosen numbers (360×170px, 13px font, 7
lines, 40-char truncation) — not grounded in anything, just "looked about
right." Replaced with a true proportional miniature:

- `PREVIEW_SCALE = 0.5` applied **uniformly** to the main stage's own
  *current* `getBoundingClientRect()` width and height, and to
  `MAIN_FONT_PX`/`MAIN_MARGIN` — same aspect ratio by construction (both
  dimensions scale together), not approximated.
- Because font and panel width scale by the identical factor, the same
  character budget that fits the main view (`MAIN_MAX_CHARS`) also fits the
  preview — no separate truncation constant needed anymore.
- Shows the **same content window** the main view shows
  (`TABS[i].lines.slice(-MAIN_LINES)`), not an independently-sized crop —
  "all of the content," tried first per explicit instruction, before a
  "lower half only" variant.
- `computePreviewGeometry()` runs fresh every time the preview opens, so it
  naturally tracks the main stage's actual current size rather than baking
  in a value that could go stale.
- **Explicit synchronous resize, not reliance on the canvas's own
  `ResizeObserver`.** Setting `previewEl.style.width/height` doesn't
  immediately mean the *canvas* inside it has the new size as far as
  Three.js knows — `ResizeObserver` callbacks are asynchronous by spec.
  `showPreview()` calls `previewStage.resize()` directly right after
  changing the CSS size; `resize()`'s own `canvas.getBoundingClientRect()`
  call forces a synchronous layout flush, so this is correct on the very
  first frame, not "correct one frame later." `createTextStage()` now
  exposes `resize` alongside `setLines` specifically for this.
- A window resize while the preview is open invalidates `previewGeom`
  (it's derived from the main stage's size) — simplest correct fix is to
  just close the preview rather than re-deriving position/size mid-hover;
  re-hovering shows it fresh at the new scale.

At `PREVIEW_SCALE = 0.5` against this browser window's actual stage size,
the panel comes out considerably larger than the original fixed 360×170 —
confirmed via zoomed screenshot that text stays crisp even at the smaller
end of that range (8px, i.e. `MAIN_FONT_PX × 0.5`), and via a second
hover test with a fuller content buffer that the panel genuinely fills its
proportional space the way the main view would, not just at the sparse
initial state. Whether `0.5` specifically feels *right* — versus a smaller
scale for a more compact flyout, or the "lower half only" crop instead of
full-content scaling — is exactly the kind of thing worth reacting to live
rather than deciding from a screenshot; not settled here on purpose.

## Verified

- Loads with zero console errors.
- Hovering a background row shows the correctly-targeted tab's content,
  positioned beside that specific row (confirmed for rows at different
  vertical positions, not just the first one tested).
- Zoomed screenshot confirms the preview text renders crisp and properly
  colored — the earlier concern (does it just look muddy at this size) does
  not hold up; it reads clean.
- "No preview on the current row" is correct, verified two ways: **console
  logging of the actual mouseenter/mouseleave event sequence** (confirmed
  `mouseenter 1` → `mouseleave 1` → `mouseenter 0`, i.e., events fire
  correctly and in the right order) and **direct inspection of the live
  DOM/computed-style state** (`classList` has no `visible`, `computedOpacity:
  "0"`) immediately after that sequence.

## A second instance of the stale-screenshot testing-harness issue

A screenshot taken right after hovering the current-tab row initially
*appeared* to show the preview still visible with stale content — looked
exactly like a real bug. But checking the live DOM state in that same
moment showed the correct hidden state (no `visible` class, `opacity: 0`),
and a **subsequent fresh screenshot** (no code or state changes in
between) correctly showed it hidden. This is the same class of issue
`../tab-peek-3d/NOTES.md` documents for `requestAnimationFrame` in a
backgrounded automation tab — here it's a stale/cached screenshot rather
than rAF not ticking, but the lesson is the same: when a screenshot
disagrees with the code's own state logic, check the live DOM/computed
style directly (or take a second, later screenshot) before concluding
there's a bug. Trusting the first screenshot here would have sent time
chasing a bug that doesn't exist.

## Not verified / open questions

- **Only tested at exactly 4 tabs**, same caveat as the other two
  Slug-based prototypes in this repo.
- **No per-glyph color** (same scoping decision throughout this
  exploration).
- **Genuinely comparing "always-on strip" vs. "hover preview" for feel**
  wasn't done — both exist now as separate prototypes
  (`../tab-thumbnails` and this one) rather than one prototype with a
  toggle between the two modes, which would make an actual side-by-side
  comparison faster. Worth doing if this direction continues.
- The show-delay (130ms) and hide-behavior (instant) were picked as
  reasonable defaults from general hover-UI convention, not tuned against
  live use — worth a gizmo if the exact feel matters going forward,
  matching the pattern in the two 3D prototypes.
