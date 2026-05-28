# Formal Specs

`specs/labpty/` holds TLA+ models of labpty state machines whose
correctness is hard to verify by integration testing alone. Each model
mirrors a specific area of the C/Swift code and is exhaustively checked
by TLC. `scripts/check-specs` runs every config and is wired into
`scripts/check`; CI fails on any mismatch.

## What is modelled

| Spec | Mirrors | Key property |
| --- | --- | --- |
| `LabptyLifecycle.tla` | `Sources/Labpty/labpty_registry.c` session-slot state machine. | `EventualReleaseOfClosePending` (F2 fix), `DeadLeakNotPermanent` (commit 5420964 fix), `EventualReapOfZombie`. |
| `LabptyByteRing.tla` | `Sources/Labpty/labpty_byte_ring.c` single-producer / single-consumer ring with safety margin. | `NoTornRead`, `WindowDoesNotContainFutureWrites`. |
| `LabptyControlChannel.tla` | `Sources/Labpty/main.c` per-connection state machine (`labpty_client_t` slots, hello negotiation, slowloris reaper). | `EstablishedImpliesNegotiated` and `UnnegotiatedIdleIsNotPermanent` (commit 2aac41a fix). |
| `LabptyStartup.tla` | `Sources/Labpty/main.c::listen_unix_socket` multi-daemon race on the `--socket` path. | `ServingDaemonOwnsPath`, `AtMostOneServing` (commit b5e7819 fix). |
| `LabptyAttachment.tla` | `Sources/Labpty/main.c` per-session connected-client mask (`attached_clients`, `ATTACH`/`DETACH`, opener auto-attach, `client_release` scrub). | `AttachmentImpliesInUse` — no mask retains a departed client, so the count never overcounts an owner (ADR 0010). |

Each module is paired with one or more `MC_*.tla` / `MC_*.cfg` harnesses
that constrain the state space for TLC. Configs come in two shapes:

- **Positive** (`MC.cfg`, `MC_Larger.cfg`, `MC_ControlChannel.cfg`,
  `MC_Attachment.cfg`, `MC_Startup.cfg`, `MC_ByteRing.cfg`,
  `MC_ByteRing_Larger.cfg`): the fix is in. TLC verifies the spec.
- **Negative-control** (`MC_PreF2.cfg`, `MC_PreSlotReclaim.cfg`,
  `MC_ControlChannelPreFix.cfg`, `MC_AttachmentPreFix.cfg`,
  `MC_StartupPreFix.cfg`,
  `MC_ByteRingTorn.cfg`, `MC_ByteRing_Boundary.cfg`): the fix is not in
  (or a parameter is set unsafely). TLC is **required to find a
  counter-example**. The negative configs are permanent regression
  tests — if one silently starts passing, the bug-shape it documented
  is gone and someone has accidentally fixed the wrong thing.

## When to update a spec

Update a spec when you change the state machine it models. In practice:

| You changed | Update |
| --- | --- |
| `labpty_registry.c` actions on session slots | `LabptyLifecycle.tla` |
| `labpty_byte_ring.c` write/read or layout fields | `LabptyByteRing.tla` |
| `main.c::labpty_client_t` fields, transitions, or expire policy | `LabptyControlChannel.tla` |
| `main.c` session attachment (`attached_clients`, attach/detach, `client_release` scrub) | `LabptyAttachment.tla` |
| `main.c::listen_unix_socket` startup sequence | `LabptyStartup.tla` |

The C symbols modelled by each spec carry a `// Modelled by specs/...`
anchor comment. If you change a symbol and the corresponding spec
doesn't change, you have either (a) made a refactor that preserves the
state machine — fine, leave the spec alone — or (b) changed the state
machine, in which case the spec must move with the code.

## When to ship a negative-control companion

When you fix a bug that lives inside a modelled state machine:

1. Reproduce the bug in the spec first (TLC should find a
   counter-example to a property you can name).
2. If the existing spec doesn't catch it, the spec was wrong or
   incomplete. Update the spec until it does, then make sure the
   counter-example matches the field-observed shape.
3. Ship a `LabptyXxxPre<descriptor>.tla` companion module that
   reproduces the bug. Wire its config into `scripts/check-specs`
   under the negative-control list.

The negative-control pattern is what keeps the proof honest. Without
it, future refactors can silently weaken the model.

## What is **not** in scope for TLA+

The specs catch state-machine and concurrency bugs. They do **not**
catch:

- Wire-format additive evolution. Use property-based tests (see
  `Tests/LabptyTests/LabptyDaemonTests.swift::testFixedShapeRequestsTolerateTrailingAdditiveBytes`).
- Resource hygiene like `FD_CLOEXEC` or `mlock`. Those live below the
  abstraction.
- Memory safety. The C boundary uses `-fbounds-safety` annotations and
  `Tools/LabptyCodingRules/check_bounds_safety_headers.sh`.
- Performance. Use the benches under `Tools/`.

Keep the scope honest; the specs are a sharp tool aimed at one class of
bugs, not a panacea.

## Running TLC locally

```sh
# Default jar location:
/Applications/TLA+ Toolbox.app/Contents/Eclipse/tla2tools.jar

# Or set TLA_JAR:
TLA_JAR=/path/to/tla2tools.jar ./scripts/check-specs
```

If the jar is absent, `scripts/check` skips the spec run with a notice.
CI sets `TLA_JAR` explicitly, so missing-jar there is a hard failure.

Each config runs in under a second on the existing parameters; the full
sweep finishes in well under a minute.
