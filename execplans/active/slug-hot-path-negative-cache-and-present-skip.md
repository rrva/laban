# Cut slug renderer per-frame CPU: negative glyph cache, font-metric caching, and redundant-present skip

This ExecPlan is a living document maintained in accordance with `PLANS.md` (repository root). Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

The slug glyph renderer (`Sources/LabanRenderer/SlugGlyphRenderer.swift`, the analytic curve-based text renderer selectable in Laban's renderer settings) burns CPU every frame on work whose result never changes: it re-resolves glyphs that failed resolution before, re-queries CoreText for the font cell size on every glyph run, and blits an unchanged frame to the screen up to 120 times per second. After this change, a busy TUI workload (Claude Code with a spinner) drops from ~4,000 cold glyph-resolution attempts per second to near zero, and the present thread encodes ~12 blits per second instead of ~110, with zero visible difference. The wins were measured, not guessed: a signpost-instrumented 20 s Instruments trace (`~/Downloads/Untitled7.trace`, build `fd06aa7e`) quantifies each one, and the same recipe re-measures them after.

Measured baseline (20 s trace, Claude Code TUI with spinner + light output, ~12 app frames/s):

    slug.glyphBuild   n=79,882  total=4549ms of span time  (~4,000/s cold-path entries)
    slug.present      n=2,158   88.7% presented the SAME published frame version as the previous present
    slug.render       n=243     instance counts identical for full and banded frames (~1,505 glyphs + ~330 raster + 31 solids every frame)
    slug.skipFrame    n=0       the existing empty-damage skip never fired in this workload
    FontAtlas.cellSize.getter   213 of 317 CTFontGetGlyphsForCharacters samples in the whole trace
    CTFontCopyPostScriptName    ~0.5% of trace CPU, called once per glyph run per frame

## Progress

- [x] (2026-07-10) Signpost instrumentation shipped (`slug.render`, `slug.publish`, `slug.present`, `slug.encodeBlit`, `slug.skipFrame`, `slug.glyphBuild`, `slug.geometryUpload`) — commits `ff77024`, `fd06aa7`.
- [x] (2026-07-10) Baseline captured and analyzed (`Untitled7.trace`, numbers above).
- [x] (2026-07-10) M0: Negative-cache failed glyph resolutions in `ensureGlyph`. Commit `115a838`.
- [x] (2026-07-10) M1: Make `FontAtlas.cellSize` a stored property. Commit `096be82`.
- [x] (2026-07-10) M2: Cache per-(source, bold, italic) font identity so `CTFontCopyPostScriptName` leaves the per-run path. Commit `4b213e7`.
- [x] (2026-07-10) M3: Hoist the no-decoration early-out to `appendGlyphRun`'s call site of `appendDecorations`. Commit `b03c9d4`.
- [x] (2026-07-10) M4: Skip redundant re-present blits when the published frame version is unchanged. Commit `2475666`.
- [x] (2026-07-10) M5: Damage-aware instance building (only build instances intersecting effective damage bands). Commit `c7437f8`.
- [x] (2026-07-10) Re-measure captured and analyzed; see `Outcomes & Retrospective`. Build `8ca61689` installed to `~/Laban.app` and restarted via `scripts/restart-app --scroll-debug`; 20 s CPU-only xctrace capture of a spinner workload driven through `POST /scroll/input`.
- [x] (2026-07-10) User verified: manual alternate-screen TUI flicker regression check for M4 (commit `f371eaa`'s scenario) passed; no flicker or stale frames with a focused Laban window running a fullscreen TUI.
- [x] (2026-07-10) Focused-window live verification of the M4 skip rate: over 15 s of a spinner workload with the window focused, `GET /scroll/present-stats` reported callbacks=174, presented=57, so 117 (67%) of present-link callbacks skipped the redundant blit. (The baseline's 88.7% figure came from a busier vsync-rate capture; the mechanism is confirmed either way: presented now tracks published frames instead of vsyncs.)

This plan is complete: all milestones implemented, re-measured, and the M4 visual regression check passed.

## Outcomes & Retrospective

Re-measure (2026-07-10, build `8ca61689`, 20 s `xctrace --template 'Metal with laban signposts' --attach`, CPU-only analysis; signpost tables empty as always for CLI captures on this machine, so the comparison is Time Profiler subtree shares of kept sample weight; workload: python spinner + periodic scroll lines via the scroll-debug server, Laban window unfocused):

    subtree / symbol              baseline (Untitled7)   re-measure   change
    appendGlyphRun subtree                14.64%           1.33%      11x lower
    ensureGlyph subtree                   12.26%           0.41%      30x lower
    glyph atlas/font lookup category       2.55%           0.01%      gone
    CTFontGetGlyphsForCharacters        317 samples        0          gone (M0+M1)
    CTFontCopyPostScriptName           ~154 samples        0          gone (M2)
    metal command encode category          5.12%           1.05%      5x lower
    encodeBlit subtree                     2.85%           0.27%      10x lower
    appendDecorations subtree              1.12%           0.09%      12x lower

Caveats: the workloads are not identical (baseline drove Claude Code's TUI; re-measure drove a python spinner with similar output shape), so treat ratios as indicative. The structural signals are workload-independent though: both CTFont symbols went to literally zero (they were called unconditionally per run/per access before), and the ensureGlyph subtree collapse matches M0's design (cold path now enters only for genuinely novel clusters). The present-thread numbers (encodeBlit) are deflated by the unfocused window parking the link; the focused-window skip verification remains open above.

What remains for a future plan: the baseline's damage-blind instance counts came from `slug.render` end messages; after M5 those counts shrink on banded frames, and the `slug.presentSkip` event counts skips directly. Both need a GUI-Instruments Immediate-mode capture (see Concrete Steps) to observe, since CLI xctrace cannot record signposts here.

## Context and Orientation

Laban is a macOS terminal. Its renderers live in `Sources/LabanRenderer/`. The slug renderer draws ordinary text by evaluating quadratic glyph outlines analytically in a fragment shader; color emoji and CJK fall back to raster atlases. Key flow, all in `Sources/LabanRenderer/SlugGlyphRenderer.swift`:

- `render(_:damage:)` (~line 880) is called on the main thread ~once per terminal frame with draw commands and a damage description (`.full` or `.partial(yRanges:)`). It resolves *effective* damage per target-ring slot (`resolveEffectiveDamage`), builds instance arrays (`buildInstances` → `appendGlyphRun`), encodes Metal passes, and commits. On completion it publishes the offscreen target (`publishLatestTarget`).
- A `VectorPresentDisplayLink` (`Sources/LabanRenderer/VectorPresentDisplayLink.swift`) fires on every vsync (up to 120 Hz on ProMotion) on thread `laban.vector.present-link` and calls `presentLatestTarget(into:)` (~line 2075), which blits the latest published target into the drawable — currently *unconditionally*, even when nothing new was published since the last vsync.
- `ensureGlyph(for:referenceAtlas:referenceVariant:fontID:attributes:)` (~line 1625) resolves a character cluster to curve geometry, front-cached by `entriesByResolveKey` (a `[SlugGlyphResolveKey: SlugGlyphEntry]` dictionary keyed on interned font ID + cluster).
- "Signposts" are `os_signpost` intervals/events emitted through `RenderEncodeSignpost` (`Sources/LabanRenderer/RenderEncodeSignpost.swift`, subsystem `com.rrva.laban.render`, category `encode`). They appear in Instruments' os_signpost track and in `xctrace export` tables. They are how this plan measures before/after.

Definitions used below:

- *Cold path*: the body of `ensureGlyph` past the `entriesByResolveKey` lookup (~line 1633) — CTFont glyph resolution, outline extraction, band building. Wrapped by the `slug.glyphBuild` signpost span.
- *Published frame version*: `publishedFrameVersion` (~line 282), a `UInt64` incremented by `publishLatestTarget` each time `render` publishes a new frame; carried in the `slug.publish` event and `slug.present` span messages.
- *Effective damage*: the union of a frame's incoming damage with per-ring-slot accumulated damage, computed by `resolveEffectiveDamage`; `.full` or a set of y-bands that becomes Metal scissor rects.

## Surprises & Discoveries

- Observation: `ensureGlyph` has no negative cache. Any cluster whose resolution returns `nil` re-runs the entire cold path on every appearance in every frame, forever. The two `nil` exits are: `resolveGlyph` fails, or the outline has no curves (`guard !outline.curves.isEmpty`, ~line 1657) — the latter is what every space character hits. In the baseline trace this produced 79,882 cold-path entries in 20 s (~330 per frame, matching the ~330 raster-fallback instances per frame), ~4.5 s of accumulated span time on the main thread.
  Evidence: `slug.glyphBuild n=79882` vs `slug.render n=243`; per-frame raster instance counts `raster= 329..331` in `slug.render` end messages.
- Observation: while a trace is recording, the signpost emit machinery itself dominates the cold path (69% of `ensureGlyph`-subtree Time Profiler rows are `_os_signpost_emit_with_name_impl` / `osSignpostWithoutMessage` closures). M0 collapses the span rate from ~4,000/s to ~new-glyphs-only, which also makes future traces clean. Until M0 lands, treat `slug.glyphBuild` span *totals* as inflated roughly 2x; the *count* is accurate.
- Observation: 88.7% of present-link blits (1,915 of 2,158) re-presented a frame version already on screen. The park policy never engaged because the workload was continuously "active" (spinner). Runs of 5–15 presents of the same version dominate.
  Evidence: consecutive `slug.present` spans with identical `v=` values in `Untitled7.trace` table 7.
- Observation: instance building is damage-blind. Frames whose effective damage was `bands:4`/`bands:5` still built the full ~1,505 slug glyphs + ~330 raster instances; only the GPU fragment work is scissored.
  Evidence: `slug.render` end messages show the same instance counts for `eff= full` and `eff= bands:N` frames.
- Observation: `FontAtlas.cellSize` (`Sources/LabanRenderer/FontAtlas.swift:163`) is a computed property performing two CoreText calls per access, and the slug path accesses it several times per glyph run per frame. 213 of the trace's 317 `CTFontGetGlyphsForCharacters` samples came from this getter, not from glyph resolution.
- Observation: `swift test --filter Vector` (run per M1's validation instructions, since `cellSize` is shared across renderers) has a pre-existing failure unrelated to this plan: `VectorZoomGlyphSizeConsistencyTests.testGlyphSizesStaySingleAcrossZoomCommits` (10 assertion failures, "renderer never produced a non-dropped frame"/glyph-size mismatches across zoom commits). Reproduced identically on commit `115a838` (M0, before any `FontAtlas` change), so it predates this plan and is not a regression from M1's `cellSize` change. Not investigated further here; flag for a separate fix.
  Evidence: same 10 failures, same messages, on both `115a838` and the M1 commit `096be82`.
- Observation: M4's spec text said to mark `lastPresentedFrameVersion = version` "only after `commandBuffer.commit()` succeeds." In practice `commandBuffer.commit()` in this present-thread usage is fire-and-forget with no synchronous success/failure signal to gate on, so the actual implementation marks the version presented (via `shouldEncodePresent(version:)`) right after `queue.makeCommandBuffer()` returns non-nil, i.e. before the `slug.present` signpost span and the blit/present/commit sequence, not strictly after `commit()`. `makeCommandBuffer()` returning `nil` is the one real synchronous failure point, and that path is still guarded (the version is not marked presented if it fails). Documented inline at the call site.
- Observation: constructing a real `CAMetalDrawable` bound to a live `CAMetalLayer` is impractical in a headless test, so M4's test coverage exercises the extracted pure function `shouldEncodePresent(version:)` directly instead of `presentLatestTarget(into:)` itself. This fully covers the skip/no-skip decision (the only present-thread behavior change) without a Metal-drawable dependency.
- Observation: `lastPresentedFrameVersion` uses a no-reset (monotonic-only) design rather than resetting to 0 in `resize()`. `publishedFrameVersion` only ever increments (`&+=1`) for the renderer's lifetime and is never rewound, so a post-resize republish always carries a strictly greater, never-before-seen version and can never be wrongly skipped, even though `resize` nils `latestPresentedTarget`. This avoids adding a reset call at every `latestPresentedTarget = nil` site and is simpler to reason about (one direction of travel for the version counter, full stop).
- Observation: for M5, no existing test asserts full-screen instance counts during partial frames. The only test referencing `lastFrameGlyphFontSizes` (`VectorZoomGlyphSizeConsistencyTests`) targets `VectorGlyphRenderer`, a different renderer; the only `SlugGlyphRendererTests` case touching zoom diagnostics (`testGestureZoomScalesRenderedPixelsWithoutRebuildingGeometry`) uses `.full` damage for both renders it compares. So M5's per-row filtering needed no test-expectation adjustments elsewhere, only its own new test.

## Plan of Work

Milestones are ordered by (risk ascending, win/effort descending). Each is independently shippable and verifiable. M0–M3 change no behavior, only CPU. M4 changes present-thread behavior behind existing invariants. M5 is a structural change to instance building.

### M0 — Negative-cache failed glyph resolutions

In `Sources/LabanRenderer/SlugGlyphRenderer.swift`:

1. Add a field next to `entriesByResolveKey` (~line 212): `private var failedResolveKeys: Set<SlugGlyphResolveKey> = []`.
2. In `ensureGlyph(for:referenceAtlas:referenceVariant:fontID:attributes:)`, immediately after the `entriesByResolveKey` hit check (~line 1633), add: `if failedResolveKeys.contains(resolveKey) { return nil }`.
3. At each of the two `nil` exits inside the cold path (the `guard let resolved = resolveGlyph... else` branch and the empty-outline/`outline` guards), insert `failedResolveKeys.insert(resolveKey)` before returning `nil`. Keep the `slug.glyphBuild` span as is — after this change it fires only for genuinely new clusters, which is the diagnostic intent.

Do NOT clear `failedResolveKeys` in `reconfigureFonts` — the resolve key embeds the interned font identity (`fontID` from PostScript name + bold + italic), so a font change produces new keys naturally, same lifetime rules as `entriesByResolveKey` (which is also never cleared). Rendering output is byte-identical: callers already treat `nil` as "use raster fallback" every frame; only the redundant re-resolution disappears.

### M1 — Store `FontAtlas.cellSize`

In `Sources/LabanRenderer/FontAtlas.swift`: convert `cellSize` (~line 163) from a computed property into a stored `public let cellSize: (width: CGFloat, height: CGFloat)` assigned in `init` using the same two CoreText calls (advance of 'M', ascent+descent+leading — keep the existing rounding). The font is immutable per `FontAtlas` instance (`withPointSize`/`reconfigureFonts` create new instances), so this is safe. All renderers benefit (`MetalRenderer` has 32 references, `VectorGlyphRenderer` 17). Check `FontAtlas` has no mutating font path first (`rg 'self\.font\s*=' Sources/LabanRenderer/FontAtlas.swift` should only hit `init`).

### M2 — Per-run font identity cache

In `Sources/LabanRenderer/SlugGlyphRenderer.swift`, `appendGlyphRun` (~line 1397) calls `FontAtlas.postScriptName(of:)` → `CTFontCopyPostScriptName` (~line 1426) on every run to feed `internedFontID`. Cache the resolved `(fontID, referenceVariant)` per (source == .sidebar, bold, italic) — 8 combinations — in a small fixed array or `[UInt8: ...]` dictionary keyed like `colorTraitCache` (~line 218). Invalidate the cache in `reconfigureFonts` and `refreshCJKFontCascade`. The interned ID semantics (ADR 0027 visual-font identity) are unchanged; only the string round-trip leaves the hot loop.

### M3 — Decoration early-out at call site

`appendGlyphRun` unconditionally calls `appendDecorations` (~line 1529), which computes `TerminalDisplayWidth.cells(of:)` and touches `cellSize` before `TextDecorationLayout.make`'s own guard returns nil for the common no-decoration case. Add at the top of `appendDecorations` (or before the call): `guard attributes.contains(.underline) || attributes.contains(.strikethrough) || attributes.contains(.overline) || underlineStyle != .none else { return }`. This mirrors `TextDecorationLayout.make`'s guard (`Sources/LabanRenderer/TextDecorationLayout.swift:22-27`) so behavior is identical.

### M4 — Skip redundant re-present blits

Measured win: ~89% of present-thread command buffers in the baseline workload.

In `Sources/LabanRenderer/SlugGlyphRenderer.swift`, `presentLatestTarget(into:)` (~line 2075) already reads `publishedFrameVersion` under `presentTargetLock`. Add a present-thread-only field `private var lastPresentedFrameVersion: UInt64 = 0` (accessed solely from the present-link callback thread, so no locking beyond the existing snapshot read). After the size guard and before creating the command buffer: if `version == lastPresentedFrameVersion`, return `false` (nothing encoded; the previously presented frame stays on glass — a presented drawable's content persists until replaced). On a successful commit path, set `lastPresentedFrameVersion = version`.

Correctness argument (spell this out in the PR): every new rendered frame increments the version inside `publishLatestTarget`, so no fresh content can be skipped; a skip only happens when the exact same published target was already blitted to a previous drawable. `VectorPresentDisplayLink`'s deferred-park budget (`PresentParkDecision`, `Sources/LabanRenderer/VectorPresentDisplayLink.swift:25`) treats a `false` return as "not presented," which only matters while the host has requested park with a pending publish — and a pending publish always carries a fresh version, which will not be skipped. Reset `lastPresentedFrameVersion = 0` where `latestPresentedTarget` is nilled (in `resize`) so a post-resize republish always presents.

Known hazards, and why they must be re-verified: commit `f371eaa` fixed alternate-screen TUI flicker caused by skip-path target publication, and ADR 0026 (`docs/adr/`) defines present-link invariants. The regression scenario is: run a fullscreen alternate-screen TUI (e.g. `htop` or Claude Code), drive scroll + clear-color changes, and confirm no flicker/stale frames; also cover `resize` mid-run. Add/extend a test in `Tests/LabanRendererTests/SlugGlyphDamageTests.swift` asserting that after `render` publishes version N and two present callbacks occur, only the first encodes (expose a test counter or reuse `presentIntervalStats` presented-count).

Do NOT extend this to `VectorGlyphRenderer` in the same changeset; it shares the display-link design but has its own publication rules. File it as follow-up after slug soaks.

### M5 — Damage-aware instance building

Structural milestone, do last. In `render(_:damage:)`, the effective damage (`.partial(yRanges:)`) is known before `buildInstances` runs, but `buildInstances` (~line 1357) walks all commands and `appendGlyphRun` emits instances for every cell. Change `buildInstances` to accept the effective damage and skip commands whose vertical extent does not intersect any damage band (glyph runs: `origin.y ..< origin.y + cellHeight` in the same y-up point space `slugScissorRect` converts from; solids: `rect.minY ..< rect.maxY`). Fragments outside bands are already scissor-culled, so GPU output is unchanged; this removes the CPU instance-building for undamaged rows (baseline: ~1,835 instances rebuilt per banded frame that the scissor then discards).

Caveats to handle: (a) the subpixel accumulate pass uses the same instance list — filtering is still safe because its draws use the same band scissors; (b) `lastFrame*Count` reserve hints and `lastFrameGlyphFontSizes`/`lastFrameQuadHeights` diagnostics will reflect only damaged rows on partial frames — check `Tests/LabanRendererTests/` for assertions on those before changing semantics; (c) cursor damage is already unioned into effective damage by `resolveEffectiveDamage`, so cursor cells always intersect. Validation must include a pixel-parity check: render a sequence full-then-partial and compare `pngData` output against the pre-change renderer for identical bytes.

## Concrete Steps

Work from the repository root (`/Users/user/wrk/laban`).

1. Build and test after each milestone:

       ./scripts/build-app
       swift test --filter SlugGlyphDamageTests    # expect: Executed 10 tests, with 0 failures (8 original + 1 M4 + 1 M5)

2. Install and hand off to the user for capture (never launch the app yourself; see `docs/process/agent-operating-guide.md`):

       ./scripts/install-app                        # prints the installed build stamp; verify it matches git rev-parse --short HEAD

3. Capture recipe (user-driven, GUI Instruments — the xctrace CLI cannot record signposts on this machine; its deferred-mode recording dies with "log archive corrupt" and silently empties ALL signpost tables):
   - Template: "Metal with signposts" (user template incl. os_signpost instrument; the Enable Subsystems list may stay empty — it only gates DynamicTracing categories).
   - File > Recording Options > Recording Mode: **Immediate** (critical).
   - Attach to LabanApp, record ~20 s of a Claude Code TUI session with spinner + light output, stop, **File > Save As to a fresh path**, close the document. If the saved bundle is small (<100 MB) and `xcrun xctrace export --input <trace> --toc` shows 0 tables, the save raced Instruments' store flush — re-save or re-record.

4. Analyze:

       # CPU hot paths
       python3 scripts/analyze-metal-trace <trace> --cpu-only --max-rows 60000
       # Signpost intervals (table index 7 = os-signpost-interval in current Instruments 26.6 TOCs; confirm via --toc)
       xcrun xctrace export --input <trace> --xpath '//trace-toc[1]/run[1]/data[1]/table[7]' --output intervals.xml

   In `intervals.xml`, rows carry `<string fmt="slug....">` names, `<duration>` in ns, and `<os-log-metadata>` whose nested `<uint64>` holds the `v=` version (the `fmt` attribute uses non-breaking thousands separators — parse the element text, not the fmt).

## Validation and Acceptance

Behavioral acceptance, per milestone, on a re-captured trace of the same workload shape:

- M0: `slug.glyphBuild` count over 20 s drops from ~80,000 to at most a few hundred (only genuinely novel clusters). `slug.render` p50 drops materially (baseline p50 38.5 ms was dominated by cold-path re-entry plus recording overhead). Rendering is pixel-identical (raster fallback counts in `slug.render` messages unchanged, still ~330/frame in the spinner workload).
- M1+M2: `FontAtlas.cellSize.getter` and `CTFontCopyPostScriptName` disappear from the Time Profiler top frames (baseline: 213 and ~154 sample rows respectively).
- M3: `appendDecorations` subtree vanishes for undecorated workloads.
- M4: ratio of `slug.present` spans to distinct `v=` values approaches 1 (baseline: 2158 spans / 243 versions = 8.9x). Present-thread `metal command encode` CPU (baseline 5.1% of kept weight) collapses proportionally. No flicker in the alternate-screen TUI scenario; `SlugGlyphDamageTests` (extended) pass.
- M5: `slug.render` end messages on `eff= bands:N` frames show instance counts proportional to damaged rows, not the full screen; full-frame counts unchanged; `pngData` parity holds for a full-then-partial sequence.

All milestones: `swift test --filter SlugGlyph` and the full `SlugGlyphDamageTests` suite pass; `scripts/build-app` succeeds; MVP regression contract (`docs/product/mvp.md`) untouched — these are perf changes with no user-visible behavior change intended.

## Idempotence and Recovery

Each milestone is a small, independent commit (single-line reason-style message). If a re-measure regresses or flickers, revert that milestone's commit alone; none depend on each other except M5 reading the effective damage that `resolveEffectiveDamage` already produces. Trace analysis is read-only and cacheable (`~/.cache/analyze-metal-trace`).

## Decision Log

- Decision: negative-cache via a separate `Set<SlugGlyphResolveKey>` rather than storing optionals in `entriesByResolveKey`.
  Rationale: `dict[key] = nil` on a `[K: V?]` removes the entry — a classic footgun; a Set is unambiguous and the extra lookup is one hash on a miss path only.
  Date/Author: 2026-07-10 / Claude + rrj.
- Decision: M4 keeps the version comparison on the present thread without new locking.
  Rationale: `lastPresentedFrameVersion` is only read/written inside the present-link callback; the published version is snapshotted under the existing `presentTargetLock`.
  Date/Author: 2026-07-10 / Claude + rrj.
- Decision: do not batch M4 with a matching VectorGlyphRenderer change.
  Rationale: separate behavioral reasons per changeset (repo standing rule); vector has its own publication invariants and its own execplan history (ADR 0026, `execplans/active/vector-drawable-pacing-120hz.md`).
  Date/Author: 2026-07-10 / Claude + rrj.

## Interfaces and Dependencies

No new dependencies. Touched files: `Sources/LabanRenderer/SlugGlyphRenderer.swift` (M0, M2–M5), `Sources/LabanRenderer/FontAtlas.swift` (M1), `Tests/LabanRendererTests/SlugGlyphDamageTests.swift` (M4/M5 coverage). The signpost surface (`RenderEncodeSignpost`, span names `slug.*`) is a diagnostic contract this plan relies on for measurement; do not rename spans mid-plan or before/after comparisons break.
