# Production Agent Control Broker and CLI

This ExecPlan is a living document maintained in accordance with `PLANS.md` at
the repository root. Keep `Progress`, `Decision Log`, and `Validation and
Acceptance` current as work proceeds. This plan builds on the observe-first
control plane from `execplans/active/agent-first-phase2-mount-live-and-security-floor.md`
and the user-facing contract in `docs/process/controlling-agent-control-plane.md`.
It does not grant live terminal input, mouse control, clipboard mutation, tab
switching, or cross-tab authority.

## Purpose / Big Picture

After Phase 2, Laban has a secure live-GUI control plane, but it is still awkward
for real agents to use. A production agent should not have to know where the
bundled `laban-agent` binary lives, should not accidentally burn a one-shot
attach bootstrap, and should not receive a confusing `401` when the real problem
is "wrong helper path" or "not a direct child of the session shell." After this
plan, an agent-attached Laban session can launch a Laban-owned broker that
redeems C14 correctly, holds the session-observe connection, and exposes a small
agent-facing client surface for observation and command proposals.

The user-visible result is: from a Laban agent-attached session,
`laban agent run -- <agent>` process-replaces itself with the verified sibling
`laban-agent`, that helper redeems C14 and starts the real agent with
`LABAN_AGENT_CONTROL_URL`, and descendants can run `laban session state --json`,
`laban session scroll --rows -40 --json`, or `laban propose --purpose ... -- git
status --short`. From any same-user process, `laban status --json` uses
app-observe only. All forbidden operations still fail with clear, non-secret
diagnostics. The installed app bundle, not a `$PATH` lookup, is the production
helper source.

## Progress

- [x] (2026-07-07) Read `PLANS.md`, `docs/process/controlling-agent-control-plane.md`,
  `execplans/agent-first-terminal-design.md`, and the active Phase 2 plan.
- [x] (2026-07-07) Performed a live probe from an agent-attached session:
  in an explicit C14-enabled agent-attached session, `LABAN_CONTROL_URL` and
  `LABAN_SESSION_ATTACH` were present; ordinary sessions and non-opt-in
  agent-attached sessions must not receive `LABAN_SESSION_ATTACH`; bare
  `laban-agent` was not on `PATH`; the installed bundle contained
  `~/Laban.app/Contents/MacOS/laban-agent`; the repo-built helper failed C14
  attach with `401`; app-observe reads worked through `control.json`.
- [x] (2026-07-07) Spawned a review agent for this plan and folded in the
  material findings: install shims must preserve `exec`, Milestone 2c must add
  server/catalog/security work rather than CLI wrappers only, production
  `laban agent serve` is removed until it has an equivalent authority boundary,
  and CLI drift must be checked against `IntentCatalog`.
- [x] (2026-07-07) Folded in an external ChatGPT-5.5 Pro review: define the MVP
  merge target, require secure `control.json` open-then-`fstat` reads, avoid
  long-lived upstream streams over the single C14 fd, require broker
  heartbeat/idle behavior, make raw requests explicitly non-authoritative, and
  specify child stdio/signal/process-lifecycle behavior.
- [x] (2026-07-07) Folded in final review hardening: child agents must not
  inherit the held C14 upstream fd or proxy fds, the proxy has resource caps for
  buggy descendants, and broker/child shutdown has a concrete default policy.
- [ ] Milestone 1: Add shared app-observe discovery parsing and a `laban` CLI
  product for app-observe reads.
- [ ] Milestone 2: Extend `laban-agent --control-attach` with a private
  session proxy and add `laban agent run -- <command>` as an `execve` launcher.
- [ ] Milestone 2b: Add session CLI commands (`laban session ...`, `laban
  propose ...`) that use `LABAN_AGENT_CONTROL_URL` and never redeem C14 directly.
- [ ] Milestone 2c: Add production-grade inventory, terminal text capture,
  streaming/wait commands, agent hooks, exit codes, completions, and install
  shims so the CLI is useful beyond raw state/proposal smoke tests.
- [ ] Milestone 3: Expand command proposals from a one-shot create action into a
  useful lifecycle with list/status/cancel, audit, and event/wait hooks.
- [ ] Milestone 4: Make diagnostics, redaction, docs, and operator controls
  production-grade.
- [ ] Milestone 5: Add installed-bundle end-to-end tests and release checks.
- [ ] Review Gate passed.

## Context and Orientation

Laban is a macOS terminal app. The GUI process owns the real tabs, terminal
sessions, and render state. Phase 2 mounts a live control server in that GUI
process over a Unix domain socket. A Unix domain socket is a local filesystem
socket, not a TCP port; a web page cannot connect to it. The server is still
HTTP/1.1 framed, so local tools can send familiar `GET /debug/state` requests
through `curl --unix-socket` or `ControlUDSClient`.

Current important files:

- `Sources/LabanControl/LabanControlServer.swift`: owns the UDS listener,
  bearer-token checks, C14 attach redemption, connection-bound session-observe
  credentials, and route dispatch.
- `Sources/LabanControl/ControlUDSClient.swift`: small Swift client for making
  HTTP-over-UDS requests and redeeming `LABAN_SESSION_ATTACH`.
- `Sources/LabanControl/ControlProcessInfo.swift`: validates that a C14 attach
  redeemer is the expected bundled `Contents/MacOS/laban-agent` helper.
- `Sources/LabanApp/Control/ControlSessionLaunchCoordinator.swift`: mints the
  single-use attach bootstrap for explicit agent-attached sessions and registers
  the session shell PID.
- `Sources/LabanAgent/main.swift`: currently has `--control-attach`, which
  redeems the bootstrap and proxies JSONL requests on stdin/stdout.
- `Sources/LabanApp/Control/LiveIntentRouter.swift`: serves live GUI observe and
  proposal intents.
- `Sources/LabanCore/Intents/IntentCatalog.swift`: declares intent ids,
  capabilities, availability, risk, audit, and sensitivity.
- `Sources/LabanControl/ControlRouteCatalog.swift`: maps HTTP routes to catalog
  intents.
- `scripts/build-app`: builds `LabanApp`, `laban-agent`, `laband`, and `labpty`
  and copies all four into `.build/laban/Laban.app/Contents/MacOS`.
- `scripts/install-app`: copies `.build/laban/Laban.app` to `~/Laban.app`.

Terms used in this plan:

- **C14 attach**: the Phase 2 one-shot attach handshake. An eligible
  agent-attached session receives `LABAN_SESSION_ATTACH`. The bundled
  `laban-agent` redeems it exactly once over the Laban UDS. The held socket
  connection becomes the session-observe credential.
- **Session-observe credential**: authority to read sensitive state for one
  terminal session and perform benign own-session navigation/proposals. It is
  bound to a socket connection, not a reusable bearer token.
- **App-observe token**: the low-stakes token in `control.json`. It can read only
  redacted app metadata.
- **Agent proxy / broker**: a private Unix-domain socket owned by `laban-agent`
  after it redeems C14. Clients send JSONL request objects to the proxy; the
  agent forwards them over its held session-observe connection and returns JSONL
  responses. The proxy URL is exposed to the launched controlling agent as
  `LABAN_AGENT_CONTROL_URL`.
- **Process replacement / `execve`**: replacing the current process image with
  another executable while preserving PID and parent PID. `laban agent run --
  <command>` uses this so the C14 redeemer is `laban-agent` and remains the
  registered shell's direct child.
- **JSONL**: newline-delimited JSON. Each line is one complete JSON object.
- **Proposal**: a command suggestion shown to the user for review. It is data,
  not PTY input. Laban must not write proposal text to the terminal.

## Observed Production Gaps

The live probe exposed the concrete production gaps this plan addresses:

1. `laban-agent` is correctly bundled by `scripts/install-app`, but not on the
   shell `PATH`. Agents should not guess bundle paths.
2. A repo-built `.build/debug/laban-agent` can talk to the server but fails C14
   for a bundled app because `ControlProcessInfo.isLabanAgentExecutable` expects
   the exact bundled helper path.
3. The C14 redeemer must also be a direct child of the registered session shell.
   Tool commands inside Codex run under wrapper processes (`codex -> rtk ->
   shell`), so launching `laban-agent --control-attach` from a tool subprocess is
   not the same as launching it directly from the Laban session shell.
4. The current JSONL proxy is useful for tests but awkward for production: it
   consumes stdin/stdout, has no discoverable command vocabulary, and returns
   low-level HTTP status without explaining likely operator mistakes.
5. The Phase 2 guide says bad `Host` and `Origin` should be rejected, while the
   current UDS transport explicitly treats Host/Origin as not part of the guard.
   Production docs and tests need one consistent contract.
6. Contemporary terminal and agent CLIs are not just request wrappers. A useful
   surface exposes stable inventory, current-pane identity, readable text
   capture, event subscription, waits, shell completions, and lightweight agent
   UI hooks. Without those, `laban` would be secure but still feel like a
   stunted smoke-test tool.

## Decision Log

- Decision: Treat direct `LABAN_SESSION_ATTACH` redemption as an internal Laban
  mechanism, not the public production integration surface.
  Rationale: It is intentionally strict: exact helper executable, direct shell
  child, one-shot bootstrap, held socket. That is good security but poor
  ergonomics for agent runtimes that run commands through wrappers. A
  Laban-owned broker can satisfy the strict C14 verifier while giving agents a
  stable client surface.
  Date/Author: 2026-07-07 / Codex.

- Decision: Preserve Phase 2 observe-first semantics.
  Rationale: Production usefulness comes from truthful observation, proposals,
  waits, and diagnostics. Live PTY input, mouse injection, clipboard mutation,
  tab switching, and cross-session access stay deferred to Terminal-Lease /
  Computer-Use work.
  Date/Author: 2026-07-07 / Codex.

- Decision: Add a broker first, then a CLI/client, instead of asking users to
  put `~/Laban.app/Contents/MacOS` on `PATH`.
  Rationale: PATH fixes only the easiest failure. They do not fix the direct-child
  requirement, one-shot bootstrap handling, JSONL usability, or diagnostics.
  Date/Author: 2026-07-07 / Codex.

- Decision: `laban agent run -- <command>` must `execve` into sibling
  `laban-agent --control-attach --control-attach-serve-cli --control-attach-run -- <command>`; it must not
  spawn `laban-agent` as a child.
  Rationale: C14 allows only a direct child of the registered shell PID and
  verifies that the connecting process is the expected `laban-agent`
  executable. If `laban` spawned `laban-agent`, the redeemer would normally be a
  grandchild and should fail. Process replacement preserves the parent
  relationship while changing the executable image to the verified helper.
  Date/Author: 2026-07-07 / Codex, from `~/Downloads/control-plane-cli-execplan.md`.

- Decision: Session CLI commands use `LABAN_AGENT_CONTROL_URL` and never fall
  back to direct C14 redemption.
  Rationale: A running agent or helper command is rarely the direct child of the
  registered shell. Direct fallback would be unreliable and would encourage
  bypassing the hardened `laban-agent` holder. The CLI can perform app-observe
  reads directly, but own-session sensitive reads go through the proxy.
  Date/Author: 2026-07-07 / Codex, from `~/Downloads/control-plane-cli-execplan.md`.

- Decision: When `laban-agent --control-attach --control-attach-serve-cli --control-attach-run -- <command>`
  launches a child controlling agent, the proxy accepts only same-uid clients
  whose process is the child or a descendant of that child.
  Rationale: The proxy URL grants own-session sensitive reads. Same-uid
  filesystem permissions alone are weaker than C14's goal. Tying proxy access
  to the launched process tree lets the intended agent and its helper CLIs use
  the proxy while rejecting unrelated same-user processes that discover the
  socket path.
  Date/Author: 2026-07-07 / Codex, from `~/Downloads/control-plane-cli-execplan.md`.

- Decision: Align the UDS Host/Origin contract in docs and tests.
  Rationale: A UDS has no DNS rebinding or browser-origin attack surface, but
  stale TCP-era docs caused a false-positive bug report during live testing.
  The production contract must state the real security boundary: private
  directory, kernel peer credentials, bearer token or bound connection, and
  capability policy.
  Date/Author: 2026-07-07 / Codex.

- Decision: Make the CLI a first-class observation and coordination surface, not
  just a thin wrapper around `/debug/state`.
  Rationale: July 2026 terminal-control surfaces such as pane inventory, text
  extraction, event streams, waits, shell completions, and agent-visible status
  hooks are table stakes for production agents. These features can be delivered
  within the observe-first boundary because they read terminal state, subscribe
  to Laban events, or ask the GUI to display agent status; they do not write to
  the PTY, paste, mutate the clipboard, move the mouse, or switch tabs.
  Date/Author: 2026-07-07 / Codex.

- Decision: Install shims for `laban` must preserve the process parent chain.
  Rationale: C14 attach succeeds only when the verified `laban-agent` remains a
  direct child of the registered session shell. A shell shim that runs
  `Contents/MacOS/laban` without `exec` inserts an extra parent and can break
  attach. The installed command must therefore be a symlink, hardlink, a small
  native launcher that calls `execve`, or a shell wrapper whose final command is
  `exec "$bundle/Contents/MacOS/laban" "$@"`.
  Date/Author: 2026-07-07 / Codex, from review agent.

- Decision: Remove production `laban agent serve` from this plan.
  Rationale: A standalone serving command that prints `LABAN_AGENT_CONTROL_URL`
  without launching a child command lacks the process-tree boundary that makes
  the proxy safe. The production surface is `laban agent run -- <command>`.
  Raw `laban-agent --control-attach` remains a low-level smoke/debug tool, not a
  reusable proxy server. Any future standalone serve mode needs its own
  authority design and tests.
  Date/Author: 2026-07-07 / Codex, from review agent.

- Decision: The CLI command surface must be catalog-backed and drift-tested.
  Rationale: `execplans/agent-first-terminal-design.md` requires CLI/catalog
  parity. Handwritten commands may still provide ergonomic grouping, but every
  control operation must map to an `IntentCatalog` intent, `ControlRouteCatalog`
  route, schema, capability, audit behavior, and live/headless router
  implementation. A drift test must fail when the catalog and CLI disagree.
  Date/Author: 2026-07-07 / Codex, from review agent.

- Decision: Treat Milestones 1, 2, and 2b as the first merge target; treat
  Milestones 2c and later as production extensions unless explicitly pulled into
  the first implementation slice.
  Rationale: The secure broker and minimal CLI are already a coherent,
  testable foundation. Text capture, screen dumps, event subscription, waits,
  hooks, proposal lifecycle, privacy controls, and broader installed-app
  automation are valuable, but bundling all of them into the first merge would
  delay the security-critical broker path and make review less focused.
  Date/Author: 2026-07-07 / Codex, from external review.

- Decision: Streaming and waits must not monopolize the single held C14
  upstream connection.
  Rationale: The broker serializes request/response work over one
  session-observe connection. A long-lived upstream HTTP stream would block
  every other broker request unless the protocol grows safe multiplexing.
  Until then, subscriptions and waits use bounded polling, finite event-batch
  requests, or another explicitly multiplexed server design.
  Date/Author: 2026-07-07 / Codex, from external review.

- Decision: Raw request escape hatches are never the security boundary.
  Rationale: `laban request` and `laban session request` are useful for tests
  and diagnostics, but they may forward arbitrary paths or action names. The
  server's route policy, intent catalog, token tier, session scope, capability
  checks, and audit behavior remain authoritative. CLI-side filters are only
  defense in depth.
  Date/Author: 2026-07-07 / Codex, from external review.

## Plan of Work

### Milestone 1: Shared Discovery and App-Observe CLI

Add a new executable product `laban` and a `LabanCLI` target. Update
`scripts/build-app` so the installed bundle carries `Contents/MacOS/laban`
beside `laban-agent`; if a global shell command is desired, add a later
installer/shim step rather than relying on `$PATH` lookup for the helper. Add
`Sources/LabanControl/ControlDiscovery.swift` so Swift code can safely locate
and parse `control.json` without exposing the token.

`ControlDiscovery` must provide:

```swift
public struct ControlAdvertisementRecord: Equatable, Codable {
  public var url: String
  public var token: String
  public var pid: Int
  public var runId: String
}

public struct RedactedControlAdvertisement: Equatable, Codable {
  public var path: String
  public var url: String
  public var pid: Int
  public var runId: String
  public var hasAppObserveToken: Bool
}
```

It must validate `control.json` with an open-then-verify flow: open the file,
`fstat` the opened fd, validate regular-file type, owner, mode, and bounded size
from that fd, reject symlinks where the platform API allows, then parse only
after validation. It must never print the token. It must validate that the
advertised socket path is inside the trusted Laban control directory, or else
document and test why app-observe accepts the advertised same-user UDS path.

Initial app-observe commands:

```sh
laban discover [--json]
laban status [--json]
laban health [--json]
laban capabilities [--json]
laban request METHOD PATH [--body JSON] [--json]
laban completions SHELL
```

Behavior:

- `discover --json` prints the control file path, socket path, pid, runId, and
  `hasAppObserveToken`, but not the token.
- `status --json` performs `GET /debug/state` with the app-observe token and
  prints the redacted app summary.
- `request METHOD PATH` is a raw app-observe escape hatch and preserves server
  errors. A sensitive endpoint should return `403` and exit non-zero; the CLI
  must not attempt broader authority.
- Raw request commands may forward denied operations for debugging, but the
  server remains the security boundary and must reject operations outside the
  caller's token tier, capability, or session scope.
- `completions SHELL` prints shell completions for `zsh`, `bash`, and `fish`.
  It never needs control-plane authority.

CLI installation:

- Add a Settings or command-palette action named "Install Laban CLI" that creates
  or updates a same-user shim in a conventional user-writable location such as
  `~/.local/bin/laban`. The shim must point at the installed app's
  `Contents/MacOS/laban`, not at `laban-agent`. It must be a symlink, hardlink,
  native `execve` launcher, or a shell wrapper whose final command is exactly
  an `exec` into the bundled `laban`; it must not leave an extra shell parent
  in the `laban agent run` process chain.
- If a command-line installer is added, use `laban install-cli [--prefix PATH]
  [--dry-run]`. It should print exactly what it would install and avoid
  requiring elevated privileges by default.

Acceptance for Milestone 1:

- `swift build --product laban` succeeds.
- `./scripts/build-app` copies both `laban` and `laban-agent` into
  `.build/laban/Laban.app/Contents/MacOS`.
- `swift run laban --help` lists the commands above.
- `swift run laban completions zsh` prints completions without reading
  `control.json`.
- The installed app exposes a documented way to install a `laban` shim; the shim
  resolves the bundled `laban` product and does not expose `laban-agent` as a
  public command.
- An installed-shim E2E proves `~/.local/bin/laban agent run -- <probe>` still
  lets the process that redeems C14 be the bundled `laban-agent` as a direct
  child of the registered session shell.
- `swift test --filter ControlDiscoveryTests` passes, including missing-field,
  open-then-`fstat`, symlink, insecure-permissions, bounded-size,
  trusted-socket-path, and redacted-output tests.
- `swift test --filter LabanCLITests` passes for argument parsing and no-secret
  output.

### Milestone 2: `laban-agent` Session Proxy and `execve` Agent Launch

Extend `laban-agent --control-attach` with a private session proxy socket. The
new flags are:

```text
--control-attach-serve-cli
--control-attach-run -- COMMAND [ARG ...]
```

`--control-attach-run` implies `--control-attach-serve-cli`. The existing
interactive `laban-agent --control-attach` JSONL stdin/stdout mode must remain
unchanged when these flags are absent.

Add `ControlEnvironmentKeys.agentControlURL = "LABAN_AGENT_CONTROL_URL"` in
`Sources/LabanCore/Control/SessionLaunchContext.swift`. This value points at the
`laban-agent` proxy socket, not the app control socket.

Add `Sources/LabanAgent/ControlAttachProxyServer.swift`. The proxy server must:

- create a private temp directory such as
  `$TMPDIR/laban-agent-control.<pid>.<uuid>` with mode `0700`;
- bind a UDS socket inside it, for example `proxy.sock`;
- set close-on-exec on listener and accepted fds;
- ensure the held app-control/C14 upstream fd is also close-on-exec before
  launching the child command, and prove the child cannot use or observe that
  upstream fd, the proxy listener fd, or any accepted proxy client fd;
- reject peer uids that differ from `getuid()`;
- when launched with a child command, reject peers whose pid is not the child
  pid and is not a descendant of the child pid;
- decode one JSON object per line using the existing `LiveControlAttachRequest`
  shape;
- enforce bounded JSONL line size, request body size, concurrent client count,
  per-client idle timeout, and maximum queued requests. Rejected proxy requests
  return a structured error without closing or corrupting the held C14 upstream;
- serialize all forwarded requests over the single held app-control fd so
  concurrent proxy clients cannot interleave HTTP bytes;
- return one `LiveControlAttachResponse` JSON object per line;
- clean up the socket and temp directory on shutdown.

Add a process-tree helper, private to `LabanAgent` unless tests need it shared:

```swift
static func isDescendant(pid: pid_t, of ancestor: pid_t) -> Bool
```

Implement it with repeated parent-pid lookup using the same macOS `sysctl`
approach used by `LabanControlServer`.

Add a `laban agent run -- <command>` CLI command that process-replaces itself
with the sibling `laban-agent` executable. It must resolve the helper from the
realpath of the running `laban` executable, not through `$PATH`:

- packaged: `.../Contents/MacOS/laban` expects
  `.../Contents/MacOS/laban-agent`;
- SwiftPM dev build: `.build/.../debug/laban` expects
  `.build/.../debug/laban-agent`.

The generated argv is:

```text
laban-agent
--control-attach
--control-attach-serve-cli
--control-attach-run
--
<command...>
```

Before `execve`, check that `LABAN_CONTROL_URL` and `LABAN_SESSION_ATTACH` are
present, but never print their values. If either is missing, print a redacted
error that says `laban agent run` requires an eligible agent-attached Laban
session.

When `laban-agent --control-attach --control-attach-serve-cli
--control-attach-run -- <command>` launches the child command:

- add `LABAN_AGENT_CONTROL_URL=<proxy path>`;
- preserve `LABAN_CONTROL_URL` for app-observe fallback;
- remove `LABAN_SESSION_ATTACH` and `LABAN_CONTROL_ATTACH_ENV`;
- record the child pid as the allowed proxy root;
- preserve the child's normal stdin, stdout, and stderr; the broker must not
  consume or proxy the child's terminal stdio;
- default to launching the child in a tracked process group when safe to do so;
- document and test `SIGINT`, `SIGTERM`, and `SIGHUP` behavior. Default policy:
  `SIGINT` is forwarded to the child and the broker exits with the child status;
  if the child exits, the broker exits with the same status; if the broker exits
  first or the upstream connection fails unrecoverably, it sends `SIGTERM` to
  the child process or process group, waits for a bounded grace period, then
  sends `SIGKILL` if needed. Any platform case where a process group is unsafe
  must have an explicit documented alternative;
- wait for the child to exit, stop the proxy, remove the socket directory, and
  exit with the child status.

The broker must keep the held C14 upstream usable during long-running child
commands. If the server has an attached-session idle timeout, the broker sends a
documented heartbeat such as `GET /debug/health` before expiry. Heartbeat
failure is treated as broker death and reported to proxy clients without
printing secrets.

Acceptance for Milestone 2:

- `laban agent run -- env` in an eligible agent-attached session causes the
  process that redeems C14 to be `laban-agent`, not a `laban` child process.
- The child environment contains `LABAN_AGENT_CONTROL_URL` and does not contain
  `LABAN_SESSION_ATTACH`.
- A proxy request from the child or descendant succeeds for `/debug/state`.
- A same-uid process outside the launched child process tree is rejected by the
  proxy when an allowed root pid is configured.
- The proxy directory is `0700`, accepted fds are close-on-exec, and concurrent
  proxy requests are serialized over the held app-control fd.
- The child launched by `laban agent run -- <probe>` does not inherit the held
  app-control/C14 upstream fd, the proxy listener fd, or any accepted proxy
  client fd.
- Oversized JSONL lines, oversized request bodies, too many concurrent clients,
  slow/idle clients, and full request queues receive structured proxy errors
  without closing or corrupting the held C14 upstream.
- `laban agent run -- sleep 600` keeps the C14 upstream usable for at least 10
  minutes of child inactivity, either because no attached-idle timeout applies
  or because the broker heartbeat keeps it alive.
- `laban agent run -- <probe>` preserves child stdin, stdout, and stderr, exits
  with the child's status, cleans up the proxy socket, and has tested
  `SIGINT`/`SIGTERM`/`SIGHUP` behavior.

### Milestone 2b: Session CLI Commands Through the Proxy

Add session-scoped CLI helpers that require `LABAN_AGENT_CONTROL_URL`. These
commands must not read `LABAN_SESSION_ATTACH` and must not call
`ControlUDSClient.redeemAttachBootstrap`.

```sh
laban session state --json
laban session request METHOD PATH [--body JSON] [--json]
laban session scroll --rows N --json
laban session proxy
laban propose --purpose TEXT -- COMMAND [ARG ...]
```

Behavior:

- `session state --json` sends `GET /debug/state` to `LABAN_AGENT_CONTROL_URL`
  and prints the response body.
- `session request METHOD PATH --body JSON --json` sends a raw proxy request and
  prints the response body. This is a diagnostics escape hatch; it is not a
  client-side authority boundary. The server must reject denied actions even if
  a raw proxy request forwards them.
- `session scroll --rows N --json` sends `POST /debug/actions` with
  `{"action":"scrollViewport","deltaRows":N}`.
- `propose --purpose TEXT -- COMMAND [ARG ...]` sends `POST /debug/actions`
  with `{"action":"propose","command":"...","purpose":"TEXT"}`. The CLI never
  writes bytes to the PTY.
- `session proxy` reads JSONL requests from stdin, forwards each line to
  `LABAN_AGENT_CONTROL_URL`, and writes JSONL responses to stdout for agents that
  cannot open UDS sockets directly.

For `propose`, if the user passes a single command string after `--`, use it
exactly. If the user passes multiple argv pieces, join them into a display
command using POSIX single-quote escaping. Example: `git`, `status`, `--short`
becomes `git status --short`; `echo`, `a b` becomes `echo 'a b'`.

Acceptance for Milestone 2b:

- From a normal shell without `LABAN_AGENT_CONTROL_URL`, `laban session state
  --json` exits before any app-control attach attempt and suggests
  `laban agent run -- <command>`.
- From a command launched under `laban agent run -- <command>`,
  `laban session state --json` returns rich own-session `/debug/state`.
- `laban session request GET /debug/sessions/<other-session-id>?includeGrid=true
  --json` returns `403`.
- `laban session request POST /debug/actions --body '{"action":"typeText"}'
  --json` returns the server's denial result; no CLI-side typed command exposes
  that forbidden operation.
- `laban propose --purpose "Inspect repository state" -- git status --short`
  returns a proposal id with `writtenToPTY:false`.

MVP merge target:

- The first mergeable implementation slice is complete after Milestones 1, 2,
  and 2b pass with installed-bundle validation and docs for the supported
  production path.
- Milestone 2c and later remain in this ExecPlan as planned production
  extensions. They may be implemented in the same branch only if the foundation
  remains independently reviewable and the MVP checks continue to pass.

### Milestone 2c: Inventory, Text Capture, Streaming, and Agent Hooks

Add the commands that make `laban` useful as a production terminal-control CLI
without expanding authority beyond observe-first.

Server and catalog work:

- Add explicit `IntentCatalog` entries for inventory, current-session identity,
  terminal text capture, screen dump, event subscription, waits, badge/notify,
  and context bundle actions. Each entry declares capability, availability,
  risk, audit, and sensitivity.
- Add route mappings in `ControlRouteCatalog` and typed request/response
  schemas for every new operation. Prefer stable, named schema types over
  route-local dictionaries so fixture and replay coverage can use the same
  contracts.
- Implement both `LiveIntentRouter` and `HeadlessIntentRouter` behavior, or mark
  an intent unavailable in headless mode with a documented reason and a failing
  parity test expectation. Headless parity is required for content extraction,
  proposal events, waits, and context bundles.
- Keep capability boundaries explicit: app-observe may read redacted inventory;
  session-observe is required for terminal content, current bound session
  details, event payloads containing content, context bundles, badge/notify, and
  proposal details beyond redacted aggregates.
- Add audit and EventLog entries for text capture, screen dump, subscription
  start/stop, wait timeout/success, badge/notify changes, and context bundle
  creation. Audit payloads must not include terminal text or tokens unless the
  destination is already session-observe scoped and explicitly designed for it.
- Add a CLI/catalog drift test that proves every non-raw CLI control command is
  backed by a catalog intent and every catalog intent intended for CLI exposure
  has a documented CLI command.

Inventory and identity:

```sh
laban list --json
laban session current --json
laban proposal list --json
laban proposal status PROPOSAL_ID --json
```

Behavior:

- `list --json` uses app-observe and returns redacted app/session inventory with
  stable tab IDs, stable session IDs, liveness, titles, workspace/process
  metadata allowed by the app-observe privacy setting, and no terminal content.
- `session current --json` requires `LABAN_AGENT_CONTROL_URL` and returns the
  bound session identity, never an active-tab index.
- `proposal list/status` are read-only views over proposals visible to the
  current authority. App-observe may list only redacted aggregate proposal state;
  own-session proposal details require the session proxy.

Terminal text capture:

```sh
laban session get-text --screen [--start-line N] [--end-line N] [--escapes]
laban session get-text --scrollback [--start-line N] [--end-line N] [--escapes]
laban session dump-screen [--format text|json] [--styles]
```

Behavior:

- These commands require `LABAN_AGENT_CONTROL_URL` because terminal content is
  sensitive session-observe data.
- `get-text --screen` extracts visible terminal text by line range. `--scrollback`
  extracts from retained scrollback using the same stable line addressing model
  as the control-plane endpoint. Without `--escapes`, output is plain text and
  does not include ANSI, OSC, or private terminal control sequences.
- `--escapes` may include style-preserving terminal escapes only when the source
  endpoint can produce them safely. It must still not emit Laban control tokens
  or private app metadata.
- `dump-screen --format json --styles` returns rows/cells, cursor position,
  selection metadata when visible, and style attributes needed by agents that
  must reason about the screen shape. `--format text` is optimized for prompt
  context, not pixel-perfect replay.

Streaming, waits, and exit codes:

```sh
laban session subscribe --format ndjson [--since EVENT_ID]
laban wait prompt [--timeout SECONDS]
laban wait proposal --id PROPOSAL_ID --state STATE [--timeout SECONDS]
laban wait command-finished [--proposal-id PROPOSAL_ID] [--timeout SECONDS]
```

Behavior:

- `session subscribe` emits one valid JSON object per line and flushes after
  each event. Event objects include a monotonic event id, type, timestamp,
  session id where permitted, and payload. It should cover prompt readiness,
  shell-integration phase changes, proposal state changes, scroll/selection
  changes when available, and command-finished correlations when available.
- `--since EVENT_ID` replays retained events when they are still available and
  then follows live events. If replay is not possible, the command fails with a
  specific diagnostic rather than silently skipping.
- Event streaming and waits must not hold the single C14 upstream connection
  open indefinitely. Until the control protocol supports safe multiplexing, the
  broker implements them using bounded polling or finite event-batch requests
  from the app-control server and emits local NDJSON to clients.
- Wait commands are implemented on top of subscribe or an equivalent shared
  waiter, not bespoke sleeps. They exit `0` on success, `4` on timeout, and use
  the common non-zero codes below for auth, capability, or transport failure.

Agent UI hooks:

```sh
laban badge set --text TEXT [--pid PID]
laban badge clear [--pid PID]
laban notify --level info|warning|error --title TEXT [--body TEXT]
laban context --json [--max-lines N] [--include state,screen,proposals]
```

Behavior:

- `badge` and `notify` require `LABAN_AGENT_CONTROL_URL`, are scoped to the
  launched agent process tree, are rate-limited, and never mutate terminal
  input, clipboard, tab selection, or scroll position. They let an agent tell
  the terminal "I am working", "blocked", or "needs review" without pretending
  to be user input.
- `context --json` returns a compact bundle for agent prompts: bound session
  identity, shell phase, cwd/repo/process metadata visible to session-observe,
  recent visible text, and relevant proposals. It must redact all tokens and
  must not include other sessions' terminal content.

Common CLI behavior:

- Commands that need only app-observe read `control.json`; commands that need
  terminal content or own-session sensitive state require
  `LABAN_AGENT_CONTROL_URL`.
- Exit codes are stable and documented: `0` success, `2` usage error, `3`
  unavailable control plane or auth failure, `4` timeout, `5` capability or
  scope denied, `6` malformed response or protocol mismatch.
- `--json` commands write machine-readable JSON to stdout and human diagnostics
  to stderr. Token values must never appear in either stream.

Acceptance for Milestone 2c:

- `IntentCatalog`, `ControlRouteCatalog`, typed schemas, live router, headless
  router or explicit unavailability, capability policy, and audit coverage exist
  for every new command in this milestone.
- `laban list --json` works from a same-user process with only app-observe and
  includes stable session IDs but no terminal content.
- `laban session current --json` returns the proxy-bound session id and does not
  depend on the currently selected tab.
- `laban session get-text --screen --start-line 0 --end-line 10` returns visible
  own-session text and fails before content access when the proxy is missing.
- `laban session dump-screen --format json --styles` has snapshot coverage for
  wrapped lines, wide glyphs, cursor, and selection metadata.
- `laban session subscribe --format ndjson` emits valid NDJSON for at least
  prompt readiness and proposal state changes; every emitted line parses as JSON
  and contains no control token.
- Long-lived `subscribe` and `wait` commands do not monopolize the single held
  C14 upstream fd; a concurrent `laban session state --json` succeeds while a
  subscription is active.
- `laban wait prompt --timeout 0.1` returns the documented timeout exit code
  when no prompt event arrives.
- `laban badge set/clear` and `laban notify` are accepted only for the launched
  agent process tree and are denied from an unrelated same-uid process.
- `laban context --json` includes useful recent screen context for the bound
  session and does not include other sessions or tokens.

### Milestone 3: Proposal Lifecycle, Events, and Waits

Turn command proposals into a production workflow rather than a one-shot create
endpoint.

Add or extend model types in `LabanCore`:

- `CommandProposal`: `id`, `targetSessionID`, `command`, `purpose`,
  `createdAt`, `state`, `createdBy`, `displayEscapedCommand`, and audit metadata.
- `CommandProposalState`: `pendingReview`, `acceptedByUser`, `rejectedByUser`,
  `cancelledByAgent`, `expired`.
- `CommandProposalEvent`: state changes suitable for EventLog and future push
  streams.

Extend `LiveIntentRouter` and `HeadlessIntentRouter` with read/query actions:

- `commandProposal.list`
- `commandProposal.get`
- `commandProposal.cancel`

Keep `command.propose` as the creation action. The GUI must show pending
proposals in a review surface that renders command bytes safely:

- control characters and newlines are visible;
- ANSI/OSC sequences are not interpreted;
- bidi override characters are shown;
- long commands are not silently truncated;
- copied text is byte-identical to what the UI says will be copied, or the UI
  shows an explicit difference.

Build on the Milestone 2c subscribe/wait primitives with proposal-specific
correlations that agents need:

- `waitForProposalState(proposalID, state)`;
- EventLog entries for proposal create/accept/reject/cancel and command-finished
  correlations when available.

Acceptance for Milestone 3:

- A session launched through `laban agent run` creates a proposal, lists it, cancels it, and observes the
  cancelled state without terminal input.
- A deceptive command containing a newline, ANSI escape, and bidi override is
  visibly escaped in the UI and in snapshot tests.
- `waitForProposalState` returns success after the proposal state changes and
  times out cleanly otherwise.

### Milestone 4: Diagnostics, Redaction, Docs, and Operator Controls

Make the production contract explicit and observable.

Diagnostics:

- Add local, redacted denial reasons to EventLog and app logs:
  `wrongExecutablePath`, `wrongParentPID`, `missingRegisteredShellPID`,
  `spentBootstrap`, `disabledBySettings`, `capabilityDenied`, `scopeDenied`.
- Keep wire responses generic where needed (`401`, `403`, `425`) so secrets and
  process details are not exposed to arbitrary clients.
- Add `--verbose` to `laban control doctor` to show redacted denial reasons from
  the current process where available.

Redaction and privacy:

- Preserve the current useful app-observe default if it still matches
  `docs/product/spec.md` and ADR 0024: liveness/counts plus same-user-visible
  workspace and process metadata such as title, cwd, repo, process command,
  args, and pid. This metadata is what makes app-observe useful for dashboards,
  session pickers, and "is there an agent session here?" checks without needing
  session-observe.
- Add a snapshot test for app-observe summary keys so usefulness and privacy are
  both intentional. The test should fail when a new key appears or an existing
  useful key disappears without a product-doc update.
- Add a user privacy setting named "Hide workspace and process metadata from
  app-observe." When enabled, app-observe omits titles, cwd, repo, process command,
  args, and pid. Session-observe for the owning agent remains unchanged.
- Document the distinction: app-observe is for useful non-content app/session
  discovery; session-observe is for terminal content and other sensitive
  own-session state. Do not tighten app-observe's default into a nearly useless
  liveness ping unless a later product/security decision explicitly changes the
  spec.

Docs:

- Update `docs/process/controlling-agent-control-plane.md`:
  - describe the `laban agent run` / agent-proxy production path first;
  - keep raw `laban-agent --control-attach` documented as a low-level smoke tool;
  - explain that `laban-agent` is bundled in `~/Laban.app/Contents/MacOS`;
  - state that UDS security is private directory + peer uid + token/bound
    connection + policy; Host/Origin checks are not the UDS security boundary;
  - document exact statuses and fix hints.
- Update `execplans/agent-first-terminal-design.md` only if this plan changes the
  roadmap order or token model.
- Update `docs/product/spec.md` if the privacy setting changes the app-observe
  product contract.

Operator controls:

- Settings has a persistent master switch for the control server from Phase 2.
  Add a separate broker setting if needed: "Allow agent sessions to start control
  broker." Turning it off prevents broker launch and removes broker sockets, but
  does not necessarily disable app-observe unless the master switch is off.

Acceptance for Milestone 4:

- `laban control doctor` or `laban discover/status` diagnostics tell a user that a repo-built helper is the wrong path
  and names the expected bundled helper path without printing any secret.
- With the privacy setting enabled, app-observe JSON omits cwd/process/title
  fields while session-observe still reads own-session rich state.
- The controlling-agent guide no longer instructs production agents to run a raw
  one-shot attach per request.

### Milestone 5: Installed-Bundle E2E and Release Checks

Add tests that exercise the path users actually run.

Test tiers:

1. Unit tests in `Tests/LabanControlTests` for broker request forwarding,
   denial-reason classification, proposal lifecycle state, and no-token logging.
2. App tests in `Tests/LabanAppTests` for agent-attached launch through the
   bundled helper path, cross-session denial, proposal UI state, and privacy
   setting behavior.
3. An installed-bundle smoke script, for example
   `scripts/test-installed-control-broker`, that covers the MVP merge target:
   - runs `./scripts/install-app`;
   - restarts `~/Laban.app`;
   - creates or uses an explicit agent-attached session;
   - verifies `~/Laban.app/Contents/MacOS/laban` and
     `~/Laban.app/Contents/MacOS/laban-agent` exist and are executable;
   - runs `laban status`, `laban agent run -- <probe>`, `laban session state`,
     `laban session scroll`, `laban session proxy`, and `laban propose` checks;
   - verifies the CLI install shim points at `Contents/MacOS/laban`;
   - verifies no TCP listener is created;
   - verifies no token appears in logs other than the app-observe token inside
     `control.json`.
4. A later full CLI smoke script, for example `scripts/test-installed-laban-cli`,
   that runs `laban list`, `laban session get-text`, `laban session subscribe`,
   `laban wait prompt`, `laban badge`, `laban context`, proposal lifecycle, and
   privacy-setting checks after Milestones 2c, 3, and 4 land.

Use `./scripts/check` as the repo-wide close-out gate. In this repo, if SwiftPM
module-cache failures occur in a managed sandbox, set `CLANG_MODULE_CACHE_PATH`
and `SWIFT_MODULE_CACHE_PATH` into `.build/` and pass `--disable-sandbox` before
treating the failure as a code bug.

Acceptance for Milestone 5:

- `./scripts/test-installed-control-broker` passes on a fresh installed app.
- `./scripts/check` passes.
- The installed-bundle smoke test fails before the proxy path exists because
  raw attach from an agent tool subprocess cannot satisfy the direct-child/path
  verifier, and passes after the `laban agent run` path is used.

## Concrete Steps

Work from the repository root:

    cd /Users/rrj/.cursor/worktrees/laban/c2yt

1. Confirm current state:

    rtk ./scripts/install-app
    rtk /bin/test -x "$HOME/Laban.app/Contents/MacOS/laban-agent"

2. Add `ControlDiscovery` in `Sources/LabanControl/ControlDiscovery.swift` and
   tests in `Tests/LabanControlTests/ControlDiscoveryTests.swift`.

3. Add the `laban` product and `LabanCLI` target in `Package.swift`, plus
   `Sources/LabanCLI/main.swift`, parser tests, and app-observe commands.

4. Extend `Sources/LabanAgent/main.swift` with
   `--control-attach-serve-cli` and `--control-attach-run -- <command>`.
   Add `Sources/LabanAgent/ControlAttachProxyServer.swift` if `main.swift`
   would grow too large.

5. Add `Sources/LabanCLI/AgentLauncher.swift`. `laban agent run` must end in
   `execve` into the sibling `laban-agent` path; it must not spawn
   `laban-agent` as a child. Do not add production `laban agent serve` in this
   plan.

6. Add `Sources/LabanCLI/AgentProxyClient.swift` for `laban session ...`,
   `laban propose ...`, and `laban session proxy`.

7. Add catalog-backed server contracts and CLI modules for inventory, text
   capture, streaming/waits, agent hooks, exit-code mapping, shell completions,
   and install-shim support. Keep raw protocol code in shared clients and add a
   CLI/catalog drift test rather than duplicating route assembly in each command.

8. Update `Sources/LabanApp` launch logic only where needed so explicit
   agent-attached sessions can offer `laban agent run -- <agent command>` as
   the supported launch shape.

9. Extend proposal model/router/UI and add event/wait support.

10. Update documentation and tests.

11. Run the validation commands below.

## Validation and Acceptance

Run targeted tests as each milestone lands:

    rtk swift test --filter LabanControlTests
    rtk swift test --filter ControlDefaultOn
    rtk swift test --filter CommandProposals
    rtk swift test --filter AppSessionCoordinatorTests
    rtk swift test --filter ControlDiscoveryTests
    rtk swift test --filter LabanCLITests
    rtk swift test --filter AgentLauncherTests
    rtk swift test --filter AgentProxyClientTests
    rtk swift test --filter SessionTextCaptureTests
    rtk swift test --filter SessionEventStreamTests
    rtk swift test --filter AgentHooksTests
    rtk swift test --filter CLIInstallTests

Run installed-bundle validation:

    rtk ./scripts/install-app
    rtk ./scripts/test-installed-control-broker
    rtk ./scripts/test-installed-laban-cli

Run the full repo gate:

    rtk ./scripts/check

The finished behavior is accepted only when all of the following are true:

- A user can start an explicit agent-attached session through `laban agent run`
  without manually finding the helper binary.
- The child agent environment does not contain `LABAN_SESSION_ATTACH`.
- `laban discover`, `laban status`, and `laban control doctor` style diagnostics
  produce actionable, redacted status.
- Own-session state/scroll/selection/proposal requests work through
  `LABAN_AGENT_CONTROL_URL`.
- Inventory, current-session identity, text capture, screen dumps,
  subscriptions, waits, context bundles, and agent hooks work through the
  appropriate app-observe or session-observe path.
- Cross-session sensitive reads return `403`.
- `laban propose -- <command>` creates a pending proposal and never writes PTY
  bytes.
- Proposal lifecycle operations and waits work.
- App-observe has a snapshot-tested allowlist and an optional privacy setting for
  workspace/process metadata.
- Docs match the UDS contract and agent-proxy production path.
- Installed-bundle E2E passes, not only SwiftPM unit tests.
- The installed app offers a documented `laban` CLI shim or equivalent install
  action, and shell completions are available for supported shells.

The first merge target may be accepted when Milestones 1, 2, and 2b pass, the
MVP docs are updated, and the installed-bundle broker/CLI smoke test passes.
Milestone 2c and later require their own targeted acceptance before being marked
complete.

## Review Gate

A separate fresh-state reviewer must verify these checks before this ExecPlan is
considered complete. The executing agent must not mark this plan done until the
gate passes.

- [ ] `rg -n "LABAN_SESSION_ATTACH" Sources/LabanAgent Sources/LabanApp Tests`
  shows `laban-agent --control-attach --control-attach-serve-cli
  --control-attach-run` removes the bootstrap before launching the child agent,
  and tests assert that behavior.
- [ ] `rg -n "redeemAttachBootstrap" Sources/LabanCLI Tests/LabanCLITests`
  returns no hits outside comments explicitly asserting the CLI must not call it.
- [ ] `rg -n "LABAN_SESSION_ATTACH" Sources/LabanCLI` returns no hits in
  `session` command execution code; hits are allowed only in `agent run`
  preflight errors and help text, and those code paths must not print the
  variable value.
- [ ] `rg -n "agent serve|--control-attach-serve-cli.*--json|agentControlURL"
  Sources/LabanCLI docs Tests` shows no production `laban agent serve` command
  that prints a reusable proxy URL without a child-process boundary.
- [ ] `rg -n "import LabanDebug" Sources/LabanCLI Sources/LabanApp` returns no
  hits.
- [ ] `rg -n "typeText|sendKey|paste|mouse|clipboard|selectTab|newTab|closeTab"`
  over the broker/client implementation shows no live broker route forwarding
  those actions.
- [ ] `rtk swift build --product laban` passes.
- [ ] `rtk swift build --product laban-agent` passes.
- [ ] `rtk swift test --filter ControlDiscoveryTests` passes.
- [ ] `rtk swift test --filter LabanCLITests` passes.
- [ ] A unit test proves `laban discover --json` redacts a synthetic
  `control.json` token whose value is `SECRET_SENTINEL_DO_NOT_PRINT`.
- [ ] `ControlDiscovery` opens `control.json`, validates the opened fd with
  `fstat`, rejects symlinks/insecure modes/oversized files, checks or documents
  the trusted socket path, and never logs the token.
- [ ] A unit test proves `laban agent run -- echo hi` constructs an `execve`
  argv for a sibling `laban-agent` path and does not search `$PATH`.
- [ ] An installed-shim test proves the shim is a symlink, hardlink, native
  `execve` launcher, or final-`exec` shell wrapper, and that `laban agent run`
  through the shim still satisfies the C14 direct-child verifier.
- [ ] A broker held idle longer than the attached-session timeout can still
  serve `laban session state --json`, or the test proves no attached-session
  idle timeout applies.
- [ ] A test proves the child launched by `laban agent run -- <probe>` does not
  inherit the held app-control/C14 upstream fd, the proxy listener fd, or any
  accepted proxy client fd.
- [ ] Tests prove oversized JSONL lines, oversized request bodies, too many
  concurrent clients, slow/idle clients, and full request queues return
  structured proxy errors without closing or corrupting the held C14 upstream.
- [ ] `laban agent run` preserves child stdin/stdout/stderr, exits with the
  child status, removes the proxy socket, and has tested
  `SIGINT`/`SIGTERM`/`SIGHUP` behavior.
- [ ] A unit test proves `laban session state --json` reads
  `LABAN_AGENT_CONTROL_URL`, constructs `GET /debug/state`, and does not read
  `LABAN_SESSION_ATTACH`.
- [ ] A catalog parity test proves every non-raw CLI control command maps to an
  `IntentCatalog` intent, `ControlRouteCatalog` route, typed schema, capability,
  audit behavior, and live/headless router behavior or explicit documented
  unavailability.
- [ ] A unit test proves `laban list --json` uses app-observe, includes stable
  session IDs, and excludes terminal content/grid text.
- [ ] A unit test proves `laban session get-text` and `dump-screen` fail before
  content access when `LABAN_AGENT_CONTROL_URL` is missing.
- [ ] A test proves `laban session subscribe --format ndjson` writes one valid
  JSON object per line, flushes events, and never prints app-control or
  session-proxy token values.
- [ ] A test proves long-lived `subscribe`/`wait` commands do not monopolize the
  single held C14 upstream fd; concurrent state/proposal requests still complete.
- [ ] A test proves `laban wait prompt --timeout 0.1` returns the documented
  timeout exit code.
- [ ] A test proves `laban badge` and `laban notify` cannot target an unrelated
  same-uid process or another session.
- [ ] A test proves `laban context --json` includes the bound session identity
  and recent screen text while excluding other sessions and tokens.
- [ ] `rtk swift run laban completions zsh` emits shell completions without
  reading `control.json`.
- [ ] The CLI install shim points at `Contents/MacOS/laban`, not
  `Contents/MacOS/laban-agent`.
- [ ] A test proves the agent proxy socket directory is `0700` and accepted fds
  have close-on-exec set.
- [ ] A test proves the agent proxy rejects a same-uid process outside the
  launched child process tree when an allowed root pid is configured.
- [ ] `rtk swift test --filter CommandProposals` passes and includes a test where
  proposal creation does not call any PTY write path.
- [ ] `rtk swift test --filter AppSessionCoordinatorTests` passes and includes an
  installed/bundled-helper-style launch that uses the exact expected helper path.
- [ ] `rtk ./scripts/test-installed-control-broker` passes.
- [ ] `rtk ./scripts/test-installed-laban-cli` passes.
- [ ] `rtk ./scripts/check` passes.
- [ ] `docs/process/controlling-agent-control-plane.md` documents `laban
  status --json`, `laban agent run -- <agent>`, `laban session state --json`,
  `laban list --json`, `laban session get-text`, `laban session subscribe`,
  `laban wait`, `laban badge`, `laban context`, `laban propose`, and
  `laban session proxy` before raw `--control-attach`.
- [ ] Documentation does not instruct generic clients to redeem C14 directly
  with `ControlUDSClient.redeemAttachBootstrap`.
- [ ] No token value appears in test logs or artifacts except inside the
  intended `control.json` app-observe file.

Review status: NOT REVIEWED

## Idempotence and Recovery

The broker socket path must be unique per broker process and removed on normal
exit. Startup may be retried safely after a crash; stale broker sockets should be
detected and removed only if they are not live sockets. The app control socket is
owned by the Phase 2 server and must not be removed by the broker.

If broker attach fails:

- `425` means the session shell PID has not been registered yet; retry briefly
  with bounded backoff.
- `401` means the bootstrap is invalid or spent; do not retry that bootstrap.
  Explain that the agent session must be relaunched.
- `403` means peer credential, helper path, or parent process checks failed.
  Log a redacted local denial reason and tell the user to use the bundled broker
  launch path.

If the child agent exits, the broker exits with the same status. If the broker
exits first, the child should receive EOF/SIGHUP in the same way it would if the
terminal session ended; do not leave a background broker holding session-observe
authority.

## Artifacts and Notes

Live probe evidence from 2026-07-07:

    LABAN_CONTROL_URL=present
    LABAN_SESSION_ATTACH=present
    laban-agent=missing
    /Users/rrj/Laban.app/Contents/MacOS/laban-agent exists
    .build/debug/laban-agent --control-attach -> 401
    control.json mode=600
    app-observe /debug/state -> 200
    app-observe /debug/sessions -> 403
    app-observe typeText -> 404

The failed `.build/debug/laban-agent` attach is expected against an installed
bundled app because `ControlProcessInfo.isLabanAgentExecutable` compares the peer
path to the bundled helper path, and `LabanControlServer.isAllowedAttachRedeemer`
also requires the peer process parent PID to equal the registered session shell
PID.
