-------------------------- MODULE LabptyStartup --------------------------
(****************************************************************************
 Labpty multi-daemon startup race on a shared Unix-domain socket path.

 What this spec covers
   Two (or more) labpty processes contending for the same `--socket`
   path. Each daemon walks an `init -> listening -> (dead)` lifecycle
   driven by Listen/Stop/Crash/Restart. The filesystem entry at the
   path is modelled as `dir_entry`: either NONE or pointing to one
   daemon's bound socket. A daemon's `bound` flag captures the
   in-kernel fact "this process holds a bind() to that path"; clients
   connecting to the path reach `dir_entry`'s daemon, not `bound`'s -
   and the bug is exactly that those two can diverge.

   The spec is parametrised by `UnconditionalUnlink`:

     FALSE -> probe-first (post-b5e7819): a daemon refuses to start if
              the path holds a live socket, and unlinks only stale
              sockets before binding.
     TRUE  -> unconditional (pre-b5e7819): every Listen() unlinks
              whatever is at the path before binding. A second daemon
              strands the first: its bind stays in-kernel but the path
              now resolves to the second daemon's socket, so existing
              sessions become unreachable via the path.

 Why TLA+ here
   This is a textbook concurrency bug: two processes against a shared
   filesystem name. The pathology is invisible in single-process
   testing because the second daemon's startup looks fine; it's the
   first daemon that gets stranded. Two-daemon interleavings on the
   shared (dir_entry, bound) pair are exactly what TLC enumerates.

 Companion module
   MC_StartupPreFix.cfg sets UnconditionalUnlink = TRUE and demonstrates
   that, without the b5e7819 fix, TLC finds the stranded-daemon
   counterexample. Same role as LabptyLifecyclePreF2 plays for the
   registry slot-leak.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    Daemons,             \* finite set of daemon process IDs (~ 2 is enough)
    MaxLifecycles,       \* per-daemon Listen-count bound for TLC finiteness
    UnconditionalUnlink  \* BOOLEAN; TRUE = pre-b5e7819 bug, FALSE = fix

ASSUME UnconditionalUnlink \in BOOLEAN
ASSUME MaxLifecycles \in 1..5

VARIABLES
    daemons,    \* Daemons -> {"init", "listening", "dead"}
    dir_entry,  \* Daemons \cup {"none"} - current owner of the path
    bound,      \* Daemons -> BOOLEAN     - daemon holds a bind() fd
    lifecycles  \* Daemons -> 0..MaxLifecycles - per-daemon Listen count

vars == << daemons, dir_entry, bound, lifecycles >>

DaemonStates == { "init", "listening", "dead" }
DirEntries   == Daemons \cup { "none" }

TypeOK ==
    /\ daemons    \in [ Daemons -> DaemonStates ]
    /\ dir_entry  \in DirEntries
    /\ bound      \in [ Daemons -> BOOLEAN ]
    /\ lifecycles \in [ Daemons -> 0..MaxLifecycles ]

Init ==
    /\ daemons    = [ d \in Daemons |-> "init" ]
    /\ dir_entry  = "none"
    /\ bound      = [ d \in Daemons |-> FALSE ]
    /\ lifecycles = [ d \in Daemons |-> 0 ]

\* ----------------------------------------------------------------------
\* Helpers
\* ----------------------------------------------------------------------

\* The C probe (connect(2)) succeeds iff some daemon is currently
\* listening *and* holds a kernel bind to that path. A stale dir_entry
\* (process crashed without unlink) yields ECONNREFUSED on probe, which
\* the fix correctly treats as "unlinkable, then re-bind".
SocketIsLive(owner) ==
    /\ owner # "none"
    /\ daemons[owner] = "listening"
    /\ bound[owner] = TRUE

\* ----------------------------------------------------------------------
\* Listen actions - one per spec variant. Listen selects via the
\* UnconditionalUnlink constant.
\* ----------------------------------------------------------------------

\* Buggy: unconditional unlink + bind. Whatever was at the path is gone;
\* the new daemon owns dir_entry. The previous daemon's `bound` flag is
\* untouched - that's the stranding.
Listen_Buggy(d) ==
    /\ daemons[d] = "init"
    /\ lifecycles[d] < MaxLifecycles
    /\ daemons'    = [ daemons    EXCEPT ![d] = "listening" ]
    /\ bound'      = [ bound      EXCEPT ![d] = TRUE ]
    /\ dir_entry'  = d
    /\ lifecycles' = [ lifecycles EXCEPT ![d] = lifecycles[d] + 1 ]

\* Fixed: probe-first.
\*   (a) Path is empty: clean bind.
\*   (b) Path holds a live socket: refuse to start.
\*   (c) Path holds a stale socket: unlink then bind.
Listen_Fixed(d) ==
    /\ daemons[d] = "init"
    /\ lifecycles[d] < MaxLifecycles
    /\ \/ \* (a) clean bind
          /\ dir_entry = "none"
          /\ daemons'    = [ daemons    EXCEPT ![d] = "listening" ]
          /\ bound'      = [ bound      EXCEPT ![d] = TRUE ]
          /\ dir_entry'  = d
          /\ lifecycles' = [ lifecycles EXCEPT ![d] = lifecycles[d] + 1 ]
       \/ \* (b) refuse - someone is already serving
          /\ dir_entry # "none"
          /\ SocketIsLive(dir_entry)
          /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
          /\ lifecycles' = [ lifecycles EXCEPT ![d] = lifecycles[d] + 1 ]
          /\ UNCHANGED << bound, dir_entry >>
       \/ \* (c) stale entry - unlink + bind
          /\ dir_entry # "none"
          /\ ~SocketIsLive(dir_entry)
          /\ daemons'    = [ daemons    EXCEPT ![d] = "listening" ]
          /\ bound'      = [ bound      EXCEPT ![d] = TRUE ]
          /\ dir_entry'  = d
          /\ lifecycles' = [ lifecycles EXCEPT ![d] = lifecycles[d] + 1 ]

Listen(d) ==
    IF UnconditionalUnlink THEN Listen_Buggy(d) ELSE Listen_Fixed(d)

\* ----------------------------------------------------------------------
\* Other lifecycle actions - identical between variants.
\* ----------------------------------------------------------------------

\* Stop: graceful shutdown - cleanup_daemon unlinks the path.
Stop(d) ==
    /\ daemons[d] = "listening"
    /\ daemons'   = [ daemons EXCEPT ![d] = "dead" ]
    /\ bound'     = [ bound   EXCEPT ![d] = FALSE ]
    /\ dir_entry' = IF dir_entry = d THEN "none" ELSE dir_entry
    /\ UNCHANGED lifecycles

\* Crash: ungraceful - the kernel reclaims the bind, but the directory
\* entry on disk persists (no unlink). The path becomes stale.
Crash(d) ==
    /\ daemons[d] = "listening"
    /\ daemons'   = [ daemons EXCEPT ![d] = "dead" ]
    /\ bound'     = [ bound   EXCEPT ![d] = FALSE ]
    /\ UNCHANGED << dir_entry, lifecycles >>

\* Restart: a dead daemon can return to init so TLC explores multi-cycle
\* interleavings within the MaxLifecycles bound.
Restart(d) ==
    /\ daemons[d] = "dead"
    /\ lifecycles[d] < MaxLifecycles
    /\ daemons' = [ daemons EXCEPT ![d] = "init" ]
    /\ UNCHANGED << dir_entry, bound, lifecycles >>

Next ==
    \/ \E d \in Daemons : Listen(d)
    \/ \E d \in Daemons : Stop(d)
    \/ \E d \in Daemons : Crash(d)
    \/ \E d \in Daemons : Restart(d)

Spec == Init /\ [][Next]_vars

\* ----------------------------------------------------------------------
\* Safety invariants
\* ----------------------------------------------------------------------

\* If a daemon is "listening" with a bound fd, the path on disk must
\* point at that daemon's socket. Otherwise the daemon is *serving but
\* unreachable via the path* - exactly the b5e7819 strand-the-live-
\* session bug. This is the invariant the fix restores.
ServingDaemonOwnsPath ==
    \A d \in Daemons :
        (daemons[d] = "listening" /\ bound[d] = TRUE) => dir_entry = d

\* No two daemons may both hold a live bind to the same path. Whether
\* the kernel would enforce this is irrelevant; the question is whether
\* the model lets two daemons believe they own the path simultaneously.
AtMostOneServing ==
    Cardinality({ d \in Daemons :
        daemons[d] = "listening" /\ bound[d] = TRUE }) <= 1

\* A bound fd implies the owning daemon is currently listening. Crash
\* and Stop both clear `bound`, so this should always hold.
BoundImpliesListening ==
    \A d \in Daemons : bound[d] = TRUE => daemons[d] = "listening"

\* `lifecycles` is monotonic by construction.
LifecyclesBounded ==
    \A d \in Daemons : lifecycles[d] \in 0..MaxLifecycles

=============================================================================
