------------------------- MODULE MC_AttachmentPreFix -------------------------
\* Negative-control variant of MC_Attachment. TeardownSkipsAttachmentScrub
\* = TRUE drops client_release's mask scrub, so a client can close its
\* socket while still listed in a session's attached set. TLC must produce
\* a counterexample to AttachmentImpliesInUse: the descriptor's
\* connected_clients then overcounts a departed owner, which would make a
\* live-but-abandoned session look owned (blocking adoption) or count a
\* dead owner. Same role LabptyControlChannelPreFix plays for the
\* control-slot leak.
EXTENDS LabptyAttachment
==========================================================================
