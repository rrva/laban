# Controlling Agent Control Plane Guide

This guide is for a local agent process that wants to observe and assist a live
Laban terminal session through the Phase 2 control plane. It describes the live
GUI contract. The older headless debug server has a wider fixture/testing
surface; do not assume headless-only actions exist in the live app.

## Contract summary

- Transport is HTTP/1.1 over a Unix domain socket. There is no TCP listener.
- The app-level discovery credential is an `app-observe` bearer token stored in
  `control.json`. It is for redacted app/session metadata only.
- A spawned controlling agent uses C14 attach: redeem the one-shot
  `LABAN_SESSION_ATTACH` bootstrap once, then keep that same socket connection
  open. The held connection is the session credential.
- Session credentials are scoped to the agent's own session. Omit target session
  IDs where possible. If a target session ID is supplied, it must be the attached
  session or the request is rejected.
- Phase 2 does not allow live PTY input, key injection, mouse injection,
  clipboard writes, tab switching, or cross-app control. Use command proposals
  for commands the user may choose to run.

## Security rules for agents

Treat these as hard requirements, not suggestions.

1. Never print, log, persist, transmit, or put in crash diagnostics:
   `LABAN_SESSION_ATTACH`, app-observe bearer tokens, raw HTTP Authorization
   headers, or an attached control fd.
2. Do not spawn child processes that inherit the attached control fd. Use
   close-on-exec and close unknown fds before `exec` where practical.
3. Do not cache `LABAN_SESSION_ATTACH`; it is single-use and should be consumed
   immediately.
4. Do not reconnect after C14 attach. If the held connection closes, report that
   the session control connection was lost and let the launcher create a new
   agent/session.
5. Do not use the app-observe token to infer or reconstruct terminal content.
   It intentionally exposes only redacted status/metadata.
6. Do not attempt live input through unsupported debug actions. In Phase 2,
   direct terminal driving is out of scope.

## Availability prerequisites

The live control plane exists only when all of these are true:

- Laban's Settings checkbox **Enable agent control server** is on.
- The process was not launched with `LABAN_CONTROL_SERVER=0`.
- The current user owns the socket and connects from the same uid.
- For C14 session attach, the agent was launched in an eligible agent-attached
  session and received `LABAN_SESSION_ATTACH` from Laban.

The security-floor contract is that `LABAN_SESSION_ATTACH` is only injected for
explicit agent attach/dev/E2E paths, not for ordinary shells. A controlling agent
must handle its absence cleanly.

## Environment variables

| Variable | Who gets it | Meaning |
|---|---|---|
| `LABAN_CONTROL_URL` | Shells/agents launched by Laban while the server is running | Absolute Unix socket path. Use this with `--unix-socket` or the native client. |
| `LABAN_SESSION_ATTACH` | Eligible controlling agent only | One-shot bootstrap for C14 attach. Not a reusable token. |
| `LABAN_CONTROL_DIR` | Dev/test override | Directory containing `control.json`; defaults to `~/Library/Application Support/Laban`. |
| `LABAN_CONTROL_SERVER=0` | App launch override | Force-disables the live control server. |
| `LABAN_CONTROL_ATTACH_ENV=1` | Dev/E2E opt-in | Required for `LABAN_SESSION_ATTACH` to be injected into agent-attached dev/E2E sessions. Ordinary shells never receive it. |

## App-observe: redacted status from `control.json`

External local helpers that are not session-attached may read `control.json` and
perform redacted observation.

Default path:

```sh
CONTROL_JSON="${LABAN_CONTROL_DIR:-$HOME/Library/Application Support/Laban}/control.json"
SOCK="$(jq -r .url "$CONTROL_JSON")"
TOKEN="$(jq -r .token "$CONTROL_JSON")"
```

Minimal redacted state query:

```sh
curl --silent --show-error \
  --unix-socket "$SOCK" \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost/debug/state | jq
```

Expected `app-observe` behavior:

- `GET /debug/state` returns app/window/session metadata with sensitive fields
  redacted.
- It must not include terminal content, find needles, selection text,
  notification bodies, command proposal text, or other sensitive session data.
- Sensitive session endpoints should return `403` or be unavailable.

Use app-observe for dashboards, liveness checks, and choosing whether a session
exists. Use C14 attach for own-session sensitive reads.

## C14 session attach through `laban-agent`

The recommended controlling-agent entrypoint is:

```sh
laban-agent --control-attach
```

It requires both `LABAN_CONTROL_URL` and `LABAN_SESSION_ATTACH`. It redeems the
bootstrap over the Unix socket, keeps the authenticated socket open, and proxies
newline-delimited JSON requests from stdin.

On success it prints a first readiness line:

```json
{"mode":"control-attach","ok":true,"sessionID":"<session-id>"}
```

After that, send one JSON object per line:

```json
{"method":"GET","path":"/debug/state"}
```

Each response is one JSON object:

```json
{"path":"/debug/state","status":200,"body":"{...raw response body...}"}
```

`body` is a string containing the HTTP response body. If the endpoint returns
JSON, parse `body` as JSON after parsing the outer proxy response.

Smoke check:

```sh
laban-agent --control-attach --control-attach-smoke=/debug/state
```

The smoke mode verifies attach and prints the HTTP status for each requested
path. Use JSONL mode for real clients because it returns bodies.

### JSONL examples

Read own-session rich state:

```sh
printf '%s\n' \
  '{"method":"GET","path":"/debug/state"}' \
  | laban-agent --control-attach
```

Read own-session visible grid:

```sh
printf '%s\n' \
  '{"method":"GET","path":"/debug/sessions/<session-id>?includeGrid=true"}' \
  | laban-agent --control-attach
```

Scroll the own-session viewport up by 40 rows:

```sh
printf '%s\n' \
  '{"method":"POST","path":"/debug/actions","body":"{\"action\":\"scrollViewport\",\"deltaRows\":-40}"}' \
  | laban-agent --control-attach
```

Propose a command for user review. This never writes bytes to the PTY:

```sh
printf '%s\n' \
  '{"method":"POST","path":"/debug/actions","body":"{\"action\":\"propose\",\"command\":\"git status --short\",\"purpose\":\"Inspect the working tree before editing\"}"}' \
  | laban-agent --control-attach
```

For long-lived control, start `laban-agent --control-attach` once, read the
ready line, keep stdin/stdout open, and multiplex requests on that process. Do
not start a new `laban-agent --control-attach` for every request; the bootstrap
is one-shot.

## Recommended workflow: broker-first

The recommended way to run a controlling agent is through the broker, not lazy
attach. Start the agent with:

```sh
laban agent run -- <agent-command>
```

`laban agent run` `execve`s into `laban-agent`, which performs the one-shot C14
redeem as a direct child of the registered session shell and then holds that
authenticated socket connection for the launched agent's lifetime. The agent
process, and its descendants, receive `LABAN_AGENT_CONTROL_URL`: a private,
per-process proxy socket that forwards requests over the held connection.

With `LABAN_AGENT_CONTROL_URL` set, `laban session state`, `laban session
request`, and `laban session scroll` talk to the proxy directly and never show
a GUI approval dialog, because the C14 redeem already happened once, at
launch, inside `laban agent run`. `laban session proxy` exists only in this
path; it is broker-only, with no lazy-attach equivalent (see the note at the
end of the next section).

Lazy attach, described next, is a recovery path for a process that is already
running in a registered session without having been started through `laban
agent run`. It is not a replacement for the broker path: prefer `laban agent
run` whenever you are the one starting the agent.

### Session reads: identity, text capture, context

These commands read the bound session and, since the dialog-first design
(`execplans/active/dialog-first-session-observe.md`), fall back to lazy attach
when `LABAN_AGENT_CONTROL_URL` is unset, exactly like `session
state`/`scroll`/`propose`. The approval dialog is accepted as strong enough
consent to release own-session content; the broker path stays available and
byte-identical when the env var is set, as an optional CI/no-dialog route:

```sh
laban session current --json
laban session get-text --screen [--start-line N] [--end-line N] [--max-lines N] --json
laban session get-text --scrollback [--start-line N] [--end-line N] [--max-lines N] --json
laban context --json [--max-lines N]
```

- `session current --json` returns the proxy-bound session's identity, shell
  phase, and last exit code. It composes `session.detail` and
  `shellIntegration.state` and strips any key that looks like a credential
  before printing.
- `session get-text` returns bounded plain-text lines from the visible screen
  (`--screen`) or full scrollback (`--scrollback`), addressed by line range,
  capped by `--max-lines`. It calls the `terminal.getText` intent
  (`dataSensitivity: .scrollback`), now a member of the own-session read family
  a dialog approval grants.
- `context --json` prints a compact bundle for agent prompts: bound session
  identity, shell phase, `session.detail` metadata, and a bounded scrollback
  tail. It is CLI-side composition over `session.detail`,
  `shellIntegration.state`, and `terminal.getText`, not a new server endpoint.
- With no broker, each composed leg is an independent lazy dispatch: under
  "Allow Once" the user sees one dialog per leg; under "Always Allow" the first
  approval persists the whole-family record and the remaining legs auto-approve
  silently. This per-leg behavior is deliberate, not a batching gap.

### Broker-only commands: waits

The `wait` commands still require `LABAN_AGENT_CONTROL_URL` and never fall back
to lazy attach:

```sh
laban wait prompt [--timeout SECONDS]
laban wait command-finished [--timeout SECONDS]
```

- `wait prompt` blocks until the bound session's shell integration phase
  reaches `atPrompt`; `wait command-finished` blocks until the shell's
  completed-command count increments. Both poll `shellIntegration.state` on
  the broker every 200ms (default 30s timeout) rather than holding a
  streaming connection open, because the single C14 upstream connection
  cannot safely multiplex a long-lived stream. They exit `0` on success, `4`
  on timeout, `3` when `LABAN_AGENT_CONTROL_URL` is unset, and `6` on a
  malformed response.

## Lazy attach fallback for already-running agents

A process that is already running in a Laban-registered shell session can
request a one-time, live GUI approval instead of a pre-injected C14 bootstrap.
This is the **lazy attach** fallback. The `laban` CLI uses it automatically when
`LABAN_AGENT_CONTROL_URL` is not set.

Lazy attach request shape:

```json
POST /control/session/attach/request
Authorization: Bearer <app-observe-token>
Content-Type: application/json

{
  "clientRequestID": "<unique-request-id>",
  "cliCommand": "session.state",
  "intendedRequest": {
    "method": "GET",
    "path": "/debug/state",
    "query": "",
    "body": null,
    "bodySHA256": null
  }
}
```

`cliCommand` is one of `session.state`, `session.scroll`, `command.propose`, or
`session.request` for advanced use. `bodySHA256` is required when `body` is
present and must match the SHA-256 of the `body` string.

Response shape:

```json
{
  "ok": true,
  "sessionID": "<session-id>",
  "approval": "once",
  "downstreamStatus": 200,
  "downstreamBody": "{...raw response body...}"
}
```

The user is shown the requesting principal, operation, and data sensitivity. For
a session-read-family request the dialog states the family scope plainly (this
session's screen text, scrollback, and selection, and that the app may suggest
commands for review) and its exclusions (no keyboard input, clipboard, tab
switching, or other sessions). They can choose **Allow Once**, **Always Allow
This App for This Session**, or **Deny**.
Always Allow is only offered for stable, signed, non-generic principals (not
shells, interpreters, or package runners). Approval records are stored in
UserDefaults under `LabanControlAttachApprovalRecordsV1` and can be revoked in
Laban's Settings, Agent tab.

HTTP status mapping:

| Status | Meaning |
|---|---|
| `200` | Approved and downstream executed. |
| `401` | App-observe token invalid or missing. |
| `403` | Denied, not a descendant of a registered session, or route not allowed. |
| `408` | Approval dialog timed out. |
| `409` | Session or process identity changed during approval. |
| `429` | A pending request for this principal/intent is already in flight. |

`session proxy` is not available through lazy attach; it requires the broker
path with `LABAN_AGENT_CONTROL_URL`, and so do the `wait` commands and `agent
run`. `session current`, `session get-text`, and `context` now fall back to
lazy attach: the approval dialog grants the own-session read family (screen
text, scrollback, selection, session detail, proposals), so those reads no
longer require the broker.

### Revoking approvals

"Always Allow This App for This Session" approvals persist as records in
UserDefaults under `LabanControlAttachApprovalRecordsV1`. Each persisted record
is listed in Laban's Settings window, Agent tab, in the approvals list, with a
Revoke button next to it. Revoking a record does not tear down a request that
is already in flight; it takes effect on the next request, which is then
treated as unapproved and prompts again (or is denied, if the user does not
respond in time). Approval records are scoped to the session they were granted
for: when the registered session shell an approval applies to goes away, the
record expires and no longer matches any later request, even from the same
signed principal.

## Live GUI endpoint subset for session-attached agents

The live GUI supports a deliberately small subset. The best client behavior is
to probe the endpoint and handle `403`/`404`, because the headless debug server
has many more endpoints than the live app.

| Endpoint | Method | Body/query | Use |
|---|---:|---|---|
| `/debug` | `GET` | none | Discovery document listing endpoints, controls, and examples. |
| `/debug/capabilities` | `GET` | none | Alias for `/debug` for clients that probe `/debug/capabilities`. |
| `/debug/health` | `GET` | none | Readiness check: returns process readiness (`ok`, `mode`, `frame`, `focused`). |
| `/debug/state` | `GET` | none | Rich own-session state. App-observe receives redacted summary instead. |
| `/debug/sessions` | `GET` | none | Session list scoped to the attached session. |
| `/debug/sessions/<session-id>` | `GET` | `includeGrid=true` optional | Own-session details; with `includeGrid=true`, returns visible-grid cells. |
| `/debug/selection` | `GET` | none | Current selection projection and selected text for the attached session. |
| `/debug/find/state` | `GET` | omit `sessionID` | Current find state for the attached session. |
| `/debug/shell-integration/state` | `GET` | omit `sessionID` | OSC 133 phase, last command exit code, and completed-command count. |
| `/debug/text` | `GET` | `source=screen\|scrollback`, `startLine`, `endLine`, `maxLines` optional | Bounded plain-text lines from the visible screen or full scrollback for the attached session. |
| `/debug/terminal-modes` | `GET` | none | DEC/private mode flags for the attached session. |
| `/debug/scroll-indicator/state` | `GET` | `hover=true` optional | Scroll-indicator state for the attached session. |
| `/debug/actions` | `POST` | `{"action":"scrollViewport","deltaRows":N}` | Move scrollback viewport. Positive/negative rows move according to app semantics. |
| `/debug/actions` | `POST` | `{"action":"propose","command":"...","purpose":"..."}` | Create a user-reviewed command proposal. |

For session-attached callers, omit `sessionID`, `sessionId`, `targetSessionID`,
and `targetSessionId` unless a specific API shape requires it. If supplied, it
must equal the readiness `sessionID`.

## Unsupported live actions in Phase 2

These may exist in discovery output or headless docs, but a live controlling
agent must treat them as unavailable unless a future lease explicitly grants
them:

- `typeText`, `key`, mouse actions, paste/copy, clipboard mutation.
- `newTab`, `closeTab`, `selectTab`, tab movement, window resize.
- `find.start`, `find.step`, `find.stop` as live control actions.
- Capture, replay, fixture, render-trace, pixel-probe, and screenshot artifact
  writes unless running the headless/debug fixture surface.

## Command proposals

A proposal is a review object shown to the user. It is not terminal input.

Request body:

```json
{
  "action": "propose",
  "command": "git status --short",
  "purpose": "Inspect the working tree before editing"
}
```

Response body:

```json
{
  "ok": true,
  "proposalID": "<uuid>",
  "targetSessionID": "<session-id>",
  "state": "pendingReview",
  "writtenToPTY": false
}
```

Rules:

- Keep command text short and exact. The UI displays a safe escaped form.
- Explain why the command is useful in `purpose`.
- Never assume proposal acceptance. Wait for ordinary terminal/shell state to
  reflect any user-run command.
- A `429` means the pending proposal queue is full; stop proposing until the
  user resolves earlier proposals.

### Proposal lifecycle

A proposal moves through these states: `pendingReview` (just created),
`ran` (the user chose to run it), `dismissed` (the user rejected it),
`cancelledByAgent` (the agent withdrew it), and `expired` (it sat in
`pendingReview` past the review TTL). All states except `pendingReview` are
terminal.

Broker-only lifecycle commands (each requires `LABAN_AGENT_CONTROL_URL`, is
scoped to the bound session, and never writes PTY bytes):

```sh
laban proposal list --json                 # proposals for the bound session, newest first
laban proposal status <PROPOSAL_ID> --json # one proposal's current state
laban proposal cancel <PROPOSAL_ID> --json # withdraw a still-pending proposal
laban wait proposal --id <PROPOSAL_ID> --state ran [--timeout SECONDS]
```

Over the wire these are the `commandProposal.list`, `commandProposal.get`, and
`commandProposal.cancel` actions on `POST /debug/actions`, all requiring the
`propose` capability. `cancel` only transitions a `pendingReview` proposal; a
proposal that is already terminal returns `409`. A proposal that targets
another session returns `403`. `wait proposal` polls `commandProposal.get`
until the proposal reaches the requested state or the timeout elapses (exit
`4`), the same bounded-polling model as `wait prompt`.

## Error handling

| Status | Meaning | Agent behavior |
|---:|---|---|
| `200` | Success | Parse the body according to the endpoint. |
| `400` | Malformed request or no such local target | Fix the client request; do not retry unchanged. |
| `401` | Missing/invalid bearer or invalid/spent bootstrap | For C14, exit and let the launcher create a fresh attach path. |
| `403` | Capability or session scope denied | Do not retry. Remove unsupported behavior from the client. |
| `404` | Endpoint unavailable on live GUI, or target not found | Probe a supported endpoint or degrade gracefully. |
| `413` | Body too large | Shrink command/purpose/request. |
| `425` | C14 attach requested before shell PID registered | Retry briefly; the bootstrap is valid but the session is not ready yet. |
| `429` | Too many pending command proposals | Stop proposing and wait for user action. |

Connection-level failures mean the held C14 credential is gone. Do not attempt to
recover by reusing the old bootstrap.

## Suggested controlling-agent loop

1. Check `LABAN_CONTROL_URL`. If absent, control is unavailable.
2. If `LABAN_SESSION_ATTACH` is present, start `laban-agent --control-attach`.
3. Read the ready line and store `sessionID` only in memory.
4. Query `/debug/state` and `/debug/sessions/<sessionID>?includeGrid=true`.
5. Observe state changes using supported GET endpoints.
6. When action is useful, prefer `command.propose`; use `scrollViewport` only for
   navigation.
7. On any `403`, remove that behavior from the current session; it is not an
   intermittent failure.
8. On connection close, report loss of control and stop.

## Direct HTTP request shape

For clients using the Swift `ControlUDSClient` or another UDS HTTP client:

```http
GET /debug/state HTTP/1.1
Host: localhost
Authorization: Bearer <app-observe-token>
Connection: close

```

For an already attached C14 connection, subsequent requests on that same socket
omit `Authorization`; the server binds the session credential to the connection.

```http
GET /debug/state HTTP/1.1
Host: localhost
Connection: keep-alive

```

POST requests must include `Content-Length` and JSON body bytes. Duplicate
`Authorization` or malformed `Content-Length` headers are rejected.

## Implementation pointers

- Environment names: `Sources/LabanCore/Control/SessionLaunchContext.swift`
- App-observe advertisement: `Sources/LabanControl/ControlAdvertisement.swift`
- C14 attach route: `Sources/LabanControl/LabanControlServer.swift`
- UDS client and `laban-agent --control-attach` behavior:
  `Sources/LabanControl/ControlUDSClient.swift`, `Sources/LabanAgent/main.swift`
- Live GUI router subset: `Sources/LabanApp/Control/LiveIntentRouter.swift`
- Intent capability metadata: `Sources/LabanCore/Intents/IntentCatalog.swift`
- Route catalog: `Sources/LabanControl/ControlRouteCatalog.swift`
- `laban` CLI commands and broker-only dispatch: `Sources/LabanCLI/LabanCommand.swift`,
  `Sources/LabanCLI/LabanCLI.swift`
- CLI/catalog drift mapping: `Sources/LabanCLI/CLICatalogMapping.swift`,
  `Tests/LabanCLITests/CLICatalogDriftTests.swift`
