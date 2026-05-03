# Multi-Pane, Multi-Session, Vertical-Tabs Terminal — Techniques

General know-how for the moving parts of a macOS-first, multi-window, multi-tab, multi-pane, multi-session terminal application. Portable components are welcome where they support the terminal core, test harness, fixtures, and headless automation, but the product shell is macOS-native.

---

## 1. App shell: a single window-group keyed by an identity value

Use the framework's data-driven window-group primitive parameterized by a small `Hashable & Codable` identity value. Each window is a scene; the framework gives you per-window state, command routing, and standard window-management for free. Persist a list of these identities to user defaults at terminate time and replay them at launch via the framework's "open window with value" entry point — that's your multi-window restoration without writing a window manager.

## 2. Vertical tabs are just a sidebar list

A "tabs sidebar" is a column in a navigation-split layout containing a selection-bound list of tab rows. Each row is a navigation link whose value is a tab ID; the binding drives a single selected-tab-ID piece of state. Sidebar visibility is a tri-state (sidebar/content/detail-only) you mutate to show or hide. A right-side inspector is the same pattern. Persist selected-ID, sidebar-visible, inspector-visible per scene using the framework's scene-scoped storage attribute so each window remembers its own layout.

## 3. Pane layout as a recursive sum-type tree

Model the pane area as `Node = Leaf | Split(axis, fraction, first, second)` — an indirect/recursive enum of pure data, no views. Splits hold the axis, a 0–1 fraction, and two child nodes. Mutating helpers do the structural work: split-leaf-by-id, remove-leaf-by-id (collapsing the surviving sibling upward), set-fraction-by-id. The render layer pattern-matches: leaves render content, splits render a divider widget around two recursive renders. This makes layout, persistence, and undo trivial because everything is pure data with stable IDs.

## 4. The split-divider widget

Wrap each split in a geometry reader that measures the container, then place the two children in a stack with a thin draggable rectangle between them. The draggable rectangle uses a drag gesture that translates pointer movement into a fraction delta, plus a hover handler that swaps the system resize cursor. Two important refinements:

- **Preview-then-commit.** During the drag, write the proposed fraction to a *local* state variable and overlay a translucent "preview" divider at that position; only on drag-end push the new fraction into the canonical tree. This keeps every drag tick from reflowing the underlying terminal pty and re-paginating.
- **Clamp by minimum pane length.** Convert a minimum-pixels constraint into a minimum-fraction at draw time, so panes can't be dragged smaller than their content needs.
- **Keyboard accessibility.** Expose the divider as an accessibility-adjustable element with increment/decrement actions in fixed steps.

## 5. Decouple sessions from views via stable IDs

The pane tree only stores **session IDs**. The actual sessions (pty, shell process, scrollback) live in a registry keyed by ID, owned by the per-window store. View recycling, reordering, and tree restructuring never touch the sessions — they just look up "the session for this ID." This is the single most important decoupling for terminal apps: the renderer's lifecycle is *not* the shell's lifecycle.

A parallel "controller" registry sits between the session and the view: one controller per leaf, retaining the embedded native terminal view across SwiftUI rebuilds, tracking a "generation" counter so a restart spins up a fresh pty against the same ID, and exposing imperative actions (start, restart, attach, detach, capture-history, restore-history).

## 6. Bridging a native terminal view into a declarative UI

Wrap the terminal library's `NSView`/`UIView` in a representable adapter. Crucial details:

- The representable's "make" method returns a host view *owned by the controller*, not a freshly created one — otherwise every parent re-render would discard the pty.
- The "dismantle" method only detaches; it doesn't kill the session.
- Layout of the terminal view inside its host uses autolayout pinning to all four edges, so the pty resizes when the split fraction changes.
- Expose accessibility: a label, a value (state + cwd), and a small set of custom actions (restart, split, close).

## 7. Shell integration via OSC sequences

To know whether the shell is at a prompt, running a command, or just exited, parse OSC 133 markers (`\e]133;A\a`, `\e]133;C\a`, `\e]133;D;<exit>\a`) out of the byte stream as it arrives. Do this with a small streaming parser that buffers partial sequences across reads. Inject the markers without making users edit their dotfiles by overlaying environment variables that point the shell at a wrapper rc-directory you generated — for zsh it's `ZDOTDIR`, bash uses `--rcfile`/`BASH_ENV`, fish uses an `XDG_CONFIG_HOME` overlay. The wrapper scripts source the user's real rc files and then append a tiny `precmd`/`PROMPT_COMMAND`/`fish_prompt` snippet that emits the markers. Surface the parsed events as a state machine (idle → at-prompt → running → finished) and feed it into the UI for status indicators and bell badges.

## 8. Focus as a single window-scoped enum

Define a flat enum of focus targets (`sidebar | inspector | empty | pane(ID)`) and bind one of these to the framework's focus-state property at the window-scene level. Each focusable view declares `.focused(state, equals: someCase)`. This gives you keyboard focus routing across heterogeneous content with one source of truth.

Layered on top:

- **History stack.** Push focused-pane-IDs onto a per-window MRU list. When the focused pane closes, pick the most recent surviving pane from the stack — the user lands where they expect.
- **Per-tab last-focused memory.** Map tab-ID → last-focused-pane-ID so switching tabs restores the right pane.
- **Pending-focus debouncing.** When you create or restructure panes, the new view doesn't exist yet on the same tick. Set a "pending focused ID" state variable, then in a main-actor task `await Task.yield()` and assign focus on the next tick — this avoids a race where focus assignment lands before the view is in the hierarchy.

## 9. Spatial pane navigation

For "focus left/right/up/down" you need geometry, not topology. Each pane reports its frame (in a shared coordinate space) into a preference-key dictionary that bubbles up to the window scene. The focus mover then, for a given direction, filters candidates that are on the correct side of the current pane and ranks them by a tuple comparator: (has-perpendicular-overlap, perpendicular-overlap-length, directional-distance-inverted, perpendicular-distance-inverted, history-rank). This produces the "natural neighbor" that tiling window managers and tmux navigation feel like.

For cyclic next/previous, just walk the leaf list returned by an in-order traversal of the pane tree.

## 10. Window-scoped menu commands without a global router

The framework provides "focused scene value" — a typed key/value channel from the active scene to the menu bar. Each window publishes its action closures (split-focused-pane, close-focused-pane, toggle-sidebar, focus-omnibox, etc.) under named keys; the menu commands read those values via the corresponding "focused value" property and dispatch into whichever window is active. There is no shared singleton router. When a closure should be disabled (e.g., "close pane" with no focused pane), publish `nil` and let the menu auto-disable.

## 11. Three-plane persistence

Treat workspace state as three logical planes in one store:

1. **Live state** — what's currently open in some window.
2. **Recently-closed** — bounded ring buffer for "reopen last" commands.
3. **Library** — long-lived saved workspaces and saved windows.

A "placement" row says "this workspace is live in window X / recently-closed / pinned to library." Workspace identity is stable across these transitions; only the placement role changes. Window-membership and window-state rows mirror the per-window scene state (selected tab, selected pane).

Per-pane snapshots store: launch configuration, title, transcript text, normal-buffer scroll position (only when valid), and an "alternate-buffer was active" flag (so you don't try to restore scroll into a fullscreen TUI). Browser panes get back/forward history arrays plus current index.

Save points: scene-phase transitions, window-became/resigned-active, app-will-terminate, and a periodic background interval. Coalesce so scene churn doesn't thrash the store.

## 12. Restoration tactics that actually feel right

- Restore *normal* buffer scrollback by replaying the captured transcript, not by snapshotting the renderer's pixels.
- If the alternate-buffer flag was set at capture time, *skip* scroll restoration — the user was in `vim`/`less` and their scroll position is meaningless.
- Run the rehydration of sessions before the views appear, then let the controller's "needs process start" check ensure the pty actually starts when the view first lays out.
- For working directory: sanitize on capture and on restore (resolve `~`, drop transient paths) so a saved workspace from yesterday doesn't try to `cd` into a temp directory that's gone.

## 13. The window-scene store

Each window owns one observable store that holds: the array of tabs, the session registry, the controller registry, plus utility maps (frame dictionary, focus history, last-focused-pane per tab). All structural mutations (create-tab, split-pane, close-pane, set-fraction) flow through the store so that the data model, the registries, and persistence stay coherent — the registries prune controllers/sessions whose leaves no longer exist after a tree mutation. This is the line where "view code" stops and "state code" begins; everything in views is a function of store + scene-storage + focus-state.

## 14. Per-shell launch context

Build the launch configuration (executable, argv, environment, cwd) by composing layers: a base "login shell" default → user preferences → per-tab overrides → the integration overlay (the env vars that point the shell at the wrapper rc-directory). The integration layer is shell-aware: zsh, bash, and fish each get a different overlay strategy because their rc-loading rules differ. Normalize the cwd at the boundary so an empty/invalid path falls back to home.

---

Put together, those are the moving parts: a data-driven window group, sidebar-as-tabs, a recursive pane enum with a draggable splitter, sessions-by-stable-ID separated from views, a representable-bridged native terminal view, OSC-133 shell integration via env-var rc-overlays, a single focus enum with history and spatial routing, scene-scoped command publishing, and three-plane persistence with transcript-based history restoration.

---

## 15. Terminal-session behavioral requirements

The session registry owns process lifetime. A terminal session owns its pty, shell process identity, terminal-core state, key encoder, mouse encoder, render snapshot state, title state, image-placement state, scrollback state, and child-exit status. Tabs, panes, and views hold stable IDs that point at sessions; they do not own the shell process directly.

Session creation is all-or-nothing. If pty creation, terminal-core creation, encoder creation, or render-state creation fails, the partially-created resources are released and the existing window state is left unchanged. Session teardown closes the pty, sends the normal terminal-disconnect signal to a still-running child, reaps the process according to platform rules, and releases terminal-core resources.

If a session object is moved or reindexed inside a collection, callback userdata/delegates must be rebound so terminal effects never point at stale storage.

## 16. PTY and interactive environment requirements

The shell runs under a pseudo-terminal with an initial rows/columns/pixel-size report derived from the host view. Resizing a pane updates both the terminal core and the pty window size. Pty reads feed bytes into the terminal parser without blocking the UI. Terminal-generated responses, such as device status replies and capability reports, are written back to the pty.

Default shell resolution follows the launch context from section 14. When no explicit shell is configured, resolve from `$SHELL`, then the platform account database, then `/bin/sh`.

The default environment should choose a widely available `TERM` entry unless the app installs a more specific terminfo entry. Truecolor support should be advertised separately. Interactive launches should not inherit automation-oriented color suppression such as `NO_COLOR` unless the user explicitly opts into that behavior.

## 17. Keyboard and command requirements

Keyboard input is encoded through the terminal core's key encoder whenever possible; app code should not maintain separate escape tables for mode-sensitive keys. Before encoding, synchronize encoder options from current terminal state so application cursor mode, keypad mode, and extended keyboard protocols are honored.

Native text input wins over raw modifier interpretation. If the platform text system produces UTF-8 text, the modifiers consumed to produce that text are marked consumed before the event reaches the terminal encoder. On macOS-style keyboard layouts, Option may be a text-entry modifier rather than terminal Alt; for example, a layout where Option-4 produces `$` must send `$`, not an Alt-modified digit chord. Shift is also consumed when it contributed to produced text.

Application commands are handled before terminal input. New tab, close tab, and numbered tab selection consume their key events and drain pending text generated by those events. Unimplemented application-command chords are swallowed rather than leaked into terminal apps as modified key sequences.

## 18. Mouse, scrollback, and focus requirements

Mouse input inside terminal content is encoded through the terminal core's mouse encoder. The encoder receives current cell size, content padding, viewport size, pointer position, buttons, and modifiers. Press, release, motion, drag, and wheel events are supported when the platform reports them.

If the terminal app has enabled mouse tracking, wheel events are forwarded to the app in the requested terminal mouse format. If mouse tracking is not active, wheel events scroll the normal viewport through scrollback. A scrollbar appears only when scrollback exceeds the visible viewport; dragging it maps pointer position to an absolute scroll offset and suppresses duplicate terminal mouse delivery for the same gesture.

Focus gained/lost sequences are emitted only to sessions that requested terminal focus reporting. Exited sessions do not receive focus reports.

## 19. Rendering and glyph requirements

Render from terminal-core render state, not by reparsing escape sequences in the UI layer. For each visible cell, resolve foreground/background colors through terminal-core palette and style rules, draw explicit backgrounds before text, apply inverse video by swapping foreground and background, render grapheme codepoints as UTF-8, draw the cursor only when it is visible and in the viewport, and clear dirty markers only after drawing.

The default monospace font stack or bundled font must cover the glyphs common terminal UIs actually use: ASCII, Latin accents, punctuation, currency symbols, arrows, mathematical and technical symbols, box drawing, block elements, geometric shapes, miscellaneous symbols, dingbats, Braille patterns, and common private-use terminal symbols such as Powerline glyphs. Missing glyph fallback must not change cell metrics.

Inline image protocols are terminal-core state, not ad hoc UI state. The terminal core owns image IDs, storage limits, and placement metadata; the renderer maps visible placements to cell coordinates. A production renderer caches uploaded image resources by image identity and destroys renderer resources only after in-flight frames no longer reference them.

## 20. Terminal effects and title requirements

The terminal core exposes callbacks/effects for pty writes, size reports, device attributes, terminal-version queries, title changes, and color-scheme queries. Returning "unknown" for host color scheme is acceptable when the platform cannot answer it, but the behavior must be explicit.

Terminal title changes update tab/window labels without changing tab identity, pane identity, session identity, or focus. Title bytes are copied into bounded or owned storage, and hostile terminal output cannot overflow UI buffers.

## 21. Failure-mode requirements

EOF from the pty, and platform-specific closed-pty errors, mark the session as exited. If the OS provides an exit status, store it and expose it in the UI. Closing the final tab follows explicit product policy: create a replacement tab, show an empty state, or close the window. It must never leave selection pointing at freed state.

After any failed spawn, close, restore, or render-resource allocation, registries contain only live references. Cleanup paths are safe to call on partially initialized sessions.
