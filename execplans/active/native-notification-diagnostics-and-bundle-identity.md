# Make Native Notification Delivery Observable and Isolate Development Bundle Identity

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban can currently decide to post a macOS notification, submit it to `UNUserNotificationCenter`, and log the result to an on-disk JSONL file. An agent using the live app-observe control plane cannot query the native authorization and presentation state, cannot trigger the same native test path as the Settings button, and cannot see the bounded sequence of native delivery stages without reading private runtime files. Development and smoke builds also reuse the production bundle identifier, which allows multiple ad hoc-signed copies with different code hashes to accumulate in LaunchServices under one identity.

After this work, an agent can query native notification state through a bounded debug endpoint, request an explicitly authorized native test notification, and poll a privacy-preserving diagnostic event ring through the running app. Headless mode exposes the same endpoint contract while stating that native delivery is unavailable. Development worktrees and smoke builds receive isolated bundle identifiers so their app registrations do not pollute the canonical `/Users/rrj/Laban.app` identity. The app reports factual signing identity fields but does not warn merely because a bundle is ad hoc signed.

## Progress

- [x] (2026-07-13) Reproduced the current failure boundary: recent live events report authorized banner settings, `UNUserNotificationCenter.add` success, and foreground `willPresent` with banner/list/sound options.
- [x] (2026-07-13) Inspected runtime identity and found six LaunchServices registrations for `com.laban.LabanApp`, all ad hoc signed with distinct CDHashes.
- [x] (2026-07-13) Unregistered every noncanonical Laban bundle and force-registered `/Users/rrj/Laban.app`; verification now reports exactly one registration.
- [x] (2026-07-13) Read `PLANS.md`, the unified attention notifier plan, product regression contract, debug process, observability, worktree isolation, and agent operating guidance.
- [x] (2026-07-13) Add shared bounded native-notification diagnostic models and storage.
- [x] (2026-07-13) Instrument native settings, submission, completion, decision, and foreground presentation stages.
- [x] (2026-07-13) Add cached native state refresh for settings plus pending and delivered counts.
- [x] (2026-07-13) Add runtime bundle/build/signing identity fields without ad hoc warnings.
- [x] (2026-07-13) Add live GUI and headless-parity notification state/test endpoint contracts, schemas, discovery, and tests.
- [x] (2026-07-13) Add configurable and automatically isolated bundle identifiers for worktree and smoke builds.
- [x] (2026-07-13) Update process documentation and CLI examples.
- [x] (2026-07-13) Run focused tests, the full `./scripts/check`, and a canonical bundled build; verify lazy attach against the currently running installed app.
- [ ] Launch the newly built app and verify the new live notification endpoints end to end.
- [x] (2026-07-13) Complete the Review Gate with a fresh agent.

## Decision Log

- Decision: Keep the native test operation outside the ordinary app-observe read capability.
  Rationale: posting a notification can display a banner, play a sound, or request authorization. The read endpoint is safe for app-observe, but the test endpoint must require an explicit GUI-capable action grant such as `navigate` and be invoked through session control or an equivalent authenticated action path.
  Date/Author: 2026-07-13 / Claude

- Decision: Return an accepted event identifier from the test endpoint, then expose completion through the diagnostic ring instead of blocking the route until native callbacks finish.
  Rationale: `LiveIntentRouter` executes GUI routes synchronously on the main thread, while `AgentNotificationPoster.finish` returns asynchronously on the main queue. Blocking would deadlock. A `202`-style accepted response plus polling preserves the current router architecture and makes every stage observable.
  Date/Author: 2026-07-13 / Claude

- Decision: Store privacy-preserving notification diagnostics in a bounded in-memory ring separate from the disk `EventLog`.
  Rationale: the existing JSONL log can contain notification title and body text and requires filesystem access. The control endpoint needs bounded metadata only, with stable sequence numbers and no notification body/title by default.
  Date/Author: 2026-07-13 / Claude

- Decision: Preserve headless contract parity by exposing the endpoints with `nativeAvailable: false` rather than pretending headless can call `UNUserNotificationCenter`.
  Rationale: a headless process does not have the real bundled AppKit delivery environment. Returning an explicit unavailable state is deterministic, testable, and honest while preserving endpoint discovery parity.
  Date/Author: 2026-07-13 / Claude

- Decision: Report signing mode, Team ID, and CDHash as diagnostic facts, but do not display or log an ad hoc-signing warning.
  Rationale: the user explicitly requested no warning for ad hoc signatures and the available Apple Development certificate is expired. The identity fields remain useful when comparing builds without treating ad hoc signing as an error.
  Date/Author: 2026-07-13 / Claude

- Decision: Keep the canonical bundle identifier for the primary checkout, derive a stable path-hash suffix automatically for linked git worktrees, and allow an explicit environment override.
  Rationale: canonical installs must keep `com.laban.LabanApp`. Worktree builds need stable, distinct identities without requiring every agent to remember an environment variable. Smoke builds should use an explicit smoke identifier.
  Date/Author: 2026-07-13 / Claude

## Surprises & Discoveries

- Observation: The running bundle was not signed by a Personal Team certificate. It was ad hoc signed and had a CDHash-only designated requirement.
  Evidence: `codesign -d -r- /Users/rrj/Laban.app` returned `designated => cdhash ...` with no Team ID.

- Observation: Laban had already crossed the native delivery boundary successfully.
  Evidence: the event log contained `attention.notification.delivery` with `outcome=added`, followed by `attention.notification.willPresent` with banner/list/sound options.

- Observation: LaunchServices contained six existing bundles with the same identifier and six distinct ad hoc CDHashes.
  Evidence: read-only `lsregister -dump` parsing found five worktree/smoke bundles plus `/Users/rrj/Laban.app`. After the explicitly authorized cleanup, the same query reports one canonical registration.

- Observation: macOS privacy controls block direct inspection of UserNotifications, Focus databases, and historical unified logs from this process.
  Evidence: the reads failed with `Operation not permitted`, so the application itself needs to expose native state through its loopback control plane.

- Observation: A next-sequence polling cursor must use an inclusive event filter.
  Evidence: the fresh review found that returning `nextSequence = 4` and filtering with `sequence > 4` skipped the next event. The store now filters with `sequence >= since`, with a cursor round-trip regression.

- Observation: An explicitly visible notification test needs lazy attach without gaining reusable authority.
  Evidence: `notifications.test` is now request-exact, outside `ControlSessionObserveFamily`, and non-persistable. An end-to-end server test proves an Always Allow decision degrades to one-time approval and stores no grant.

## Review Gate

A separate fresh agent must verify the following before this ExecPlan is complete:

- [x] Run the focused notification/control tests named in `Concrete Steps`; exit 0.
- [x] Run the bundle-identity resolution test; canonical, explicit override, worktree, and smoke cases produce distinct valid identifiers.
- [x] Inspect `ControlRouteCatalog.endpoints`, `IntentCatalog`, `LiveIntentRouter`, and headless routing; both notification endpoints are discoverable with the intended capability floor.
- [x] Confirm the state response and diagnostic ring omit notification title/body text and expose a hard capacity bound.
- [x] Confirm the test action cannot be called with an ordinary app-observe read token but is available through an explicitly approved, request-exact, non-persistable GUI action scope.
- [x] Confirm no code path emits an ad hoc-signing warning.
- [x] Run `./scripts/check`; exit 0, including 2,029 sequential tests, smoke runtime, and E2E.

Review status: APPROVED (2026-07-13). The fresh reviewer found two blockers (lazy-attach admission and cursor semantics); both were fixed with regressions and the re-review reported no remaining ship-blocking finding.

## Context and Orientation

`Sources/LabanCore/AppModel.swift` creates `AttentionNotificationEvent` values from OSC terminal notifications, BEL, and tab-attention transitions. `Sources/LabanApp/MainWindowController.swift` applies frontmost-tab and user-setting policy, then forwards eligible events to `AgentNotificationPoster`. `Sources/LabanApp/AgentNotificationPoster.swift` calls `UNUserNotificationCenter`, lazily requests authorization, submits immediate requests, and writes structured events to `EventLog`. `Sources/LabanApp/AppDelegate.swift` installs the notification-center delegate and selects foreground presentation options.

The live GUI control surface is routed by `Sources/LabanApp/Control/LiveIntentRouter.swift`. HTTP path and intent mappings live in `Sources/LabanControl/ControlRouteCatalog.swift`. Capability, sensitivity, availability, and schema metadata live in `Sources/LabanCore/Intents/IntentCatalog.swift`. The headless implementation lives under `Sources/LabanDebug` and must retain endpoint contract parity even when a native facility is unavailable. JSON schemas live under `schemas/debug`.

The phrase app-observe means the low-privilege token used by `laban health`, `laban status`, and `laban request` to inspect non-sensitive application state. A notification test is not observation because it can cause visible or audible output, so it must require an explicit action capability.

The phrase diagnostic ring means a fixed-capacity in-memory list of recent metadata records. When capacity is exceeded, the oldest records are discarded. Records must include a monotonic sequence number so callers can request only entries newer than a prior sequence.

The canonical application identity is `com.laban.LabanApp` at `/Users/rrj/Laban.app`. `scripts/build-app` currently hardcodes that identifier into every bundle, including bundles produced in linked worktrees and `.build-smoke`.

## Plan of Work

### Milestone 1: Shared diagnostic state and instrumentation

Add a source file in `Sources/LabanCore`, such as `NativeNotificationDiagnostics.swift`, containing Codable response models and a thread-safe bounded store. The store should track:

- Native availability and latest native settings snapshot.
- Pending and delivered notification counts, with the timestamp of the last completed refresh.
- A bounded metadata-only event ring with sequence, timestamp, event ID, tab ID, source, category, stage, outcome, suppression reason, error domain/code, and foreground presentation options.
- No notification title or body.

Instrument `AgentNotificationPoster` at settings, authorization failure, submit, add success/failure, and final decision boundaries. Instrument `AppDelegate.userNotificationCenter(...willPresent...)` for the foreground presentation boundary. Preserve the existing disk event log.

Add a live-only native state refresher in `Sources/LabanApp` that asynchronously asks `UNUserNotificationCenter` for settings, pending requests, and delivered notifications, then updates the store without blocking the main thread. Refresh at launch, after native add completion, after foreground presentation, and whenever the state endpoint is queried.

Add a runtime identity provider using `Bundle`, `BuildInfo`, and Security.framework signing information. Report bundle identifier/path, build commit/date, signing mode, Team ID when present, and CDHash when available. Do not produce warning fields, alerts, or log messages solely because the signature is ad hoc.

### Milestone 2: Debug/control endpoint contract

Add these endpoint mappings:

- `GET /debug/notifications/state`, intent `notifications.state`, read-only app-observe capability.
- `POST /debug/notifications/test`, intent `notifications.test`, GUI-capable explicit action capability.

The state endpoint accepts an optional `since` sequence query and returns identity, cached native settings/counts, refresh state, recent diagnostic entries, and the next sequence cursor. Querying it requests an asynchronous refresh, so the response must state whether data is refreshing and when counts/settings were last refreshed.

The test endpoint accepts an optional bounded body with `title`, `body`, and `soundEnabled`; defaults use Laban's native test text. It creates a known event ID, posts through the same `AgentNotificationPoster` implementation as real tab attention, and immediately returns accepted metadata containing the event ID. Completion is observed through the state endpoint ring. Validate lengths and reject malformed input without posting.

Wire the live router to a notification test closure owned by `MainWindowController`. Keep normal attention policy unchanged. The explicit test bypasses frontmost-tab and category policy in the same way as the Settings test button.

Expose the same endpoints in headless discovery. The headless state response returns `nativeAvailable: false` plus any deterministic diagnostic records. The headless test route returns a stable unavailable response and never claims native delivery.

Add schemas under `schemas/debug`, catalog/discovery entries, CLI raw-request examples in documentation, and focused tests for capability gating, discovery parity, response privacy, ring bounds, accepted test response, live closure invocation, and headless unavailable behavior.

### Milestone 3: Bundle identity isolation

Update `scripts/build-app` to resolve the bundle identifier in this order:

1. Explicit `LABAN_BUNDLE_IDENTIFIER` when set and valid.
2. A deterministic `com.laban.LabanApp.worktree.<path-hash>` identifier when the checkout is a linked git worktree.
3. Canonical `com.laban.LabanApp` in the primary checkout.

Use the resolved identifier everywhere the generated Info.plist currently hardcodes `com.laban.LabanApp`, including the remote-shell URL type name. Add `--print-bundle-identifier` so tests and agents can inspect the resolved value without building.

Update `scripts/smoke-runtime` to set a dedicated smoke identifier. Update diagnostics preference-domain lookup to use `Bundle.main.bundleIdentifier` with the canonical identifier only as a fallback.

Add a focused shell test that checks canonical default, explicit override validation, linked-worktree derivation, stability across repeated calls, and distinct identifiers for two worktree paths. Wire the test into `scripts/check` in the appropriate scripts/process stage.

### Milestone 4: Documentation, cleanup, and verification

Update `docs/process/dev-process.md` with endpoint contracts, capability expectations, asynchronous test polling, and headless behavior. Update `docs/process/worktree-isolation.md` with bundle-identity isolation and the explicit override. Update `docs/process/observability.md` with the bounded native-notification diagnostic ring.

Run the focused tests and full repository gate. Build an app bundle using `./scripts/build-app`, inspect its generated identifier, and install a dedicated debug bundle path if live verification requires a new build. Do not launch Laban from the shell. The user launches the installed bundle when needed.

After the user is running the new build, verify:

1. `laban request GET /debug/notifications/state --json` returns native settings and identity without notification content.
2. The ordinary app-observe token cannot post the test notification.
3. An explicitly approved `laban session request POST /debug/notifications/test` returns an accepted event ID.
4. Polling notification state shows submit, added or addFailed, decision, and willPresent when foreground.
5. LaunchServices still reports only the canonical installed registration unless a deliberately isolated worktree app has been registered under its distinct identifier.

## Concrete Steps

Work from `/Users/rrj/wrk/laban`.

Before building, check for concurrent Swift builds:

```sh
pgrep -fl "swift build"
```

Run focused Swift tests while iterating:

```sh
swift test --filter 'AgentNotificationPosterTests|AttentionNotification|LiveControlObserveTests|CatalogParityTests|ControlAvailabilityParityTests'
```

Run the bundle identity script test once added:

```sh
./scripts/test-build-app-bundle-identifier
```

Inspect identifier resolution without building:

```sh
./scripts/build-app --print-bundle-identifier
LABAN_BUNDLE_IDENTIFIER=com.laban.LabanApp.manual ./scripts/build-app --print-bundle-identifier
```

Run the full gate:

```sh
./scripts/check
```

Build the app bundle through the supported path:

```sh
./scripts/build-app
```

Do not run `open` or launch Laban from the shell. For live verification, install to a dedicated path and ask the user to launch it:

```sh
LABAN_BUNDLE_IDENTIFIER=com.laban.LabanApp.notification-diagnostics \
  LABAN_INSTALL_DIR="$HOME/Laban-notification-diagnostics" \
  ./scripts/install-app
```

## Validation and Acceptance

The work is complete when all of these are demonstrably true:

- A low-privilege app-observe query returns native notification authorization, alert/list/sound settings, alert style, refresh timestamps, pending/delivered counts, build identity, signing facts, and a bounded recent event list.
- The response never includes notification title or body.
- A test notification cannot be posted with the app-observe read token.
- An explicitly approved GUI control call receives an event ID immediately and the ring later shows the native result.
- The live ring distinguishes settings, submit, added, addFailed, authorization failure, decision, and foreground willPresent stages.
- Headless discovery includes the same endpoint paths and the state explicitly reports native delivery unavailable.
- Headless test requests do not claim success and never call `UNUserNotificationCenter`.
- Ring capacity is mechanically tested and old records are evicted.
- No code path warns merely because signing is ad hoc.
- The primary checkout resolves `com.laban.LabanApp`; linked worktrees resolve stable distinct suffixes; smoke builds use a separate identifier; explicit valid overrides work; invalid identifiers fail before building.
- `./scripts/check` passes.
- The fresh Review Gate passes.

## Idempotence and Recovery

Source edits and tests are repeatable. The diagnostic ring is in memory and resets on app launch. Querying state may request another asynchronous refresh but must not post notifications.

The LaunchServices cleanup already performed is reversible: opening or force-registering one of the removed bundles would register it again. No bundle files were deleted. Future worktree builds prevent identity collision by using distinct identifiers.

If bundle-identifier resolution fails, `--print-bundle-identifier` must fail before invoking SwiftPM. If a worktree identifier changes unexpectedly, compare the canonicalized checkout path and path-hash input before rebuilding.

If live endpoint verification is blocked because the installed app is old, verify the `LABANBuildCommit` stamp, install to the dedicated debug path, and let the user launch it. Never launch the app from the shell.

## Artifacts and Notes

Current forensic baseline:

```text
running bundle: /Users/rrj/Laban.app
bundle id: com.laban.LabanApp
build commit: 4747bcf1
signing: ad hoc, no Team ID, CDHash-only designated requirement
LaunchServices registrations after cleanup: 1
native runtime evidence: authorized, alert style banner, add succeeded, willPresent requested banner/list/sound
```

## Interfaces and Dependencies

At completion, the implementation should expose types equivalent to:

```swift
public struct NativeNotificationDiagnosticEvent: Codable, Sendable {
  public var sequence: Int
  public var timestamp: Date
  public var eventId: String
  public var tabId: String?
  public var source: String?
  public var category: String?
  public var stage: String
  public var outcome: String?
  public var suppressionReason: String?
  public var errorDomain: String?
  public var errorCode: Int?
  public var presentationOptions: [String]?
}

public struct NativeNotificationDiagnosticsSnapshot: Codable, Sendable {
  public var nativeAvailable: Bool
  public var refreshInFlight: Bool
  public var lastRefreshedAt: Date?
  public var settings: NativeNotificationSettingsSnapshot?
  public var pendingCount: Int?
  public var deliveredCount: Int?
  public var events: [NativeNotificationDiagnosticEvent]
  public var nextSequence: Int
}
```

Exact names may follow surrounding conventions, but the behavior and privacy contract must remain. Use Foundation locking or an existing repository lock helper for the bounded store. Use UserNotifications only in `LabanApp`; headless code must not construct `UNUserNotificationCenter.current()`.
