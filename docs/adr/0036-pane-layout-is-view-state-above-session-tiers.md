# 0036: Pane layout is view state above session tiers

Status: Accepted (2026-09-28)

A pane is addressed by the stable ID of the session it displays. The recursive
pane tree belongs to LabanCore and workspace.json. labpty and laband have no
pane concept; their logical session ID is always the session ID. A tab's first
session uses the tab ID, preserving existing daemon keys on upgrade; additional
panes receive fresh UUIDs. Session.ID remains a String; a distinct wrapper type
is deferred. Closing the first pane must not change the survivor's identity.

This amends ADR 0024: persisted attach approvals match the same daemon shell
across app restarts now that session IDs are stable. Registration still checks
the live shell PID and existing scoped authorization rules. Split screenshots
are denied to session-scoped clients to prevent sibling terminal disclosure.

Split tabs use renderer draw commands. A single-grid GPU payload cannot encode
two independently sized grids. laband restores the focused pane full width with
a notice, and refuses new splits. Neither daemon's implementation changes.
