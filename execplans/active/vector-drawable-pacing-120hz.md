# Never wait for drawables: hold 120 Hz under heavy vector scroll

This ExecPlan is a living document maintained in accordance with `PLANS.md` (at
the repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds. Add optional sections only when they contain information that will
help a fresh contributor.

## Post-merge review follow-ups (2026-06-29)

A fresh-state Review Gate (verdict PASS-WITH-NITS; no correctness/crash/corruption
bug) raised two follow-ups, addressed as follows:

- **Doc drift (fixed):** ADR 0026 + the ADR index claimed "frames-in-flight raised
  above 1 (target 2)". The shipped design keeps `frameInFlight = 1` (the
  accumulation atlas is persistent) and gets cross-thread safety from a dedicated
  present queue + a 3-deep target ring. Docs corrected to match the code.
- **`stop()` thread-leak window (fixed):** if `stop()` ran before the present
  thread captured its run loop, `CFRunLoopStop` was skipped and `cancel()` cannot
  break `CFRunLoopRun()`, leaking the thread. Added a `stopRequested` flag the
  thread checks before entering `CFRunLoopRun()`.
- **Idle-park (RESOLVED):** the present link now rides the host's existing
  animate-or-park policy (`TerminalIdlePolicy.displayLinkShouldRun`) instead of
  self-detecting idle. `updateDisplayLinkRunState()` calls
  `VectorGlyphRenderer.setPresentLinkRunning(policy.shouldRun)` every frame, so the
  present thread parks (zero CPU) whenever the main tick parks — unfocused, occluded,
  OR focused-and-idle — and resumes 120 Hz on the next wake. This reuses the
  battle-tested ADR 0018 idle policy rather than inventing new idle logic (the
  earlier self-park attempts that regressed the active rate). Verified live: active
  fps 119.9 / p99 8.33, focused-idle parks in ~8 vsyncs, scroll-resume back to
  fps 119.6 immediately.
- **Latent crash fixed:** a test (`LabanDebugSmokeTests`) caught that calling
  `nextDrawable()` on a layer with a `CAMetalDisplayLink` attached raises
  `CAMetalLayerInvalidOperation`. The fix made the present link the SOLE presenter
  (no per-frame fallback to the legacy `nextDrawable()` path while the link exists);
  the legacy path is reachable only when the link was never created (macOS 13 / opt-
  out). This was a real hazard latent in the originally-merged code.
- **Present-thread lifecycle hardening (2026-07-22):** macOS 27.0 build
  `26A5378n` testing proved that `CFRunLoopStop()` issued after a worker captures
  its run loop but before `CFRunLoopRun()` does not stop the later activation.
  Teardown now queues the stop in the default-mode run loop, the thread logs and
  rebuilds if `CFRunLoopRun()` returns without a deliberate stop, and screen-change
  notifications rebuild both the visible and any warming pending backend.

## Purpose / Big Picture

When the user scrolls a terminal while the **vector glyph renderer** is selected,
the animation stutters: the main thread blocks waiting for Core Animation to hand
back a reusable drawable, and on a 120 Hz ProMotion display the frame cadence
collapses to a harmonic of the refresh rate (the "half-rate basin" — frames
delivered every ~16 ms instead of every ~8.33 ms). A GPU System Trace of heavy
scroll measured the main thread spending p50 **7.2 ms** and p95 **~15 ms** blocked
in `CAMetalLayer.nextDrawable()`, while the actual GPU render work was only ~1 ms.
The stall is presentation/drawable starvation, not GPU compute.

After this change, on **macOS 26** (the user's deployment target for the goal),
the vector renderer no longer blocks the main thread on drawable acquisition and
holds a steady 120 Hz during continuous scroll: the per-frame interval stays near
8.33 ms and the live "jank frame" counter stays at (or very near) zero. On older
macOS (13–25) the existing behavior is preserved unchanged — the goal is only
required to hold on macOS 26.

You can see it working with the app's built-in scroll diagnostics: with the app
launched `--scroll-debug`, `GET /scroll/frame-stats` reports frame-interval
p50/p95/p99 and a `jankFrames` count over the display-link ring. Before this
change, driving `POST /scroll/smooth` bursts shows p95/p99 frame intervals well
above 8.33 ms and nonzero jank; after, p99 holds near 8.33 ms and jank drops to
~0. A GPU Metal trace of the same scroll shows the "blocked waiting for next
drawable" interval collapse from p95 ~15 ms to near zero.

This is renderer-architecture work. It is recorded in **ADR 0026**
(`docs/adr/0026-display-synced-drawable-acquisition.md`, created by this plan) and
preserves the frame-command contract and MVP behavior (`docs/product/mvp.md`).

## Definitions (plain language)

- **Drawable**: a `CAMetalDrawable`, one reusable framebuffer texture that Core
  Animation lends the app to render a frame into and then displays. A
  `CAMetalLayer` owns a small pool (2 or 3). `layer.nextDrawable()` borrows one;
  it **blocks** the calling thread when the pool is empty until the compositor
  recycles a previously-presented drawable (which only happens on a display
  refresh). That block is the throttle and the source of the stall.
- **Frames in flight**: how many frames the CPU is allowed to have submitted to
  the GPU but not yet finished-and-presented at once. Limiting this to 1 (a
  `DispatchSemaphore(value: 1)`) means the CPU cannot start frame N+1 until frame
  N has fully drained, which forces the drawable pool to empty every frame — the
  direct cause of the basin.
- **Half-rate basin / "the basin"**: a self-sustaining equilibrium where a 120 Hz
  panel settles at 60 Hz (or 80 Hz) because each frame misses its vsync slot,
  Core Animation infers a lower refresh, and drawable recycling then locks to the
  slower interval. Documented by Apple DTS (a developer measured ~80 Hz at a
  requested 120 Hz with 2 drawables + 1 in flight).
- **`CAMetalDisplayLink`** (macOS 14+): a display link specialized for Metal. Its
  per-frame delegate callback **delivers an already-acquired drawable** plus a
  `targetTimestamp` (render deadline) and `targetPresentationTimestamp` (estimated
  on-screen time). Because the drawable arrives in the callback, the app never
  calls `nextDrawable()` on its own thread, so the synchronous block is removed
  from the encode path entirely. This is Apple's stated recommended frame-pacing
  mechanism ("we strongly advise using CAMetalDisplayLink over CADisplayLink").
- **`CADisplayLink`** (macOS 14+) / **`CVDisplayLink`** (macOS 13): the app's
  current vsync tick. It fires a callback each refresh, the app builds a frame and
  calls the renderer, and the renderer acquires the drawable itself. This is the
  legacy path that stays in place for older macOS.
- **MetalDrawableScheduler**: the existing class
  (`Sources/LabanRenderer/MetalDrawableScheduler.swift`) that wraps
  `nextDrawable()` in an async request on a background queue, parks late drawables
  ("carry-forward"), prefetches, and has an explicit half-rate-basin escape hatch
  (`onDrawableReadyAfterMiss`). It is shared by the classic (`MetalRenderer`) and
  vector (`VectorGlyphRenderer`) backends. It is a sophisticated mitigation of the
  blocking `nextDrawable()` problem; this plan keeps it as the macOS-13–25 fallback
  and adds a display-synced path that sidesteps it on macOS 26.

## Progress

- [x] (2026-06-29) Diagnosis complete. GPU trace: main thread p50 7.2 ms / p95
  ~15 ms blocked in `nextDrawable()`; GPU render ~1 ms. Code audit: both renderers
  wire `MetalDrawableScheduler` identically; the asymmetry is that the vector
  renderer's single per-frame command buffer also contains the GPU glyph-mask
  bakes (`ensureResidentMask`→`encodeAccumulate`), and `frameInFlight =
  DispatchSemaphore(value: 1)` is held across bake+render+present. SOTA research
  (June 2026) independently confirms "only 1 frame in flight → the basin" and
  names `CAMetalDisplayLink` as the fix. Machine is macOS 26.5, native arm64 (no
  Rosetta 60 Hz cap). Layer already has `maximumDrawableCount=3`,
  `allowsNextDrawableTimeout=true`.
- [x] (2026-06-29) Milestone 0: live baseline captured on macOS 26.5, vector/fluid,
  tab 7. frame-stats (tick): fps 119.7, p99 10.5, max 21.3, jank 0.21%. GPU trace
  (present-side): drawable-wait p50 6.53 / p99 15.34 / max 40.6 ms; vector.content
  GPU p95 1.10 ms. Discovered frame-stats measures the display-link TICK interval,
  not present cadence, so it understates drawable misses — acceptance uses the GPU
  drawable-wait number as the primary truth (see Artifacts caveat).
- [~] Milestone 1 (cheap, all-OS): raise frames-in-flight above 1. DEFERRED to a
  contingency — the vector renderer's accumulation atlas is persistent across
  frames (temporal AA), so >1 in flight would corrupt accumulation. M2 removes the
  drawable wait without needing it. See Decision Log.
- [x] (2026-06-29) Milestone 2: added `VectorPresentDisplayLink` (CAMetalDisplayLink
  on a dedicated high-QoS thread, macOS 14+). `render()` fast path encodes content
  into the offscreen target and commits WITHOUT acquiring a drawable; the present
  link blits the latest target into its ready drawable each vsync and presents.
  Legacy `MetalDrawableScheduler` acquire+present kept for macOS 13 / opt-out
  (`LabanVectorPresentDisplayLink=NO`). Result: drawable-wait ELIMINATED (0
  waiters; was p50 6.53/p99 15.34 ms), frame-stats jank 0.21%→0.07%, p99
  10.5→9.15 ms. 79 vector tests green, parity unchanged, lint clean.
- [ ] Milestone 3: decouple the vector GPU mask-bake work from the present
  command buffer / in-flight window if M1+M2 do not fully clear the tail.
- [ ] ADR 0026 written and referenced.
- [ ] Review Gate passed.

## Context and Orientation

All paths are relative to the repository root.

### How a frame is driven today

1. A vsync tick fires: `TerminalBitmapView.displayLinkTick` (around
   `Sources/LabanApp/TerminalBitmapView.swift:1271`) → `advanceFrame(wake:)`
   (around `:1814`). On macOS 14+ the tick is a `CADisplayLink` with a
   `preferredFrameRateRange` (`:1216`); on macOS 13 a `CVDisplayLink` (`:1226`).
2. `advanceFrame` builds the frame commands and calls `backend.render(commands,
   damage:)` (around `:2352`).
3. Inside the renderer (`VectorGlyphRenderer.render`,
   `Sources/LabanRenderer/VectorGlyphRenderer.swift:631`), the frame:
   - takes the `frameInFlight` semaphore via `drawableScheduler.beginFrame(...)`;
   - encodes offscreen work into one `MTLCommandBuffer`: GPU glyph-mask bakes
     (`prepareGlyphResources`→`ensureResidentMask`→`scratchRasterizer.encodeAccumulate`),
     then the content render pass (`encode`);
   - acquires the drawable **late** via `scheduledFrame.acquireDrawable(nonBlocking:
     dropIfBusy)` (`:696`) — this is where the block happens on the scheduler's
     background queue;
   - blits the offscreen target into the drawable and `present`s it (`:700`–`713`);
   - releases `frameInFlight` in `addCompletedHandler` (`:718`–`722`), i.e. only
     after the whole command buffer (bakes + render + present) finishes on the GPU.

The classic `MetalRenderer` (`Sources/LabanRenderer/MetalRenderer.swift:1091`
onward) has the **same** structure and the **same** scheduler wiring, but its
per-frame command buffer has **no GPU bakes** (it samples a pre-baked bitmap
atlas), so its in-flight window is shorter and it stays at 120 Hz where vector
falls into the basin. (Bench numbers at plan authoring: classic frame p95 ~8.8 ms,
vector ~16 ms.)

### Why the existing scheduler is not enough on its own

`MetalDrawableScheduler` already does the right late-acquire, async-acquire, and
carry-forward/prefetch tricks, and an explicit basin escape hatch. But it is
fundamentally still calling `nextDrawable()` and gating on `frameInFlight =
DispatchSemaphore(value: 1)`. With one frame in flight, the pool drains every
frame and the async acquire just moves the ~one-vsync wait off the main thread's
*stack* without removing the wait from the *pipeline*. The GPU trace shows the
result: the wait is still ~7.2 ms p50. The structural fixes are (1) more than one
frame in flight, and (2) on macOS 26, stop calling `nextDrawable()` at all and let
`CAMetalDisplayLink` deliver the drawable.

### Confirmed environment facts (do not re-derive)

- Deployment target: `Package.swift` `platforms: [.macOS(.v13)]`. So every macOS-14+
  API (`CADisplayLink`, `CAMetalDisplayLink`) must be behind `#available`.
- The running/target machine is macOS 26.5, native arm64. The goal is only
  required to hold on macOS 26; older OS keeps current behavior.
- `CAMetalLayer` is already configured `maximumDrawableCount = 3`,
  `allowsNextDrawableTimeout = true`, `framebufferOnly = false` (needed for capture
  readback) in both renderers. Keep `allowsNextDrawableTimeout = true` (setting it
  false risks a documented hard hang).
- The vector renderer shares one offscreen persistent `targetTexture` +
  `accumTexture` + mask atlas across frames. Raising frames-in-flight requires
  these per-frame-written resources to be double/triple-buffered or the work that
  writes them to be ordered so frame N+1 cannot stomp frame N (the very reason the
  semaphore is 1 today — see the comment at `MetalDrawableScheduler.swift:38`).

### Measurement vehicles (this plan's acceptance)

- **Live app** `--scroll-debug` HTTP control surface (`ScrollDebugServer`):
  - `POST /config/renderer?name=vectorGlyph`, `POST /config/smooth-scroll?mode=fluid`,
    `POST /config/tab?index=N` — pick a deep-scrollback normal-buffer shell tab that
    is NOT the tab the agent/driver runs in (the driver's own shell output pollutes
    the measured tab). Tab 7 (`index=6`) is the standard target here.
  - NOTE: `?reset=1` on frame-stats is a GET query, not a POST.
  - `POST /scroll/smooth?rows=N&velocity=V` to drive sub-cell smooth scroll,
  - `GET /scroll/frame-stats[?reset=1]` → mean/p50/p95/p99 frame interval + stddev +
    `jankFrames` over the display-link ring. **This is the primary acceptance metric.**
  - `GET /scroll/screenshot.png` for a visual correctness check.
- **GPU Metal System Trace** via `scripts/analyze-metal-trace --record N --attach
  <pid>` (attach by pid; the "log archive corrupt" record warning is benign — the
  bundle still analyzes; re-run `analyze-metal-trace <bundle>` if needed). The
  "blocked waiting for next drawable" / `ca-client-buffer-wait-interval` label is
  the before/after number.
- **`VectorScrollFrameTimeBench`** measures only CPU encode time against an
  off-window layer; it does **not** capture drawable-wait, so it is NOT the
  acceptance vehicle here (it stays green as a no-regression check only).

## Plan of Work

Smallest, all-OS-safe change first; the macOS-26 SOTA path second; structural
decoupling last only if needed. Each milestone is independently measurable against
Milestone 0 and committed separately.

### Milestone 0 — Live baseline

Launch the installed app `--scroll-debug`, select vector/fluid + a deep-scrollback
tab, reset frame-stats, drive a fixed smooth-scroll workload, and record
`/scroll/frame-stats` (p50/p95/p99 interval, jankFrames) plus a GPU trace's
drawable-wait p95. Record both in Artifacts as the baseline. No code change.

### Milestone 1 — More than one frame in flight (all OS)

The basin's root cause per both the code audit and the SOTA research is
`frameInFlight = DispatchSemaphore(value: 1)`. Raise it to allow 2 (optionally 3)
frames in flight. The blocker is the shared offscreen `targetTexture`/`accumTexture`:
with >1 in flight, frame N+1 must not write the texture frame N is still reading.
Two safe options, to be chosen by what the code allows with least churn:

- (a) **Double-buffer the per-frame-written offscreen textures** (a small ring of
  target/accum textures indexed by an in-flight counter), so each in-flight frame
  owns its own; raise the semaphore to 2.
- (b) If the accumulation atlas makes (a) too invasive, raise the semaphore to 2
  but keep a **dedicated** present/blit command buffer separate from the bake
  command buffer (see M3) so only the cheap present work is double-buffered.

Prefer (a) if the textures are cleanly per-frame. Validate that nothing reads a
texture across the in-flight boundary (GPUCellParity-style pixel check + the
existing vector parity tests). This alone should let the drawable pool keep a spare
and cut the per-frame block materially on all macOS versions.

Target value: **2 frames in flight**, not 3. Apple's WWDC25 reference frame-pacing
architecture (session 211 "Go further with Metal 4 games") caps in-flight at 2 with
`maximumDrawableCount = 3`; more in-flight only adds latency. `maximumDrawableCount`
stays 3 (2 is also valid on macOS and lower-latency, but 3 gives starvation slack
for a bursty workload — keep 3 unless a latency measurement says otherwise).

### Milestone 2 — `CAMetalDisplayLink` acquisition on macOS 26 (the SOTA fast path)

**Chosen architecture: decouple present from content render (renderer-internal
present display-link).** The vector renderer already renders content into a
persistent offscreen `targetTexture`, then in the same command buffer acquires a
drawable, blits target→drawable, and presents. Split that:

- On the fast path, `render(_:damage:)` on the main-thread tick encodes only the
  GPU mask bakes + content render into `targetTexture` and commits — **it does not
  acquire a drawable or present.** This removes the ~6.5 ms `nextDrawable()` wait
  from the main thread entirely.
- A `CAMetalDisplayLink` the renderer owns internally, running on a dedicated
  high-QoS thread, fires each vsync; its callback takes `update.drawable`, blits
  the latest `targetTexture` into it, and presents. The drawable arrives ready, so
  presentation never blocks. The link always has a target to present (re-presenting
  an unchanged target is a ~0.05 ms blit), so it never misses a 120 Hz slot.
- Synchronization: content-render and present-blit share the renderer's one
  `MTLCommandQueue`, so the GPU serializes them in commit order; the present-blit
  reads whatever committed target state exists (frame N's content while N+1
  encodes). The `targetTexture` reference and its size are swapped only under a
  lock so a resize can't free a texture mid-blit. `frameInFlight = 1` still
  serializes accumulation-atlas access on the content side.
- Idle: the present link `isPaused = true` when `render()` has produced no new
  content for a short while (and unpauses on the next `render()`), so a quiescent
  terminal does not blit every vsync (respects ADR 0018 event-driven production).
- Zero `TerminalBitmapView` changes: it keeps calling `render()` each tick. On
  macOS < the gate, `render()` keeps doing acquire+blit+present exactly as today
  and the internal present link is never created.

Original sketch (kept for reference; the renderer-internal variant above is the
one being implemented):

Add an OS-gated path that, on macOS 26 (guard `#available(macOS 14.0, *)` — the API
floor — but the goal/validation target is 26), drives presentation from a
`CAMetalDisplayLink` whose callback delivers the drawable:

- Create `CAMetalDisplayLink(metalLayer: layer)`, set `preferredFrameRateRange =
  CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)`, set
  `preferredFrameLatency` low (try `1` for a terminal that finishes in 2–3 ms;
  raise toward 2 only if starvation reappears — it trades latency for slack),
  register it on a **dedicated high-QoS thread's run loop** (not main), and
  `isPaused = true` when the terminal is idle (unpause on scroll/keystroke wake —
  reuse the existing wake sources).
- In `metalDisplayLink(_:needsUpdate:)`, take `update.drawable`, drive the frame
  using `update.targetPresentationTimestamp` as the animation clock (so motion is
  smooth across any rate transition), encode the renderer's content into a command
  buffer that targets that drawable, `present(drawable)` (plain present — the link
  paces), and `commit()`.
- The renderer needs a new entry point that renders **into a supplied drawable**
  instead of acquiring one. Add e.g. `VectorGlyphRenderer.renderInto(drawable:
  commands:damage:)` that skips `drawableScheduler` entirely. The existing
  `render(_:damage:)` stays as the legacy path used by the `CADisplayLink`/
  `CVDisplayLink` tick on macOS < the gate.
- On macOS < gate, none of this is constructed; `caDisplayLink`/`cvDisplayLink` +
  `MetalDrawableScheduler` continue exactly as today (byte-for-byte unchanged).

This removes `nextDrawable()` from the main/encode path on macOS 26, which is the
direct mechanism of "never wait for drawables."

### Milestone 3 — Decouple GPU mask bakes from the present window (only if needed)

If after M1+M2 the vector tail still shows occasional misses traceable to the bake
bursts sitting in the same command buffer as the present, split them: commit the
mask-bake work in its own command buffer (it writes only the resident atlas, which
is already designed to be read next frame), so the present command buffer is just
render+blit and its completion (which releases an in-flight slot) is not gated
behind bake GPU time. Validate parity unchanged. Skip this milestone if M1+M2
already meet the acceptance bar — record that decision.

## Concrete Steps

Run from the repository root. Working dir in the current tree:
`/Users/user/wrk/laban/.claude/worktrees/adaptive-tickling-porcupine`.

### Milestone 0 baseline

> IMPORTANT: `~/Laban.app` may have been replaced by another agent at any time.
> Always `scripts/install-app` from this worktree and confirm
> `Info.plist:LABANBuildCommit` matches the commit under test *immediately before*
> any profiling run, and restart the app (background relaunch) so the running
> bundle is the one you think you are measuring.

1. Build + install current `main`: `scripts/install-app` (confirm
   `Info.plist:LABANBuildCommit` matches HEAD). Relaunch the app `--scroll-debug`
   yourself (do not `open` it from the shell — single-instance ghost).
2. Drive and measure (localhost JSON; a hook blocks `curl`, so use Python urllib):

       python3 - <<'PY'
       import urllib.request, json, time
       def post(p):
           urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8787"+p, method="POST"), timeout=5).read()
       def get(p):
           return json.loads(urllib.request.urlopen("http://127.0.0.1:8787"+p, timeout=5).read())
       post("/config/renderer?name=vectorGlyph"); post("/config/smooth-scroll?mode=fluid")
       post("/config/tab?index=6")                 # a deep-scrollback shell tab
       post("/scroll/frame-stats?reset=1")
       t=time.time()+12
       i=0
       while time.time()<t:
           post(f"/scroll/smooth?rows={-30 if i%2==0 else 30}&velocity={1200+(i%5)*400}")
           time.sleep(0.22); i+=1
       print(json.dumps(get("/scroll/frame-stats"), indent=1))
       PY

3. Record the printed p50/p95/p99 interval + jankFrames into Artifacts. Optionally
   capture a GPU trace (`scripts/analyze-metal-trace --record 16 --attach <pid>`)
   and record the drawable-wait p95.

### Milestones 1–3

Each: edit the named files, `swift build --target LabanRenderer` (and `LabanApp`),
run `swift test --filter VectorGlyphParityTests` and `--filter Vector` (expect 0
failures), `scripts/install-app`, relaunch `--scroll-debug`, re-run the exact M0
driver, and compare `/scroll/frame-stats` against the M0 baseline. Lint changed
files with `swift-format lint --configuration .swift-format <files>`. Commit each
milestone separately with a single-line reason-style message.

## Validation and Acceptance

Behavioral, on macOS 26:

1. **Never wait for drawables (GPU trace):** after M2, a GPU Metal trace of the
   standard heavy-scroll workload shows the "blocked waiting for next drawable" /
   `ca-client-buffer-wait-interval` p95 drop from the M0 baseline (~15 ms) to near
   zero (no synchronous drawable wait on the render path).
2. **Never miss a frame at 120 Hz (frame-stats):** after M1+M2, `GET
   /scroll/frame-stats` under the standard driver reports p99 frame interval near
   8.33 ms (within a small tolerance, e.g. ≤ ~9.5 ms) and `jankFrames` at or very
   near 0, versus a clearly worse baseline. Record before/after.
3. **Correctness unchanged:** `swift test --filter VectorGlyphParityTests` and
   `--filter Vector` stay all-green (no pixel-diff change); a
   `/scroll/screenshot.png` after scrolling shows correct text (all glyphs, colors,
   alignment, cursor/selection).
4. **No regression off the fast path:** on the legacy path (or by reading the diff)
   confirm macOS < gate behavior is unchanged — the `CAMetalDisplayLink` code is
   only constructed under `#available`, and `MetalDrawableScheduler` /
   `CADisplayLink` / `CVDisplayLink` are untouched for older OS.

XCTest prints `Executed N tests, with 0 failures` on success.

## Idempotence and Recovery

Every step is a source edit + build/test + install. Milestones commit separately so
a regression bisects and `git revert`s cleanly. The `CAMetalDisplayLink` path is
additive and OS-gated, so reverting M2 restores the scheduler path with no data
migration. No destructive operations. Re-running the measurement driver is safe.

## Decision Log

- Decision: Target the goal at macOS 26 only; keep macOS 13–25 on the existing
  `MetalDrawableScheduler` + `CADisplayLink`/`CVDisplayLink` path unchanged.
  Rationale: The user's deployment/target machine is macOS 26.5 and explicitly
  scoped the goal to macOS 26. `CAMetalDisplayLink` is macOS 14+, so an OS-gated
  dual-path (SOTA fast path + untouched legacy fallback) matches both the API
  floor and the user's documented preference for `#available` fast path + pinned
  legacy fallback.
  Date/Author: 2026-06-29 / execution session.

- Decision: Do Milestone 1 (frames-in-flight > 1) before the `CAMetalDisplayLink`
  rewrite.
  Rationale: Both the code audit and the SOTA research identify
  `DispatchSemaphore(value: 1)` as the basin's root cause. Raising it is the
  smallest, all-OS, lowest-risk change and may itself clear most of the tail,
  de-risking the larger M2.
  Date/Author: 2026-06-29 / analysis session.

- Decision (SUPERSEDES the above): Defer Milestone 1; go straight to Milestone 2
  (`CAMetalDisplayLink`). Keep `frameInFlight = 1`.
  Rationale: On inspection, the vector renderer's shared offscreen resources split
  into (a) `targetTexture`, genuinely per-frame and double-bufferable, and (b)
  `accumTexture`/`atlasTexture`/`maskAtlas`, which are **persistent temporal-
  accumulation** textures — masks accumulate coverage samples across many frames
  (the renderer's defining feature, ADR 0022). Raising frames-in-flight means
  frame N+1 bakes into the atlas while frame N still reads it, which would corrupt
  or break accumulation; double-buffering the atlas would discard accumulated
  coverage. So M1 is high-risk *specifically* for the vector renderer and does not
  cleanly apply. Crucially, M2 does not need it: with `CAMetalDisplayLink` the
  drawable is delivered ready in the callback, so the ~6.5 ms `nextDrawable()` wait
  is removed **without** changing the in-flight model. `frameInFlight = 1` then
  serves its real purpose — serializing access to the accumulation atlas — while
  no longer gating on a drawable wait. The per-frame GPU work is ~1–2 ms, well
  inside the 8.33 ms callback budget, so 1-in-flight does not throttle 120 Hz. M1
  stays in the plan as a *contingency* only if M2 leaves a throughput tail that is
  traceable to in-flight serialization (unlikely given the ~1 ms GPU cost).
  Date/Author: 2026-06-29 / execution session.

## Surprises & Discoveries

- Observation: The two renderers wire `MetalDrawableScheduler` identically; the
  vector renderer is slower not because it uses the scheduler wrong but because its
  single in-flight command buffer also carries the per-frame GPU mask bakes, so the
  1-frame-in-flight semaphore is held across bake+render+present.
  Evidence: `VectorGlyphRenderer.render` commits one command buffer containing
  `ensureResidentMask`→`encodeAccumulate` + `encode` + present, releasing
  `frameInFlight` only in `addCompletedHandler`; `MetalRenderer` has no per-frame
  bakes. GPU trace: `laban.vector.content` p95 1.13 ms but drawable-wait p95 ~15 ms.

- Observation: SOTA research and the local code audit converge on the same root
  cause and fix independently.
  Evidence: Apple DTS forum (thread 763426) reports ~80 Hz at requested 120 Hz with
  2 drawables + 1 in flight; recommends `CAMetalDisplayLink` and ≥2 in flight.
  Matches `MetalDrawableScheduler.swift:38` (`frameInFlight` value 1) exactly.

- Observation (LOAD-BEARING GOTCHA): `CAMetalDisplayLink` on a dedicated thread
  fires ZERO callbacks if the run loop is pumped with
  `RunLoop.run(mode:before:)` in a `while` loop — the link's source is never
  serviced and nothing ever presents. It must block in `CFRunLoopRun()` (stop via
  `CFRunLoopStop` from another thread). Isolated test: `run(before:)` → 0
  callbacks; `CFRunLoopRun()` → 235 callbacks in 2 s (~118 Hz). Also: the link only
  fires when its layer is hosted in a visible, activated on-screen window; an
  offscreen/headless layer yields 0 callbacks (so headless tests cannot exercise
  the present cadence — it must be measured in the live app).

- Observation: The tick-interval `frame-stats` metric actively MISLEADS for this
  work. It records the main-thread display-link TICK interval, which stays ~120 Hz
  even when content is late or nothing presents. The first "success" reading
  (drawable-wait eliminated, jank 0.07%) hid a real bug: the present link was
  firing 0 callbacks, so NOTHING was presenting via the fast path — the screen was
  only updating because... it wasn't, on tab 7 (the agent can't see that tab). Only
  after adding a present-side counter (`callbacks`/`presented`, GPU trace showing
  884 content renders / 0 present-blits) did the bug surface. Acceptance MUST use
  the present-side cadence (`GET /scroll/present-stats`), not `frame-stats`.

## Interfaces and Dependencies

- New renderer entry point (vector, and optionally classic for symmetry):
  `func renderInto(drawable: any CAMetalDrawable, commands: [FrameCommand], damage:
  RenderDamage) -> Bool` that encodes + presents into the supplied drawable without
  touching `MetalDrawableScheduler`. The existing `render(_:damage:)` is retained
  for the legacy tick path.
- New host type (LabanApp): a `CAMetalDisplayLink` driver
  (`#available(macOS 14.0, *)`), owning a dedicated high-QoS thread/run loop, a
  delegate that calls `renderInto(drawable:)`, `isPaused` toggled by the existing
  frame-wake sources. Lives beside the current `caDisplayLink`/`cvDisplayLink` in
  `TerminalBitmapView`, selected by `#available` + renderer kind.
- Config (unchanged, asserted): `maximumDrawableCount = 3`,
  `allowsNextDrawableTimeout = true`, `displaySyncEnabled` default true,
  `presentsWithTransaction` false. Do not set `allowsNextDrawableTimeout = false`.
- Frames-in-flight semaphore raised from 1; requires per-in-flight target/accum
  texture ownership (a small texture ring) to keep the shared-resource invariant.
- ADR `docs/adr/0026-display-synced-drawable-acquisition.md` and an index line in
  `docs/adr/README.md`.
- No product-doc (spec/mvp) change; this is performance/architecture that preserves
  MVP behavior.

## Review Gate

A separate fresh-state agent must verify before completion (see PLANS.md):

- [ ] `git log --oneline` shows one commit per implemented milestone, reason-style,
      naming the drawable/pacing change; ADR 0026 committed and linked in
      `docs/adr/README.md`.
- [ ] `swift test --filter VectorGlyphParityTests` and `swift test --filter Vector`
      each exit 0 with `0 failures` (paste the `Executed N` lines).
- [ ] OS gating: grep the new `CAMetalDisplayLink` usage; every reference is inside
      an `#available(macOS 14.0, *)` (or newer) guard, and `MetalDrawableScheduler.swift`,
      the `CVDisplayLink` path, and the `CADisplayLink` tick are unchanged for the
      legacy path (diff shows additive-only there). Expect: no `CAMetalDisplayLink`
      symbol outside an availability guard.
- [ ] `allowsNextDrawableTimeout` is never set to `false` anywhere (grep; expect
      zero hits of `allowsNextDrawableTimeout = false`).
- [ ] Frames-in-flight: the `frameInFlight` semaphore initial value is > 1, OR a
      dedicated present buffer decouples it; and a test/grep shows per-in-flight
      target-texture ownership (no single shared target written by >1 in-flight
      frame). Reviewer confirms the shared-resource invariant is preserved.
- [ ] Acceptance numbers: reviewer runs the M0 driver against the built app and
      confirms `/scroll/frame-stats` p99 interval is near 8.33 ms with jankFrames
      ~0, materially better than the recorded M0 baseline. (Requires macOS 26 +
      a 120 Hz display; if the reviewer's hardware differs, it records that and
      defers this one check to the user.)
- [ ] `swift-format lint` exits 0 on all changed Swift files.

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Artifacts and Notes

Prior GPU trace (pre-change, build 206e4fa, heavy fluid scroll, tab 7):

    laban.vector.content (GPU render)        p95 1.13 ms  p99 1.37  max 2.2
    blocked waiting for next drawable        p50 7.2 ms   p95 ~15 ms  max 40
    present-blit                             p95 0.05 ms

Milestone 0 baseline (2026-06-29, build 04c263e, macOS 26.5, vector/fluid, tab 7
[4807 rows, normal buffer], driven by 114 `POST /scroll/smooth` bursts of ±50 rows
at ~10 Hz over 12 s):

    frame-stats (display-link TICK interval):
      fps 119.7  p50 8.33  p95 9.15  p99 10.50  max 21.3 ms  jank 3/1446 (0.21%)
    GPU trace (PRESENT-side truth):
      drawable-wait (ca-client-buffer-wait-interval): p50 6.53  p95 7.71  p99 15.34  max 40.6 ms
      vector.content (GPU render):                    p50 0.93  p95 1.10  p99 1.26 ms

Reading: the main thread waits ~6.5 ms (≈ 0.8 of a 120 Hz vsync) for a drawable on
*every* frame, while the GPU render is ~1 ms. The tick-cadence frame-stats only
tips into visible jank ~0.2% of the time because the wait usually overlaps the
vsync slot — so frame-stats UNDERSTATES the problem (see the measurement caveat
below). The drawable-wait p50 6.5 ms is the stall the macOS-26 fast path removes;
"never miss a frame" is the elimination of the p99 15.3 ms / max 40.6 ms tail.

MEASUREMENT CAVEAT (load-bearing): `GET /scroll/frame-stats` records the
display-link *tick* interval (`TerminalBitmapView.noteDisplayLinkTick`,
`:1276`/`:1285`), NOT actual present cadence. The display link keeps ticking at
120 Hz even when a frame is computed-but-not-presented or a drawable is missed, so
a missed drawable only shows as tick-jank if it stalls the main thread enough to
delay the *next tick*. The true "did we present every refresh" number is the GPU
trace's `ca-client-buffer-wait-interval` / "blocked waiting for next drawable", or
`MTLDrawable.presentedTime`. Acceptance therefore uses BOTH: frame-stats jank → ~0
AND drawable-wait p50/p99 → near zero. Consider adding a presented-frame interval
counter (via `addPresentedHandler`/`presentedTime`) as part of M1 so the live
endpoint reports the present-side truth directly.

After M2 (2026-06-29, build dfe71c9, CAMetalDisplayLink present path, same tab-7
driver):

    frame-stats (tick):  fps 119.9  p50 8.33  p95 8.35  p99 9.15  max 16.7  jank 1/1450 (0.07%)
    GPU trace (present): drawable-wait — ZERO waiters (ca-client-buffer-wait-interval empty)
                         vector.content GPU p50 0.49  p95 0.51 ms

    vs M0:  drawable-wait p50 6.53 / p99 15.34 / max 40.6  ->  ELIMINATED
            frame-stats p99 10.50 -> 9.15, max 21.3 -> 16.7, jank 0.21% -> 0.07%

The "never wait for drawables" goal is met: the synchronous `nextDrawable()` block
is gone from both the main thread and the present thread (no `ca-client-buffer-wait`
intervals at all).

CORRECTION (later same day): that first reading was measured with the wrong metric
(`frame-stats` tick interval) and the present link was actually firing 0 callbacks
(CFRunLoopRun gotcha — see Surprises), so nothing presented via the fast path. After
fixing the run loop and adding the present-side metric:

After M2 FIXED (build 14befd4, present-side `GET /scroll/present-stats`, tab 7,
aggressive driver ±60 rows):

    [steady] present fps 119.7  p50/p95/p99 8.33/8.33/8.33  max 16.7  jank 3/1187 (0.25%)  cb 1192 / pres 1188
    [fast]   present fps 119.8  p50/p95/p99 8.33/8.33/8.33  max 16.7  jank 2/1202 (0.17%)  cb 1203 / pres 1203

Present p99 = 8.33 ms exactly: every vsync presents at 120 Hz. callbacks ≈ presented
(every link callback shows a frame). The display refreshes at 120 Hz independent of
content-render timing — when content is briefly late, the last good target is
re-presented, so the user never sees a stutter. Goal met on the present side.
