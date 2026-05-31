# Stream Capture Hashes During Recording

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Long captures should finish without rereading hundreds of megabytes of PTY stream sidecars into memory. This change keeps each stream's byte count and SHA-256 digest up to date as bytes are recorded, so final manifest writing is constant-memory and does not depend on reopening stream files.

## Progress

- [x] Read the capture/debug process contract and `CaptureRecorder` finalization path.
- [x] Read existing recorder tests around byte offsets, hashes, and manifest finalization.
- [x] Add a regression proving manifest stream metadata comes from recorded state, not from rereading the stream sidecar at finish.
- [x] Add per-stream incremental SHA-256 state beside existing stream offsets.
- [x] Update stream hashers in `recordBytes` after successful writes.
- [x] Change manifest stream summaries to use recorded offsets and finalized hash state instead of `Data(contentsOf:)`.
- [x] Run focused recorder tests and the full package suite.

## Context and Orientation

`Sources/LabanDebug/CaptureRecorder.swift` writes capture artifacts. PTY bytes are appended to files under `streams/`, and the final `manifest.json` records the path, total byte count, and SHA-256 hash for each stream. Before this change, `streamManifest(_:)` opened each stream file and loaded the whole file into `Data` during `finish()`. That was simple but made finish time and peak memory scale with capture length.

The recorder already serializes state through an `NSLock`, and `recordBytes` updates `streamOffsets` under that lock. A `CryptoKit.SHA256` value can be updated incrementally with each `Data` chunk and finalized later without consuming the hasher, which fits the existing lock model.

## Plan of Work

Add a `streamHashers` dictionary keyed by `CaptureByteDirection`, initialize it with empty SHA-256 hashers for the three stream files, and update the relevant hasher inside `recordBytes` only after the byte write succeeds. Keep per-event chunk hashes unchanged because replay validates individual byte refs with those hashes.

Change `streamManifest(_:)` so it reads `streamOffsets[direction]` for the byte count and finalizes `streamHashers[direction]` for the stream hash. It should no longer call `Data(contentsOf:)` on the stream URL.

Add a regression in `Tests/LabanDebugTests/CaptureRecorderTests.swift`: write bytes to `pty-output`, remove read permission from that stream sidecar before `finish()`, then assert the manifest still reports the correct byte count and SHA-256. The old implementation would fail this because it could not reread the sidecar.

## Validation and Acceptance

Run from `/Users/dev/.codex/worktrees/4ba1/laban`:

```sh
rtk swift test --filter CaptureRecorderTests
rtk swift test
```

Acceptance: recorder tests pass, including the no-reread regression, and the full suite remains green.

Validated on 2026-05-05:

```sh
rtk swift test --filter CaptureRecorderTests
rtk swift test
```
