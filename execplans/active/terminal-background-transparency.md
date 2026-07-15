# Enable terminal background transparency across every renderer

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress`, `Decision Log`, and `Validation and Acceptance` current as implementation proceeds. A fresh contributor must be able to resume from this file and the repository alone.

## Purpose / Big Picture

Laban should let a user make the terminal canvas translucent without making text, the cursor, selection, input-method preedit, or application-selected cell backgrounds hard to read. The first visible implementation may use the Slug glyph renderer, but the feature is complete only when software, classic Metal, GPU-driven Metal, vector glyph, and Slug glyph rendering all obey one renderer-neutral contract and produce equivalent alpha output.

After this work, the Appearance settings offer a background-opacity slider, an opt-in control for applying opacity to explicitly colored terminal cells, mutually exclusive `None`, `System Blur`, and `Image` background sources, exact Fill/Fit/Stretch image scaling, and a localized, theme-neutral `Frosted` preset. A user can see a stable blurred or personally selected image backdrop through the terminal content while the entire sidebar remains a cohesive opaque navigation surface, can switch renderers without an opaque flash or semantic change, and can rely on Laban becoming fully opaque when macOS Reduce Transparency, native full-screen mode, or an unavailable managed image requires it. Headless screenshots and debug state make the renderer-neutral alpha behavior autonomously verifiable; installed-window evidence and compositor traces cover the native blur and image hosts that cannot exist headlessly.

The shipped default remains exactly as it is today: 100% opacity, source `None`, no imported image, explicit-cell opacity off, an opaque sidebar, and no visual or performance change. Every backdrop is an explicit opt-in. Locale, preferred language, region, input source, and CJK font are compatibility inputs only and never select an appearance setting or preset. This preserves `docs/product/mvp.md` as the regression contract while adding the new behavior to `docs/product/spec.md`.

## Progress

- [x] (2026-07-14) Read `PLANS.md`, the product contracts, renderer ADRs, renderer process rules, and the existing renderer-parity plans.
- [x] (2026-07-14) Map the window, settings, snapshot, shared frame producer, debug harness, and all five renderer paths.
- [x] (2026-07-14) Research current Apple APIs and mature terminal transparency behavior, including macOS 26/27 Liquid Glass changes available in July 2026.
- [x] (2026-07-14) Research native and mature terminal transparency behavior and audit Laban's existing CJK fonts, localization, fixtures, IME path, and renderer tests as compatibility surfaces.
- [x] (2026-07-14) Record the renderer-neutral design, rollout order, and measurable acceptance criteria in this ExecPlan.
- [x] (2026-07-14) Address the independent fresh-context plan review: idempotent alpha, real backend proof, frame/cache routing, mixed-version `laband`, generated localization, observer ownership, mechanical performance gates, and theme-neutral preset semantics.
- [x] (2026-07-14) Descope `System Blur` and the `Frosted` preset to a documented follow-up; this historical decision was superseded after live validation (see `Active Work: Background Sources and Frosted Preset`).
- [x] (2026-07-14) Address the second independent plan review: define an authenticated installed-GUI control path, correct the software compositing seam, distinguish full-frame canvas overwrite from partial transparent erasure, and replace interpretive source/performance/IME review checks with executable verifiers.
- [x] (2026-07-15) Add the direct-opacity product contract, approved deferred System Blur/Frosted direction, and accepted ADR 0028 before implementation changes.
- [x] (2026-07-15) Implement the shared requested/effective policy, notification-backed settings, explicit-background snapshot bit, ABI-1 transport, and negotiated helper capability with focused tests.
- [x] (2026-07-15) Capture the immutable pre-renderer opaque Slug/vector release baseline at commit `0779195` with all 4,800 samples accepted across ten independent processes.
- [x] (2026-07-15) Deliver the first end-to-end Slug implementation, including AppKit window transparency and the grayscale antialiasing fallback.
- [x] (2026-07-15) Add equivalent software, classic Metal, GPU-driven Metal, vector glyph, and Slug replace-compositing support; pass the 25-test renderer alpha/idempotence/AA suite across all five selectors.
- [x] (2026-07-15) Add the live settings UI, full-screen and accessibility policy, fixture-authorized GUI and headless controls, renderer-identity parity matrix, alpha probes, transition smoke, and fixed renderer benchmark tooling.
- [x] (2026-07-15) Diagnose the vector wall-time tail without changing production code, benchmark method, baseline, or thresholds: identical binaries move the failure between opaque and direct runs, while 2,000-frame Metal traces keep vector content GPU p99 below `0.45 ms` and expose wall-only host-scheduling outliers.
- [x] (2026-07-15) Run exactly one post-diagnosis balanced acceptance comparison at `4ab9b68` with no retry. All 20 processes and 4,800 scheduled frames were accepted, but vector direct wall p99 remained outside its 10% gate, so the generated artifact was not promoted.
- [ ] Produce the final passing balanced renderer-comparison artifact. Sequential ordering was proven to confound opacity with host regime; multiple balanced runs accept every sample but move the vector p99 tail failure between opaque CPU, opaque wall, and direct wall. The one authorized post-diagnosis run also failed; no failing artifact is promoted as passing evidence.
- [ ] Complete the Apple Pinyin installed-window evidence and the five-run compositor evidence on the exact base-M1/8-GiB/60-Hz lane. Human validation supplied opaque, light, committed, wrap, and mode-2027 captures; a genuine 90% candidate capture over a dark high-contrast backdrop and the final manifest still remain. The exact compositor invocation rejects this 16-GiB host on `memoryBytes` before sampling.
- [x] (2026-07-15) Finish repository implementation closeout at `a8e0644`: the canonical full gate passes 444 parallel-safe tests plus 2,132 sequential tests with 16 expected skips and zero failures, the profilable release is installed at `/Users/rrj/Laban.app`, and all five Reduce Transparency and native-full-screen transition cycles pass.
- [x] (2026-07-15) Amend the contract after installed-app validation: keep the full sidebar opaque as one navigation surface and promote System Blur/Frosted from deferred direction into this active plan without weakening accessibility, full-screen, idle, or compositor gates.
- [x] (2026-07-15) Implement the opaque-sidebar slice at `f05f1bd`: terminal opacity no longer enters `SidebarProducer` or its memo key; local, remote, warm-swap, headless, CJK, generated-localization, and sidebar suites prove alpha 255 for the sidebar while terminal alpha follows the request.
- [x] (2026-07-15) Amend the product contract and ADR for the mutually exclusive Image source, managed still-image import, Fill/Fit/Stretch scaling, safe missing-image fallback, and explicit no-auto-selection boundary before source implementation.
- [x] (2026-07-15) Replace the permissive CJK evidence record with a version-2 schema and self-testing verifier that requires installed System Blur and Image/Fill debug state, source-specific trust-gate and complete Apple Pinyin flows, real hashed PNGs, and an explicitly unclaimed Rime/Squirrel status when that flow was not run. The actual installed captures remain pending.
- [x] (2026-07-15) Implement the AppKit-only System Blur effect host beneath the terminal content plane at `0a5df45`, `15154ea`, and `2ae3e79`, including settings/debug/headless resolution, lifecycle, accessibility, full-screen, opaque-sidebar, and zero-idle-cost coverage.
- [x] (2026-07-15) Implement the managed Image source in that same terminal-only AppKit host at `f7c4b53`, `d758ec1`, `ea2e209`, `39ffa4b`, and `9ae3ed1`, including atomic contained import/relaunch/removal, Fill/Fit/Stretch, missing/corrupt recovery, settings/debug/headless resolution, and zero-idle-cost coverage.
- [x] (2026-07-15) Implement the theme-neutral localized `Frosted` preset and its custom-state transitions at `aee32aa` without changing theme, sidebar opacity, explicit-cell policy, or locale behavior.
- [x] (2026-07-15) Close the expanded implementation at `589b8ca`: enforce GUI intent parity; strict per-run image compositor and lifecycle gates; exact corrupt-image vocabulary; exact preference/managed-asset restoration; and bounded process-group cleanup on normal exit, exceptions, SIGHUP, SIGINT, and SIGTERM.
- [x] (2026-07-15) Pass the canonical repository gate at `589b8ca`: 448 parallel-safe tests plus 2,194 sequential tests with 16 expected skips and zero failures, 46.29% labpty MC/DC against the 45% floor, sanitizer, runtime smoke, and E2E. All compositor, performance, transition-state, CJK-evidence, and debug-contract self-tests also pass.
- [x] (2026-07-15) Install profilable release `589b8ca` at `/Users/rrj/Laban.app` and pass five installed None↔System Blur↔Image source/opacity cycles, Fill/Fit/Stretch, missing-image repair, relaunch, Reduce Transparency, and native full-screen restoration at `.artifacts/transparency/transitions-589b8ca`.
- [x] (2026-07-15) Recalibrate Frosted to fixed opacity 0.30 at `e2cf5b3` after full-display measurements showed that the native material tint compounded 0.83/0.90 canvas tint into a nearly flat result; custom opacity remains literal. Add and pass a fixture-only full-display ScreenCaptureKit oracle with known rear stripes, source-correlation gates, edge-energy reduction, exact state, process cleanup, and preference restoration.
- [ ] Capture blur- and image-specific installed-window, scaling, CJK/IME, transition, and compositor evidence on every required lane; direct-opacity evidence does not substitute for the new AppKit-backed scenarios.
- [ ] Pass the fresh-agent Review Gate after the final implementation closeout. Sol approved the expanded implementation at `589b8ca` with no implementation findings; overall acceptance remains blocked by the stable final renderer artifact, source-specific CJK/Apple Pinyin manifest, both exact compositor summaries, and the macOS 27/120-Hz lane contract. Those literal evidence requirements must not be waived.

## Surprises & Discoveries

- Observation: The older CJK-compatibility inventory understates the current app. The live string catalog has 189 entries and zero missing `zh-Hans` or `zh-Hant` values, and focused CJK font, Chinese trust-gate, and preedit suites currently pass 30 tests with zero failures.
  Evidence: `rtk jq` over `Sources/LabanApp/Resources/Localizable.xcstrings`, followed by `rtk swift test --filter CJKFont`, `rtk swift test --filter ChineseTrustGate`, and `rtk swift test --filter FrameProducerPreedit` on 2026-07-14.

- Observation: The July 2026 native-looking answer for a terminal content canvas is not Liquid Glass. Apple's material guidance reserves Liquid Glass for navigation and controls and directs content backgrounds to standard materials.
  Evidence: Apple Human Interface Guidelines, Materials, researched 2026-07-14.

- Observation: Window-only ScreenCaptureKit filters suppress behind-window material composition and can make a working `NSVisualEffectView` look flat; AppKit hierarchy variants were equivalent under a complete-display capture. The remaining flatness at high canvas opacity came from the native material's own tint compounding the renderer tint, not from the host hierarchy.
  Evidence: Full-display stripe probes measured green-channel standard deviation `9.11` before the material, `6.24` at canvas opacity 0.30, `1.58` at 0.83, and `1.06` at 0.90. The installed-app oracle at 0.30 then measured direct/blur stripe correlations `1.000/0.896` and reduced edge energy from `179.532` to `1.123` (`0.0063x`) in `.artifacts/transparency/system-blur-composition-e2cf5b3-run2/summary.json`.

- Observation: Alpha-capable pixel formats were not enough for the current retained renderers. Their themed full clears and source-over solid pipelines would apply a translucent base more than once, while partial loads and the reusable software bitmap could accumulate alpha toward opaque.
  Evidence: Independent review of `Shaders.metal`, `MetalRenderer`, `VectorGlyphRenderer`, `SlugGlyphRenderer`, and `SoftwareRenderer` on 2026-07-14. The plan now requires non-blended full/damage resets plus replace background writes.

- Observation: `POST /debug/actions` is one aggregate route, not one `ControlRouteCatalog` entry per action. The live GUI currently permits only a small action allowlist, and `GET /debug/accessibility` is read-only, so an installed-app transition smoke cannot use newly named actions until their intent descriptors, authorization, GUI dispatch, and live handlers are all wired explicitly.
  Evidence: `ControlRouteCatalog`, `DebugActionIntentID`, `LabanControlServerRouting.dispatchGUIAction`, `LiveIntentRouter.route`, and `IntentCatalog` inspected on 2026-07-14.

- Observation: `SoftwareBackend.render` delegates command drawing to `SoftwareRenderer.render`; compositing-mode dispatch and `CGBlendMode.copy` therefore belong in `SoftwareRenderer`, while the backend owns bitmap reset/invalidation and presentation state.
  Evidence: `Sources/LabanRenderer/SoftwareBackend.swift` and `Sources/LabanRenderer/SoftwareRenderer.swift` inspected on 2026-07-14.

- Observation: `swift test -c release --filter ...` still compiles unrelated test targets, and the current tree has test-only control-server APIs available only in debug configuration, so a release XCTest benchmark cannot be isolated mechanically with `--filter`.
  Evidence: the first clean-worktree baseline attempt failed while compiling `LabanControlTests` because `skipExecutableVerificationForTests`, `mintSessionObserveToken`, and `testListenerFD` are absent in release builds. The replacement `transparency-renderer-bench` executable depends only on `LabanCore`, `LabanRenderer`, and `LabanTerminalCore` and builds in release without compiling unrelated tests.

- Observation: vector rendering intentionally permits only one content frame in flight, so an immediate asynchronous second submission can return `false` while the prior command buffer completes; that is backpressure, not a failed timing sample.
  Evidence: the first isolated vector baseline stopped at CPU-encode warmup frame 1. The final harness waits outside the timed interval for the next accepted submission, bounds the retry at five seconds, and accepted exactly 240 measured CPU and 240 measured wall frames in each of five processes per renderer.

- Observation: adding a defaulted compositing argument to the Metal renderer's local solid-emitter closure changes its function value from `(CGRect, UInt32) -> Void` to `(CGRect, UInt32, FrameCompositingMode) -> Void`; Swift does not apply default arguments when converting a function value to a narrower closure type.
  Evidence: the first clean detached renderer build failed at all decoration emitters. Commit `f22b205` wraps those call sites in explicit two-argument closures, after which the renderer target compiled.

- Observation: PNG test images use top-down row indexing while renderer damage coordinates are bottom-up. A small opaque rectangle at logical `y = 4...8` made the intended PNG `(5, 5)` semantic probe sample the translucent canvas instead.
  Evidence: the first clean renderer run produced alpha 179 for every purported opaque probe across all five backends. Commit `0bd657c` uses a full-height opaque stripe and probes PNG row 12, which is also inside the lower logical damage band; all 25 focused renderer tests then passed.

- Observation: the implementation host matches the required lane's stable macOS build, Macmini9,1 model, base Apple M1 chip, and 60 Hz display, but has 16 GiB rather than the required 8 GiB memory.
  Evidence: host identity captured on 2026-07-15 reports macOS 26.5.1 build 25F80, Macmini9,1, Apple M1, 17,179,869,184 bytes, and 60 Hz. The exact `profile-transparency-compositor --app=$HOME/Laban.app --lane=stable-base-m1-8gb-60hz --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json --duration=60 --runs=5 --artifacts=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz` invocation exits before sampling with `host does not match lane contract: memoryBytes`; it writes no summary, and none is claimed from this host.

- Observation: the first end-to-end renderer comparison failed only vector opaque CPU p99 even though its p50, p95, wall metrics, and direct-transparency metrics improved; an unchanged repeat passed every fixed gate.
  Evidence: the accepted repeat used 20 distinct release-benchmark processes and accepted all 4,800 samples. Vector opaque median CPU p50/p95/p99 was `1.097/1.401/1.696 ms` against the immutable baseline p99 limit of `1.939 ms`. No code, baseline, threshold, aggregation, or methodology changed; `.artifacts/transparency/renderer-comparison.json` is the passing repeat.

- Observation: the renderer parity evidence script initially assumed TCP readiness, treated state-returning debug actions as if they returned an `ok` field, and used an invalid `jq all` expression plus the wrong command kind for its find probe.
  Evidence: commit `16e2126` added Unix-socket readiness, validates each action's actual typed response, and corrected the probe expressions. The matrix now passes all five exact configured/effective renderer identities with null fallback reasons and nonempty PNGs.

- Observation: the full repository gate has one failure unrelated to transparency: DEC private cursor-position reporting returns no reply in `LabanSessionTests.testDECXCPRRepliesWithDECPrivateMarker`.
  Evidence: `./scripts/check` passed static checks, formal-spec drift checks, fuzz/build work, and reached the 442-test suite before that single failure. The same isolated test fails with the same empty reply in a clean validation worktree detached at merge base `3599f60`, while neighboring terminal-query tests pass.

- Observation: Computer Use can enumerate applications in this environment, but a fresh kernel still cannot return application state for either Finder or Laban.
  Evidence: the fresh kernel initialized and `list_apps` returned, after which bounded `get_app_state` calls for `com.laban.LabanApp` and `com.apple.finder` both hung past their timeouts. No blind input was sent and no Apple Pinyin or labeled visible-window evidence is fabricated; the CJK evidence manifest deliberately remains absent until a working UI bridge or human-operated run supplies it.

- Observation: the merge-base DECXCPR test failure was deterministic stale dependency output, not a terminal-session or transparency defect. `scripts/fetch-libghostty-vt` previously treated the upstream commit plus archive/header existence as a complete cache identity, so patches 0001 and 0003 could be added later while an archive containing only patch 0002 remained accepted; CI's zig-out and SwiftPM caches had the same omission.
  Evidence: before repair, both missing patches were forward-applicable and the fetch script exited early. The corrected fetch rejected the missing stamp/unapplied source, restored the pinned disposable checkout, applied 0002/0001/0003, rebuilt under Zig 0.15.2, touched the established C bridge relink input, and atomically wrote the ordered patch hash stamp. DECXCPR, DA1, XTWINOPS, and alt-screen-clear regressions then passed, a second fetch no-op'd without Zig, and `scripts/check-dependencies` mechanically validated source, stamp, and CI cache keys.

- Observation: four sequential benchmark blocks assigned the final host/thermal regime exclusively to vector direct opacity, and unchanged runs reversed which vector condition looked faster. Balancing adjacent opaque/direct pairs removed that systematic confound but did not eliminate process/GPU scheduling tails tight enough for the 5%/10% p99 gates.
  Evidence: the passing sequential repeat had vector opaque/direct CPU p50 `1.097/0.958 ms`; the second review's unchanged sequential run reversed them to `0.957/1.212 ms`. Two balanced 20-process runs then accepted all 4,800 samples and recorded the exact alternating schedule, but failed different gates: run 1 only vector opaque wall p99, run 2 vector opaque CPU p99 plus direct wall p99. No renderer, benchmark executable, workload, sample count, aggregation, threshold, or baseline changed.

- Observation: disjoint Metal damage bands could corrupt each other even though their scissors did not overlap, because recursive band encoding reused mutable renderer-owned instance buffers before the shared command buffer committed. The later band overwrote data still referenced by the earlier pass.
  Evidence: commit `09d9955` encodes the stable draw data once and repeats it under exact per-band scissors in one encoder. `GPUCellParityTests` then passed 49 tests with one expected skip, including disjoint partial-damage coverage.

- Observation: the styled glyph ladder initially exceeded its fixed 48-MiB atlas budget because admission counted synthetic bold/italic raster slop and the atlas used square next-fit shelf packing, not because the required glyph ink intrinsically exceeded the budget.
  Evidence: commits `13e2aca` and `0e58f34` separate intrinsic admission width from synthetic style slop, crop transparent horizontal remainder while retaining the antialiasing guard and normalized CJK geometry, and use first-fit shelves. The final deterministic prewarm is 50,190,867 bytes (47.9 MiB), 140,781 bytes below the 48-MiB cap; all five atlas-ladder tests and the relevant GPU, Metal glyph-smoke, CJK font-metrics, vector, and Slug suites pass.

- Observation: the final full gate's six assertions were stale contract reconstructions exposed by the transparency change, not renderer failures. Capture replay rebuilt the terminal canvas with implicit source-over although live capture serializes replacement compositing, and the control catalog still asserted 49 routes after adding the one fixed transparency endpoint.
  Evidence: commits `ca734ca` and `a8e0644` align capture replay and its AppKit-style fixture with `.replace` and update the exact unique-route count to 50. On `a8e0644`, `rtk ./scripts/check` passes the 444-test parallel-safe shard and the 2,132-test sequential shard with 16 expected skips and zero failures; labpty MC/DC is 46.86% against the 45% floor, and sanitizer, runtime-smoke, and E2E gates pass.

- Observation: the final implementation renderer comparison remained just outside the immutable wall-tail gate despite accepting every sample with the exact balanced schedule; rerunning until it passed would conceal the evidence rather than validate it.
  Evidence: `.artifacts/transparency/renderer-comparison-final-head.json` accepted 4,800/4,800 samples and failed only vector opaque wall p99: `2.491208 ms` exceeds the `2.128219 ms` 5%-over-baseline threshold. CPU, direct-opacity, and 8.33-ms gates passed. The run was not retried or rerolled, and the older passing `.artifacts/transparency/renderer-comparison.json` was not replaced or misrepresented as final-head evidence.

- Observation: the vector acceptance miss follows host/GPU scheduling tails rather than a measured transparency-path or steady-state GPU regression, but that diagnosis is not a waiver for the fixed wall-time gate.
  Evidence: the identical benchmark binary `c5c93473f8a7dead01f5d733b06746e0705e2176178dc37b5093e65f441d72cd` produced three unchanged balanced artifacts that respectively failed opaque wall p99 (`2.345583 ms`), failed direct wall p99 (`2.255542 ms`), and passed both (`1.939958/1.792459 ms`). At final head, focused 2,000-frame traces measured opaque CPU/wall p99 `1.795667/1.799791 ms` and direct CPU/wall p99 `1.853709/1.604208 ms`; actual vector-content GPU p99 was `0.408083/0.440166 ms`, while direct still contained a `28.371750 ms` wall maximum. No production or benchmark optimization follows from those data. Disabling or otherwise changing the presenter would change the method relative to the immutable baseline, so it was not used as acceptance evidence.

- Observation: one post-diagnosis same-method acceptance run still failed a moving vector wall tail despite accepting every scheduled frame, so it does not replace either the final-head failure or the older canonical artifact.
  Evidence: `.artifacts/transparency/renderer-comparison-post-diagnosis.json` (SHA-256 `d587ea29c5f199e17bdbfa9248c157ee59db63d5b7f62b87ab0d66a8763643c4`) records head `4ab9b689168fdc40e6717fa142bdcfa711b60f18`, benchmark binary `c646f3a3bee0f530bdcf5e37edfd520f01eb1c70fbd2c7b684d8cfb15e740529`, the exact alternating 20-process schedule, and 4,800/4,800 accepted scheduled frames. Its sole failure is vector direct wall p99 `1.987666 ms` above `1.689584 * 1.10 = 1.858542 ms`. The run was not retried, and `.artifacts/transparency/renderer-comparison.json` remained byte-for-byte unchanged.

- Observation: the installed release exercises the real accessibility and native-full-screen transition machinery cleanly after repository closeout.
  Evidence: `rtk ./scripts/install-app` installed profilable release `a8e0644` at `/Users/rrj/Laban.app`; `rtk ./scripts/transparency-transition-smoke --app=$HOME/Laban.app --cycles=5 --artifacts=.artifacts/transparency/transitions-final` passed all five Reduce Transparency and all five native-full-screen cycles.

## Outcomes & Retrospective

As of 2026-07-15 the complete implementation scope is closed at `589b8ca`: direct opacity, an AppKit-native System Blur host, a managed Image host with exact Fill/Fit/Stretch behavior, the localized theme-neutral Frosted preset, and the cohesive opaque sidebar all share one requested/effective policy. Software, classic Metal, GPU-driven Metal, vector glyph, and Slug use overwrite/replace background semantics, preserve opaque semantic regions, keep retained damage idempotent, flip presentation opacity live, and force vector-family grayscale antialiasing only while the surface is translucent. The Appearance controls, generated 11-locale catalog, accessibility/full-screen coordinator, fixture-authorized diagnostics, headless parity, safe image store, transition tooling, and fail-closed evidence verifiers are implemented and mechanically exercised.

Repository and installed-runtime closeout are green. At `589b8ca`, `rtk ./scripts/check` passes 448 parallel-safe tests plus 2,194 sequential tests with 16 expected skips and zero failures, 46.29% labpty MC/DC against the 45% floor, sanitizer, runtime smoke, and E2E. The four feature verifier self-tests and debug-contract check pass. The same implementation commit is installed as a profilable release at `/Users/rrj/Laban.app`; `.artifacts/transparency/transitions-589b8ca` passes five None↔System Blur↔Image cycles plus Fill/Fit/Stretch, missing-image repair, relaunch, Reduce Transparency, and native full-screen restoration. Sol's final expanded-scope implementation review reports no findings and approves `589b8ca`.

Overall acceptance nevertheless remains incomplete, and no missing evidence is inferred from code completeness. The final balanced renderer evidence still lacks a stable passing final artifact; the source-specific version-2 CJK/Apple Pinyin manifest is absent; the exact stable base-M1/8-GiB/60-Hz and macOS-27/Apple-silicon/120-Hz compositor summaries are absent; and the macOS 27 lane contract cannot be pinned without observing that host. This 16-GiB base-M1/60-Hz host cannot substitute for either lane. The third bounded Review Gate therefore remains **NOT PASSED**; the later Sol approval is an implementation review, not a reroll or waiver of items 1, 12, and 14.

## Research Snapshot: July 2026 State of the Art

This section embeds the conclusions needed to implement the feature; external pages are evidence, not required reading.

Apple's public contract is straightforward. An `NSWindow` that shows content behind it must not claim to be opaque, and a `CALayer` whose pixels can contain alpha must have `isOpaque == false`. Metal's existing `bgra8Unorm` and `bgra8Unorm_srgb` formats carry alpha, so Laban does not need a new pixel format. Its Metal shaders already emit premultiplied color; keep source-over for glyphs/overlays, but use overwrite clears and replace blending for background-establishing pixels so retained redraws are idempotent. Sources: [`NSWindow.backgroundColor`](https://developer.apple.com/documentation/appkit/nswindow/backgroundcolor), [`CALayer.isOpaque`](https://developer.apple.com/documentation/quartzcore/calayer/isopaque), and [`CAMetalLayer.pixelFormat`](https://developer.apple.com/documentation/quartzcore/cametallayer/pixelformat).

Use public semantic system effects instead of a private Core Animation filter, ScreenCaptureKit feedback loop, or hand-written blur shader. `NSVisualEffectView` with behind-window blending is available on Laban's macOS 13 minimum, adapts to system appearance, and leaves blur/compositing in AppKit and WindowServer rather than the terminal render loop. Do not put Liquid Glass behind the terminal canvas: Apple's current guidance assigns Liquid Glass to navigation and controls and says not to use it in the content layer, while standard materials remain the appropriate macOS background/content treatment. Keep the AppKit host replaceable so a future sidebar or control-plane treatment can adopt a newer semantic effect without changing frame commands or any renderer. Sources: [`NSVisualEffectView`](https://developer.apple.com/documentation/appkit/nsvisualeffectview), [`behindWindow`](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow), [`underWindowBackground`](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum/underwindowbackground), and [Human Interface Guidelines: Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

Accessibility overrides aesthetics. When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true, Laban must render an opaque background and remove the backdrop view while preserving the user's requested settings for later restoration. Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` so this changes live. Source: [`accessibilityDisplayShouldReduceTransparency`](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency).

Current terminal implementations converge on three useful semantics:

1. Opacity applies to the default terminal background, while explicitly colored cell backgrounds stay opaque unless the user opts in.
2. Text and overlays do not inherit the background opacity.
3. Blur/material is a separate choice from opacity, and native full screen may force opacity where macOS composition otherwise produces artifacts.

Ghostty's current configuration documents default-background opacity, separate cell-background opacity, blur, and macOS 26 `macos-glass-regular` / `macos-glass-clear` modes. Its current AppKit implementation places `NSGlassEffectView` below the terminal surface and disables transparency in native full screen. Stable source snapshots used for this plan are [`TerminalViewContainer.swift`](https://github.com/ghostty-org/ghostty/blob/cf60af281bd7559a819aa25372cef01d623b8c5a/macos/Sources/Features/Terminal/TerminalViewContainer.swift) and [`TerminalWindow.swift`](https://github.com/ghostty-org/ghostty/blob/cf60af281bd7559a819aa25372cef01d623b8c5a/macos/Sources/Features/Terminal/Window%20Styles/TerminalWindow.swift); the user-facing reference is [Ghostty configuration](https://ghostty.org/docs/config/reference). WezTerm exposes separate window and text/background opacity plus a macOS blur control in [Appearance](https://wezterm.org/config/appearance.html) and [`macos_window_background_blur`](https://wezterm.org/config/lua/config/macos_window_background_blur.html). Kitty likewise applies opacity to the default background by default and treats blur as optional in [its configuration reference](https://sw.kovidgoyal.net/kitty/conf/).

Additional terminal and desktop implementations confirm that transparency and compositor blur can be exposed as independent, performance-sensitive controls. Deepin Terminal exposes background transparency, Deepin's compositor work treats blur as an explicitly measured effect, and WindTerm exposes window transparency. These implementations inform only API and performance constraints. Laban's `Frosted` preset is a deterministic convenience bundle from the validated product contract: 30% opacity, System Blur, opaque explicit cell backgrounds, and no theme change. It is localized like every other setting, keeps the global default opaque, and is never selected from locale, language, region, input source, or font. Sources: [Deepin Terminal](https://wiki.deepin.org/en/Software/Offical_Project/Deepin_Terminal), [Deepin 25 Treeland blur work](https://www.deepin.org/en/deepin-25-pre-treeland/), [DTK `InWindowBlur`](https://docs.deepin.org/linuxdeepin/master/dtkdeclarative/classInWindowBlur.html), and [WindTerm](https://github.com/kingToolbox/WindTerm).

Laban already has substantial CJK compatibility that this feature must preserve. The accepted CJK font policy offers PingFang SC, Noto Sans Mono CJK SC, Sarasa Term/Mono/Gothic SC, and custom choices with live renderer refresh; CJK cells remain exactly two terminal cells wide and oversized glyphs may only scale down. The committed trust-gate fixture covers mixed Chinese prompts, dense Hanzi, ambiguous-width characters, emoji/ZWJ/flags, Powerline, and box drawing. The current localization catalog contains 189 strings with no missing `zh-Hans` or `zh-Hant` values. Transparency acceptance must reuse those assets, preserve opaque IME preedit backing, and explicitly guard Slug's adjacent-Hanzi raster fallback. The remaining manual claim gate is a real Rime/Squirrel IME pass; Apple Pinyin coverage alone is not enough to claim broad IME compatibility.

Laban has one additional correctness constraint. `Sources/LabanRenderer/VectorGlyphShaders.metal` states that its RGB subpixel path preserves destination alpha and assumes an opaque destination; it is therefore unsuitable for a translucent render target. Both vector and Slug renderers must resolve their effective antialiasing mode to grayscale whenever effective opacity is below 1.0 or system blur is active. Preserve the user's configured subpixel choice and restore it immediately when the surface returns to opaque.

## Decision Log

- Decision: Store one requested transparency configuration and derive an effective configuration from accessibility, full-screen state, OS capability, active snapshot-writer capability, and headless state.
  Rationale: User intent must survive temporary system overrides. A pure resolver makes the same behavior testable in AppKit, headless, and every renderer without reading `UserDefaults` on a render thread.
  Date/Author: 2026-07-14 / Codex

- Decision: Apply opacity only to the terminal content plane; keep the entire sidebar, explicit cell backgrounds, and foreground overlays opaque by default.
  Rationale: Installed validation showed that a translucent sidebar base beneath opaque tab cards looks like mismatched layers. Keeping the base, selectors, selected state, text, status, and attention cues opaque makes the sidebar one cohesive navigation surface. Selection, find highlights, cursor, image content, preedit, and explicit terminal backgrounds also carry meaning beyond decoration. The separate opt-in changes only explicit terminal cell backgrounds.
  Date/Author: 2026-07-14 / Codex
  Amended 2026-07-15: user validation replaced the earlier translucent-sidebar-base rule. Commit `f05f1bd` removes terminal opacity from `SidebarProducer` and its memo signature.

- Decision: Add `LABAN_CELL_FLAG_EXPLICIT_BACKGROUND` at bit 9 and set it when Ghostty reports an explicit background or inverse video is active.
  Rationale: Comparing a cell color with the current theme cannot distinguish an explicit color equal to the default and fails across theme changes. Inverse video visually promotes the foreground to a background and must remain opaque under the default policy. The existing local and laband snapshot layouts already transport a `UInt16` flags field, but old writers require the negotiated `snapshotCellExplicitBackgroundV1` capability; without it the app forces opacity rather than assuming the absent bit means inherited background.
  Date/Author: 2026-07-14 / Codex

- Decision: Reset full/damaged targets without blending and render every background-establishing primitive with replace compositing; reserve source-over for glyph coverage and semantic overlays.
  Rationale: The retained Metal targets and reusable software bitmap otherwise draw translucent backgrounds over prior translucent backgrounds, causing alpha to accumulate toward opaque. A full reset may overwrite with the resolved canvas RGBA to preserve zoom margins; partial damage erases to transparent before replay. Replace is renderer-neutral, idempotent, and preserves scroll-blitted premultiplied pixels.
  Date/Author: 2026-07-14 / Codex

- Decision: Ship direct opacity plus one `NSVisualEffectView` system-blur mode behind the terminal canvas; do not use Liquid Glass for terminal content and do not implement configurable blur radius or private filters.
  Rationale: This is the native, power-aware content-background treatment in Apple's July 2026 guidance. Keeping the backdrop host in AppKit and the alpha contract renderer-neutral preserves the option to add future effects to navigation or chrome without coupling any renderer to an OS visual style.
  Date/Author: 2026-07-14 / Codex
  Amended 2026-07-14: the system-blur mode itself was deferred to the section now titled `Active Work: Background Sources and Frosted Preset`. The no-Liquid-Glass, no-private-filter, and AppKit-host constraints were unchanged.
  Amended 2026-07-15: installed-app feedback promoted System Blur back into this active ExecPlan. The effect remains AppKit-only and all compositor/accessibility gates remain binding.

- Decision: Treat `None`, `System Blur`, and `Image` as mutually exclusive terminal backdrop sources and host Blur/Image only in AppKit below the terminal canvas.
  Rationale: One source choice avoids ambiguous blur-over-image semantics. Reusing the terminal canvas opacity as the sole tint keeps all five renderers unchanged and prevents a second image-opacity control or renderer texture path.
  Date/Author: 2026-07-15 / Codex

- Decision: Import a validated still image into private Application Support storage instead of persisting an external path or long-lived security-scoped bookmark.
  Rationale: The current app bundle is not sandboxed and has no bookmark-lifecycle convention. A managed copy survives relaunch, does not disclose the original absolute path in defaults or debug output, needs picker access only during import, and remains compatible with a future sandbox. Failed or cancelled replacement can leave the prior managed asset atomically intact.
  Date/Author: 2026-07-15 / Codex

- Decision: Persist exactly `Fill`, `Fit`, and `Stretch` image scaling, with Fill as the default; missing or corrupt managed images force a safe opaque effective surface.
  Rationale: Fill gives a useful default, Fit preserves the entire image with opaque black letterboxing, and Stretch supplies the requested independent-axis option. A missing image must not silently turn an Image request into direct desktop transparency; `backgroundImageUnavailable` preserves the request while protecting the visible window.
  Date/Author: 2026-07-15 / Codex

- Decision: Add a localized, theme-neutral `Frosted` preset with opacity 0.30, system blur, and explicit cell backgrounds kept opaque; do not auto-select it by locale and do not change the active theme. Amended after full-display compositor measurements showed the native material's tint compounded a 0.90 canvas tint into a nearly flat result (green-channel standard deviation `1.06` at 0.90 versus `6.24` at 0.30); arbitrary custom opacity remains literal.
  Rationale: Live validation established that direct transparency was not useful enough without blur. A named preset makes the exact validated combination reproducible while preserving the user's theme and keeping the opaque global default; its availability is unrelated to language, locale, region, input source, or font.
  Date/Author: 2026-07-14 / Codex
  Amended 2026-07-14: the preset was deferred with system blur; the definition above remains preserved in `Active Work: Background Sources and Frosted Preset`.
  Amended 2026-07-15: `Frosted` is again active work in this plan because direct transparency without blur did not provide enough utility in live use.
  Amended 2026-07-15: applying Frosted switches the source to System Blur but preserves an imported image and scaling mode for a later switch back; Frosted never combines Blur and Image.
  Amended 2026-07-15: the fixed preset opacity changed from 0.90 to the measured 0.30 value. No compensation curve was added; individual slider values continue to map literally to the canvas opacity.

- Decision: Verify System Blur visually with a full-display ScreenCaptureKit filter over known rear stripes, never with Laban's app screenshot or a window-only capture filter.
  Rationale: Only complete-display capture preserves the WindowServer's behind-window material composition. Source correlation rejects an opaque/occluded terminal, while reduced edge energy distinguishes the native blur from direct transparency. The fixture uses the existing environment-gated diagnostic credential and does not broaden production routes.
  Date/Author: 2026-07-15 / Codex

- Decision: Make the existing CJK trust gate, all 11 generated localizations, CJK font cascade, adjacent-Hanzi Slug fallback, and real IME composition part of transparency acceptance.
  Rationale: Compatibility acceptance must preserve fine strokes, double-width placement, fallback glyphs, and preedit readability across every renderer. A generic Latin alpha probe cannot establish those properties.
  Date/Author: 2026-07-14 / Codex
  Amended 2026-07-15: Because direct renderer PNGs cannot prove an AppKit native source, final evidence separately records raw installed `/debug/transparency` state and visible trust-gate/IME flows for System Blur and Image/Fill. These compatibility records never select or justify an appearance default.

- Decision: Force effective grayscale antialiasing in vector and Slug renderers for every translucent/material surface.
  Rationale: RGB subpixel coverage depends on a known opaque destination. Compositing those channels over an unknown desktop color creates color fringes and violates the existing shader's alpha assumption.
  Date/Author: 2026-07-14 / Codex

- Decision: Native full-screen and Reduce Transparency force effective opacity to 1.0 and backdrop style to none, then restore the requested configuration on exit.
  Rationale: Reduce Transparency is an explicit accessibility contract. Native full-screen opacity avoids AppKit/WindowServer artifacts such as gray fill or other-space content showing through and follows the current Ghostty macOS policy.
  Date/Author: 2026-07-14 / Codex

- Decision: Keep `TerminalBitmapView` as the sole workspace accessibility observer and feed its cached Reduce Transparency value into the coordinator.
  Rationale: The view already owns the complete accessibility projection. A second coordinator observer would duplicate invalidation/presentation and violate the one-wake idle-performance contract.
  Date/Author: 2026-07-14 / Codex

- Decision: Prove renderer parity through the authenticated debug-server path and assert configured/effective renderer identity before accepting a screenshot.
  Rationale: The legacy one-shot fixture path constructs `SoftwareRenderer` unconditionally. Debug-server startup already creates the selected production backend and exposes `/debug/render`, `/debug/frame-commands`, and `/debug/screenshot`.
  Date/Author: 2026-07-14 / Codex

- Decision: Slug is the first implementation milestone, but no Slug-only setting or command is allowed.
  Rationale: Slug provides the fastest visible path requested by the user, while defining settings, frame semantics, debug projection, and backend hooks in shared modules prevents a renderer-specific dead end.
  Date/Author: 2026-07-14 / Codex

- Decision: Keep every Review Gate item mechanical and runnable by a fresh agent on the implementation host. Renderer architecture is checked by focused behavior tests plus `scripts/check-transparency-source-invariants`; CJK/IME evidence is checked by `scripts/verify-transparency-cjk-evidence`; and lane-pinned `profile-transparency-compositor` runs are executed by the executing agent on matching machines while the gate verifies their JSON against a version-controlled lane contract through `scripts/verify-transparency-performance`. No gate item asks a reviewer to interpret grep output or prose.
  Rationale: `PLANS.md` requires gate items a script could check, and the compositor script refuses a mismatched host, so a gate that ordered the reviewer to run lane-pinned commands would deadlock the review-fix loop on any single machine.
  Date/Author: 2026-07-14 / Devin (plan review)

- Decision: Drive installed-app transparency smoke tests through the existing environment-gated GUI control server and aggregate `POST /debug/actions` route, using a new `diagnosticControl` capability granted only to the whole-app fixture token. Add GUI-safe typed actions for requested transparency, diagnostic reset, a Reduce Transparency test override, and real native-full-screen entry/exit; do not make `GET /debug/accessibility` mutating and do not relax `IntentCatalog`'s prohibition on ordinary `.fixture`-capability intents in GUI.
  Rationale: The installed app needs deterministic actuation, but app-observe, session-observe, and approved session tokens must not be able to mutate global appearance or test overrides. A separate capability preserves that boundary while reusing authentication, discovery, audit, and routing already exercised by the GUI control server.
  Date/Author: 2026-07-14 / Codex (second plan review fixes)

- Decision: Ship direct opacity only (the slider plus the explicit-cell opt-in); defer `System Blur`, the `Frosted` preset, the effect host, the `--background-effect` agent flag, and the 120 Hz macOS 27 seed compositor lane to a follow-up ExecPlan seeded by the section now titled `Active Work: Background Sources and Frosted Preset`.
  Rationale: The deferral removes the two riskiest external dependencies, WindowServer material-cost budgets and beta-OS compositor behavior, from the critical path of an otherwise renderer-internal change. `TerminalBackdropStyle`, the resolver inputs, and the debug vocabulary are retained so the follow-up is purely additive and cannot change resolver semantics.
  Date/Author: 2026-07-14 / Devin (plan review)
  Amended 2026-07-15: superseded by explicit user feedback after direct-opacity validation. System Blur, Frosted, the effect host, agent flag, and both compositor lanes are now incomplete deliverables in this plan; no threshold or evidence requirement is relaxed.
  Closed 2026-07-15: the implementation deliverables are complete at `589b8ca`; the renderer, CJK/IME, and exact-lane evidence requirements remain open without relaxation.

- Decision: Name the second native-compositor lane `macos27-apple-silicon-120hz`, require its exact version/build/channel/model/chip/memory/refresh values through a separate hashed lane contract, and make the final verifier require both that lane and `stable-base-m1-8gb-60hz` exactly.
  Rationale: Blur and Image exercise AppKit/WindowServer behavior that differs across the macOS 26 stable and macOS 27 high-refresh environments. The lane class can be implemented mechanically now, but the exact macOS 27 contract file is created only from a verified 120 Hz Apple-silicon capture host; placeholder identity values would turn a future mismatch into fabricated evidence.
  Date/Author: 2026-07-15 / Codex (expanded compositor implementation)

- Decision: Run the renderer baseline and compare phases through a dedicated `transparency-renderer-bench` release executable rather than release XCTest.
  Rationale: SwiftPM's test filter selects execution but does not isolate compilation, so unrelated debug-only test APIs make a release XCTest bundle unavailable. A dedicated executable preserves release optimization, uses only the renderer/core dependency boundary, and lets the wrapper prove ten distinct processes and hash the exact measured binary.
  Date/Author: 2026-07-15 / Codex (implementation)

## Context and Orientation

Laban turns a terminal snapshot into a renderer-neutral list of `FrameCommand` values, then one of five backends draws those commands. A frame command is a rectangle, glyph run, image, or other drawing operation with a source category such as terminal, sidebar, cursor, or selection. The relevant paths are:

- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` defines `LabanCell`, including the `UInt16` flags copied from Ghostty.
- `Sources/LabanTerminalCore/snapshot.c` reads Ghostty's terminal render state and fills each `LabanCell`. It already detects whether a background-color query succeeds and already performs inverse-color swapping.
- `Sources/LabanCore/LabandProtocol.swift` and `Sources/LabanCore/LabandSnapshotRingLayout.swift` serialize and read the same flags for daemon-backed sessions. No structure size change is planned, but hello capability negotiation distinguishes new semantic writers from ABI-1 legacy writers.
- `Sources/LabanCore/FrameProducer.swift` is the central conversion seam for both local and remote snapshots. It creates the terminal base rectangle, background runs, glyph runs, cursor, selection, find, image, and preedit commands.
- `Sources/LabanCore/SidebarProducer.swift` emits the sidebar base canvas and its more meaningful cards and overlays.
- `Sources/LabanRenderer/FrameCommand.swift` defines the shared drawing input.
- `Sources/LabanRenderer/RendererBackend.swift` defines the backend interface used by the app and headless runtime.
- `Sources/LabanRenderer/SoftwareBackend.swift` draws into a premultiplied BGRA Core Graphics bitmap.
- `Sources/LabanRenderer/MetalRenderer.swift`, `VectorGlyphRenderer.swift`, and `SlugGlyphRenderer.swift` own alpha-capable `CAMetalLayer` surfaces. Classic and GPU-driven modes are both implemented by `MetalRenderer` and selected by `Sources/LabanRenderer/RendererSelection.swift`.
- `Sources/LabanRenderer/VectorGlyphShaders.metal` contains the RGB-subpixel and grayscale compositing paths shared by the vector-family renderers.
- `Sources/LabanRenderer/MetalReadback.swift` and `PNGEncoder.swift` turn GPU targets into PNG evidence. They must preserve alpha.
- `Sources/LabanApp/TerminalBitmapView.swift` owns the active backend or software image and swaps the backend's presentation layer into the AppKit view.
- `Sources/LabanApp/MainWindowController.swift` creates the `NSWindow`, container, terminal view, and overlays. Today only the titlebar is transparent; the content window and renderer layers are opaque.
- `Sources/LabanApp/SettingsWindowController.swift` builds the Appearance and Rendering settings UI.
- `Sources/LabanCore/FrameProducer.swift` also defines `TerminalAccessibilityVisualOptions`, the accessibility display choices used during frame production. `TerminalBitmapView` already observes the workspace accessibility-change notification.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift`, `Sources/LabanApp/ScrollDebugServer.swift`, and the intent/projection types under `Sources/LabanCore/Intents` and `Sources/LabanCore/Control` provide deterministic headless actions and debug state. `Sources/LabanApp/Control/LiveIntentRouter.swift` owns the corresponding live-GUI query/action handlers.
- `Sources/LabanControl/ControlRouteCatalog.swift` declares every loopback `/debug` route with its method and schema references; `POST /debug/actions` is one aggregate route whose individual action names map through `DebugActionIntentID` and `IntentCatalog`. `scripts/check-debug-contract` cross-checks the route catalog against the endpoints and schemas documented in `docs/process/dev-process.md`. Register a new endpoint there, but register new action names in the action/intent seams named below rather than inventing per-action routes.

“Requested configuration” below means values persisted from the user's settings. “Effective configuration” means the values actually applied after system policy. “Premultiplied alpha” means final render-target red, green, and blue have been multiplied by alpha; `FrameCommand` colors remain in the repository's existing straight-RGBA representation and each renderer performs that multiplication exactly once. “Explicit background” means a terminal application emitted a background color for a cell, including inverse video, rather than the cell merely inheriting the terminal's default canvas.

The five renderer names used by settings and tests are `software`, `classic`, `gpuDriven`, `vectorGlyph`, and `slugGlyph`. All acceptance scenarios must cover all five unless a milestone is explicitly Slug-only.

## User-visible Contract

Add these controls to the Appearance tab in `SettingsWindowController`:

- **Background opacity**, a 0–100% slider with a numeric percentage label. Default: 100%. Persist the unit interval as a `Double`, clamp invalid stored values to 0...1, and coalesce slider updates so dragging does not enqueue redundant full redraws.
- **Apply opacity to colored cell backgrounds**, a checkbox. Default: off. It affects only terminal cells marked with the new explicit-background flag, including inverse-video cells.

Add **Background source** (`None` / `System Blur` / `Image`) and **Preset** (`Opaque` / `Frosted`) to the Appearance tab. These sources are mutually exclusive. `None` preserves direct window transparency. `System Blur` places one public behind-window AppKit material beneath the terminal content plane. `Image` places one validated, user-imported local still image beneath that plane. Neither extends under the opaque sidebar. An opacity of 1.0 resolves to a fully opaque surface with zero active backdrop cost.

When Image has no imported asset, selecting it opens a single-file `NSOpenPanel` sheet. Cancel restores the prior source without changing settings. A successful selection is decoded before commit, copied through a staging file into a private `background-images` child of `PersistenceStore.defaultBaseURL()`, and persisted only by a generated relative identifier plus a display name. Never persist or expose the original absolute path. `None` and System Blur preserve the imported copy; **Remove Image** clears it and selects None. Animated inputs use only the first frame so Image cannot introduce a periodic render source.

Expose an Image scaling popup with exactly **Fill**, **Fit**, and **Stretch**. Persist and live-apply the raw values `fill`, `fit`, and `stretch`; malformed or missing stored values resolve to Fill. Fill is the default and uses proportional aspect-fill (`max(destinationWidth / sourceWidth, destinationHeight / sourceHeight)`) with a centered crop. Fit uses proportional aspect-fit (`min(...)`) with centered opaque-black letterbox bars. Stretch independently maps each source axis to the complete terminal rectangle. Composite transparent source-image pixels over that same opaque-black backing. Respect image orientation metadata and recompute geometry on resize without importing or decoding per frame.

The existing background-opacity slider is the sole tint control for all three sources. The themed terminal canvas composites over Blur or Image, so lower opacity reveals more of the source; do not add an image-opacity slider. Choosing Image or changing image scaling produces custom preset state. Frosted remains exactly 30% opacity, System Blur, and opaque explicit cell backgrounds. Applying Frosted preserves the imported image and scaling for a later switch back; Frosted never combines Blur and Image. Custom opacity values, including 90%, remain literal and are not compensated.

Add every new label, help string, accessibility description, and debug-facing user message to the localization generator's translation tables for all 11 supported locales, then regenerate `Localizable.xcstrings`; never hand-edit only the generated catalog.

Apply the effective opacity to:

- the terminal's default base canvas;
- cells inheriting that default background.

Do not apply it to any sidebar primitive: its base, selectors/cards, text, status, selection, hover, drag, and attention cues remain one opaque navigation surface. Also do not apply it to terminal text, glyph coverage, cursor, selection, find highlights, images, preedit, or explicitly colored cell backgrounds by default. When the explicit-cell checkbox is enabled, apply it to explicit and inverse terminal cell backgrounds only; do not change the other exclusions.

When Reduce Transparency is active, the window is in native full screen, or the active remote session comes from a legacy snapshot writer that cannot identify explicit backgrounds, report an effective opacity of 1.0 and effective backdrop style `none`, keep the requested values persisted, and restore them without restarting when the override ends. The deterministic reason priority is `reduceTransparency`, then `nativeFullscreen`, then `legacySnapshotWriter`. A visible Image request whose managed copy is missing or corrupt uses the lower-priority reason `backgroundImageUnavailable`, stays fully opaque, and never falls through to direct desktop transparency. Keep that request and scaling mode so **Choose Again…** can repair it. Switching renderer, resizing, live font zooming, rebuilding the view, selecting a local/new-helper session, opening/restoring a session, and entering/exiting full screen must not produce an opaque, white, or uninitialized flash.

The untouched defaults are 100% opacity, source None, no imported image, explicit-cell opacity off, and an opaque sidebar. All transparency, blur, and image behavior is opt-in. No locale, language, region, input source, or CJK-font path may alter these defaults or select Frosted/Image. Compatibility fixtures and IME evidence verify behavior only; they never justify or drive appearance policy.

## Implementation Status: Background Sources and Frosted Preset

Direct background opacity, System Blur, managed Image, exact image scaling, and the `Frosted` preset are implemented at `589b8ca`. The canonical repository gate, final implementation review, and installed transition smoke are green. WindowServer material/image-host cost evidence, the stable final renderer artifact, source-specific CJK/IME evidence, and exact-lane identity remain on the critical path. Every direct-opacity renderer, accessibility, full-screen, idle, compatibility, and evidence gate remains binding.

Completed implementation deliverables:

- The **Background source** popup (`None` / `System Blur` / `Image`) and the **Preset** control (`Opaque` / `Frosted`) in the Appearance tab. `System Blur` means a behind-window standard macOS material, not Liquid Glass and not a renderer shader. `Image` means the managed local still image, not a terminal-frame image command. Backdrop source and opacity multiply rather than replace each other: the source supplies the backdrop and the themed Laban canvas tints it with the chosen opacity; None means direct window transparency.
- `Sources/LabanApp/TerminalBackgroundEffectHost.swift`, owning zero or one child: either one `NSVisualEffectView` with `.behindWindow` blending for System Blur or one cached image view for Image, never both. It occupies only the terminal content rectangle, sits below `TerminalBitmapView` and below cursors/overlays in `MainWindowController`, and never extends under the opaque sidebar or over glyphs. Its interface stays source-oriented; AppKit/ImageIO types never leak into `LabanCore` or `LabanRenderer`. Before replacing a child, remove the prior child and constraints. At effective opacity 1.0 the host is hidden/absent so an invisible source costs nothing.
- A managed image store below `PersistenceStore.defaultBaseURL()/background-images/`. Validate and copy through a private staging asset before atomically publishing the relative identifier; keep the prior asset/configuration on cancel or failure and retire it only after the replacement is usable. On relaunch resolve only contained generated identifiers. Missing/corrupt files retain the request, force visible opacity with `backgroundImageUnavailable`, expose repair/removal controls, and never reveal an external path through defaults, logs, or debug state.
- Fill/Fit/Stretch geometry and lifecycle tests for portrait and landscape images, transparent-image backing, resize, relaunch, replacement, removal, malformed persistence, missing/corrupt recovery, and first-frame-only animated inputs. Load/decode once per imported asset or required backing-scale refresh, not in a renderer or periodic frame loop.
- The `Frosted` preset: atomically selects 30% opacity, system blur, and leaves `Apply opacity to colored cell backgrounds` off. Theme-neutral (never changes `Theme.current`, `Theme.followsSystemAppearance`, or the user's dark/light variants), localized in all 11 locales, and never auto-selected from region, language, input source, or CJK font. Changing an individual control after applying a preset produces a custom state rather than mutating the preset definition.
- `laban-agent --background-effect=<none|system-blur>` in the deterministic equals-form flag style.

Remaining evidence obligations:

- Blur compositor scenarios and budgets: `Frosted` static WindowServer CPU median at most 8.0 percentage points above opaque static; `Frosted` animated at most 15.0 points above opaque animated. Every individual Image Fill/Fit/Stretch 60-second static run keeps renderer-present delta zero, app CPU median below 1.0%, zero deadline misses, zero post-settling image import/decode/file-read/apply/redraw growth, and its own WindowServer CPU median at most 2.0 percentage points above the five-run opaque-static median. Add installed-app Blur/Image screenshots, all three scaling modes, and compatibility evidence over each AppKit-backed source.
- The second compositor hardware lane: one 120 Hz Apple-silicon machine on the then-current macOS release or developer seed. New-OS material behavior is exactly the risk the follow-up owns; do not call beta-seed numbers representative of a final release.
- Constraints that bind the feature unchanged: no Liquid Glass behind terminal content, no private filters, no configurable blur radius, and blur/compositing stays in AppKit/WindowServer rather than the terminal render loop (see `Research Snapshot`).

The original foundations remain part of the completed implementation: the `TerminalBackdropStyle.systemBlur` case, the resolver's `supportsBehindWindowBlur` and `headless` inputs with their resolve-to-`none` behavior, the requested/effective backdrop fields in `/debug/transparency`, the `backdropSubviewCount` diagnostic, and the grayscale-AA rule for any translucent or material-backed surface.

Implementation landed in the planned order: bounded AppKit Blur host and lifecycle tests; pure source/scaling/availability contract and managed import store; mutually exclusive Image host; settings/debug/headless resolution; then the atomic Frosted preset with generated localizations. Installed transition coverage is complete. Installed-window/scaling/compatibility evidence and both exact compositor lanes remain; no evidence step may bypass host ownership, the managed-path boundary, or the opaque sidebar.

## Interfaces and Dependencies

Do not add a third-party dependency. AppKit, QuartzCore, CoreGraphics, and Metal already provide everything needed.

Keep renderer responsibilities smaller than window-style responsibilities. Create `Sources/LabanRenderer/RendererSurfaceTransparency.swift` with only the renderer-facing state:

```swift
public struct RendererSurfaceTransparency: Equatable, Sendable {
  public var isOpaque: Bool
}
```

Extend `FrameCommand.rect` with an explicit renderer-neutral compositing semantic in `Sources/LabanRenderer/FrameCommand.swift`:

```swift
public enum FrameCompositingMode: UInt8, Equatable, Sendable {
  case sourceOver
  case replace
}

case rect(
  CGRect,
  color: UInt32,
  source: FrameSource,
  compositing: FrameCompositingMode = .sourceOver
)
```

`replace` means that the command establishes the final premultiplied RGBA value for every covered pixel; drawing it twice must produce the same bytes as drawing it once. The translucent terminal base, the fully opaque sidebar base, inherited/default cell backgrounds, and explicit/inverse cell backgrounds use `replace`. Glyph coverage, cursor, selection, find, preedit foreground, images, and semantic overlays remain `sourceOver`. The GPU-cell background phase is semantically `replace` even though it is generated from `TerminalCellPayload` rather than `FrameCommand.rect`; its solid instances must use the same replace pipeline.

Create `Sources/LabanCore/TerminalTransparency.swift` with the pure cross-process/requested and effective policy types. Exact spelling can change only if all uses and this plan are updated together:

```swift
public enum TerminalBackdropStyle: String, CaseIterable, Codable, Sendable {
  case none
  case systemBlur
  case image
}

public enum TerminalBackgroundImageScaling: String, CaseIterable, Codable, Sendable {
  case fill
  case fit
  case stretch
}

public enum TerminalBackgroundImageAvailability: String, Codable, Sendable {
  case none
  case available
  case missing
  case corrupt
  case headlessUnsupported
}

public struct TerminalTransparencyConfiguration: Equatable, Sendable {
  public var backgroundOpacity: Double       // always clamped to 0...1
  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle
  public var imageScaling: TerminalBackgroundImageScaling
}

public enum TerminalSnapshotBackgroundCapability: String, Codable, Sendable {
  case inProcess
  case supported
  case legacy
}

public enum TerminalTransparencyForceOpaqueReason: String, Codable, Sendable {
  case reduceTransparency
  case nativeFullscreen
  case legacySnapshotWriter
  case backgroundImageUnavailable
}

public struct EffectiveTerminalTransparency: Equatable, Sendable {
  public var backgroundOpacity: Double
  public var applyToExplicitCellBackgrounds: Bool
  public var backdropStyle: TerminalBackdropStyle
  public var forceOpaqueReason: TerminalTransparencyForceOpaqueReason?
  public var isSurfaceOpaque: Bool
}

public enum TerminalTransparencyPolicy {
  public static func resolve(
    requested: TerminalTransparencyConfiguration,
    reduceTransparency: Bool,
    nativeFullscreen: Bool,
    supportsBehindWindowBlur: Bool,
    imageAvailability: TerminalBackgroundImageAvailability,
    snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability,
    headless: Bool
  ) -> EffectiveTerminalTransparency
}
```

The resolver must be pure and deterministic. An unavailable or headless system-blur request resolves to `backdropStyle == .none` while preserving the requested configuration in settings. Headless preserves an Image request and scaling but reports `headlessUnsupported` and effective backdrop `none`. A visible missing/corrupt Image request forces opacity with `backgroundImageUnavailable`; it must not become direct transparency. Reduce Transparency, native full screen, and a legacy snapshot capability retain that priority order ahead of image unavailability. An opacity of exactly 1 resolves to an opaque surface and no effective backdrop. Use a small epsilon only at the UI parsing boundary; rendering should receive a stable clamped value.

`TerminalBackdropStyle` keeps its `systemBlur` case and adds `image`; the resolver keeps its `supportsBehindWindowBlur` input and receives pure Image availability rather than an AppKit URL. The visible app passes `supportsBehindWindowBlur: true` only after the host is installed and capable. Headless remains false and resolves native sources to effective `none`. `TerminalTransparencyPolicyTests` cover supported, unavailable, headless, missing, and corrupt paths so AppKit capability cannot change resolver semantics.

Extend `RendererBackend` with a live method such as:

```swift
func setSurfaceTransparency(_ transparency: RendererSurfaceTransparency)
```

Every backend must implement it. For each Metal backend, it updates `CAMetalLayer.isOpaque`, invalidates any persistent full-frame target, and guarantees the next presented drawable was entirely initialized with the new alpha policy. For software it records the state needed for presentation and invalidates the bitmap. A newly created backend must receive the current state before its presentation layer becomes visible.

All backends must also implement the same damage-reset contract. A full frame resets the whole target with blending disabled to the resolved terminal canvas RGBA, including its effective alpha; this preserves intentional empty/zoom margins without compositing a second tint. If no terminal canvas command exists, reset to transparent black. Every subsequently replayed base/background command uses replace, so drawing the canvas after the clear leaves identical bytes. A partial frame first erases every damaged band/rectangle to transparent black with blending disabled, then replays intersecting commands. Background-establishing commands use a no-blend `source = one, destination = zero` pipeline in Metal and `CGBlendMode.copy` in Core Graphics; source-over commands keep the existing premultiplied-alpha pipeline. Scroll blits copy existing premultiplied pixels unchanged and erase/replay every newly exposed or invalidated region. `NSWindow.backgroundColor` and permanent terminal view/layer backgrounds remain clear, so AppKit never adds another tint. Rename/adapt the current `fullRedrawClearColor` helper to return the effective-alpha canvas clear and prohibit using it through a blending draw.

Create `Sources/LabanCore/TerminalBackgroundCompositingOptions.swift`:

```swift
public struct TerminalBackgroundCompositingOptions: Equatable, Sendable {
  public var opacity: UInt8
  public var applyToExplicitCellBackgrounds: Bool

  public static let opaque = TerminalBackgroundCompositingOptions(
    opacity: 255,
    applyToExplicitCellBackgrounds: false
  )
}
```

`backgroundCompositingOptions: TerminalBackgroundCompositingOptions` and `snapshotBackgroundCapability: TerminalSnapshotBackgroundCapability` on `TerminalSurfaceFrameRequest` are the sole per-frame transport into `TerminalSurfaceController`. Thread them through both local and remote `makeFrame` paths, every request constructor in the visible app and `HeadlessDebugRuntime`, capture/replay request construction, backend prewarming, and renderer switching. Pass the compositing value into `FrameProducer` only. `SidebarProducer` and `SidebarCacheSignature` intentionally exclude it, so terminal-only opacity changes reuse opaque sidebar commands. Neither producer reads settings.

Resolve colors to the existing straight-RGBA command representation during command production and premultiply exactly once in each renderer's shader/Core Graphics boundary. Opacity changes alpha only; do not premultiply on both sides of that boundary. The ADR and tests must name the actual representation. The key invariants are one premultiplication and one themed-background application, not merely that alpha is present.

Create `Sources/LabanApp/TerminalTransparencySettings.swift` following the notification-backed pattern of nearby settings types. It owns persisted requested values, Image scaling, a generated managed-image identifier/display name, and a `didChangeNotification`, but it does not inspect windows or accessibility. Missing keys must produce exactly opacity 1.0, source None, Fill scaling, no image, and explicit-cell opacity off under every locale/input configuration. Create `Sources/LabanApp/TerminalBackgroundImageStore.swift` to validate/import/replace/remove contained managed assets without persisting the selected absolute path. Create `Sources/LabanApp/TerminalWindowTransparencyCoordinator.swift` as the one MainActor owner that:

- observes requested-setting changes and the target window's enter/exit-full-screen notifications;
- receives Reduce Transparency as an input from `TerminalBitmapView`, which remains the sole owner of the existing workspace accessibility observer for Reduce Motion, Increase Contrast, Differentiate Without Color, and Reduce Transparency;
- receives the active session's snapshot-background capability from `TerminalBitmapView`/session coordination before that session's first frame or tab-selection frame is built;
- receives managed-image availability from the image store without exposing a URL to renderers or debug projection;
- resolves effective state with `TerminalTransparencyPolicy`;
- configures `NSWindow.isOpaque` and keeps `NSWindow.backgroundColor == .clear` whenever the surface is nonopaque;
- sends the effective configuration to `TerminalBitmapView`;
- exposes a read-only requested/effective status projection for debug output;
- removes notification tokens on teardown.

Refactor the existing `TerminalBitmapView` accessibility callback rather than adding another observer. It refreshes the cached `TerminalAccessibilityDisplayOptions` once, forwards `reduceTransparency` to the coordinator, applies all changed visual/transparency state, and coalesces that notification into one frame invalidation/wake. The coordinator's call back into the view must support `wake: false` for this path so the view performs the single wake after all accessibility fields are current. Unit tests compare counter deltas before and after one notification and require one accessibility callback, at most one effective transparency application, and one render wake.

Create `TerminalBackgroundEffectHost` in this plan with the ownership, terminal-only geometry, zero-or-one Blur/Image child lifecycle, and cached Fill/Fit/Stretch image view recorded in `Active Work: Background Sources and Frosted Preset`.

Add a MainActor method on `TerminalBitmapView`, for example:

```swift
func applyTransparency(
  requested: TerminalTransparencyConfiguration,
  effective: EffectiveTerminalTransparency,
  wake: Bool = true
)
```

It caches effective background-compositing options, updates the active backend surface, invalidates one full frame, and wakes rendering once unless the caller is the coalescing accessibility path described above. Backend creation, prewarming, and renderer switching must copy this value into `TerminalSurfaceFrameRequest` before rendering and before installing the new `presentationLayer`. The no-image software fallback and transient-resize layer may show one themed alpha tint before the first renderer frame, but must be a distinct removable layer: remove/hide it before presenting renderer pixels so it can never double-composite with the frame. The `NSWindow`, `TerminalBitmapView`, and permanent backing layers remain clear whenever nonopaque.

Add `LABAN_CELL_FLAG_EXPLICIT_BACKGROUND = 1u << 9` to `LabanTerminalCore.h`. In `snapshot.c`, retain whether the background-color query succeeded before falling back to the default. Set the bit when it succeeded or when inverse video is active. Preserve the bit through `LabandSnapshotCell`, `LabandSnapshotRingCellRead`, and every local/remote conversion. If any `TextAttributes` or style cache compares flags, mask the new non-glyph bit out so it cannot split glyph batches or alter font selection.

The unchanged `UInt16` field makes the layout additive but does not make old writers semantically compatible. Add the hello capability string `snapshotCellExplicitBackgroundV1` to new `laband` builds and carry the negotiated capability through `LabandLifecycleDecision`, session coordination, and the active frame request. Direct/in-process snapshots are capability-known because they use the app's own terminal core. When the active session is remote and the connected helper did not advertise this capability, resolve the whole terminal window to opacity 1.0 and backdrop style none with `forceOpaqueReason == legacySnapshotWriter`; preserve the requested setting and restore it immediately when the user selects a capability-aware session or the helper is safely upgraded. Do not guess from colors, because an explicit color equal to the theme default is otherwise indistinguishable.

Keep protocol and ring ABI version 1 only if the capability is present in hello and mechanically gates all old-writer paths. Tests must decode old JSON snapshots and ABI-1 rings with an old hello lacking the capability, prove the forced-opaque downgrade, and cover explicit-theme-equal and inverse cells. Complement them with new-writer/new-reader tests proving bit 9 survives JSON and ring transport. If implementation cannot propagate the negotiated capability unambiguously to every session, bump the relevant protocol/ring ABI instead of shipping an unsafe heuristic.

Add debug state and action contracts. Use a response model with at least:

```json
{
  "requestedOpacity": 0.70,
  "effectiveOpacity": 1.0,
  "requestedBackdropStyle": "image",
  "effectiveBackdropStyle": "none",
  "backgroundImageScaling": "fill",
  "backgroundImageState": "missing",
  "backdropSubviewKind": "none",
  "applyToExplicitCellBackgrounds": false,
  "forceOpaqueReason": "backgroundImageUnavailable",
  "surfaceOpaque": true,
  "effectiveGlyphAntialiasing": "grayscale",
  "snapshotExplicitBackgroundCapability": "supported",
  "configuredRenderer": "slugGlyph",
  "effectiveRenderer": "slugGlyph",
  "backdropSubviewCount": 0,
  "accessibilityRefreshCount": 4,
  "effectiveTransparencyApplyCount": 7,
  "transparencyRenderWakeCount": 7,
  "rendererPresentCount": 42
}
```

Expose the projection at `GET /debug/transparency`. Preserve the requested/effective backdrop fields and extend their schema enum with `image`. Add `backgroundImageScaling` (`fill`, `fit`, `stretch`), `backgroundImageState` (`none`, `available`, `missing`, `corrupt`, `headlessUnsupported`), `backdropSubviewKind` (`none`, `systemBlur`, `image`), and an optional suppression reason. Never expose the selected or managed absolute path; a generated asset identifier, decoded dimensions, and cached content digest are sufficient for evidence.

Add these typed action names to the existing aggregate `POST /debug/actions` contract:

- `setBackgroundTransparency`, carrying clamped `opacity` and `applyToExplicitCellBackgrounds`, updates the same requested settings used by the Appearance UI;
- `resetTransparencyDiagnostics` resets diagnostic counters only, never requested/effective state;
- `setReduceTransparencyOverride`, carrying nullable `enabled`, installs or removes a debug-only override and runs through the same cached-accessibility/coalesced-apply path as the workspace notification; removing the override immediately restores the real `NSWorkspace` value;
- `setNativeFullScreen`, carrying `enabled`, calls the real target window `toggleFullScreen(_:)` path when a transition is needed; the caller polls `/debug/transparency` until the requested native-full-screen state is observed rather than treating action return as transition completion.
- `setBackgroundSource`, carrying `none`, `systemBlur`, or `image`, changes only the requested source and reuses an already imported image when present;
- `setBackgroundImageScaling`, carrying `fill`, `fit`, or `stretch`, live-applies and persists scaling without reimporting or waking a parked renderer after the host redraw settles;
- `importBackgroundImage`, carrying a fixture path and initial scaling, is available only to the isolated whole-app fixture token. Resolve the path through the existing fixture/control-directory containment rules, validate it, and copy it into a run-scoped managed store before atomically selecting Image;
- `removeBackgroundImage` selects None, clears the managed identifier, and removes only the feature-owned managed copy.

The actions are not separate `ControlRouteCatalog` routes. Add their names and intent-ID mappings in `Sources/LabanCore/Intents/DebugRequestPayloads.swift`, Codable request models and schemas in `LabanCore`, cases/decoding in `Sources/LabanDebug/DebugRuntimeRequests.swift`, variants in `schemas/debug/action.schema.json`, descriptors in `IntentCatalog.shared`, GUI dispatch allowlisting in `LabanControlServerRouting.dispatchGUIAction`, and handlers in `LiveIntentRouter.route`; route the headless-applicable setting/reset/Reduce-Transparency actions through `HeadlessIntentRouter` as well. `ControlRouteCatalog` changes only for the new fixed `GET /debug/transparency` endpoint. Update discovery/schema/authorization tests so every action resolves to exactly one descriptor and the advertised surface matches the implementation.

Add `Capability.diagnosticControl` and grant it only to `ControlTokenTier.fixture`; none of `appObserve`, `sessionObserve`, `approvedSession`, or `approvedSessionFamily` receives it. Explicitly reject/filter `diagnosticControl` from approval-request capability parsing so an approved-session capability array cannot acquire it. All diagnostic appearance actions require that capability, use the environment-gated whole-app GUI fixture token, and are absent or forbidden for every other token. Preserve the existing validation rule that rejects `.fixture`-capability descriptors available in GUI; these descriptors use the narrower `diagnosticControl` capability instead. Add policy tests proving fixture-token success, non-fixture denial (including a forged approved-session capability list), GUI availability for every action, headless unavailability for `setNativeFullScreen`, headless request/effective projection for native sources, strict fixture-path containment for image import, and no permission broadening in `ControlLazyAttachAllowlist` or `ControlSessionObserveFamily`.

Counter deltas make one-observer, one-wake, and one-present requirements mechanical. `backdropSubviewCount` is instantaneous: exactly 1 while effective System Blur or Image is active, otherwise 0; `backdropSubviewKind` distinguishes them and proves mutual exclusion. Include the active snapshot-writer capability state (`inProcess`, `supported`, or `legacy`), real versus overridden Reduce Transparency state, native-full-screen state, and effective renderer identity in the projection. Add cached image import/decode/apply/redraw counts so a static evidence window can prove there are no per-frame file reads or decodes. `GET /debug/accessibility` remains read-only.

Extend `laban-agent` with deterministic equals-form flags `--background-opacity=<0...1>` and `--background-opacity-cells`. Keep user-image selection in Settings and fixture-authorized diagnostics rather than adding an arbitrary external-path agent flag. Headless mode applies alpha to PNG output, preserves requested source/scaling in state, and reports native backdrop resolution as `none` because no AppKit host exists.

## Plan of Work

### Milestone 0: Specify the contract and preserve explicit-background identity

First update `docs/product/spec.md` with the user-visible contract above. State that the exact default is opacity 1.0, source None, no image, explicit-cell opacity off, and an opaque sidebar; every renderer must be equivalent; foreground content remains legible; accessibility and full screen can force opacity; and headless PNG alpha is part of the behavior. Record mutually exclusive None/System Blur/Image, managed import, Fill/Fit/Stretch, safe missing-image fallback, and the `Frosted` preset with the AppKit-only source and theme-neutral constraints. Do not edit the historical milestones/non-goals in `docs/product/mvp.md`.

Add `docs/adr/0028-terminal-background-transparency.md` and index it from `docs/adr/README.md`. The ADR records ownership across the window, AppKit backdrop host, managed image store, frame request/producer, and renderer; the opaque-sidebar boundary; replace-versus-source-over command semantics; effective-alpha canvas overwrite for full frames versus transparent-black erasure for partial damage; the one-premultiplication/one-themed-tint invariant; explicit-background flag and mixed-version capability semantics; forced grayscale AA; the single accessibility-observer owner; system overrides; and why public native backdrops replace configurable private blur or renderer image paths. Mark it accepted before later milestones and amend it whenever user validation changes these load-bearing boundaries.

Then add the shared value types and tests for `TerminalTransparencyPolicy`. Add settings persistence tests for defaults, clamping, notification coalescing, old installations with missing keys, unavailable/unrequestable system blur (persisted-but-unsupported backdrop values resolve to `none`), legacy snapshot writers, and requested-versus-effective restoration.

Before changing a renderer, add the harness-only baseline phase of `scripts/benchmark-transparency-renderers` and capture `.artifacts/transparency/opaque-baseline.json` from the current opaque Slug/vector paths. The baseline phase must not depend on the new renderer behavior; it wraps the existing release benchmark conventions with the fixed 40-warmup/240-frame/five-process JSON contract. Record the implementation commit and hardware/OS identity in the baseline so the compare phase can reject a mismatched host/build configuration.

Add the cell flag in `LabanTerminalCore.h` and `snapshot.c`. Extend existing snapshot fixture tests so these cases are distinguished:

- a default-background cell does not carry the bit;
- `SGR 41m` or another explicit background does carry it;
- an explicit color equal to the theme default still carries it;
- inverse video carries it;
- local, laband protocol, and snapshot-ring paths preserve it;
- an old helper without `snapshotCellExplicitBackgroundV1` forces opacity with `legacySnapshotWriter`, while a new helper advertises and preserves the bit;
- it does not affect glyph style/batch keys.

At the end of this milestone, the feature is not visible yet, but tests can prove that shared policy and cell semantics are stable. Run the focused commands in `Concrete Steps` and commit this milestone independently.

### Milestone 1: Deliver Slug transparency end to end

Wire `TerminalBackgroundCompositingOptions` through `TerminalSurfaceFrameRequest`, every visible/headless/prewarm request constructor, and both local and remote `makeFrame` paths before passing it into `FrameProducer`. Apply opacity to the terminal base rectangle and default-background runs and mark those commands `replace`. Keep explicit-background runs opaque unless opted in and mark them `replace` as well. Preserve preedit and all foreground overlays as `sourceOver`. Keep every `SidebarProducer` command opaque and exclude terminal compositing options from its memo signature. Tests must show that the first frame after a settings change, backend prewarm, and renderer swap carries requested terminal alpha plus sidebar alpha 255, without rebuilding the sidebar solely because terminal opacity changed.

Implement `RendererBackend.setSurfaceTransparency` first in `SlugGlyphRenderer`. Change its `CAMetalLayer.isOpaque` live, rebuild or invalidate retained full-frame resources, and reset every full target by overwriting it with the resolved effective-alpha canvas clear. For partial bands, add an explicit transparent erase pass with blending disabled before replay; render replace solids through a no-blend pipeline and source-over content through the existing pipeline. Do not solve transparency by reordering frame commands: retained batching can reorder equivalent primitives, so compositing mode must be carried into the instance split. Add repeated full-frame, repeated identical partial-band, zoom-margin, and scroll-blit tests that render the same 70% base at least 100 times and assert alpha remains 179 rather than approaching 255.

Extend the existing subpixel-policy resolver used by vector/Slug rendering so any nonopaque effective surface returns grayscale. Include the exact machine-readable reason string `transparentSurface` in renderer/debug status; the Review Gate greps for that literal. Do not overwrite the persisted RGB-subpixel setting. Add shader/render tests that demonstrate there is no RGB fringe and that returning to opacity 1 restores the configured mode.

Build the AppKit settings and coordinator. Make the window and Slug layer nonopaque only when effective transparency requires it, with a clear permanent AppKit background. If cold launch needs a tint before the first frame, use a distinct temporary fallback layer and remove it before installing the renderer presentation layer; never tint both the AppKit background and renderer target. Update cold-launch activation, transient resize, renderer swap, and full-screen transitions so the effective state is applied before presentation.

At the end of this milestone, launch the installed app with Slug selected, set opacity to 70%, and observe a real window behind Laban through the default background. Explicit red and inverse backgrounds remain opaque, glyphs and preedit remain legible, and toggling the setting does not restart the session.

### Milestone 2: Bring every renderer to parity

Implement the same surface hook in classic and GPU-driven `MetalRenderer`, `VectorGlyphRenderer`, and `SoftwareBackend`. Do not fork the semantic decisions into five renderers: each receives already resolved frame colors plus the one `isOpaque` surface property.

For Metal paths, audit full redraw overwrite clears, retained backing textures, partial-damage transparent erase passes, replace/source-over pipeline splits, scroll blits, and drawable-to-readback copies. Alpha outside damage must never contain stale data. The first frame after opacity/backdrop changes must be a full redraw. Preserve existing present-link and idle-parking behavior from ADR 0026: a settings change may wake and present once, but a translucent idle window must not cause continuous app-side rendering.

For the software backend, overwrite the bitmap with the resolved effective-alpha canvas clear at the start of every currently-full render, use `CGBlendMode.copy` for replace rectangles, restore `.normal` for source-over content, and ensure `TerminalBitmapView.draw(_:)` does not paint a fallback beneath the completed image. If software later honors partial damage, it must use the same transparent erase-and-replay contract. For classic/GPU-driven Metal and vector rendering, add the same replace pipeline and damage reset used by Slug. Vector uses the same grayscale-on-transparency rule as Slug. Classic and GPU-driven renderers do not gain a separate AA setting.

Add a shared renderer parity fixture with default canvas, explicit colored and inverse cells, normal and faint glyphs, cursor, selection, find highlight, image, preedit, opaque sidebar base, selected tab, and attention state. Render at opacity 0.70 in all five modes, read back PNG pixels, and compare semantic probes rather than requiring identical glyph rasterization. For every backend, capture after one full frame, after 100 identical full frames, after 100 identical partial-damage frames, and after a scroll blit plus exposed-row replay; terminal default alpha must be 179 in every capture and the sidebar plus semantic regions must remain 255.

At the end of this milestone, switching among all five renderers preserves background alpha and exclusions. Default opacity 1.0 produces the same opaque images as the pre-feature baselines.

### Milestone 3: Prove CJK and IME compatibility

Reuse `fixtures/cjk/trust-gate.fixture.json` rather than inventing a transparency-only approximation. Extend its debug run so opaque, 85%, 90%, and 95% direct transparency can be selected without changing the fixture text.

Run the fixture through software, classic, GPU-driven, vector glyph, and Slug with PingFang SC. If Noto Sans Mono CJK SC or a Sarasa SC preset is installed, repeat visible spot checks with it and record the exact font/version; absence of optional fonts is not a failure. Probes and screenshots must cover the mixed Chinese prompt, dense Hanzi, ambiguous-width characters, emoji/ZWJ/flag clusters, Powerline and box drawing, and adjacent `中文` in Slug. Confirm every CJK glyph occupies the same two-cell geometry as the opaque run and that fine horizontal/vertical strokes remain distinguishable over both light and dark high-contrast backdrops.

Exercise live Apple Pinyin composition and selection with the window transparent. The preedit mask, caret, candidate-window anchor, marked-text replacement, wide-glyph wrap, and mode-2027 cluster widths must match the opaque path. Before claiming broad IME compatibility in release notes, repeat the same acceptance flow with a current Rime/Squirrel installation; if that manual pass has not happened, document Apple Pinyin as tested and leave Rime/Squirrel unclaimed.

Store the CJK/IME record at `.artifacts/transparency/cjk/cjk-evidence.json` using `schemas/transparency-cjk-evidence.schema.json` version 2. It contains installed-build/capture-host provenance; `rendererArtifacts` with exactly the five keys `software`, `classic`, `gpuDriven`, `vectorGlyph`, and `slugGlyph`; and exact native-source records for 90% System Blur and 90% Image/Fill. The System Blur record requires light and dark trust-gate PNGs, the Image/Fill record requires a high-contrast trust-gate PNG, and both require a captured raw `/debug/transparency` response proving the requested/effective source, opacity, zero override, and exactly one matching backdrop child. Every PNG record carries its actual dimensions and SHA-256 digest.

The `applePinyin` record has `status: "passed"` only when its `sourceArtifacts` contains exact opaque, System Blur, and Image/Fill flows, each with candidate, committed, candidate-wrap, committed-wrap, and mode-2027 PNGs. The `rimeSquirrel` status is exactly `passed` or `notTested`: `passed` requires nonempty opaque, System Blur, and Image/Fill artifacts and `compatibilityClaimed: true`; `notTested` requires an empty source-artifact object and `compatibilityClaimed: false`. Add a `Transparency IME support` table to `docs/product/spec.md` whose statuses match the manifest exactly. `scripts/verify-transparency-cjk-evidence` validates the versioned record, exact source/role sets, real PNG signatures/dimensions/digests, state JSON semantics, Git-ancestor installed build, artifact containment, and product-spec agreement. This permits an honest Rime/Squirrel limitation statement while mechanically rejecting a positive claim without complete evidence.

Add every transparency source string to `TRANSLATIONS` in `scripts/gen-localizable-xcstrings.py` and, where that generator expects it, `scripts/localizable-supplement-de-pt-it.py`. Supply nonempty, non-English-fallback translations for all 11 declared locales (`zh-Hans`, `zh-Hant`, `ja`, `ko`, `fr`, `es`, `hi`, `ru`, `de`, `pt-BR`, and `it`), then run the generator to replace `Sources/LabanApp/Resources/Localizable.xcstrings`. Do not translate renderer identifiers or debug enum values, but localize their user-facing labels and accessibility descriptions. Add `TransparencyLocalizationTests` following `NativeFocusStatusMonitorTests`' catalog-validation pattern; it enumerates every new English key and asserts `state == translated`, nonempty value, and `value != key` for all 11 locales. Add `ChineseTransparencyTrustGateTests` to assert renderer parity, opaque preedit/explicit backgrounds, the adjacent-Hanzi Slug regression, and stable two-cell placement at 85%, 90%, and 95%.

### Milestone 4: Finish debug proof, accessibility, performance, and documentation

Add the typed debug actions, `/debug/transparency` projection, and `laban-agent` flags. Register only the new fixed `GET /debug/transparency` route in `Sources/LabanControl/ControlRouteCatalog.swift`; wire the actions through `DebugActionIntentID`, `IntentCatalog.shared`, the aggregate action schema/decoder, GUI server dispatch, `LiveIntentRouter`, and the applicable headless router/runtime paths exactly as specified in `Interfaces and Dependencies`. Add the fixture-token-only `diagnosticControl` authorization boundary, strict image fixture-path containment, and denial tests before exposing any GUI handler. `rtk ./scripts/check-debug-contract` must pass with the endpoint and action examples documented. Update schemas and `docs/process/dev-process.md` with request/response examples, the deterministic transparency/image fixture, authenticated installed-GUI action commands, polling semantics for native full screen, managed-import/override cleanup, and PNG alpha inspection. Keep `HeadlessDebugRuntime` in semantic parity for applicable request/scaling actions: it ignores only native backdrop hosting and native-full-screen actuation, which do not exist headlessly, and reports those resolutions explicitly.

Exercise Reduce Transparency in the installed app with `setReduceTransparencyOverride`; that action must call the same cached-accessibility update/coalesced wake method that the existing `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` observer calls. Keep `/debug/accessibility` read-only. Unit tests invoke the real observer callback with a provider-injected workspace value, while the installed-app smoke proves the downstream window/renderer transition. Exercise repeated native full-screen enter/exit cycles through coordinator tests and `setNativeFullScreen`; that action calls the real AppKit transition and the script polls state to completion. Requested values must survive both overrides, and every test override must be removed in `defer`/trap cleanup so a failed smoke cannot leave the installed app in synthetic accessibility state or full screen.

Add `RendererTransparencyPerformanceTests` and `scripts/benchmark-transparency-renderers`. The benchmark uses the CJK trust-gate at a 160x48 grid and scale 2, warms 40 frames, accepts 240 measured frames, and repeats each process five times for Slug and vector at opaque 1.0 and direct 0.90. It writes one versioned JSON document containing hardware/OS/build identity plus per-run and median-of-five p50/p95/p99 CPU-encode and wall time. Milestone 0 captures the opaque baseline before renderer changes. The script exits nonzero unless post-change opaque p50 and p99 are each no more than 5% above baseline, direct p50 and p99 are each no more than 10% above post-change opaque, and every p99 is at most 8.33 ms. There is no reviewer-exception escape hatch; a threshold change requires an explicit plan/ADR amendment with new evidence.

Add `scripts/check-transparency-source-invariants`. It contains a checked-in exact allowlist for pre-existing `UserDefaults` references under `Sources/LabanRenderer`, fails on any added renderer-side settings read, and reports only deterministic pass/fail output; do not ask a reviewer to compare grep hits with a merge base. Presentation-layer opacity is behavioral, not a source regex: `RendererSurfaceTransparencyTests` constructs every backend, applies nonopaque then opaque state, and asserts each layer-backed backend flips `presentationLayer.isOpaque` false then true before presentation while software invalidates/rebuilds its bitmap state.

Add `scripts/profile-transparency-compositor` for the installed app. It runs opaque and direct 0.90 over identical static and animated high-contrast backdrops, allows a 2-second settling interval, resets transparency/present diagnostics, then records 60 seconds per scenario. Repeat the four-scenario matrix five times and write a versioned JSON summary with top-level identity fields `lane`, `osVersion`, `osBuild`, `osReleaseChannel`, `hardwareModel`, `chipModel`, `memoryBytes`, and `displayHz`, plus app CPU median/p95, WindowServer CPU median/p95, renderer-present delta, accessibility-refresh/effective-apply/wake deltas, present-interval deadline misses, and trace paths. It exits nonzero unless every static run has renderer-present delta 0 and app CPU median below 1.0%; every run has zero display-deadline misses; and direct static WindowServer CPU median is no more than 2.0 percentage points above opaque static. Capture/analyze traces using the repository's `scripts/capture-profile`, `scripts/analyze-metal-trace`, and `docs/process/profiling-hiccups.md` conventions; missing required CPU, deadline, or identity fields is a failure, not an inferred pass.

Extend that profiler and verifier with Frosted static/animated plus Image Fill/Fit/Stretch static scenarios over the same sampling windows and one checked-in high-resolution image fixture. Every native-source static run must remain parked with renderer-present delta 0 and app CPU median below 1.0%, and every sampling run must have zero post-settling image import/decode/file-read/apply/redraw growth. Median WindowServer CPU may be at most 8.0 percentage points above opaque static for Frosted static and at most 15.0 points above opaque animated for Frosted animated. Every individual 60-second Image Fill/Fit/Stretch run must have its own WindowServer CPU median at most 2.0 points above the five-run opaque-static median; one outlier cannot be hidden by an aggregate Image median. The zero-deadline-miss requirements stay unchanged.

Run the compositor gate on the required `stable-base-m1-8gb-60hz` lane: a base Apple M1 with 8 GiB RAM at 60 Hz using the latest stable macOS 26.x build available when the evidence is captured. Before capture, add `fixtures/performance/transparency-stable-base-m1-8gb-60hz.json` with the exact allowed `lane`, `osVersion`, `osBuild`, `osReleaseChannel`, `hardwareModel`, `chipModel`, `memoryBytes`, and `displayHz` values observed on that verified host; record the source/date used to establish that the build is stable in this plan's `Decision Log`. Both profiler and final verifier load that version-controlled lane contract and reject any identity mismatch; changing the pinned OS build or machine requires a Decision Log update and a fresh capture, never an artifact-only edit. If that lane is unavailable, the performance milestone remains incomplete. Native Blur/Image hosting also requires the 120 Hz Apple-silicon macOS 27 lane described in `Active Work: Background Sources and Frosted Preset`; renderer-side 120 Hz timing remains gated by the 8.33 ms p99 budget in the renderer benchmark. Do not weaken the numeric budgets.

Run the full gates, build/install `~/Laban.app` with `./scripts/install-app`, collect the artifacts named below, update this plan's progress and retrospective, and submit the final commit to the Review Gate.

### Milestone 5: Make blur useful while keeping navigation opaque

The first atomic slice is complete at `f05f1bd`: `SidebarProducer` always establishes an opaque replace-composited base, all tab/navigation commands retain their prior semantic strength, and terminal opacity no longer participates in the sidebar memo. Keep this behavior fixed while implementing the remaining slices.

First add `TerminalBackgroundEffectHost` and unit-test its zero-or-one-child lifecycle, terminal-only geometry, appearance changes, Reduce Transparency/full-screen removal, and deallocation. Then expose System Blur through requested/effective settings, the existing coordinator, debug projection/actions, and `laban-agent`; headless must preserve the request while reporting effective `none`. Next add the atomic `Frosted` preset and generated 11-locale strings, including transitions to custom state when an individual control changes. Finally rerun installed-window light/dark, CJK/IME, five-renderer, transition, idle, and compositor evidence with the blur active. Acceptance requires the sidebar to remain opaque in every capture, `backdropSubviewCount` to be exactly 1 only for effective System Blur, and every existing numeric performance/accessibility/full-screen gate to remain unchanged.

### Milestone 6: Import and host background images without renderer changes

First extend the pure requested/effective model with source `image`, Fill/Fit/Stretch, Image availability, and `backgroundImageUnavailable`. Add default/non-auto-selection and policy-matrix tests before AppKit work. Commit this source-model slice independently.

Next add `TerminalBackgroundImageStore` and its temporary-directory tests. Import one picker-selected still image through a private staging path under `PersistenceStore.defaultBaseURL()/background-images/`, validate the managed copy before publishing a generated relative identifier, preserve the previous asset on cancel/failure, and remove only feature-owned files. Prove relaunch, replacement, removal, malformed identifiers, path containment, missing/corrupt recovery, and absence of original absolute paths in defaults/debug output. Commit the storage/picker slice independently.

Then generalize `TerminalBackgroundEffectHost` from a material-only child to a zero-or-one Blur/Image child. Add a cached image view with exact centered Fill crop, centered Fit plus opaque-black letterboxing, and independent-axis Stretch. Transparent source pixels composite over black. The host stays below `TerminalBitmapView`, begins at `SidebarLayout.defaultWidth`, and never enters a renderer. Add portrait/landscape geometry, backing-scale, resize, orientation, mutual-exclusion, first-frame-only animated-input, and deallocation tests. Commit this host slice independently.

Finally expose source, Choose…/Choose Again…/Remove Image, and scaling controls with all generated localizations; add diagnostic projection/actions, strict fixture-path authorization, headless requested/effective resolution, and Frosted/custom transitions. Switching source/scaling/import must preserve terminal session identity and settle after one host update without a periodic renderer wake. Commit controls and diagnostics independently.

### Milestone 7: Close image evidence and performance gates

Install the implementation and capture Fill, Fit, and Stretch screenshots at 90% using the same checked-in high-resolution fixture; each must show complete opaque sidebar coverage and the exact scaling geometry. Capture one installed five-renderer Image/Fill switch sequence without flashes, plus the CJK trust fixture and Apple Pinyin composition/commit/wrap flow over Image/Fill as compatibility evidence. Extend transition smoke through None↔System Blur↔Image, 100%↔90%, missing-image safe fallback/repair, relaunch, Reduce Transparency, and native full screen. Require `backdropSubviewCount == 1` only for effective Blur/Image and `backdropSubviewKind` to identify exactly one.

Extend compositor profiling with static Image Fill/Fit/Stretch scenarios on the same required lanes. Each 60-second static run must have renderer-present delta 0, app CPU median below 1.0%, zero deadline misses, no image import/decode/file-read/apply/redraw growth after settling, and its individual WindowServer CPU median at most 2.0 percentage points above the five-run opaque-static median. Existing direct and Frosted thresholds remain unchanged. This milestone is incomplete until the installed evidence, generated manifest/schema checks, compositor summaries, and fresh Review Gate pass.

## Concrete Steps

Run all commands from `/Users/rrj/wrk/laban`. Follow the repository's machine-local command wrapper rule by prefixing shell commands with `rtk`.

Before editing and before each commit:

```sh
rtk git status --short --branch
```

Expect existing unrelated dirt to remain untouched. At plan creation time it includes `.rpg/graph.json`, `.serena/project.yml`, `.cachebro/`, and `.continues-handoff.md`; re-check rather than assuming that list is permanent.

Milestone 0 focused tests:

```sh
rtk swift test --filter TerminalTransparencyPolicyTests
rtk swift test --filter TerminalTransparencySettingsTests
rtk swift test --filter SnapshotExplicitBackgroundTests
rtk swift test --filter LabandSnapshotSyncOutputRingTests
rtk swift test --filter LabandExplicitBackgroundCapabilityTests
rtk swift test --filter FrameProducerTransparencyTests
rtk ./scripts/benchmark-transparency-renderers --phase=baseline --fixture=fixtures/cjk/trust-gate.fixture.json --warmup=40 --frames=240 --runs=5 --output=.artifacts/transparency/opaque-baseline.json
```

The new test cases should fail before their production changes and pass afterward; `LabandSnapshotSyncOutputRingTests` is an existing suite that only gains new cases, so run it before editing to confirm the baseline is green. A failure showing that an explicit background lacks bit 9, a legacy helper did not force opacity, or unavailable system blur overwrote the requested value is a real contract failure, not a baseline to update. Preserve `opaque-baseline.json` unchanged through closeout; the benchmark command records five independent processes for both Slug and vector and exits 0 only when all required samples were accepted.

Milestone 1 Slug checks:

```sh
rtk swift test --filter SlugGlyphTransparencyTests
rtk swift test --filter RendererTransparencyIdempotenceTests
rtk swift test --filter VectorSubpixelPolicyTests
rtk swift test --filter VectorSubpixelLayoutTests
rtk swift test --filter TerminalWindowTransparencyCoordinatorTests
rtk swift test --filter TerminalTransparencySettingsUITests
rtk ./scripts/build-app
```

Start the debug app with the repository's documented isolated run command from `docs/process/agent-operating-guide.md`; do not invent a parallel socket. Select Slug, set opacity to 70%, and capture both a window screenshot and a renderer PNG under `.artifacts/transparency/windows/m1-slug/`, not in a tracked source directory.

Milestone 2 parity checks:

```sh
rtk swift test --filter RendererTransparencyParityTests
rtk swift test --filter MetalRendererTransparencyTests
rtk swift test --filter VectorGlyphTransparencyTests
rtk swift test --filter SoftwareBackendTransparencyTests
rtk swift test --filter RendererSelectionRoutingTests
rtk swift test --filter RendererTransparencyIdempotenceTests
```

Add `scripts/transparency-renderer-parity-matrix` using the proven readiness/authentication/capture structure in `scripts/vector-glyph-parity-matrix`. For each of `software`, `classic`, `gpuDriven`, `vectorGlyph`, and `slugGlyph`, it must launch the debug-server path with the exact argument forms `--headless --debug-server=127.0.0.1:0 --fixture=... --artifacts=... --renderer=... --deterministic --background-opacity=0.70`; it must not use the one-shot renderer, which currently hard-codes `SoftwareRenderer`. Before accepting `/debug/screenshot?target=active`, the script saves `/debug/render` and fails unless both `configuredRenderer` and `effectiveRenderer` equal the requested selector and `fallbackReason` is null. Run it with:

```sh
rtk ./scripts/transparency-renderer-parity-matrix --fixture=fixtures/transparency-parity.fixture.json --opacity=0.70 --artifacts=.artifacts/transparency/parity
```

The matrix exits 0 only after all five renderer-identity assertions, alpha probes, idempotence captures, and PNG nonemptiness checks pass. It writes one subdirectory per renderer containing `render.json`, `transparency.json`, `frame-commands.json`, and `screenshot.png`.

Milestone 3 CJK and IME compatibility checks:

```sh
rtk swift test --filter CJKFont
rtk swift test --filter ChineseTrustGate
rtk swift test --filter FrameProducerPreedit
rtk swift test --filter ChineseTransparencyTrustGateTests
rtk python3 scripts/gen-localizable-xcstrings.py
rtk python3 scripts/gen-localizable-xcstrings.py --check
rtk swift test --filter TransparencyLocalizationTests
rtk ./scripts/verify-transparency-cjk-evidence --self-test
rtk ./scripts/verify-transparency-cjk-evidence --manifest=.artifacts/transparency/cjk/cjk-evidence.json --spec=docs/product/spec.md
```

Extend the generator with `--check`; it performs no write and exits nonzero if the committed catalog differs from generated output. `TransparencyLocalizationTests` validates every new key across all 11 locales. Capture the five renderer images, the installed native-source trust-gate and state records, the complete Apple Pinyin opaque/System Blur/Image-Fill flows, and an optional equivalent Rime/Squirrel run under `.artifacts/transparency/cjk/`. Write the manifest described above and run its verifier only after those executing-agent manual flows are complete. Preserve the pre-feature focused baseline recorded in `Surprises & Discoveries`: 30 existing CJK/preedit tests pass before the new transparency tests are added.

Milestone 4 and closeout:

```sh
rtk swift test --filter TransparencyHeadlessTests
rtk swift test --filter RendererTransparencyPerformanceTests
rtk swift test --filter TransparencyDiagnosticsTests
rtk swift test --filter RendererSurfaceTransparencyTests
rtk swift test --filter TerminalBackgroundImageStoreTests
rtk swift test --filter TerminalBackgroundImageScalingTests
rtk swift test --filter TerminalBackgroundEffectHostTests
rtk swift test --filter TerminalBackgroundSourceSettingsUITests
rtk swift test --filter BackgroundSourceLocalizationTests
rtk ./scripts/check-transparency-source-invariants
rtk ./scripts/benchmark-transparency-renderers --phase=compare --fixture=fixtures/cjk/trust-gate.fixture.json --warmup=40 --frames=240 --runs=5 --baseline=.artifacts/transparency/opaque-baseline.json --output=.artifacts/transparency/renderer-comparison.json
rtk ./scripts/check
rtk ./scripts/install-app
rtk ./scripts/verify-system-blur-composition --app=$HOME/Laban.app --artifacts=.artifacts/transparency/system-blur-composition
rtk ./scripts/transparency-transition-smoke --app=$HOME/Laban.app --cycles=5 --artifacts=.artifacts/transparency/transitions
rtk ./scripts/profile-transparency-compositor --app=$HOME/Laban.app --lane=stable-base-m1-8gb-60hz --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json --duration=60 --runs=5 --artifacts=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz
rtk ./scripts/profile-transparency-compositor --app=$HOME/Laban.app --lane=macos27-apple-silicon-120hz --lane-contract=fixtures/performance/transparency-macos27-apple-silicon-120hz.json --duration=60 --runs=5 --artifacts=.artifacts/transparency/compositor/macos27-apple-silicon-120hz
rtk ./scripts/verify-transparency-performance --renderer=.artifacts/transparency/renderer-comparison.json --compositor=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json --compositor=.artifacts/transparency/compositor/macos27-apple-silicon-120hz/summary.json --lane-contract=fixtures/performance/transparency-macos27-apple-silicon-120hz.json
```

Every command in this Milestone 4 block must exit 0. Run each compositor command on the machine matching its `--lane-contract`; the profiler detects the host identity, compares every field with the contract, and refuses a mismatch before sampling or creating its artifact directory. Transfer only the resulting artifact directories back into their matching children under `.artifacts/transparency/compositor/`, then run the final verifier over both summaries and both version-controlled contracts. The macOS 27 contract file named above remains absent until the exact 120 Hz Apple-silicon host is observed; create it from that host's exact identity rather than inventing or extrapolating values. If `./scripts/check` is not the current full gate when implementation begins, read `docs/process/agent-operating-guide.md`, replace it here with the canonical command, and record the change in `Decision Log`. `./scripts/build-app` proves only `.build/laban/Laban.app`; `./scripts/install-app` is required to update and validate `~/Laban.app`.

`transparency-transition-smoke` launches the installed app with the repository's environment-gated GUI control server, reads its whole-app fixture token, and uses the diagnostic actions above. It registers shell-trap cleanup before the first mutation; cleanup removes the Reduce Transparency override, exits native full screen if necessary, restores the initial requested settings/source/scaling, and removes only the run-scoped imported fixture. Before each measured operation it resets diagnostics, performs exactly one action, and polls `/debug/transparency` until the expected state settles. A requested-settings change must produce exact `effectiveTransparencyApplyCount`/`transparencyRenderWakeCount`/settled `rendererPresentCount` deltas of 1/1/1; a scaling-only change may redraw the AppKit host once but must not grow renderer presents after settling. A Reduce Transparency override must additionally produce `accessibilityRefreshCount == 1`. Native full-screen transitions may cause AppKit resize/animation presents, so their mechanical contract is instead: the effective force-opaque state changes once, the complete request is preserved/restored, `backdropSubviewCount` settles to 0, and `rendererPresentCount` does not change during a two-second idle window after the transition settles. Run five cycles for None↔System Blur↔Image, missing-image safe fallback/repair, real AppKit full screen, and simulated Reduce Transparency. The smoke also attempts each mutating action with app-observe and session-observe tokens and requires HTTP 403, proving the fixture-only authorization boundary on the installed binary.

For debug-state proof, use the actual loopback/unix-socket command documented by the implementation in `docs/process/dev-process.md`. The transcript must show requested and effective values separately. A representative forced-opaque response is:

```json
{
  "requestedOpacity": 0.7,
  "effectiveOpacity": 1,
  "requestedBackdropStyle": "none",
  "effectiveBackdropStyle": "none",
  "forceOpaqueReason": "reduceTransparency",
  "surfaceOpaque": true,
  "effectiveGlyphAntialiasing": "grayscale"
}
```

The antialiasing field may report the configured mode when the renderer has no RGB-subpixel mode; document that vocabulary in the schema and keep it stable.

## Validation and Acceptance

The feature is accepted only when all of the following are demonstrated, not merely when the code compiles.

### Default regression

- With no new preference keys, all five renderers resolve opacity to 1.0, source None, Fill as the dormant scaling default, no imported image, explicit-cell opacity off, an opaque sidebar, and an opaque presentation surface.
- The same untouched defaults hold under every supported locale, preferred-language list, region, selected input source, and CJK font. No such input selects Image, System Blur, or Frosted.
- Existing opaque screenshot baselines remain pixel-identical outside any intentional metadata-only difference. Do not regenerate baselines merely to hide an alpha or color change.
- Idle renderer telemetry remains parked; no new settings or accessibility observer performs per-frame work or reads `UserDefaults` inside a render loop.

### Alpha semantics

At effective opacity 0.70, a deterministic readback must show, allowing one 8-bit rounding unit:

- default canvas alpha: 179 (`round(255 * 0.70)`);
- default/inherited cell background alpha: 179;
- sidebar base and every navigation card: 255;
- explicit red background alpha with opt-in off: 255;
- inverse cell background alpha with opt-in off: 255;
- explicit and inverse background alpha with opt-in on: 179;
- glyph interior, cursor, selection emphasis, image content, and preedit backing: their existing semantic alpha, not blindly 179;
- pixels outside every initialized region: deterministic transparent/tinted output, never stale texture contents.

These probes must pass for software, classic, GPU-driven, vector, and Slug. Glyph shape pixels may differ among renderers; probe areas chosen by the fixture must not depend on identical font rasterization.

- Full-target reset overwrites the resolved canvas RGBA once (alpha 179 at 70%) and a following replace canvas command leaves the same bytes; partial-damage erases write transparent black before replay.
- Replaying the same full frame 100 times leaves default alpha at 179, not 255.
- Replaying the same partial damage 100 times leaves every damaged default-background pixel at 179 and every undamaged pixel byte-identical.
- A scroll blit preserves source alpha exactly; newly exposed rows are erased to transparent and replayed to alpha 179.
- `NSWindow` and permanent AppKit backing layers contribute no second tint. Full renderer clears are overwrite operations, not blended tints, and a temporary launch fallback is absent before the first renderer frame is presented.

### Live window behavior

- With another high-contrast window behind Laban, Slug at 70% shows that backdrop through the terminal while the sidebar base and every tab selector remain opaque and cohesive; text and semantic overlays remain legible.
- Switching through every renderer leaves the apparent tint and transparency unchanged and does not flash opaque white, black, or a prior frame.
- Changing opacity updates the existing window and session without restart.
- Resizing, live font zoom, tab selection, view reconstruction, cold launch, session restore, and renderer switching keep session identity and never reveal an opaque transient-resize fill.
- With System Blur requested and available, exactly one effect view occupies only the terminal content rectangle and `backdropSubviewCount == 1`; switching to None, opacity 1.0, Reduce Transparency, native full screen, or an unsupported/headless context removes or hides it and reports count 0.
- With Image requested and available, exactly one cached image view occupies only the terminal content rectangle and `backdropSubviewKind == image`; the System Blur child is absent. None/System Blur/Image switches are mutually exclusive and preserve the imported asset until explicit removal.
- Fill performs a centered proportional crop, Fit shows the complete proportional image with opaque-black centered letterbox bands, and Stretch fills both axes independently. Transparent image pixels never reveal unrelated desktop content through the image host.
- Picker cancel, invalid input, or failed replacement leaves the prior request and asset unchanged. A successful managed import survives relaunch without an external absolute path in defaults/debug state. Missing/corrupt managed data forces `backgroundImageUnavailable` and opaque output until repaired or removed.
- At opacity 1.0 the window and renderer layer report opaque with zero added effect cost.

### Accessibility and full screen

- Toggling Reduce Transparency while the app is running immediately makes the window opaque and reports `forceOpaqueReason == reduceTransparency`; toggling it back restores the requested opacity.
- Entering native full screen does the same with `nativeFullscreen`; exiting restores the request. Five consecutive enter/exit cycles produce the same result and do not accumulate notification observers.
- If both overrides apply, the status uses a deterministic priority documented in `TerminalTransparencyPolicyTests`; removing one while the other remains cannot restore transparency.
- `TerminalBitmapView` is the only workspace accessibility observer. After resetting diagnostics, one real observer callback or debug override refresh increments `accessibilityRefreshCount` by 1, `effectiveTransparencyApplyCount` by at most 1, `transparencyRenderWakeCount` by 1, and settled `rendererPresentCount` by 1. Unit tests separately prove that one `NSWorkspace` notification invokes that refresh path exactly once.
- Selecting a remote session whose helper lacks `snapshotCellExplicitBackgroundV1` forces opacity with `legacySnapshotWriter`; selecting an in-process or capability-aware session restores the unchanged request. Old JSON and ABI-1 ring fixtures cannot produce a translucent explicit or inverse background.
- An unavailable Image request is lower priority than the three existing force-opaque reasons. Removing a higher-priority override cannot reveal direct transparency; it restores Image only if available and otherwise remains opaque with `backgroundImageUnavailable`.

### Glyph correctness

- Slug and vector report effective grayscale AA whenever the surface is translucent.
- No colored fringe appears on vertical glyph stems over a high-contrast checkerboard backdrop.
- Returning to an opaque surface restores the user's configured RGB-subpixel mode without changing its persisted setting.

### CJK and IME compatibility

- `fixtures/cjk/trust-gate.fixture.json` passes through software, classic, GPU-driven, vector glyph, and Slug at opaque, 85%, 90%, and 95% direct transparency; mixed Chinese/English, dense Hanzi, ambiguous widths, emoji clusters, Powerline, and box drawing retain their opaque-run cell geometry.
- Fine Hanzi strokes remain distinguishable over light and dark high-contrast backdrops. Slug renders adjacent `中文` without a blank glyph, bad raster stride, overlap, or one-cell shift.
- PingFang SC, Noto Sans Mono CJK SC, Sarasa Term/Mono/Gothic SC, and custom CJK choices continue to refresh live. Optional fonts are visually checked when installed; automated policy tests cover the entire explicit cascade regardless of installation.
- Preedit backing remains opaque, glyphs and caret remain full-strength, and Apple Pinyin marked-text replacement, candidate anchoring, double-width wrapping, ZWJ clusters, and mode 2027 behave exactly as in the opaque path. Rime/Squirrel is either manually passed on the implementation build or explicitly omitted from compatibility claims.
- Every new user-facing string originates in the localization generator and has translated, nonempty, non-English-fallback values for all 11 supported locales. A generator `--check` run proves the committed catalog is current.
- Compatibility fixtures and IME evidence never feed appearance defaults or preset selection; tests mechanically guard this one-way boundary.

### Headless and debug parity

- The typed action changes opacity deterministically in `HeadlessDebugRuntime`; its PNG contains the expected alpha probes for all five renderer selectors. Each artifact's `/debug/render` proves `configuredRenderer` and `effectiveRenderer` equal the requested backend before the PNG is accepted.
- `/debug/transparency` distinguishes requested from effective state and explains forced opacity/unavailable native effects.
- Image state projects source, scaling, availability, subview kind, and cached lifecycle counters without an absolute path. Fixture import rejects paths outside the authorized fixture/control root; non-fixture tokens receive HTTP 403 for every image action.
- Headless preserves requested System Blur/Image and Fill/Fit/Stretch state while reporting effective native source None, zero subviews, and no renderer-specific image path.
- The same fixture and state projection are available in the visible app path; no debug-only frame-production fork implements the semantics.

### Performance and power

- After diagnostics reset, one settings change increments effective-apply, render-wake, and settled renderer-present counts by exactly 1, after which the idle window parks.
- The five-process renderer JSON passes these fixed gates: post-change opaque p50 and p99 no more than 5% above baseline; direct p50 and p99 no more than 10% above post-change opaque; all p99 values at most 8.33 ms.
- No renderer recreates a pipeline, atlas, or font/glyph cache solely because the opacity slider changed. Only the full-frame target/damage state may be invalidated.
- No static image scenario reads or decodes the managed file per frame, advances image lifecycle counters after settling, or creates a timer/display-link wake. Scaling/resize invalidates only the AppKit image host as needed.
- The five-run compositor JSON passes these fixed gates: every 60-second static run has renderer-present delta 0 and app CPU median below 1.0%; every run has zero deadline misses and zero post-settling image lifecycle growth; direct static is at most 2.0 percentage points above opaque static; every individual Image Fill/Fit/Stretch run is at most 2.0 points above the five-run opaque-static median; Frosted static is at most 8.0 points above opaque static; and Frosted animated is at most 15.0 points above opaque animated.
- The required hardware/OS lane passes: base M1-class 8 GB/60 Hz (or an older supported Apple-silicon machine) on the latest stable macOS 26.x. Missing metrics or a missing lane is not a pass.

### Repository closeout

- Focused tests and the full current gate pass on implementation head `589b8ca`: 448 parallel-safe tests and 2,194 sequential tests with 16 expected skips and zero failures, plus sanitizer, runtime smoke, E2E, and 46.29% labpty MC/DC coverage against the 45% floor.
- `./scripts/install-app` installs profilable release `589b8ca` at `/Users/rrj/Laban.app`, and `.artifacts/transparency/transitions-589b8ca` passes the five-cycle installed-app None/System Blur/Image, scaling, missing-image, relaunch, Reduce Transparency, and native-full-screen smoke.
- The Review Gate remains not passed until a stable passing final balanced renderer artifact meets every fixed threshold, the source-specific CJK/Apple Pinyin evidence verifier passes, both exact compositor lane artifacts exist and pass, and the observed macOS 27/120-Hz host is pinned in its lane contract. Repository, implementation-review, and install success do not waive those evidence requirements.
- `docs/product/spec.md`, ADR 0028, schemas, and `docs/process/dev-process.md` describe the final behavior and actual commands.
- Generated screenshots, traces, and PNGs stay in documented artifact directories and are not accidentally committed.
- Unrelated pre-existing worktree changes remain untouched.

## Review Gate

A separate fresh-state agent must verify every item against the final implementation commit. The executing agent must not mark this ExecPlan complete until the gate passes. On a failure, record file-and-line findings here, fix them, and have another fresh reviewer rerun the entire gate. Stop and surface to a human after three failures of the same item, as required by `PLANS.md`.

- [ ] Run every command in the `Milestone 4 and closeout` code block under `Concrete Steps` except the two `profile-transparency-compositor --lane=...` commands; expect exit 0 from each and preserve every referenced JSON/artifact directory. The lane-pinned compositor runs are the executing agent's responsibility on machines matching each lane (the script refuses a mismatched host); this gate verifies both recorded artifacts in the performance-evidence item below.
- [x] Run `rtk swift test --filter RendererSurfaceTransparencyTests`; expect every layer-backed backend to report `presentationLayer.isOpaque == false` after applying nonopaque state and `true` after restoring opaque state before presentation, plus software bitmap invalidation/rebuild assertions. Run `rtk ./scripts/check-transparency-source-invariants`; expect exit 0. The script's checked-in allowlist is the sole authority for pre-existing renderer-side `UserDefaults` references and fails on any added settings read; the reviewer does not interpret source hits.
- [x] Run `rtk swift test --filter RendererTransparencyParityTests` and `rtk swift test --filter RendererTransparencyIdempotenceTests`; expect alpha 179/255 assertions plus 100x full, 100x partial, and scroll-blit stability to pass for all five renderers.
- [x] Run `rtk rg -l 'FrameCompositingMode' Sources/LabanRenderer`; expect the file list to include `SoftwareRenderer.swift`, `MetalRenderer.swift`, `VectorGlyphRenderer.swift`, and `SlugGlyphRenderer.swift`. Run `rtk rg -n 'CGBlendMode\.copy' Sources/LabanRenderer/SoftwareRenderer.swift`; expect at least one hit. `SoftwareBackend` owns full-bitmap reset/invalidation, while `SoftwareRenderer` owns per-command blend selection. The reset/replace behavior itself is proven by the `RendererTransparencyIdempotenceTests` run above, not by code inspection.
- [x] Run `rtk swift test --filter TerminalTransparencyPolicyTests`; expect cases for Reduce Transparency, native full screen, both overrides, opacity 1, unavailable/headless system blur, `legacySnapshotWriter`, and restoration to pass.
- [x] Run `rtk swift test --filter SnapshotExplicitBackgroundTests` and `rtk swift test --filter LabandExplicitBackgroundCapabilityTests`; expect default, explicit, theme-equal explicit, inverse, old/new JSON, old/new ring, hello capability, and forced-opaque downgrade cases to pass.
- [x] Run `rtk rg -l 'backgroundCompositingOptions' Sources/LabanCore Sources/LabanApp Sources/LabanDebug`; expect the file list to include `Sources/LabanCore/TerminalSurfaceController.swift` and `Sources/LabanDebug/HeadlessDebugRuntime.swift`. Run `rtk bash -c '! rg -q backgroundCompositingOptions Sources/LabanCore/SidebarProducer.swift && ! rg -A8 "struct SidebarCacheSignature" Sources/LabanCore/TerminalSurfaceController.swift | rg -q ompositing'`; expect exit 0. Run `rtk swift test --filter FrameProducerTransparencyTests`, `rtk swift test --filter TransparencyHeadlessTests`, and `rtk swift test --filter ChineseTransparencyTrustGateTests`; expect local, remote, current-renderer, warm-swap, headless, and five-renderer CJK frames to carry requested terminal alpha while every replace-composited sidebar base remains alpha 255 and terminal-only changes reuse the sidebar memo.
- [x] Run `rtk swift test --filter TerminalBackgroundEffectHostTests`, `rtk swift test --filter TerminalBackgroundImageStoreTests`, `rtk swift test --filter TerminalBackgroundImageScalingTests`, `rtk swift test --filter FrostedPresetTests`, `rtk swift test --filter TerminalBackgroundSourceSettingsUITests`, and `rtk swift test --filter BackgroundSourceLocalizationTests`; expect zero-or-one mutually exclusive terminal-only Blur/Image children, opaque-sidebar geometry, exact Fill/Fit/Stretch math/backing, atomic contained managed imports, safe missing/corrupt fallback, exact defaults under locale/input variations, and Frosted 0.30/System Blur/opaque explicit cells while preserving the managed image and changing individual controls to custom state. The installed transition smoke passes None↔Blur↔Image with `backdropSubviewCount == 1` and matching kind only while Blur/Image is effective and 0 otherwise.
- [x] Run `rtk swift test --filter VectorSubpixelPolicyTests`; expect passing cases where a translucent surface resolves to grayscale with the machine-readable reason `transparentSurface`, and where returning to opacity 1 restores the configured mode without changing its persisted setting. Run `rtk rg -n 'transparentSurface' Sources`; expect at least one production hit in the AA resolver or debug projection.
- [x] Run `rtk ./scripts/transparency-renderer-parity-matrix --fixture=fixtures/transparency-parity.fixture.json --opacity=0.70 --artifacts=.artifacts/transparency/review-parity`; expect exit 0, five backend-identity assertions, five nonempty PNGs, and alpha/idempotence probes.
- [x] Run `rtk swift test --filter CJKFont`, `ChineseTrustGate`, `FrameProducerPreedit`, and `ChineseTransparencyTrustGateTests`; expect all to pass, including adjacent `中文`, two-cell geometry, opaque preedit, and all five renderer selectors.
- [x] Run `rtk python3 scripts/gen-localizable-xcstrings.py --check` and `rtk swift test --filter TransparencyLocalizationTests`; expect exit 0 and all new keys translated across all 11 locales.
- [ ] Run `rtk ./scripts/verify-transparency-cjk-evidence --self-test`, then `rtk ./scripts/verify-transparency-cjk-evidence --manifest=.artifacts/transparency/cjk/cjk-evidence.json --spec=docs/product/spec.md`; expect both to exit 0. The verifier requires version-2 installed-build provenance; real, hashed PNGs for all five renderer keys; raw state plus light/dark System Blur and high-contrast Image/Fill trust-gate evidence; and complete Apple Pinyin candidate/commit/wrap/mode-2027 PNGs for opaque, System Blur, and Image/Fill. It accepts Rime/Squirrel only with nonempty source-specific artifacts and `compatibilityClaimed: true`; otherwise it requires `notTested`, an empty source-artifact object, `compatibilityClaimed: false`, and the exact product-spec status `not tested - compatibility unclaimed`. Performing the live flows and capturing evidence remains the executing agent's responsibility, not this gate's.
- [x] Run `rtk ./scripts/transparency-transition-smoke --app=$HOME/Laban.app --cycles=5 --artifacts=.artifacts/transparency/transitions-589b8ca`; expect exit 0, exactly one terminal-only backdrop subview with matching `systemBlur` or `image` kind while that source is effective and zero for None, opacity 1, accessibility/full-screen overrides, and unavailable-image fallback; exact requested-setting restoration; exact bounded apply/wake/present deltas; and zero renderer-present growth during each two-second post-full-screen idle window.
- [x] Run `rtk ./scripts/verify-system-blur-composition --self-test`, then run `rtk ./scripts/verify-system-blur-composition --app=$HOME/Laban.app --artifacts=.artifacts/transparency/system-blur-composition-e2cf5b3-run2`; expect both to exit 0. The installed oracle must use a complete-main-display `SCContentFilter(display:excludingWindows:)`, report exact 0.30 None/System Blur state, preserve source correlation through blur, reduce known stripe-edge energy relative to direct transparency, restore the typed preference subset exactly, and leave no fixture process alive. Window-only or app-screenshot evidence cannot satisfy this item.
- [ ] Run `rtk ./scripts/verify-transparency-performance --renderer=.artifacts/transparency/renderer-comparison.json --compositor=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json --compositor=.artifacts/transparency/compositor/macos27-apple-silicon-120hz/summary.json --lane-contract=fixtures/performance/transparency-macos27-apple-silicon-120hz.json`; expect exit 0. The verifier is the sole gate authority for the 5% opaque, 10% translucent, and 8.33 ms renderer thresholds; every fixed CPU, present, deadline, direct/Blur/Image WindowServer threshold; zero post-settling image import/decode/file-read/apply/redraw growth; and exact equality of all required summary identity fields plus the contract SHA with each version-controlled lane contract. It requires every individual Image 60-second run—not merely each scaling mode's aggregate median—to remain within 2.0 WindowServer CPU points of the opaque-static median on both exact lanes. The required lanes are `stable-base-m1-8gb-60hz` (stable macOS 26.x, base Apple M1, 8 GiB, 60 Hz) and `macos27-apple-silicon-120hz` (macOS 27.x, explicitly identified Apple-silicon Mac, 120 Hz), with exact build/channel/model/memory values pinned only after observing a verified host. A missing lane, Fill/Fit/Stretch scenario, artifact, contract field, summary field, or verifier failure fails this item; do not substitute grep or manual arithmetic.
- [x] Run `rtk git diff --check` and `rtk git status --short`; expect no whitespace errors, no generated artifacts, and only feature/plan files intentionally included in the final commits.

Plan-review status: findings from the 2026-07-14 second independent review are addressed; the first and second fresh implementation reviews below did not pass and require another full fresh-state rerun after correction/evidence completion.

Implementation Review Gate status: **NOT PASSED** — first fresh review completed at 2026-07-15T10:33:09Z against final implementation commit `111066d1de43e33753f1c3bde749088cabbca9c4` (merge base `3599f60fbe8a4c3a20095ba096efabd50798999e`).

First-review results and findings:

- No runtime implementation defect was confirmed by the complete diff review, focused renderer/policy/headless/CJK/localization suites, five-backend parity matrix, installed-app transition smoke, or installed-bundle verification. `/Users/rrj/Laban.app` was installed from `111066d`, passed deep strict code-sign verification, and reported that commit in `LABANBuildCommit`.
- Item 1 is not passed. The focused tests, source invariants, five-process renderer comparison, install, and five-cycle installed-app smoke passed, but `rtk ./scripts/check` exited 1 at `Tests/LabanTerminalCoreTests/LabanSessionTests.swift:3245`: `XCTAssertEqual failed: Optional("") != Optional("\u{1B}[?4;7R") - DECXCPR must reply CSI ? row ; col R`. The same isolated failure was reproduced at merge base `3599f60fbe8a4c3a20095ba096efabd50798999e`, so it is not attributed to this feature, but the literal gate still fails. The exact closeout performance command `rtk ./scripts/verify-transparency-performance --renderer=.artifacts/transparency/renderer-comparison.json --compositor=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json` also exited 1 because the compositor summary is missing.
- Item 6 is not passed as an evidence-coverage finding. Both named commands exit 0, but `Tests/LabanCoreTests/SnapshotExplicitBackgroundTests.swift:11-53` covers local identity, one JSON round trip, and glyph-attribute exclusion, while `Tests/LabandTests/LabandExplicitBackgroundCapabilityTests.swift:5-45` covers hello/lifecycle classification. They do not execute the ABI-1 ring case at `Tests/LabanCoreTests/LabandSnapshotSyncOutputRingTests.swift:61-94`, nor do the two selected suites establish all claimed old/new JSON, old/new ring, and forced-opaque downgrade cases.
- Item 7 is not passed. The exact command `rtk rg -A8 'struct SidebarCacheSignature' Sources/LabanCore/TerminalSurfaceController.swift | rg -c 'ompositing'` exits 1: the declaration starts at `Sources/LabanCore/TerminalSurfaceController.swift:337`, but the real `backgroundCompositingOptions` field is at line 353 and its signature construction is at line 914, outside the eight-line search window. In addition, `rtk swift test --filter FrameProducerTransparencyTests` exits 0, but `Tests/LabanCoreTests/FrameProducerTransparencyTests.swift:13-106` contains five command-semantics tests and no first settings-change/swap-frame or sidebar memo-rebuild assertion, so the named suite cannot prove the gate's stated request-seam coverage.
- Item 12 is not passed. The exact command `rtk ./scripts/verify-transparency-cjk-evidence --manifest=.artifacts/transparency/cjk/cjk-evidence.json --spec=docs/product/spec.md` exits 1 with `verify-transparency-cjk-evidence: manifest is missing: /Users/rrj/wrk/laban/.artifacts/transparency/cjk/cjk-evidence.json`. Five renderer CJK PNGs exist, but the required manifest and Apple Pinyin evidence do not.
- Item 14 is not passed. The exact command `rtk ./scripts/verify-transparency-performance --renderer=.artifacts/transparency/renderer-comparison.json --compositor=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json` exits 1 with `verify-transparency-performance: compositor summary is missing: .artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json`. The review host is a 16 GiB Apple M1, while the contract requires exactly 8 GiB; that expected mismatch is not a waiver for the missing lane artifact.
- Items 2-5, 8-11, 13, and 15 passed exactly. Item 9 produced five nonempty renderer PNGs and matching configured/effective renderer identities. Item 13 passed all five installed-app cycles with the required requested/effective restoration, counter deltas, idle-present behavior, and zero backdrop subviews. Before this plan-only review edit, item 15 reported only the unrelated pre-existing untracked `.continues-handoff.md`, which was preserved untouched.

Second Implementation Review Gate status: **NOT PASSED** — second fresh review completed at 2026-07-15T10:59:00Z against final implementation commit `ef1b4505cf494ae08887849dd81e775c4fa07879` (merge base `3599f60fbe8a4c3a20095ba096efabd50798999e`).

Second-review results and findings:

- No implementation defect was found in the complete `0aad26b4cde6826bcb0a06c80709ccf8c098397a` and `ef1b4505cf494ae08887849dd81e775c4fa07879` fix diffs. Items 6 and 7 now pass exactly. Item 6's selected suites execute local/default/explicit/theme-equal/inverse identity, old/new JSON, old/new ABI-1 ring, old/new hello classification, forced-opaque downgrade, and request-restoration cases. Item 7's literal eight-line cache grep returns `1`, and the selected `FrameProducerTransparencyTests` filter executes nine tests across `LabanCoreTests` and `LabanAppTests`, including first local/remote settings-change frames, first current-renderer and warm-swap frames, and sidebar memo invalidation/reuse.
- Item 1 is not passed. The first exact invocation of `rtk ./scripts/benchmark-transparency-renderers --phase=compare --fixture=fixtures/cjk/trust-gate.fixture.json --warmup=40 --frames=240 --runs=5 --baseline=.artifacts/transparency/opaque-baseline.json --output=.artifacts/transparency/renderer-comparison.json` accepted all 4,800 samples but exited 1: vector direct-versus-post-change-opaque exceeded the 10% limit at CPU p50 (`1.211834` versus `0.957209 ms`), CPU p99 (`1.672667` versus `1.421667 ms`), and wall p99 (`2.230125` versus `1.557292 ms`). An unchanged immediate repeat exited 0, so the first-run gate failure remains recorded rather than hidden by the passing replacement artifact at `.artifacts/transparency/renderer-comparison.json`. `rtk ./scripts/check` also exited 1 at `Tests/LabanTerminalCoreTests/LabanSessionTests.swift:3245`: `Optional("")` did not equal `Optional("\u{1B}[?4;7R")`. The merge-base reproduction from the first review remains recorded above and is not treated as a waiver. Finally, the block's exact `rtk ./scripts/verify-transparency-performance --renderer=.artifacts/transparency/renderer-comparison.json --compositor=.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json --lane-contract=fixtures/performance/transparency-stable-base-m1-8gb-60hz.json` exited 1 because `.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json` is missing. The four focused tests, source-invariant check, app install, and five-cycle transition smoke in the same block passed.
- Item 12 is not passed. `rtk ./scripts/verify-transparency-cjk-evidence --manifest=.artifacts/transparency/cjk/cjk-evidence.json --spec=docs/product/spec.md` exited 1 because `.artifacts/transparency/cjk/cjk-evidence.json` is missing. The Computer Use blocker was independently reconfirmed during this review: app enumeration returned, but `get_app_state` did not return for either Finder or `/Users/rrj/Laban.app`, and a harmless Finder `press_key` action for `Escape` also did not return after a fresh Computer Use kernel reset. No Apple Pinyin evidence or compatibility claim is fabricated.
- Item 14 is not passed. The exact performance-verifier command above exits 1 because `.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json` is missing. The actual review host is macOS 26.5.1 build 25F80, Macmini9,1, base Apple M1, 17,179,869,184 bytes, and 60 Hz; `fixtures/performance/transparency-stable-base-m1-8gb-60hz.json` requires 8,589,934,592 bytes. This 16-GiB host therefore cannot produce the pinned 8-GiB lane summary, and the mismatch is not treated as a pass.
- Items 2-11, 13, and 15 passed exactly on the second rerun. Item 9 again produced five nonempty renderer PNGs with matching configured/effective identities and null fallback reasons. Item 13 again passed all five installed-app cycles. Before this plan-only review edit, item 15 reported only the preserved unrelated untracked `.continues-handoff.md`.

Third Implementation Review Gate status: **NOT PASSED** — third fresh Sol review completed at 2026-07-15T12:55:11Z against reviewed commit `664af8d7d360134e924812522600407539601138` (merge base `3599f60fbe8a4c3a20095ba096efabd50798999e`).

Third-review results and findings:

- The reviewer found no runtime correctness, security, renderer, API, debug-authorization, snapshot compatibility, capture/replay, or atlas defect in the final implementation. Items 2-11, 13, and 15 pass. The repository-wide gate, authenticated five-renderer parity, focused CJK/preedit/localization suites, installed-app transition smoke, snapshot old/new compatibility coverage, replacement-compositing replay, route authorization, and 48-MiB atlas budget all have passing mechanical evidence.
- Item 1 is not passed. `.artifacts/transparency/renderer-comparison-final-head.json` accepted all 4,800/4,800 samples under the exact balanced schedule but vector opaque wall p99 is `2.491208 ms`, above the immutable `2.128219 ms` threshold. The artifact is stamped with renderer commit `0e58f34`; the later reviewed commits `ca734ca`, `a8e0644`, and `664af8d` are capture/replay, route-catalog, and plan-only changes, so they do not invalidate that renderer measurement. The final performance verifier also cannot pass without the compositor summary. No retry, reroll, threshold change, or substitution of the older passing artifact is accepted as evidence.
- Item 12 is not passed. `.artifacts/transparency/cjk/cjk-evidence.json` and the required Apple Pinyin evidence are absent because the Computer Use state/action bridge does not return. The review caught the false `passed` value in `docs/product/spec.md`; the implementation response changes it to the verifier's exact honest status, `not tested - compatibility unclaimed`. The verifier must continue to fail on the missing manifest until real evidence exists.
- Item 14 is not passed. `.artifacts/transparency/compositor/stable-base-m1-8gb-60hz/summary.json` is absent because this Macmini9,1/base-M1/60-Hz host has 16 GiB rather than the lane contract's exact 8 GiB. The missing summary and hardware mismatch are not waivable.
- This is the third bounded failure of the same acceptance items. Per `PLANS.md`, implementation/review work stops here for human coordination or new external evidence; do not launch a fourth review, reroll performance until green, fabricate UI evidence, substitute the 16-GiB host, or weaken any threshold. Overall Review Gate status remains **NOT PASSED**.

Expanded-scope implementation review status: **APPROVED** — final fresh Sol review completed on 2026-07-15 against implementation commit `589b8ca770d3266eb2dc1b17b0159ed8a924c45b`.

- Sol found no implementation defects and approved `589b8ca`. The review mechanically exercised real stubborn-descendant process groups after both live and already-exited wrappers, bounded SIGTERM-to-SIGKILL escalation, direct-child reap, non-group cleanup paths, deferred SIGHUP/SIGINT/SIGTERM delivery, exact preference and managed-image restoration, app/capture process ownership, adversarial per-run Image CPU and lifecycle-counter failures, `corrupt` wire vocabulary, GUI intent parity, all four feature verifier self-tests, and the debug-contract/diff checks.
- This is an implementation-only approval of the expanded System Blur/Image/Frosted work. It does not rerun or supersede the third bounded Review Gate, promote a failed renderer artifact, fabricate CJK evidence, or waive lane identity. Items 1, 12, and 14 remain open because the stable passing final renderer artifact, source-specific CJK version-2 manifest, both compositor summaries, and the observed macOS 27/120-Hz lane contract are absent.

## Idempotence and Recovery

All settings are additive and default to the current opaque behavior, so old preference domains and clean installs are safe. Clamp malformed opacity values on read and write; malformed/missing image scaling resolves to Fill. If System Blur is unavailable or the process is headless, retain it as requested but resolve effective source to None. Headless treats Image the same way while projecting `headlessUnsupported`. A visible missing/corrupt managed Image instead remains opaque with `backgroundImageUnavailable`; it never degrades to direct transparency. If the active remote helper lacks `snapshotCellExplicitBackgroundV1`, preserve the request but force opacity until a capability-aware session is active; never reinterpret legacy cell colors heuristically.

Managed image replacement is retry-safe: validate and copy to a generated staging asset, move it into the contained feature directory, publish the new identifier/configuration, then retire the previous managed file. Cancel or any failure before publication leaves the old state intact. On launch, reject identifiers that escape the managed directory. `None`/System Blur do not delete an imported image; only explicit removal or successful replacement retires a feature-owned asset. Orphan staging files may be removed on the next image-store initialization without touching unrelated Application Support content.

Renderer and window-state changes must be safe to repeat. Store notification tokens and unregister them exactly once. Applying an equal effective state must be a no-op so repeated accessibility/full-screen notifications cannot trigger redraw storms. Background rendering is idempotent by construction: a non-blended full reset or transparent partial erase followed by `replace` yields the same premultiplied bytes no matter how often a region is replayed. Permanent AppKit surfaces remain clear, so renderer output is never tinted twice.

If a renderer fails during the rollout, keep opacity 1.0 as that renderer's temporary safe behavior only on the implementation branch; do not ship or mark the milestone complete with a renderer-specific semantic gap. Slug-first commits may be merged only if the user-visible setting remains gated to Slug or hidden until Milestone 2; the preferred route is to keep milestone commits on one feature branch and expose settings only when parity lands.

If a Metal readback shows stale or accumulating alpha, first confirm the damaged region was erased to transparent and the background instance used the replace pipeline; a forced full redraw is a diagnostic, not an acceptable fix for repeated partial-frame accumulation. If AppKit produces a launch flash, ensure the clear window background, temporary fallback layer, terminal view, and backend `isOpaque` state are all configured before `makeKeyAndOrderFront`, and remove the fallback before renderer presentation; do not hide the problem with a delay or permanent tint.

Tests and artifact generation are repeatable. The localization catalog is regenerated from its Python source tables and `--check` is read-only. Benchmark comparison always reuses the immutable Milestone 0 baseline JSON. Delete only feature-created files under `.build/` or `.artifacts/transparency/` when retrying. Never clean or reset unrelated user changes, and never use `git reset --hard` or `git checkout --` as recovery.

## Artifacts and Notes

Keep these artifacts for final review under the exact ignored root `.artifacts/transparency/`, as permitted by `docs/process/dev-process.md`:

- `transitions/transparency-requested.json`, `transitions/transparency-reduce-transparency.json`, `transitions/transparency-fullscreen.json`, `transitions/transparency-restored.json`, and source/image requested/effective/counter snapshots proving exact accessibility-refresh, apply, wake, settled-present, backdrop-kind, and image-lifecycle deltas;
- `parity/{software,classic,gpuDriven,vectorGlyph,slugGlyph}/` containing `render.json`, `transparency.json`, `frame-commands.json`, and `screenshot.png` with alpha preserved;
- `windows/` containing labeled visible-window screenshots for opaque and 90% direct/System Blur in both a light and dark theme, plus 90% Image Fill/Fit/Stretch captures using the checked-in image fixture and an installed five-renderer Image/Fill sequence;
- `cjk/cjk-evidence.json` at schema version 2; the five exact renderer PNGs; hashed `cjk/transparency-cjk-{systemBlur,imageFill}-state.json` debug responses; light/dark System Blur and high-contrast Image/Fill trust-gate PNGs; exact opaque/System-Blur/Image-Fill Apple Pinyin candidate, commit, wrap, and mode-2027 PNGs; and—only when all three source flows were actually exercised—source-labeled `cjk/transparency-cjk-ime-rime-squirrel.*` PNGs;
- immutable `opaque-baseline.json` plus `renderer-comparison.json`, each containing five-run p50/p95/p99 data, renderer, scale, AA mode, CJK font, thresholds, and OS/build/hardware identity;
- `compositor/{stable-base-m1-8gb-60hz,macos27-apple-silicon-120hz}/summary.json` and their trace paths for five 60-second runs of each opaque/direct/Frosted scenario and Image Fill/Fit/Stretch static scenario on both required hardware/OS lanes, reporting app, WindowServer, renderer-present, deadline, and every image lifecycle counter separately;
- `system-blur-composition/summary.json`, direct/System-Blur full-display PNGs, and token-free state snapshots proving source correlation plus reduced stripe-edge energy through the real AppKit material;
- `idle/telemetry.json` showing a one-time wake followed by the parked state.

Milestone 0 baseline evidence was captured from the clean detached worktree at
commit `0779195be3c2c75b2ffe51fe5fb7f4ac8b0026aa` and copied to
`.artifacts/transparency/opaque-baseline.json` (SHA-256
`3962153a80a40b9a05633903ab93566d91dcd29617fead06d5d7517087fea121`). The
release executable hash is
`c9f796f2d519b461c152737e09107a3b261565d530eb7461b78c824cc742b348` on
macOS 26.5.1 build 25F80, Macmini9,1 / Apple M1 / 16 GiB, Swift 6.3.3. All
4,800 measured samples were accepted. Median-of-five timings were Slug CPU
p50/p95/p99 `0.931/1.105/1.494 ms`, Slug wall `1.040/1.530/1.679 ms`, vector
CPU `1.235/1.549/1.846 ms`, and vector wall `1.270/1.669/2.027 ms`.

The non-rerolled final implementation comparison is
`.artifacts/transparency/renderer-comparison-final-head.json`. It accepted all
4,800 scheduled samples and passed every CPU, direct-opacity, and 8.33-ms gate,
but failed vector opaque wall p99 at `2.491208 ms` against the fixed
`2.128219 ms` limit. After the host-scheduling diagnosis, exactly one unchanged
acceptance run produced
`.artifacts/transparency/renderer-comparison-post-diagnosis.json` (SHA-256
`d587ea29c5f199e17bdbfa9248c157ee59db63d5b7f62b87ab0d66a8763643c4`). It
records head `4ab9b68`, benchmark binary SHA-256
`c646f3a3bee0f530bdcf5e37edfd520f01eb1c70fbd2c7b684d8cfb15e740529`, 20
unique processes, and 4,800/4,800 accepted scheduled frames, but fails vector
direct wall p99 at `1.987666 ms` against `1.858542 ms`; it was not retried or
promoted. The older passing `.artifacts/transparency/renderer-comparison.json`
remains byte-for-byte preserved at SHA-256
`6312f78d681f61156110c2e4fa89b03d728540a54909a470a406e7225ec86e00` and is
not represented as final-head evidence. Installed-app transition evidence from
implementation release `589b8ca` is under
`.artifacts/transparency/transitions-589b8ca`. Human-operated Apple Pinyin
screenshots exist, but the complete source-specific version-2 manifest does not;
the exact compositor profiler invocation rejected this host on `memoryBytes`
before producing an 8-GiB-lane summary, and no macOS 27/120-Hz lane is available.
Those required acceptance artifacts remain absent.

When implementation reveals a non-obvious compositing, AppKit, shader, or WindowServer behavior, add a short `Surprises & Discoveries` entry with the smallest evidence excerpt that proves it. At the end of each milestone, update `Progress` and add an `Outcomes & Retrospective` entry if the result or remaining risk differs materially from this plan.
