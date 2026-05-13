# Contributing to Laban

Laban is an agent-driven repository. The way work is planned, executed, and
documented here is deliberate: the project is partly a test bed for autonomous
software development. Human contributors are welcome — there is no
gatekeeping against human work — but the conventions below are oriented
toward agents and apply to everyone.

## How work is planned

- Non-trivial or cross-boundary changes are planned in an **ExecPlan**: a
  self-contained Markdown file under `execplans/active/` describing goals,
  steps, and verification in enough detail that a fresh contributor could pick
  it up cold. The rules live in `PLANS.md`.
- Small contributions (typo fixes, isolated bug fixes, small docs changes) do
  not need an ExecPlan. Open a PR with a clear behavioral reason.
- `AGENTS.md` is the entry-point map. `docs/process/agent-operating-guide.md`
  has the engineering style, verification, and changeset rules.

## How to make a change

1. Read `AGENTS.md` and skim `docs/process/agent-operating-guide.md`.
2. Make sure `./scripts/check` passes locally before opening a PR.
3. Use atomic commits with single-line, reason-style messages: describe *why*
   the change exists, not *what* changed or which files it touches.
4. Keep changesets focused on one behavioral reason.
5. Open a PR. Reviews focus on whether the change is necessary, narrow, and
   verifiable.

## Tests and verification

User-visible terminal behavior must be autonomously verifiable: through unit
tests, debug-state checks, screenshot artifacts, or capture/replay artifacts.
`docs/process/dev-process.md` describes the debug and headless harness.

The minimal local gate is:

```sh
./scripts/check
```

CI (GitHub Actions) runs lint + build on every push and pull request.

## Licensing of contributions

By contributing, you agree that your contributions will be licensed under the
MIT license (see `LICENSE`).
