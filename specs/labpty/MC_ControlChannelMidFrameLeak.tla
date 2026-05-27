------------------- MODULE MC_ControlChannelMidFrameLeak -------------------
\* Hypothetical-regression variant of MC_ControlChannel.
\* Same protocol, but ExpireIgnoresMidFrame = TRUE, modelling what would
\* happen if expire_stalled_clients dropped the `|| has_pending_frame`
\* half of its check. An established client stuck mid-frame would be
\* exempt from the slowloris reaper, and no dispatch action is forced
\* to fire — TLC produces a counter-example to StuckMidFrameIsNotPermanent.
\* This isn't a historical bug; it's a guard so a future "simplification"
\* of the C condition doesn't silently regress the property.
EXTENDS LabptyControlChannel
============================================================================
