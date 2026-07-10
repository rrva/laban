# Labpty fresh-eyes audit — 2026-07-10

**Scope:** full re-read of `Sources/Labpty/*` (main.c, labpty_registry.c, labpty_byte_ring.c, labpty_protocol.c, labpty_frame.c, all headers), `Sources/LabanCore/Labpty*` (reader, writer, protocol, framing, layout, overflow gate, degradation), `Tests/LabptyTests/*` (6 files, ~200KB), and `specs/labpty/*.tla` (10 model specs). Two parallel subagents covered test-coverage gaps and TLA+-vs-C divergences.

**Companion doc:** `docs/quality/labpty-audit-2026-07-10.md` (first pass, which fixed 3 bugs).

**Verdict:** no crash bugs found. The codebase is in excellent shape. Six findings below, ordered by severity. Findings 1-3 are behavioral inconsistencies worth fixing; 4-6 are coverage and process gaps.

---

## Finding 1: `handle_write` does not close master_fd on hard write error (inconsistent with `flush_pending_input`)

**Severity:** medium (behavioral bug, not a crash)

**Location:** `Sources/Labpty/main.c` lines 811-817 (handle_write) vs lines 1000-1020 (flush_pending_input)

### Why it is a bug

`handle_write` and `flush_pending_input` both write to `session->master_fd` and both can hit a hard error (EIO: the child closed its slave side; EBADF: the fd is invalid). They handle it differently:

`handle_write` (line 817):
```c
if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
return LABPTY_E_INTERNAL;   // <-- returns without closing master_fd
```

`flush_pending_input` (lines 1018-1019):
```c
close(session->master_fd);  // <-- closes the broken master
session->master_fd = -1;
return;
```

After `handle_write` returns E_INTERNAL, the session stays `alive=1` with `master_fd` still >= 0. Subsequent `writeInput` and `resize` calls on the same session check `session->master_fd < 0` (lines 639, 757) to reject, but since `master_fd` is still valid, they attempt the operation and fail with E_INTERNAL again. The client sees repeated E_INTERNAL errors until `drain_session` reads EOF/EIO on the next poll cycle (at most ~100ms later) and finally closes the fd.

Concrete consequences:

- The client sees a stream of `E_INTERNAL` instead of a single clean `SESSION_NOT_FOUND`. A client that retries on E_INTERNAL will spin briefly.
- The broken session is still listed as alive in `listSessions` (alive=1) during the window, so other clients may attempt to attach to a dying session.
- The inconsistency means a future maintainer might "fix" one path to match the other and introduce a double-close or a missed teardown.

### Fix suggestion

Close `master_fd` on hard write error before returning, mirroring `flush_pending_input`:

```c
// main.c, handle_write, after line 816:
if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
/* Hard write error: the slave is gone. Close the master so the session
 * tears down via the R1 hangup-grace path on the next reap tick, instead
 * of staying alive with a broken master that returns E_INTERNAL to every
 * subsequent writeInput/resize. Mirrors flush_pending_input's R3 path. */
close(session->master_fd);
session->master_fd = -1;
return LABPTY_E_INTERNAL;
```

### Caveat

EIO on `write(master_fd)` only occurs when all slave-side fds are closed. The daemon holds `slave_inspect_fd`, which often keeps the slave side alive (data goes into the buffer even if the child never reads it). So this path is less common than it first appears, but the inconsistency is real and the fix is low-risk.

---

## Finding 2: `handle_terminate` returns descriptor with stale (empty) `logical_id` and `ring_path`

**Severity:** low (cosmetic, potentially confusing for clients)

**Location:** `Sources/Labpty/main.c` lines 688-725, `Sources/Labpty/labpty_registry.c` lines 447-448

### Why it is a bug

`labpty_session_descriptor` returns a `labpty_descriptor_view_t` by value, but `logical_id` and `ring_path` are **pointers** into the session struct's arrays:

```c
// labpty_registry.c:447-448
.logical_id = session->logical_id,
.ring_path = session->ring.path,
```

In `handle_terminate`'s alive path:

1. Line 688: `descriptor = labpty_session_descriptor(session)` captures the struct, but the pointers still point into the live session.
2. Line 694: `labpty_session_request_close(session, ...)` calls `session->logical_id[0] = '\0'` (line 332 in registry.c) and `labpty_byte_ring_unlink_path` which sets `session->ring.path[0] = '\0'` (line 241 in byte_ring.c).
3. Line 725: `encode_descriptor_view_payload(&descriptor, out, cap)` encodes the now-empty strings into the response.

The client receives a terminate response with `logical_id=""` and `byteRingShmPath=""`. The dead-leak path (lines 695-722) does NOT clear `logical_id`, so its descriptor is correct. Only the alive path has this issue.

Concrete consequences:

- A client that uses the terminate response's `logical_id` to find and clean up the corresponding tab (e.g. removing it from a dictionary keyed by `logical_id`) would fail to match the empty string.
- The response looks like a session with no identity, which is misleading. The client already knows the handle, so this doesn't break core functionality, but it violates the implicit contract that a response descriptor reflects the session's state at the time of the response.

### Fix suggestion

Copy the strings into local buffers before calling `labpty_session_request_close`, or build the descriptor after the state change:

```c
// Option A: capture before modification
labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
char logical_id_snap[LABPTY_LOGICAL_ID_BYTES + 1];
char ring_path_snap[LABPTY_PATH_BYTES + 1];
snprintf(logical_id_snap, sizeof(logical_id_snap), "%s", descriptor.logical_id);
snprintf(ring_path_snap, sizeof(ring_path_snap), "%s", descriptor.ring_path);
descriptor.logical_id = logical_id_snap;
descriptor.ring_path = ring_path_snap;
if (session->alive) {
    labpty_session_request_close(session, monotonic_ns());
}
// ... rest unchanged, encode uses the snapshots
```

```c
// Option B: build after modification, but adjust alive and clear path
if (session->alive) {
    labpty_session_request_close(session, monotonic_ns());
}
labpty_descriptor_view_t descriptor = labpty_session_descriptor(session);
descriptor.alive = 0;
// Note: logical_id and ring_path will already be "" here, which is
// the correct state for a terminated session.
```

Option A preserves the pre-termination identity in the response. Option B accepts that the post-termination state has an empty id and is arguably more honest. Either is an improvement over the current behavior (capturing before, encoding after).

---

## Finding 3: `drain_session` can close master_fd while `pending_input` is staged (silent data loss)

**Severity:** low (data loss in a teardown scenario, not a crash)

**Location:** `Sources/Labpty/main.c` lines 1253-1262 (service_poll_watch), 1132-1155 (drain_session), 991-1024 (flush_pending_input)

### Why it is a bug

When a session has both POLLOUT (pending input to flush) and POLLIN (output to read), `service_poll_watch` calls `flush_pending_input` first, then `drain_session`:

```c
// main.c:1258-1261
if (revents & POLLOUT) flush_pending_input(s);
if (s->master_fd >= 0 && poll_revents_readable(revents)) drain_session(daemon, s);
```

If `flush_pending_input` gets EAGAIN (can't flush the tail yet), it returns with the tail still staged (`pending_input_total > pending_input_sent`). Then `drain_session` reads, gets EOF (n==0), and closes `master_fd` (line 1150-1151). The staged tail is now orphaned: `pending_input_total > 0` but `master_fd = -1`, so no future POLLOUT will ever flush it.

The client already received `LABPTY_OK` for the writeInput (the preflight admitted it and the initial write partially succeeded), so the client believes the bytes were delivered. The tail is silently lost.

Compare with `flush_pending_input`'s hard-error path (R3, lines 1009-1017), which logs the dropped byte count. Here the loss is silent.

Concrete consequences:

- The ADR 0008 externally-atomic guarantee says: if `writeInput` returns OK, the bytes were delivered (or the session is torn down). Here the bytes are lost and the session is torn down, but the loss is not logged.
- The R3 path in `flush_pending_input` explicitly logs dropped bytes for diagnosability. This path should match.
- The window is narrow: it only happens when the child hangs up (EOF on master) while a writeInput tail is staged. The session is dying anyway, so the lost bytes are for a child that has already closed its slave.

### Fix suggestion

In `drain_session`, before closing `master_fd` on EOF, check for staged input and log the loss (matching the R3 pattern):

```c
// main.c, drain_session, around line 1150:
if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
/* EOF or hard read error: the child hung up. If we have staged
 * writeInput that was never flushed, log the loss so it is
 * diagnosable (matches the R3 path in flush_pending_input). */
if (session->pending_input_total > session->pending_input_sent) {
    size_t dropped = session->pending_input_total - session->pending_input_sent;
    fprintf(stderr,
        "labpty: dropped %zu staged writeInput byte(s) on session %llu "
        "after master EOF (child hung up before the accepted tail flushed)\n",
        dropped, (unsigned long long)session->handle);
    session->pending_input_total = 0;
    session->pending_input_sent = 0;
}
close(session->master_fd);
session->master_fd = -1;
break;
```

---

## Finding 4: Test coverage gaps in crash-critical paths

**Severity:** high (process gap)

Three crash-critical C daemon paths have **zero test coverage**:

### 4a: Pending input staging/drain (`pending_input`, `flush_pending_input`, POLLOUT drain)

The complete non-blocking write staging mechanism is untested:
- `handle_write` staging an unsent tail when the master returns EAGAIN (lines 819-825)
- `flush_pending_input` draining the tail on POLLOUT (lines 991-1024)
- The R3 hard-error path: closing the master and logging dropped bytes when `write()` returns EIO/EBADF during flush (lines 1000-1020)
- The backpressure gate: a second `writeInput` is refused while a tail is pending (line 761)
- Interaction with canonical-mode preflight: the estimate counts staged bytes as delivered

**Risk:** This is the ADR 0008 non-blocking write path and the R3 teardown path. If the staging logic has a bug (e.g. a wrong index, a missed reset, a double-flush), the daemon could silently lose input or corrupt the pending buffer. No test exercises this.

**Suggested test:** Open a session with a slow-consuming child (e.g. `cat` with a small buffer), send a `writeInput` larger than the master accepts in one `write()`, verify the tail is staged and eventually flushed, verify a second `writeInput` during staging returns `INPUT_BACKPRESSURE`, and verify the full payload reaches the child.

### 4b: R1 hangup grace deadline (`hangup_deadline_ns`, 250ms grace)

The grace window between detecting `alive=1, master_fd<0` and tearing down the session is untested:
- The deadline is armed on first sight of `alive=1, master_fd<0` (registry.c:424)
- The deadline fires after 250ms if the slot is still hung-up-but-running (registry.c:426-428)
- The deadline is cleared if the child is reaped by `waitpid` during the window (registry.c:398)
- The deadline is cleared if the master recovers (registry.c:429-432)

**Risk:** If the grace deadline logic has a bug, slots could leak (deadline never fires) or sessions could be torn down prematurely (deadline fires too fast). The SIGKILL escalation IS tested (`testTerminateHupIgnoringChildEscalatesToSigkill`), but the grace timing is not.

**Suggested test:** Open a session, close the master fd out-of-band (simulating drain_session EOF), wait 260ms, verify the session is torn down. Also test that a child that exits naturally during the grace window is reaped by the normal `waitpid` path, not force-closed.

### 4c: `handle_write` EIO on master (finding 1)

No test for the broken-master state where `write(master_fd)` returns EIO. The test should verify that after EIO, the session is torn down (not left alive with a broken master).

---

## Finding 5: TLA+ spec divergences (unmodeled crash-critical paths)

**Severity:** medium (process gap)

The "Modelled by" comments in the C code are accurate for what they claim. But significant C behavior is **not modeled** in any spec:

| C behavior | Spec coverage | Risk |
|------------|---------------|------|
| R1 hangup grace deadline (`hangup_deadline_ns`, 250ms grace) | None | Session teardown on hung-up PTY is unverified by formal methods |
| R3 pending input hard-error teardown (`flush_pending_input` EIO path) | None | The accepted-but-undelivered input path is unverified |
| Frame deadline (`frame_deadline_ns`) trickle defense | Partial | `LabptyControlChannel.tla` models `Expire` but not the two-deadline distinction; the C code comment at line 1307 explicitly notes this |
| Canonical backpressure (ADR 0008 preflight, `canonical_pending_estimate`) | None | The preflight admission check is unverified |
| Wake watch mechanism (R2, control-reconnect survival) | None | `LabptyOutputWake.tla` models park/notify but not the per-client watch set |
| Slave inspect fd and preflight machinery | None | Not modeled in any spec |

Additionally, `LabptyOutputWake.tla` defines an `IgnoreStalePark` constant that the C code does not implement (the C code always requires offset match for park). This is a divergence where the C code is stricter than the spec. Not a bug, but the spec models behavior that doesn't exist in the implementation.

### Recommendations

1. Create a TLA+ spec for the R1 hangup grace deadline, modeling `hangup_deadline_ns` and the `alive=1/master_fd=-1` to `close_pending=1` transition.
2. Extend `LabptyControlChannel.tla` to model the `frame_deadline_ns` vs `deadline_ns` distinction and prove the trickle-attack defense.
3. Create a TLA+ spec for the pending input buffer and R3 hard-error path.
4. Remove or document the `IgnoreStalePark` constant in `LabptyOutputWake.tla` since the C code does not implement it.

---

## What was verified as correct

The following areas were scrutinized closely and confirmed sound:

- **Protocol decoders**: All bound-checked, CBMC-proven, trailing bytes tolerated for additive evolution (ADR 0007). NUL-byte rejection in `read_string`. UTF-8 validation for echoed text fields.
- **Byte ring write/read**: Release-acquire ordering on `output_offset` publish. Wraparound arithmetic correct. Safety margin (64KB) exceeds max write (4KB), preventing torn reads. Power-of-two capacity enforced.
- **Socket startup**: O_EXCL|O_NOFOLLOW on ring files. Private shm dir validation. Stale-socket probe, bind, unlink retry. Inode-validated cleanup unlink.
- **SIGKILL escalation**: 200ms HUP budget, then SIGKILL, then reap. `close_pending` prevents double-terminate. Logical_id relinquished at request_close time (race-free reuse per `LabptyReuse.tla`).
- **Slowloris defense**: Two-deadline system (idle 250ms + frame-total 2s). Established client distinction. Maintenance floor (50ms) prevents budget stretching under continuous readiness.
- **Attachment bits**: `uint8_t` bitmask, popcount for connected_clients. `client_release` scrubs from all sessions. Reuse memset clears.
- **Signal handling**: SIGHUP ignored (daemon outlives launcher per ADR 0006). SIGPIPE ignored. SIGTERM/SIGINT trigger graceful shutdown. `killpg` with ESRCH/EPERM fallback to `kill`.
- **`laban_pty_open`**: `setsid()` in child (so `killpg(child_pid)` is correct, `child_pid == pgid`). CLOEXEC on all fds. Nonblocking master. Fallback shell resolution.
- **Poll set sizing**: `LABPTY_MAX_POLL_WATCHES = 1 + 8 + 64 = 73` exactly matches max possible watches. Assert cannot fail.
- **Ring file preallocation**: `F_PREALLOCATE` before `ftruncate` prevents SIGBUS on full disk. Error returns `E_RING_MAP_FAILED` eagerly.
- **`labpty_registry_open` failure path**: Ring-create failure after PTY open correctly calls `labpty_session_request_close` for async teardown instead of blocking the event loop.
- **Preflight variable naming**: `pending_canq` (FIONREAD = canonical queue) and `pending_rawq` (`canonical_pending_estimate` = raw queue) are correctly named. The arithmetic `used_input = canq + rawq` is correct.
