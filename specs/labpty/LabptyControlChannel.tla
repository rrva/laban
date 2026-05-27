-------------------------- MODULE LabptyControlChannel --------------------------
(****************************************************************************
 Labpty per-connection control-channel state machine, modelled for TLC.

 What this spec covers
   The state machine of a single labpty_client_t slot in
   `Sources/Labpty/main.c`, across the full lifecycle of an accept ->
   hello negotiation -> dispatch -> write-response -> idle cycle. The
   abstracted record per slot is:

     - state         : "empty" | "idle" | "reading" | "writing"
     - in_use        : 1 while the slot is allocated
     - negotiated    : 1 once hello successfully completed
     - established   : 1 if the slot is exempt from the slowloris
                       idle-timeout (slot reclamation)

   The spec is parametrised by the boolean constant
   `EstablishOnAnyRoundTrip`:

     FALSE -> established' := negotiated  (post-2aac41a, correct)
     TRUE  -> established' := 1           (pre-2aac41a, buggy)

   With the buggy variant, an idle un-negotiated client - e.g. one whose
   hello was rejected for a missing capability, or a pre-hello client
   that sent a non-hello frame and earned a `capability_required`
   response - is marked established=1 after the single rejection
   round-trip. The slowloris expire never reclaims its slot. The
   control-slot pool leaks one finite slot per such client, and the
   daemon eventually refuses new control connections.

 Why TLA+ here
   The daemon is single-threaded server-side, so this is purely about
   the order in which external events can arrive at one client across
   ticks of the event loop. TLC walks the cross-product of (client
   action x time tick) and checks the liveness property that every
   un-negotiated client eventually frees its slot. The fairness
   constraint WF_vars(Expire) models the event-loop guarantee that
   eligible expirations do fire.

 Companion module
   MC_ControlChannelPreFix.cfg sets EstablishOnAnyRoundTrip = TRUE and
   demonstrates that, without the 2aac41a fix, TLC finds the exact
   rejected-client slot-leak counterexample. Same role as
   LabptyLifecyclePreF2 plays for the registry slot-leak.
 ****************************************************************************)

EXTENDS Naturals, FiniteSets

CONSTANTS
    Clients,                  \* finite set of client slot IDs (~ LABPTY_MAX_CLIENTS)
    MaxFramesPerClient,       \* per-slot frame-cycle bound for TLC finiteness
    EstablishOnAnyRoundTrip,  \* BOOLEAN; TRUE = pre-2aac41a bug, FALSE = fix
    ExpireIgnoresMidFrame     \* BOOLEAN; TRUE = hypothetical regression where
                              \* expire_stalled_clients drops its
                              \* `|| has_pending_frame` branch and lets
                              \* established slots leak when stuck mid-frame.
                              \* FALSE = matches current C behaviour.

ASSUME EstablishOnAnyRoundTrip \in BOOLEAN
ASSUME ExpireIgnoresMidFrame   \in BOOLEAN
ASSUME MaxFramesPerClient \in 1..10

VARIABLES clients

vars == << clients >>

ClientStates == { "empty", "idle", "reading", "writing" }

EmptyClient ==
    [ state         |-> "empty",
      in_use        |-> 0,
      negotiated    |-> 0,
      established   |-> 0,
      frames_issued |-> 0 ]

TypeOK ==
    clients \in [ Clients -> [
        state         : ClientStates,
        in_use        : 0..1,
        negotiated    : 0..1,
        established   : 0..1,
        frames_issued : 0..MaxFramesPerClient
    ] ]

Init == clients = [ c \in Clients |-> EmptyClient ]

\* ----------------------------------------------------------------------
\* Actions
\* ----------------------------------------------------------------------

Accept(c) ==
    /\ clients[c].state = "empty"
    /\ clients' = [ clients EXCEPT ![c] =
            [ EmptyClient EXCEPT !.state = "idle", !.in_use = 1 ] ]

\* StartFrame: client begins streaming bytes for a new request frame.
\* In C terms, the first non-empty read on the socket sets read_have > 0.
StartFrame(c) ==
    /\ clients[c].state = "idle"
    /\ clients[c].frames_issued < MaxFramesPerClient
    /\ clients' = [ clients EXCEPT ![c].state = "reading" ]

\* DispatchHello: full hello frame received. labpty_negotiate_hello
\* either accepts (ok = 1, sets negotiated) or rejects (ok = 0, e.g.
\* missing capability). Either way the daemon stages a response frame.
DispatchHello(c, ok) ==
    /\ clients[c].state = "reading"
    /\ ok \in 0..1
    /\ clients' = [ clients EXCEPT
            ![c].state      = "writing",
            ![c].negotiated = IF ok = 1 THEN 1 ELSE clients[c].negotiated ]

\* DispatchNonHelloBeforeHello: a non-hello frame arrived from a slot
\* that has not yet negotiated. dispatch_frame returns
\* LABPTY_E_CAPABILITY_REQUIRED; the rejection response is staged just
\* like any other. negotiated remains 0.
DispatchNonHelloBeforeHello(c) ==
    /\ clients[c].state = "reading"
    /\ clients[c].negotiated = 0
    /\ clients' = [ clients EXCEPT ![c].state = "writing" ]

\* DispatchNonHelloNormal: a normal post-hello frame. negotiated must
\* already be 1.
DispatchNonHelloNormal(c) ==
    /\ clients[c].state = "reading"
    /\ clients[c].negotiated = 1
    /\ clients' = [ clients EXCEPT ![c].state = "writing" ]

\* WriteComplete: client_pump_write finished the response. This is the
\* line whose behaviour the 2aac41a fix changed:
\*   - Pre-fix: `client->established = 1;`
\*   - Post-fix: `client->established = client->negotiated;`
WriteComplete(c) ==
    /\ clients[c].state = "writing"
    /\ clients' = [ clients EXCEPT
            ![c].state         = "idle",
            ![c].established   =
                IF EstablishOnAnyRoundTrip THEN 1 ELSE clients[c].negotiated,
            ![c].frames_issued = clients[c].frames_issued + 1 ]

\* Expire: expire_stalled_clients reclaims the slot when the slowloris
\* deadline has elapsed. The C condition is
\*   skip iff (established AND NOT has_pending_frame)  -> exempts the
\*   established-byte-ring-reader case, kills everything else.
\* Equivalently the action is enabled when the slot is un-negotiated
\* (any state) OR when an established slot is stuck mid-frame
\* (state in {reading, writing}). The `~ExpireIgnoresMidFrame` guard
\* on the second branch lets the spec model the hypothetical regression
\* where the `|| has_pending_frame` half of the C check is removed.
Expire(c) ==
    /\ clients[c].in_use = 1
    /\ \/ clients[c].established = 0
       \/ /\ ~ExpireIgnoresMidFrame
          /\ clients[c].state \in {"reading", "writing"}
    /\ clients' = [ clients EXCEPT ![c] = EmptyClient ]

\* Disconnect: client closes the socket (read returns EOF, write fails).
\* Always permitted by the model so TLC also explores benign departures.
Disconnect(c) ==
    /\ clients[c].in_use = 1
    /\ clients' = [ clients EXCEPT ![c] = EmptyClient ]

Next ==
    \/ \E c \in Clients : Accept(c)
    \/ \E c \in Clients : StartFrame(c)
    \/ \E c \in Clients, ok \in 0..1 : DispatchHello(c, ok)
    \/ \E c \in Clients : DispatchNonHelloBeforeHello(c)
    \/ \E c \in Clients : DispatchNonHelloNormal(c)
    \/ \E c \in Clients : WriteComplete(c)
    \/ \E c \in Clients : Expire(c)
    \/ \E c \in Clients : Disconnect(c)

\* Fairness: the event-loop tick runs forever, so Expire eventually
\* fires on any continuously-eligible slot. No fairness on Disconnect:
\* TLC must consider adversarial slowloris clients that never depart.
Fairness == \A c \in Clients : WF_vars(Expire(c))

Spec == Init /\ [][Next]_vars /\ Fairness

\* ----------------------------------------------------------------------
\* Safety invariants
\* ----------------------------------------------------------------------

EmptyImpliesClean ==
    \A c \in Clients :
        clients[c].state = "empty" =>
            /\ clients[c].in_use = 0
            /\ clients[c].negotiated = 0
            /\ clients[c].established = 0

InUseIffNotEmpty ==
    \A c \in Clients :
        clients[c].in_use = 1 <=> clients[c].state # "empty"

EstablishedRequiresInUse ==
    \A c \in Clients :
        clients[c].established = 1 => clients[c].in_use = 1

NegotiatedRequiresInUse ==
    \A c \in Clients :
        clients[c].negotiated = 1 => clients[c].in_use = 1

\* The direct safety expression of the 2aac41a bug. The fix made
\* established = negotiated, so any state with established=1 must also
\* have negotiated=1. Under EstablishOnAnyRoundTrip = TRUE TLC reaches
\* (established=1, negotiated=0) on the first hello-rejection
\* WriteComplete and produces an immediate counterexample.
EstablishedImpliesNegotiated ==
    \A c \in Clients :
        clients[c].established = 1 => clients[c].negotiated = 1

\* ----------------------------------------------------------------------
\* Liveness property
\*
\* An un-negotiated client at the "idle" rest state - dispatch has
\* fired and the response has been written - cannot stay there
\* forever. Either it advances (StartFrame, Disconnect) or the
\* slowloris Expire reclaims its slot. Under fair Expire and
\* EstablishOnAnyRoundTrip = FALSE this holds (Expire is enabled
\* because established=0). Under EstablishOnAnyRoundTrip = TRUE (the
\* pre-2aac41a bug) established=1 disables Expire forever, and TLC
\* finds the stuttering counterexample where the client just sits at
\* idle/negotiated=0 indefinitely.
\* ----------------------------------------------------------------------

UnnegotiatedIdleIsNotPermanent ==
    \A c \in Clients :
        [] (
            (clients[c].in_use = 1 /\ clients[c].negotiated = 0
                /\ clients[c].state = "idle")
            ~> (clients[c].in_use = 0
                \/ clients[c].state # "idle"
                \/ clients[c].negotiated = 1)
        )

\* No slot stays parked in a mid-frame state forever. The C event loop's
\* slowloris check kills stuck mid-frame clients regardless of
\* negotiation status. Under fair Expire and ExpireIgnoresMidFrame =
\* FALSE this holds: a slot at reading or writing has Expire enabled
\* and eventually fires. Under ExpireIgnoresMidFrame = TRUE (the
\* hypothetical regression where the `|| has_pending_frame` branch is
\* dropped), an established slot stuck at reading is exempt from
\* Expire, no dispatch action is forced to fire, and TLC produces a
\* counter-example showing the slot is parked forever.
StuckMidFrameIsNotPermanent ==
    \A c \in Clients :
        [] (clients[c].state \in {"reading", "writing"}
            ~> clients[c].state \notin {"reading", "writing"})

=============================================================================
