-------------------------- MODULE LabptyStartup --------------------------
(****************************************************************************
 Labpty multi-daemon startup and cleanup races on one Unix-domain socket path.

 Binding an AF_UNIX pathname publishes its directory entry before listen(2)
 makes connect(2) succeed. The production startup therefore has three visible
 phases: acquire an advisory lock, probe and bind, then publish a listening
 socket and release the lock. A second un-serialized daemon can probe the
 bound-not-listening entry, receive ECONNREFUSED, misclassify it as stale,
 unlink it, and strand the first daemon's bound socket.

 Constants select three permanent negative-control bug shapes:

   UnconditionalUnlink = TRUE
       Pre-b5e7819 startup removes a live daemon's socket without probing.

   SerializedStartup = FALSE
       Probe-first startup has no lock across bind -> listen, exposing the
       bound-not-listening stale-probe race.

   InodeValidatedCleanup = FALSE
       A closing predecessor unlinks a successor's newly rebound socket.

 The positive model sets all fixes: probe-first, serialized startup, and
 inode-validated cleanup.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    Daemons,
    MaxLifecycles,
    UnconditionalUnlink,
    SerializedStartup,
    InodeValidatedCleanup

ASSUME UnconditionalUnlink   \in BOOLEAN
ASSUME SerializedStartup     \in BOOLEAN
ASSUME InodeValidatedCleanup \in BOOLEAN
ASSUME MaxLifecycles \in 1..5

VARIABLES
    daemons,      \* Daemons -> lifecycle state
    dir_entry,    \* Daemons \cup {"none"}; pathname's current socket inode
    bound,        \* Daemons -> BOOLEAN; process holds a bound socket fd
    lifecycles,   \* Daemons -> startup-attempt count
    startup_lock  \* Daemons \cup {"none"}; advisory lock-file owner

vars == << daemons, dir_entry, bound, lifecycles, startup_lock >>

DaemonStates == { "init", "starting", "bound", "listening", "closing", "dead" }
DirEntries   == Daemons \cup { "none" }

TypeOK ==
    /\ daemons     \in [ Daemons -> DaemonStates ]
    /\ dir_entry   \in DirEntries
    /\ bound       \in [ Daemons -> BOOLEAN ]
    /\ lifecycles  \in [ Daemons -> 0..MaxLifecycles ]
    /\ startup_lock \in DirEntries

Init ==
    /\ daemons     = [ d \in Daemons |-> "init" ]
    /\ dir_entry   = "none"
    /\ bound       = [ d \in Daemons |-> FALSE ]
    /\ lifecycles  = [ d \in Daemons |-> 0 ]
    /\ startup_lock = "none"

SocketIsLive(owner) ==
    /\ owner # "none"
    /\ daemons[owner] = "listening"
    /\ bound[owner] = TRUE

ReleasedLock(d) ==
    IF SerializedStartup /\ startup_lock = d THEN "none" ELSE startup_lock

AcquireStartup(d) ==
    /\ daemons[d] = "init"
    /\ lifecycles[d] < MaxLifecycles
    /\ (~SerializedStartup \/ startup_lock = "none")
    /\ daemons' = [ daemons EXCEPT ![d] = "starting" ]
    /\ lifecycles' = [ lifecycles EXCEPT ![d] = lifecycles[d] + 1 ]
    /\ startup_lock' = IF SerializedStartup THEN d ELSE startup_lock
    /\ UNCHANGED << dir_entry, bound >>

ProbeAndBind_Buggy(d) ==
    /\ daemons[d] = "starting"
    /\ daemons'   = [ daemons EXCEPT ![d] = "bound" ]
    /\ bound'     = [ bound EXCEPT ![d] = TRUE ]
    /\ dir_entry' = d
    /\ UNCHANGED << lifecycles, startup_lock >>

ProbeAndBind_Fixed(d) ==
    /\ daemons[d] = "starting"
    /\ \/ /\ dir_entry = "none"
          /\ daemons'   = [ daemons EXCEPT ![d] = "bound" ]
          /\ bound'     = [ bound EXCEPT ![d] = TRUE ]
          /\ dir_entry' = d
          /\ UNCHANGED << lifecycles, startup_lock >>
       \/ /\ dir_entry # "none"
          /\ SocketIsLive(dir_entry)
          /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
          /\ startup_lock' = ReleasedLock(d)
          /\ UNCHANGED << dir_entry, bound, lifecycles >>
       \/ /\ dir_entry # "none"
          /\ ~SocketIsLive(dir_entry)
          /\ daemons'   = [ daemons EXCEPT ![d] = "bound" ]
          /\ bound'     = [ bound EXCEPT ![d] = TRUE ]
          /\ dir_entry' = d
          /\ UNCHANGED << lifecycles, startup_lock >>

ProbeAndBind(d) ==
    IF UnconditionalUnlink THEN ProbeAndBind_Buggy(d) ELSE ProbeAndBind_Fixed(d)

PublishListen(d) ==
    /\ daemons[d] = "bound"
    /\ bound[d] = TRUE
    /\ daemons' = [ daemons EXCEPT ![d] = "listening" ]
    /\ startup_lock' = ReleasedLock(d)
    /\ UNCHANGED << dir_entry, bound, lifecycles >>

CloseListen(d) ==
    /\ daemons[d] = "listening"
    /\ bound[d] = TRUE
    /\ daemons' = [ daemons EXCEPT ![d] = "closing" ]
    /\ bound'   = [ bound EXCEPT ![d] = FALSE ]
    /\ UNCHANGED << dir_entry, lifecycles, startup_lock >>

UnlinkPath(d) ==
    /\ daemons[d] = "closing"
    /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
    /\ dir_entry' =
          IF InodeValidatedCleanup /\ dir_entry # d THEN dir_entry
          ELSE "none"
    /\ UNCHANGED << bound, lifecycles, startup_lock >>

Stop(d) ==
    /\ daemons[d] = "listening"
    /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
    /\ bound'   = [ bound EXCEPT ![d] = FALSE ]
    /\ dir_entry' = IF dir_entry = d THEN "none" ELSE dir_entry
    /\ UNCHANGED << lifecycles, startup_lock >>

CrashListening(d) ==
    /\ daemons[d] = "listening"
    /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
    /\ bound'   = [ bound EXCEPT ![d] = FALSE ]
    /\ UNCHANGED << dir_entry, lifecycles, startup_lock >>

CrashStartup(d) ==
    /\ daemons[d] \in { "starting", "bound" }
    /\ daemons' = [ daemons EXCEPT ![d] = "dead" ]
    /\ bound'   = [ bound EXCEPT ![d] = FALSE ]
    /\ startup_lock' = ReleasedLock(d)
    /\ UNCHANGED << dir_entry, lifecycles >>

Restart(d) ==
    /\ daemons[d] = "dead"
    /\ lifecycles[d] < MaxLifecycles
    /\ daemons' = [ daemons EXCEPT ![d] = "init" ]
    /\ UNCHANGED << dir_entry, bound, lifecycles, startup_lock >>

Next ==
    \/ \E d \in Daemons : AcquireStartup(d)
    \/ \E d \in Daemons : ProbeAndBind(d)
    \/ \E d \in Daemons : PublishListen(d)
    \/ \E d \in Daemons : CloseListen(d)
    \/ \E d \in Daemons : UnlinkPath(d)
    \/ \E d \in Daemons : Stop(d)
    \/ \E d \in Daemons : CrashListening(d)
    \/ \E d \in Daemons : CrashStartup(d)
    \/ \E d \in Daemons : Restart(d)

Spec == Init /\ [][Next]_vars

ServingDaemonOwnsPath ==
    \A d \in Daemons :
        (daemons[d] = "listening" /\ bound[d] = TRUE) => dir_entry = d

AtMostOneServing ==
    Cardinality({ d \in Daemons :
        daemons[d] = "listening" /\ bound[d] = TRUE }) <= 1

AtMostOneBoundSocket ==
    Cardinality({ d \in Daemons : bound[d] = TRUE }) <= 1

BoundImpliesStartupOrListening ==
    \A d \in Daemons : bound[d] = TRUE => daemons[d] \in { "bound", "listening" }

SerializedLockMatchesStarter ==
    SerializedStartup /\ startup_lock # "none"
        => daemons[startup_lock] \in { "starting", "bound" }

LifecyclesBounded ==
    \A d \in Daemons : lifecycles[d] \in 0..MaxLifecycles

=============================================================================
