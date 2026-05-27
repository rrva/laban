--------------------------- MODULE MC_StartupPreFix ---------------------------
\* Negative-control variant of MC_Startup.
\* Same model, but UnconditionalUnlink = TRUE, reproducing the
\* pre-b5e7819 behaviour where every Listen() unlinks whatever is at the
\* path before binding. TLC should produce a counterexample to
\* ServingDaemonOwnsPath (and AtMostOneServing): a second daemon
\* starting strands the first one's session by hijacking its path.
EXTENDS LabptyStartup
================================================================================
