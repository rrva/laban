# 13. The RPG Semantic Graph Is a Committed, Generated Artifact Owned by `main`

Date: 2026-05-31

## Status

Accepted.

Governs `.rpg/graph.json` and the `rpg` MCP server. Operational how-to lives in
`docs/process/rpg-graph-maintenance.md`; this ADR records the durable policy.

## Context

[rpg-encoder](https://github.com/userFRM/rpg-encoder) builds `.rpg/graph.json`, a
semantic graph that maps every entity (function/class/method) to *what it does*
— lowercase verb-object "features" — plus dependency and containment edges,
served to agents through the `rpg` MCP server. It is committed to git on purpose:
a fresh clone or worktree gets intent-based code search for free.

Two recurring problems shaped this decision:

- **Lifting lags structure.** Structure extraction (tree-sitter) is free and
  deterministic and tracks the tree automatically; "lifting" — an LLM writing the
  features — is the only step that needs a model. So coverage drifts down as code
  grows: it was observed at 79% with ~1069 entities unlifted or stale.
- **Lifting cost.** The in-session agent model (Opus, or Codex) is wasteful for
  what is mechanical summarization, and paid lifting APIs (Haiku, GPT-4o-mini)
  are an unwanted recurring spend.

The repository also runs dozens of concurrent git worktrees (Claude and Codex
agents). A committed 10 MB JSON that the MCP auto-syncs per worktree threatens
unresolvable merge conflicts, 100k-line review diffs, and per-branch churn.

## Decision

Keep `.rpg/graph.json` committed and treat it as a **generated artifact**, not
hand-edited source:

- **`main` is the canonical owner.** Lifting refresh (`update_rpg` → lift →
  commit) happens on `main`, at a *quiescent* checkout. `main` is a live-moving
  tree, so re-lifting against a moving target never converges — lift a settled
  snapshot, commit, and accept a small rolling stale set refreshed at the next
  checkpoint. Stale entities still carry features and remain usable.
- **Lift with a cheap small model.** In Claude Code, dispatch Haiku subagents
  that drive the MCP loop (`get_entities_for_lifting` → `submit_lift_results` →
  repeat → `finalize_lifting` once at DONE). Never spend the in-session
  Opus/Codex model or paid API credits — lifting is mechanical summarization and
  a small model is the correct tool.
- **Feature worktrees read, never write.** They consume the inherited graph for
  search; they do not commit per-branch drift. Per worktree:
  `git update-index --skip-worktree .rpg/graph.json` keeps the MCP's local
  re-sync out of `git status` and out of commits.
- **Git treats it as generated.** Root `.gitattributes`:
  `.rpg/graph.json merge=ours -diff linguist-generated`, with a one-time
  `git config merge.ours.driver true` (shared `.git/config`, covers all
  worktrees). Merges keep our side and regenerate — the graph is never
  3-way-merged.

## Consequences

- A new worktree inherits a fully-lifted graph for free — the committed graph is
  a shared, pre-paid lift cache. Only `embeddings.bin` rebuilds locally (the
  `models/` cache can be symlinked); the gitignored caches (`models/`,
  `embeddings.bin`, `pending_routing.json`, `config.toml`) do not travel.
- No 10 MB JSON merge conflicts, and `git diff` / PR reviews no longer show graph
  churn. Verified by `git check-attr -a .rpg/graph.json` →
  `diff: unset`, `merge: ours`, `linguist-generated: set`.
- Coverage is maintained at near-zero marginal cost: the backlog clear is
  one-time, and steady state is a handful of entities re-lifted per checkpoint by
  a cheap Haiku pass — no Opus tokens, no API credits.
- Feature worktrees need one extra setup step (`skip-worktree`, or a future
  `SessionStart` hook). Not yet automated.

## Applies To New Code

When maintaining the RPG graph: do **not** lift with the in-session/expensive
model or paid API credits — dispatch a small-model worker through the MCP loop,
give it a hard batch floor (small models stop early), call `finalize_lifting`
exactly once at DONE, and confirm the result with `reload_rpg` + `lifting_status`
rather than trusting the worker's self-report. Refresh and commit the graph only
on `main`, against a settled tree; never chase a live-moving checkout. Any new
committed, generated artifact of comparable size should get the same
`merge=ours -diff linguist-generated` treatment. See
`docs/process/rpg-graph-maintenance.md`.
