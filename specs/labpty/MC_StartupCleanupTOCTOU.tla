------------------------ MODULE MC_StartupCleanupTOCTOU ------------------------
\* Negative-control variant of MC_Startup. The probe-first Listen fix is
\* in place (UnconditionalUnlink = FALSE), but cleanup_daemon's final
\* unlink is unconditional (InodeValidatedCleanup = FALSE) — the
\* pre-inode-check behaviour. TLC reaches a state where daemon B has
\* won the stale-recovery rebind but daemon A's UnlinkPath then strips
\* the dir_entry, leaving B bound but unreachable.
EXTENDS LabptyStartup
================================================================================
