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

Three further layers close the loop from spec to running code, each its own
section below: **runtime trace conformance** (`scripts/check-trace`) replays the
real daemon's transitions through the TLA+ models so `// Modelled by` is a
checked fact, not a claim; **mutation adequacy** (`scripts/check-{trace,cbmc}-
mutants`) injects faults and requires each check to catch them; and the **MC/DC
coverage gate** (`scripts/coverage-labpty`) ratchets decision coverage and runs
the `proofs/labpty/coverage/*_cov.c` assertion harnesses.

## What is modelled

| Spec | Mirrors | Key property |
| --- | --- | --- |
| `LabptyLifecycle.tla` | `Sources/Labpty/labpty_registry.c` session-slot state machine. | `EventualReleaseOfClosePending` (F2 fix), `DeadLeakNotPermanent` (commit 5420964 fix), `EventualReapOfZombie`. |
| `LabptyByteRing.tla` | `Sources/Labpty/labpty_byte_ring.c` single-producer / single-consumer ring with safety margin. | `NoTornRead`, `WindowDoesNotContainFutureWrites`. |
| `LabptyControlChannel.tla` | `Sources/Labpty/main.c` per-connection state machine (`labpty_client_t` slots, hello negotiation, slowloris reaper). | `EstablishedImpliesNegotiated` and `UnnegotiatedIdleIsNotPermanent` (commit 2aac41a fix). |
| `LabptyStartup.tla` | `Sources/Labpty/main.c::listen_unix_socket` multi-daemon race on the `--socket` path. | `ServingDaemonOwnsPath`, `AtMostOneServing` (commit b5e7819 fix). |
| `LabptyAttachment.tla` | `Sources/Labpty/main.c` per-session connected-client mask (`attached_clients`, `ATTACH`/`DETACH`, opener auto-attach, `client_release` scrub). | `AttachmentImpliesInUse` — no mask retains a departed client, so the count never overcounts an owner (ADR 0010). |
| `LabptyReuse.tla` | `Sources/Labpty/labpty_registry.c` `logical_id` reuse: `labpty_session_request_close` relinquishes the id at terminate; `labpty_registry_open` rejects only a still-held id. | `NotAliveImpliesIdRelinquished` (mechanism) and `TerminatedIdIsReusable` (contract) — a terminated logical_id is immediately reusable, not just eventually. `LabptyLifecycle.tla` has no `logical_id`, so it could not state this. |

Each module is paired with one or more `MC_*.tla` / `MC_*.cfg` harnesses
that constrain the state space for TLC. Configs come in two shapes:

- **Positive** (`MC.cfg`, `MC_Larger.cfg`, `MC_ControlChannel.cfg`,
  `MC_Attachment.cfg`, `MC_Startup.cfg`, `MC_Reuse.cfg`, `MC_ByteRing.cfg`,
  `MC_ByteRing_Larger.cfg`): the fix is in. TLC verifies the spec.
- **Negative-control** (`MC_PreF2.cfg`, `MC_PreSlotReclaim.cfg`,
  `MC_ControlChannelPreFix.cfg`, `MC_AttachmentPreFix.cfg`,
  `MC_StartupPreFix.cfg`, `MC_ReusePreFix.cfg`,
  `MC_ByteRingTorn.cfg`, `MC_ByteRing_Boundary.cfg`): the fix is not in
  (or a parameter is set unsafely — `MC_Reuse` and `MC_ReusePreFix` share
  one module and flip the `Fixed` constant). TLC is **required to find a
  counter-example**. The negative configs are permanent regression
  tests — if one silently starts passing, the bug-shape it documented
  is gone and someone has accidentally fixed the wrong thing.

## When to update a spec

Update a spec when you change the state machine it models. In practice:

| You changed | Update |
| --- | --- |
| `labpty_registry.c` actions on session slots | `LabptyLifecycle.tla` |
| `labpty_registry.c` `logical_id` reuse (`request_close` relinquish / `open` duplicate rule) | `LabptyReuse.tla` |
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
discharges, for `labpty_frame.c`, `labpty_protocol.c` and the byte-ring
writer in `labpty_byte_ring.c`:

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

The byte-ring writer has its own pair: `ring_proof.c::proof_byte_ring_write`
proves the wraparound write arithmetic (the `& (capacity-1)` split and the
over-capacity clamp) stays in bounds for any prior `output_offset` and a
small power-of-two capacity family, and `ring_negctl.c` pins the clamp. CBMC
owns only this **sequential index math**; the **cross-process ordering**
(`NoTornRead`, `WindowDoesNotContainFutureWrites`) stays with
`LabptyByteRing.tla`, because neither CBMC nor any sequential analysis models
the shared-memory release/acquire faithfully — the proof models the atomic
release store as a plain in-bounds store for exactly that reason.

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
`labpty_decode_write_input_request`, and `valid_utf8`. The first five are
loop-free (only the fixed 8-iteration read loop, covered by the small
`--unwind`); `valid_utf8` carries a **loop contract** (`i <= n`,
`decreases n - i`) after being made single-exit — its malformed-input paths
set a result flag and `break` instead of an early `return`, because CBMC loop
contracts support `break`/`goto` exits but not `return`. That refactor is
behaviour-preserving, checked by a 100M-input exhaustive differential against
the original logic plus the existing `LabptyTests`.

**Not contracted** — `labpty_decode_open_request`, `labpty_decode_hello_request`.
Their array loops call `read_string` and fill 2-D fixed aggregates, so an
unbounded proof needs a `read_string` cursor contract plus loop
invariants/`assigns` over those arrays — a larger effort. They stay covered by
the bounded proofs above and by the fuzzer at full input size. The path
forward is modular: make the loops single-exit, give `read_string` /
`labpty_read_bytes` a contract, and `--replace-call-with-contract` them.

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
- `scripts/fuzz-labpty --check-msan` replays the corpus under
  MemorySanitizer (uninitialized reads ASan misses). MSan is Linux-only —
  `-fsanitize=memory` is rejected on `arm64-apple-darwin` by every clang —
  so it self-skips on macOS and runs in Linux CI. Also wired into
  `scripts/check`.

A real campaign belongs on Linux/CI (AFL++'s macOS support is the weak
spot). Locally, `--check` always runs because it needs only the system
`cc` with ASan/UBSan.

## Runtime trace conformance (binding the C to the specs)

The TLA+ models prove the *spec* is correct; CBMC proves the *decoders* safe.
Neither proves the *daemon obeys its spec* — the `// Modelled by` anchors were
honour-system until `scripts/check-trace` closed the loop. It drives the **real**
daemon code through seeded-random operation sequences, captures the transitions
the daemon emits (`LABPTY_TRACE`), and replays them through the matching TLA+
model with TLC. A logged transition that is not a spec action makes TLC
deadlock; the safety invariants are checked on every observed state.

Three machines are bound, each fuzzed over many seeds (TLC replays all of a
machine's traces in one run) with a `-DLABPTY_TRACE_NEGCTL` negative control TLC
is **required to reject**:

| Binding | Spec | Harness (seeds) | Negative control |
| --- | --- | --- | --- |
| attachment | `LabptyAttachment.tla` | `proofs/labpty/trace/trace_attachment.c` (64) | skip the `client_release` scrub |
| reuse | `LabptyReuse.tla` | `proofs/labpty/trace/trace_reuse.c` (32) | keep the id while close_pending |
| control | `LabptyControlChannel.tla` | `proofs/labpty/trace/trace_control.c` (24) | establish on any round-trip |

The daemon emits only the **observable projection**: a model variable with no
daemon counterpart (the control channel's `frames_issued`, a TLC finiteness
bound) stays hidden and the spec lets it run free while pinning the observed
fields. Each `Trace<X>.tla` conjoins the **labelled** model action (`StepAction`),
so a fault that produces a different-but-valid action — an attach that wrongly
clears a bit, reading as a detach — is still caught.

`scripts/check-trace` is wired into `scripts/check` and self-skips to a
compile-only drift smoke without the TLA+ jar. `check-anchors` rule E refuses a
`Trace*.tla` or `proofs/labpty/trace/*.c` that `check-trace` does not run.

**When to update:** if you change a bound machine's observable transitions
(attachment masks; reuse open/terminate/reap; the control-channel
accept/hello/dispatch/write/expire cycle), update both the harness
(`proofs/labpty/trace/<machine>.c`) and `Trace<machine>.tla`, then re-run
`scripts/check-trace`. A new bound machine needs a `Trace<machine>.tla`, an
`MC_Trace<machine>.cfg`, a generator (`scripts/gen-<machine>-tla.py`), and a
`check-trace` stanza — `check-anchors` rule E enforces the last.

**Is the conformance meaningful?** Conformance is a refinement (daemon ⊆ model);
it says nothing about whether the seeds *exercise* the whole model.
`scripts/check-model-coverage` is the inverse check — it drives each binding's
seeds and asserts every model action appears at least once, so a transition the
fuzzer never reaches (and so never checks) fails loudly instead of passing
vacuously. It found `DispatchNonHelloNormal` — a negotiated client's second
round-trip — unreached across every control seed until a deterministic prelude
was added. Wired into `scripts/check`; fast (C runs + counting, no solver).

## Mutation adequacy (do the checks have teeth?)

A green proof or conformance run shows the check **passes** — not that it would
**catch a regression**. Two standalone runners inject faults into the real code
and require each to be rejected:

- `scripts/check-cbmc-mutants` mutates the byte-ring writer and frame decoders
  and requires each CBMC proof to report `VERIFICATION FAILED`.
- `scripts/check-trace-mutants` mutates the attachment / reuse / control code and
  requires the trace replay to reject the trace.

These are **deep** checks (a build + solver run per mutant) — run manually or in
deep CI, self-skipping without their tool, not in the fast `scripts/check`. A
**surviving** mutant is a real gap: the harness does not observe enough state, or
the property is too weak. Mutation-testing this layer is what surfaced that the
attachment binding could not tell attach from detach until each transition was
required to match its *labelled* action, and that the byte-ring proof covers
memory safety but not byte *placement* (that is `NoTornRead`'s job). When you add
a binding or proof, add a mutant the new check must catch.

## MC/DC coverage gate

`scripts/coverage-labpty` measures Modified Condition/Decision Coverage
(DO-178C DAL-A) of the daemon's un-proven decision code and ratchets it
(`--check N`), as the union of the integration suite and the deterministic
harnesses in `proofs/labpty/coverage/*_cov.c`. Those harnesses go beyond
coverage where it matters and double as **regression gates**:
`signal_cov.c` macro-stubs `killpg`/`kill` and asserts that no out-of-range
client-controlled signal number reaches the syscall (lesson L9), so reverting
that guard fails the harness. `poll_cov.c` binds the event loop's
poll-multiplexing layer — the last daemon layer with no formal binding, and a
data-structure consistency invariant rather than a state machine, so a proof
harness is the right tool, not a TLA+ trace binding: it asserts `build_poll_set`
emits a poll set whose every slot's `(fd, kind, index)` is consistent with the
daemon state, and `service_poll_watch` routes a slot's `revents` to the handler
at *that* slot's index — so a misrouting fault (a wrong stored index, a
kind/index mismatch, a fixed-index dispatch) fails the harness.

`coverage-labpty` is wired into `scripts/check` (macOS-only; skips without the
darwin profile runtime), and `check-anchors` rule F refuses an unwired `*_cov.c`.
Gating it is what turns a stale coverage assertion — like the `main_cov` drift
the `handle_write` hung-up-child fix introduced — into a check failure instead of
silent rot. See `docs/quality/labpty-mcdc-coverage.md` for the baseline, the
ratchet, and the infeasible-condition deviation record.
