# Make Keyboard Input Terminal-Core Encoded And AppKit-Native

This ExecPlan is a living document maintained in accordance with `PLANS.md`.
Keep `Progress` and `Validation and Acceptance` current as work proceeds. A
fresh contributor should be able to read only this file and the current
working tree, then implement high-fidelity keyboard input without relying on
prior conversation.

## Purpose / Big Picture

Laban can already open real shell sessions, render terminal output, handle
basic text input, paste, scrollback, mouse reporting, and tab shortcuts. The
remaining keyboard gap is that mode-sensitive terminal keys are still encoded
in Swift with hand-written byte tables, while terminal programs can change how
arrows, function keys, keypad keys, modified text keys, and release events
must be reported.

After this change, users should be able to run shells, tmux, vim, neovim,
readline prompts, and keyboard-aware TUIs with correct arrows, function keys,
Ctrl/Shift/Alt combinations, Kitty keyboard protocol, xterm
`modifyOtherKeys`, and application cursor/keypad modes. Native macOS text
input still wins: layout-specific characters and IME commits are sent as
text, not accidentally reinterpreted as terminal Alt or Super chords.

## Progress

- [x] (2026-05-04) Checked `docs/product/mvp.md`,
  `docs/product/spec.md`, `docs/reference/prototype-implementation-notes.md`,
  and `docs/process/dev-process.md` for keyboard requirements.
- [x] (2026-05-04) Inspected current Laban key routing in
  `Sources/LabanApp/TerminalBitmapView.swift`,
  `Sources/LabanApp/TerminalInputView.swift`,
  `Sources/LabanTerminalCore/session.c`,
  `Sources/LabanTerminalCore/include/LabanTerminalCore.h`,
  `Sources/LabanCore/Session.swift`, and the related tests.
- [x] (2026-05-04) Inspected libghostty-vt key encoder headers in
  `.external/libghostty-vt/include/ghostty/vt/key/encoder.h` and
  `.external/libghostty-vt/include/ghostty/vt/key/event.h`.
- [x] (2026-05-04) Inspected `/Users/rrj/wrk/ghostling/main.c` and
  `/Users/rrj/wrk/ghostling/README.md` for its keyboard encoder path and
  known input limitations.
- [x] (2026-05-04) Updated the debug/input-log milestone so it records
  recorder-compatible event envelopes and explicitly does not claim to be the
  durable in-the-wild input/render replay system.
- [x] (2026-05-04) Add terminal-core key event ABI, persistent libghostty key encoder/event
  ownership, Swift wrappers, and focused core tests.
- [x] (2026-05-04) Replace AppKit hand-written terminal escape tables with normalized key
  events routed through the terminal core while preserving native text input.
- [x] (2026-05-04) Implement debug `key` action, `/debug/input-log`, schema updates, and
  headless tests that expose keyboard routing decisions to agents.
- [x] (2026-05-04) Add end-to-end keyboard segment to `scripts/test-e2e`: enter key, Cmd-T,
  `/debug/input-log` route assertions.
- [ ] Pass the Review Gate in this plan before marking the keyboard work done.

## Decision Log

- Decision: The terminal core owns terminal key encoding through libghostty-vt;
  Swift/AppKit only classifies app commands, native text, and platform key
  identity.
  Rationale: The MVP and product spec both require terminal key input to use
  the terminal core's encoder when available. Application cursor mode,
  keypad mode, `modifyOtherKeys`, and Kitty keyboard protocol are terminal
  state, so Swift cannot correctly encode them with static byte tables.
  Date/Author: 2026-05-04 / Codex.

- Decision: Keep macOS Option as text-entry by default; add a later profile
  setting before treating Option-letter as terminal Meta by default.
  Rationale: The product docs explicitly say layout-specific Option-produced
  characters must be delivered as text. libghostty-vt has a
  `macos_option_as_alt` option, but the current MVP has no settings UI. This
  plan sets that option to `GHOSTTY_OPTION_AS_ALT_FALSE` after every terminal
  state sync and reports Option as consumed when native text used it. A future
  profile/settings shard can expose `macos-option-as-alt`.
  Date/Author: 2026-05-04 / Codex.

- Decision: Command/Super belongs to the app layer on macOS.
  Rationale: Laban's tab, copy, and paste commands are macOS commands. The
  spec says unimplemented Command chords must be swallowed rather than sent to
  terminal apps as Super-modified key sequences. This matches the Ghostling
  prototype's app-command gate and the libghostty encoder's macOS behavior.
  Date/Author: 2026-05-04 / Codex.

- Decision: Text commits should normally go through the key encoder when a
  current physical key event is available, and fall back to direct UTF-8 writes
  only for IME or synthetic text without a meaningful key event.
  Rationale: Passing UTF-8 text, unshifted codepoint, modifiers, and consumed
  modifiers to libghostty lets protocols such as Kitty keyboard report
  associated text correctly. AppKit sometimes commits text without a single
  physical key event, especially through IME; direct text write remains the
  conservative fallback for those cases.
  Date/Author: 2026-05-04 / Codex.

- Decision: Treat `/debug/input-log` as a bounded diagnostic projection over a
  recorder-compatible input event envelope, not as the durable recording or
  replay system.
  Rationale: A separate in-the-wild reproducibility plan needs one lockstep
  timeline that can connect platform input, normalized key events, encoded PTY
  bytes, terminal output, frame-command extraction, render traces, and
  screenshots. This keyboard plan must not bake in a private keyboard-only log
  shape that future recording work has to replace. It should emit structured
  events with stable IDs and frame/session references so a later recorder can
  persist and replay the same facts.
  Date/Author: 2026-05-04 / Codex.

## Surprises & Discoveries

- Observation: Laban's current `TerminalKeyEncoder` in
  `Sources/LabanApp/TerminalInputView.swift` hard-codes arrows, F1-F12, Tab,
  Backtab, Ctrl mappings, and an Option-letter escape prefix before AppKit
  native text handling. This bypasses terminal modes and can also preempt
  Option-produced text.
  Evidence: `TerminalBitmapView.keyDown(with:)` checks macOS private-use
  function key scalars, control helpers, and option helpers before calling
  `interpretKeyEvents([event])`.

- Observation: Ghostling keeps `GhosttyKeyEncoder` and `GhosttyKeyEvent` on
  each `TerminalSession`, calls `ghostty_key_encoder_setopt_from_terminal`
  before encoding, maps platform keys into `GhosttyKey`, sets modifiers,
  unshifted codepoint, consumed modifiers, and UTF-8 text, then calls
  `ghostty_key_encoder_encode`.
  Evidence: `/Users/rrj/wrk/ghostling/main.c` has `key_encoder` and
  `key_event` fields in `TerminalSession`; `handle_input` syncs encoder
  options, drains text input, fills a `GhosttyKeyEvent`, and writes encoded
  bytes to the PTY.

- Observation: Ghostling is a useful behavior lab but not enough for Laban's
  macOS app because Raylib does not provide rich enough native input events
  for full Kitty keyboard protocol correctness.
  Evidence: `/Users/rrj/wrk/ghostling/README.md` says Kitty keyboard protocol
  support is broken for some inputs because Raylib cannot report enough input
  detail, while libghostty-vt itself supports the protocol when given correct
  events.

## Review Gate

A separate fresh-state review agent must verify the following before this
ExecPlan is considered complete. The executing agent must not mark the plan as
done until this gate has passed.

- [x] (2026-05-04) Run `./scripts/check` from the repository root; exit 0, `check passed`.
- [x] (2026-05-04) Run `swift test --filter LabanSessionKeyEncodingTests`; 7 tests pass:
  normal Up arrow, application cursor Up after `ESC [?1h`, Ctrl-C, Shift-Tab,
  `modifyOtherKeys` Ctrl-Shift-H after `ESC [>4;2m`, Kitty Shift-Backspace after
  `ESC [>1u`, and Option-produced text with Option marked consumed.
- [x] (2026-05-04) Run `swift test --filter TerminalKeyInputTests`; 10 tests pass:
  app-command handling, unhandled Command chord swallowing, native Option-produced
  text, PUA function-key mapping, AppKit selector mapping for Enter/Backspace/
  Escape/Tab/Backtab, Ctrl-letter routing through the core encoder, and key-up
  release events with no UTF-8 text.
- [x] (2026-05-04) Run `swift test --filter LabanDebugKeyboardSmokeTests`; 5 tests pass:
  `/debug/actions` `key`, `/debug/input-log`, Command route `appCommand`,
  text route `terminal`, ignored unsupported key actions, recorder-compatible
  event IDs and frame references, and encoded bytes exposed in bounded debug
  diagnostics.
- [x] (2026-05-04) Run `./scripts/test-e2e`; existing E2E flow plus keyboard segment
  (enter key, Cmd-T, `/debug/input-log` route assertions) all pass.
- [x] (2026-05-04) Grep `Sources/LabanTerminalCore/include/LabanTerminalCore.h`; public
  declarations for `LabanKeyEvent`, `LabanKey`, `LabanKeyAction`,
  `laban_session_encode_key`, and `laban_session_send_key` all present.
- [x] (2026-05-04) Grep `Sources/LabanTerminalCore/session.c`; calls to
  `ghostty_key_encoder_new`, `ghostty_key_event_new`,
  `ghostty_key_encoder_setopt_from_terminal`, `ghostty_key_encoder_setopt`,
  and `ghostty_key_encoder_encode` all present.
- [x] (2026-05-04) Run `rg` for escape byte tables in `Sources/LabanApp`; zero hits.
- [x] (2026-05-04) Run `rg` for old helper names in `Sources/LabanApp Tests`; zero hits.
- [x] (2026-05-04) Grep `Sources` for `InputEventEnvelope`; one normalized type with
  `inputId`, `source`, `frameBefore`, `sessionId`, `route`, and `encodedHex`
  in `DebugModels.swift`. `/debug/input-log` projects from that type.
- [ ] In the AppKit app, run `cat -v`, press Enter, Backspace, Tab, Shift-Tab,
  arrows, Ctrl-C, and Option-produced text; verify no Command shortcut text
  leaks to the terminal. Record outcomes in `Outcomes & Retrospective`.
- [ ] In a real TUI (`vim`, `nvim`, or `tmux`), verify arrows, modified arrows,
  function keys, and release-aware keyboard mode behavior. Record in
  `Outcomes & Retrospective`.

Review status: AUTOMATED GATES PASSED — manual AppKit acceptance pending

## Context and Orientation

The relevant files are:

- `Sources/LabanTerminalCore/session.c` owns `struct LabanSession`,
  libghostty terminal state, PTY writes, render state, mouse encoder, and
  snapshot extraction. Add low-level key encoder ownership and key send/encode
  functions here.
- `Sources/LabanTerminalCore/include/LabanTerminalCore.h` is the public C ABI
  used by Swift. Keep raw Ghostty handles and Ghostty enum names out of Swift
  except where they are hidden behind Laban-owned enum names.
- `Sources/LabanCore/Session.swift` wraps the C ABI in Swift. Add Swift
  `KeyEvent`, `Key`, `KeyAction`, modifier constants, `encodeKey`, and
  `sendKey` here.
- `Sources/LabanApp/TerminalBitmapView.swift` owns AppKit responder events,
  `NSTextInputClient`, copy, paste, and the visible terminal view. Replace the
  current key tables with app-command filtering, normalized key events, and
  native text routing.
- `Sources/LabanApp/TerminalInputView.swift` currently contains the manual
  `TerminalKeyEncoder`. Replace it with pure mapping helpers such as
  `TerminalKeyInput`, `TerminalKeyDescriptor`, and `TerminalInputRoute`, or
  delete it if the logic moves to better-named files.
- `Sources/LabanDebug/HeadlessDebugRuntime.swift` and
  `Sources/LabanDebug/DebugHTTPServer.swift` own debug actions and endpoints.
  Implement `key` and `/debug/input-log` here.
- `schemas/debug/action.schema.json` already defines a minimal `key` action.
  Extend it for explicit action type, text, unshifted codepoint, and consumed
  modifiers.
- `schemas/debug/input-log.schema.json` already defines the normalized input
  log response shape. Use it instead of inventing a new route log schema.
- `Tests/LabanTerminalCoreTests/LabanSessionTests.swift`,
  `Tests/LabanAppTests/TerminalKeyEncoderTests.swift`, and
  `Tests/LabanDebugTests/LabanDebugSmokeTests.swift` are the existing nearby
  test files. Add new test files or rename the AppKit test file as needed.

Definitions used in this plan:

- Terminal key encoder means libghostty-vt's `GhosttyKeyEncoder`, which turns
  a normalized key event into terminal input bytes.
- Normalized key event means a platform-independent record containing action
  (`press`, `repeat`, or `release`), physical key identity, active modifiers,
  modifiers consumed by native text input, optional UTF-8 text, optional
  unshifted Unicode codepoint, and whether the event is part of composition.
- Input event envelope means the outer record around a normalized input event.
  It adds replay-oriented context such as a stable `inputId`, source
  (`appkit`, `debug`, `paste`, `mouse`, or `command`), active tab/session IDs,
  routing decision, frame number before the event was applied, encoded bytes,
  and errors. This keyboard plan only keeps a bounded diagnostic log of these
  envelopes. A later recording plan owns durable artifacts and replay.
- Lockstep recording means durable capture where input events, PTY bytes,
  terminal state changes, frame commands, render traces, and screenshots can
  be ordered on one timeline. This plan must preserve enough correlation data
  for that future work but must not implement the full recorder.
- Consumed modifier means a modifier already used by the platform text system
  to produce text. For example, on a macOS layout where Option-4 produces a
  currency symbol, Option is consumed and should not become terminal Alt.
- Application cursor mode is a terminal mode where arrow keys encode
  application sequences such as `ESC OA` instead of normal sequences such as
  `ESC [A`.
- `modifyOtherKeys` is an xterm keyboard mode enabled here with
  `ESC [>4;2m`; it causes many modified text keys to encode as numeric
  escape sequences such as `ESC [27;6;72~`.
- Kitty keyboard protocol is a modern keyboard protocol enabled here with
  sequences such as `ESC [>1u`; it can report disambiguated keys, releases,
  alternate key codes, and associated text.

The checked-out libghostty-vt headers expose these required APIs:

```c
GhosttyResult ghostty_key_encoder_new(
    const GhosttyAllocator *allocator,
    GhosttyKeyEncoder *encoder
);

void ghostty_key_encoder_free(GhosttyKeyEncoder encoder);

void ghostty_key_encoder_setopt_from_terminal(
    GhosttyKeyEncoder encoder,
    GhosttyTerminal terminal
);

void ghostty_key_encoder_setopt(
    GhosttyKeyEncoder encoder,
    GhosttyKeyEncoderOption option,
    const void *value
);

GhosttyResult ghostty_key_encoder_encode(
    GhosttyKeyEncoder encoder,
    GhosttyKeyEvent event,
    char *out_buf,
    size_t out_buf_size,
    size_t *out_len
);
```

`ghostty_key_encoder_setopt_from_terminal` reads cursor-key mode, keypad mode,
Alt escape prefix mode, `modifyOtherKeys`, and Kitty keyboard flags from the
terminal. It resets `macos_option_as_alt` to false, so if Laban later exposes
an Option-as-Alt preference the terminal core must set that option after every
terminal-state sync.

`GhosttyMods` bit order is:

```text
shift = 1
control = 2
alt/option = 4
super/command = 8
capsLock = 16
numLock = 32
```

Use this same bit order in Laban's key ABI. The mouse ABI already uses this
order after a prior review fix; the keyboard ABI should not create a second
modifier convention.

## Plan of Work

### Milestone 1: Terminal Core Key ABI

Add a small C ABI for key events while keeping Swift out of raw libghostty
handles.

In `Sources/LabanTerminalCore/include/LabanTerminalCore.h`, add:

```c
typedef enum {
    LABAN_KEY_ACTION_RELEASE = 0,
    LABAN_KEY_ACTION_PRESS = 1,
    LABAN_KEY_ACTION_REPEAT = 2
} LabanKeyAction;

typedef enum {
    LABAN_KEY_UNIDENTIFIED = 0,
    LABAN_KEY_BACKQUOTE,
    LABAN_KEY_BACKSLASH,
    LABAN_KEY_BRACKET_LEFT,
    LABAN_KEY_BRACKET_RIGHT,
    LABAN_KEY_COMMA,
    LABAN_KEY_DIGIT_0,
    LABAN_KEY_DIGIT_1,
    LABAN_KEY_DIGIT_2,
    LABAN_KEY_DIGIT_3,
    LABAN_KEY_DIGIT_4,
    LABAN_KEY_DIGIT_5,
    LABAN_KEY_DIGIT_6,
    LABAN_KEY_DIGIT_7,
    LABAN_KEY_DIGIT_8,
    LABAN_KEY_DIGIT_9,
    LABAN_KEY_EQUAL,
    LABAN_KEY_A,
    LABAN_KEY_B,
    LABAN_KEY_C,
    LABAN_KEY_D,
    LABAN_KEY_E,
    LABAN_KEY_F,
    LABAN_KEY_G,
    LABAN_KEY_H,
    LABAN_KEY_I,
    LABAN_KEY_J,
    LABAN_KEY_K,
    LABAN_KEY_L,
    LABAN_KEY_M,
    LABAN_KEY_N,
    LABAN_KEY_O,
    LABAN_KEY_P,
    LABAN_KEY_Q,
    LABAN_KEY_R,
    LABAN_KEY_S,
    LABAN_KEY_T,
    LABAN_KEY_U,
    LABAN_KEY_V,
    LABAN_KEY_W,
    LABAN_KEY_X,
    LABAN_KEY_Y,
    LABAN_KEY_Z,
    LABAN_KEY_MINUS,
    LABAN_KEY_PERIOD,
    LABAN_KEY_QUOTE,
    LABAN_KEY_SEMICOLON,
    LABAN_KEY_SLASH,
    LABAN_KEY_BACKSPACE,
    LABAN_KEY_ENTER,
    LABAN_KEY_SPACE,
    LABAN_KEY_TAB,
    LABAN_KEY_DELETE,
    LABAN_KEY_END,
    LABAN_KEY_HOME,
    LABAN_KEY_INSERT,
    LABAN_KEY_PAGE_DOWN,
    LABAN_KEY_PAGE_UP,
    LABAN_KEY_ARROW_DOWN,
    LABAN_KEY_ARROW_LEFT,
    LABAN_KEY_ARROW_RIGHT,
    LABAN_KEY_ARROW_UP,
    LABAN_KEY_ESCAPE,
    LABAN_KEY_F1,
    LABAN_KEY_F2,
    LABAN_KEY_F3,
    LABAN_KEY_F4,
    LABAN_KEY_F5,
    LABAN_KEY_F6,
    LABAN_KEY_F7,
    LABAN_KEY_F8,
    LABAN_KEY_F9,
    LABAN_KEY_F10,
    LABAN_KEY_F11,
    LABAN_KEY_F12,
    LABAN_KEY_F13,
    LABAN_KEY_F14,
    LABAN_KEY_F15,
    LABAN_KEY_F16,
    LABAN_KEY_F17,
    LABAN_KEY_F18,
    LABAN_KEY_F19,
    LABAN_KEY_F20,
    LABAN_KEY_F21,
    LABAN_KEY_F22,
    LABAN_KEY_F23,
    LABAN_KEY_F24
} LabanKey;

enum {
    LABAN_KEY_MOD_SHIFT = 1 << 0,
    LABAN_KEY_MOD_CONTROL = 1 << 1,
    LABAN_KEY_MOD_ALT = 1 << 2,
    LABAN_KEY_MOD_SUPER = 1 << 3,
    LABAN_KEY_MOD_CAPS_LOCK = 1 << 4,
    LABAN_KEY_MOD_NUM_LOCK = 1 << 5,
    LABAN_KEY_MOD_SHIFT_SIDE = 1 << 6,
    LABAN_KEY_MOD_CONTROL_SIDE = 1 << 7,
    LABAN_KEY_MOD_ALT_SIDE = 1 << 8,
    LABAN_KEY_MOD_SUPER_SIDE = 1 << 9
};

typedef struct {
    LabanKeyAction action;
    LabanKey key;
    int modifiers;
    int consumed_modifiers;
    int composing;
    uint32_t unshifted_codepoint;
    const char *utf8;
    size_t utf8_len;
} LabanKeyEvent;

int laban_session_encode_key(
    LabanSession *session,
    const LabanKeyEvent *event,
    uint8_t *out_bytes,
    size_t out_capacity,
    size_t *out_len
);

int laban_session_send_key(LabanSession *session, const LabanKeyEvent *event);
```

Add numpad and international keys later only when AppKit mapping or tests need
them. The first implementation must include all keys listed above because they
cover shell editing, TUIs, F-key bindings, and debug actions.

In `Sources/LabanTerminalCore/session.c`:

- Include `ghostty/vt/key/encoder.h` and `ghostty/vt/key/event.h`.
- Add `GhosttyKeyEncoder key_encoder;` and `GhosttyKeyEvent key_event;` to
  `struct LabanSession`.
- Allocate both during `laban_session_create` after terminal creation and
  before the session is returned. On any failure, free all earlier resources.
- Free both in `free_ghostty_resources`.
- Add a `map_laban_key` function that switches from `LabanKey` to `GhosttyKey`.
  Do not rely on enum numeric equality with Ghostty.
- Add a `map_laban_key_action` function that switches to
  `GhosttyKeyAction`.
- Implement `laban_session_encode_key`:
  - validate `session`, `event`, and `out_len`;
  - set `*out_len = 0` before doing work;
  - call `ghostty_key_encoder_setopt_from_terminal(s->key_encoder,
    s->terminal)`;
  - set `GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT` to
    `GHOSTTY_OPTION_AS_ALT_FALSE` after syncing terminal state;
  - fill the persistent `s->key_event` with action, key, modifiers,
    consumed modifiers, composing, unshifted codepoint, and UTF-8 text;
  - pass `NULL, 0` as UTF-8 when `utf8_len == 0`, when `utf8 == NULL`, or when
    the text is a C0 control character or macOS private-use function key;
  - call `ghostty_key_encoder_encode`;
  - clear the event's UTF-8 pointer back to `NULL, 0` before returning so the
    persistent event never retains a Swift buffer pointer;
  - if libghostty returns `GHOSTTY_OUT_OF_SPACE`, return a distinct nonzero
    error for encode-only calls and leave `out_len` containing the required
    size.
- Implement `laban_session_send_key`:
  - call `laban_session_encode_key` with a 128-byte stack buffer;
  - if it returns out-of-space, allocate the required size, encode again, and
    free the buffer after writing;
  - return 0 when encoded length is zero;
  - in PTY mode, write encoded bytes to `pty_fd`;
  - in fixture mode, do not pretend a PTY exists. Return 0 after encoding and
    let tests assert bytes with `laban_session_encode_key`.

Add `Tests/LabanTerminalCoreTests/LabanSessionKeyEncodingTests.swift` with
direct C ABI tests. Use fixture sessions because encoding depends on terminal
state, not a live PTY.

Required core tests:

- Normal Up arrow encodes `ESC [A`.
- After writing `ESC [?1h` to the fixture terminal, Up arrow encodes
  `ESC OA`.
- Ctrl-C with key `LABAN_KEY_C`, modifier `LABAN_KEY_MOD_CONTROL`, no UTF-8,
  encodes byte `0x03`.
- Shift-Tab encodes `ESC [Z`.
- After writing `ESC [>4;2m`, Ctrl-Shift-H with UTF-8 `H` and unshifted
  codepoint `h` encodes `ESC [27;6;72~`.
- After writing `ESC [>1u`, Shift-Backspace encodes `ESC [127;2u`.
- Option-produced text with modifiers `ALT`, consumed modifiers `ALT`,
  UTF-8 text such as `[` or `$`, and Option-as-Alt false encodes exactly that
  text, not an ESC-prefixed Alt sequence.

### Milestone 2: Swift Session Wrapper

In `Sources/LabanCore/Session.swift`, add:

- `public enum KeyAction { case release, press, repeat }`
- `public enum Key { ... }` matching the C keys above.
- `public struct KeyModifiers: OptionSet` using the same bit values as the C
  `LABAN_KEY_MOD_*` constants.
- `public struct KeyEvent` with action, key, modifiers, consumedModifiers,
  composing, unshiftedCodepoint, and optional `text`.
- `func toLabanKeyEvent(_:)` conversion.
- `public func encodeKey(_ event: KeyEvent) -> [UInt8]?`.
- `@discardableResult public func sendKey(_ event: KeyEvent) -> Int32`.

Keep the public Swift names small and terminal-neutral. The Swift layer should
not expose `GhosttyKey`, `GhosttyMods`, or `GhosttyKeyEncoder`.

### Milestone 3: AppKit Input Routing

Replace the manual AppKit escape-table path with a three-stage route:

1. App commands.
2. Native text and IME.
3. Terminal-core encoded non-text keys.

In `Sources/LabanApp/TerminalInputView.swift`, replace `TerminalKeyEncoder`
with pure helpers that can be unit-tested without an AppKit window. A good
shape is:

```swift
struct TerminalKeyDescriptor {
  var action: KeyAction
  var key: Key
  var modifiers: KeyModifiers
  var characters: String?
  var charactersIgnoringModifiers: String?
  var isComposing: Bool
  var isRepeat: Bool
}

enum TerminalInputRoute: Equatable {
  case appCommand(AppCommand)
  case swallowCommand
  case nativeText
  case encodedKey(KeyEvent)
  case ignored
}
```

Map `NSEvent` into `TerminalKeyDescriptor` in one place. Import
`Carbon.HIToolbox` and use macOS virtual key codes such as `kVK_ANSI_A`,
`kVK_ANSI_0`, `kVK_Return`, `kVK_Delete`, `kVK_Escape`, `kVK_Tab`, and
function/navigation key constants where possible. For arrows and F-keys,
also support AppKit private-use characters from
`charactersIgnoringModifiers` because those are what the current view sees:
`NSUpArrowFunctionKey`, `NSDownArrowFunctionKey`, `NSLeftArrowFunctionKey`,
`NSRightArrowFunctionKey`, `NSF1FunctionKey` through `NSF24FunctionKey`,
`NSHomeFunctionKey`, `NSEndFunctionKey`, `NSPageUpFunctionKey`,
`NSPageDownFunctionKey`, and `NSDeleteFunctionKey`.

Modifier mapping rules:

- Shift sets `LABAN_KEY_MOD_SHIFT`.
- Control sets `LABAN_KEY_MOD_CONTROL`.
- Option sets `LABAN_KEY_MOD_ALT`.
- Command sets `LABAN_KEY_MOD_SUPER`, but Command events are handled or
  swallowed before terminal encoding.
- Caps Lock and Num Lock should be set if AppKit exposes them in
  `modifierFlags`.
- Left/right side bits may be left unset in the first implementation if AppKit
  does not provide them through stable APIs.

Routing rules:

- If Command is down, handle Cmd-T, Cmd-W, Cmd-1 through Cmd-9, Cmd-C, and
  Cmd-V as app commands when they reach the view. For any other Command chord,
  return `.swallowCommand`. Do not call `interpretKeyEvents` for Command
  chords.
- If Control is down and the key is a mappable text key or special key, return
  `.encodedKey` with no UTF-8 text instead of letting AppKit insert C0 control
  text. This lets libghostty decide whether Ctrl-C is byte `0x03`, a
  `modifyOtherKeys` sequence, or a Kitty keyboard sequence.
- If the event is a non-text physical key such as an arrow, function key,
  Escape, Backspace, Enter, Tab, or Shift-Tab, return `.encodedKey`.
- For ordinary text and Option-produced text, return `.nativeText` so
  `interpretKeyEvents([event])` can call `insertText` through AppKit's native
  text system. When `insertText` is called while a current key descriptor is
  active, build a `KeyEvent` with the committed UTF-8 text, the physical key if
  known, and consumed modifiers. Mark Shift consumed when Shift was down and
  produced text; mark Option consumed when Option was down and produced text.
  Do not mark Control or Command consumed.
- `setMarkedText` updates composition state but sends no bytes. Final
  `insertText` sends the committed text. If there is no active physical key
  descriptor, write UTF-8 directly to the session as the conservative IME
  fallback.
- `keyUp(with:)` should send release events for mappable physical keys with no
  UTF-8 text. The encoder will usually produce no bytes unless a terminal app
  enabled a release-aware keyboard protocol.

In `Sources/LabanApp/TerminalBitmapView.swift`:

- Add a `currentKeyDescriptor` property used only during
  `interpretKeyEvents([event])`.
- Rework `keyDown(with:)` to:
  - build a descriptor;
  - route app commands or swallowed Command chords;
  - send encoded keys directly for non-text/control routes;
  - otherwise set `currentKeyDescriptor`, call `interpretKeyEvents([event])`,
    and clear `currentKeyDescriptor` with `defer`.
- Rework `insertText` to encode text through `session.sendKey` when
  `currentKeyDescriptor` is present and the text is not a C0 control or PUA
  function-key scalar. Fall back to `session.write(Array(text.utf8))` when no
  descriptor is available.
- Rework `doCommand(by:)` so Enter, Backspace, Escape, Tab, and Backtab become
  `KeyEvent`s sent through `session.sendKey`, not literal byte arrays.
- Add `override func keyUp(with event: NSEvent)` to send release events for
  mappable keys.
- Keep `paste(_:)` using `session.writePaste` if that helper exists in the
  current tree, or the existing paste wrapper. Paste is not a key event.

Add `Tests/LabanAppTests/TerminalKeyInputTests.swift`. Tests should exercise
the pure descriptor/route helpers rather than constructing real `NSEvent`
objects where that would be brittle.

Required AppKit input tests:

- Cmd-T routes to `.appCommand(.newTab)`.
- Cmd-W routes to close active tab.
- Cmd-1 routes to select tab index 0.
- Cmd-X or another unimplemented Command chord routes to `.swallowCommand`.
- Option-produced text routes to `.nativeText`; the built text key event has
  Option in `consumedModifiers`.
- Control-C routes to `.encodedKey` with key C, Control modifier, and no UTF-8
  text.
- Shift-Tab routes to key Tab with Shift modifier.
- Arrow PUA scalars route to the corresponding arrow keys with modifiers
  preserved.
- `doCommand` selector mapping creates key events for Enter, Backspace,
  Escape, Tab, and Backtab.
- Key-up creates release actions without UTF-8 text.

### Milestone 4: Debug Actions And Input Log

The debug server must expose keyboard routes so agents can verify the behavior
without desktop automation.

In `schemas/debug/action.schema.json`, extend the `key` action to allow:

```json
{
  "action": "key",
  "key": "enter",
  "type": "press",
  "modifiers": ["shift", "control", "alt", "option", "command", "super"],
  "consumedModifiers": ["shift", "alt", "option"],
  "text": "$",
  "unshifted": "4"
}
```

Use `type` values `press`, `repeat`, and `release`; default to `press` if the
field is absent. `key` names should include letters `a` through `z`, digits
`0` through `9`, `enter`, `backspace`, `escape`, `tab`, `space`, `delete`,
`home`, `end`, `pageUp`, `pageDown`, `insert`, `arrowUp`, `arrowDown`,
`arrowLeft`, `arrowRight`, and `f1` through `f24`. Keep the existing
`modifiers` aliases where both `alt` and `option` map to `LABAN_KEY_MOD_ALT`,
and both `command` and `super` map to `LABAN_KEY_MOD_SUPER`.

In `Sources/LabanDebug/HeadlessDebugRuntime.swift` and the shared input helper
files:

- Add a reusable input event envelope type rather than a private
  `HeadlessDebugRuntime` JSON struct. A good shape is `InputEventEnvelope`
  with at least `inputId`, `seq`, `source`, `kind`, `route`, `frameBefore`,
  `tabId`, `sessionId`, `key`, `text`, `modifiers`, `consumedModifiers`,
  `command`, `encodedHex`, and `error`. The name can differ, but the type must
  be reusable by a future capture writer and by `/debug/input-log`.
- Add an input-log ring buffer with a bounded maximum, for example 512
  envelopes. The ring is a diagnostic projection only; it is not the durable
  capture artifact.
- Ensure every envelope has a stable `inputId` string, a monotonically
  increasing `seq`, and the frame number before the event was applied. If the
  event routes to a terminal session, include that session ID. If it produces
  terminal input bytes, include `encodedHex` and byte length. Do not store only
  human-readable text because a later replay plan must compare exact bytes.
- Log existing `typeText`, `paste`, `copy`, mouse, and command routes as input
  envelopes while preserving the current `/debug/events` endpoint.
- Implement `case "key"`:
  - parse the key action into a `KeyEvent`;
  - if Command is present, use the same app-command policy as AppKit:
    handled commands affect tabs/clipboard and route `appCommand`; unhandled
    Command chords route `ignored` and send no terminal bytes;
  - otherwise call `session.encodeKey` to capture encoded bytes for the debug
    response/log and `session.sendKey` for real PTY sessions;
  - in fixture mode, do not feed non-text terminal-control input into the VT
    parser. Return ok if encoding succeeds and log the encoded bytes.
- Add `GET /debug/input-log?since=<sequence>` in
  `Sources/LabanDebug/DebugHTTPServer.swift`.
- Serve `/debug/input-log` by projecting the stored envelopes into
  `schemas/debug/input-log.schema.json`. The schema permits additional
  properties; include `inputId`, `source`, `frameBefore`, `tabId`,
  `sessionId`, `encodedHex`, and `encodedLength` whenever present.
- Do not add a replay format, capture manifest, screenshot capture, or byte
  stream archive in this keyboard plan. Those belong to the full capture/replay
  ExecPlan. This plan only ensures keyboard/input data is structured enough for
  that future recorder to subscribe to the same event stream.

Add `Tests/LabanDebugTests/LabanDebugKeyboardSmokeTests.swift`.

Required debug tests:

- `{"action":"key","key":"enter"}` returns ok and logs kind `key`, route
  `terminal`, an `inputId`, `frameBefore`, and a session ID.
- `{"action":"key","key":"t","modifiers":["command"]}` creates a new tab and
  logs route `appCommand`, command `newTab`.
- `{"action":"key","key":"x","modifiers":["command"]}` logs route `ignored`
  and does not write terminal bytes.
- `{"action":"key","key":"4","modifiers":["option"],"consumedModifiers":["option"],"text":"$","unshifted":"4"}`
  logs text route `terminal`, consumed modifier `option`, and encoded text
  bytes for `$` in `encodedHex`.
- `GET /debug/input-log?since=0` returns `events` and `next`.

### Milestone 5: End-To-End And Manual Acceptance

Extend `scripts/test-e2e` with a short keyboard section:

- start the headless debug server as it already does;
- send `{"action":"key","key":"enter"}`;
- send `{"action":"key","key":"t","modifiers":["command"]}`;
- fetch `/debug/input-log?since=0`;
- assert that at least one event has `kind == "key"` and `route ==
  "terminal"`;
- assert that one event has `route == "appCommand"` and `command == "newTab"`;
- assert that no Command event route is `terminal`.

Manual AppKit acceptance is still required because native text and IME are
platform behavior:

- Launch `.build/laban/Laban.app/Contents/MacOS/LabanApp`.
- Run `cat -v`.
- Press Enter, Backspace, Tab, Shift-Tab, arrows, F1 if available, Ctrl-C,
  and local-layout Option-produced characters. Observe that control keys and
  text behave as they do in a native terminal and that Option-produced text is
  visible as text.
- Press Command chords that are not implemented, such as Cmd-X. Observe that
  no character or escape sequence appears in `cat -v`.
- Run one real TUI available on the machine, such as `vim`, `nvim`, or `tmux`.
  Exercise arrows, modified arrows, Tab/Shift-Tab, and function keys. Record
  any program-specific gaps in this plan under `Surprises & Discoveries`.

## Concrete Steps

Run commands from the repository root:

```sh
pwd
# /Users/rrj/wrk/laban/.claude/worktrees/still-glowing-cobra

swift test --filter LabanSessionKeyEncodingTests
swift test --filter TerminalKeyInputTests
swift test --filter LabanDebugKeyboardSmokeTests
./scripts/test-e2e
./scripts/check
```

During implementation, run focused tests after each milestone. Before marking
the plan complete, run the full Review Gate. If a command fails, keep the plan
current by adding a Progress entry or Surprise with the failure and the fix.

## Validation and Acceptance

The feature is accepted only when all of these are true:

- The old Swift terminal escape table is gone from app code. App code maps
  platform keys to Laban key events, not terminal bytes.
- `laban_session_encode_key` proves libghostty-vt encodes default, cursor
  application, `modifyOtherKeys`, and Kitty keyboard protocol sequences from
  current terminal state.
- Native AppKit text input still sends layout-specific text exactly once.
- Option-produced text is not converted into terminal Alt by default.
- Handled Command shortcuts perform the app command and do not leak generated
  text into the terminal.
- Unhandled Command shortcuts are swallowed.
- Debug `/debug/actions` can drive key events without desktop automation.
- `/debug/input-log` exposes whether each key/text/command went to the
  terminal, app command layer, or ignored route.
- `./scripts/check` passes.
- Manual AppKit acceptance has been recorded in this plan.

## Idempotence and Recovery

All changes are additive or replacement edits inside source and test files.
The key ABI can be implemented and tested without a real shell by using
fixture sessions and `laban_session_encode_key`. If a session creation change
fails midway, restore by freeing any newly allocated key encoder/event in the
same cleanup path used for render and mouse resources.

Do not delete the old `TerminalKeyEncoder` until the new core key tests and
AppKit route tests pass. When deleting it, also delete or rewrite tests that
assert hard-coded escape bytes in Swift; those tests should move to
`LabanSessionKeyEncodingTests`.

Generated artifacts from `./scripts/test-e2e` belong under `.artifacts/` and
`.tmp/`, which are already ignored by git.

## Interfaces and Dependencies

Use libghostty-vt's checked-in C API; do not add a new keyboard protocol
dependency and do not hand-roll xterm, Kitty, or function-key tables in Swift.

The terminal-core implementation depends on:

- `ghostty/vt/key/encoder.h`
- `ghostty/vt/key/event.h`
- `ghostty/vt/terminal.h`

The AppKit implementation depends on:

- `AppKit.NSEvent` for responder events and native text input.
- `NSTextInputClient` methods already implemented by `TerminalBitmapView`.
- `Carbon.HIToolbox` virtual key constants for stable physical-key mapping.

The debug implementation depends on existing project debug contracts:

- `docs/process/dev-process.md`
- `schemas/debug/action.schema.json`
- `schemas/debug/input-log.schema.json`
- `schemas/debug/events.schema.json`

## Outcomes & Retrospective

Fill this section after implementation or at major milestones. Include the
final commit SHA, the exact tests run, the AppKit/TUI manual programs used,
and any known keyboard gaps deliberately deferred to future settings or
accessibility work.
