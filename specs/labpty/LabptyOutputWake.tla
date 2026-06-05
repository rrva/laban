---------------------------- MODULE LabptyOutputWake ----------------------------
(****************************************************************************
 Output-wake readiness model.

 This spec covers the `output-wake/v1` parked/active contract layered on top
 of the byte ring:

   - while parked, the first producer write transitions the reader to active
     and creates one wake;
   - while active, further producer writes create no wakes;
   - the reader may park only when its observed byte-ring offset still equals
     the daemon's output offset.

 The byte ring remains the data plane and is modelled separately by
 LabptyByteRing.tla. This model is only the readiness protocol around
 `main.c::notify_output_wake_clients` and `handle_park_output_wake`.
 ****************************************************************************)

EXTENDS Naturals

CONSTANTS
    MaxOutput,
    WakeWhileActive,
    IgnoreStalePark

ASSUME MaxOutput \in 1..6
ASSUME WakeWhileActive \in BOOLEAN
ASSUME IgnoreStalePark \in BOOLEAN

VARIABLES mode, pending, output, observed, wakes, bursts

vars == << mode, pending, output, observed, wakes, bursts >>

Modes == { "parked", "active" }

TypeOK ==
    /\ mode \in Modes
    /\ pending \in BOOLEAN
    /\ output \in 0..MaxOutput
    /\ observed \in 0..MaxOutput
    /\ observed <= output
    /\ wakes \in 0..MaxOutput
    /\ bursts \in 0..MaxOutput

Init ==
    /\ mode = "parked"
    /\ pending = FALSE
    /\ output = 0
    /\ observed = 0
    /\ wakes = 0
    /\ bursts = 0

ProducerWrite ==
    /\ output < MaxOutput
    /\ output' = output + 1
    /\ IF mode = "parked" THEN
          /\ mode' = "active"
          /\ pending' = TRUE
          /\ wakes' = wakes + 1
          /\ bursts' = bursts + 1
       ELSE
          /\ mode' = mode
          /\ bursts' = bursts
          /\ IF WakeWhileActive THEN
                /\ pending' = TRUE
                /\ wakes' = wakes + 1
             ELSE
                /\ pending' = pending
                /\ wakes' = wakes
    /\ UNCHANGED observed

ReadWake ==
    /\ pending = TRUE
    /\ pending' = FALSE
    /\ UNCHANGED << mode, output, observed, wakes, bursts >>

DrainRing ==
    /\ mode = "active"
    /\ observed' = output
    /\ UNCHANGED << mode, pending, output, wakes, bursts >>

ParkReader ==
    /\ mode = "active"
    /\ IF observed = output \/ IgnoreStalePark THEN
          /\ mode' = "parked"
       ELSE
          /\ mode' = "active"
    /\ UNCHANGED << pending, output, observed, wakes, bursts >>

Next == ProducerWrite \/ ReadWake \/ DrainRing \/ ParkReader

Spec == Init /\ [][Next]_vars

\* A parked reader is only armed at an offset the app actually drained.
ParkedImpliesObservedCurrent ==
    mode = "parked" => observed = output

\* Streaming output while active must not create wake-per-drain churn.
NoMoreWakesThanBursts ==
    wakes <= bursts

=============================================================================
