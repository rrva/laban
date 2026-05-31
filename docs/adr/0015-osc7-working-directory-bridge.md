# 15. OSC 7 Working-Directory Bridge (local-host-only, authoritative cwd)

Date: 2026-05-31

## Status

Accepted.

Third extension of the ADR 0012 Laban-side OSC host responder (`osc_host.c`),
after OSC 9/10/11 (ADR 0012) and OSC 52 (ADR 0014). Observe-only on the wire
(no PTY reply), like OSC 9. Does not change the ADR 0001 boundary and does not
patch vendored libghostty.

## Context

A shell emits `OSC 7 ; file://<host>/<path> ST` from its prompt hook on every
prompt to tell the terminal its current directory. libghostty-vt parses OSC 7
but the VT-only API does not surface it, so Laban dropped it.

Laban derives a session's cwd from `proc_pidinfo(PROC_PIDVNODEPATHINFO)` of the
foreground process (`process_metadata.c`). That cwd feeds new-tab-inherits-cwd,
the tab path display, branch resolution, and the persisted restore cwd. It has
two weaknesses the codex-compatibility inventory (session `f710dcd1`) flagged:
the vnode path can lag a `cd`, and it reports the *foreground process's* cwd,
which differs from the shell's logical cwd when a wrapper or subprocess is in
front. OSC 7 carries the shell's own answer and fixes both.

OSC 7 is also emitted by a shell running on a **remote** host over SSH, where
the reported path (e.g. `/home/user`) does not exist on the local machine.
Adopting it as a local cwd would break new-tab-inherits-cwd. So the report's
authority component must be validated before the path is trusted locally.

## Decision

Recognise OSC 7 in `laban_scan_osc_host` and treat a local-host report as the
session's authoritative cwd.

**Parse + validate (`osc_host.c`, `dispatch_osc7`).** Strip an optional
`file://`, take the authority up to the next `/`, and require the remainder to
be an absolute, percent-decoded path. The authority is accepted only when it is
empty, `localhost`, or matches the local hostname (full, or first DNS label, via
`gethostname`); any other host — chiefly a remote SSH shell — is ignored so the
local `proc_pidinfo` cwd stands. A valid path is stored in `s->osc7_cwd`. (OSC 7
reuses the host scanner's inline payload buffer, bumped to 2048 B to hold a
realistic `file://` URL.)

**Adopt as authoritative cwd (`process_metadata.c`).**
`laban_session_process_metadata` returns `osc7_cwd` when valid, in preference to
the `proc_pidinfo` vnode path, falling back to it and then to the launch cwd.
Because the existing metadata sync (`TabMetadataSynchronizer`, 0.25 s) already
sources `titleMetadata.workspace.cwd` from `processMetadata().cwd`, every
consumer — new-tab cwd, tab path, branch, restore — picks up the OSC 7 cwd with
**no change to the Swift cwd write-path**. This keeps the integration in the C
core where the data already lives and avoids a second writer racing the sync.

**New tabs inherit it.** `createTab` (⌘T) resolves the active tab's reported cwd
(`workspace.cwd`, else the live process cwd) and spawns the new shell there via
`AppModel.newTabSessionFactory` → `Session.realShell(size:cwd:)`, falling back to
the prior default-location spawn when no cwd is known, the factory is unset
(headless), or the directory no longer exists (reusing `resolveRestoredCwd`'s
existence check). This is what turns OSC 7 from a recorded-but-inert value into a
visible behaviour: report a directory, open a tab, land there.

**Observe (optional).** `LabanOSCWorkingDirectoryCallback` →
`Session.onWorkingDirectory` → `AppModel.onWorkingDirectoryChange` (main queue) →
`HeadlessDebugRuntime` records a `cwd.osc7` event. This hook is purely
observational (the cwd adoption above does not depend on it); it gives the
headless harness an autonomously-verifiable signal and any observer an immediate
notification.

**Why OSC 7 wins over proc_pidinfo.** The whole point of OSC 7 is the shell's
*logical* cwd, which is exactly the case proc_pidinfo gets wrong (foreground
subprocess, lagging vnode). A shell re-emits OSC 7 after each `cd`, so the stored
value stays fresh. Shells that never emit OSC 7 (default macOS zsh) leave
`osc7_cwd` invalid and the behaviour is unchanged — the change is purely
additive. Laban's own shell-integration overlay does not (yet) emit OSC 7, so
this primarily benefits shells/tools configured to send it. (Default macOS zsh
also reports the cwd well enough via proc_pidinfo for the common
at-the-prompt new-tab case; OSC 7 wins the lagging/subprocess cases.)

## Consequences

- A shell that reports OSC 7 gets accurate, lag-free cwd for new tabs (⌘T opens
  in the active tab's directory), the tab path, branch resolution, and restore —
  even while a subprocess is foreground.
- A remote SSH shell's OSC 7 is correctly ignored; the local ssh-client cwd from
  proc_pidinfo stands, so new-tab-inherits-cwd never lands on a nonexistent path.
- No regression for shells that don't emit OSC 7 (the dominant case today):
  `osc7_cwd` stays invalid and proc_pidinfo is used exactly as before. Verified
  by `LabanSessionTests.testProcessMetadataReportsForegroundProcessAndCwd`
  (unchanged) and `testOSC7*` (adoption, percent-decode, remote-host rejection),
  plus `HeadlessWorkingDirectoryTests` (event-stream parity).
- New-tab inheritance falls back to the prior default-location spawn whenever no
  cwd is known or it no longer exists, so ⌘T never fails to open a tab. Verified
  by `AppModelTests.testNewTabInheritsActiveTabCwd` and
  `testNewTabFallsBackToDefaultFactoryWhenNoCwdKnown`.
- Lives in the shared C core, so all three session tiers inherit the scanner;
  the cwd it feeds flows through the existing per-tier metadata path.

## Applies To New Code

When an observed sequence carries host-scoped state (a path, a hostname, a URL)
that Laban will act on locally, validate the host/authority before trusting it —
a remote peer (SSH, a nested session) can emit a value that is correct there and
wrong here. Prefer feeding such state into the data path where it already lives
(here, the C `process_metadata` cwd source) over adding a parallel writer to the
UI model, and keep an observational callback only for immediacy and headless
verification.
