# RPG Semantic Graph — Maintenance & Worktree Strategy

`.rpg/graph.json` is a **committed, generated** semantic code graph built by
[rpg-encoder](https://github.com/userFRM/rpg-encoder) and served to agents via
the `rpg` MCP server. It maps every function/class/method to *what it does*
(verb-object "features"), plus dependency and containment edges. It is committed
on purpose — upstream's own guidance — so a fresh clone or worktree inherits a
fully-lifted graph for free.

This doc is the playbook for keeping it fresh **cheaply** and **without merge
pain** across many git worktrees. Durable policy is in
`docs/adr/0013-rpg-graph-committed-generated-artifact.md`.

## Per-clone setup — two commands, once per clone

Both classic failure modes — textual merge conflicts on the 10 MB JSON, and
structural drift piling into a lift backlog — come from skipping this setup.
Both commands write to the clone's shared `.git`, so one run covers every
worktree of that clone.

```bash
git config merge.ours.driver true   # activate the merge=ours declared in .gitattributes
rpg-encoder hook install            # pre-commit hook: structural sync on every commit
```

- **The merge driver is mandatory, not cosmetic.** `.gitattributes` declares
  `merge=ours` for the graph, but git ignores the attribute unless the clone
  defines the driver. Without it, a two-sided edit falls back to a textual
  3-way conflict inside generated JSON.
- **The hook kills structural drift.** It runs `rpg-encoder update` —
  tree-sitter structure extraction only: deterministic, no LLM, no API key,
  a true no-op when no source changed — and auto-stages `.rpg/graph.json`,
  so every commit carries a graph whose entities, edges, and `base_commit`
  match that commit.

Verify (from any worktree):

```bash
git config --get merge.ours.driver                       # → true (empty = merge=ours is inert)
ls "$(git rev-parse --git-common-dir)/hooks/pre-commit"  # hook installed
```

**Remove any `skip-worktree` flag.** An earlier version of this doc recommended
`git update-index --skip-worktree .rpg/graph.json` per feature worktree. That
flag is incompatible with the hook: `git add` fails on skip-worktree paths, so
the hook aborts and **the commit is blocked**. Clear it in every worktree that
has it:

```bash
git ls-files -v .rpg/graph.json                       # 'S' prefix = flag set
git update-index --no-skip-worktree .rpg/graph.json
```

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

- **Dispatch a fresh Haiku agent with a hardened prompt — do NOT fork — unless
  the orchestrator is itself Haiku.** The cheap-model rule and the "tools must be
  directly callable" rule used to be reconciled by forking the orchestrator (its
  loaded `rpg` tools carry into the fork). That no longer works: `subagent_type:
  "fork"` **ignores the `model` override and always runs the orchestrator's
  model**. Forking from an Opus/Sonnet orchestrator therefore burns the expensive
  model on mechanical summarization — exactly what the Haiku rule forbids. Fork
  *only* when the orchestrator is already Haiku.
  Otherwise spawn a fresh `general-purpose` agent with `model: "haiku"` and a
  prompt hardened to defeat the rabbit-hole the fork used to avoid (a fresh agent
  receives only tool *schemas* from `ToolSearch`, and an unhardened Haiku talks
  itself into "I can't invoke these" and detours into bash/npm/HTTP — observed
  once: 24 wasted turns, zero batches). The prompt that does work:
  - **STEP 0 front-loads the exact selector** and asserts callability:
    `ToolSearch("select:mcp__rpg__lifting_status,mcp__rpg__get_entities_for_lifting,mcp__rpg__submit_lift_results")`,
    then in plain words *"after this call those functions ARE directly callable —
    you CAN invoke them, do not doubt it"*, then a `lifting_status` call to prove
    it (doubles as the reachability check).
  - **An ABSOLUTE rule:** *"the only mechanism is calling the `mcp__rpg__*`
    functions directly; if a call errors, copy it verbatim and STOP — never
    shell/npm/HTTP/CLI."*
  - **A hard batch floor** (see below).
  This combination did not rabbit-hole: successive such workers cleared a 1357-
  entity backlog ~386 entities/pass (78%→89%→…) with zero shell detours.
- **Persist + resume.** The graph is written to disk after *every* submit, so
  work is fully resumable. Chain successive Haiku workers, sequentially (not in
  parallel — see below) — each handles ~10–18 batches (~25 entities/batch)
  before its own context fills.
- **Give workers a hard batch floor.** Haiku tends to "hand off" after 1–2
  batches. Instruct: *"do not report until the tool says DONE or you have
  submitted N batches."*
- **`finalize_lifting` only at DONE.** Calling it mid-flow auto-routes pending
  entities against incomplete signals and locks the hierarchy in early. It *is*
  re-runnable as more entities are lifted later.
- **Reload after workers.** Subagents may hold an isolated MCP session; call
  `reload_rpg` in the orchestrator session to pick up their on-disk writes
  before trusting `lifting_status`.
- **Run workers one at a time, not concurrently.** That same isolated-session
  caveat is why parallel workers are unsafe: if each subagent holds its own
  in-memory graph and `submit_lift_results` rewrites the whole `graph.json`, two
  workers running at once last-writer-wins each other — the second clobbers the
  first's lifts even on disjoint scopes. Sequential workers each load the latest
  on-disk state (including the prior worker's writes) when their session first
  touches a tool, so nothing is lost. Slower, but the only safe order until the
  server's write model is confirmed to merge rather than overwrite.
- **Verify, don't trust self-reports.** Confirm coverage with `reload_rpg` +
  `lifting_status` after a run — workers occasionally miscount or finalize early.

## The treadmill: lift at a quiescent checkpoint, not continuously

With the pre-commit hook installed, structural drift is gone: every commit
ships a graph whose entities and edges match the tree, and `base_commit`
tracks `HEAD`. What goes stale is **semantics only** — an edited entity keeps
its old feature phrases until the next lift, and stale features are still
usable.

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
- **Feature branches carry structural graph updates by design.** With the hook,
  a commit that adds a function updates the graph in the same commit. That is
  the intended behavior, not per-branch drift — do not strip those hunks out.
- **Divergence self-heals.** Two branches each carrying hook-updated graphs do
  not conflict in *local* merges and rebases (`merge=ours` keeps one side
  whole). GitHub's server-side PR merge does **not** run custom merge drivers,
  so when two open PRs both carry graph updates, the second shows a conflict
  after the first lands — resolve locally: rebase onto `main` (where
  `merge=ours` applies) and push. Whichever side "wins", the next commit's hook
  regenerates structure from the actual merged tree; entities dropped in the
  race reappear as a small unlifted set for the next lift pass.
- **`main` owns semantic refreshes.** Full lift passes (`update_rpg` → Haiku
  subagents → `finalize_lifting`) run against `main` at a quiet checkpoint, not
  on feature branches.
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
  Inert until the per-clone driver config (see Per-clone setup) is applied.
- `-diff` — no textual diff, so reviews don't dump ~100k lines of churn.
- `linguist-generated` — GitHub collapses it in PRs.

Beware that `git check-attr -a .rpg/graph.json` reports the *attribute*, not
the driver — it prints `merge: ours` even in a clone where `merge=ours` is
inert. The authoritative check is `git config --get merge.ours.driver`.
