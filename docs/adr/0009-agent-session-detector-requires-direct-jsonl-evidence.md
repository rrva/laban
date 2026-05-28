# 9. AgentSessionDetector Attributes Sessions Only From Direct JSONL Evidence

Date: 2026-05-28

## Status

Accepted. Tightens the per-detector contract first laid down when the
shell-cwd fallback was added to `AgentSessionDetector`. The fallback's
behavior is narrowed; the rest of the detector's API is unchanged.

## Context

`AgentSessionDetector` runs per-tab and decides which Claude session id
belongs to that tab's shell. Two cwd-newest fallbacks existed:

1. Inside `findAgent`, when a live `claude` descendant is found but
   `openVnodePaths` returns no `.jsonl` (Claude Code closes its session
   file while idle).
2. `findRecentClaudeSessionForShellCwd`, when no live `claude`
   descendant is found at all (post-exit recovery).

Both fallbacks resolved the session id by picking the newest
`*.jsonl` in `$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/`. The
disambiguation cue was the shell's cwd alone. Two tabs in the same
repository share that cwd, so both detectors would converge on the
same — invariably the most recently written — jsonl. The tab whose
session was written more recently "won." The other tab's session id
got silently overwritten with its sibling's.

At persistence time `agentByTab[<other tab>]` captured the contaminated
id; on relaunch, `RestoreLaunchPlanner` prefilled `claude --resume
<wrong id>` and the tabs collapsed onto a single conversation.

The fallbacks were correct for the single-shell case they were written
for (recover the session id of a claude that has just exited, or that
has temporarily closed its jsonl fd). The cross-tab failure mode was
not anticipated; the detector had no cross-tab view to disambiguate
from.

## Decision

`AgentSessionDetector` attributes a session id to its shell only from
direct evidence that the jsonl was held open by a process in that
shell's descendant tree. A per-detector `seenAgentJsonlPaths: Set<String>`
records every jsonl path that `findAgent` resolved via
`openVnodePaths(of:)`. Both cwd-newest fallback sites now require the
candidate path to be a member of that set before returning.

First-time attribution must come through the live-fd path. The
fallbacks recover sessions whose ownership was previously witnessed;
they do not bootstrap ownership from cwd similarity.

Paths are canonicalized through `URL(fileURLWithPath:)
.resolvingSymlinksInPath().path` before insertion and lookup so that
libproc's vnode paths (which on macOS are `/private/var/...`) and
FileManager's enumerator results (which on macOS are `/var/...` for
the same on-disk file) compare equal.

## Consequences

- Sibling tabs in the same project directory persist independent
  session ids. The user's reported bug — multiple Claude sessions in
  the same repo collapsing onto a single conversation at restore — is
  fixed.
- A first-tick blind window opens for tabs whose `claude` lives less
  than one detector tick (~2 seconds) and never has its jsonl fd
  caught open. The session id cannot be recovered post-exit; the tab
  persists with `agent == nil` and restore opens a fresh shell. This
  is a niche regression and is strictly safer than the alternative,
  which was inheriting whichever jsonl was most recently written in
  the cwd.
- Already-corrupted `agentByTab` entries on disk from before this ADR
  shipped survive into the first relaunch. Tabs whose persisted
  agent points at a sibling's session will still collapse once on
  that relaunch. The next quit captures the now-clean detector state,
  and subsequent restores are correct. The detector auto-heals; no
  on-disk migration is required.
- The `recentSessionCutoff` parameter on `AgentSessionDetector.init`
  retains its role of filtering stale files but no longer carries
  cross-tab disambiguation responsibility. Sibling tabs opened around
  the same time used to share an effectively identical cutoff and
  could not be told apart; the seen-jsonl gate is the actual
  disambiguator now.
- Tests that previously asserted the shell-cwd-blind fallback
  (`testFindAgentFallsBackToNewestClaudeJSONLForProcessCwd`,
  `testDetectFallsBackToRecentClaudeJSONLForShellCwdWithoutLiveAgent`,
  `testShellCwdClaudeLogLookupIsCachedBriefly`,
  `testObserveNowBypassesCachedClaudeLogMiss`) now seed evidence via a
  live observation first, then exercise the fallback. The intent of
  each test — cache invalidation, post-exit recovery, idle-fd
  recovery, stale-file rejection — survives the rewrite.

## Applies To New Code

Persistence detectors that attribute external state (session ids, log
files, sockets, sub-process artifacts) to a Laban tab must not infer
ownership from a property that multiple tabs can simultaneously
exhibit (shared cwd, shared project dir, shared user). Direct evidence
of containment — an open fd held by a process in this tab's descendant
tree, an explicit handshake, a tab-keyed identifier in the artifact
itself — is the only sound attribution signal. Recovery fallbacks that
operate on weaker signals must verify the result against an
attribution record built from direct evidence.
