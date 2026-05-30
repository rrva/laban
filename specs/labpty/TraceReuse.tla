----------------------------- MODULE TraceReuse -----------------------------
(****************************************************************************
 Runtime trace conformance: replay real labpty registry lifecycle traces
 through LabptyReuse and assert every logged transition is a spec action.

 This binds the bug-prone machine — the logical_id reuse path where the
 SESSION_ID_IN_USE race lived (the relinquish-at-terminate fix in
 labpty_session_request_close). proofs/labpty/trace/trace_reuse.c drives the
 REAL registry (labpty_registry_open / request_close / reap) through seeded
 random walks over open(id)/terminate/reap and emits the observable per-slot
 state (used, alive, close_pending, logical_id). scripts/check-trace generates
 the TraceReuseData module from the NDJSON of each run and runs this module.

 How the check works
   TInit picks a trace index tk nondeterministically and reconstructs
   LabptyReuse's `sessions` from that trace's first record (Init, all empty).
   TLC therefore explores EVERY seed's trace in one run. TNext steps to the
   next record AND conjoins Allowed: the logged transition must be an
   OpenSession, a Terminate, or a DaemonReap. If it is not (e.g. a terminate
   that keeps its id while close_pending), no action enables, the behaviour
   deadlocks before the trace is consumed, and TLC reports it — what
   scripts/check-trace asserts for the -DLABPTY_TRACE_NEGCTL negative control.
   The reuse safety invariants (NotAliveImpliesIdRelinquished,
   TerminatedIdIsReusable, ...) are checked on every reconstructed state.

 Abstraction
   The daemon's labpty_registry_reap is atomic where the model splits
   ChildDies then ReapTick. DaemonReap collapses both, batch-freeing every used
   close_pending slot — the same set ReapTick eventually frees. The model's
   transient `child = "zombie"` is never observed, so child is reconstructed as
   "running" while a slot is used and "none" when free.

 Fixed is TRUE (the correct, relinquish-at-terminate spec) in
 MC_TraceReuse.cfg; MaxSessions/Ids come from the generated TraceReuseData.
 ****************************************************************************)

EXTENDS LabptyReuse, TraceReuseData, Sequences

VARIABLES ti, tk

tvars == << sessions, ti, tk >>

CurTrace == Traces[tk]

\* Reconstruct `sessions` from a per-slot trace record (sequences over Slots).
Reconstruct(rec) ==
    [ s \in Slots |->
        Rec(rec.used[s], rec.alive[s],
            IF rec.used[s] = 1 THEN "running" ELSE "none",
            rec.cp[s], rec.lid[s]) ]

\* The daemon's atomic reap = the model's ChildDies then ReapTick, batched over
\* every used close_pending slot.
DaemonReap ==
    /\ \E s \in Slots : sessions[s].used = 1 /\ sessions[s].close_pending = 1
    /\ sessions' = [ s \in Slots |->
            IF sessions[s].used = 1 /\ sessions[s].close_pending = 1
            THEN Empty ELSE sessions[s] ]

Allowed == Next \/ DaemonReap

TInit ==
    /\ tk \in 1..Len(Traces)
    /\ ti = 1
    /\ sessions = Reconstruct(CurTrace[1])

TNext ==
    \/ /\ ti < Len(CurTrace)
       /\ ti' = ti + 1
       /\ tk' = tk
       /\ sessions' = Reconstruct(CurTrace[ti + 1])
       /\ Allowed   \* the logged step is an OpenSession / Terminate / DaemonReap
    \/ /\ ti = Len(CurTrace)
       /\ UNCHANGED tvars

TSpec == TInit /\ [][TNext]_tvars

\* Sanity guard surfaced as an invariant: the index never runs past its trace.
TraceIndexInRange == ti \in 1..Len(CurTrace)

=============================================================================
