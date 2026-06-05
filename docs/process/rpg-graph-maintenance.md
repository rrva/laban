# RPG Semantic Graph — Maintenance & Worktree Strategy

`.rpg/graph.json` is a **committed, generated** semantic code graph built by
[rpg-encoder](https://github.com/userFRM/rpg-encoder) and served to agents via
the `rpg` MCP server. It maps every function/class/method to *what it does*
(verb-object "features"), plus dependency and containment edges. It is committed
on purpose: a fresh clone or worktree inherits a fully-lifted graph for free.

This doc is the playbook for keeping it fresh **cheaply** and for living with it
across many git worktrees.

## Lifting is the only expensive step — use a small model

"Lifting" = an LLM reads each entity and writes 1–5 lowercase verb-object
phrases (`decode hello request frame`, `copy output ring bytes`). Structure
extraction (tree-sitter) is free and deterministic; lifting is the only part
that needs an LLM, and it is **mechanical summarization**, so a small model is
the *correct* tool — not a compromise.

Do **not** spend Opus/Codex (too smart, wasteful) or paid API credits on it.
In Claude Code, dispatch **Haiku subagents** that drive the MCP lift loop — the
"cheaper-model mechanism" `lifting_status` asks for. It costs subscription
tokens only.

### The lift loop (what each worker does)

1. `lifting_status` — note coverage `X/Y` and the stale count.
2. `get_entities_for_lifting(scope="*")` — returns a batch of entities with
   source + a `NEXT_ACTION` block. (Omit `batch_index` on the first call; the
   server tracks what is already lifted, including stale re-lifts.)
3. For every entity key in the batch, write 1–5 verb-object phrases describing
   the **current** behavior. Match house style; for tests describe the asserted
   behavior; for C protocol/proof code describe framing/state-machine/proof
   behavior.
4. `submit_lift_results(features=<JSON string>)` — map each entity key exactly
   as shown in the header (methods as `file:Class::method`) to its phrase array.
5. Follow `NEXT_ACTION`; repeat until it reports **DONE**.
6. `finalize_lifting` — **exactly once, only at DONE**.

### Hard-won gotchas

- **Dispatch the worker as a context fork, not a fresh agent that must
  `ToolSearch`.** Load the `rpg` MCP tools in the orchestrator session first,
  then spawn the Haiku worker as a *fork* so `get_entities_for_lifting` /
  `submit_lift_results` / `lifting_status` are already directly callable in its
  function set. A fresh `general-purpose` subagent only receives the tool
  *schemas* from `ToolSearch`, and Haiku reliably talks itself into "I can't
  invoke these" and rabbit-holes into bash/npm/HTTP workarounds (observed: 24
  wasted turns, zero batches submitted). The fork removes that indirection.
- **Pin the mechanism in the worker prompt.** State plainly: *"the only
  mechanism is calling the `mcp__rpg__*` functions directly; if a call errors,
  report it verbatim and stop — never try shell/npm/HTTP."* Open the prompt with
  a STEP 0 that calls `lifting_status` to prove the tools work before the loop —
  it doubles as the reachability check if a fork ever does lack the server.
- **Persist + resume.** The graph is written to disk after *every* submit, so
  work is fully resumable. Chain successive Haiku forks — each handles ~10–18
  batches (~25 entities/batch) before its own context fills.
- **Give workers a hard batch floor.** Haiku tends to "hand off" after 1–2
  batches. Instruct: *"do not report until the tool says DONE or you have
  submitted N batches."*
- **`finalize_lifting` only at DONE.** Calling it mid-flow auto-routes pending
  entities against incomplete signals and locks the hierarchy in early. It *is*
  re-runnable as more entities are lifted later.
- **Reload after workers.** Subagents may hold an isolated MCP session; call
  `reload_rpg` in the orchestrator session to pick up their on-disk writes
  before trusting `lifting_status`.
- **Verify, don't trust self-reports.** Confirm coverage with `reload_rpg` +
  `lifting_status` after a run — workers occasionally miscount or finalize early.

## The treadmill: lift at a quiescent checkpoint, not continuously

`main` is a live-moving checkout. Re-lifting against a moving tree never
converges — each pass takes minutes, and edits/commits made meanwhile create the
next stale set. (Observed in practice: 893 stale → re-lifted → 275 *new* stale
appeared during the same run.) Stale entities still carry features and remain
usable, so:

- Lift to 100% of a **settled** snapshot, commit it, and accept a small rolling
  stale set that you refresh at the next quiet checkpoint.
- Don't chain workers chasing a tree someone is actively editing.

The backlog clear is one-time; steady state is a handful of entities per commit.

## Worktree strategy

Committing the graph is an asset, not a liability:

- **Shared, pre-paid lift cache.** A new worktree checks out the fully-lifted
  graph and pays nothing to re-lift. Lift once on `main`; N worktrees inherit it.
- **`main` is the canonical owner.** Refresh (`update_rpg` → Haiku lift →
  commit) on `main`. Feature worktrees *read* the graph; they should not commit
  per-branch drift.
- **Neutralize local churn per feature worktree:**
  ```bash
  git update-index --skip-worktree .rpg/graph.json
  ```
  This is stored in that worktree's own index, so `main` keeps tracking the file
  while the worktree ignores the MCP's local re-sync churn — clean `git status`,
  no accidental 10MB commits.
- **Caches don't travel.** `.rpg/.gitignore` excludes `models/`,
  `embeddings.bin`, `pending_routing.json`, `config.toml`. A fresh worktree
  inherits the lifted *features* (in `graph.json`) for free but rebuilds
  embeddings locally. Symlink the code-independent model to skip the
  re-download: `ln -s "$LABAN_MAIN_REPO/.rpg/models" .rpg/models`. Feature/intent
  search over committed features works immediately; only vector similarity needs
  `embeddings.bin`.

## `.gitattributes` (already applied)

The root `.gitattributes` treats the graph as the generated artifact it is:

```gitattributes
.rpg/graph.json merge=ours -diff linguist-generated
```

- `merge=ours` — never 3-way-merge the 10MB JSON; keep our side and regenerate.
  Requires once per clone (lives in shared `.git/config`, so it covers all
  worktrees): `git config merge.ours.driver true`.
- `-diff` — no textual diff, so reviews don't dump ~100k lines of churn.
- `linguist-generated` — GitHub collapses it in PRs.

Verify: `git check-attr -a .rpg/graph.json` → `diff: unset`, `merge: ours`,
`linguist-generated: set`.
