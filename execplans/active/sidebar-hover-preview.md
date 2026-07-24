# Sidebar Hover Preview: A Live Miniature of a Background Tab's Recent Output

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

Today, checking on a background tab (one you are not currently viewing) means
switching to it, which loses your place on the tab you were on. This change
adds a **hover preview**: hover a non-active tab's row in the left sidebar, and
a small floating panel appears beside it showing that tab's most recent
terminal output, live and legible, rendered as crisp vector text rather than a
blurry scaled screenshot. Move the mouse away and it disappears. The active
tab's own row never shows a preview (its content is already the whole right
side of the window).

Milestone 7 adds a second, keyboard-driven trigger for the same panel:
**hold-to-peek**. Hold Ctrl+Tab or Cmd+Option+←/→ (Laban's existing tab-cycle
shortcuts) and, instead of switching immediately, the panel shows a preview of
the tab you'd land on; keep tapping while holding to cycle further; release
the modifier to commit the switch. This mirrors macOS's own Cmd+Tab
app-switcher. Direct-jump shortcuts (Cmd+1…9) are unaffected — they have no
natural "hold" moment to hook into, so they keep switching instantly.

This only works when Laban's `slugGlyph` renderer is the effective renderer
(see "Term glossary" below) and a new setting is turned on. On any other
renderer, hovering a tab row behaves exactly as it does today: nothing happens.
`docs/adr/0031-sidebar-hover-preview-is-a-slug-capability.md` records why this
is intentionally Slug-only, mirroring the precedent in
`docs/adr/0030-spinner-motion-is-a-slug-capability.md` for spinner motion
smoothing.

You will know this works when: with the Slug renderer active and the new
setting on, hovering a background tab's sidebar row shows a panel with that
tab's last few lines of terminal output, positioned beside the row, gone the
instant the mouse leaves the row or the setting/renderer changes.

### Term glossary (plain language, used throughout this plan)

- **Effective renderer**: which `RendererBackend` is actually drawing frames
  right now, as opposed to which one the user *selected* in Settings — a
  selection can silently fall back (e.g. `slugGlyph` falls back to
  `SoftwareBackend` when no Metal device exists). Detected today via a live
  Swift type check, `backend is SlugGlyphRenderer`, computed only inside
  `Sources/LabanApp/TerminalBitmapView.swift` (AppKit layer) and passed down
  as a plain `Bool` named `effectiveRendererIsSlug`.
- **`FrameCommand`**: a small enum (`Sources/LabanRenderer/FrameCommand.swift`)
  that is the *only* thing every renderer consumes to draw a frame — a list of
  `.rect(...)`, `.glyphRun(...)`, `.cursor(...)`, etc. values. Nothing in this
  repo draws directly; everything goes through this list. Every `FrameCommand`
  case that draws something carries a `source: FrameSource` tag (`.sidebar`,
  `.terminal`, etc.) that renderers use to decide *how* to draw it (which font,
  which cell size).
- **`FontAtlas`**: a lightweight wrapper (`Sources/LabanRenderer/FontAtlas.swift`)
  around a `CTFont` (CoreText font) at one specific point size, with its cell
  width/height precomputed. A renderer typically owns one `FontAtlas` for
  terminal text and a second, smaller one for sidebar text.
  `SlugGlyphRenderer` is the only renderer this plan adds a *third* one to.
- **Slug / `SlugGlyphRenderer`**: `Sources/LabanRenderer/SlugGlyphRenderer.swift`,
  one of five `RendererBackend` implementations (`docs/adr/0027-slug-glyph-renderer.md`).
  It renders text by evaluating glyph outline curves analytically in a Metal
  fragment shader, so the same cached curve data can be redrawn crisply at any
  point size just by changing a scale factor — unlike the other renderers,
  which bake a bitmap glyph atlas at one fixed size and must rebuild it (a real
  cost) to change size.
- **Scrollback**: the terminal's history of output that has scrolled off the
  visible screen. `Session.scrollbackBlock(rowOffset:maxRows:)`
  (`Sources/LabanCore/Session.swift:883`) reads it directly from a session,
  independent of whether that session's tab is currently visible on screen.
- **ExecPlan / this document**: see `PLANS.md` at the repository root for the
  full authoring rules this document follows.

## Progress

- [x] (2026-07-23) Milestone 1: Settings scaffold + `FrameCommand`/`FontAtlas` groundwork (no visible behavior change). Added `Sources/LabanCore/HoverPreviewSettings.swift`, `Tests/LabanCoreTests/HoverPreviewSettingsTests.swift` (9 tests, all passing), `FrameSource.sidebarPreview` case, `FontAtlas.previewPointSize(forTerminalPointSize:)` and `FontAtlas.persistedPreviewPointSize`. `swift build` clean for LabanCore/LabanRenderer.
- [x] (2026-07-23) Milestone 2: `SlugGlyphRenderer` third atlas + `.sidebarPreview` routing. Added `previewFontAtlas`/`previewReferenceFontAtlas` to `SlugGlyphRenderer` (init, `reconfigureFonts`, `atlas(for:)`/`referenceAtlas(for:)` helpers replacing the old two-way ternaries), widened `runFontIdentity`'s cache key to a 2-bit atlas-kind field (see Decision Log), threaded `previewFontAtlas` through `RendererSelection.makeRendererBackend` (Slug construction only, per ADR 0031), and through every `sidebarFontAtlas` site in `TerminalBitmapView.swift` that affects backend construction/reconfiguration (init, both `makeBackend` calls, the `makeBackend` static wrapper, `applyRendererSelection`, and `applyFontSize`'s ladder-miss/backend-reconfigure paths). Also folded in `TerminalSurfaceController.previewCellWidth`/`previewCellHeight` (originally scoped to Milestone 4) since threading `TerminalBitmapView`'s new `previewFontAtlas` through the `TerminalSurfaceController(...)` constructor call and `updateCellMetrics(...)` touches the exact same lines — see Decision Log. Added `Tests/LabanRendererTests/SlugGlyphRendererPreviewAtlasTests.swift` (2 tests, passing) proving `.sidebarPreview` glyph runs resolve the preview atlas's point size and stay distinct from terminal/sidebar. `swift build` (whole package) and `swift test --filter SlugGlyphRendererPreviewAtlasTests` both clean.
- [x] (2026-07-23) Milestone 3: `SidebarProducer` emits the preview panel from resolved content. Added `SidebarProducer.HoverPreview` (nested struct) and a standalone `static func hoverPreviewCommands(...)` (extracted rather than left inline in `output(...)`, anticipating Milestone 4's memoization-bypass need — see Decision Log) that `output(...)` now calls internally so its own behavior/tests stay consistent. Added 3 tests to `Tests/LabanCoreTests/SidebarProducerTests.swift`: panel+glyph commands present for a background-tab preview, no `.sidebarPreview` commands when `hoverPreview` is nil, no `.sidebarPreview` commands when previewing the active tab's own row. All 52 `SidebarProducerTests` cases pass (49 pre-existing unmodified + 3 new).
- [x] (2026-07-23) Milestone 4: `TerminalSurfaceController` + `TerminalBitmapView` wiring. `sidebarCommands` gained `viewportWidth`, `effectiveRendererIsSlug`, `hoverPreviewEnabled` parameters; resolves `SidebarProducer.HoverPreview` from `model.session(forTab:)` + `Session.scrollbackBlock(rowOffset: 0, maxRows: 500)` when the hovered tab differs from the active tab, and appends `SidebarProducer.hoverPreviewCommands(...)` after the memoized sidebar lookup (bypassing `SidebarCacheSignature`, per Milestone 3's Decision Log). `TerminalSurfaceFrameRequest` gained `hoverPreviewEnabled: Bool = false`; both `TerminalBitmapView` call sites now pass `hoverPreviewEnabled: HoverPreviewSettings.enabled`. Added a `HoverPreviewSettings.didChangeNotification` observer mirroring the spinner-motion one (forces a render retry so toggling the setting takes effect live). Full package build and full `swift test` both pass (0 failures). Built via `./scripts/build-app`, installed to `~/Laban-hover-preview.app` (not launched from the shell). Manual verification pending the user launching the app (see Validation and Acceptance).
- [x] (2026-07-23) Milestone 5: Settings UI checkbox + debug endpoint + headless parity. See Milestone 5's own section for the full (corrected, larger-than-originally-scoped) file list. Full `swift test` passes.
- [ ] Milestone 6: Manual verification, polish pass, Review Gate. Manual verification of the four issues found in the first testing round (opacity, live-update, color fidelity, fps) is now confirmed working by the user against the latest build (commit e651b420 + the two follow-on fixes). First Review Gate pass complete (fresh agent, commit `dbfd5c17`): items 1-4, 8 passed; item 9 (ADR drift) failed and is fixed; items 5-7 gained dedicated unit coverage (`HoverPreviewRendererGateTests`) closing the "needs live-app verification" gap. Remaining: a second, clean Review Gate pass after all fixes (including Milestone 7 below), plus a final `./scripts/check` run.
- [x] (2026-07-24) Milestone 7: keyboard hold-to-peek. Holding Ctrl+Tab / Cmd+Option+←/→ now previews the tab a release would land on instead of switching instantly (`TerminalBitmapView.beginOrAdvancePeek`/`.commitPeek`, gated on `flagsChanged` observing the triggering chord's modifier(s) lift). Shares 100% of the existing panel-rendering path — only a new `peekedSidebarTabId` trigger, combined as `peekedSidebarTabId ?? hoveredSidebarTabId` everywhere the previewed tab is read. 4 new unit tests (`HoverPreviewKeyboardPeekTests`, access-level-loosened white-box tests of the state machine — no NSEvent-simulation precedent existed to test the real `keyDown`/`flagsChanged` dispatch, same gap noted for the earlier keyboard-hover-clear fix). Direct-jump shortcuts (Cmd+1…9) and menu-bar tab actions are unaffected — they still call the original instant-commit `selectTab(at:)`/`selectRelativeTab(delta:)` path. Manual verification found and fixed two real bugs, both confirmed working by the user — see Surprises & Discoveries: (1) Cmd+Option+←/→ never reached `keyDown` because the Tab menu's own keyEquivalent intercepted it first (commit `cfcfbacc`). (2) Ctrl+Tab never reached `keyDown` either, for an unrelated reason: AppKit reserves Control-Tab for key-view-loop navigation and swallows it in `performKeyEquivalent:`, before `keyDown:` — fixed by overriding `performKeyEquivalent(with:)` to re-dispatch to `keyDown(with:)` for that one chord (commit `98fe8eae`), root-caused via temporary diagnostic logging that showed `flagsChanged` seeing the Control press/release while `keyDown` never fired for the Tab key at all. A related hardening (disabling AppKit's native window tabbing, since Laban's tabs are its own sidebar concept — commit `420cc300`) did not turn out to be the fix, but is kept regardless as legitimate independent hygiene. Full `swift test` (2847 tests) passes.

## Decision Log

- Decision: Keyboard-triggered preview uses a hold-to-peek gesture on the
  existing *cycle* shortcuts (Ctrl+Tab, Cmd+Option+←/→, Cmd+Shift+[/]) —
  holding previews, releasing commits — rather than (a) a brief preview
  flash on every keyboard switch including the direct-jump shortcuts
  (Cmd+1…9), or (b) a dedicated preview-only shortcut with a second
  keypress to commit.
  Rationale: direct-jump shortcuts are instant, one-shot activations with no
  natural "moment" to show a preview during — there's nothing to hold. Cycle
  shortcuts already have real hold semantics on macOS (this mirrors Cmd+Tab
  app-switching, a pattern every user already knows), so extending them to
  preview-then-commit is the smallest change that fits an existing mental
  model, versus inventing a new shortcut or a timed-flash interaction with
  its own new questions (how long is "brief"? does Reduce Motion affect it?).
  User confirmed this choice directly when asked to pick between the three
  options.
  Date/Author: 2026-07-24, implementation session.

- Decision: Preview panel size and font size both scale from the *terminal
  content pane's* current size by a fixed ratio (`previewScale = 0.5`), not
  from independently chosen pixel constants.
  Rationale: this was prototyped and visually validated in the throwaway
  browser prototype `prototype/tab-hover-preview/` (see its `NOTES.md`,
  "Realistic scale" section): scaling both panel dimensions and font size by
  the same factor keeps the aspect ratio exact and keeps the same character
  budget that fits the real terminal view also fitting the preview, with no
  separate truncation constant. `0.5` read as legible and correctly
  proportioned in that prototype's zoomed-screenshot check.
  Date/Author: 2026-07-23, planning session.
- Decision: The preview has no show/hide delay or fade animation in this
  plan's scope (v1 shows/hides instantly, tied directly to
  `hoveredSidebarTabId` changing).
  Rationale: the prototype's 130ms show-delay and CSS opacity fade were
  explicitly UI polish, not load-bearing for proving the capability (see the
  prototype's `NOTES.md`, "Not verified / open questions"). Keeping v1
  instant avoids a whole additional question (does a fade need to respect
  Reduce Motion?) that a non-animated reveal sidesteps entirely, since an
  instant appear/disappear is not "motion" in the sense Laban's other
  Reduce-Motion-gated features address. Milestone 6 revisits this once the
  static version is in hand and can be judged live, per
  `docs/process/agent-operating-guide.md`'s "For UI work, verify with the
  running app" rule.
  Date/Author: 2026-07-23, planning session.
- Decision: Content resolution (session lookup + `scrollbackBlock` call) lives
  in `TerminalSurfaceController.sidebarCommands` (`LabanCore`), not inside
  `SidebarProducer`.
  Rationale: `TerminalSurfaceController` already holds `model: AppModel` and
  already has `AppModel.session(forTab:) -> Session?`
  (`Sources/LabanCore/AppModel.swift:413`) plus the existing
  `hoveredTabId` parameter on `sidebarCommands`
  (`Sources/LabanCore/TerminalSurfaceController.swift:1225`).
  `SidebarProducer` is documented as producing `FrameCommand`s from plain
  inputs (tabs, geometry) with no session access at all; keeping it that way
  means it stays trivially unit-testable with fake data (see Milestone 3).
  Date/Author: 2026-07-23, planning session.
- Decision: `runFontIdentity`'s cache key (`SlugGlyphRenderer.swift`, previously
  `sidebar: Bool` packed into bit 0 of a `UInt8`) is widened to a 2-bit
  "atlas kind" field (0 = terminal, 1 = sidebar, 2 = preview) rather than
  aliasing preview onto the sidebar bucket.
  Rationale: research (a fresh read of the function before editing, per this
  plan's own Milestone 2 step 5 instruction) confirmed the `sidebar` bool is
  purely a cache-key bit distinguishing which `FontAtlas`/reference-font
  identity a cached `(fontID, referenceVariant)` pair was resolved against —
  it is not a semantic "is this UI chrome" flag. `previewFontAtlas` is a
  genuinely different `FontAtlas` from `sidebarFontAtlas` (different point
  size: the preview's `previewScale = 0.5` ratio off the terminal size vs.
  the sidebar's fixed 11/14 ratio), so aliasing preview to `sidebar: true`
  would let a stale `CTFont`/fontID resolved against `sidebarReferenceFontAtlas`
  leak into preview glyph runs (or vice versa) whenever the cache is warm
  from both a sidebar row and a preview panel in the same session. Widening
  the key avoids that collision at the cost of two more cache slots (8 -> 16
  entries max, `bold`/`italic` unchanged at 2 bits each).
  Date/Author: 2026-07-23, implementation session.
- Decision: `TerminalBitmapView.init`'s new `previewFontAtlas` parameter is
  optional (`FontAtlas? = nil`, coalesced internally to a derived atlas),
  unlike `sidebarFontAtlas` (required, no default) at the same call site.
  Rationale: `sidebarFontAtlas` is required because every real caller
  (`MainWindowController.makeAndShow`) always has a concrete one to pass and
  the type deliberately gives call sites no accidental-default footgun. But
  24 existing test call sites across `Tests/LabanAppTests/*.swift` construct
  `TerminalBitmapView` directly without any preview-atlas awareness (they
  predate this feature and aren't testing it). Making the parameter required
  would force a mechanical, feature-irrelevant edit to all 24 files for no
  behavioral benefit. Giving it a default that derives a same-ratio preview
  atlas from the required `fontAtlas` (mirroring `FontAtlas.previewPointSize`)
  keeps those tests unchanged while `MainWindowController` still passes an
  explicit, persisted-size atlas in production. This mirrors the *renderer
  layer's* own idiom (`SlugGlyphRenderer.init`'s `sidebarFontAtlas: FontAtlas?
  = nil` coalesced to `?? fontAtlas`), just applied one layer up.
  Date/Author: 2026-07-23, implementation session.
- Decision: `TerminalSurfaceController.previewCellWidth`/`previewCellHeight`
  work (originally scoped to Milestone 4 step 1) was implemented during
  Milestone 2 instead.
  Rationale: `TerminalBitmapView`'s `previewFontAtlas` threading (Milestone 2
  step 7) and the `TerminalSurfaceController(...)` constructor call /
  `updateCellMetrics(...)` call (Milestone 4 step 1) are the same lines in the
  same function (`init` and `applyFontSize` respectively) — splitting them
  across two milestones would mean reading and re-editing the same ~30-line
  spans twice. `GlyphAtlasLadder`/`ColdLaunchAtlasPrewarmer` (the other
  `sidebarFontAtlas`-adjacent optimization paths in the same grep sweep) were
  deliberately left untouched: they only feed pre-rasterized atlas data to
  Metal/software/vector raster backends, which `SlugGlyphRenderer`'s analytic
  preview atlas doesn't need — extending them would add unused surface area.
  Date/Author: 2026-07-23, implementation session.
- Decision: the preview-panel emission logic lives in a standalone
  `static func hoverPreviewCommands(...)` on `SidebarProducer`, called both
  from inside `output(...)` (so Milestone 3's own tests, which call
  `output(hoverPreview:)` directly, see identical behavior) and, starting in
  Milestone 4, directly from `TerminalSurfaceController.sidebarCommands`
  after its memoized `build()`/`SidebarCacheSignature` lookup.
  Rationale: this is Milestone 4 step 1's option (a) from the plan's original
  Decision Log entry ("keep it simple, and keep the existing memoization's
  cost model... unpolluted by a feature with entirely different invalidation
  timing"), implemented via the plan's own suggested mechanism ("extracting
  the preview-emission logic... into a standalone function... callable
  independently of the full output(...)"). Implemented in Milestone 3 (not
  deferred to Milestone 4) since writing the extraction once, before any
  caller depends on the inline shape, was simpler than writing it inline
  first and refactoring under a caller's feet later.
  Date/Author: 2026-07-23, implementation session.

## Surprises & Discoveries

- Observation: manual testing of Milestone 7 (keyboard hold-to-peek) found that
  neither of the two documented trigger chords actually reached
  `TerminalBitmapView.keyDown` in the real app, despite `HoverPreviewKeyboardPeekTests`
  passing and mouse-hover continuing to work fine (ruling out a renderer/setting
  gate regression). Root-caused (not guessed) with a throwaway unit test that
  constructed a real `NSEvent` via `NSEvent.keyEvent(with:...)` and called
  `view.keyDown(with:)` directly — this passed immediately, proving
  `beginOrAdvancePeek`'s routing and state-machine logic were already correct in
  isolation, and narrowing the bug to something between the physical keystroke
  and that method call (a layer none of this plan's existing tests exercise; see
  `HoverPreviewKeyboardPeekTests`'s own doc comment about the same gap). Two
  distinct causes found:
  1. **Cmd+Option+←/→ (fixed, confirmed by manual test):** the Tab menu's
     "Next/Previous Tab" `NSMenuItem`s (`MenuCommands.swift`) had that exact
     chord registered as their `keyEquivalent`, wired to the pre-Milestone-7
     `@objc selectNextTab(_:)`/`selectPreviousTab(_:)` methods that call
     `selectRelativeTab(delta:)` directly. AppKit's menu key-equivalent matching
     intercepts a matching physical keystroke application-wide *before* it
     becomes a `keyDown:` event for the first responder, so the peek gesture was
     unreachable by design, not by bug — pressing the chord always took the old
     instant-switch path instead. Fixed by dropping the `keyEquivalent`
     (commit `cfcfbacc`): a menu click still instant-switches (no "hold" concept
     for a mouse click, so that's correct), and the physical chord now reaches
     `keyDown` and routes through `TerminalKeyDescriptor` normally.
  2. **Ctrl+Tab (fixed, confirmed by manual test):** had no menu-equivalent
     conflict (no menu item anywhere registers it) and no OS-level shortcut
     conflict (user checked System Settings → Keyboard → Keyboard Shortcuts,
     found nothing; a plain unmodified Tab press and Cmd+T both work normally,
     ruling out a broader keyboard regression). Disabling AppKit's native
     window-tabbing (`NSWindow.allowsAutomaticWindowTabbing = false` in
     `AppDelegate`, plus `window.tabbingMode = .disallowed` in
     `MainWindowController`, commit `420cc300`) did not fix it either — kept
     anyway as legitimate independent hygiene, but ruled out as the cause.
     Root-caused with temporary diagnostic logging in
     `TerminalBitmapView.keyDown`/`flagsChanged` (writing to `AppLog.app`,
     readable from the plain-text file at
     `~/Library/Application Support/Laban/log/` without needing Console.app):
     a user repro showed `flagsChanged` firing normally for the Control
     press/release, but **no `keyDown` entry ever appeared for the Tab key**.
     This is a third, distinct mechanism from the menu-equivalent conflict
     above: AppKit reserves Control-Tab / Control-Shift-Tab as a key-view-loop
     navigation shortcut (moving first responder between views) and swallows
     it at the `performKeyEquivalent:` stage — earlier in the event pipeline
     than `keyDown:`, and unrelated to native window tabbing. Fixed by
     overriding `performKeyEquivalent(with:)` in `TerminalBitmapView` to
     detect Control+Tab specifically and re-dispatch to `keyDown(with:)`
     (commit `98fe8eae`), which keeps `TerminalKeyDescriptor.route` as the
     single place chord-to-command mapping is decided. Diagnostic logging was
     removed once the fix was confirmed. Lesson for future AppKit keyboard
     work in this codebase: a chord not reaching `keyDown:` can have more than
     one independent cause (menu key equivalents, native window tabbing, and
     key-view-loop navigation all pre-empt `keyDown:` in different ways) —
     confirm which one with evidence (a synthetic in-process event proves the
     app's own logic; real-app logging proves what the OS actually delivered)
     rather than fixing the first plausible-sounding theory and assuming it's
     the only one.
- Observation: a third round of user feedback (after the opacity/live-update/color
  fixes were confirmed working) flagged that switching tabs via a keyboard
  shortcut (Cmd+1…9, Ctrl+Tab, Cmd+Option+←/→) while the mouse still rests
  over an unrelated sidebar row left the hover-preview panel showing that
  now-stale row. This is a genuinely different case from the existing
  active-tab-suppression guard (`hoveredTabId != activeTabId` in
  `TerminalSurfaceController.hoverPreviewOverlayCommands`): that guard only
  hides the preview when the tab you keyboard-switch *to* happens to be the
  one you were hovering — it does nothing when you switch to some *other*
  tab while still hovering a *third*, unrelated row, which is exactly what
  a rapid keyboard-navigation session looks like. Confirmed via a fresh
  Explore-agent trace before writing a fix (not assumed): every keyboard
  tab-switch path already invalidates the render loop correctly and reads
  `activeTab`/`hoveredSidebarTabId` fresh every frame with no stale
  caching, so this was not a render-invalidation bug — `hoveredSidebarTabId`
  (`Sources/LabanApp/TerminalBitmapView.swift`) is simply never cleared by
  anything except mouse-move/mouse-exit/tab-close, never by an
  active-tab-change event. Fixed by clearing it explicitly (via the
  existing private `setHoveredSidebarTab(nil)` helper, same one mouse-exit
  already uses) at the two AppKit-view entry points a keyboard/non-mouse
  tab switch always funnels through: `selectTab(at:)` (Cmd+1…9, Ctrl+Tab,
  Cmd+Option+←/→ — all keyboard shortcuts bottom out here per
  `TerminalInputView.swift`'s `TerminalKeyDescriptor.route`) and
  `selectTabFromExternalNavigation(_:)` (native notification responses —
  included for the same reason: the mouse position is unrelated to which
  tab a non-mouse trigger just activated). Deliberately did NOT touch the
  sidebar's own mouse-click tab-selection path (`selectTabPreservingSelection(_:)`'s
  third caller, the `.selectTab(let id)` case in the sidebar hit-test
  handler): clicking a row means the mouse is already hovering that exact
  row, so the existing `hoveredTabId != activeTabId` guard already
  suppresses correctly there with no extra clearing needed. No automated
  regression test added: simulating a `mouseMoved(with:)` NSEvent to set
  hover state has no precedent anywhere in this test suite (confirmed by
  search), and building that AppKit-event-simulation infrastructure from
  scratch was judged disproportionate to this one fix; verified by direct
  code reading plus the user's own manual retest instead.
- Observation: a second round of manual testing found the opacity fix
  (below) was necessary but not sufficient — the panel background painted
  correctly relative to OTHER solid rects, but the terminal's own glyph
  text still rendered through it. Root cause, found by reading `SlugGlyphRenderer.render()`'s
  actual GPU encode sequence directly (not re-trusting the earlier
  ordering-only fix): the renderer draws in **two fixed phases**, not one
  array-order painter's algorithm — ALL `.rect` commands from every source
  draw in an earlier phase (`replaceSolids` then `solids`,
  `SlugGlyphRenderer.swift` render() ~1742-1774), THEN ALL `.glyphRun`
  commands from every source draw in a strictly later, separate phase
  (~1791+). So no matter where a `.rect` sits in the command array, a
  *different source's* glyph text — which is always in the later phase —
  draws over it. Appending the preview last (the earlier fix) only
  reordered within each phase; it could never make a rect win against
  another source's glyph. The existing `.preedit` (IME composition) case
  already solved exactly this problem via an "occlusion mask" mechanism —
  `preeditMaskRects` (collected once per frame from `.rect(..., .preedit,
  ...)` commands) makes `appendGlyphRun` skip emitting any OTHER source's
  glyph cells that intersect those rects, so nothing exists in the later
  glyph phase to draw over the masked area. Generalized this to
  `overlayMaskRects` (also collecting `.sidebarPreview` rects) rather than
  building a genuine third render pass — reuses proven, already-tested
  machinery instead of duplicating ~150 lines of GPU pipeline setup
  (subpixel accumulate pass, band-scissored damage, motion-glyph buffers)
  for a new "always-last" overlay phase. Regression test:
  `SlugGlyphCorrectnessTests.testHoverPreviewPanelMasksUnderlyingTerminalGlyph`
  (verified to fail without the fix by temporarily stashing it and
  re-running, per this plan's own testing discipline).
  Evidence: `Sources/LabanRenderer/SlugGlyphRenderer.swift` render()'s draw
  sequence, read directly line-by-line before writing the fix (not
  inferred from the earlier investigation's summary, which had gotten the
  "append last" conclusion half right and half wrong).
- Observation: the same manual-testing round flagged that the preview
  showed no color ("also the preview lacks color") — a real, load-bearing
  gap, not a nice-to-have. Root cause: `Session.scrollbackBlock(...).lines()`
  (the v1 content source) is a plain-`String` accessor built for the FIND
  feature's text search; it has no per-cell color/attribute data to
  preserve, by design. Fixed by replacing the scrollback-text content path
  entirely: `TerminalSurfaceController.hoverPreviewOverlayCommands` now
  takes the hovered tab's own live `session.snapshot()` and feeds it
  through `FrameProducer` (`Sources/LabanCore/FrameProducer.swift`) — the
  SAME cell-reading/run-coalescing code the real terminal pane already
  uses every frame — configured with the preview's small cell size and
  positioned at the panel's content rect. `FrameProducer` is reused
  UNMODIFIED (deliberately: it hardcodes `source: .terminal` throughout a
  large, hot, correctness-critical function with many call sites, and
  threading a parameterized `source` through all of them for this one
  caller was judged not worth the regression risk to the main terminal
  render path). Its output is post-processed in pure Swift instead:
  `.rect`/`.glyphRun` commands with `source: .terminal` are relabeled to
  `.sidebarPreview`, rows that don't fully fit the panel's content rect
  vertically are dropped (not partially drawn), and each kept glyph run is
  truncated (by Character count, matching the plan's already-accepted v1
  truncation simplification, not display-column width) to whatever whole
  preview cells fit horizontally. This also fixed "high fps, same as main
  pane" as a side effect: real terminal color/attribute data updates every
  frame the snapshot changes, same as the main pane, with no separate
  polling or caching layer to fall behind. `SidebarProducer.HoverPreview`
  narrowed from `(tabId, lines, viewportWidth, cellWidth, cellHeight)` to
  `(tabId, viewportWidth)` since `SidebarProducer` now owns only the
  panel's chrome (border + background); geometry was extracted into a new
  pure `SidebarProducer.hoverPreviewPanelRect(...)` function shared by the
  chrome-drawing code and the controller's content-positioning code, so
  the two never compute the rect differently. `Tests/LabanCoreTests/SidebarProducerTests.swift`'s
  Milestone 3 hover-preview tests were updated for the narrower shape (one
  renamed to `testHoverPreviewOnBackgroundTabEmitsPanelChromeRects` and
  asserts only the 2 chrome rects, since content no longer flows through
  `SidebarProducer` at all). New regression test:
  `TerminalSurfaceControllerTests.testHoverPreviewContentPreservesTerminalForegroundColor`
  (feeds 24-bit-truecolor ANSI red output to the hovered tab, asserts a
  `.sidebarPreview` glyph run carries that exact color).
- Observation: Manual testing (Milestone 6) surfaced two real bugs not
  caught by the unit-test suite, because both are about *frame-to-frame*
  behavior across the renderer/controller boundary that no existing test
  exercised end-to-end.
  1. **Opacity / "terminal content shows through" bug.** Root cause:
     command *order*, not compositing mode. `TerminalSurfaceController.sidebarCommands`
     originally appended the preview's commands (`baseCommands + previewCommands`)
     and `makeFrame` used that combined list as-is — but the terminal pane's
     own background rect and grid glyphs were appended to `commands` *after*
     `sidebarCommands`'s return, in both `makeFrame` overloads. `SlugGlyphRenderer`
     draws each `FrameCommand` bucket in array order with no depth test
     (painter's algorithm: `Sources/LabanRenderer/SlugGlyphRenderer.swift`'s
     `buildInstances`/`render`), so the terminal pane's every-frame repaint —
     which always runs, hover or not — painted directly over the preview
     panel. `.replace` vs `.sourceOver` compositing was a red herring: `Theme.current.bg1`
     is fully opaque, so `.replace` and `.sourceOver` are byte-identical for
     it (`replacesDestination`'s early-out for alpha 255). Fixed by moving
     preview-command resolution out of `sidebarCommands` into a new private
     `TerminalSurfaceController.hoverPreviewOverlayCommands(...)`, called by
     both `makeFrame` overloads and appended to `commands` *last*, after the
     terminal pane's own commands, at every return path (including the
     session-nil/snapshot-nil early returns). Regression test:
     `TerminalSurfaceControllerTests.testHoverPreviewCommandsAppearAfterTerminalCommands`.
  2. **"Paused video" / stale-content bug.** Root cause: nothing invalidated
     the frame when the *hovered, non-active* tab produced new PTY output.
     Every session's dirty push already reaches `TerminalBitmapView`'s
     `model.onSessionDirty` handler (not scoped to the active tab), but
     `TerminalSurfaceController.syncSessions` only set `activeTerminalDirty`
     for the active tab; for every other tab it just called
     `session.markRendered()`. The sidebar's own "new output" signal
     (`TabMetadataSynchronizer.noteOutput`, which sets `modelChanged`) is
     deliberately edge-triggered — it fires once on the transition into
     `.unseenOutput` and then returns `false` on every subsequent tick, by
     design (a documented perf guard against re-rendering the whole sidebar
     on every streamed byte from every background tab). So a hovered
     background tab's *first* byte after hover-start would repaint, but
     nothing after that would, until some *unrelated* wake (active-tab
     cursor blink, a resize, scroll) happened to also rebuild the sidebar —
     hence "a frame of a paused video." Fixed by adding a `hoveredTabId`
     parameter to `syncSessions`: when a non-active tab's session is dirty
     and matches `hoveredTabId`, `modelChanged` is now also set (in addition
     to, not instead of, the existing `markRendered()` call), independent of
     `noteSurfaceOutput`'s edge-triggered signal. `TerminalBitmapView`'s
     `advanceFrame` threads `hoveredSidebarTabId` through. This intentionally
     does NOT touch the edge-triggered path (`TabMetadataSynchronizer.noteOutput`
     stays exactly as before) so tabs that are dirty-but-not-hovered keep the
     original perf guard. Regression test:
     `TerminalSurfaceControllerTests.testSyncSessionsHoveredInactiveTabKeepsReportingModelChanged`,
     which also locks in the *un*-hovered steady-streaming case staying silent
     (asserting the perf guard survives the fix).
  Evidence: user-reported symptoms during Milestone 6 manual testing ("the
  preview needs to have opaque background... the preview should update
  live, but now its like looking at a frame of a paused video"); root
  causes confirmed via a fresh Explore-agent code trace before any fix was
  written (both bugs' mechanisms cited above with exact file:line evidence
  in that investigation, condensed here).
- Observation: Milestone 5's file list ("mirror the exact file list
  `SpinnerMotionSmoothingSettings` touches outside `LabanCore`... 4 files")
  undercounts the real surface. `grep -rniln spinnerMotion Sources/ Tests/`
  returns 23 files, not 4: beyond `SettingsWindowController.swift`,
  `LiveIntentRouter.swift`, `ControlProjectionBridge.swift`, and
  `HeadlessDebugRuntime.swift` (the class declaration; the actual debug logic
  lives in an `extension HeadlessDebugRuntime` in a *different* file,
  `DebugStateEndpoints.swift`), full parity also touches:
  `Sources/LabanApp/TerminalBitmapView.swift` (didChangeNotification observer
  at ~934-948, a live GUI-side `spinnerMotionState` accessor at ~1365-1389,
  and the two `TerminalSurfaceFrameRequest` construction sites at ~1703-1704
  and ~3216-3217 — already covered by this plan's own Milestone 4, not new
  work, just noting the overlap);
  `Sources/LabanDebug/DebugWindowActions.swift` (the actual write-side
  handler, `setSpinnerMotionSmoothingEnabled`/`resetSpinnerMotionDiagnostics`);
  `Sources/LabanDebug/DebugRuntimeRequests.swift`,
  `Sources/LabanDebug/DebugRuntimeActions.swift`,
  `Sources/LabanDebug/HeadlessIntentRouter.swift`,
  `Sources/LabanDebug/DebugDiscoveryEndpoints.swift` (routing/dispatch glue);
  `Sources/LabanCore/Intents/IntentCatalog.swift`,
  `Sources/LabanCore/Intents/DebugRequestPayloads.swift` (intent descriptors +
  action-request Codable payload types);
  `Sources/LabanCore/Control/Projections/ControlProjectionContext.swift`,
  `Sources/LabanCore/Control/Projections/ControlResponseModels.swift`,
  `Sources/LabanCore/Control/Projections/ControlStateProjections.swift`
  (the response struct + aggregate-state wiring);
  `Sources/LabanControl/ControlRouteCatalog.swift` (HTTP route registration)
  plus a matching `schemas/debug/*.schema.json` file. Milestone 5's plan text
  is corrected below to name this full list rather than the original 4-file
  claim. No existing test exercises the spinner-motion debug endpoint or
  intents at all (verified: no `SpinnerMotionSmoothingSettingsTests.swift`,
  no debug-route test) — Milestone 5's new tests for hover-preview are
  therefore new ground, not a copy of an existing spinner-motion test.
  Evidence: `grep -rniln spinnerMotion Sources/ Tests/` (23 hits); full
  per-file line numbers captured in the implementation session's research
  pass, reproduced in Milestone 5's Plan of Work below.
- Observation: the `defaults write com.rrva.Laban ...` bundle identifier this
  plan copied from `SpinnerMotionSmoothingSettings.swift`'s doc comment (and
  by extension put into `HoverPreviewSettings.swift`'s own doc comment in
  Milestone 1) does not match the app's real bundle identifier. Confirmed via
  `./scripts/build-app --print-bundle-identifier` (prints `com.laban.LabanApp`
  from the primary checkout) and `PlistBuddy -c 'Print :CFBundleIdentifier'`
  on the built app's `Info.plist` (also `com.laban.LabanApp`). `com.rrva.Laban`
  does not appear in any `Info.plist`-generating code (`grep -rn
  "com.rrva.Laban" Sources/` only matches doc comments in
  `SpinnerMotionSmoothingSettings.swift`, `GlyphEffectSettings.swift`, and
  this plan's own `HoverPreviewSettings.swift`), so it is a stale reference
  predating some earlier bundle-identifier rename, not a currently-valid
  alternate identifier. `defaults write com.rrva.Laban ...` is a silent no-op
  against the real app (writes to a preferences domain nothing reads).
  Manual verification in this plan uses the corrected `com.laban.LabanApp`
  domain throughout. Not fixed in the two pre-existing files (out of scope
  for this feature) — worth a follow-up doc fix, flagged here for
  visibility rather than silently left for a future contributor to
  rediscover.
  Evidence: `./scripts/build-app --print-bundle-identifier` → `com.laban.LabanApp`;
  `defaults write com.laban.LabanApp LabanSidebarHoverPreviewEnabled -bool YES`
  followed by `defaults read com.laban.LabanApp LabanSidebarHoverPreviewEnabled`
  → `1`, confirming the correct domain actually persists.
- Observation: `HoverPreviewStateResponse`
  (`Sources/LabanCore/Control/Projections/ControlResponseModels.swift`)
  intentionally does not copy `SpinnerMotionStateResponse`'s telemetry
  fields (`activeTransitions`, `analyticMotionInstances`, `fallbackSnaps`,
  `effectKind`, `remainingSeconds`, `liveEffectFrames`, wave diagnostics).
  It carries only `configured`/`effectiveRenderer`/`rendererEligible`/
  `effectiveEnabled` (ADR 0031's explicit requirement) plus two
  hover-preview-specific fields, `previewedTabId`/`showing`. Rationale:
  spinner motion's telemetry fields describe per-frame motion-detector
  state with no hover-preview equivalent (the preview panel is a static
  content projection, not an animated effect) — copying the shape would
  mean fabricating meaningless zero fields. `previewedTabId`/`showing` were
  added instead because they are cheap (already-resolved local state) and
  directly answer "is a panel actually showing right now," which a debug
  client checking this endpoint would otherwise have no way to confirm.
  Date/Author: 2026-07-23, implementation session.

## Context and Orientation

Laban is a native macOS terminal app. Its terminal pane and left sidebar are
**not** drawn with SwiftUI — both are drawn by one custom `NSView` subclass,
`TerminalBitmapView` (`Sources/LabanApp/TerminalBitmapView.swift`, ~8500
lines), from a list of `FrameCommand` values built by pure, renderer-neutral
functions in the `LabanCore` Swift package target. `SidebarProducer`
(`Sources/LabanCore/SidebarProducer.swift`) is specifically the function that
turns `[Tab]` (the list of open tabs) plus some layout numbers into the
`[FrameCommand]` list for the sidebar column. `TerminalSurfaceController`
(`Sources/LabanCore/TerminalSurfaceController.swift`) is the layer above it
that assembles a full frame (terminal + sidebar) from a `TerminalSurfaceFrameRequest`
and calls `SidebarProducer` internally via its own `sidebarCommands(...)`
method.

There are five renderer backends implementing the `RendererBackend` protocol
(`SoftwareBackend`, `MetalRenderer` ("classic"), a GPU-driven cell renderer,
`VectorGlyphRenderer`, and `SlugGlyphRenderer`), all consuming the same
`[FrameCommand]` list. Which one is *configured* is a user setting; which one
is *effective* can differ (silent fallback when a renderer's requirements
aren't met, e.g. no Metal device). `TerminalBitmapView` is the only place that
computes "is the effective renderer Slug" as a real Swift type check
(`backend is SlugGlyphRenderer`, at `TerminalBitmapView.swift:1704` and
`:3217`) and threads the answer down into `LabanCore` as a plain
`Bool` field, `TerminalSurfaceFrameRequest.effectiveRendererIsSlug`
(`TerminalSurfaceController.swift:127`). This is the established pattern
(`docs/adr/0030-spinner-motion-is-a-slug-capability.md`,
`Sources/LabanCore/SpinnerMotionSmoothingSettings.swift`) for adding a
capability that only one renderer implements, without leaking that renderer's
type into `LabanCore` (which must stay renderer-neutral — it does not import
`LabanRenderer`'s concrete backends, only the shared `FrameCommand` contract).

**Hover detection already exists and needs no new code.** `TerminalBitmapView`
already tracks `hoveredSidebarTabId: Tab.ID?`
(`TerminalBitmapView.swift:268`), updated by `mouseMoved(with:)` →
`updateHoveredSidebarTab(at:)` (`TerminalBitmapView.swift:4088`), which calls
`SidebarProducer.hitTest(...)` and, on a change, calls `setHoveredSidebarTab(_:)`
(`:4110`) which stores the new id and calls `invalidateRenderAndWake()` — the
event-driven wake mechanism from `docs/adr/0018-event-driven-frame-production.md`
that tells the app "something changed, draw a new frame." That id already
flows all the way through `TerminalSurfaceFrameRequest.hoveredSidebarTabId`
into `TerminalSurfaceController.sidebarCommands(hoveredTabId:)`
(`TerminalSurfaceController.swift:1225`), called from both of
`TerminalSurfaceController`'s frame-assembly methods (local-session path at
`:908` and remote/daemon-served path at `:1136`) with the identical arguments
`hoveredTabId: request.hoveredSidebarTabId`. Today `sidebarCommands` only uses
that id to decide whether to draw the close-✕ glyph and to pass it to
`SidebarProducer.output(hoveredTabId:)`, which currently uses it the same way.
This plan adds a *second* use of the same, already-flowing id: when eligible,
resolve its tab's recent content and draw a preview panel.

`Session.scrollbackBlock(rowOffset: Int = 0, maxRows: Int = 0) -> ScrollbackBlock?`
(`Sources/LabanCore/Session.swift:883`) reads scrollback text directly from a
`Session` object, with no dependency on whether that session's tab is the one
currently on screen. `ScrollbackBlock` (`Sources/LabanCore/TerminalFind.swift:22`)
has a `lines() -> [String]` method (`TerminalFind.swift:66`) that already does
the correct byte-offset-to-per-row-`String` splitting (trailing newline/NUL
trimming included) — reuse it; do not re-derive row splitting from
`ScrollbackBlock.text`/`rowOffsets` by hand. A `Tab`'s `Session` is resolved via
`AppModel.session(forTab: Tab.ID) -> Session?` (`Sources/LabanCore/AppModel.swift:413`);
`TerminalSurfaceController` already holds `public let model: AppModel`
(`TerminalSurfaceController.swift:489`).

`SlugGlyphRenderer` (`Sources/LabanRenderer/SlugGlyphRenderer.swift`, ~3500
lines) already renders two simultaneous font sizes from one shared glyph curve
cache (`GlyphCurveStore`, keyed by `(postScriptName, pointSize, glyph, matrix)`
but always queried at a fixed `referencePointSize = 14`; on-screen size is a
render-time `pointScale = activeAtlas.pointSize / Self.referencePointSize`
factor, not a re-bake). It stores `fontAtlas`/`referenceFontAtlas` (terminal
size) and `sidebarFontAtlas`/`sidebarReferenceFontAtlas` (sidebar size,
smaller), and picks between them per-command with a plain ternary at exactly
two sites: `SlugGlyphRenderer.swift:2161` (`let activeAtlas = source == .sidebar
? sidebarFontAtlas : fontAtlas`) and `:2336-2337` (the same ternary, plus the
matching one for `referenceAtlas`, inside the function that actually emits GPU
glyph instances). Both atlas pairs are computed together, in lockstep, in
exactly two places: the `init` (`:911`) and `reconfigureFonts(fontAtlas:sidebarFontAtlas:)`
(`:1184`). This plan adds a *third* pair, `previewFontAtlas`/`previewReferenceFontAtlas`,
following the identical shape.

`FrameCommand.source` is a `FrameSource` enum
(`Sources/LabanRenderer/FrameCommand.swift:66`) with cases `.sidebar`,
`.chrome`, `.terminal`, `.cursor`, `.selection`, `.find`, `.image`, `.preedit`.
There is no exhaustive `switch` over `FrameSource` anywhere in
`Sources/LabanRenderer` or `Sources/LabanApp` that a new case would break
(verified by grep; the only two `switch source` occurrences in the whole
`Sources/` tree are unrelated `String`/`TerminalBackdropStyle` switches in
`Sources/LabanApp/SettingsWindowController.swift:1787` and
`Sources/LabanCore/Control/Projections/ControlStateProjections.swift:211`).
Adding a case is therefore additive and safe.

## Plan of Work

### Milestone 1 — Settings scaffold + `FrameCommand`/`FontAtlas` groundwork

No user-visible behavior changes yet. This milestone adds the pieces every
later milestone depends on.

1. **New file** `Sources/LabanCore/HoverPreviewSettings.swift`. Copy the exact
   shape of `Sources/LabanCore/SpinnerMotionSmoothingSettings.swift` (already
   read in full above — reproduce its structure, not its content):
   - `public enum HoverPreviewSettings`
   - `public static let enabledKey = "LabanSidebarHoverPreviewEnabled"`
   - `public static let enabledEnvironmentKey = "LABAN_SIDEBAR_HOVER_PREVIEW_ENABLED"`
   - `public static let didChangeNotification = Notification.Name("LabanSidebarHoverPreviewSettingsDidChange")`
   - `environmentOverride(environment:) -> Bool?`, `enabled` / `enabled(defaults:environment:)`,
     `setEnabled(_:defaults:environment:) -> Bool` — copy
     `SpinnerMotionSmoothingSettings`'s implementations verbatim, renaming only
     the constants above. Defaults to **off** (same opt-in posture as spinner
     motion smoothing; `docs/product/spec.md` governs new-scope defaults —
     confirm this stays consistent with any explicit default-state guidance
     there before shipping Milestone 5).
2. **Edit** `Sources/LabanRenderer/FrameCommand.swift`: add one case to
   `FrameSource` (after `case sidebar`):
   ```swift
   /// A floating live-preview panel of a background tab's recent scrollback,
   /// shown on sidebar-row hover. Slug-only; see docs/adr/0031.
   case sidebarPreview
   ```
3. **Edit** `Sources/LabanRenderer/FontAtlas.swift`: add a preview-size
   constant and derivation function mirroring the existing sidebar ones
   exactly (`sidebarPointSize(forTerminalPointSize:)` is at line 50-52):
   ```swift
   private static let defaultPreviewPointSize: CGFloat = 7.0  // 14 * 0.5

   /// Hover-preview point size derived from a terminal point size, preserving
   /// the previewScale = 0.5 ratio (see execplans/active/sidebar-hover-preview.md,
   /// Decision Log). Mirrors `sidebarPointSize(forTerminalPointSize:)`.
   public static func previewPointSize(forTerminalPointSize size: CGFloat) -> CGFloat {
     size * (defaultPreviewPointSize / defaultTerminalPointSize)
   }
   ```
   Do **not** add a `persistedPreviewPointSize` static var unless a later
   milestone finds it's actually needed at a call site — `sidebarPointSize`
   has one because sidebar atlases are built from the persisted terminal size
   at multiple points; check whether the same is true for preview before
   copying that part too.

**Milestone 1 acceptance**: `swift build` succeeds from the repository root
with no other files changed. `HoverPreviewSettings.enabled` returns `false` by
default; a unit test (add to a new
`Tests/LabanCoreTests/HoverPreviewSettingsTests.swift`, mirroring whatever
`SpinnerMotionSmoothingSettingsTests.swift` file already tests for the
existing settings type — find it with `find Tests -iname
'*SpinnerMotionSmoothingSettings*'` and copy its test shape) confirms the env
override and default-off behavior. Run `swift test --filter
HoverPreviewSettingsTests` and expect all new tests to pass.

### Milestone 2 — `SlugGlyphRenderer` third atlas + `.sidebarPreview` routing

Still no user-visible change (nothing emits `.sidebarPreview` commands yet),
but by the end of this milestone a hand-constructed `.glyphRun(..., source:
.sidebarPreview)` command, fed into `SlugGlyphRenderer` directly, renders
correctly at the smaller preview size. This is the riskiest, most
Slug-internals-specific milestone — validate it in isolation before wiring
real data into it.

1. **Edit** `SlugGlyphRenderer`: add two stored properties beside the existing
   sidebar pair (near line 407-409):
   ```swift
   public private(set) var previewFontAtlas: FontAtlas
   private var previewReferenceFontAtlas: FontAtlas
   ```
2. Extend the memberwise `init` (line ~712, alongside the existing
   `sidebarFontAtlas: FontAtlas? = nil` parameter) with
   `previewFontAtlas: FontAtlas? = nil`, and initialize the two new
   properties in the init body (near line 909-911) the same way the sidebar
   pair is:
   ```swift
   self.previewFontAtlas = previewFontAtlas ?? fontAtlas
   self.previewReferenceFontAtlas = (previewFontAtlas ?? fontAtlas).withPointSize(Self.referencePointSize)
   ```
3. Extend `reconfigureFonts(fontAtlas:sidebarFontAtlas:)` (line 1184) to
   `reconfigureFonts(fontAtlas:sidebarFontAtlas:previewFontAtlas: FontAtlas? = nil)`
   and mirror the same two assignments there.
4. At the two atlas-selection ternary sites (`:2161` and `:2336-2337`),
   replace the two-way ternary with a small private helper so the mapping
   lives in one place:
   ```swift
   private func atlas(for source: FrameSource) -> FontAtlas {
     switch source {
     case .sidebar: return sidebarFontAtlas
     case .sidebarPreview: return previewFontAtlas
     default: return fontAtlas
     }
   }
   private func referenceAtlas(for source: FrameSource) -> FontAtlas {
     switch source {
     case .sidebar: return sidebarReferenceFontAtlas
     case .sidebarPreview: return previewReferenceFontAtlas
     default: return referenceFontAtlas
     }
   }
   ```
   and use `atlas(for: source)` / `referenceAtlas(for: source)` at both call
   sites in place of the old ternaries.
5. **Check `runFontIdentity`** (referenced at `:2340`, signature
   `runFontIdentity(sidebar: source == .sidebar, bold:italic:referenceAtlas:)`):
   read its full implementation (`grep -n "func runFontIdentity" Sources/LabanRenderer/SlugGlyphRenderer.swift`)
   before editing. It almost certainly uses the `sidebar: Bool` flag as part of
   a cache key or font-fallback-identity choice. Determine whether "preview"
   needs to be a third identity bucket (likely: change the parameter from
   `sidebar: Bool` to an enum/pass `source` directly) or whether reusing the
   sidebar identity for preview is harmless (possible if the function only
   cares about "is this the smaller UI-chrome font" as a boolean, in which
   case preview should map to `true` there too, sharing the sidebar's
   fallback-cascade choice while still using its own `FontAtlas` for actual
   size). Record whichever is true in this plan's Decision Log once
   determined — do not guess silently.
6. **Edit** `Sources/LabanRenderer/RendererSelection.swift`: at the
   `SlugGlyphRenderer(...)` construction call (~line 195), thread a
   `previewFontAtlas` argument through from `makeRendererBackend`'s own
   parameters (which will need a new parameter added, threaded the same way
   `sidebar: FontAtlas` already is — check `makeRendererBackend`'s full
   signature with `grep -n "func makeRendererBackend" Sources/LabanRenderer/RendererSelection.swift`
   first). Other branches of `makeRendererBackend` (the `MetalRenderer`,
   `VectorGlyphRenderer`, `SoftwareBackend` constructions) do **not** need
   this new parameter — leave them untouched.
7. **Edit** `Sources/LabanApp/TerminalBitmapView.swift`: everywhere
   `sidebarFontAtlas` is computed and threaded (the initial construction near
   `makeBackend`'s call site, and the live-resize path in `applyFontSize`
   around line 4692-4755), compute a parallel `previewFontAtlas` via
   `FontAtlas.previewPointSize(forTerminalPointSize:)` and thread it the same
   way. Grep for every `sidebarFontAtlas` occurrence in this file first
   (`grep -n "sidebarFontAtlas" Sources/LabanApp/TerminalBitmapView.swift`) and
   treat that list as the checklist of sites needing a parallel
   `previewFontAtlas` line — do not assume the two call sites already read in
   this plan's research are the only ones.

**Milestone 2 acceptance**: add a focused test (new file
`Tests/LabanRendererTests/SlugGlyphRendererPreviewAtlasTests.swift`, or add
cases to an existing `SlugGlyphRenderer`-focused test file if one already
covers `sidebarFontAtlas` routing — find it with `grep -rl
"sidebarFontAtlas" Tests/`) that constructs a `SlugGlyphRenderer` with a
distinct `previewFontAtlas` (different point size from both `fontAtlas` and
`sidebarFontAtlas`), feeds it a single `.glyphRun(..., source: .sidebarPreview)`
command, and asserts (via whatever introspection the existing sidebar-atlas
tests use — e.g. checking `frameGlyphFontSizes` if that's how existing tests
verify which atlas a command resolved to) that the preview atlas's point size,
not the terminal or sidebar one, was used. Run `swift test --filter
SlugGlyphRendererPreviewAtlasTests` (or the actual filter name once the file
exists) and expect it to pass. `swift build` must still succeed with zero new
warnings from this file.

### Milestone 3 — `SidebarProducer` emits the preview panel

Still not wired to real hover/session data — this milestone makes
`SidebarProducer` able to draw a preview panel given already-resolved content,
and is unit-testable with fake inputs, matching how `SidebarProducer.swift`'s
existing tests (`grep -rl "SidebarProducer" Tests/`) already construct fake
`[Tab]` arrays.

1. **Edit** `Sources/LabanCore/SidebarProducer.swift`: add a nested struct
   next to the existing `DragIndicator` struct (line 40-47):
   ```swift
   /// Resolved content for the floating hover-preview panel: the tab being
   /// previewed, its most recent scrollback lines (oldest first, already
   /// truncated to a reasonable fetch bound by the caller), and the geometry
   /// inputs needed to size/position the panel and its text. `cellWidth`/
   /// `cellHeight` are the PREVIEW font's cell size (from
   /// `SlugGlyphRenderer.previewFontAtlas.cellSize`), not the sidebar's.
   public struct HoverPreview: Equatable {
     public var tabId: Tab.ID
     public var lines: [String]
     public var viewportWidth: CGFloat
     public var cellWidth: CGFloat
     public var cellHeight: CGFloat
     public init(
       tabId: Tab.ID, lines: [String], viewportWidth: CGFloat,
       cellWidth: CGFloat, cellHeight: CGFloat
     ) {
       self.tabId = tabId
       self.lines = lines
       self.viewportWidth = viewportWidth
       self.cellWidth = cellWidth
       self.cellHeight = cellHeight
     }
   }

   /// Scale applied to the terminal content pane's current width/height to
   /// get the preview panel's size, and to the terminal point size to get the
   /// preview font's point size (`FontAtlas.previewPointSize`). See
   /// execplans/active/sidebar-hover-preview.md, Decision Log.
   static let previewScale: CGFloat = 0.5
   static let previewGap: CGFloat = 10
   static let previewInset: CGFloat = 8
   ```
2. Add `hoverPreview: HoverPreview? = nil` as a new trailing parameter to
   `output(tabs:activeTabId:height:topInset:hoveredTabId:dragIndicator:scrollOffset:)`
   (line 158-163). Leave `commands(...)` (the legacy wrapper at line 61)
   unchanged — it does not need this parameter unless a caller of it turns out
   to need the feature (check with `grep -rn "\.commands(" Sources/ | grep -i
   sidebar` before deciding; if only `sidebarCommands` needs it, `output` is
   the only entry point that needs the new parameter).
3. Inside `output(...)`, after the existing tab-row loop (after line 376, before
   the drop-target-accent block at line 378), add the preview-panel emission.
   Sketch (adapt exactly to this file's real coordinate variables — `tabY`,
   `visibleRect`, `sidebarWidth`, `height`, `topInset`, `scrollOffset` are all
   already in scope from the surrounding function; this is not literal
   copy-paste code, work out the exact expressions against the real
   surrounding code):
   ```swift
   if let preview = hoverPreview, preview.tabId != activeTabId,
      let rowIndex = tabs.firstIndex(where: { $0.id == preview.tabId }),
      preview.cellWidth > 0, preview.cellHeight > 0 {
     let rowTabY = height - CGFloat(rowIndex + 1) * rowHeight - topInset + scrollOffset
     let paneWidth = max(0, preview.viewportWidth - sidebarWidth)
     let paneHeight = max(0, height - topInset)
     let panelWidth = paneWidth * Self.previewScale
     let panelHeight = paneHeight * Self.previewScale
     if panelWidth >= 2 * Self.previewInset, panelHeight >= 2 * Self.previewInset {
       var panelY = rowTabY + rowHeight - panelHeight
       panelY = min(panelY, height - panelHeight)
       panelY = max(panelY, 0)
       let panelRect = CGRect(
         x: sidebarWidth + Self.previewGap, y: panelY,
         width: panelWidth, height: panelHeight)
       // Border: a slightly larger rect painted first, background painted on
       // top inset by 1pt, so only a 1pt ring of the border color shows —
       // avoids needing a new FrameCommand case for strokes.
       cmds.append(.rect(panelRect.insetBy(dx: -1, dy: -1), color: Theme.current.dim0, source: .sidebarPreview))
       cmds.append(.rect(panelRect, color: Theme.current.bg1, source: .sidebarPreview, compositing: .replace))
       let maxCols = max(1, Int(floor((panelWidth - 2 * Self.previewInset) / preview.cellWidth)))
       let maxLines = max(1, Int(floor((panelHeight - 2 * Self.previewInset) / preview.cellHeight)))
       let shown = preview.lines.suffix(maxLines)
       for (i, line) in shown.enumerated() {
         let truncated = String(line.prefix(maxCols))
         let y = panelRect.maxY - Self.previewInset - CGFloat(i + 1) * preview.cellHeight
         cmds.append(.glyphRun(
           origin: CGPoint(x: panelRect.minX + Self.previewInset, y: y),
           text: truncated, foreground: Theme.current.fg0, background: Theme.current.bg1,
           attributes: [], source: .sidebarPreview))
       }
     }
   }
   ```
   Note the known v1 simplification: `String(line.prefix(maxCols))` truncates
   by `Character` count, not display column width, so a line containing
   wide (e.g. CJK) characters can overflow the panel width slightly. This
   mirrors the same simplification the browser prototype used and is an
   accepted limitation for v1 — do not attempt grapheme-width-aware
   truncation in this milestone; note it in `Surprises & Discoveries` if it
   turns out to look bad in Milestone 6's manual check, and scope a follow-up
   rather than scope-creeping this milestone.
4. Add unit tests to `Tests/LabanCoreTests/SidebarProducerTests.swift` (or
   wherever `SidebarProducer` is already tested — `grep -rl "SidebarProducer"
   Tests/LabanCoreTests/`): construct 2+ fake `Tab`s, call `output(...)` with a
   `hoverPreview` pointing at the non-active tab, and assert (a) at least one
   `.rect(..., source: .sidebarPreview)` and one `.glyphRun(..., source:
   .sidebarPreview)` command is present; (b) calling with `hoverPreview: nil`
   produces byte-identical output to the pre-this-milestone behavior (a
   regression guard — existing tests should already cover this if they pin
   exact command counts/content); (c) calling with `hoverPreview.tabId ==
   activeTabId` produces **no** `.sidebarPreview` commands (the
   no-preview-on-your-own-tab rule).

**Milestone 3 acceptance**: `swift test --filter SidebarProducerTests` passes,
including the three new cases above. Every pre-existing `SidebarProducerTests`
case still passes unmodified (proves the new parameter is additive).

### Milestone 4 — `TerminalSurfaceController` + `TerminalBitmapView` wiring

This is the milestone where the feature becomes live end-to-end for local
(in-process) sessions. Remote/daemon-served sessions (`laband`-hosted tabs) are
covered by the same code path since both of `TerminalSurfaceController`'s
frame-assembly methods call the same `sidebarCommands`, but verify this
explicitly in Milestone 6 rather than assuming it.

1. **Edit** `Sources/LabanCore/TerminalSurfaceController.swift`:
   - Add two new stored properties near `sidebarCellWidth`/`sidebarCellHeight`
     (line 580-581): `public var previewCellWidth: CGFloat` and
     `public var previewCellHeight: CGFloat`, set in both initializers (line
     592 and 612) the same way the sidebar pair is (default to `0` when no
     explicit value is given, matching `HoverPreview`'s guard in Milestone
     3 step 3 that skips rendering when cell size is `<= 0`).
   - Add `effectiveRendererIsSlug: Bool = false` and `hoverPreviewEnabled:
     Bool = false` as new parameters to `sidebarCommands(...)` (line
     1225-1233).
   - Inside `sidebarCommands`, before calling `producer.output(...)` (inside
     the local `build()` closure at line 1240), resolve the preview content:
     ```swift
     let hoverPreview: SidebarProducer.HoverPreview? = {
       guard effectiveRendererIsSlug, hoverPreviewEnabled,
         let hoveredTabId, hoveredTabId != activeTabId,
         previewCellWidth > 0, previewCellHeight > 0,
         let session = model.session(forTab: hoveredTabId),
         let block = session.scrollbackBlock(rowOffset: 0, maxRows: 500)
       else { return nil }
       return SidebarProducer.HoverPreview(
         tabId: hoveredTabId, lines: block.lines(), viewportWidth: sidebarWidth + terminalPaneWidthPlaceholder,
         cellWidth: previewCellWidth, cellHeight: previewCellHeight)
     }()
     ```
     The `viewportWidth` field needs the **full window content width**
     (sidebar + terminal pane), not just `sidebarWidth` — check whether
     `TerminalSurfaceController` already has that value available under a
     different name near this function (search for how `request.viewportWidth`
     from `TerminalSurfaceFrameRequest` reaches this area, since
     `sidebarCommands` itself is not currently passed the request directly —
     it may need a new `viewportWidth: CGFloat` parameter threaded from both
     call sites at line 908 and 1136, where `request.viewportWidth` is
     already in scope). Resolve this concretely; do not ship a placeholder.
   - Pass `hoverPreview: hoverPreview` into `producer.output(...)` at line
     1242-1250, and into the `build()` cache — **critical**: `hoverPreview`'s
     content (scrollback lines) changes far more often than the rest of the
     sidebar's memoization signature (`SidebarCacheSignature`, line 1258)
     accounts for. Either (a) exclude `hoverPreview` from the
     `SidebarCacheSignature` equality check and always append its commands
     fresh after the memoized `build()` result (cleanest — the preview panel
     commands are cheap to regenerate every call, unlike the whole sidebar),
     or (b) include a content hash of `hoverPreview` in the signature. Prefer
     (a): keep it simple, and keep the existing memoization's cost model
     (built for the "don't rebuild every tab's title on every frame" problem)
     unpolluted by a feature with entirely different invalidation timing. If
     you choose (a), make sure the preview commands are appended in the
     `hoveredTabId == nil` early-return-equivalent case too (i.e. don't skip
     appending "no preview" — there's nothing to append when `hoverPreview ==
     nil`, so this reduces to: call `build()`/use the cached `output.commands`
     as today, then separately compute and append preview commands via a
     *second*, small `SidebarProducer.output(...)` call or by extracting the
     preview-emission logic from Milestone 3 into a standalone function
     `SidebarProducer.hoverPreviewCommands(tabs:activeTabId:height:...:hoverPreview:)`
     callable independently of the full `output(...)`. Pick whichever keeps
     `SidebarProducer`'s public surface simplest and document the choice in
     this plan's Decision Log once made.
   - Thread the two new `sidebarCommands` parameters through both call sites
     (line 908 and 1136): `effectiveRendererIsSlug: request.effectiveRendererIsSlug`,
     `hoverPreviewEnabled: ` — this needs a new field on
     `TerminalSurfaceFrameRequest` itself, `hoverPreviewEnabled: Bool = false`,
     added the same way `spinnerMotionSmoothingEnabled` was added (struct
     field at line ~126, init parameter + assignment at line ~159/190).
2. **Edit** `Sources/LabanApp/TerminalBitmapView.swift`: wherever
   `TerminalSurfaceFrameRequest(...)` is constructed with
   `spinnerMotionSmoothingEnabled: SpinnerMotionSmoothingSettings.enabled`
   (grep for that exact string to find the site(s)), add a parallel
   `hoverPreviewEnabled: HoverPreviewSettings.enabled` argument. Also set
   `controller.previewCellWidth`/`previewCellHeight` wherever
   `controller.sidebarCellWidth`/`sidebarCellHeight` are currently assigned
   (grep for `sidebarCellWidth =` in this file), sourcing the values from the
   `previewFontAtlas.cellSize` computed in Milestone 2 step 7.
3. Listen for `HoverPreviewSettings.didChangeNotification` wherever
   `SpinnerMotionSmoothingSettings.didChangeNotification` is already observed
   in `TerminalBitmapView.swift` (grep for that string), and trigger the same
   kind of `invalidateRenderAndWake()` follow-up so toggling the setting live
   takes effect on the next frame without needing a relaunch.

**Milestone 4 acceptance**: this is the first milestone with real observable
behavior. Build the app (`./scripts/build-app` from the repository root —
**not** bare `swift build`, per `docs/process/agent-operating-guide.md`),
install it to a dedicated path so it doesn't clobber any other running
instance (`LABAN_INSTALL_PATH=~/Laban-hover-preview.app ./scripts/install-app`
— check the exact env var name `docs/process/worktree-isolation.md` or
`agent-operating-guide.md` documents for a dedicated install path before
running this; do not guess it), then:
```sh
defaults write com.laban.LabanApp LabanSidebarHoverPreviewEnabled -bool YES
```
(`com.laban.LabanApp` is the app's real bundle identifier, confirmed via
`./scripts/build-app --print-bundle-identifier` from the primary checkout and
`PlistBuddy -c 'Print :CFBundleIdentifier'` on the built `Info.plist`. The
doc comments this plan's Milestone 1 copied verbatim from
`SpinnerMotionSmoothingSettings.swift` say `com.rrva.Laban`, which is stale
in *that* pre-existing file too — see Surprises & Discoveries.)
Launch the installed app (the user launches it manually — do not `open` or
otherwise launch the GUI app yourself from the shell), open 2+ tabs with
different visible content in each (e.g. run a different command in each), and
hover a non-active tab's sidebar row. Expect a panel to appear beside that row
showing that tab's recent output. Moving the mouse to the active tab's row, or
off the sidebar entirely, must make the panel disappear.

### Milestone 5 — Settings UI checkbox + debug endpoint + headless parity ✅ (2026-07-23)

Settings UI checkbox: `SettingsWindowController.swift` gained
`hoverPreviewCheckbox`, wired identically to the spinner-motion checkbox
(same rendering-settings grid row, same `isEnabled = (selection ==
.slugGlyph) && !envLocked` disable rule, same toggle-handler shape). Debug
endpoint: `GET /debug/sidebar-hover-preview` (intent `hoverPreview.state`)
returns `HoverPreviewStateResponse`; write action `hoverPreview.setEnabled`
(legacy name `setHoverPreviewEnabled`) persists the setting through
`HoverPreviewSettings.setEnabled`. Both headless (`HeadlessDebugRuntime` via
`ControlProjectionBridge`) and live-GUI (`TerminalBitmapView.hoverPreviewState`
→ `MainWindowController` → `LiveControlEnvironment` → `LiveIntentRouter`)
paths report state through the same `ControlStateProjections.hoverPreviewResponse`
accessor, satisfying AGENTS.md's `HeadlessDebugRuntime` feature-parity rule.
`swift run LabanControlGen --write` regenerated the committed
`schemas/debug/discovery-endpoints.json`; `IntentCatalogTests` and
`DiscoveryEndpointParityTests` both required a one-line update each (new
intent id in a fixture-catalog membership check; regenerated doc). Full
`swift test` passes (0 failures) after all fixes.

**Corrected file list** (see Surprises & Discoveries for how this was
discovered to be larger than 4 files): `Sources/LabanApp/SettingsWindowController.swift`
(checkbox), `Sources/LabanApp/Control/LiveIntentRouter.swift` (live GUI query
dispatch + `LiveControlEnvironment` provider field), `Sources/LabanApp/TerminalBitmapView.swift`
(`hoverPreviewState` computed property, mirroring `spinnerMotionState`),
`Sources/LabanApp/MainWindowController.swift` (wires the real provider into
`LiveControlEnvironment`), `Sources/LabanDebug/ControlProjectionBridge.swift`
(headless provider closure), `Sources/LabanDebug/DebugStateEndpoints.swift`
(the `hoverPreview()` HTTP-facing method), `Sources/LabanDebug/DebugWindowActions.swift`
(`setHoverPreviewEnabled` write handler), `Sources/LabanDebug/DebugRuntimeRequests.swift`,
`Sources/LabanDebug/DebugRuntimeActions.swift`, `Sources/LabanDebug/HeadlessIntentRouter.swift`,
`Sources/LabanDebug/DebugDiscoveryEndpoints.swift` (routing/dispatch/discovery
glue), `Sources/LabanCore/Intents/IntentCatalog.swift`,
`Sources/LabanCore/Intents/DebugRequestPayloads.swift` (intent descriptors +
action payload type), `Sources/LabanCore/Control/Projections/ControlProjectionContext.swift`,
`Sources/LabanCore/Control/Projections/ControlResponseModels.swift`,
`Sources/LabanCore/Control/Projections/ControlStateProjections.swift`
(new `HoverPreviewStateResponse` + aggregate `StateResponse.hoverPreview`
field), `Sources/LabanControl/ControlRouteCatalog.swift` (both the
documented `endpoint(...)` catalog entry AND the separate
`legacyJSONReadRoutePaths` list that actually builds the dispatchable
`ControlRoute` — the catalog entry alone does not make a route reachable),
`schemas/debug/sidebar-hover-preview.schema.json` (new file, mirrors
`schemas/debug/spinner-motion.schema.json`'s shape), and the generated
`schemas/debug/discovery-endpoints.json` (regenerated via `swift run
LabanControlGen --write`, not hand-edited).

Mirror the exact file list `SpinnerMotionSmoothingSettings` touches outside
`LabanCore` (found via `grep -rl "SpinnerMotionSmoothingSettings" Sources/`):
`Sources/LabanApp/SettingsWindowController.swift` (checkbox, disabled when
`!effectiveRendererIsSlug`, same disabled-state UX as the spinner-motion
checkbox), `Sources/LabanApp/Control/LiveIntentRouter.swift` (control-plane
intent to read/write the setting live), `Sources/LabanDebug/ControlProjectionBridge.swift`
and `Sources/LabanDebug/HeadlessDebugRuntime.swift` (debug endpoint reporting
`configured`/`rendererEligible`/`effectiveEnabled`, matching ADR 0030's
"Applies To New Code" precedent, plus headless parity per this repo's
standing rule that `HeadlessDebugRuntime` must stay in feature parity with
the visible app path). Read each file's existing spinner-motion-smoothing
code as the template before writing the hover-preview equivalent; do not
invent a different shape.

**Milestone 5 acceptance**: the Settings window shows a hover-preview
checkbox that is visibly disabled (grayed out, per whatever visual convention
the spinner-motion checkbox already uses) when the configured renderer isn't
Slug. A debug request (find the exact route the spinner-motion debug state
uses via `grep -rn "spinnerMotion" Sources/LabanDebug/` and use the sibling
route for hover preview once created) returns JSON containing `configured`,
`rendererEligible`, and `effectiveEnabled` keys with correct values in at
least two states: setting off, and setting on with a non-Slug renderer forced
(`LABAN_RENDERER` env var — check its accepted values via
`Static.launchForcesSoftwareRenderer` in `TerminalBitmapView.swift:1184` and
any sibling env vars for forcing other renderers).

### Milestone 6 — Manual verification, polish pass, Review Gate

1. Use the `laban-terminal-control` skill (`laban session screenshot`) to
   capture the running app with a preview visible, and visually confirm text
   is crisp (not blurry) at the small preview size, matching the browser
   prototype's own "zoomed screenshot confirms crisp text" verification step.
2. Revisit the Decision Log's "no fade/delay" decision live: if the instant
   appear/disappear feels visually jarring in practice (the concern the
   prototype's 130ms debounce addressed — flashing during a fast mouse pass
   over multiple rows), decide whether to add a show-delay. If added, gate any
   *animated* portion (not the instant reveal itself) behind Reduce Motion,
   consistent with how every other timed visual effect in this codebase is
   gated. Record the outcome in `Surprises & Discoveries`.
3. Verify the remote/daemon-served frame-assembly path (line 1136's caller)
   also shows the preview correctly for a `laband`-hosted tab, not only the
   local-session path — this was flagged as unverified-by-construction in
   Milestone 4's context, not merely "probably fine."
4. Run `./scripts/check` (the repository's full check suite) and `./scripts/test`
   (or `swift test` for the full suite if `./scripts/test` is narrower — check
   which) from the repository root and confirm a clean pass.
5. Spawn a fresh review agent (no prior context from this implementation
   session) with the Agent tool, per `PLANS.md`'s Review Gate process, and run
   every item in the Review Gate section below.

## Review Gate

- [x] `grep -rn "sidebarFontAtlas" Sources/LabanRenderer/SlugGlyphRenderer.swift`
      and confirm every site that has a sidebar-atlas branch also has a
      matching preview-atlas branch (no site was updated for sidebar and
      missed for preview).
- [x] `grep -rn "switch source" Sources/` returns 5 matches: 2 pre-existing
      unrelated ones (`SettingsWindowController.swift`,
      `ControlStateProjections.swift` — neither switches over `FrameSource`)
      and 3 in `Sources/LabanRenderer/SlugGlyphRenderer.swift` this feature
      added (`atlas(for:)`, `referenceAtlas(for:)`, `atlasKind(for:)`). For
      each of those 3, confirm it has a `default:` case (not an exhaustive
      per-case list) — `grep -A5 "private func atlas(for source\|private func referenceAtlas(for source\|private func atlasKind(for source" Sources/LabanRenderer/SlugGlyphRenderer.swift`
      and check each block ends in `default:`. This is what makes them safe
      against a future `FrameSource` case: it falls into `default` rather
      than requiring every switch site to be updated in lockstep.
- [x] Run `swift test --filter SidebarProducerTests`; expect 100% pass
      including the 3 new hover-preview cases from Milestone 3.
- [x] Run `swift test --filter HoverPreviewSettingsTests`; expect 100% pass.
- [x] Run `swift test --filter HoverPreviewRendererGateTests`; expect 100%
      pass. This is the mechanical replacement (added after the first review
      round) for what used to be three manual live-app steps: non-Slug
      renderer + setting on → no preview; Slug + setting off → no preview;
      Slug + setting on + hovering the active tab's own row → no preview;
      plus a positive control proving the other three aren't vacuous.
- [x] Run `swift test --filter HoverPreviewKeyboardPeekTests`; expect 100%
      pass (Milestone 7's peek/advance/commit state machine, including
      wraparound and the commit-with-nil-tabId no-op case).
- [x] `grep -n "keyEquivalentModifierMask" Sources/LabanApp/MenuCommands.swift`
      — confirm the "Previous Tab"/"Next Tab" `NSMenuItem`s do **not** appear
      (both must have `keyEquivalent: ""` and no modifier mask). If either
      has a keyEquivalent again, Cmd+Option+←/→ will silently stop reaching
      `keyDown` and hold-to-peek will regress exactly as it did before commit
      `cfcfbacc`.
- [x] `grep -n "override func performKeyEquivalent" Sources/LabanApp/TerminalBitmapView.swift`
      — exactly one hit. Its absence means Ctrl+Tab is being swallowed by
      AppKit's key-view-loop navigation before `keyDown` ever fires (the
      regression fixed in commit `98fe8eae`).
- [x] `./scripts/check` exits 0.
- [ ] Re-read `docs/adr/0031-sidebar-hover-preview-is-a-slug-capability.md`
      against the final implementation and confirm every file it names still
      matches reality (renumber/reword any drift found during implementation
      rather than leaving the ADR stale).

Review status: FAILED (2026-07-24) — see findings

Review findings (filled in by the review agent):

Fresh Review Gate pass at commit `19de71886ee10fd64c98470090eb6706737d55de`.
Items 1-9 all passed cleanly and exactly as specified:
(1) every `sidebarFontAtlas` site in `SlugGlyphRenderer.swift` (property decl
line 407, init param line 718, init assignment lines 914/917,
`reconfigureFonts` lines 1193/1196/1199, `atlas(for:)` line 2343) has a
matching `previewFontAtlas` branch alongside it. (2) `grep -rn "switch source"
Sources/` returns exactly 5 matches — `SettingsWindowController.swift:1766`
(switches over `TerminalBackdropStyle`, unrelated),
`ControlStateProjections.swift:218` (switches over `String`, unrelated), and
`SlugGlyphRenderer.swift:2342/2353/2615` (`atlas(for:)`, `referenceAtlas(for:)`,
`atlasKind(for:)`), each ending in a `default:` case. (3) `swift test --filter
SidebarProducerTests`: 52/52 passed, including
`testHoverPreviewOnActiveTabEmitsNoPreviewCommands`,
`testHoverPreviewOnBackgroundTabEmitsPanelChromeRects`,
`testNilHoverPreviewEmitsNoPreviewCommands`. (4) `swift test --filter
HoverPreviewSettingsTests`: 9/9 passed. (5) `swift test --filter
HoverPreviewRendererGateTests`: 4/4 passed. (6) `swift test --filter
HoverPreviewKeyboardPeekTests`: 4/4 passed. (7) `grep -n
"keyEquivalentModifierMask" Sources/LabanApp/MenuCommands.swift` returns 5
matches, none for the Tab menu; direct inspection of
`Sources/LabanApp/MenuCommands.swift:215-226` confirms both "Previous Tab" and
"Next Tab" `NSMenuItem`s use `keyEquivalent: ""` with no modifier mask, with a
comment explaining why. (8) `grep -n "override func performKeyEquivalent"
Sources/LabanApp/TerminalBitmapView.swift` returns exactly one hit, line 5509.
(9) `./scripts/check` exited 0 (full output scanned for `fail`/`error:`,
nothing beyond expected zero-failure test-suite summaries).

Item 10 (ADR re-read) did **not** pass: two of the ADR's three `file:line`
citations have drifted from the actual current source.
`docs/adr/0031-sidebar-hover-preview-is-a-slug-capability.md` line 69 cites
`sidebarCommands(hoveredTabId:)` at
`Sources/LabanCore/TerminalSurfaceController.swift:1288`; the function
actually starts at **line 1299** (`grep -n "func sidebarCommands"
Sources/LabanCore/TerminalSurfaceController.swift`). The same ADR paragraph's
line 72 cites the private `hoverPreviewOverlayCommands(hoveredTabId:...)` at
`Sources/LabanCore/TerminalSurfaceController.swift:1396`; the function
actually starts at **line 1407** (`grep -n "func hoverPreviewOverlayCommands"
Sources/LabanCore/TerminalSurfaceController.swift`). Both are off by exactly
11 lines, and both functions' names, parameter shapes, and described roles
are otherwise accurate (read in full — `sidebarCommands` at 1299-1306 and
`hoverPreviewOverlayCommands` at 1407-1415 match the ADR's description
verbatim); this reads as an unrelated intervening edit shifting line numbers
in `TerminalSurfaceController.swift` after the ADR was last checked (recent
history includes commits `e80239a6`/`4f253cec` touching adjacent settings
code), not a drift in the mechanism itself. Every other claim in the ADR was
verified against current source and found accurate: the
`SlugGlyphRenderer.swift:2341`/`:2352` citations for `atlas(for:)`/
`referenceAtlas(for:)` are exact; the `peekedSidebarTabId ?? hoveredSidebarTabId`
combination pattern is present at 8 sites in `TerminalBitmapView.swift`
(e.g. lines 1445, 1746, 2839, 3258); the `overlayMaskRects` occlusion-mask
mechanism collecting `.preedit`- and `.sidebarPreview`-tagged rects is at
`SlugGlyphRenderer.swift:2151-2154`, matching the ADR's description exactly;
`runFontIdentity`'s cache key is a 2-bit `atlasKind(for:)` field as claimed;
`Session.scrollbackBlock` has zero references left in
`TerminalSurfaceController.swift`, `SidebarProducer.swift`, or
`TerminalBitmapView.swift`, confirming the ADR's "no longer used by this
feature at all" claim; `SidebarProducer.output(...)` (line 184) no longer
takes a `hoverPreview` parameter, and the standalone
`hoverPreviewPanelRect(...)`/`hoverPreviewCommands(...)` functions (lines 448,
475) and the `HoverPreview` struct's narrowed `{tabId, viewportWidth}` shape
(lines 58-65) exist exactly as the ADR and plan's Interfaces section describe;
the Settings checkbox disable rule (`SettingsWindowController.swift:875`,
`slugSelected && !hoverPreviewEnvLocked`) matches; and no
`sidebarPreview`/`previewFontAtlas`/`HoverPreview` references exist in
`SoftwareBackend`, `MetalRenderer`, or `VectorGlyphRenderer` files, confirming
non-Slug renderers are untouched. **Fix needed**: update the two stale
line-number citations in `docs/adr/0031-sidebar-hover-preview-is-a-slug-capability.md`
(`:1288` → `:1299`, `:1396` → `:1407`) — or reword them to avoid pinning
exact line numbers that drift — then re-run this Review Gate item.

## Validation and Acceptance

The feature is complete when all of the following hold, verified against a
real running app built via `./scripts/build-app` and installed to a dedicated
path (never launched via `open`/shell — the user launches it):

1. Slug renderer active, setting on, 2+ tabs with distinct content: hovering a
   background tab's sidebar row shows a floating panel with that tab's recent
   output within one frame of the hover starting; moving off the row removes
   it within one frame.
2. The panel's text is crisp at its small size (confirmed via a zoomed
   `laban session screenshot` capture, not merely "looks fine" at normal
   zoom).
3. Any other renderer, or the setting off, or hovering the active tab's own
   row: sidebar behaves exactly as it did before this change (byte-identical
   `FrameCommand` output for the sidebar aside from the pre-existing
   hover-close-✕ behavior — verified by the Milestone 3 regression test).
4. `swift test --filter SidebarProducerTests`, `swift test --filter
   HoverPreviewSettingsTests`, and `./scripts/check` all pass.
5. The Review Gate above has passed cleanly per `PLANS.md`'s review-fix loop.

## Interfaces and Dependencies

- `Sources/LabanCore/HoverPreviewSettings.swift` (new): public API
  `enabled: Bool`, `enabled(defaults:environment:) -> Bool`,
  `setEnabled(_:defaults:environment:) -> Bool`, `didChangeNotification`,
  `enabledKey`, `enabledEnvironmentKey`.
- `Sources/LabanRenderer/FrameCommand.swift`: `FrameSource` gains
  `case sidebarPreview`.
- `Sources/LabanRenderer/FontAtlas.swift`: new
  `static func previewPointSize(forTerminalPointSize: CGFloat) -> CGFloat`.
- `Sources/LabanRenderer/SlugGlyphRenderer.swift`: new public
  `previewFontAtlas: FontAtlas` property; `init` and `reconfigureFonts` gain a
  `previewFontAtlas: FontAtlas? = nil` parameter.
- `Sources/LabanCore/SidebarProducer.swift`: new public nested
  `HoverPreview` struct (`{tabId: Tab.ID, viewportWidth: CGFloat}`); the panel
  is built by two standalone static functions,
  `hoverPreviewPanelRect(...)` (pure geometry) and `hoverPreviewCommands(...)`
  (chrome rects only), **not** a parameter on `output(...)` — that parameter
  was removed once it became dead code (commit `aa30bb1a`) after the
  color-fidelity rewrite moved real content resolution into
  `TerminalSurfaceController`.
- `Sources/LabanCore/TerminalSurfaceController.swift`: private
  `hoverPreviewOverlayCommands(...)` resolves content via
  `session.snapshot()` + `FrameProducer`; `sidebarCommands(...)` itself no
  longer takes `viewportWidth`/`effectiveRendererIsSlug`/`hoverPreviewEnabled`
  (those were dead there too and removed in the same cleanup). New
  `previewCellWidth`/`previewCellHeight: CGFloat` public properties.
  `TerminalSurfaceFrameRequest` gains `hoverPreviewEnabled: Bool = false`.
- `Sources/LabanApp/TerminalBitmapView.swift` (Milestone 7): `peekedSidebarTabId:
  Tab.ID?` and `peekCommitModifiers: NSEvent.ModifierFlags` (both `internal`
  for test access); `beginOrAdvancePeek(delta:triggerModifiers:)`,
  `commitPeek(tabId:)`; `override func performKeyEquivalent(with:)` re-dispatches
  Control+Tab to `keyDown(with:)`. Every read of "which tab is being
  previewed" combines `peekedSidebarTabId ?? hoveredSidebarTabId`.
- Depends on already-existing, unmodified APIs: `AppModel.session(forTab:)`,
  `Session.snapshot()` / `laban_snapshot_destroy`, `FrameProducer`,
  `TerminalBitmapView.hoveredSidebarTabId` and its update path, `Theme.current`
  color tokens (`bg1`, `dim0`, `fg0`).
- No changes required to `SoftwareBackend`, `MetalRenderer`,
  `VectorGlyphRenderer`, or any non-Slug renderer file.
