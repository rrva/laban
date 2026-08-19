# Make Native Notification Delivery Observable and Isolate Development Bundle Identity

This ExecPlan is a living document maintained in accordance with `PLANS.md`. Keep `Progress` and `Validation and Acceptance` current as work proceeds.

## Purpose / Big Picture

Laban can currently decide to post a macOS notification, submit it to `UNUserNotificationCenter`, and log the result to an on-disk JSONL file. An agent using the live app-observe control plane cannot query the native authorization and presentation state, cannot trigger the same native test path as the Settings button, and cannot see the bounded sequence of native delivery stages without reading private runtime files. Development and smoke builds also reuse the production bundle identifier, which allows multiple ad hoc-signed copies with different code hashes to accumulate in LaunchServices under one identity.

After this work, an agent can query native notification state through a bounded debug endpoint, request an explicitly authorized native test notification, and poll a privacy-preserving diagnostic event ring through the running app. Headless mode exposes the same endpoint contract while stating that native delivery is unavailable. Development worktrees and smoke builds receive isolated bundle identifiers so their app registrations do not pollute the canonical `/Users/user/Laban.app` identity. The app reports factual signing identity fields but does not warn merely because a bundle is ad hoc signed.

The Notifications Settings tab also offers an explicit Focus troubleshooting check. Laban does not inspect Focus at launch, while posting notifications, during background refresh, or when an agent polls notification state. Only pressing the troubleshooting button may request Focus Status permission and read `INFocusStatusCenter`. The result is cached in the same privacy-preserving diagnostic state so the user and an observing agent can see whether macOS reports that the current Focus silences Laban.

Clicking a delivered Laban notification also returns the user to its originating tab. The ordinary notification tap is the action; no redundant custom action is registered. If the tab was closed or its metadata is absent or malformed, Laban still activates without changing the current tab or crashing.

## Progress

- [x] (2026-07-13) Reproduced the current failure boundary: recent live events report authorized banner settings, `UNUserNotificationCenter.add` success, and foreground `willPresent` with banner/list/sound options.
- [x] (2026-07-13) Inspected runtime identity and found six LaunchServices registrations for `com.laban.LabanApp`, all ad hoc signed with distinct CDHashes.
- [x] (2026-07-13) Unregistered every noncanonical Laban bundle and force-registered `/Users/user/Laban.app`; verification now reports exactly one registration.
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
- [x] (2026-07-13) Add an explicit, user-triggered Focus troubleshooting check to Notifications Settings without automatic Focus reads or permission prompts.
- [x] (2026-07-13) Cache Focus authorization and nullable app-perspective suppression in native notification diagnostics, schemas, live/headless parity, and focused tests.
- [x] (2026-07-13) Add the Focus Status usage description, update operational documentation, and validate the locally signed bundle as far as possible without launching it.
- [x] (2026-07-13) Route default notification taps to the originating live tab with a safe activate-only fallback and focused tests.
- [x] (2026-07-13) Address review findings: reuse the terminal view's state-safe external tab-selection path, distinguish Focus privacy from Allowed Apps settings, timestamp cached checks, and localize the complete Focus troubleshooting surface.
- [ ] (2026-07-13) Re-run the Focus-specific Review Gate with a fresh reviewer.

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

- Decision: Read Focus Status only after the user presses a troubleshooting control in Notifications Settings.
  Rationale: Focus Status is privacy-protected and checking it is diagnostic, not part of ordinary notification delivery. Launch, notification submission, endpoint polling, and background refresh must neither read Focus nor surprise-prompt for permission. The explicit action may request authorization, read the app-perspective result, and cache it for later UI and endpoint observation.
  Date/Author: 2026-07-13 / Codex implementer

- Decision: Represent an authorized but absent `isFocused` value as unknown rather than false.
  Rationale: Apple documents `INFocusStatus.isFocused` as nullable and its sample requires the Communication Notifications capability. A nil value cannot prove that Focus permits Laban, especially for an ad hoc-signed local build without that capability.
  Date/Author: 2026-07-13 / Codex implementer

- Decision: Treat the system default notification action as “open the originating tab” and do not register a custom action.
  Rationale: A banner tap is the platform-standard navigation gesture. `AgentNotificationPoster` already embeds the tab ID, so the delegate can select that tab and raise its window. Stale or malformed IDs must degrade to application activation without guessing another tab.
  Date/Author: 2026-07-13 / Codex implementer

- Decision: Timestamp every explicit Focus result and describe it as historical rather than continuously current.
  Rationale: Focus remains strictly user-triggered, so cached state can become stale immediately after the check. `focusCheckedAt` exposes that boundary to the UI and debug endpoint without adding polling or background API access.
  Date/Author: 2026-07-13 / Codex implementer

- Decision: Keep notification-originated tab selection at `TerminalBitmapView`'s ownership boundary.
  Rationale: direct model selection bypasses marked-text teardown, per-tab selection persistence, sidebar visibility, and render invalidation. The external wrapper calls the existing `selectTabPreservingSelection` sequence rather than duplicating it.
  Date/Author: 2026-07-13 / Codex implementer

## Surprises & Discoveries

- Observation: The running bundle was not signed by a Personal Team certificate. It was ad hoc signed and had a CDHash-only designated requirement.
  Evidence: `codesign -d -r- /Users/user/Laban.app` returned `designated => cdhash ...` with no Team ID.

- Observation: Laban had already crossed the native delivery boundary successfully.
  Evidence: the event log contained `attention.notification.delivery` with `outcome=added`, followed by `attention.notification.willPresent` with banner/list/sound options.

- Observation: LaunchServices contained six existing bundles with the same identifier and six distinct ad hoc CDHashes.
  Evidence: read-only `lsregister -dump` parsing found five worktree/smoke bundles plus `/Users/user/Laban.app`. After the explicitly authorized cleanup, the same query reports one canonical registration.

- Observation: macOS privacy controls block direct inspection of UserNotifications, Focus databases, and historical unified logs from this process.
  Evidence: the reads failed with `Operation not permitted`, so the application itself needs to expose native state through its loopback control plane.

- Observation: A next-sequence polling cursor must use an inclusive event filter.
  Evidence: the fresh review found that returning `nextSequence = 4` and filtering with `sequence > 4` skipped the next event. The store now filters with `sequence >= since`, with a cursor round-trip regression.

- Observation: An explicitly visible notification test needs lazy attach without gaining reusable authority.
  Evidence: `notifications.test` is now request-exact, outside `ControlSessionObserveFamily`, and non-persistable. An end-to-end server test proves an Always Allow decision degrades to one-time approval and stores no grant.

- Observation: Personal Focus, not notification submission or signing, was the live suppressing boundary.
  Evidence: after the user added Laban to Personal Focus's Allowed Apps, the existing notification test endpoint produced a visible notification without a code or signing change.

- Observation: Apple documents a capability limitation beyond the Focus Status privacy prompt.
  Evidence: `INFocusStatusCenter` compiles and links in the ad hoc local bundle and the generated Info.plist carries `NSFocusStatusUsageDescription`, but Apple's sample requires the Communication Notifications capability for a non-nil current Focus value. The current ad hoc signature has no entitlements, so runtime code treats authorized nil as inconclusive.

## Review Gate

A separate fresh agent must verify the following before this ExecPlan is complete:

- [x] Run the focused notification/control tests named in `Concrete Steps`; exit 0.
- [x] Run the bundle-identity resolution test; canonical, explicit override, worktree, and smoke cases produce distinct valid identifiers.
- [x] Inspect `ControlRouteCatalog.endpoints`, `IntentCatalog`, `LiveIntentRouter`, and headless routing; both notification endpoints are discoverable with the intended capability floor.
- [x] Confirm the state response and diagnostic ring omit notification title/body text and expose a hard capacity bound.
- [x] Confirm the test action cannot be called with an ordinary app-observe read token but is available through an explicitly approved, request-exact, non-persistable GUI action scope.
- [x] Confirm no code path emits an ad hoc-signing warning.
- [x] Run `./scripts/check`; exit 0, including 2,029 sequential tests, smoke runtime, and E2E.
- [ ] Search `Sources/LabanApp` for `INFocusStatusCenter`; every read/request is reachable only from the Notifications Settings troubleshooting action, and normal notification refresh has no Focus dependency.
- [ ] Run Focus diagnostics model, monitor, UI-presentation, live-control, headless-router, catalog parity, and schema tests; expect exit 0.
- [ ] Build the app bundle, verify `NSFocusStatusUsageDescription` is present, and inspect the code signature without launching the app.
- [ ] Inspect default notification-response routing; confirm a valid tab is selected and raised, stale or malformed IDs preserve the current selection, non-default actions do not navigate, and every path calls the completion handler once.
- [ ] Confirm notification response selection uses `TerminalBitmapView.selectTabFromExternalNavigation`, with an integration regression for marked text and cached selection restoration; no direct `AppModel.selectTab` call may be added to `MainWindowController`.
- [ ] Confirm Focus results expose `focusCheckedAt`, UI copy says “At the last check,” denied access opens Privacy & Security > Focus, active suppression opens general Focus settings, and neither path reads Focus automatically.
- [ ] Confirm all new Focus labels, buttons, status/progress copy, tooltips, and `NSFocusStatusUsageDescription` are present in every supported localization resource.

Review status: FOCUS EXTENSION NOT REVIEWED. The original notification diagnostics work was approved on 2026-07-13 after fixing lazy-attach admission and cursor semantics; the new Focus-specific gate items above still require the requested fresh reviewer.

## Context and Orientation

`Sources/LabanCore/AppModel.swift` creates `AttentionNotificationEvent` values from OSC terminal notifications, BEL, and tab-attention transitions. `Sources/LabanApp/MainWindowController.swift` applies frontmost-tab and user-setting policy, then forwards eligible events to `AgentNotificationPoster`. `Sources/LabanApp/AgentNotificationPoster.swift` calls `UNUserNotificationCenter`, lazily requests authorization, submits immediate requests, and writes structured events to `EventLog`. `Sources/LabanApp/AppDelegate.swift` installs the notification-center delegate and selects foreground presentation options.

`INFocusStatusCenter` is the public macOS API that reports Focus from the calling application's perspective: when authorized, `focusStatus.isFocused == true` means a Focus is active and this app is not allowed through it. Its value is nullable. Focus authorization is separate from notification authorization, and reading it is not part of the normal notification refresher. `SettingsWindowController` owns the only user gesture that invokes the Focus check; the shared diagnostics store only caches and returns the result.

`AgentNotificationPoster` stores the originating `tabId` in each notification's `userInfo`. `AppDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` delegates default-action routing to a testable handler. `MainWindowController.focusTabFromNotification(_:)` asks `TerminalBitmapView.selectTabFromExternalNavigation(_:)` to validate and select through the same marked-text, selection-cache, sidebar, and render-invalidating path as other UI selection, then raises the window. A stale ID returns false so the handler retains the activate-only fallback.

The live GUI control surface is routed by `Sources/LabanApp/Control/LiveIntentRouter.swift`. HTTP path and intent mappings live in `Sources/LabanControl/ControlRouteCatalog.swift`. Capability, sensitivity, availability, and schema metadata live in `Sources/LabanCore/Intents/IntentCatalog.swift`. The headless implementation lives under `Sources/LabanDebug` and must retain endpoint contract parity even when a native facility is unavailable. JSON schemas live under `schemas/debug`.

The phrase app-observe means the low-privilege token used by `laban health`, `laban status`, and `laban request` to inspect non-sensitive application state. A notification test is not observation because it can cause visible or audible output, so it must require an explicit action capability.

The phrase diagnostic ring means a fixed-capacity in-memory list of recent metadata records. When capacity is exceeded, the oldest records are discarded. Records must include a monotonic sequence number so callers can request only entries newer than a prior sequence.

The canonical application identity is `com.laban.LabanApp` at `/Users/user/Laban.app`. `scripts/build-app` currently hardcodes that identifier into every bundle, including bundles produced in linked worktrees and `.build-smoke`.

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

### Milestone 5: Explicit Focus troubleshooting

Extend `NativeNotificationDiagnosticsSnapshot` with a Focus authorization status, nullable `focusSuppressesNotifications` value, and nullable `focusCheckedAt` timestamp. A live store begins in `notChecked`; headless state reports `unavailable`. The state endpoint only returns the cached value and must not itself touch `INFocusStatusCenter`.

Add a small app-only Focus monitor around `INFocusStatusCenter`. Its `check` method is called only by a new Notifications Settings troubleshooting button. On that click, it reads the current authorization state, requests authorization only when it is not determined, then reads `focusStatus.isFocused` only when authorized. Cache the timestamped result and update a nearby status label phrased as “At the last check.” Authorized `true` is a factual historical warning that Focus was silencing Laban; authorized `false` says it was not silencing Laban then; authorized `nil`, denied, restricted, not determined, unknown, and unavailable all remain explicit inconclusive states. Denied authorization routes to Privacy & Security > Focus, while detected suppression routes to general Focus settings for Allowed Apps.

Add `NSFocusStatusUsageDescription` to the generated Info.plist. Do not add an ad hoc-signing warning. Apple documents the Communication Notifications capability as a requirement for obtaining a non-nil current Focus value; validate compilation, the generated plist, and the locally signed bundle, but do not claim local runtime support until the user launches and explicitly runs the check.

### Milestone 6: Notification tap routing

Implement the notification-center response delegate for `UNNotificationDefaultActionIdentifier`. Pass the existing `tabId` metadata through a small testable handler, validate that the tab still exists in `MainWindowController`, select and raise it when valid, then activate Laban. Missing, malformed, or stale IDs activate Laban without changing the current selection. Other action identifiers perform no navigation, and every response path invokes Apple's completion handler exactly once. Do not register an “Open Tab” notification action because the default tap already carries that meaning.

## Concrete Steps

Work from `/Users/user/wrk/laban`.

Before building, check for concurrent Swift builds:

```sh
pgrep -fl "swift build"
```

Run focused Swift tests while iterating:

```sh
swift test --filter 'AgentNotificationPosterTests|AttentionNotification|LiveControlObserveTests|CatalogParityTests|ControlAvailabilityParityTests'
```

For the Focus extension, include:

```sh
swift test --filter 'NativeNotificationDiagnosticsTests|NativeFocusStatusMonitorTests|NativeFocusTroubleshootingPresentationTests|LiveControlObserveTests|HeadlessIntentRouterTests|CatalogParityTests|ControlAvailabilityParityTests'
```

For notification response routing, include:

```sh
swift test --filter 'NativeNotificationResponseHandlerTests'
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
- Focus authorization and app-perspective suppression are never read automatically; only the explicit Notifications Settings troubleshooting action can invoke `INFocusStatusCenter`.
- Before that action, live diagnostics report `focusAuthorizationStatus: "notChecked"`, `focusSuppressesNotifications: null`, and `focusCheckedAt: null`; headless reports `unavailable` with both nullable fields null.
- After an explicit check, the Settings UI and state endpoint share the cached result and never turn denied, restricted, unavailable, unknown, or an authorized nil value into a false "Focus is off" claim.
- The generated Info.plist includes a user-understandable `NSFocusStatusUsageDescription`.
- A default notification tap selects and raises the originating live tab; stale, missing, or malformed tab metadata activates Laban without selecting another tab, and all paths complete the system callback exactly once.
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
running bundle: /Users/user/Laban.app
bundle id: com.laban.LabanApp
build commit: 4747bcf1
signing: ad hoc, no Team ID, CDHash-only designated requirement
LaunchServices registrations after cleanup: 1
native runtime evidence: authorized, alert style banner, add succeeded, willPresent requested banner/list/sound
```

Focus extension verification on 2026-07-13:

```text
focused tests after review-finding remediation: 94 passed, 0 failed
covered: explicit-only Focus reads, checkedAt caching and historical UI copy, distinct permission/allowlist settings destinations, localized Focus resources, live/headless contracts, safe notification-tap tab routing
lint: passed
check-docs: passed
check-debug-contract: passed
LabanControlGen --check: passed
git diff --check: passed
notification-state schema JSON: valid
Focus localization catalog: all 189 entries have all 11 supported non-English locales; the 21 Focus keys have translated, non-empty values
build-app: passed; ad hoc signature valid on disk and satisfies its Designated Requirement
Info.plist NSFocusStatusUsageDescription: present and non-empty
localized InfoPlist.strings: generated for English plus all 11 supported non-English locales; French and Japanese values parsed and verified
linked frameworks: Intents.framework and libswiftIntents.dylib present
runtime Focus check: intentionally not run; only the user may press the troubleshooting button
full ./scripts/check: intentionally not run because its smoke stage launches Laban and this review pass may not launch or restart the app
```

Notification response routing verification on 2026-07-13:

```text
focused tests: 5 passed, 0 failed
covered: valid tab, stale tab, missing/malformed tabId, non-default action, deferred completion
runtime notification tap: not run; requires the user-launched updated bundle and a delivered notification
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
