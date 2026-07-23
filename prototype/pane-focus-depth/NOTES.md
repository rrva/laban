# pane-focus-depth prototype — NOTES

PROTOTYPE. Throwaway. Not part of the Laban build; nothing here ships.

## Question being answered

Per-glyph animation (the `slug-glyph-effects` prototype next door) risks
"output scanning visual fatigue" if scoped too broadly — bulk process output
would get the same per-character treatment as a single typed keystroke. This
prototype asks the opposite-granularity question: can a *pane-level* depth
cue (borrowed from the "text as real geometry" idea behind JSlug/Slug
rendering — tilt, lift, soft shadow, parallax) give an obvious, satisfying
focus-change signal *without* animating anything continuously or per-glyph?

## How to run

```sh
cd prototype/pane-focus-depth
python3 -m http.server 8738
# → http://localhost:8738/
```

No npm, no build step, no dependencies — plain HTML/CSS/JS, native DOM text
(not WebGL/Slug — this prototype is about whole-pane motion, not glyph
rendering fidelity).

## Chrome sampled from a live screenshot

The sidebar (title-bar dots, "+", tab list, colors) is not invented — it's
read from `laban session screenshot` of the actually-running app (this very
Claude Code session, in Laban, on this branch) via the `laban-terminal-control`
skill, then pixel-sampled with PIL:

| Element | Color | Sample point (2400×1576 capture) |
|---|---|---|
| Sidebar background | `#21222b` | (150,300), consistent down the full column |
| Selected-tab row background | `#444657` | (200,90) |
| Selected-tab accent bar | `#b393ef` | (3,90), left edge of the highlighted row |
| Dim secondary text (session name, branch) | `#646f9d` | (90,143), (90,282) |
| Sidebar-to-content boundary | x ≈ 400 of 2400 (≈17%) | horizontal scan at y=1300 |

The main *pane* background intentionally does **not** copy the `#474856`
sampled from the live screenshot's content area — that reading is Claude
Code's own chat-UI background (and this window may have transparency/blur
active per `terminal-background-transparency-handoff.md`), not Laban's raw
terminal background. Panes here use the conventional near-black terminal bg
instead, since the point of "full panes" is to look like actual terminal
content, not to reproduce one specific app's incidental coloring. The
sidebar chrome doesn't have that ambiguity (it's Laban's own UI, unaffected
by whatever's running inside the terminal), so those colors are copied
directly.

The three sidebar rows drive which single pane is `.active`; the pane
switches on click or `1`/`2`/`3`.

**Correction (2026-07-23):** the first version of this prototype showed all
three panes simultaneously, side by side, and lifted the focused one
*relative to its visible siblings*. That's wrong — the live screenshot this
chrome is sampled from shows Laban displaying **one full-size session at a
time** (tab-style), not a split view. There are no visible siblings to lift
relative to, so the mechanic changed: only one `.pane` is ever `display:
block`, sized to fill the whole content area, and the pane you're switching
*to* plays a "rise into focus" arrival — starting from a receded, tilted-back,
dimmed pose and easing to full identity — instead of a relative lift/recede
pair. The sidebar's role didn't change: its selected row still mirrors
whichever pane is currently active.

## Design

- **One-shot, not continuous.** The arrival animation plays exactly once, on
  the frame the active pane changes. Nothing animates while you're just
  reading — the opposite of the per-glyph fatigue concern.
- **Settles back to flat.** The incoming pane eases from its receded starting
  pose (`translateY(16px) translateZ(-32px) rotateX(-3deg) scale(.965)`,
  dimmed) to full identity over 260ms, then sits completely still. The only
  persistent difference from any other moment is the static sidebar
  highlight + pane border color — not animated, costs nothing to look at
  while working.
- **`display:none` needs an explicit two-frame handoff.** A pane that was
  `display:none` has no prior rendered frame for a CSS transition to
  animate *from* — toggling `display` and a transform class in the same
  tick just jumps straight to the end state with no visible motion. Fixed by:
  set `display:block` + the receded-pose class, force a layout flush
  (`void pane.offsetWidth`), *then* remove the receded-pose class on the
  next `requestAnimationFrame` so the browser has actually painted the
  starting pose before the transition runs. Caught this by testing (two
  screenshots straddling a switch showed identical, already-settled frames)
  rather than assuming the first version's class-toggle timing would just
  work for a `display:none` element the same way it did for opacity/scale
  changes on an always-visible one.
- **CSS transforms, not WebGL.** `perspective` on the container +
  `translateZ`/`rotateX`/`scale`/`filter` on the pane. Intentionally *not* a
  literal 3D-tilted text renderer — real perspective-projected monospace
  text has a legibility cost (see the research discussion this came out of);
  keeping the tilt small (~3°) and brief avoids that while still reading as
  "this thing physically arrived."

## Verified

- Loads with zero console errors.
- Only one pane is ever visible; the sidebar's selected row always matches
  the active pane — confirmed via direct DOM assertion
  (`.pane[data-pane="1"].classList.contains('focused-static')` and
  `.tab-row[data-pane="1"].classList.contains('selected')`, both `true`
  after a JS-dispatched click on the sidebar row) and by clicking through all
  three live.
- Caught the arrival mid-flight: two screenshots taken ~1s apart after
  switching show the *same* pane content at two different sizes/positions —
  the first noticeably smaller/lower than the fully-settled second — which
  is the actual signature of the transition playing, not just a before/after
  comparison.

**Browser-tool note (not a prototype bug):** mid-session a stale Chrome tab
(left over from an earlier disconnect) stopped responding to screenshot
capture specifically, while still responding to JS `eval` and DOM state
queries — pixel-coordinate clicks also silently missed their target on that
tab even after the reload. Confirmed real by reproducing on a fresh tab
(worked immediately) and by dispatching `.click()` via JS on the stale tab
(worked, proving the page itself was fine). Closing the stale tab and
opening a new one resolved it. Worth remembering if a browser-tool session
ever seems "stuck" after a tab-loss error — try a fresh tab before assuming
the page is broken.

## Not verified

Real-time feel — same caveat as the glyph-effects prototype. A static
screenshot (even one caught mid-transition) can't tell you whether this
arrival reads as "satisfying" or "too much"/"too little." Worth watching
live and tuning: how far back/down the starting pose is, the tilt angle, and
the transition duration (currently 260ms, no explicit hold — unlike the
first version there's nothing to hold *against*, since the outgoing pane is
already gone the instant you switch).

## Open questions if this direction is pursued for real

- Laban's actual pane-switching model is now confirmed (tab-style, one
  session frontmost at a time) — but does it already have its own focus
  transition (even a plain crossfade) that this would need to replace rather
  than add to?
- Real Metal-rendered terminal content (not native DOM text) would need its
  own answer to the "perspective distorts monospace legibility" tradeoff —
  a brief, small-angle, one-shot tilt is probably fine, but that needs
  checking against actual rendered glyphs, not browser-native font
  rendering.
- Does the outgoing pane need *any* transition (even just an instant cut,
  as implemented now), or would a brief cross-dissolve read better than a
  hard cut behind the incoming pane's pop-in?
