# Replace the standard About panel with a diagnostic About window

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root.

## Purpose / Big Picture

The standard About panel showed a version, a commit and a build age. For a
terminal, a bug report needs more: exactly which build is running and how it
is signed, which terminal core and renderer it uses, whether the long-lived
session daemon is older than the app, and what the terminal actually answers
when a program probes it. After this change, "About Laban" opens a window with
four sections (Build, Components, What programs see, Credits) whose values all
come from the running process. A **Run Self-Test** button proves the terminal's
capability replies on this machine. The behavior is specified in
`docs/product/spec.md` §27.

To see it: install a build (`LABAN_WMO_PROFILE=1 ./scripts/install-app`),
restart, and choose Laban → About Laban. Then press Run Self-Test and expect
10 rows marked ✓, or ✓ plus a "switched off" row for Kitty graphics when
graphics are disabled.

## Progress

- [x] (2026-09-25) `TerminalCapabilitySelfTest` (LabanCore). It probes a
  fixture session with DA1, XTVERSION, DECXCPR, the Kitty keyboard query,
  OSC 11, OSC 4, the color-scheme report, DECRQM 2026/2004 and the Kitty
  graphics query. `TerminalCapabilitySelfTestTests` (3) pass.
- [x] (2026-09-25) `AboutInfo` (LabanApp) reads the live values:
  - the code signature, through the Security framework;
  - the VT core, from Info.plist stamps;
  - running `labpty` daemons with an older-than-installed check;
  - GPU and display, `TERM`/`TERM_PROGRAM`, and the Kitty graphics gate.

  `AboutInfoTests` (5) pass.
- [x] (2026-09-25) `AboutWindowController` replaces
  `orderFrontStandardAboutPanel`. `UpdaterController.lastUpdateCheckDate`
  was added.
- [x] (2026-09-25) `scripts/build-app` stamps `LABANLibghosttyCommit` and
  `LABANLibghosttyPatches` from `scripts/fetch-libghostty-vt` and bundles
  `THIRD_PARTY_LICENSES.md`, `LICENSE` and `licenses/*.txt` under
  `Contents/Resources/Licenses/`.
- [x] (2026-09-25) `THIRD_PARTY_LICENSES.md` changes:
  - the Swift-package section for the removed profiler dependencies is gone,
    along with `licenses/Apache-2.0.txt`, which only it used;
  - Sparkle is added, with `licenses/Sparkle-LICENSE.txt`;
  - a Slug acknowledgement is added.
- [x] (2026-09-25) Six new UI labels translated into the 8 shipped locales;
  catalog regenerated.
- [x] (2026-09-25) Rendered the window offscreen and reviewed the image; fixed
  the Kitty graphics row to report the applied gate rather than the persisted
  setting.
- [x] (2026-09-25) Independent feature and bug-hunt reviews. Fixed:
  - the stale-daemon check (see Decision Log);
  - daemons launched from another install or a `/private` path were missed
    (every labpty of the user is now listed, compared without resolving
    symlinks);
  - the signature is read from the running code (`SecCodeCopySelf`);
  - build-app fails when the pin or patch stamps cannot be read;
  - macOS, font and theme rows added;
  - plain-language probe names with inline purposes;
  - "9 passed, 1 turned off" summary instead of counting a turned-off probe
    as passed;
  - VoiceOver status words and announcements;
  - row labels localized;
  - credits list every palette and Laban's copyright;
  - the JetBrains Mono OFL is bundled;
  - licenses open in TextEdit.

  Deferred by the user's scope choice: Copy Diagnostics and an
  agent-readable endpoint, and input source, shell and control-server rows.
- [ ] Installed-app check (signature row shows team `3563RJWBQP`, VT core
  shows `7c40388b2` with 3 patches, self-test 10/10).

## Decision Log

- Decision: The self-test lives in LabanCore and runs in-process against a
  fixture session, not through the control server.
  Rationale: It needs no PTY or child process, answers in milliseconds, and
  exercises the same `laban_session_*` path every tab uses. Placing it in
  LabanCore leaves it reusable by a future `laban --version --verbose` or
  control endpoint.
  Date/Author: 2026-09-25 / Claude.

- Decision: Detect a stale session daemon by comparing the identity (device
  and inode) of the executable the daemon has mapped with the file installed
  as this app's `labpty`, instead of adding a build field to the labpty hello
  handshake.
  Rationale: The labpty protocol is frozen (ADR 0007). The first version
  compared the process start time with the binary's modification time, but
  `ditto` (install-app, Sparkle) preserves build-time mtimes, so a daemon
  restarted between a build and its install was never flagged. A code hash
  via `SecCodeCopyGuestWithAttributes` also failed: it hashes the file now on
  disk, not the mapped one. The mapped file's inode is what the process
  actually runs.
  Verified live: the pre-install daemon (pid 67765) reports a different build.
  Date/Author: 2026-09-25 / Claude, after independent review.
  Date/Author: 2026-09-25 / Claude.

- Decision: Credit Eric Lengyel's Slug algorithm, but not the generic
  techniques used elsewhere.
  Rationale: The default renderer is named after it and follows its published
  reference. Credits cover named, published works that a visible feature is
  built on (libghostty-vt, Slug, JetBrains Mono, Sparkle, Selenized), not
  textbook methods.
  Date/Author: 2026-09-25 / Claude, at the user's prompt.

## Validation and Acceptance

- `swift test --filter TerminalCapabilitySelfTestTests`: 3 pass; with Kitty
  graphics enabled every probe passes, and disabled reports `.disabled`.
- `swift test --filter AboutInfoTests`: 5 pass.
- `python3 scripts/gen-localizable-xcstrings.py --check` passes (240 strings).
- In the installed app, About Laban shows:
  - team `3563RJWBQP` with hardened runtime;
  - the VT core `libghostty-vt 7c40388b2 (Ghostty), 3 local patches`;
  - the effective renderer;
  - and a self-test result of "10 of 10 as expected".
