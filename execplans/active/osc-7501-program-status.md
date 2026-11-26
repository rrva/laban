# Adopt OSC 7501, the Program Status Protocol

This ExecPlan is a living document maintained in accordance with `PLANS.md`
(repository root). Keep `Progress` and `Validation and Acceptance` current as
work proceeds.

## Purpose / Big Picture

A program running in a Laban tab can now tell Laban what it is doing, and
Laban shows it. A coding agent that needs permission makes its tab pulse and
raises a macOS notification with the agent's own question. A long build shows
"▰▰▱▱▱ 40% Pushing image" in the sidebar. A finished task marks its tab until
the user looks at it. Programs can ask Laban whether it supports this and get
an answer.

The mechanism is OSC 7501, the Program Status Protocol, specification
revision 0.4 (2026-10-10). An OSC ("operating system command") is an escape
sequence a program writes to its terminal: the bytes `ESC ]`, a number, `;`,
a payload, and a terminator that is either `ESC \` (called ST) or the BEL
byte 0x07.

To see it working, run this in a Laban tab, then switch to another tab:

    printf '\033]7501;state=blocked:kind=permission:msg=QXBwcm92ZT8=\033\\'; sleep 30

The first tab's sidebar row shows "Approve?" in the attention colour with a
pulsing ◆, and a notification appears.

## Progress

- [x] (2026-11-25) C scanner: answer the query, deliver reports, deliver RIS as a clear.
- [x] (2026-11-25) Swift: `ProgramStatusReport.parse` and `ProgramStatusRecords`.
- [x] (2026-11-25) `Session.onProgramStatus` hook.
- [x] (2026-11-25) `AppModel`: records in tab metadata, attention events, lifetimes.
- [x] (2026-11-25) Sidebar line and error dot; attention classifier; close confirmation.
- [x] (2026-11-25) Debug state (`programStatus` on a tab), `program.status` event, schema.
- [x] (2026-11-25) Tests at four layers; docs (`docs/features.md`, `docs/product/spec.md`, ADR 0041).
- [ ] Look at the sidebar rendering in the visible app (not yet done; see Validation).
- [ ] Move this plan to `execplans/completed/` when the change merges.

## Decision Log

- Decision: C delivers the raw payload; Swift validates it.
  Rationale: the rules need UTF-8 validation and Unicode general-category
  checks, which Foundation has. A pure Swift parser is unit-testable without a
  session. OSC 52 already splits the work this way.
  Date/Author: 2026-11-25, Claude.
- Decision: records live in `TabTitleMetadata.programStatus` and nothing is
  copied into the older `progress`, `agentStatus` or `notification` fields.
  Rationale: every consumer (sidebar, attention, close dialog, debug state,
  exit cleanup, per-pane metadata in split tabs) already reads tab metadata,
  and the older sequences keep their behaviour.
  Date/Author: 2026-11-25, Claude.
- Decision: the query reply is the bare `ESC ] 7501 ; ? ST`, without
  `states=`/`kinds=` lists.
  Rationale: the protocol defines a bare reply as "exactly the standard
  lists", which is what Laban accepts.
  Date/Author: 2026-11-25, Claude.
- Decision: `idle` records are dropped on process exit and at a new prompt.
  Rationale: the protocol allows it, and an `idle` record from a program that
  is gone says nothing.
  Date/Author: 2026-11-25, Claude.
- Decision: OSC 9;4 progress is not mapped into the records.
  Rationale: the protocol makes the mapping optional and warns that it
  overwrites `kind` and `msg`. The sidebar prefers the OSC 7501 line when
  both exist.
  Date/Author: 2026-11-25, Claude.
- Decision: a banner is raised only when the summary record's state or
  message changes into `blocked`, `done` or `error`.
  Rationale: the protocol asks terminals to rate-limit effects outside the
  terminal; a program can rewrite its state as fast as it can write.
  Date/Author: 2026-11-25, Claude.

## Surprises & Discoveries

- Observation: a sidebar info line wider than the row is not clipped; it is
  not drawn at all.
  Evidence: `appendGlyph` in `Sources/LabanCore/SidebarProducer.swift` returns
  early unless `visibleRect.contains(cellRect)`. The program-status line is
  therefore cut to the row width in `programStatusDisplayLine`.
- Observation: capture replay does not run the OSC scanners.
  Evidence: `laban_session_replay_pty_output` in
  `Sources/LabanTerminalCore/session_lifecycle.c` calls
  `ghostty_terminal_vt_write` directly. A replayed capture shows no program
  status. This is the same for OSC 7, 9, 133 and 21337.

## Context and Orientation

Laban is a macOS terminal. Bytes from the program arrive on a pty
(pseudo-terminal, the kernel pipe between terminal and program) and go to
libghostty-vt, the vendored library that interprets escape sequences.
libghostty-vt drops OSC 7501, so Laban reads the same bytes itself with small
state machines called scanners.

- `Sources/LabanTerminalCore/osc_host.c` is the scanner for OSCs that Laban
  handles or answers. `osc_host_interesting` lists the numbers.
  `dispatch_osc_host` routes a complete payload. Replies go through
  `laban_write_terminal_response`.
- `Sources/LabanCore/Session.swift` wraps the C session. Each C callback has
  a Swift hook (`onProgress`, `onProgramStatus`, …).
- `Sources/LabanCore/AppModel.swift` owns tabs. `attachSessionCallbacks`
  connects a session's hooks to tab metadata. Hooks fire on the reader thread
  with the C session lock held, so each hops to the main queue before it
  takes the model lock.
- `Sources/LabanCore/TabTitleMetadata.swift` is the per-pane metadata the
  sidebar renders (`Sources/LabanCore/SidebarProducer.swift`) and the
  attention classifier reads (`Sources/LabanCore/TabAttention.swift`).
  "Attention" is how urgently a background tab wants the user: `none`,
  `passive`, `done`, `needsAction`.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` runs the app model without
  a window for tests. Tab state is served as JSON described by
  `schemas/debug/state.schema.json`.

The protocol, as implemented:

- Report: `ESC ] 7501 ; key=value:key=value ST`. Keys are lowercase letters,
  at most 16 bytes. Values use `[A-Za-z0-9_.,+/=-]`. Whitespace around keys
  and values is ignored. A malformed pair is skipped. Unknown keys are
  ignored. The last value of a repeated key wins.
- `state` is required: `idle`, `working`, `done`, `blocked`, `error`, or
  `clear`. A report with no or an unknown `state` is ignored.
- `id` is a path of up to 8 segments of `[A-Za-z0-9_.+-]{1,32}` joined by
  `/`, at most 128 bytes. No `id` addresses the root record. An invalid `id`
  discards the report.
- `kind` (`permission`, `question`, `auth`) counts only with `blocked`.
  `progress` (integer 0–100) counts only with `working` or `blocked`. `app`
  is `[A-Za-z0-9_.+-]{1,32}`. An invalid value of these three is treated as
  absent.
- `msg` (at most 2732 bytes encoded, 2048 decoded) and `title` (256 / 192)
  are standard base64 of UTF-8 with optional padding. Bad base64, an exceeded
  limit, or a control character (U+0000–001F, U+007F–009F) in the decoded
  text discards the whole report.
- A report replaces its record completely. `state=clear` removes the
  addressed record and its children; without `id` it removes all records.
- A pane keeps at most 256 records; the least recently updated one is evicted.
- `working` and `blocked` records end when the process exits or the shell
  draws a new prompt (OSC 133 `A`). `done` and `error` survive both. A full
  terminal reset (RIS, `ESC c`) removes all records.
- Query: `ESC ] 7501 ; ? ST`. Reply: `ESC ] 7501 ; ? ST`.

## Plan of Work

All of this is implemented; the list is the map of the change.

1. `Sources/LabanTerminalCore/osc_host.c`: add 7501 to
   `osc_host_interesting`; add `dispatch_program_status` (query reply, else
   the callback); in the scanner's `OH_AFTER_ESC` state deliver `state=clear`
   on `ESC c`; add `laban_session_set_program_status_callback`.
   `session_internal.h`: `OSC_HOST_PAYLOAD_MAX` 2048 → 4096 and the callback
   fields. `include/LabanTerminalCore.h`: the public typedef and setter.
2. `Sources/LabanCore/ProgramStatus.swift` (new): `ProgramStatusState`,
   `ProgramStatusBlockKind`, `ProgramStatusReport.parse`,
   `ProgramStatusRecord`, `ProgramStatusRecords` (`apply`, `dropLiveRecords`,
   `dropSeenResults`, `effectiveApp`, `summary`).
3. `Sources/LabanCore/Session.swift`: `onProgramStatus`, following
   `onProgress`.
4. `Sources/LabanCore/TabTitleMetadata.swift`: `programStatus:
   ProgramStatusRecords?`.
5. `Sources/LabanCore/AppModel.swift`: `attachProgramStatus`,
   `applyProgramStatusReport`, `programStatusBody`, `onProgramStatusChange`;
   drop live records at a prompt in `applyShellIntegration`; drop seen results
   in `acknowledgePaneAttention` and `markActiveTabNotificationSeen`; show a
   sibling pane's status in `tabWithPaneAttention`.
   `Sources/LabanCore/TabMetadataSynchronizer.swift`: drop live records in
   `applyExitState`.
6. `Sources/LabanCore/TabAttention.swift`: `blocked` → `needsAction`, `done`
   → `done`. `Sources/LabanCore/SidebarProducer.swift`:
   `programStatusDisplayLine` and a red dot for `error`.
   `Sources/LabanCore/CloseConfirmation.swift`: `working` counts as an agent
   that is working.
7. Debug: `ProgramStatusResponse` in
   `Sources/LabanCore/Control/Projections/ControlResponseModels.swift`, filled
   in `ControlStateProjections.swift` (omitted under observe redaction);
   `schemas/debug/state.schema.json`; the `program.status` event in
   `Sources/LabanDebug/DebugShellIntegrationEndpoints.swift`, wired in
   `HeadlessDebugRuntime.swift`.

## Concrete Steps

From the repository root:

    swift build
    swift test --filter 'ProgramStatusTests|testOSC7501|testProgramStatusReachesTab'
    scripts/check

## Validation and Acceptance

Automated, all passing on 2026-11-25:

- `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`:
  `testOSC7501QueryRepliesWithQueryTerminator` (reply bytes for ST and BEL
  queries; the reply precedes the reply to a following `CSI c`) and
  `testOSC7501ReportsReachCallbackUnparsed` (split reads, over-long report
  dropped, OSC 75010 not matched, RIS delivered as `state=clear`).
- `Tests/LabanCoreTests/ProgramStatusTests.swift`: 18 tests for the grammar,
  limits, text rules, record store, lifetimes, cap, and the sidebar line.
- `Tests/LabanCoreTests/AppModelTests.swift`:
  `testOSC7501ProgramStatusDrivesTabStateAndAttention`.
- `Tests/LabanDebugTests/TabTitleEndToEndTests.swift`:
  `testProgramStatusReachesTabAndDiesWithTheProgram` (a real `/bin/sh` on a
  pty; reads `programStatus` and `attention` from debug state and the
  `program.status` event).

Not yet verified: how the sidebar line looks in the visible app. The line's
text, colour choice and width limit are unit-tested, and it is drawn by the
same code path as the OSC 21337 status line, but nobody has looked at it on
screen. Run the command in Purpose and look.

## Idempotence and Recovery

The change is additive. A program that never sends OSC 7501 sees no
difference, except that `OSC 7501 ; ?` now gets a reply. To back the feature
out, remove 7501 from `osc_host_interesting`; everything downstream then
receives nothing.

## Interfaces and Dependencies

    // Sources/LabanTerminalCore/include/LabanTerminalCore.h
    typedef void (*LabanProgramStatusCallback)(
        void *userdata, const uint8_t *payload, size_t len);
    int laban_session_set_program_status_callback(
        LabanSession *session, LabanProgramStatusCallback callback, void *userdata);

    // Sources/LabanCore/ProgramStatus.swift
    public static func ProgramStatusReport.parse(_ payload: some Sequence<UInt8>) -> ProgramStatusReport?
    public mutating func ProgramStatusRecords.apply(_ report: ProgramStatusReport) -> Bool
    public var ProgramStatusRecords.summary: ProgramStatusRecord? { get }

    // Sources/LabanCore/Session.swift
    public var onProgramStatus: ((ProgramStatusReport) -> Void)?

    // Sources/LabanCore/AppModel.swift
    public var onProgramStatusChange: ((Tab.ID, ProgramStatusRecord?) -> Void)?

No new dependencies. Design rationale is in
`docs/adr/0041-osc-7501-program-status.md`.
