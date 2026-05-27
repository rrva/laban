----------------------- MODULE LabptyLifecyclePreF2 -----------------------
(****************************************************************************
 Negative-control variant of LabptyLifecycle.
 Same state space and actions, but ReapTick does NOT release a close_pending
 slot — reproducing the pre-F2 (slot-leak) behavior in
 `Sources/Labpty/labpty_registry.c`. TLC should find a counterexample to
 EventualReleaseOfClosePending, confirming the F2-property in the production
 spec really measures what we think it measures.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS MaxSessions, MaxOpens

VARIABLES sessions, next_handle
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

OpenSession(slot) ==
    /\ sessions[slot].used = 0
    /\ next_handle < MaxOpens
    /\ sessions' = [ sessions EXCEPT ![slot] = SessionRecord(1, 1, "running", 0, next_handle + 1) ]
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
    /\ sessions' = [ sessions EXCEPT ![slot] = SessionRecord(1, 0, "running", 1, sessions[slot].handle) ]
    /\ UNCHANGED next_handle

\* PRE-F2 REAP: even on a close_pending slot, just clear child and alive
\* — do not release the slot. This mirrors the original
\* labpty_registry_reap behavior before the F2 fix.
ReapTickPreF2 ==
    /\ sessions' = [ s \in Slots |->
            IF sessions[s].used = 1 /\ sessions[s].child = "zombie"
            THEN [ sessions[s] EXCEPT !.child = "none", !.alive = 0 ]
            ELSE sessions[s] ]
    /\ UNCHANGED next_handle

ReapTickEnabled ==
    \E s \in Slots : sessions[s].used = 1 /\ sessions[s].child = "zombie"

ChildDeathUnderKill(s) ==
    /\ sessions[s].close_pending = 1
    /\ sessions[s].child = "running"
    /\ ChildDiesNaturally(s)

Next ==
    \/ \E s \in Slots : OpenSession(s)
    \/ \E s \in Slots : ChildDiesNaturally(s)
    \/ \E s \in Slots : TerminateFast(s)
    \/ \E s \in Slots : TerminateSlow(s)
    \/ (ReapTickEnabled /\ ReapTickPreF2)

Fairness ==
    /\ WF_vars(ReapTickPreF2 /\ ReapTickEnabled)
    /\ \A s \in Slots : WF_vars(ChildDeathUnderKill(s))

Spec == Init /\ [][Next]_vars /\ Fairness

\* Liveness property: should FAIL under pre-F2 behavior, because a slot
\* that hits TerminateSlow → child dies → reap clears child/alive but
\* not used, and nothing else transitions it back to used=0 unless the
\* client retries terminate. TLC's counterexample is exactly the slot
\* leak.
EventualReleaseOfClosePending ==
    \A s \in Slots :
        [] (sessions[s].close_pending = 1 ~> sessions[s].used = 0)

===========================================================================
