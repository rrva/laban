# Agents Open Terminals: `laban new`, `split`, `run --wait`

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. It is complete; it stays as the design record for the
2026-11-26 amendment to ADR 0024.

## Purpose / Big Picture

Before this change a program running inside Laban could read its own terminal
and propose commands, but it could not open a terminal. Opening one is what
power users and coding agents reach for most: run the tests in a pane beside
me, tail a log in a background tab, run a build and give me its exit code. After this change, from any shell inside Laban:

```sh
laban split --down -- npm test          # new pane under mine; prints its session id
laban new --label logs --no-focus -- tail -f dev.log
laban run --wait -- make check; echo $?  # exits with make's status
```

No dialog appears. A process outside every Laban session is refused.

## Progress

- [x] 2026-11-26 Ragnar chose `new`, `split` and `run --wait`, and confirmed that
  opening terminals should need no dialog while typing into them stays deferred.
- [x] Capability `.spawn`; intents `session.spawnTab` / `session.spawnSplit`
  (`POST /debug/actions`, actions `spawnTab` / `spawnSplit`) with input and output
  schemas in `IntentCatalog`.
- [x] `ControlSpawnRouting` (LabanCore): validation, anchoring a split to the
  caller's own pane, limits, notice text, rate limiter.
- [x] Lazy attach: allowlist entries with `requiresApproval: false`; the server
  routes them after the ancestry proof without a dialog (`approval: inSession`).
- [x] GUI: `TerminalBitmapView.openControlSpawn` opens the tab or split, runs argv
  through the existing command-session factory, applies label/focus, posts the
  notice; `LiveIntentRouter` audits `control.spawn` and rate-limits.
- [x] `AppModel.splitPane(anchor:focusNewPane:)`, `makePaneSession(argv:)`.
- [x] Headless parity (`DebugSpawnActions`).
- [x] CLI: `new`, `split`, `run [--wait]`, help, completions.
- [x] Fixed: the first tab of a fresh launch was never registered for lazy attach,
  so every `laban` session command from it was refused.
- [x] ADR 0024 amendment, spec §24 amendment, agent control guide.
- [x] End-to-end run in an isolated dev build (see Validation).
- [x] Fresh-context review (FAIL) addressed: the CLI resolves argv[0] on the
  caller's PATH; sandboxed callers get the dialog; `run --wait` records 128+N on
  a signal; labels are refused for splits; the notice names the wrapped command
  and sits on the new pane; the tab path reuses `createTabPreservingSelection`;
  monotonic rate-limit clock.
- [x] Second review (FAIL) addressed: `.spawn` is no longer on the
  session-observe broker tier and the CLI always lazy-attaches, so a sandboxed
  agent under `laban agent run` also gets the dialog; that dialog names the
  sandbox escape and shows the command and directory; the server requires an
  absolute `argv[0]`; `--no-focus` restores the right selection; a focused new
  tab discards IME composition; directories are not commands.

## Surprises & Discoveries

- The first tab of a fresh launch had no registered shell. `AppModel.init`
  creates it before `MainWindowController` hooks `onSessionCreated`, so its
  shell PID never reached the control server and lazy attach from it failed with
  `notDescendantOfRegisteredSession`. This was not specific to spawning: reads
  failed the same way. The fix registers the sessions that exist when the hook is
  installed.
- With the default labpty backend the app keeps no child exit status (a daemon
  session reports `exited(code: 0)`), so `run --wait` cannot ask the app for it.

## Decision Log

- The terminal starts argv with `execve` (no PATH search, relative paths against
  Laban's directory), so the CLI resolves `argv[0]` the way the caller's shell
  would and exits 127 itself. The first end-to-end run missed this because every
  command was either absent or wrapped in `/bin/sh`.
- A sandboxed caller keeps the dialog: the new terminal runs outside its sandbox,
  so for it a spawn is an escape (`ControlSandboxCheck`, fail closed).

- Spawning is not driving. Opening a new terminal never writes bytes into an
  existing session, and the caller could run the same command itself, so it gets
  its own capability (`.spawn`) instead of `.input`. `send`/`send-key` stay
  deferred: they could press Enter on another agent's permission prompt.
- The in-session ancestry proof is the credential. Lazy attach already proves a
  requester descends from a registered session's shell before any dialog; for the
  two spawn intents the server mints a one-request, request-exact tier and routes.
  Nothing is persisted, so there is nothing to revoke.
- A split always divides the caller's own pane, never the focused one, so a
  background agent cannot rearrange the pane the user is typing in.
- `run --wait` wraps the command in `/bin/sh`, which writes its pid and then the
  exit status into a `0700` directory the CLI created. The CLI polls, exits with
  the status, and reports when the wrapper died without writing one (the user
  closed the terminal). This works the same for every backend. The tab is named
  after the real command because the terminal runs the wrapper.
- The working directory defaults to the caller's, because that is what
  `laban split -- make test` means to the person typing it.
- The new terminal is marked "Opened by a program: <command>" through the
  existing tab notice, and every spawn is audited (`control.spawn` event, the
  agent-attached indicator, an in-session auto-approve audit record).
- Reading a spawned terminal's content is out of scope: reads stay own-session.

## Outcomes & Retrospective

`new`, `split` and `run --wait` work end to end without a dialog. An event
stream, agent skill setup, and a program-status read are separate work.

## Context and Orientation

- `Sources/LabanCore/Control/ControlSpawn.swift`: request/response types,
  `ControlSpawnRouting.plan`, `ControlSpawnRateLimiter`.
- `Sources/LabanCore/Intents/IntentCatalog.swift`: `.spawn`, the two descriptors.
- `Sources/LabanControl/ControlLazyAttachAllowlist.swift` and
  `LabanControlServerLazyAttach.swift`: the no-dialog branch.
- `Sources/LabanControl/LabanControlPolicy.swift`: only the fixture tier
  tier grants `.spawn` directly; lazy attach mints it per request.
- `Sources/LabanApp/Control/LiveIntentRouter.swift`, `TerminalBitmapView.swift`
  (`openControlSpawn`), `MainWindowController.swift` (binding, first-tab
  registration).
- `Sources/LabanDebug/DebugSpawnActions.swift`: headless parity. The headless
  runtime starts its own session kind, so it validates argv but does not run it.
- `Sources/LabanCLI/SpawnCommand.swift`, `RunWaiter.swift`, `LabanCommand.swift`.

## Plan of Work

Done as listed under Progress, in one branch.

## Validation and Acceptance

- Unit and integration tests: `ControlSpawnRoutingTests`,
  `AppModelSpawnSplitTests`, `LazyAttachInSessionSpawnTests` (no dialog inside a
  session, `403` outside, reads still prompt), `SpawnCommandTests`,
  `RunWaitTests` (the real wrapper records status 3 and keeps `a b` one word),
  `SpawnHeadlessTests`, plus the updated invariant and policy tests.
- End to end (2026-11-26, isagel): a dev build launched with an isolated
  `LABAN_SUPPORT_DIR`/`LABAN_CONTROL_DIR` and a scripted login shell. From the
  first tab, with no dialog: `laban split --down -- …` printed a session id and
  the tab became two panes; `laban new --no-focus --label e2e-tab --json -- …`
  opened a background tab titled `e2e-tab`; `laban run --wait --json -- sh -c
  'exit 7'` printed `exitStatus: 7` and exited 7; `laban split --cwd
  /nonexistent` printed `laban: cwd is not a directory` and exited 5. Three
  `control.spawn` events were logged with the caller's session id.
- `./scripts/check` passes except the known labpty MC/DC floor, which fails on
  `main` too.

## Idempotence and Recovery

Nothing here migrates state. Reverting the branch removes the commands; no
persisted approval records are created by spawning.
