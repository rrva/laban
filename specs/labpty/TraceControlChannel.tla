------------------------- MODULE TraceControlChannel -------------------------
(****************************************************************************
 Runtime trace conformance: replay real labpty control-channel traces through
 LabptyControlChannel and assert every logged transition is a spec action.

 This binds the per-connection state machine in Sources/Labpty/main.c — the
 accept -> hello -> dispatch -> write -> idle / expire cycle where the 2aac41a
 slot-leak bug lived. proofs/labpty/trace/trace_control.c drives the REAL client
 pipeline over a socketpair (client_pump_read / dispatch_frame / client_pump_
 write / expire_stalled_clients / client_release) and emits the observable
 per-client state (state, in_use, negotiated, established). scripts/check-trace
 generates TraceControlData from each run and runs this module.

 How the check works
   TInit picks a trace index tk nondeterministically and starts the model at
   all-empty (the Init record). TNext fires the model action the daemon
   labelled (StepAction), which DETERMINES clients', then pins the four
   observable fields of every client to the next record (ProjMatch). TLC
   explores every seed's trace in one run. If a logged transition is not the
   labelled spec action (e.g. write-complete that marks a rejected client
   established), no action matches the projection, the behaviour deadlocks, and
   TLC reports it — what scripts/check-trace asserts for the
   -DLABPTY_TRACE_NEGCTL negative control. The safety invariants
   (EstablishedImpliesNegotiated, ...) are checked on every state.

 Hidden variable
   The model's frames_issued is a TLC finiteness bound with no daemon
   counterpart, so it is NOT pinned: the model carries it freely (StartFrame's
   guard, WriteComplete's increment) while only the four observable fields are
   constrained. EstablishOnAnyRoundTrip = FALSE / ExpireIgnoresMidFrame = FALSE
   (the correct spec) are set in MC_TraceControlChannel.cfg; Clients comes from
   the generated TraceControlData.
 ****************************************************************************)

EXTENDS LabptyControlChannel, TraceControlData, Sequences

VARIABLES ti, tk

tvars == << clients, ti, tk >>

CurTrace == Traces[tk]

\* The four fields the daemon emits; frames_issued is hidden.
ProjMatch(mc, tc) ==
    /\ mc.state       = tc.state
    /\ mc.in_use      = tc.in_use
    /\ mc.negotiated  = tc.negotiated
    /\ mc.established  = tc.established

MatchesTrace(i) == \A c \in Clients : ProjMatch(clients[c], CurTrace[i].clients[c])

\* The model action the daemon labelled; it determines clients', which TNext
\* then checks against the trace's observable projection.
StepAction(rec) ==
    CASE rec.action = "Accept"     -> \E c \in Clients : Accept(c)
      [] rec.action = "StartFrame" -> \E c \in Clients : StartFrame(c)
      [] rec.action = "DispatchHello" ->
            \E c \in Clients, ok \in 0..1 : DispatchHello(c, ok)
      [] rec.action = "DispatchNonHelloBeforeHello" ->
            \E c \in Clients : DispatchNonHelloBeforeHello(c)
      [] rec.action = "DispatchNonHelloNormal" ->
            \E c \in Clients : DispatchNonHelloNormal(c)
      [] rec.action = "WriteComplete" -> \E c \in Clients : WriteComplete(c)
      [] rec.action = "Expire"     -> \E c \in Clients : Expire(c)
      [] rec.action = "Disconnect" -> \E c \in Clients : Disconnect(c)
      [] OTHER -> FALSE

TInit ==
    /\ tk \in 1..Len(Traces)
    /\ ti = 1
    /\ clients = [ c \in Clients |-> EmptyClient ]
    /\ MatchesTrace(1)

TNext ==
    \/ /\ ti < Len(CurTrace)
       /\ StepAction(CurTrace[ti + 1])
       /\ \A c \in Clients : ProjMatch(clients'[c], CurTrace[ti + 1].clients[c])
       /\ ti' = ti + 1
       /\ tk' = tk
    \/ /\ ti = Len(CurTrace)
       /\ UNCHANGED tvars

TSpec == TInit /\ [][TNext]_tvars

\* Sanity guard surfaced as an invariant: the index never runs past its trace.
TraceIndexInRange == ti \in 1..Len(CurTrace)

=============================================================================
