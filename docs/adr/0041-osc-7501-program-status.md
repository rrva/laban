# 41. OSC 7501 Program Status

Date: 2026-11-25

## Status

Accepted.

Fourth extension of the ADR 0012 Laban-side OSC host responder (`osc_host.c`),
after OSC 9/10/11 (ADR 0012), OSC 52 (ADR 0014) and OSC 7 (ADR 0015). Does
not change the ADR 0001 boundary and does not patch vendored libghostty.

## Context

The Program Status Protocol (OSC 7501, specification revision 0.4 of
2026-10-10) lets a program tell the terminal what it is doing: `idle`,
`working`, `done`, `blocked` or `error`, with an optional one-line message,
progress percentage, block kind, application id, and an `id` path so one
program can report several records. Coding agents and build tools emit it.
A terminal that supports it answers the feature query `OSC 7501 ; ?`.

Until now Laban learned the same facts indirectly: OSC 9;4 progress, OSC
21337 tab status, OSC 9/99/777 notification text matched against keywords,
and agent-specific terminal-title markers. Each of those is a heuristic or a
presentation command; none states "blocked on the user" as data.

libghostty-vt's OSC parser rejects the number 7501 and drops the sequence,
and its C API has no unknown-OSC callback.

## Decision

1. **Scan and answer in `osc_host.c`.** 7501 joins the host scanner's
   allowlist. The `?` query is answered there through
   `laban_write_terminal_response`, echoing the query's terminator, with or
   without a registered callback. The reply is the bare `?`, which the
   protocol defines as "exactly the standard states and kinds". The inline
   payload buffer grows from 2048 to 4096 bytes, the protocol's cap for a
   whole sequence; a longer report is dropped, as the protocol requires.
2. **Validate in Swift.** C hands the raw payload to
   `LabanProgramStatusCallback`. `ProgramStatusReport.parse`
   (`Sources/LabanCore/ProgramStatus.swift`) owns the grammar, the limits,
   base64, and the text rules, as the Swift bridge already does for OSC 52.
   The rules need UTF-8 and Unicode-category checks that Foundation has and C
   does not, and a pure Swift function is directly unit-testable.
3. **Records are pane metadata.** `TabTitleMetadata.programStatus` holds the
   pane's `ProgramStatusRecords`. The sidebar line, the attention level, the
   close-confirmation "working" state, and the debug state all derive from
   the records' summary (most urgent state, then most recent). Nothing is
   copied into `progress`, `agentStatus` or `notification`, so the older
   sequences keep working unchanged beside it.
4. **Lifetimes use events Laban already sees.** Child exit and OSC 133 `A`
   drop `working`, `blocked` and `idle` records. `done` and `error` stay until
   the user looks at the tab (the same acknowledgement that clears an OSC 9
   badge). RIS reaches Swift as a `state=clear` report.
5. **Notifications are edge-triggered.** An attention event is raised only
   when the summary's state or message changes into `blocked` (needs action)
   or `done`/`error` (completion), and then goes through the existing
   attention policy and dedupe. A program rewriting its state in a loop
   cannot raise a banner per write.
6. **OSC 9;4 is not mapped into records.** The protocol allows mapping it to
   the root record and warns about the overwrite that causes. Laban keeps
   OSC 9;4 as `TabProgress`; when a pane has an OSC 7501 line, the sidebar
   shows that line instead of the OSC 9;4 line.

## Consequences

- A program can detect Laban's support and report state without heuristics.
- Message text from a program reaches the sidebar and macOS notifications.
  It is refused when it contains control characters, shown as plain text, and
  stripped of invisible formatting characters (bidirectional overrides and
  the like; the zero-width joiner and non-joiner stay).
- Capture replay bypasses the scanners (`laban_session_replay_pty_output`),
  so a replayed capture shows no program status, like every other
  host-scanner sequence.
- In a split tab the sidebar row shows the focused pane's status, else a
  sibling pane's.
- The reply does not advertise `states=`/`kinds=` lists. If Laban later
  accepts a non-standard state it must start advertising them.

## Applies To New Code

- New OSC 7501 keys are added in `ProgramStatusReport.parse`; unknown keys
  must keep being ignored and an unknown `state` must keep discarding the
  report.
- Anything that shows record text outside the terminal grid must take it
  from a parsed `ProgramStatusRecord`, never from the raw payload.
- New effects of a record outside the terminal (sounds, badges, banners) go
  through `AttentionNotificationEvent`, not a direct call.
