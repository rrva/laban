# tab-peek-3d prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

Both other prototypes in this repo are about *switching* attention (a flip
or a settle-flat swap). This one asks a different question: can you *watch*
what background tabs are doing without switching away from, or losing track
of, the tab you're actually in? Idea as given: the current tab tilts
vertically in 3D, opening up space beneath it where three live,
faithfully-scaled mini-panes of the other tabs appear.

**2026-07-23 update:** the resting main card originally left unused margin
around it (it was sized to also fit the peek-time mini row even when not
peeking) and had a persistent purple border. Feedback: the resting terminal
should fill the pane like an actual terminal, not sit inside a bordered
card with visible margin. Fixed — see "Fills the pane, borderless at rest"
below.

## How to run

```sh
cd prototype/tab-peek-3d
npm install
npm start
# → http://localhost:8740/
```

Hold `Space` to peek; release to snap back. Click a sidebar row to switch
the current tab outright; click a mini-pane while peeking to switch to it
*and* exit peek in one motion ("dive in"). Gizmo (top-left): tilt angle
(10–45°) and transition duration (120–900ms).

Reuses the WebGL technique from `../tab-flip-3d` (PerspectiveCamera +
`MeshStandardMaterial` + lighting on Slug geometry, `geometry.addText()`)
and the sidebar chrome from `../pane-focus-depth` (same live-screenshot-
sampled colors), extended to **four tabs** (`main`/`tests`/`build`/`logs`)
so there are always exactly three "others" to show — the layout is fixed at
3 mini-panes side by side, so this only works cleanly with exactly 4 tabs;
see "Open questions" for what a different tab count would need.

## The mechanic

- **Top-anchored pivot, not a repositioned one.** All of a card's content
  (backing plane, border plane, text) is authored with local `y = 0` at the
  card's own *top* edge, extending downward to `y = -height`. That makes a
  `THREE.Group`'s own origin its top-center pivot for free — scaling and
  rotating the group stays anchored at the top with zero extra position
  math, which is what makes "tilts back and shrinks toward its fixed top
  edge, revealing space below" work without hand-tuning a compensating
  translation every time the tilt angle or scale changes.
- **Tilt + shrink together, not tilt alone.** Purely relying on perspective
  foreshortening from the tilt to "naturally" free up space is elegant but
  fragile — how much space it actually frees depends on the exact tilt
  angle, which is now a live-tunable slider. A modest uniform scale-down
  (`MAIN_PEEK_SCALE`, tuned to `0.68` after the resting-size change below)
  runs alongside the tilt so there's guaranteed clearance for the mini row
  regardless of what tilt angle someone dials in.
- **Mini row Y tracks the live scale, every frame, not just at the end.**
  `layoutMiniRow()` computes the row's Y from the main card's *current*
  interpolated scale and is called every tick during the transition, so the
  mini-panes rise into place in sync with the main card shrinking, rather
  than popping into their final position only once the tilt finishes.
- **The three "other" mini-panes are assigned by index, excluding current**
  (`TABS.map((_,i)=>i).filter(i=>i!==currentIndex)`), always in ascending
  order — switching which tab is current always reassigns all three
  mini-pane slots consistently rather than leaving stale assignments.

## Fills the pane, borderless at rest

Two related fixes from live feedback:

- **`MAIN_HEIGHT` went from 100 to 150 world units, `TOP_Y` from 65 to 76**
  (against a fixed ~82-unit camera frustum half-height) — the resting card
  now fills nearly the entire stage instead of leaving unused margin above
  and below it. Room for the mini row during peek comes *entirely* from
  `MAIN_PEEK_SCALE` shrinking the (now much taller) card, not from ever
  reserving space at rest — `MAIN_PEEK_SCALE` moved from `0.8` to `0.68` to
  keep the same clearance margin against the taller card.
- **The border is no longer part of `setOpacity()`'s uniform fade.** It used
  to be one of three materials (border/backing/text) that a mini-pane's
  0→1 fade moved together, and the main card was simply never faded (always
  opacity 1, border included) — so the border was a constant, full-intensity
  purple outline around every card, always. Now `BORDER_SUBTLE = 0.3` caps
  it well below full intensity even at maximum visibility, and the *main*
  card's border is driven separately from its (always-opaque) backing/text:
  `0` at rest, fading up to `0.3` in sync with the same peek-progress value
  (`op`) that drives the mini row's fade, back to `0` once settled flat
  again. Net effect: a resting main card reads as "the terminal, full
  stop" — no visible card outline at all — while a faint edge is still
  legible during the tilt/peek, where it helps read the foreshortened
  card's boundary against the black background. Mini-panes get the same
  `BORDER_SUBTLE` cap through the unmodified `setOpacity()` path, since they
  never have an independent "rest" state distinct from fully hidden.

## Live background activity

Each non-`main` tab has a `feed`: a small pool of plausible next-lines
(test results, compiler output, log entries) that a `setInterval` (1.8s,
50% chance per tab per tick) appends to that tab's `lines` buffer and marks
`dirty`. This runs **regardless of whether you're peeking** — the tabs keep
"working" whether you're watching or not, same as real background
processes — and `feedIdx` wraps (`% feed.length`), so long-running tabs
cycle back through their pool rather than running out of content. While
peeking, a dirty tab's mini-pane geometry is rebuilt and rendered on the
spot; while not peeking, content still accumulates silently and the next
peek shows whatever's piled up in the meantime, which is more representative
of "catching up on what happened" than always starting fresh.

## Bugs found and fixed while building this

1. **Overlapping/garbled text on the `build` and `logs` mini-panes.** First
   live screenshot showed what looked like double-exposed text. Debug
   inspection (`width`, `position`, `childCount` per mini-group) showed
   everything structurally correct — one text mesh per group, correct
   widths, correct non-overlapping X positions. The actual cause: WebGL
   doesn't auto-clip a mesh to any "logical card boundary" the way DOM/CSS
   `overflow: hidden` would — that's purely a browser layout convention,
   not something a 3D scene graph gives you for free. A long line (e.g.
   `[89/212] Compiling LabanRenderer VectorGlyphShaders.metal`, 59 chars) at
   the mini font size is nearly double the character budget the ~50-unit
   mini-card width can hold, so it simply rendered straight through the
   card's own border into the neighboring pane's space. Fixed by truncating
   mini-pane lines to 30 characters (`truncateForMini`) — which is also
   just realistic: a real thumbnail/preview would truncate too, not silently
   overflow into its neighbor.
2. **Holding then releasing Space got stuck mid-tilt forever.** The first
   version guarded `setPeek` with `if (transitioning) return;` — meant to
   prevent overlapping animations, but it also silently dropped a release
   request that arrived while the *enter* transition was still in flight.
   Confirmed live via a direct state dump: after keydown then keyup,
   `transitioning` stayed `true` and `mainGroup.rotation.x` stayed pinned at
   `0` indefinitely — the release had nowhere to go, so nothing ever
   resumed. This is a real, not hypothetical, failure mode: a quick tap is
   *exactly* a keydown immediately followed by keyup, and the whole feature
   is a hold gesture. Rewritten so `setPeek` always retargets a live (or
   fresh) animation from its *current* interpolated pose rather than being
   blocked by one already running — verified via a direct state-level test
   (request peek-in, immediately request peek-out with zero settle time in
   between, confirm it still converges cleanly to flat/hidden) before ever
   trusting a screenshot of it.

## A real testing-methodology finding (not a prototype bug)

`requestAnimationFrame` does not fire — at all, not just throttled — in a
Chrome tab whose `document.hidden` is `true`, which is the state this
automated browser tab was in for plain `javascript_exec`-dispatched
`KeyboardEvent`s (confirmed via `document.visibilityState`/`hasFocus()`),
even though a `computer` tool *click* on the same tab did win real
`hasFocus()` without changing `visibilityState`. Consequence: bugs #2 above
was only fully diagnosable by driving the animation through explicit,
fabricated timestamps (`tick(performance.now() + 100000)`) rather than
trusting rAF to tick naturally in this harness — a real user's actually-
visible, actually-focused browser tab is unaffected by any of this; it's
purely an artifact of automating a tab that isn't the frontmost/visible one.
Worth remembering for any future prototype whose interaction depends on
sustained key state rather than a single discrete trigger.

## Known simplifications (scoped out, not forgotten)

- **Exactly 4 tabs, exactly 3 mini-panes**, not a general N-tabs-minus-one
  layout. A 5th tab would need either a scroll/overflow answer for the mini
  row or a cap ("show the 3 most recently active others") — neither is
  implemented.
- **No per-glyph color** (same scoping decision as `../tab-flip-3d`, same
  reason: `addText()`'s single-material convenience path, not the
  `aGlyphColor` bolt-on from `../slug-glyph-effects`).
- **The outgoing main-tab content swap on `switchCurrent()` is an instant
  cut**, not a transition of its own — this prototype is testing the
  tilt/reveal mechanic specifically, not combining it with the flip from
  `../tab-flip-3d`. Combining them is a plausible follow-up, not attempted
  here.

## Not verified

Real-time feel of the hold/release gesture and the tilt+shrink+reveal
motion together — confirmed correct at the state/logic level (this
NOTES.md's bug-fix section) and visually correct at the settled end-states
(screenshots), but, same caveat as every prototype in this repo: whether
26° and 320ms actually feel *right* — snappy enough for a glance, not so
fast it's disorienting — is a live-holding-the-key judgment call, which is
exactly why the gizmo exists rather than baking those numbers in.
