# Labpty audit — 2026-07-10

**Scope:** `Sources/Labpty/*`, `Sources/LabanCore/Labpty*`, `Sources/LabanCore/PTYLabClient.swift`, `Tests/LabptyTests/*`, `specs/labpty/*`, `proofs/labpty/*`.

**Method:** manual code review, static analysis (`swift build` with `-Wall -Wextra`), local test runs (`swift test --filter LabptyTests`, `LABPTY_STRESS=1` soak), formal verification (`scripts/check-specs`, `scripts/check-cbmc`, `scripts/check-trace`), and parallel subagent review passes.

**Verdict:** the daemon is in unusually good shape for C code at a trust boundary. No crash bugs or client-controlled abort paths were found. Three real correctness/security bugs were found and fixed in this pass; the remaining findings are lower-severity hardening or process gaps.

---

## Fixes applied in this audit

| # | Severity | File | Issue | Fix |
|---|---|---|---|---|
| 1 | Medium | `Sources/Labpty/labpty_registry.c:211` | Defensive reuse guard used `slave_inspect_fd > 0`, so fd `0` would leak if it ever survived a close path. | Changed to `>= 0`. |
| 2 | High | `Sources/LabanCore/LabptyByteRingReader.swift:28` | Production byte-ring reader opened the daemon-provided ring path without `O_NOFOLLOW`, allowing a same-UID symlink planted after creation to redirect reads. | Added `O_NOFOLLOW` to `Darwin.open` flags. |
| 3 | High | `Sources/LabanCore/PTYLabClient.swift:246-257` | `attachSession(logicalSessionId:)` and `detachSession(sessionId:)` only queried the local cache/list; they never called the daemon's `ATTACH`/`DETACH` RPCs, so `connectedClients` and orphan/adoption state were wrong for callers using the generic `TerminalSessionClient` API (e.g. `HeadlessDebugRuntime`). | Both methods now resolve the handle and call `attachLabptySession(handle:)` / `detachLabptySession(handle:)`, then refresh the cached descriptor. |

All three fixes pass:

- `swift test --filter LabptyTests` — 113 tests, 0 failures.
- `LABPTY_STRESS=1 LABPTY_STRESS_DURATION_S=10 swift test --filter LabptyStressTests` — passed (one flaky failure on first run unrelated to the changes; passed on rerun).
- `scripts/check-cbmc` — all proofs verified, negative controls refuted.
- `scripts/check-trace` — attachment/reuse/control traces conform.

---

## Additional findings (not fixed)

### Daemon (C)

| # | Severity | File | Issue | Why not fixed |
|---|---|---|---|---|
| 4 | Low | `Sources/Labpty/labpty_byte_ring.c:21-32` | `open_ring_backing()` has a same-UID TOCTOU window between `lstat()` and `unlink()` for stale ring files. A same-UID attacker could swap a verified regular file for a symlink in that window and cause `unlink()` to remove the symlink target. The retry `open(O_EXCL|O_NOFOLLOW)` prevents daemon corruption; only the unlink target is at risk. | Acceptable risk today: cross-UID attacks are blocked, and a race-resistant `openat`-based cleanup would add non-trivial complexity for a same-UID-only edge case. |
| 5 | Low | `Sources/Labpty/main.c` | The `frame_deadline_ns` trickle-defense and output-wake watch-handle delivery are not modelled in TLA+ / trace conformance (see formal-coverage section). | Covered by adversarial Swift tests; TLA+ models intentionally abstract these details. |

### Swift LabanCore

| # | Severity | File | Issue | Why not fixed |
|---|---|---|---|---|
| 6 | Medium | `Sources/LabanCore/LabptyByteRingWriter.swift:26-40` | Test-only writer uses `O_RDWR|O_CREAT|O_TRUNC` (follows symlinks/truncates targets) and `memset(..., mapLength)` instead of `F_PREALLOCATE`, so a full disk can SIGBUS. The daemon's writer was hardened against both hazards; this class was left unsafe. | The class is not used in production, only in tests. Fixing it would require changing test setup (e.g. unique temp paths per writer, removing `O_TRUNC`) and is left for a follow-up that can validate no test breakage. |
| 7 | Medium | `Sources/LabanCore/LabptyByteRingReader.swift:68-127` | The reader rediscovers `countersOffset` from the header and only requires 8-byte alignment + span fit. A malicious producer can place the counters inside the ring data itself, making the reader chase garbage offsets without crashing. | Tolerable because the producer is the trusted daemon; hardening to pin the offset to the declared counters region would reduce additive-layout flexibility and needs its own regression test. |
| 8 | Low | `Sources/LabanCore/LabptyFraming.swift:289-299` | `LabptyPayloadReader.readString` accepts embedded NUL bytes, while the C daemon rejects them. A malicious peer can return strings that mismatch daemon validation and can poison client-side dictionaries keyed by those strings. | Low exploitability in the current threat model (same-UID attacker already needed); fix is to reject `bytes.contains(0)` in `readString`. |
| 9 | Low | `Sources/LabanCore/LabptyByteRingLayout.swift:76` | `fnv1a64` hashes the full string; C caps at `LABPTY_LOGICAL_ID_BYTES`. Encoders enforce the limit, so normal paths match, but out-of-band use of a longer string diverges. | Minor consistency gap; fixing requires deciding whether Swift should mirror the C cap. |
| 10 | Low | `Sources/LabanCore/PTYLabClient.swift:653` | `fcntl(F_SETFD, FD_CLOEXEC)` return value is ignored. If it fails, the socket fd leaks across `exec`. | Rare failure mode; should be checked and treated as a connection error. |
| 11 | Low | `Sources/LabanCore/PTYLabClient.swift:165-186` | `resize`/`signal` accept any `Int` and rely on the daemon to reject out-of-range values, surfacing generic errors rather than clear client-side validation. | Quality-of-error issue, not a crash. |
| 12 | Low | `Sources/LabanCore/PTYLabClient.swift:517-523` | After `ensureDaemonRunning` respawns the daemon, only one connect attempt is made; if the daemon is slow to bind, the transient failure surfaces to the caller. | Could be retried with the same backoff used elsewhere. |
| 13 | Low | `Sources/LabanCore/PTYLabClient.swift:419-420` | Reconnect retry sleeps while holding the client lock, blocking other RPCs on that client for up to ~620 ms. | Architectural; releasing the lock during backoff would require restructuring the retry loop. |

### Tests / formal verification

| # | Severity | Finding |
|---|---|---|
| 14 | High (process) | `.github/workflows/check.yml` only runs `swift-format lint` and `swift build`. It does **not** run `swift test`, `scripts/check-specs`, `scripts/check-cbmc`, `scripts/check-trace`, or any of the other verification gates that `scripts/check` runs locally. The formal layer's health therefore depends entirely on local developer discipline. |
| 15 | Medium (process) | `LabptyOutputWake.tla` has no runtime trace binding (a binding commit exists in history but is not on `HEAD`). `LabptyAttachment.tla` does not model the park-reconnect attach action added in commit `6df049e6`. Both are covered by Swift integration tests, but the formal-to-code anchor is weaker than for other specs. |
| 16 | Low (coverage) | No dedicated test exercises the C degraded path where `ptsname_r()`/`open()` for the slave inspect fd fails (the R1 hangup-grace branch). The path is correct but unverified. |

---

## Formal verification status

Run locally on this checkout:

- `scripts/check-specs` — 21 TLC configs pass (10 positive + 11 negative controls).
- `scripts/check-cbmc` — all bounded proofs verify and negative controls refute.
- `scripts/check-trace` — attachment, reuse, and control-channel traces conform.
- `scripts/check-model-coverage` — all model actions exercised.
- `scripts/check-anchors` — passes.
- `scripts/check-fd-hygiene` — passes.

The formal layer is healthy locally. The risk is that CI does not run any of these gates.

---

## Recommendations

1. **CI expansion** — add a job to `.github/workflows/check.yml` that runs `swift test` and at least `scripts/check-specs`, `scripts/check-cbmc`, and `scripts/check-trace`. These are fast enough for per-PR gating.
2. **Restore output-wake trace binding** — either bring the historical `TraceOutputWake.tla`/`trace_output_wake.c` binding onto `HEAD` or remove/adjust the `// Modelled by` claim in `main.c` so it does not overstate trace coverage.
3. **Model park-reconnect attach** — add the `parkOutputWake` re-attach action to `LabptyAttachment.tla` and exercise it in `trace_attachment.c`.
4. **Harden `LabptyByteRingWriter`** — even though it is test-only today, it should mirror the daemon's `O_EXCL|O_NOFOLLOW` + `F_PREALLOCATE` contract so it cannot become a footgun if adopted for production use.
5. **Pin reader counters offset** — consider requiring `countersOffset == LabptyByteRingLayout.countersOffset` (or at least that it lies inside the declared header/counters region) to prevent a malicious ring from redirecting the reader's counters into data bytes.
6. **Reject embedded NULs in Swift strings** — align `LabptyPayloadReader.readString` with the daemon's `memchr` guard.
7. **Check `fcntl` return** — treat a failed `FD_CLOEXEC` as a connection error in `PTYLabClient.connect`.

---

## Files touched by this audit

- `Sources/Labpty/labpty_registry.c`
- `Sources/LabanCore/LabptyByteRingReader.swift`
- `Sources/LabanCore/PTYLabClient.swift`
- `docs/quality/labpty-audit-2026-07-10.md`
