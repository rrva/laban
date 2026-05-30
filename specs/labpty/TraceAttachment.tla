-------------------------- MODULE TraceAttachment --------------------------
(****************************************************************************
 Runtime trace conformance: replay real labpty daemon attachment traces
 through LabptyAttachment and assert every logged transition is a spec action.

 This is the binding that turns "// Modelled by LabptyAttachment.tla" in
 Sources/Labpty/main.c from a claim into a checked fact. The daemon's
 labpty_trace_emit (gated on LABPTY_TRACE) appends one record per attachment
 transition — inUse (connected client slots), alive (used session slots),
 attached (the attached_clients bitmask) — and scripts/check-trace runs the
 harness under many seeds, generating the TraceData module below from the
 NDJSON of each run.

 How the check works
   TInit picks a trace index tk nondeterministically and pins the model
   variables to that trace's first record (the all-zero Init the daemon emits
   before its first Connect). TLC therefore explores EVERY seed's trace in a
   single run. TNext steps to the next record of the chosen trace AND conjoins
   LabptyAttachment!Next: the logged transition must be one the spec permits.
   If it is not (e.g. a disconnect that fails to scrub a departed client's
   bit), no action enables, the behaviour deadlocks before the trace is
   consumed, and TLC reports it — exactly what scripts/check-trace asserts for
   the -DLABPTY_TRACE_NEGCTL negative-control trace. A conformant trace reaches
   its end, where the absorb step stutters so the consumed trace is not
   mistaken for a deadlock.

 Traces, TraceClients, TraceSessions come from the generated TraceData module;
 Clients/Sessions are overridden to those in MC_TraceAttachment.cfg.
 ****************************************************************************)

EXTENDS LabptyAttachment, TraceData, Sequences

VARIABLES ti, tk

tvars == << inUse, alive, attached, ti, tk >>

CurTrace == Traces[tk]

\* Reconstruct the model's function-shaped variables from a trace record's
\* compact set form. A session absent from `attached`'s domain carries {}.
ModelInUse(rec)    == [ c \in Clients  |-> IF c \in rec.inUse THEN 1 ELSE 0 ]
ModelAlive(rec)    == [ s \in Sessions |-> IF s \in rec.alive THEN 1 ELSE 0 ]
ModelAttached(rec) ==
    [ s \in Sessions |-> IF s \in DOMAIN rec.attached THEN rec.attached[s] ELSE {} ]

\* The transition must be the SPECIFIC action the daemon labelled it, not merely
\* some enabled action. Without this an attach that wrongly clears a bit looks
\* like a valid Detach (both are always enabled for a connected client), so the
\* binding could not tell attach from detach — a gap caught by
\* scripts/check-trace-mutants.
StepAction(rec) ==
    CASE rec.action = "Connect"          -> \E c \in Clients : Connect(c)
      [] rec.action = "Disconnect"       -> \E c \in Clients : Disconnect(c)
      [] rec.action = "OpenSession"      -> \E c \in Clients, s \in Sessions : OpenSession(c, s)
      [] rec.action = "Attach"           -> \E c \in Clients, s \in Sessions : Attach(c, s)
      [] rec.action = "Detach"           -> \E c \in Clients, s \in Sessions : Detach(c, s)
      [] rec.action = "TerminateSession" -> \E s \in Sessions : TerminateSession(s)
      [] OTHER                           -> FALSE

AtTrace(i) ==
    /\ inUse    = ModelInUse(CurTrace[i])
    /\ alive    = ModelAlive(CurTrace[i])
    /\ attached = ModelAttached(CurTrace[i])

TInit ==
    /\ tk \in 1..Len(Traces)
    /\ ti = 1
    /\ AtTrace(1)

TNext ==
    \/ /\ ti < Len(CurTrace)
       /\ ti' = ti + 1
       /\ tk' = tk
       /\ inUse'    = ModelInUse(CurTrace[ti + 1])
       /\ alive'    = ModelAlive(CurTrace[ti + 1])
       /\ attached' = ModelAttached(CurTrace[ti + 1])
       /\ StepAction(CurTrace[ti + 1])   \* the labelled action, specifically
    \/ /\ ti = Len(CurTrace)
       /\ UNCHANGED tvars

TSpec == TInit /\ [][TNext]_tvars

\* Sanity guard surfaced as an invariant: the index never runs past its trace.
TraceIndexInRange == ti \in 1..Len(CurTrace)

=============================================================================
