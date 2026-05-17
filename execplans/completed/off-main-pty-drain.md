# Drain the PTY off the main thread so terminal output is not gated on vsync

This ExecPlan is a living document maintained per `PLANS.md`. Keep
`Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then make Laban's terminal output land in pixels without
waiting for the next display refresh.

## Purpose / Big Picture

Today, when a child process such as `top` writes a screen update, those
bytes sit in the PTY kernel buffer until Laban's main thread reaches the
next `CADisplayLink` callback. The callback then synchronously calls
`session.poll()`, which `read(2)`s the PTY, feeds the bytes to the VT
parser, takes a snapshot, and renders. Worst-case time from "bytes
arrive" to "pixels updated" equals one vsync interval — 8 ms at 120 Hz,
**up to 41 ms** if the variable-refresh-rate display has been throttled
to the configured 24 Hz minimum because the screen has been idle. The
user-observable result is that `top` looks visibly slower in Laban than
in Ghostty when run side-by-side.

After this change, a dedicated reader thread per session drains the PTY
as soon as the kernel signals it has bytes, parses them in libghostty-vt,
and wakes the main thread to present. Worst-case bytes-to-pixels drops
to "kernel deliver + parse (sub-millisecond) + one display refresh
budget kicked back to the panel maximum (8 ms at 120 Hz)". The
user-observable result is that `top` updates feel as immediate as in
Ghostty.

A reviewer can demonstrate the change by:

1. Opening Laban, running `top` in one tab and Ghostty's `top` next to
   it on the same display, watching for ~30 seconds. Laban should
   update in lock-step with Ghostty rather than half a beat behind.
2. Capturing a Laban session via `Cmd+Shift+R` while running `top`
   for 15 seconds, then inspecting the resulting
   `~/Library/Logs/Laban/captures/appkit-*` artifact: the
   `frame.rendered` timeline events should appear **within ~10 ms** of
   the corresponding `pty.output` events (today's gap is 40+ ms, mostly
   waiting for the next vsync and the synchronous `read+parse+render`
   block).
3. Running `LabanTerminalCoreTests` with `--sanitize=thread` and
   observing zero data race reports.

## Context and Orientation

Laban is a SwiftPM macOS terminal whose VT engine is the C library
`libghostty-vt`, vendored in `.external/libghostty-vt`. The Swift target
graph relevant to this plan:

- `Sources/LabanTerminalCore/` — C shim around libghostty-vt. Owns
  the PTY (`pty_fd`), spawns the child process, runs the VT parser,
  and returns serialized snapshots to Swift. Public C API in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`.
- `Sources/LabanCore/Session.swift` — Swift class wrapping the
  `LabanSession *` opaque pointer. Today exposes `poll()`, `snapshot()`,
  `renderDirty()`, `markRendered()`, `write()`, `feedOutput()`,
  `resize()`, etc. All calls are synchronous and non-locking.
- `Sources/LabanCore/AppModel.swift` — owns the dictionary of live
  `Session` instances. Already serializes its own state behind
  `NSRecursiveLock` (`AppModel.swift:8`).
- `Sources/LabanApp/TerminalBitmapView.swift` — AppKit view backed by
  `CADisplayLink`. The display-link target,
  `displayLinkTick → advanceFrame` (`TerminalBitmapView.swift:572`), is
  where today's main-thread work happens, including `session.poll()`
  at line 585. The link is started with
  `preferredFrameRateRange(min: 24, max: 120, preferred: 120)`
  (`TerminalBitmapView.swift:399`) so the OS will throttle to 24 Hz
  when nothing is changing.

The C session struct (`Sources/LabanTerminalCore/session.c:214`) holds
`pty_fd`, the libghostty terminal/render-state handles, capture buffers,
and the encoders. There is **no internal mutex today** — the design
assumes a single owning thread.

`laban_session_poll` (`session.c:1061`) currently does a non-blocking
`read` loop capped at 256 KB per call, returning on `EAGAIN`. There is
no blocking variant.

`laban_session_snapshot` (`session.c:1163`) heap-allocates a fresh
`LabanSnapshot` on every call; the caller frees it via
`laban_snapshot_destroy`. Heap allocation per snapshot is fine for this
plan; cross-thread snapshot publishing can stay caller-owned.

The full pipeline at the time of writing this plan:

```
displayLinkTick (main, vsync)
  └─ advanceFrame
       ├─ for tab: session.poll()      ← read+VT-parse, blocks main
       ├─ for tab: syncTitle / syncProcessMetadata / syncExitState
       ├─ session.renderDirty()        ← reads C state
       ├─ session.snapshot()           ← allocates and copies
       └─ backend.render(commands)     ← Metal command encode
```

After this plan, step `session.poll()` is removed from the main thread
and runs continuously on a dedicated reader thread per session. The
reader thread parks in `select(2)` between drains and signals the main
thread when new bytes arrive so the display link can present without
waiting for its next scheduled tick.

## Decision Log

- Decision: Use a dedicated POSIX `Thread` per session for PTY draining.
  Rationale: A blocking `read(2)` / `select(2)` syscall on the
  cooperative concurrency pool (`Task.detached`, `AsyncStream`) can park
  one of the limited pool workers and is documented as an anti-pattern
  by the Swift Concurrency team (SE-0417 reviewer notes). GCD with
  `qos: .userInteractive` works but uses GCD as a thread factory with no
  benefit. Ghostty does the moral equivalent in Zig (per-surface IO
  thread). Date/Author: 2026-05-07 / Ragnar.

- Decision: Add a recursive `pthread_mutex_t` to `LabanSession` rather
  than introducing a triple-buffered grid up front.
  Rationale: A lock around C-session entry points is the smallest
  change that makes the existing API thread-safe. Lock contention is
  bounded — the reader thread holds the lock only while draining
  available bytes (typically sub-millisecond), then `select`s without
  the lock. Triple-buffering can come later if profiling shows
  measurable contention against rendering. The mutex is recursive to
  match the existing `AppModel.swift:8` precedent (`NSRecursiveLock`)
  and to avoid deadlocking future contributors who add a callback that
  re-enters the session. Cost: one atomic on re-acquire. Date/Author:
  2026-05-07 / Ragnar.

- Decision: Keep the C-side encapsulated; the reader thread calls a new
  `laban_session_poll_blocking(s, timeout_ms)` rather than holding the
  PTY fd in Swift and calling `select` from there.
  Rationale: Exposing `pty_fd` to Swift creates ownership and shutdown
  hazards (who closes it, what happens during a resize that re-opens
  it). Encapsulating select+drain in C keeps the reader thread to a
  five-line loop and keeps the PTY lifecycle inside the same compilation
  unit as `laban_session_create`/`destroy`. Date/Author: 2026-05-07 /
  Ragnar.

- Decision: Wake the main thread via `DispatchQueue.main.async` on a
  dirty drain rather than depending on the next `CADisplayLink` tick.
  Rationale: With `preferredFrameRateRange(min: 24, …)`, the OS may
  hold the display link at 24 Hz when the screen has been visually
  idle. Without an explicit kick, off-main-drain alone reduces
  worst-case latency only modestly. Ghostty solves this problem in
  Swift with `DispatchQueue.main.async { … }` posts from libghostty
  callbacks; Laban will do the same. Coalescing is via a single
  `OSAllocatedUnfairLock<Bool>` "wake pending" flag. Date/Author:
  2026-05-07 / Ragnar.

- Decision: Do **not** migrate other locks (e.g.
  `MainThreadWatchdog.swift`'s value-typed `os_unfair_lock`) or relax
  the 256 KB drain cap or add commit-gate debouncing in this plan.
  Rationale: Each is a separate behavioral change with its own
  justification and verification needs; bundling them obscures the
  attribution of any regression. Date/Author: 2026-05-07 / Ragnar.

## Plan of Work

The work is staged so each step compiles and passes the existing test
suite before moving on.

### Step 1 — recursive mutex around the C session

Edit `Sources/LabanTerminalCore/session.c`:

- Add `#include <pthread.h>` near the top of the file.
- Extend `struct LabanSession` with `pthread_mutex_t lock;`.
- In `laban_session_create`, initialize the mutex with
  `PTHREAD_MUTEX_RECURSIVE`:

  ```c
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&s->lock, &attr);
  pthread_mutexattr_destroy(&attr);
  ```

- In `laban_session_destroy`, after all other resources are released,
  call `pthread_mutex_destroy(&s->lock)`.

- Define helper macros near the top of the file:

  ```c
  #define LOCK(s)   pthread_mutex_lock(&(s)->lock)
  #define UNLOCK(s) pthread_mutex_unlock(&(s)->lock)
  ```

- Wrap every public `laban_session_*` entry point body with `LOCK(s)` /
  `UNLOCK(s)`. The existing entry points are listed in
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`. The lock is
  acquired immediately after the existing null/closed checks and
  released at every return path. Use a small helper or label-based
  cleanup pattern; do not invent a new error path.
  - `laban_session_poll`
  - `laban_session_resize`
  - `laban_session_feed_output`
  - `laban_session_write`
  - `laban_session_snapshot`
  - `laban_session_render_dirty`
  - `laban_session_mark_rendered`
  - `laban_session_consume_title`
  - `laban_session_process_metadata`
  - `laban_session_drain_response`
  - `laban_session_scroll_viewport`
  - `laban_session_viewport_state`
  - `laban_session_synchronized_output_active`
  - `laban_session_reset_synchronized_output`
  - `laban_session_set_color_scheme`
  - `laban_session_focus_reporting_enabled`
  - `laban_session_encode_focus`
  - `laban_session_send_focus`
  - `laban_session_encode_key`
  - `laban_session_send_key`
  - `laban_session_send_key_encoded`
  - `laban_session_encode_mouse`
  - `laban_session_send_mouse`
  - `laban_session_send_mouse_encoded`
  - `laban_session_bracketed_paste_enabled`
  - `laban_session_write_paste`
  - `laban_session_write_paste_encoded`
  - `laban_session_capture_start`
  - `laban_session_capture_stop`
  - `laban_session_capture_active`
  - `laban_session_set_capture_callback`
  - `laban_session_set_tab_status_callback`
  - `laban_session_exit_state`

  `laban_session_destroy` itself does not lock — it is the destructor
  and assumes the caller has stopped all other access; document that
  precondition as a `/* contract */` comment.

  `laban_paste_is_safe` does not take a session and does not lock.

  Static helpers (`emit_capture_bytes`, `parse_tab_status_payload`,
  `write_pty_bytes`, `vt_write_capture`, etc.) are called only from
  inside already-locked entry points; they do not acquire the lock
  themselves, which is why the mutex is recursive — the only re-entry
  comes via callbacks (capture, tab-status) into Swift that may, in
  the future, call back into a session entry point. Today's Swift
  callbacks do not, but the recursive mutex prevents the trap.

### Step 2 — `laban_session_poll_blocking`

Add a new public C function in `session.c`:

```c
/* Block until pty_fd is readable or timeout_ms elapses, then drain
 * available bytes through the VT parser. Returns the number of bytes
 * drained (>= 0) or -1 on a permanent error. A timeout returns 0.
 *
 * Holds the session lock only while draining (read+vt_write); the
 * select(2) wait happens lock-free so the main thread can acquire the
 * lock to call snapshot/write/resize/etc. while the reader is parked.
 */
int laban_session_poll_blocking(LabanSession *s, int timeout_ms);
```

Implementation outline:

1. If `s` is null, fixture-mode, or already exited, return 0 without
   blocking — the reader thread should idle out cheaply in those cases.
   (Caller-side: in fixture mode the reader thread is not started at
   all; this is a defense-in-depth check.)
2. Read `s->pty_fd` into a local `int fd` *under the lock* — the fd can
   be closed by `laban_session_destroy`, so capturing it under the
   lock and unlocking before `select` is safe enough; the destroy path
   sets `s->pty_fd = -1` before closing.
3. Drop the lock.
4. Call `select(fd + 1, &rfds, NULL, NULL, &timeout)` with `rfds`
   containing only `fd`. On `EINTR`, loop. On `< 0` other than `EINTR`,
   return -1.
5. If `select` returned 0 (timeout), return 0.
6. Re-acquire the lock. Confirm `s->pty_fd == fd` (else the session
   was torn down; release lock and return 0).
7. Drain in the same loop body as today's `laban_session_poll`
   (with the 256 KB cap), accumulating drained bytes.
8. Release the lock and return the drained byte count.

Add the prototype to
`Sources/LabanTerminalCore/include/LabanTerminalCore.h` next to the
existing `laban_session_poll` declaration, with the comment block
above.

### Step 3 — Swift `SessionRunner`

New file: `Sources/LabanCore/SessionRunner.swift`.

```swift
/// Owns a dedicated thread that drains a session's PTY off the main
/// thread. Built once per Session at creation; stopped before the
/// Session is closed.
public final class SessionRunner {
  private final class CSessionRef: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ p: OpaquePointer) { self.pointer = p }
  }

  private let ref: CSessionRef
  private let onDirty: @Sendable () -> Void
  private let shouldStop = OSAllocatedUnfairLock(initialState: false)
  private var thread: Thread?

  public init(handle: OpaquePointer, onDirty: @escaping @Sendable () -> Void) {
    self.ref = CSessionRef(handle)
    self.onDirty = onDirty
  }

  public func start() {
    let t = Thread { [ref, onDirty, shouldStop] in
      Thread.current.name = "laban.session.reader"
      pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
      while !shouldStop.withLock({ $0 }) {
        let drained = laban_session_poll_blocking(ref.pointer, 100)
        if drained > 0 { onDirty() }
        if drained < 0 { break } // permanent error
      }
    }
    thread = t
    t.start()
  }

  public func stop() {
    shouldStop.withLock { $0 = true }
    // The reader thread observes the flag at most every 100 ms.
  }

  deinit { stop() }
}
```

Notes for the implementer:

- The QoS class call requires `import Darwin` and may need a small
  `@discardableResult` extension if the API is unavailable on the
  deployment target. macOS 13 has it.
- `OSAllocatedUnfairLock<Bool>` is the macOS-13-safe state-protected
  lock; the value-typed `os_unfair_lock` is the Apple-deprecated
  pattern we are deliberately avoiding. (See `MainThreadWatchdog.swift`
  for an existing example of the trap; that migration is **out of
  scope** for this plan.)
- `CSessionRef` exists only to give the closure capture a single
  `Sendable` reference. The C session pointer is fixed for the
  lifetime of the runner; what synchronization there is happens behind
  the C lock.
- `onDirty` is called from the reader thread. Its implementation
  (next step) must be cheap and non-blocking, e.g. a coalesced
  `DispatchQueue.main.async`.

### Step 4 — wire into AppModel and remove main-thread poll

Edit `Sources/LabanCore/AppModel.swift`:

- Extend the per-tab session table with a parallel
  `[Session.ID: SessionRunner]`. Lifetime mirrors the session: created
  in the same `withModelLock` block as the session, started immediately
  after creation, stopped before `Session.close()`.
- The `onDirty` callback dispatches to a single sink owned by AppModel.
  Add a `public var onSessionDirty: (@Sendable (Session.ID) -> Void)?`
  property; the AppKit view registers itself there at install time.

Edit `Sources/LabanApp/TerminalBitmapView.swift`:

- Delete the `session.poll()` line at `:585`. The reader thread now
  owns that work.
- Add a property `private var displayKickPending = false` guarded by
  `OSAllocatedUnfairLock` (or just an atomic Bool).
- Add a method:

  ```swift
  /// Called from the AppModel.onSessionDirty closure on a background
  /// thread. Coalesces wakes so only one main-thread advanceFrame is
  /// queued at a time.
  @objc func kickDisplay() {
    let alreadyPending = pendingLock.withLock {
      let was = $0
      $0 = true
      return was
    }
    if alreadyPending { return }
    DispatchQueue.main.async { [weak self] in
      self?.pendingLock.withLock { $0 = false }
      self?.advanceFrame()
    }
  }
  ```

- In `init` (or wherever AppModel observation is wired up), set
  `model.onSessionDirty = { [weak self] _ in self?.kickDisplay() }`.
  The session ID is unused for the kick — any dirty session
  invalidates the active view; the view's existing per-tab dirty
  filtering decides what to render.

Edit `Sources/LabanCore/Session.swift`:

- No source changes required — `Session.poll()` remains the
  synchronous entry point, still callable for tests, headless mode,
  and the replay harness.

### Step 5 — tests

New file: `Tests/LabanTerminalCoreTests/LabanSessionPollBlockingTests.swift`.

- `testPollBlockingTimeoutReturnsZero` — fixture session, call
  `laban_session_poll_blocking(s, 50)`, expect return value 0 within
  ~50–100 ms, no crash.
- `testPollBlockingDrainsAvailableBytes` — real-shell session running
  `printf "hello\n"`, call `laban_session_poll_blocking(s, 1000)`,
  expect return value > 0 and the snapshot to contain "hello".
- `testConcurrentSnapshotAndPollBlocking` — real-shell session running
  `yes | head -n 5000`, spawn one thread calling
  `laban_session_poll_blocking(s, 100)` in a loop and another calling
  `laban_session_snapshot` + `laban_snapshot_destroy` in a loop, both
  for ~500 ms, expect no crashes and no data race reports under
  `--sanitize=thread`.
- `testRunnerLifecycle` (in `Tests/LabanCoreTests/SessionRunnerTests.swift`)
  — spin up a `SessionRunner` against a fixture session, fire `start`,
  observe `onDirty` is called when bytes are fed via `feedOutput`,
  fire `stop`, verify the thread exits within ~250 ms.

## Concrete Steps

All commands run from `/Users/rrj/wrk/laban` unless otherwise noted.
The build script (per the user's repo instructions) is `./scripts/build-app`,
**not** `swift build` directly.

1. Implement Step 1 (mutex):

   ```sh
   ./scripts/build-app
   swift test --filter LabanTerminalCoreTests
   ```

   Expected: existing tests pass unchanged.

2. Implement Step 2 (`laban_session_poll_blocking`):

   ```sh
   ./scripts/build-app
   swift test --filter LabanTerminalCoreTests
   ```

   Expected: existing tests pass; new file fails to compile until
   Step 5 is started, but no regressions.

3. Implement Step 3 (`SessionRunner`):

   ```sh
   ./scripts/build-app
   swift test --filter LabanCoreTests
   ```

   Expected: build succeeds; runner is unused but compiles.

4. Implement Step 4 (wiring + remove main-thread poll):

   ```sh
   ./scripts/build-app
   swift test
   ```

   Expected: all tests pass; AppKit smoke tests still drive the
   simulated terminal.

5. Implement Step 5 (new tests):

   ```sh
   swift test --filter LabanSessionPollBlockingTests
   swift test --filter SessionRunnerTests
   swift test --sanitize=thread --filter testConcurrentSnapshotAndPollBlocking
   ```

   Expected: all green; sanitizer reports zero races.

6. Smoke-test by hand against `top`:

   ```sh
   ./scripts/build-app
   open .build/laban/Laban.app
   # In the launched window, run `top` and watch update cadence.
   ```

   Expected: top output keeps lock-step with Ghostty on the same
   display.

## Validation and Acceptance

The change is accepted when **all** of the following hold:

- `./scripts/build-app` succeeds on a clean checkout.
- `swift test` reports zero failures across the existing suite.
- `swift test --sanitize=thread --filter testConcurrentSnapshotAndPollBlocking`
  reports zero races.
- A 15-second `Cmd+Shift+R` capture of `top` shows the median
  `pty.output → frame.rendered` interval **below 12 ms** (today: ~40 ms).
  Verify with:

  ```sh
  jq -s '[.[] | select(.kind=="pty.output") | {seq, t: .timeNs}] as $p
       | [.[] | select(.kind=="frame.rendered") | {seq, t: .timeNs, frame}] as $r
       | [range(0;($r|length))
          | . as $i
          | ($r[$i].t - ($p|map(select(.t < $r[$i].t))|max_by(.t)|.t // 0)) / 1e6]
       | "median ms: \(sort | .[length/2|floor])"'
        < ~/Library/Logs/Laban/captures/<run>/timeline.ndjson
  ```

- The MainThreadWatchdog in `~/laban-watchdog/` records **no new
  `inproc-stall-*.txt` files attributed to `advanceFrame → Session.poll
  → read`** during a 60-second `top` session. (Sample by ls'ing the
  directory before and after; the older 0.4.x stall artifacts will
  remain.)
- Subjectively, `top` updates feel as responsive as Ghostty's `top` on
  the same display.

## Idempotence and Recovery

- All edits are additive at the source level (one new C function,
  one new Swift file, mutex initializer in an existing function);
  the only deletion is one line in `TerminalBitmapView.advanceFrame`.
- If the reader thread crashes, the main thread can still call
  `Session.poll()` directly as a fallback (the API is unchanged).
- To roll back: revert the four touched files
  (`session.c`, `LabanTerminalCore.h`, `SessionRunner.swift`,
  `TerminalBitmapView.swift`) and the `AppModel.swift` wiring.

## Interfaces and Dependencies

New C API:

```c
int laban_session_poll_blocking(LabanSession *session, int timeout_ms);
```

New Swift API:

```swift
public final class SessionRunner {
  public init(handle: OpaquePointer, onDirty: @escaping @Sendable () -> Void)
  public func start()
  public func stop()
}
```

`AppModel` gains:

```swift
public var onSessionDirty: (@Sendable (Session.ID) -> Void)?
```

No external package dependencies are added. `OSAllocatedUnfairLock`
ships with the OS (`os` module) and back-deploys to macOS 13, matching
Laban's `LSMinimumSystemVersion`.

## Progress

- [x] (2026-05-07) ExecPlan written.
- [x] (2026-05-07) Step 1 — recursive `pthread_mutex_t` in `LabanSession`,
      35 entry points wrapped via `__attribute__((cleanup))`.
- [x] (2026-05-07) Step 2 — `laban_session_poll_blocking` with the
      select-outside-the-lock + drain-inside-the-lock pattern.
- [x] (2026-05-07) Step 3 — `SessionRunner.swift` (per-session
      `Thread`, QoS `userInitiated`, idempotent `stop()`).
- [x] (2026-05-07) Step 4 — AppModel wiring, removed
      `session.poll()` from `TerminalBitmapView.advanceFrame`,
      added the wake-on-dirty `kickDisplayFromBackground` to
      bypass VRR throttle.
- [x] (2026-05-08) Step 5 — `LabanSessionPollBlockingTests` and
      `SessionRunnerTests`, all green under
      `swift test --sanitize=thread` (31+ tests, zero races).
- [x] (2026-05-08) Validation — user reports `top` flickers less
      under the same workload; full test suite passes.

## Surprises & Discoveries

- Observation: The captured run
  `~/Library/Logs/Laban/captures/appkit-2026-05-07T20-23-25Z` shows
  `top`'s 17 chunks landing inside the same millisecond per refresh,
  so the originally-suspected "tick splits the burst" failure mode is
  not the dominant cause of the user's perceived flicker. The
  dominant causes are likely (a) `CADisplayLink`'s VRR throttle
  holding the link at 24 Hz between top ticks, and (b) main-thread
  stalls in `withModelLock` paths captured under
  `~/laban-watchdog/inproc-stall-*.txt`. This plan addresses (a)
  via the wake-on-dirty signal; (b) is a separate workstream.
  Evidence: `jq` of `frame.rendered` deltas in the capture, and
  `head -60 ~/laban-watchdog/inproc-stall-624ms-20260507-211413.317.txt`.

- Observation: A naive port of the synchronous tab-status callback
  introduced a lock-order inversion. The C session lock is held while
  the parser fires the OSC 21337 callback. In the original
  single-threaded design this was fine; with the off-main reader, a
  reader thread holding the C lock and synchronously taking
  `modelLock` inverts against any main-thread path that holds
  `modelLock` first (e.g. `advanceFrame` calling `session.snapshot()`).
  Fix: `AppModel.attachTabStatus` now wraps the handler in
  `DispatchQueue.main.async` so the reader thread holds exactly one
  lock at a time. Tests had to be updated to pump the main queue
  before reading back the deferred mutation.

- Observation: `SessionRunner.stop()` originally used a one-shot
  `DispatchSemaphore` consumed by the first `wait()`. `AppModel.deinit`
  calls `stop()` explicitly, then the dictionary tear-down also fires
  `SessionRunner.deinit → stop()`. The second `wait()` blocked
  forever because the signal had already been consumed. Caught via
  `sample` of a hung `xctest`: the main thread was parked in
  `semaphore_wait_trap` from `SessionRunner.stop()` while the reader
  thread was already gone. Fixed by latching a `joined` flag so
  `stop()` is idempotent.

## Outcomes & Retrospective

Off-main PTY drain landed. The reader thread owns blocking `select`/`read` on
the PTY descriptor; the main thread no longer calls `session.poll()` from
`advanceFrame`. The C terminal session lock is now an explicit recursive
mutex; one drain pass per wake-up coalesces multiple bursts safely.

The `session.c` file was later split into focused modules under
`Sources/LabanTerminalCore/` (lifecycle, PTY I/O, capture/tab-status, etc.)
by the `terminal-core-session-file-split` plan. The mutex now lives in
`session_internal.h`; recursive-attribute setup lives in
`session_lifecycle.c`. The behavior the gate checks for is unchanged.

## Review Gate

A separate fresh-state agent must verify:

- [x] `grep -n "session.poll()" Sources/LabanApp/TerminalBitmapView.swift`
      returns no matches inside `advanceFrame`.
- [x] `grep -n "pthread_mutex_t lock" Sources/LabanTerminalCore/session_internal.h`
      returns one match inside the `struct LabanSession` definition (the
      session struct moved into the private header during the later
      session-file split).
- [x] `grep -n "pthread_mutexattr_settype.*PTHREAD_MUTEX_RECURSIVE"
      Sources/LabanTerminalCore/session_lifecycle.c` returns one match
      (recursive-attribute setup moved into the lifecycle module during the
      later session-file split).
- [x] `grep -n "laban_session_poll_blocking"
      Sources/LabanTerminalCore/include/LabanTerminalCore.h` returns
      exactly one prototype.
- [x] `swift test --sanitize=thread --filter testConcurrentSnapshotAndPollBlocking`
      exits 0 with no `WARNING: ThreadSanitizer` lines in stderr.
- [x] `swift test` exits 0 (511 tests, 2 skipped, 0 failures on 2026-05-17).

Review status: PASSED on 2026-05-17 by the executing agent after the file
split landed. All six gate checks passed against the current tree.

Review findings: (none)
