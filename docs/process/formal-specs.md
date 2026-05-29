# Formal Specs

`specs/labpty/` holds TLA+ models of labpty state machines whose
correctness is hard to verify by integration testing alone. Each model
mirrors a specific area of the C/Swift code and is exhaustively checked
by TLC. `scripts/check-specs` runs every config and is wired into
`scripts/check`; CI fails on any mismatch.

A second formal layer lives in `proofs/labpty/`: CBMC bounded-model-
checking harnesses that prove the wire-format decoders memory-safe on
untrusted socket input. TLA+ reasons about the state machines; CBMC
reasons about the C that parses bytes at the trust boundary. See
[Bounded model checking (CBMC)](#bounded-model-checking-cbmc) below.

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
- Deep memory safety of the wire-format decoders — that is proven
  separately by the CBMC harnesses in `proofs/labpty/` (see below). The
  `-fbounds-safety` annotations and
  `Tools/LabptyCodingRules/check_bounds_safety_headers.sh` enforce the
  boundary annotations those proofs and the daemon rely on.
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

## Bounded model checking (CBMC)

`proofs/labpty/` holds CBMC harnesses that prove the labpty wire-format
decoders memory-safe and contract-correct on untrusted input. Every byte
they consume comes from a client socket, so this is the daemon's trust
boundary. CBMC explores **all** inputs up to a small length bound and
discharges, for `labpty_frame.c` and `labpty_protocol.c`:

- no out-of-bounds read or write, no invalid/NULL pointer, no use of a
  freed or dead object (`--bounds-check --pointer-check
  --pointer-primitive-check`);
- no undefined behaviour: signed overflow, pointer overflow, out-of-range
  shift, divide-by-zero;
- value contracts the rest of the daemon relies on: decoded `frame_len`
  in `[FRAME_HEADER_BYTES, MAX_FRAME]`, the write-input slice fully
  contained in the request buffer, decoded strings NUL-terminated within
  their fixed-size field.

This is the C-tier analogue of the TLA+ models: bounded, exhaustive,
counterexample-producing.

`--unsigned-overflow-check` and `--conversion-check` are deliberately
off. The decoders reinterpret fixed-width little-endian words by design
(modular assembly of u16/u32/u64; the u32↔i32 reinterpret of the signal
number in `labpty_read_i32`). Genuine narrowing is guarded in-code
instead — the `len > UINT32_MAX` check in `write_string`, the masking in
`labpty_read_u16`.

### Positive proofs and negative controls

Like the `MC_*` configs, the harnesses come in two shapes:

- **Positive** (`proof_*` in `frame_proof.c`): CBMC must report
  `VERIFICATION SUCCESSFUL`.
- **Negative-control** (`negctl_*` in `frame_negctl.c`): each reintroduces
  exactly one removed guard — the `len < FRAME_HEADER_BYTES` check in
  header decode, the `i + k >= n` lookahead bounds in the UTF-8 validator
  — and CBMC is **required to find a counter-example**. They prove the
  harness and checker can still see that class of bug, so a green positive
  proof is not vacuous. This is the same discipline the `MC_*PreFix` /
  `*Torn` configs enforce for the TLA+ models: if a negative control
  silently starts verifying, a guard's proof has gone vacuous and someone
  has weakened it.

`proof_decode_open` and `proof_decode_hello` are present in
`frame_proof.c` but **not gated**: both read input only through primitives
already proven (`labpty_read_*`, `read_string`, `valid_utf8`) and add only
array-loop iteration bounded by explicit `> max_count` guards, while their
large fixed output aggregates (open's ~1.4 MB struct; hello's
`capabilities[64][65]`) make the BMC formula intractable at a useful
unwind. They stay compilable so the drift smoke catches signature changes,
and can be run on demand with a long timeout.

### Running it

`scripts/check-cbmc` runs every gated harness with its `--function`,
`--unwind` and check flags, asserts the expected outcome, and is wired
into `scripts/check`. It needs `cbmc` on PATH (`brew install cbmc`); the
full sweep finishes in a few seconds.

When `cbmc` is absent the script degrades to a **compile-only drift
smoke**: it compiles every harness against the current decoder source
through a stub `proofs/labpty/stubs/LabanTerminalCore.h`, so a decoder
signature or type change can never silently rot the proof even on a
machine without CBMC. CI installs `cbmc`, so the real proofs run there.

### When to update a proof

| You changed | Update |
| --- | --- |
| A `labpty_decode_*` decoder, `read_string`, or `valid_utf8` | the matching `proof_*` in `frame_proof.c` |
| A guard whose removal is a known bug-shape | add or adjust a `negctl_*` in `frame_negctl.c` |

Key decoder symbols carry a `// Proven by proofs/labpty/...` anchor
comment, mirroring the TLA+ `// Modelled by specs/...` anchors.

### Unbounded proofs via contracts (DFCC)

The bounded harnesses above are exhaustive only up to a small `--unwind`.
`scripts/check-cbmc-contracts` removes that bound for the loop-free
decoders using CBMC **code contracts** and **dynamic frame condition
checking (DFCC)**: it proves them memory-safe and contract-correct for
**every input length**, not just up to ~26 bytes.

The contracts are zero-cost `__CPROVER_*` annotations written directly on
the real decoders — gated by `-DLABPTY_CONTRACTS` through
`Sources/Labpty/include/labpty_contracts.h`, exactly like the
`-fbounds-safety` `__sized_by` annotations next to them. With the macro
disabled (every normal build, the bounded proofs, the fuzzer) they expand
to nothing, so the proof binds to production code without changing it. For
example `labpty_decode_header` carries:

```c
LABPTY_REQUIRES(__CPROVER_is_fresh(bytes, len))
LABPTY_REQUIRES(__CPROVER_is_fresh(out, sizeof(*out)))
LABPTY_ASSIGNS(*out)
LABPTY_ENSURES(__CPROVER_return_value == LABPTY_OK ==>
               (out->frame_len >= LABPTY_FRAME_HEADER_BYTES &&
                out->frame_len <= LABPTY_MAX_FRAME && out->abi_major == 1))
```

`__CPROVER_is_fresh(bytes, len)` says "for an arbitrary, unbounded `len`,
treat `bytes` as a fresh readable object of exactly that size" — so the
proof covers all lengths at once. The pipeline is `goto-cc` →
`goto-instrument --dfcc main --enforce-contract <fn> --apply-loop-contracts`
→ `cbmc`; the small `--unwind` only covers the fixed 8-iteration
little-endian read loops, which are bounded by construction.

Contracted (unbounded): `labpty_decode_header`, `labpty_decode_resize_request`,
`labpty_decode_signal_request`, `labpty_decode_handle_request`,
`labpty_decode_write_input_request`.

**Not contracted** — `valid_utf8`, `labpty_decode_open_request`,
`labpty_decode_hello_request`. Their own loops use early `return` on the
error path, and CBMC loop contracts do not cleanly support early `return`
(only `break`/`goto` exits); contracting them would mean refactoring the
loops to single-exit, a behaviour-touching change. They stay covered by
the bounded proofs above and by the fuzzer at full input size. The next
step for them is modular: give `read_string` / `labpty_read_bytes` a
contract and `--replace-call-with-contract` them, after the loops are made
single-exit.

`scripts/check-cbmc-contracts` is wired into `scripts/check` and self-skips
when `cbmc`/`goto-cc` are absent.

### Fuzzing the decoders (dynamic complement)

CBMC is exhaustive but only up to a small input bound. The
`proofs/labpty/fuzz/` harness covers the other half: it runs the **real**
decoders at **full input size** under AddressSanitizer + UBSan — the
large-payload paths that are intractable for bounded model checking
(open's argv/envp arrays, hello's capability list, 64 KB write-input).
This is dynamic testing, not a proof, but it closes CBMC's bound and the
two together harden the whole trust boundary.

`fuzz_decoders.c` defines the libFuzzer ABI entry point
`LLVMFuzzerTestOneInput`, which AFL++, libFuzzer, Honggfuzz and Centipede
all consume — so the harness is engine-portable and outlives any single
tool. `make_seeds.py` generates the committed seed corpus under `corpus/`
(input layout: a selector byte then the op payload).

`scripts/fuzz-labpty` drives it:

- `scripts/fuzz-labpty [seconds]` runs a campaign, **preferring AFL++**
  (the actively maintained engine), then libFuzzer (in upstream
  maintenance mode, but a drop-in via the shared ABI). Discovered inputs
  and crashes go to the gitignored `findings/`; the committed seeds stay
  curated.
- `scripts/fuzz-labpty --check` builds the harness under ASan/UBSan and
  replays the seed corpus once — deterministic and engine-independent.
  This is the form wired into `scripts/check`, and the fallback when no
  fuzzing engine is installed. It doubles as a drift guard: a decoder
  signature change breaks the build here.

A real campaign belongs on Linux/CI (AFL++'s macOS support is the weak
spot). Locally, `--check` always runs because it needs only the system
`cc` with ASan/UBSan.
