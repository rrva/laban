# Architecture Deepening Candidates

Findings from an architecture review on 2026-05-23 against `main`. Surfaces
places where shallow modules could be merged or refactored into deeper ones
with smaller interfaces and more leverage.

Uses the vocabulary from
`~/.claude/skills/improve-codebase-architecture/LANGUAGE.md`:

- **Module** — anything with an interface and an implementation.
- **Interface** — everything a caller must know (types, invariants, ordering,
  error modes), not just the type signature.
- **Depth** — leverage at the interface. Deep = a lot of behaviour behind a
  small interface. Shallow = interface nearly as complex as the implementation.
- **Seam** — where an interface lives.
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Deletion test** — imagine deleting the module. If complexity vanishes, it
  was a pass-through. If complexity reappears across N callers, it was
  earning its keep.

Project domain terms come from `AGENTS.md` and the source tree
(terminal session, snapshot, frame command, debug runtime, etc.). No
`CONTEXT.md` exists yet — terms used here that prove load-bearing should be
promoted there when a candidate is acted on.

---

## 1. The debug-runtime action surface is fragmented routing

**Files:** `Sources/LabanDebug/HeadlessDebugRuntime.swift` (525),
`DebugRuntimeActions.swift`, `DebugHTTPServer.swift` (745), and the ~13
`Debug*Actions.swift` + ~20 `Debug*Endpoints.swift` files
(`DebugTabActions`, `DebugInputActions`, `DebugClipboardActions`,
`DebugDropActions`, `DebugSelectionActions`, `DebugFindActions`,
`DebugViewportActions`, `DebugMouseActions`, `DebugWindowActions`,
`DebugFixtureEndpoints`, …).

**Problem:** "Apply a debug action against the running runtime" is one
concept, smeared across ~35 files. Each `Debug*Actions` file is 30–300 lines
and exists almost entirely to extend `HeadlessDebugRuntime` with one verb.
Endpoints are string-matched in `DebugHTTPServer` against ad-hoc handlers;
there is no typed registry of "what does this runtime accept?"
`DebugDiscoveryCatalog` exists only as a comment-shaped grouping. The
interface to *use* the debug runtime is "construct the right action enum
case, hold the runtime lock, decode the response shape" — and that shape
varies per file.

**Deletion test:** Deleting any one `Debug*Actions.swift` file deletes a verb
but adds no consolidation pressure anywhere else. That's the signature of
pass-through fragmentation — the modules don't earn their keep individually;
the *set* of them is what matters, but the set has no seam.

**Solution:** A single deep `DebugRuntime` interface where actions are values
in one typed namespace and routing is internal. Endpoints + actions collapse
into the runtime; HTTP becomes a thin adapter at one seam. The discovery
catalog becomes the *source* of the routing table rather than a comment
about it.

**Benefits:**

- **Leverage** — callers (HTTP server, capture-replay, in-process tests) all
  go through one interface instead of memorising 35 files.
- **Locality** — changing an action's shape touches one place; today it
  touches the action file, the endpoint file, the discovery catalog, and
  `DebugModels`.
- **Tests** — every action file owns its own tests today and the routing
  layer is untested. Tests move to the runtime interface and the HTTP
  adapter becomes a thin transport test.

**ADR conflict:** none. Lives entirely inside `LabanDebug`.

---

## 2. The frame-production cluster has an implicit ordering contract

**Files:** `Sources/LabanCore/TerminalSurfaceController.swift` (517),
`FrameProducer.swift` (501), `TabMetadataSynchronizer.swift` (311),
`SidebarProducer.swift` (312), plus `TerminalRenderGate.swift` and
`TerminalDisplayKickCoalescer.swift` in `LabanApp`.

**Problem:** Producing one frame for a tab is one concept, but it is wired
through four modules that must run in a specific order with implicit
preconditions — `TabMetadataSynchronizer` has to have observed the latest
snapshot before `FrameProducer` reads metadata; `SidebarProducer` reads
state that `TabMetadataSynchronizer` derived; `TerminalSurfaceController` is
the only thing that knows the dance. There are roughly 51 cross-seam calls
between the terminal-UI layer and the surface controller for three
coordination methods (`renderDirty`, `resetSynchronizedOutput`,
`markRendered`).

**Deletion test:** Deleting `FrameProducer` or `SidebarProducer` would push
their bodies back into `TerminalSurfaceController` — complexity reappears.
So each individual piece earns its keep. The shallowness is at the *seam
between them*: each has a small interface, but together they require a
caller to know the ordering, which makes the effective interface large.

**Solution:** Make the four pieces internal to a deeper *frame production*
module behind `TerminalSurfaceController`. Public interface is "the surface
for this session; advance to the next frame on this snapshot generation."
`FrameProducer` etc. stay as internal seams the tests of this module use,
but they are no longer part of the public interface.

**Benefits:**

- **Leverage** — `MainWindowController` and `HeadlessDebugRuntime` (which
  AGENTS.md requires in parity) ask for "next frame on session N" instead of
  orchestrating four objects.
- **Locality** — the ordering contract lives in one file. Today a regression
  there can be introduced by any of four callers.
- **Tests** — integration tests stop poking at `FrameProducer.advance(...)`
  and start exercising "given this snapshot, what frame and what sidebar do
  we render?" — the **interface is the test surface**.

**ADR conflict:** none. Stays Swift-side; doesn't change the
`LabanSession`/`LabanSnapshot` boundary owned by ADR 0001.

---

## 3. Session persistence has nine files and no seam

**Files:** `Sources/LabanCore/Persistence/AgentSessionDetector.swift` (727),
`AgentSupport.swift` (704), `TranscriptWriter.swift` (328),
`TranscriptHost.swift` (217), `RecentByteRing.swift` (281),
`PersistenceCoordinator.swift` (133), and the rest of
`Sources/LabanCore/Persistence/`.

**Problem:** "Persist a terminal session so it can be restored on restart"
is a coherent concept, but there is no module that owns it.
`PersistenceCoordinator` is named like a facade but is only 133 lines of
wiring. Callers — `AppModel`, `Session`, `TabMetadataSynchronizer` — reach
into the directory and grab the specific helper they need.
`AgentSessionDetector` in particular is doing two jobs (liveness *and*
state mirroring) and is referenced directly from `AppModel`.

**Deletion test:** Deleting `PersistenceCoordinator` would change almost
nothing — proof it is a pass-through today. Deleting any single helper file
would move complexity into its callers, which is the inverse signal: the
helpers earn their keep but the *facade* doesn't.

**Solution:** Promote `PersistenceCoordinator` from a constructor bag to the
actual interface. Callers receive "the persistence handle for this
app/session" and only call into the handle. `AgentSessionDetector`,
`TranscriptWriter`, `TranscriptHost`, `RecentByteRing` move behind it as
internal implementation. `AgentSessionDetector` itself is split internally
into "liveness probe" and "state mirror" but neither is exported.

**Benefits:**

- **Leverage** — one ingest path for "session produced these bytes / changed
  tab / closed" and one query path for "restore me from disk." Today a new
  persistence concern (e.g. shell-integration restore) gets wired into three
  places.
- **Locality** — ordering rules between transcript flush, ring buffer, and
  detector live in one file. Today they're spread.
- **Tests** — behaviour tests move from "did `RecentByteRing` evict
  correctly" to "after these inputs, does restore produce the right state?"
  The internal helpers keep their unit tests as internal seam tests.

**ADR conflict:** none. Persistence is not covered by an ADR.

---

## 4. `TerminalBitmapView` is a wide AppKit adapter doing several modules' work in one file

**Files:** `Sources/LabanApp/TerminalBitmapView.swift` (3,093 lines).

**Problem:** This `NSView` subclass implements `NSTextInputClient`, mouse
handling, scrolling, drag-and-drop, clipboard glue, render scheduling,
capture-recording hooks, latency probing, and the rendering surface — in
one class. AppKit forces a single `NSView` instance, so we can't *literally*
split it. But most of its surface area is *not* required by AppKit; it's
just glued into this class for convenience. Many of those concerns have peer
Swift modules already (`TerminalInputView`, `TerminalSelectionInput`,
`TerminalMouseInput`, `TerminalScrollInput`, `TerminalRenderGate`) that the
view also calls into.

**Deletion test:** Deleting `TerminalBitmapView` would not delete the
concerns — it would scatter them into AppKit callbacks somewhere else. So
the *view* earns its keep. The shallow part is that the **interface** of
`TerminalBitmapView` (what test code, debug code, and `MainWindowController`
see) is enormous and unstable, while the implementation does eight
unrelated things.

**Solution:** Treat `TerminalBitmapView` as a thin **adapter** that
translates AppKit callbacks into calls on a small set of deep Swift modules
behind it. Each concern — text input, selection, scroll, drag/drop,
clipboard, render scheduling — gets one peer in `LabanCore` (no AppKit
deps, per AGENTS.md hard rule) with a single interface. The view holds them
and forwards. The headless runtime calls those peers directly without going
through AppKit.

This is the AGENTS.md hard rule's friction point: *"HeadlessDebugRuntime
stays in feature parity with `MainWindowController.makeAndShow`."* Today the
only way to maintain parity is to re-implement what the view does in
headless mode. Deepening the peer modules is what makes parity cheap.

**Benefits:**

- **Leverage** — AppKit and headless paths share one stack of deep modules;
  the AppKit view is a 200–400 line adapter.
- **Locality** — a bug in selection or scroll has one home. Today it could
  live in the view, the peer module, or the seam between them.
- **Tests** — peers test directly in `LabanCore`. AppKit-only tests shrink
  to focusing on AppKit event translation. The 13 test files referencing
  `TerminalBitmapView` largely move down a layer.

**ADR conflict:** none directly, but brushes ADR 0001 rule #4 (input
normalisation in AppKit, encoding in `LabanTerminalCore`). The deepening
would keep that split — the peer modules normalise; `LabanTerminalCore`
still encodes.

---

## 5. Session-to-app callback wiring is three parallel mechanisms

**Files:** `Sources/LabanCore/Session.swift` (1,506), C-side in
`session_lifecycle.c`, `tab_status.c`.

**Problem:** `Session` exposes three callback setters — bell, tab-status,
persistence — each implemented independently with its own opaque-pointer
state struct, its own C-side registration, and its own thunk. Callers
(`AppModel`, `TabMetadataSynchronizer`, `MainWindowController`) wire each
one separately. Adding a fourth (e.g. shell-integration events, hyperlink
hover) replicates the pattern.

**Deletion test:** Deleting one callback would lose the feature; deleting
the *third-time-repeated mechanism* would force consolidation. So the
mechanism is shallow — the work of "tell Swift a thing happened in the C
session" is done three times.

**Solution:** A single session-observation seam on `Session` — one place to
register interest, one place where C-side events fan in. The C side gets
one event-emit callback into Swift; Swift dispatches to whichever observers
care. Three becomes one.

**Benefits:**

- **Leverage** — future event types (which are coming — shell integration
  already has its own overlay) cost one struct case, not a new C-to-Swift
  round-trip.
- **Locality** — the C↔Swift event protocol lives at one seam, not three.
- **Tests** — `Session` becomes testable without invoking a real C session
  for each callback type; the dispatch is pure Swift.

**ADR conflict:** brushes ADR 0001 rule #3 (Swift sees only
`LabanSession*`/`LabanSnapshot*`). This refactor keeps that — the single
C-side callback still emits owned C events that Swift decodes; no raw
libghostty types cross.

---

## Suspicious but inconclusive

- **`AppModel.swift` (1,478 lines)** — could be a god object or a
  legitimately coordinating module. The shape depends on how many callers
  reach inside it vs. through methods. Needs a reference-count pass.
- **`Session.fixture` is called from 83 test sites** — fixture might be a
  real test helper, or test scaffolding leaking into production `Session`.
  Worth a closer look.
- **`DebugModels.jsonError` called from 41 places** — utility vs. scattered
  error-handling concept.
- **The C target's split** (`snapshot.c`, `session_lifecycle.c`,
  `scrollback_extract.c`, …) is *probably* deliberate depth behind the
  `LabanSession*`/`LabanSnapshot*` interface (ADR 0001), not fragmentation.
  Worth a quick confirm.

---

## Next step

Pick a candidate to grill on. The grilling pass walks constraints,
dependencies, what the deepened seam looks like, and which tests survive.
Side-effects:

- New load-bearing terms get promoted to `CONTEXT.md` (created lazily).
- Rejected candidates with durable reasons become ADRs so future reviews
  don't re-suggest them.
