# Reduce Trace-Visible Metadata Polling

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Recent Instruments CPU Counters traces of Laban while idle show recurring
filesystem, sandbox, and process-introspection work on frame and detector
ticks. A user should be able to leave the terminal idle without Laban repeatedly
opening Claude session-log directories, recomputing home-directory titles, or
setting the same window title each rendered frame. This work keeps the same
agent-resume and tab-title behavior, but coalesces repeated work so the trace
shows fewer APFS and sandbox samples.

## Progress

- [x] (2026-05-19) Created this focused trace-performance ExecPlan.
- [x] (2026-05-19) Inspected the hot source paths and nearby tests.
- [x] (2026-05-19) Throttled the detector tick that drives the `proc_listpids` child scan.
- [x] (2026-05-19) Cached repeated Claude session-log discovery on detector ticks.
- [x] (2026-05-19) Replaced UUID validation that walks Swift `Character` values with a byte-level check.
- [x] (2026-05-19) Avoided repeated home-directory standardization and unchanged window-title writes.
- [x] (2026-05-19) Audited `os_log` / `Logger` call sites and found no Laban per-frame logger matching the sampled trace path.
- [x] (2026-05-19) Added focused tests for the behavior affected by the optimizations.
- [x] (2026-05-19) Ran targeted validation and the full package test suite.
- [x] (2026-05-19) Reviewed the fresh profile trace at
  `/Users/dev/Downloads/Untitled4.trace` from the profile build.
- [x] (2026-05-19) Increased the Claude session-log lookup cache from 2 seconds
  to 5 seconds after the follow-up trace still showed the detector/log-locator
  cluster.
- [x] (2026-05-19) Recorded the new dominant render-path process-metadata work
  in `execplans/active/terminal-surface-syncsessions-idle-perf.md` rather than
  expanding this detector-focused plan.

## Decision Log

- Decision: Treat `FrameProducer.commands(...)` string-allocation work as out of
  scope for this pass unless a very small safe change appears while editing.
  Rationale: The trace also implicates renderer allocation, but that code is a
  higher-risk rendering surface. The user specifically highlighted per-frame
  filesystem/APFS/sandbox work, and the smallest high-leverage patch is to
  coalesce metadata polling first.
  Date/Author: 2026-05-19 / Codex

- Decision: Keep `TabTitleResolver.cwdDisplayName(_:)` as a collateral change,
  not a headline optimization.
  Rationale: In the newer trace it is a small accumulated cost compared with
  process scanning and Claude session-log directory enumeration. Caching it is
  cheap because nearby title code is already being touched, but success for this
  plan depends mainly on reducing detector polling and filesystem scans.
  Date/Author: 2026-05-19 / Codex

- Decision: Force one-shot observations to bypass the Claude session-log lookup
  cache.
  Rationale: Timed detector ticks should coalesce idle filesystem polling, but
  quit/debug persistence flushes are explicit "sample now" operations. A full
  test run caught a case where a cached miss hid a freshly created Claude log
  from `persistenceFlush()`, so `observeNow()` and
  `observeNowPreservingLiveAgentOnMiss()` clear the cache before sampling.
  Date/Author: 2026-05-19 / Codex

- Decision: Do not add a forced `observeNow()` to the tab-close teardown hook.
  Rationale: `AppModel.closeTab` removes the tab from the workspace before
  `onTabClosed` fires, and closed tabs are not persisted for restore. Quit is the
  path that must preserve running agent metadata, and it already calls
  `observeNowAll()` before flushing persistence. A late detector update after tab
  close is ignored so it cannot recreate private agent metadata for a missing
  tab.
  Date/Author: 2026-05-19 / Codex

- Decision: Increase the Claude session-log lookup cache interval to 5 seconds.
  Rationale: The first pass matched the cache interval to the 2 second detector
  cadence to preserve responsiveness. The follow-up 20 second profile trace
  still showed `AgentSessionDetector` / `ClaudeSessionLogLocator` samples, so the
  cache now spans multiple idle detector ticks. Explicit `observeNow` paths still
  clear the cache before persistence flushes.
  Date/Author: 2026-05-19 / Codex

## Surprises & Discoveries

- Observation: The source audit found Laban `AppLog` calls, including an input
  latency summary in `TerminalBitmapView`, but the sampled `_os_log_impl...`
  stacks from the trace were AppKit update-cycle signposts rather than a Laban
  per-frame logger. No logging call was removed in this pass.
  Evidence: `rtk rg -n "AppLog\\.|Logger\\(|os_log|OSLog|signpost|_os_log" Sources`
  showed Laban call sites; the earlier trace stack inspection attributed the
  sampled `os_log` work to Apple `UpdateCycle`/AppKit frames.

- Observation: The first full test run failed
  `LabanDebugSmokeTests.testPersistenceFlushRecordsRecentClaudeLogWithoutLiveChild`
  because the new detector cache correctly coalesced a previous miss, but a
  forced persistence flush must see files created after that miss.
  Evidence: The failure was `XCTUnwrap failed: expected non-nil value of type
  "AgentInfo"` at `Tests/LabanDebugTests/LabanDebugSmokeTests.swift:240`; after
  clearing the lookup cache in forced observations, that smoke test and the full
  suite passed.

- Observation: The fresh profile trace removed the previous APFS/sandbox cluster
  as a headline cost, but exposed render-path process metadata as the next
  dominant fixable source of libproc work.
  Evidence: `xcrun xctrace export --input ~/Downloads/Untitled4.trace --xpath
  '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` shows
  `TerminalBitmapView.advanceFrame()` →
  `TerminalSurfaceController.syncSessions(...)` →
  `TabMetadataSynchronizer.syncSurfaceMetadata(...)` →
  `Session.processMetadata()` → `laban_session_process_metadata` →
  `proc_pidpath` / `__proc_info`. The source throttle is currently 0.25 seconds
  per tab in `Sources/LabanCore/TabMetadataSynchronizer.swift`.

- Observation: Instruments trace bundles can contain the launched app's
  environment.
  Evidence: The table-of-contents export for `/Users/dev/Downloads/Untitled4.trace`
  included environment variable names and values. Treat trace bundles as
  sensitive artifacts when sharing them.

## Context and Orientation

Laban is a macOS terminal application. `Sources/LabanCore/Persistence/AgentSessionDetector.swift`
tracks child AI-agent processes such as Claude and Codex so tabs can resume
sessions after restart. It uses a `ProcessIntrospector` implementation backed by
libproc to walk child PIDs, fetch argv/environment/current working directory
metadata, and inspect open `.jsonl` session-log files. `ClaudeSessionLogLocator`
also scans `~/.claude/projects/<encoded-cwd>/` to find the newest session log.

`Sources/LabanCore/TabTitleMetadata.swift` resolves automatic tab titles. Its
`TabTitleResolver.cwdDisplayName(_:)` function currently standardizes both the
candidate path and the home directory when a cwd-derived title is requested.

`Sources/LabanApp/.../TerminalBitmapView.swift` advances rendering frames and
applies the model-derived window title. The trace shows main-thread time in this
frame path, so unchanged window-title writes should be skipped.

The macOS terms in the trace mean:

- APFS is Apple's filesystem; repeated directory enumeration and file-attribute
  reads show up as APFS B-tree and extended-attribute work.
- The sandbox evaluator is macOS policy code run when an app opens files.
- Coalescing means caching or rate-limiting repeated requests so one logical
  state check does not redo the same kernel work every frame or detector tick.

## Plan of Work

1. In `AgentSessionDetector`, preserve existing live-agent and shell-cwd fallback
   behavior while avoiding repeated expensive calls:
   - Increase the default detector cadence from two scans per second to one
     immediate scan followed by a slower repeat cadence, reducing repeated
     `proc_listpids(PROC_PPID_ONLY, ...)` scans of system PID state while idle.
   - Match direct agent basenames without fetching argv first.
   - Only fetch argv for versioned/wrapper executable names that need invocation
     fallback matching.
   - Cache recent shell-cwd Claude-log lookup results for a short interval so a
     missing live process does not rescan the same directory every detector tick.
2. In `AgentSupport.isUUID(_:)`, validate the canonical UUID string by UTF-8
   bytes at fixed positions instead of using `String.count`, `split`, and
   `Character.isHexDigit`.
3. In `TabTitleResolver.cwdDisplayName(_:)`, reuse the standardized home path and
   cache cwd display names by input path.
4. In `TerminalBitmapView`, remember the last window title applied and only set
   `window?.title` when the computed title changes.
5. Run a source audit for `os_log`, `Logger`, and `AppLog` call sites. If a Laban
   logger is in the frame path sampled by Instruments, remove or gate it. If the
   trace samples are AppKit signposts instead, record that as a discovery and
   leave behavior unchanged.
6. Update tests in `Tests/LabanCoreTests` to cover behavior preserved by the
   optimizations, especially UUID validation and process-introspection call
   coalescing.

## Concrete Steps

Run commands from `/Users/dev/wrk/laban` and prefix them with `rtk` per the
repository agent runtime convention.

1. Inspect the relevant source and tests:

   ```sh
   rtk sed -n '1,420p' Sources/LabanCore/Persistence/AgentSessionDetector.swift
   rtk sed -n '1,220p' Sources/LabanCore/Persistence/AgentSupport.swift
   rtk sed -n '430,520p' Sources/LabanCore/TabTitleMetadata.swift
   ```

2. Apply the focused source and test patches.
3. Run targeted tests:

   ```sh
   rtk swift test --filter AgentSupportTests
   rtk swift test --filter AgentSessionDetectorTests
   rtk swift test --filter TabTitleMetadataTests
   ```

4. If those pass, run the broader package test suite if time permits:

   ```sh
   rtk swift test
   ```

## Validation and Acceptance

Acceptance for this plan is:

- `AgentSupportTests` passes, including UUID edge cases that would exercise the
  new byte-level validator.
- `AgentSessionDetectorTests` passes, including tests that prove direct agent
  basename detection avoids unnecessary argv lookups and shell-cwd fallback
  avoids rescanning unchanged directories on every detector tick.
- `TabTitleMetadataTests` passes, proving title resolution behavior remains
  unchanged.
- A future Instruments trace should show less recurring APFS/sandbox work from
  Claude session-log directory scanning and cwd title resolution while idle.
- In a follow-up 20 second idle trace with waiting threads off, the combined
  `AgentSessionDetector` / `ClaudeSessionLogLocator` / `LibprocIntrospector`
  cluster should fall from roughly 150 samples in the supplied trace to under
  about 20 samples. If it does not, the next suspect is repeated metadata refresh
  outside this detector path, such as `TabMetadataSynchronizer` filesystem work.

Validation run on 2026-05-19:

- `rtk swift test --filter AgentSupportTests` passed: 20 tests, 0 failures.
- `rtk swift test --filter AgentSessionDetectorTests` passed: 15 tests, 0 failures.
- `rtk swift test --filter TabTitleMetadataTests` passed: 11 tests, 0 failures.
- `rtk swift test --filter TerminalBitmapView` passed: 16 tests, 0 failures.
- `rtk swift test --filter LabanDebugSmokeTests/testPersistenceFlushRecordsRecentClaudeLogWithoutLiveChild`
  passed after the forced-observation cache fix: 1 test, 0 failures.
- `rtk swift test` passed: 641 tests, 3 skipped, 0 failures.
- `rtk swift test --filter PersistenceRoundTripTests/testClosedTabAgentMetadataIsNotPersistedOrRecreatedByLateUpdate`
  passed after the post-review tab-close regression test: 1 test, 0 failures.
- `rtk swift test` passed after the post-review stale-tab guard: 642 tests, 3
  skipped, 0 failures.
- `./scripts/build-app --profile` passed and produced `.build/laban/Laban.app`
  plus `.build/laban/Laban.app.dSYM`. The build emitted transient Swift module
  cache warnings about missing `.pcm` paths but exited successfully.
- `xcrun xctrace export --input ~/Downloads/Untitled4.trace --toc` succeeded and
  showed a 20.273 second CPU Counters run of `.build/laban/Laban.app`.
- A local XML row scan of the exported `time-profile` table found the new
  process-metadata path present in samples: `TabMetadataSynchronizer.syncSurfaceMetadata`
  in 118 rows, `Session.processMetadata()` in 78 rows,
  `laban_session_process_metadata` in 72 rows, and `proc_pidpath` in 24 rows.
- `rtk swift test --filter AgentSessionDetectorTests` passed after increasing
  the default Claude session-log lookup cache to 5 seconds: 15 tests, 0 failures.
- `./scripts/build-app --profile` passed after the 5 second cache change and
  refreshed `.build/laban/Laban.app` plus `.build/laban/Laban.app.dSYM`. The
  same transient Swift module-cache `.pcm` warnings appeared and the command
  exited successfully.

## Outcomes & Retrospective

The trace-visible metadata polling pass is complete. `AgentSessionDetector` now
uses a 2 second default repeat cadence, avoids argv sysctl work for ordinary
non-agent process names, caches Claude session-log lookups between detector
ticks, and bypasses that cache for explicit flush samples. UUID validation now
uses fixed-position UTF-8 bytes. Tab cwd title resolution reuses the standardized
home path and a bounded cache, and `TerminalBitmapView` skips setting an
unchanged `NSWindow.title`.

This does not address the larger `FrameProducer.commands(...)` allocation bucket.
That should be handled in a separate renderer-focused pass with its own tests and
trace comparison.

## Idempotence and Recovery

The source changes are additive or local replacements. If a test fails, re-run
the targeted test with the same `rtk swift test --filter ...` command after
fixing the local file. Do not reset the working tree because unrelated user
changes may be present.
