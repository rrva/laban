-------------------------- MODULE TraceAttachment --------------------------
(****************************************************************************
 Runtime trace conformance: replay a real labpty daemon's attachment trace
 through LabptyAttachment and assert every logged transition is a spec action.

 This is the binding that turns "// Modelled by LabptyAttachment.tla" in
 Sources/Labpty/main.c from a claim into a checked fact. The daemon's
 labpty_trace_emit (gated on LABPTY_TRACE) appends one record per attachment
 transition — inUse (connected client slots), alive (used session slots),
 attached (the attached_clients bitmask) — and scripts/check-trace generates
 the TraceData module below from that NDJSON, then runs this module.

 How the check works
   TInit pins the model variables to Trace[1] (the all-zero Init the daemon
   emits before its first Connect). TNext steps to the next trace record AND
   conjoins LabptyAttachment!Next: the logged transition must be one the spec
   permits. If it is not (e.g. a disconnect that fails to scrub a departed
   client's bit), no action enables, the behaviour deadlocks before the trace
   is consumed, and TLC reports it — exactly what scripts/check-trace asserts
   for the -DLABPTY_TRACE_NEGCTL negative-control trace. A conformant trace
   reaches the end, where the absorb step stutters so the consumed trace is
   not mistaken for a deadlock.

 Trace, TraceClients, TraceSessions come from the generated TraceData module;
 Clients/Sessions are overridden to those in MC_TraceAttachment.cfg.
 ****************************************************************************)

EXTENDS LabptyAttachment, TraceData, Sequences

VARIABLE ti

tvars == << inUse, alive, attached, ti >>

\* Reconstruct the model's function-shaped variables from a trace record's
\* compact set form. A session absent from `attached`'s domain carries {}.
ModelInUse(rec)    == [ c \in Clients  |-> IF c \in rec.inUse THEN 1 ELSE 0 ]
ModelAlive(rec)    == [ s \in Sessions |-> IF s \in rec.alive THEN 1 ELSE 0 ]
ModelAttached(rec) ==
    [ s \in Sessions |-> IF s \in DOMAIN rec.attached THEN rec.attached[s] ELSE {} ]

AtTrace(i) ==
    /\ inUse    = ModelInUse(Trace[i])
    /\ alive    = ModelAlive(Trace[i])
    /\ attached = ModelAttached(Trace[i])

TInit ==
    /\ ti = 1
    /\ AtTrace(1)

TNext ==
    \/ /\ ti < Len(Trace)
       /\ ti' = ti + 1
       /\ inUse'    = ModelInUse(Trace[ti + 1])
       /\ alive'    = ModelAlive(Trace[ti + 1])
       /\ attached' = ModelAttached(Trace[ti + 1])
       /\ Next   \* the logged step must be a LabptyAttachment action
    \/ /\ ti = Len(Trace)
       /\ UNCHANGED tvars

TSpec == TInit /\ [][TNext]_tvars

\* Sanity guard surfaced as an invariant: the index never runs past the trace.
TraceIndexInRange == ti \in 1..Len(Trace)

=============================================================================
