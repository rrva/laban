# 24. Agent-Control Server Security: Loopback, Host/Origin, Two-Tier Tokens

Date: 2026-06-20

## Status

Accepted.

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

**Transport hardening (every request and stream upgrade):**

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
- **Control/sensitive token** — injected into the environment
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
- A user-visible "agent attached" indicator shows when a `.control`-tier client is
  connected; a user-facing disable switch exists.
- **No in-band escape-sequence control channel.** Never write title/clipboard
  read-backs into the input stream; constrain DECRQSS/DSR. Programmatic "type
  this" runs through the *same* sanitizer/validation as a human keystroke; all
  agent/model/tool/repo bytes are untrusted before the VT parser. OSC 52 write
  only (behind an explicit opt-in); read never.

Per-session token scoping (one token per session via child-env injection — no
`labpty` wire change, since the wire already carries child `envp`) is deferred to
a later phase; v1 ships a single app-scoped token per tier.

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
  the first byte and must never place a `.control`/`.observeSensitive` token in
  it. Tokens must never be logged (log the URL only).
- New transports (MCP, CLI) reuse this token/capability model; they do not invent
  their own auth.
