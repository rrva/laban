# Codex Execution Plans (ExecPlans):

This document describes the requirements for an execution plan ("ExecPlan"), a design document that a coding agent can follow to deliver a working feature or system change. Treat the reader as a complete beginner to this repository: they have only the current working tree and the single ExecPlan file you provide. There is no memory of prior plans and no external context.

## How to use ExecPlans and PLANS.md

When authoring an executable specification (ExecPlan), follow PLANS.md _to the letter_. If it is not in your context, refresh your memory by reading the entire PLANS.md file. Read the source material needed to produce an accurate specification, then flesh out the skeleton as you do your research. Re-read only the sections that are relevant to the work in front of you.

When implementing an executable specification (ExecPlan), do not prompt the user for "next steps"; simply proceed to the next step or milestone. Keep the required sections up to date, and update `Progress` whenever work changes state in a meaningful way (for example: started, split, blocked, or completed). Resolve ambiguities autonomously, and commit frequently.

When discussing an executable specification (ExecPlan), record decisions in a log in the spec for posterity; it should be unambiguously clear why any change to the specification was made. ExecPlans are living documents, and it should always be possible to restart from _only_ the ExecPlan and no other work.

When researching a design with challenging requirements or significant unknowns, use milestones to implement proof of concepts, "toy implementations", etc., that allow validating whether the user's proposal is feasible. Read the source code of libraries by finding or acquiring them, research deeply, and include prototypes to guide a fuller implementation.

## Requirements

NON-NEGOTIABLE REQUIREMENTS:

- Every ExecPlan must be fully self-contained. Self-contained means that in its current form it contains all knowledge and instructions needed for a novice to succeed.
- Every ExecPlan is a living document. Contributors are required to revise it as progress is made, as discoveries occur, and as design decisions are finalized. Each revision must remain fully self-contained.
- Every ExecPlan must enable a complete novice to implement the feature end-to-end without prior knowledge of this repo.
- Every ExecPlan must produce a demonstrably working behavior, not merely code changes to "meet a definition".
- Every ExecPlan must define every term of art in plain language or do not use it.

Purpose and intent come first. Begin by explaining, in a few sentences, why the work matters from a user's perspective: what someone can do after this change that they could not do before, and how to see it working. Then guide the reader through the exact steps to achieve that outcome, including what to edit, what to run, and what they should observe.

The agent executing your plan can list files, read files, search, run the project, and run tests. It does not know any prior context and cannot infer what you meant from earlier milestones. Repeat any assumption you rely on. Do not point to external blogs or docs; if knowledge is required, embed it in the plan itself in your own words. If an ExecPlan builds upon a prior ExecPlan and that file is checked in, incorporate it by reference. If it is not, you must include all relevant context from that plan.

## Formatting

Write ExecPlans as ordinary Markdown documents. Use standard headings, lists, tables, and fenced code blocks when they improve clarity. Prose is best for rationale and orientation; lists, checklists, and tables are best for execution steps, status tracking, and verification details. The `Progress` section must use checkboxes. If a `Review Gate` section is present, checkboxes are recommended there as well so a fresh review agent can mark each check explicitly.

## Guidelines

Self-containment and plain language are paramount. If you introduce a phrase that is not ordinary English ("daemon", "middleware", "RPC gateway", "filter graph"), define it immediately and remind the reader how it manifests in this repository (for example, by naming the files or commands where it appears). Do not say "as defined previously" or "according to the architecture doc." Include the needed explanation here, even if you repeat yourself.

Avoid common failure modes. Do not rely on undefined jargon. Do not describe "the letter of a feature" so narrowly that the resulting code compiles but does nothing meaningful. Do not outsource key decisions to the reader. When ambiguity exists, resolve it in the plan itself and explain why you chose that path. Err on the side of over-explaining user-visible effects and under-specifying incidental implementation details.

Anchor the plan with observable outcomes. State what the user can do after implementation, the commands to run, and the outputs they should see. Acceptance should be phrased as behavior a human can verify ("after starting the server, navigating to [http://localhost:8080/health](http://localhost:8080/health) returns HTTP 200 with body OK") rather than internal attributes ("added a HealthCheck struct"). If a change is internal, explain how its impact can still be demonstrated (for example, by running tests that fail before and pass after, and by showing a scenario that uses the new behavior).

Specify repository context explicitly. Name files with full repository-relative paths, name functions and modules precisely, and describe where new files should be created. If touching multiple areas, include a short orientation paragraph that explains how those parts fit together so a novice can navigate confidently. When running commands, show the working directory and exact command line. When outcomes depend on environment, state the assumptions and provide alternatives when reasonable.

Be idempotent and safe. Write the steps so they can be run multiple times without causing damage or drift. If a step can fail halfway, include how to retry or adapt. If a migration or destructive operation is necessary, spell out backups or safe fallbacks. Prefer additive, testable changes that can be validated as you go.

Validation is not optional. Include instructions to run tests, to start the system if applicable, and to observe it doing something useful. Describe comprehensive testing for any new features or capabilities. Include expected outputs and error messages so a novice can tell success from failure. Where possible, show how to prove that the change is effective beyond compilation (for example, through a small end-to-end scenario, a CLI invocation, or an HTTP request/response transcript). State the exact test commands appropriate to the project’s toolchain and how to interpret their results.

Capture evidence. When your steps produce terminal output, short diffs, or logs, include them inside the single fenced block as indented examples. Keep them concise and focused on what proves success. If you need to include a patch, prefer file-scoped diffs or small excerpts that a reader can recreate by following your instructions rather than pasting large blobs.

## Milestones

Milestones are optional. Use them when the work has distinct, independently verifiable stages, when a prototype or migration needs explicit checkpoints, or when a future contributor would benefit from a staged narrative. If you include milestones, introduce each with a brief paragraph that describes the scope, what will exist at the end of the milestone that did not exist before, the commands to run, and the acceptance you expect to observe. Progress and milestones are distinct: milestones tell the story, progress tracks granular work. `Progress` is mandatory; milestones are not.

Each milestone, when present, must be independently verifiable and incrementally implement the overall goal of the execution plan.

## Living plans and design decisions

- ExecPlans are living documents. As the work progresses, keep the plan accurate enough that a fresh contributor can resume from it.
- Every ExecPlan must contain and maintain a `Progress` section and a `Validation and Acceptance` section. These are not optional.
- Add a `Decision Log` section when you make a load-bearing decision: a choice between credible alternatives that affects future code, validation, or operational behavior. Do not log defaults, stylistic preferences, or obvious simplifications.
- Add a `Surprises & Discoveries` section when you encounter non-obvious behavior, bugs, performance tradeoffs, or constraints that materially shaped the implementation. Include short evidence snippets when useful.
- Add an `Outcomes & Retrospective` section at major milestones or at completion when a summary of what was achieved, what remains, or what was learned would help the next contributor.
- Add a `Review Gate` section when the task or repository workflow requires independent review, or when the work crosses a review boundary that benefits from fresh eyes.
- If a section would contain only placeholder text such as `(none yet)`, omit it until there is something worth recording.
- If you change course mid-implementation, document why in the `Decision Log` when that change is load-bearing, and reflect the implications in `Progress`.

## Review gate and review-fix loop

Use a Review Gate when the task or repository workflow requires independent review. The Review Gate defines the checks a separate review agent must perform after the executing agent reports the plan as complete. When a Review Gate is present, the executing agent must not mark the ExecPlan as done until the gate has passed.

The review is performed by a fresh agent with no prior context, spawned by the executing agent using the Agent tool. It receives the ExecPlan, the specific milestone or phase under review, the changed files, and AGENTS.md. It does not receive the executing agent's conversation history. This fresh-state property is what makes the review valuable: the reviewer encounters the code the way the next agent will.

The review-fix loop works as follows:

1. The executing agent completes the work under review and updates Progress to reflect completion.
2. A separate review agent with fresh state reads the ExecPlan's Review Gate section and performs every check listed there.
3. If all checks pass, the review agent marks the Review Gate as passed with a timestamp and brief summary, naming the commit SHA the review ran against.
4. If any check fails, the review agent records specific findings in the Review Gate section with concrete file paths, line references, and what is wrong.
5. The executing agent (or a new agent) reads the review findings and fixes each issue.
6. After fixes, the review agent (fresh state again) re-runs the full Review Gate. Partial re-checks are not sufficient.
7. Steps 4 through 6 repeat until the Review Gate passes cleanly.

The Review Gate should focus on the checks that benefit from fresh eyes. Domain-specific checks are usually the most valuable. Repository-wide baseline commands or policy checks may be included when the repo requires them, but those belong to repository instructions such as `AGENTS.md`, not to PLANS.md itself.

The loop is bounded: stop after three failed reviews on the same gate item. Repeated failure on the same item usually means the gate is mis-specified, the implementation has a deeper problem a local fix is not reaching, or the executing agent and the reviewer are reading the spec differently — none of which converge with another fix-then-review cycle. Append a `Surprises & Discoveries` entry summarising what was tried and surface the issue to a human reviewer instead of spinning further.

### Writing Review Gate items: prefer mechanical checks

Review Gate items must be checkable without judgment by a fresh agent that has never seen the code. A good item names a specific file, command, regex, or assertion ("grep `<pattern>` in `<path>`; expect zero hits"; "run `<command>`; expect exit 0 and stdout containing `<string>`"; "mutate `<file>:<line>` to `<value>`; rerun; expect `<observed>`; revert"). A bad item asks the reviewer to "verify that X is correct" or "ensure error handling is reasonable" — both decay into rubber-stamping because two reviewers will not agree on what passing looks like. When a check needs prose to interpret, lift it out of the Review Gate and into the executing agent's responsibilities. Gates are for things a script could check, not for things a thoughtful human could check.

# Prototyping milestones and parallel implementations

It is acceptable—-and often encouraged—-to include explicit prototyping milestones when they de-risk a larger change. Examples: adding a low-level operator to a dependency to validate feasibility, or exploring two composition orders while measuring optimizer effects. Keep prototypes additive and testable. Clearly label the scope as “prototyping”; describe how to run and observe results; and state the criteria for promoting or discarding the prototype.

Prefer additive code changes followed by subtractions that keep tests passing. Parallel implementations (e.g., keeping an adapter alongside an older path during migration) are fine when they reduce risk or enable tests to continue passing during a large migration. Describe how to validate both paths and how to retire one safely with tests. When working with multiple new libraries or feature areas, consider creating spikes that evaluate the feasibility of these features _independently_ of one another, proving that the external library performs as expected and implements the features we need in isolation.

## Skeleton of a Good ExecPlan

```md
# <Short, action-oriented description>

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds. Add optional sections only when they contain information that will help a fresh contributor.

If PLANS.md file is checked into the repo, reference the path to that file here from the repository root and note that this document must be maintained in accordance with PLANS.md.

## Purpose / Big Picture

Explain in a few sentences what someone gains after this change and how they can see it working. State the user-visible behavior you will enable.

## Progress

Use a list with checkboxes to summarize granular steps. Update this section whenever the work changes state in a way a fresh contributor needs to know, even if it requires splitting a partially completed task into two (“done” vs. “remaining”). This section must always reflect the actual current state of the work.

- [x] (2025-10-01 13:00Z) Example completed step.
- [ ] Example incomplete step.
- [ ] Example partially completed step (completed: X; remaining: Y).

Timestamps are optional. Include them when they help explain ordering or coordination, not as ceremony.

## Decision Log (Optional)

Record load-bearing decisions in the format:

- Decision: …
  Rationale: …
  Date/Author: …

## Review Gate (Optional)

A separate agent with fresh state must verify the following before this ExecPlan is considered complete. The executing agent must not mark the plan as done until this gate has passed. See the "Review gate and review-fix loop" section in PLANS.md for the full process.

List only the checks that this review must verify. Prefer domain-specific checks. Add repository-wide baseline checks only when the repo's own workflow requires them.

- [ ] …

Review status: NOT REVIEWED

Review findings (filled in by the review agent):

(none yet)

## Surprises & Discoveries (Optional)

Document unexpected behaviors, bugs, optimizations, or insights discovered during implementation. Provide concise evidence.

- Observation: …
  Evidence: …

## Outcomes & Retrospective (Optional)

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the result against the original purpose.

## Context and Orientation

Describe the current state relevant to this task as if the reader knows nothing. Name the key files and modules by full path. Define any non-obvious term you will use. Do not refer to prior plans.

## Plan of Work

Describe, in prose, the sequence of edits and additions. For each edit, name the file and location (function, module) and what to insert or change. Keep it concrete and minimal.

## Concrete Steps

State the exact commands to run and where to run them (working directory). When a command generates output, show a short expected transcript so the reader can compare. This section must be updated as work proceeds.

## Validation and Acceptance

Describe how to start or exercise the system and what to observe. Phrase acceptance as behavior, with specific inputs and outputs. If tests are involved, say "run <project’s test command> and expect <N> passed; the new test <name> fails before the change and passes after>".

## Idempotence and Recovery

If steps can be repeated safely, say so. If a step is risky, provide a safe retry or rollback path. Keep the environment clean after completion.

## Artifacts and Notes

Include the most important transcripts, diffs, or snippets as indented examples. Keep them concise and focused on what proves success.

## Interfaces and Dependencies

Be prescriptive. Name the libraries, modules, and services to use and why. Specify the types, traits/interfaces, and function signatures that must exist at the end of the milestone.

If you follow the guidance above, a single, stateless agent -- or a human novice -- can read your ExecPlan from top to bottom and produce a working, observable result. That is the bar: SELF-CONTAINED, SELF-SUFFICIENT, NOVICE-GUIDING, OUTCOME-FOCUSED.

When you revise a plan, ensure your changes are reflected wherever they matter. Keep the document coherent. Add rationale where future readers would not be able to reconstruct it from the code and validation steps alone.
```
