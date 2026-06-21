# 24. Agent-Control Server Security: Loopback, Host/Origin, Two-Tier Tokens

Date: 2026-06-20

## Status

Accepted; **amended 2026-06-20** (observe-first for Phase 2) **and 2026-06-21**
(transport → Unix domain socket) — see "Amendment" below. The original two-tier
*control* token model is superseded by two *observe* tiers plus a deferred lease; all
input/clipboard actuation and cross-tab authority move to a future Terminal-Lease /
Computer-Use ADR. **The loopback-TCP transport + `Host`/`Origin` validation in
"Transport hardening" below are superseded by a UDS transport with peer-credential +
filesystem-permission auth** (Amendment §Transport). The fail-closed posture, `0600`
rule, capability-from-catalog policy, audit, indicator, and disable switch are
unchanged.

## Context

ADR 0023 puts an authenticated loopback control server inside the GUI users run.
That server can type into terminals, read scrollback, and capture screenshots —
it is a keylogger- and exfiltration-equivalent surface. Unlike the existing
dev-only debug server (off by default, banned from release builds), this surface
is meant to be safely enable-able in a shipped release GUI, so it needs a real
security model, not just "loopback + a flag."

Lessons that constrain the design:

- **Loopback bind is necessary but not sufficient.** Any web page can `POST` to
  `127.0.0.1` (the CDP/WebDriver class of bug), and `127.0.0.1.<attacker>` DNS
  rebinding defeats a naive bind. Strict `Host`-header and `Origin`-header
  validation are required, not optional.
- **`0600` is not same-user protection.** A `0600` discovery file stops other
  Unix *users*, but any same-user process that knows the path
  (`~/Library/Application Support/Laban/control.json`) can read it. A token that
  is both advertised in a file *and* grants control is therefore unsafe under
  observe-on-by-default.
- **Escape-sequence control is a severe trust boundary.** iTerm2 CVE-2022-45872
  (CVSS 9.8): query responses (DECRQSS/DSR/title read-back) written into the PTY
  *as if typed* are executed by the shell. OSC 52 clipboard *read* is universally
  refused.
- **Fail closed.** ttyd's 2017 RCE set `authenticated = true` on a message that
  merely omitted the token. Absence of a credential must deny.

## Decision

**Posture: token-gated, fail closed, observe-on-by-default — with the default-on
flip gated behind a release checklist, not a phase label.** Through Phase 0–1 the
server is off unless `LABAN_CONTROL_SERVER=1`. The flip to observe-on-by-default
happens only once the floor below exists.

**Transport hardening (every request and stream upgrade):** *(Superseded 2026-06-21 —
the control plane now binds a **Unix domain socket**, not loopback TCP, so items 1–3
below are obviated; see Amendment §Transport. Item 4 — token required, fail-closed —
still holds, alongside peer-credential + filesystem-permission auth.)*

1. Bind `127.0.0.1`/`[::1]` only, never `0.0.0.0`.
2. Validate `Host`: accept only literal `127.0.0.1`/`localhost`/`[::1]`
   (optionally `:port`); strict IPv6 parse (reject `[::1]evil`); reject trailing
   labels (`127.0.0.1.evil.com`, `localhost.evil.com`).
3. Reject any request bearing an `Origin` header (no browser client exists).
4. Missing or invalid bearer token → `401`. Deny by default.

**Two-tier token model (both app-scoped in v1):**

- **Observe token** — advertised in `control.json`, which must be created `0600`
  **from the first byte** (open `O_CREAT|O_EXCL,0600`, write, `fsync`,
  `rename(2)`; never `.atomic`-write-then-`chmod`, which briefly exposes the
  token). Grants `.observe` (non-sensitive state) only.
- **Control/sensitive token** *(superseded for Phase 2 — see Amendment: replaced by an
  agent-attached-only, session-scoped session-observe credential obtained via a
  one-shot attach handshake; no app-wide control token, no live actuation)* — injected
  into the environment
  (`LABAN_CONTROL_TOKEN`/`LABAN_CONTROL_URL`) of children Laban spawns. Grants
  `.control` + `.observeSensitive`. A same-user process can read the file but
  cannot read another process's environment on macOS, so control/sensitive
  authority never sits in a world-path file.
- **Fixture token** — headless tests only (`.fixture`); the shipped GUI never
  grants it.

**Capability tiers, policy generated from the catalog** (a new intent is denied
until classified with a `requiredCapability`): `.observe` / `.observeSensitive`
(scrollback, visible-grid text, process cwd/command, input log, clipboard
summary) / `.control` / `.clipboard` / `.fixture`. Each intent also declares a
`dataSensitivity` (what may leak) independent of its capability (who may call).

**Standing constraints:**

- High-power reads (full keystroke stream, full scrollback) require
  `.observeSensitive`, never bare `.observe`. Every `.control`/`.observeSensitive`
  access is logged to the `EventLog`.
- A user-visible "agent attached" indicator shows when a privileged client is
  connected; a user-facing disable switch exists, plus a **persistent Settings master
  toggle** that disables the server entirely (off ⇒ no server, no `control.json`, no
  injected tokens) for a complete opt-out.
- **No in-band escape-sequence control channel.** Never write title/clipboard
  read-backs into the input stream; constrain DECRQSS/DSR. Programmatic "type
  this" runs through the *same* sanitizer/validation as a human keystroke; all
  agent/model/tool/repo bytes are untrusted before the VT parser. OSC 52 write
  only (behind an explicit opt-in); read never.

Per-session token scoping (one token per session via child-env injection — no
`labpty` wire change, since the wire already carries child `envp`) is deferred to
a later phase; v1 ships a single app-scoped token per tier.

## Amendment (2026-06-20): Observe-first for Phase 2

A security deliberation concluded that an *agent-driven* terminal (programmatic
input, an app-wide control token) creates a sandbox-escape surface that Laban's
lack of an inter-tab boundary makes unsafe to ship by default. Phase 2 ships an
*agent-observable* terminal instead. The following supersede the **Decision** above
for Phase 2; the deferred items return only behind an explicit, user-leased mode.

- **No app-wide control token.** The "Control/sensitive token … grants `.control` +
  `.observeSensitive`" tier is **removed**. There are now two **observe** tiers:
  - **app-observe** — in `control.json`, grants `.observe` only: the
    `app.stateSummary` (liveness/discovery, plus per-tab title/cwd/repo/workspace and
    process command/args/pid — `ps`/`lsof`-equivalent, already same-user-visible, so
    no net-new capability; 2026-06-20 decision). **No terminal content** (grid/
    scrollback/selection/find-needle/clipboard/keystroke log) — that line stays
    `.observeSensitive` (the §5.1 row's "process cwd/command" moves to app-observe;
    its scrollback/grid/input-log stays sensitive).
  - **session-observe** — obtained **only by sessions explicitly marked
    agent-attached** via a **one-shot attach handshake**: the env carries a single-use
    bootstrap (`LABAN_SESSION_ATTACH`, bound to a preallocated `sessionID`) + the URL;
    the agent **redeems it once** for a **connection-bound** credential and the server
    invalidates the bootstrap, so a descendant (npm/test/`curl | sh`) that reads the
    env later finds a spent bootstrap and gets no working credential — **no long-lived
    bearer in any inheritable variable**. Grants `.observeSensitive` + benign
    own-session **view scroll** (`scrollViewport`; **`tab.select` removed** — it
    hijacks focus / redirects keystrokes) **for its own session only**. A normal
    shell's children inherit no sensitive authority. If env secrecy cannot be proven
    on the supported macOS/SIP matrix, no bootstrap is injected at all.
- **Capability `.control` is renamed `.navigate`; `command.propose` splits into
  `.propose`.** Post-pivot the old `.control` granted only benign navigation +
  proposals (it no longer "controls" the terminal), so the name was misleading.
  `.navigate` = benign own-session view scroll (`scrollViewport`; `tab.select` removed
  as a focus-hijack vector); `.propose` = `command.propose`. `control` is **retired**
  (a future actuation/lease
  tier is `.input` + a distinct `.execute`, never `.control`). End-state enum:
  `observe, observeSensitive, navigate, propose, input, clipboard, fixture`.
- **Per-session scoping is pulled forward** (the ADR had deferred it): for
  `.observeSensitive`/`.navigate`/`.propose`, the policy requires `targetSession ==
  token.sessionID`; cross-session → `403`. `session.list`/rich `app.state` are
  redacted to the owning session. Only the test-only `.fixture` token has whole-app
  scope.
- **All input/mouse/clipboard actuation is deferred** to a future Terminal-Lease /
  Computer-Use ADR. `terminal.typeText`/`sendKey`/`paste`/`click`/`mouseWheel`/
  `mouseDrag` form an `.input` capability granted **only** to the `.fixture` token
  (headless E2E), `headlessOnly`, build-gated out of the release GUI where feasible.
  No live GUI surface actuates input. Command assistance ships as **command
  proposals** — a data object the user reviews and runs, never PTY bytes.
- **The future actuation mode is a distinct product mode** ("trust by default" holds
  only inside an enforced boundary): the user picks a target session, a short-lived
  **lease**, visible indicator, command approval/classifier, no self-injection, no
  cross-tab unless named, audit + revocation.

This phase is executed by
`execplans/active/agent-first-phase2-mount-live-and-security-floor.md`.

### Transport (2026-06-21): Unix domain socket, not loopback TCP

The control plane binds a **UDS** at `control.sock` inside a `0700` user-owned dir —
**no TCP listener, no network surface**. This eliminates the loopback-TCP attack class
the "Transport hardening" section above was built to mitigate: DNS rebinding,
browser/CDP CSRF (a web page cannot open a UDS), and any cross-host reachability. The
guard becomes **filesystem permissions** (`0700` dir) **+ kernel peer-credentials**
(`getpeereid`/`LOCAL_PEERCRED`: connecting `uid` must equal the owner) **+ the bearer
token** (fail-closed). `Host`/`Origin` validation is moot. **HTTP request framing + the
JSON/intent wire are retained over the socket** (HTTP-over-UDS), so the catalog,
policy, adapters, and byte-stable response bodies are unchanged — only the listener and
discovery change: `control.json` (still `0600`) and `LABAN_CONTROL_URL` carry the socket
path; readiness emits the path; clients use `--unix-socket`. Peer-credentials also
harden the agent-attach handshake (the redeemer's pid/uid can be checked). A named pipe
was rejected (FIFOs aren't connection-oriented on macOS); a custom protocol was rejected
(no security gain over HTTP-over-UDS). This **migrates the shipped Phase-0/1 loopback-TCP
server**.

## Consequences

- A same-user process that reads `control.json` obtains observe-only,
  non-sensitive state — it cannot drive the terminal or read scrollback. The
  "agent attached" indicator is a backstop, not the primary control.
- The Phase 2 default-on flip is gated on a release checklist: observe-only file
  token; `.observeSensitive`/`.control` on the separate env token; secure
  `0600`-from-first-byte write; Host/Origin tests including malformed hosts;
  visible indicator; disable switch; audit persistence; no token ever logged.
- Agents Laban spawns authenticate with zero prompt (env token); unrelated local
  processes are limited or denied. This mirrors iTerm2's `ITERM2_COOKIE`-into-
  launched-scripts model, which is the security precedent (not its transport
  choice).
- Escape-sequence command attribution (OSC 633/133) is not trusted as
  authoritative without a per-session nonce; until then such state is labeled
  unverified.

## Applies To New Code

- A new intent must declare both a `requiredCapability` and a `dataSensitivity`
  before it ships; unclassified ⇒ denied by the generated policy.
- Never write terminal/title/clipboard read-backs into the input stream.
  Programmatic input takes the same validation path as human input.
- Any code that advertises the server must write the discovery file `0600` from
  the first byte and must place **only** the app-observe token in it — never a
  token granting `.observeSensitive`/`.navigate`/`.propose`/`.input`. Tokens must
  never be logged (log the URL only).
- New transports (MCP, CLI) reuse this token/capability model; they do not invent
  their own auth.
