-------------------------- MODULE LabptyLifecycle --------------------------
(****************************************************************************
 Labpty session-registry lifecycle, modelled for TLC.

 What this spec covers
   The state machine of a single labpty session slot across all interleavings
   of (open, terminate-fast, terminate-slow, child-dies-naturally, reap-tick).
   It mirrors the abstract structure of `labpty_session_t` and the routines
   in `Sources/Labpty/labpty_registry.c`:

     - used           : 1 while the slot is allocated to a logical session
     - alive          : 1 while the session can serve client RPCs
     - child          : "none" | "running" | "zombie" — child process state
     - close_pending  : 1 when labpty_session_close ran but the child outlived
                        the SIGKILL wait, deferring slot cleanup to reap

 Why TLA+ here
   The daemon is single-threaded server-side, so shared-memory races are out
   of scope; sanitizers already proved them absent. What remains, and what
   TLA+ excels at, is exhaustive checking of the *temporal interleaving* of
   external events with daemon ticks. Specifically:

     - Safety: does the (used, alive, child, close_pending) tuple ever reach
       an inconsistent state under any interleaving?
     - Liveness: does every close_pending eventually transition to ~used,
       given fair scheduling of the reap tick? This is the property that F2
       added — TLC proves it holds here. The companion LabptyLifecyclePreF2
       module demonstrates that, without the F2 fix, TLC finds the exact
       slot-leak counterexample.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    MaxSessions,   \* slots in the registry; LABPTY_MAX_SESSIONS=64 in production
    MaxOpens       \* total opens allowed (bounds next_handle so TLC is finite)

VARIABLES
    sessions,      \* slot_id -> session record
    next_handle    \* monotonic handle counter, bounded by MaxOpens

vars == << sessions, next_handle >>

Slots == 1..MaxSessions
ChildStates == { "none", "running", "zombie" }

SessionRecord(used, alive, child, close_pending, handle) ==
    [ used |-> used, alive |-> alive, child |-> child,
      close_pending |-> close_pending, handle |-> handle ]

EmptySlot == SessionRecord(0, 0, "none", 0, 0)

TypeOK ==
    /\ sessions \in [ Slots -> [ used : 0..1, alive : 0..1,
                                  child : ChildStates,
                                  close_pending : 0..1,
                                  handle : 0..MaxOpens ] ]
    /\ next_handle \in 0..MaxOpens

Init ==
    /\ sessions = [ s \in Slots |-> EmptySlot ]
    /\ next_handle = 0

\* ----------------------------------------------------------------------
\* Actions
\* ----------------------------------------------------------------------

OpenSession(slot) ==
    /\ sessions[slot].used = 0
    /\ next_handle < MaxOpens
    /\ sessions' = [ sessions EXCEPT ![slot] =
            SessionRecord(1, 1, "running", 0, next_handle + 1) ]
    /\ next_handle' = next_handle + 1

ChildDiesNaturally(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].child = "running"
    /\ sessions' = [ sessions EXCEPT ![slot].child = "zombie" ]
    /\ UNCHANGED next_handle

TerminateFast(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions' = [ sessions EXCEPT ![slot] = EmptySlot ]
    /\ UNCHANGED next_handle

TerminateSlow(slot) ==
    /\ sessions[slot].used = 1
    /\ sessions[slot].child = "running"
    /\ sessions' = [ sessions EXCEPT ![slot] =
            SessionRecord(1, 0, "running", 1, sessions[slot].handle) ]
    /\ UNCHANGED next_handle

\* labpty_registry_reap: zombie children are reaped. F2 fix: if the slot
\* is close_pending, finish the cleanup; otherwise mark child gone and
\* alive=0 but keep the slot used (the "outlive child exit" semantic).
ReapTick ==
    /\ sessions' = [ s \in Slots |->
            IF sessions[s].used = 1 /\ sessions[s].child = "zombie"
            THEN IF sessions[s].close_pending = 1
                 THEN EmptySlot
                 ELSE [ sessions[s] EXCEPT !.child = "none", !.alive = 0 ]
            ELSE sessions[s] ]
    /\ UNCHANGED next_handle

ReapTickEnabled ==
    \E s \in Slots : sessions[s].used = 1 /\ sessions[s].child = "zombie"

\* Fairness: SIGKILL-issued children eventually die (OS contract).
ChildDeathUnderKill(s) ==
    /\ sessions[s].close_pending = 1
    /\ sessions[s].child = "running"
    /\ ChildDiesNaturally(s)

Next ==
    \/ \E s \in Slots : OpenSession(s)
    \/ \E s \in Slots : ChildDiesNaturally(s)
    \/ \E s \in Slots : TerminateFast(s)
    \/ \E s \in Slots : TerminateSlow(s)
    \/ (ReapTickEnabled /\ ReapTick)

Fairness ==
    /\ WF_vars(ReapTick /\ ReapTickEnabled)
    /\ \A s \in Slots : WF_vars(ChildDeathUnderKill(s))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ----------------------------------------------------------------------
\* Safety invariants
\* ----------------------------------------------------------------------

FreeSlotIsClean ==
    \A s \in Slots :
        sessions[s].used = 0 =>
            /\ sessions[s].alive = 0
            /\ sessions[s].child = "none"
            /\ sessions[s].close_pending = 0
            /\ sessions[s].handle = 0

ClosePendingImpliesNotAlive ==
    \A s \in Slots :
        sessions[s].close_pending = 1 => sessions[s].alive = 0

UsedImpliesValidChild ==
    \A s \in Slots :
        sessions[s].used = 1 => sessions[s].child \in ChildStates

HandlesAreUnique ==
    \A a, b \in Slots :
        (a # b /\ sessions[a].used = 1 /\ sessions[b].used = 1) =>
            sessions[a].handle # sessions[b].handle

\* ----------------------------------------------------------------------
\* Liveness properties
\* ----------------------------------------------------------------------

EventualReleaseOfClosePending ==
    \A s \in Slots :
        [] (sessions[s].close_pending = 1 ~> sessions[s].used = 0)

EventualReapOfZombie ==
    \A s \in Slots :
        [] (sessions[s].child = "zombie" ~> sessions[s].child # "zombie")

=============================================================================
