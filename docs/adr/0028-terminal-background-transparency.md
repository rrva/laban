# 28. Terminal Background Transparency Uses One Renderer-Neutral Compositing Contract

Date: 2026-07-15

## Status

Accepted. Implementation is tracked in
`execplans/active/terminal-background-transparency.md`.

## Context

Laban has five renderer selections: software, classic Metal, GPU-driven Metal,
vector glyph, and Slug glyph. They share terminal and sidebar frame production,
but they do not all establish or retain pixels in the same way. The software
path reuses a Core Graphics bitmap, while the Metal paths retain alpha-capable
targets and can replay only damaged regions. Merely making a window or layer
nonopaque is therefore insufficient. Drawing a translucent themed background
with normal source-over blending more than once accumulates alpha toward opaque,
and retaining old pixels across damage can expose stale alpha.

Transparency also crosses process and UI boundaries. Local snapshots can know
whether a terminal cell inherited the default background, but an older `laband`
snapshot writer does not carry that semantic identity. AppKit owns the window
and macOS accessibility/full-screen state, while render threads must remain free
of `UserDefaults`, AppKit material views, and policy decisions. RGB-subpixel
glyph coverage additionally assumes a known opaque destination and is invalid
when the desktop or another window can show through the target.

The product contract in `docs/product/spec.md` ships direct background opacity
first. A system material and the theme-neutral `Frosted` preset are approved
direction, but their WindowServer behavior and performance evidence belong to a
separate follow-up.

## Decision

### Ownership is split at existing boundaries

- `TerminalTransparencySettings` owns the persisted **requested** opacity,
  explicit-cell opt-in, and backdrop-style value. It publishes changes but does
  not inspect windows, accessibility state, sessions, or renderers.
- `TerminalWindowTransparencyCoordinator` is the single MainActor owner of the
  **effective** policy for a window. It combines the requested configuration
  with native-full-screen state, the cached Reduce Transparency input, active
  snapshot-writer capability, native-effect capability, and headless state. It
  configures `NSWindow.isOpaque`, keeps nonopaque window backgrounds clear, and
  passes the resolved state to `TerminalBitmapView`.
- `TerminalBitmapView` remains the sole owner of the existing
  `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` observer. It
  refreshes all cached accessibility display options once, forwards Reduce
  Transparency to the coordinator, coalesces the resulting invalidation into
  one render wake, and applies the effective state to a backend before that
  backend's presentation layer becomes visible. No second workspace observer
  is added for transparency.
- `TerminalSurfaceFrameRequest` carries already-resolved background-compositing
  options and the snapshot-background capability through local, remote,
  prewarm, switch, capture/replay, visible-app, and headless paths.
  `FrameProducer` and `SidebarProducer` consume those values without reading
  settings or AppKit state. The sidebar cache signature includes the
  compositing options.
- Each `RendererBackend` owns only presentation-surface opacity and the
  mechanics needed to honor compositing and damage. It does not resolve user or
  system policy. Software, classic, GPU-driven, vector, and Slug must implement
  the same output contract.
- A future `TerminalBackgroundEffectHost` is an AppKit-only owner of at most one
  behind-window material view below the terminal surface and every overlay. It
  does not exist in the direct-opacity delivery, and neither `LabanCore` nor
  `LabanRenderer` may depend on `NSVisualEffectView`.

Requested values survive every temporary override. The effective resolver is
pure and deterministic. Reduce Transparency forces an opaque surface first,
native full screen second, and a legacy snapshot writer third. Removing an
override restores the unchanged request immediately; removing one of several
active overrides cannot restore transparency. An unavailable or headless
system-material request resolves its effective backdrop to `none` without
discarding the requested value. An opacity of exactly `1.0` resolves to an
opaque surface and no active backdrop.

### Background pixels replace; semantic content composites source-over

Frame-command colors remain in Laban's existing straight-RGBA representation.
Each renderer converts them to premultiplied RGBA exactly once at its existing
Core Graphics or shader boundary. Producers do not premultiply colors.

Background-establishing primitives use `replace` compositing: terminal and
sidebar base canvases, inherited/default cell backgrounds, and explicit or
inverse cell backgrounds. `replace` means a primitive writes the final
premultiplied RGBA bytes for its covered pixels, so replaying it is idempotent.
The GPU-cell solid-background phase has the same semantics even when its input
is `TerminalCellPayload` rather than a rectangle command. Glyph coverage,
cursor, selection, find highlights, preedit content, images, selected-tab and
attention chrome, and other semantic overlays retain source-over compositing
and their existing semantic alpha.

A full frame resets the entire target with blending disabled. If a terminal
canvas is present, the reset overwrites with that resolved themed canvas RGBA,
including effective alpha; otherwise it writes transparent black. Replaying the
canvas as a replace command must leave the same bytes. A partial redraw first
erases each damaged region to transparent black with blending disabled, then
replays intersecting commands. Scroll blits copy existing premultiplied pixels
without modification, and newly exposed regions follow the same erase-and-
replay rule. Core Graphics implements replace with `CGBlendMode.copy`; Metal
uses a no-blend pipeline equivalent to source one and destination zero.

The themed background is applied exactly once. `NSWindow`, permanent AppKit
views/layers, and renderer presentation surfaces contribute no second tint. A
temporary launch or resize fallback, if needed, is a distinct removable layer
and is removed before renderer pixels are presented. Surface-policy changes
invalidate retained targets and require the next presented frame to initialize
the whole target, preventing stale, opaque, white, or previous-frame flashes.

### Explicit cell identity is transported, not inferred

`LABAN_CELL_FLAG_EXPLICIT_BACKGROUND` uses bit 9 of the existing `UInt16` cell
flags. Snapshot production sets it when Ghostty successfully supplies an
explicit background or when inverse video is active, including when the
explicit color equals the theme default. Glyph style and batch keys mask this
non-glyph flag out.

New `laband` writers advertise `snapshotCellExplicitBackgroundV1`, and local
in-process snapshots are capability-known. A remote session whose writer does
not advertise that capability is `legacy`; it forces the entire effective
surface opaque rather than treating a missing bit as inherited background or
guessing from colors. The request remains stored and is restored when a local
or capability-aware session becomes active. Protocol and ring ABI 1 may remain
only if hello negotiation mechanically gates every old-writer path and bit 9 is
preserved by new JSON and ring transport; otherwise the relevant ABI must be
bumped before shipping.

### Translucent glyph targets use grayscale antialiasing

Vector and Slug resolve their effective glyph antialiasing to grayscale for
every nonopaque or material-backed surface. RGB-subpixel coverage assumes an
opaque destination and can fringe over unknown desktop colors. This is an
effective rendering choice only: the configured RGB-subpixel preference stays
persisted and is restored as soon as the effective surface is opaque. Renderers
without an RGB-subpixel mode keep their existing antialiasing behavior.

### Native materials are deferred and remain an AppKit concern

The direct-opacity feature creates no backdrop-effect view. `System Blur` and
the localized, theme-neutral `Frosted` preset are deferred to a separate
ExecPlan after direct opacity ships and passes review. `Frosted` is fixed at
90% background opacity with System Blur and opaque explicit cell backgrounds;
it never changes the active theme and is never selected from locale, language,
input source, or CJK font.

That follow-up must use a public semantic behind-window AppKit material hosted
below terminal content. It must not put Liquid Glass behind terminal content,
use private Core Animation filters, capture the screen as a feedback loop,
implement blur in a renderer shader, or expose a configurable blur radius.
Public native material keeps blur and power behavior in AppKit/WindowServer,
adapts to system appearance and accessibility, and leaves all five renderer
contracts unchanged.

## Consequences

- The default request remains opacity `1.0`, explicit-cell opacity off, and no
  backdrop, preserving existing opaque rendering and idle behavior.
- Direct transparency can be implemented once in frame semantics and then
  proven equivalent across all five backends instead of becoming a Slug-only
  feature.
- Retained full frames, repeated damage, and scroll blits remain alpha-stable;
  repeated drawing cannot make a 70% background drift toward opaque.
- Semantic foreground and application-selected background content remains
  legible by default. Users can separately opt explicit and inverse cell
  backgrounds into opacity.
- Renderer switching, prewarming, resizing, view reconstruction, session
  selection, accessibility changes, and full-screen transitions must apply the
  current effective state before presentation without changing terminal session
  identity.
- Headless PNGs preserve alpha and use the same producers and backend contract,
  making alpha, override, and mixed-version behavior autonomously verifiable.
- A settings or accessibility change may invalidate, wake, and present once;
  translucency does not create a periodic render source and preserves ADR
  0018/0026 idle and presenter invariants.

## Applies To New Code

- New producers must receive background-compositing policy through their frame
  request. They must not read `UserDefaults`, AppKit state, or renderer type.
- New renderers and renderer fast paths must support both replace and
  source-over semantics, full overwrite reset, partial transparent erasure,
  alpha-preserving scroll blits/readback, and live surface-opacity changes.
- Additions to snapshot transport must preserve explicit-background identity
  and negotiate writer capability; color equality is never a substitute.
- Any new RGB-subpixel path must resolve to grayscale when its destination is
  not known opaque.
- Any future background effect remains outside frame production and renderer
  code. Changing the native-material constraints, `Frosted` definition, or the
  direct-opacity exclusions requires an ADR amendment and corresponding product
  contract update.
