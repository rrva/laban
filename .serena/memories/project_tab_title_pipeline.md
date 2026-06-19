# Tab title pipeline (as of 73d8d1e, 2026-06-11)

Flow: PTY bytes → C scanners (`laban_session_consume_title`, `tab_status.c` OSC 21337) →
`Session.consumeTitle()/processMetadata()` → `TabMetadataSynchronizer.syncSurfaceMetadata`
→ `TabTitleResolver.titleChoice` → sidebar. Daemon path (`AppSessionCoordinator.refreshTabMetadata`,
250ms) feeds the same synchronizer; labpty mode hardcodes `title: ""` (titles come only from the
local session parse), laband mode re-asserts the title every poll.

Key contracts (fixed 2026-06-11, commits f6cff7b/fb61228/73d8d1e):
- Precedence: user > frozen > agent.taskLabel/sessionName > **live terminalTitle** > repo@worktree > non-shell process > cwd > process > fallback. The OSC title is NOT gated on foreground-process classification (that gating caused the "all tabs say laban" regression when `-zsh` became a recognized shell).
- Title staleness is ownership-liveness: `TabMetadataSynchronizer` records the owner ProcessIdentity when a title is set and clears the title only when the owner pid is dead (`processIsAlive`, injectable for tests). Foreground pid flutter (agent tool subprocesses) must never wipe a live owner's title ("title lottery").
- `syncTitle` resolves the tab index BEFORE `session.consumeTitle()` (consume clears the C dirty flag; consuming first dropped titles during tab rebuilds).

E2E harness: `Tests/LabanDebugTests/TabTitleEndToEndTests.swift` — real /bin/sh PTY via
`HeadlessDebugRuntime(sessionMode: .realShell)`, client script exercises OSC 0/2/21337.
In deterministic mode each `runtime.state()` call = one sync pass (process refresh throttled
0.25s), so wipe/consume races are reproducible by driving pass timing explicitly.

Notes / open items:
- `workspace.repoName` is only set by the headless debug runtime; production folder line = cwd basename.
- Generation gating (9981626) skips per-tab sync while `dirtyGeneration` unchanged; any output bytes (incl. title-only OSC) bump it, but zero-output process transitions can be observed late on the local path (daemon path is not gated). Headless uses `.pollAllSessions` which bypasses gating.
- Foreground detection (libproc/tcgetpgrp) often reports the login shell while an agent runs — don't re-introduce shell-gating of titles.
- Future direction researched 2026-06-10: agent slot fillable via OSC 21337 extension (taskLabel), on-device Foundation Models summarizer as disambiguator for non-self-labeling tabs.
