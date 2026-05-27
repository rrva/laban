--------------------- MODULE MC_ControlChannelPreFix ---------------------
\* Negative-control variant of MC_ControlChannel.
\* Same protocol, but EstablishOnAnyRoundTrip = TRUE, reproducing the
\* pre-2aac41a behaviour in client_pump_write where every completed
\* round-trip - including ones that ended with a rejection response -
\* marked the client established. TLC should produce a counterexample
\* to UnnegotiatedSlotsAreReclaimed, exactly the slot-leak from
\* rejected pre-hello and bad-capability clients.
EXTENDS LabptyControlChannel
==========================================================================
