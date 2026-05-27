------------------------- MODULE MC_ByteRingTorn -------------------------
\* Negative-control variant of MC_ByteRing.
\* Same protocol, but ReadableWindow = Capacity (no safety margin). TLC
\* should produce a counterexample to NoTornRead, demonstrating that the
\* margin commit 26760d5 added is actually necessary.
EXTENDS LabptyByteRing
==========================================================================
