# 28. Terminal Background Transparency Uses One Renderer-Neutral Compositing Contract

Date: 2026-07-15

## Status

Accepted; amended 2026-07-15 after installed-app validation and again for
user-imported background images, then amended 2026-07-16 for the complete
linear-premultiplied working-space and encoded-sRGB storage boundary on
translucent curve-renderer targets. Implementation is tracked in
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

Installed-app validation showed that applying opacity to the sidebar base while
leaving tab cards opaque fragmented one navigation surface into mismatched
layers, and that direct transparency without backdrop blur was not useful
enough. The product contract therefore keeps the entire sidebar opaque and
promotes a system material plus the theme-neutral `Frosted` preset into the
active implementation. Their WindowServer behavior and performance evidence
remain mandatory rather than being waived by the scope amendment.

The same terminal-only host also needs to support a user-imported still image.
That image is another backdrop source, not terminal image content and not a new
renderer feature. Treating it as an AppKit sibling below the terminal canvas
lets the existing themed canvas alpha remain the only tint control and keeps
software, classic Metal, GPU-driven Metal, vector glyph, and Slug identical.

## Decision

### Ownership is split at existing boundaries

- `TerminalTransparencySettings` owns the persisted **requested** opacity,
  explicit-cell opt-in, mutually exclusive backdrop source, imported-image
  identifier, and image-scaling mode. It publishes changes but does not inspect
  windows, accessibility state, sessions, or renderers. It never derives a
  request from locale, language, region, input source, or CJK font.
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
  `FrameProducer` consumes those values without reading settings or AppKit
  state. `SidebarProducer` deliberately does not consume terminal opacity, and
  its cache signature excludes terminal compositing options so a terminal-only
  opacity change can reuse the fully opaque navigation commands.
- Each `RendererBackend` owns only presentation-surface opacity and the
  mechanics needed to honor compositing and damage. It does not resolve user or
  system policy. Software, classic, GPU-driven, vector, and Slug must implement
  the same output contract.
- `TerminalBackgroundEffectHost` is the AppKit-only owner of at most one
  backdrop child below the terminal surface and every overlay: either one
  behind-window material view for effective System Blur or one cached still-
  image view for effective Image, never both. It never extends under the opaque
  sidebar. Neither `LabanCore` nor `LabanRenderer` may depend on
  `NSVisualEffectView`, `NSImage`, ImageIO, or image-scaling geometry.

Requested values survive every temporary override. The effective resolver is
pure and deterministic. Reduce Transparency forces an opaque surface first,
native full screen second, and a legacy snapshot writer third. Removing an
override restores the unchanged request immediately; removing one of several
active overrides cannot restore transparency. An unavailable or headless
system-material request resolves its effective backdrop to `none` without
discarding the requested value. An opacity of exactly `1.0` resolves to an
opaque surface and no active backdrop.

Image is available only when its managed copy exists and decodes. A missing or
corrupt managed image adds the lowest-priority visible-window force-opaque
reason `backgroundImageUnavailable`: Reduce Transparency, native full screen,
and legacy snapshot-writer policy retain their existing order ahead of it. The
request and scaling mode survive the failure, but the app never falls through
to direct desktop transparency. Headless mode preserves an Image request while
resolving its AppKit-only effective backdrop to `none`.

### Background pixels replace; semantic content composites source-over

Frame-command colors remain in Laban's existing straight-RGBA representation.
Each renderer converts them to its active target's premultiplied representation
at the existing Core Graphics or shader boundary. Producers do not premultiply
colors. A storage resolve may convert between linear-premultiplied working color
and encoded-sRGB-premultiplied presentation color, but it never treats already-
premultiplied RGB as straight color or multiplies it by the same alpha twice.

Background-establishing primitives use `replace` compositing: the translucent
terminal base canvas, the fully opaque sidebar base canvas, inherited/default
cell backgrounds, and explicit or inverse cell backgrounds. `replace` means a
primitive writes the final premultiplied RGBA bytes for its covered pixels, so
replaying it is idempotent.
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

For Vector and Slug, the final `bgra8Unorm_srgb` presentation target has an
additional storage boundary. Metal decodes the existing encoded-sRGB-
premultiplied destination bytes before fixed-function blending, which produces
`linear(sRGB * alpha)` rather than the `linear(sRGB) * alpha` representation
required for correct linear-light source-over. Correcting only replacement
backgrounds therefore leaves bright antialiased glyph edges and semantic
overlays wrong.

Every nonopaque Vector and Slug frame instead composites completely into a
private `rgba16Float` linear-premultiplied working target. Replacement
backgrounds, clears, glyph coverage, semantic alpha, and source-over blending
all operate there. A single full-frame resolve then unpremultiplies in linear
light, encodes the straight color to sRGB, premultiplies in encoded sRGB, and
writes the existing final `bgra8Unorm_srgb` bytes. Only that final target is
published, presented, read back, or encoded as PNG. A retained partial redraw
loads and repairs the working target paired with the same final ring slot, then
resolves the complete frame once. Allocation or pipeline failure is fail-closed;
the render does not fall back to blending directly into encoded-premultiplied
sRGB storage.

An always-opaque Vector or Slug surface preserves the shipped direct path: it
compiles no translucent shader library or pipeline, allocates no working
texture, and adds no resolve pass. Its existing sRGB target continues to provide
linear-light blending with alpha fixed at one.

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

### Native backdrops remain an AppKit concern

`None`, `System Blur`, and `Image` are mutually exclusive background sources.
`None` preserves direct window transparency. `System Blur` and Image occupy the
same terminal-only AppKit host below the terminal canvas. The renderer's
existing background opacity remains the sole tint control for every source;
there is no independent image-opacity control. At opacity 1.0 the host owns no
active child and contributes no steady-state cost.

Image selection is a managed import, not a durable reference to the original
file. After an `NSOpenPanel` selection decodes successfully, Laban copies the
still image through a staging file into a private `background-images`
subdirectory of `PersistenceStore.defaultBaseURL()`, commits only a generated
relative identifier and display name, and then retires the previous managed
copy. It persists neither the original absolute path nor a path in debug state.
This avoids long-lived security-scoped-bookmark ownership while remaining
compatible with a future sandbox: the picker grants the one read needed to
copy into app-owned Application Support. Cancel, decode failure, or copy
failure leaves the prior request and managed image unchanged.

Image scaling is a persisted, live setting with exactly three cases. `Fill` is
the default and uses the larger proportional scale, centering and cropping the
overflow. `Fit` uses the smaller proportional scale, centers the result, and
fills uncovered letterbox bands with opaque black. `Stretch` maps the source to
the full terminal rectangle independently on each axis. Transparent pixels in
the source image composite over the same opaque black backing. Image decoding
is cached and never occurs in a renderer path or per-frame loop; selection,
scaling changes, and resize may invalidate the host once.

`System Blur` and the localized, theme-neutral `Frosted` preset are active work
in the same ExecPlan. `Frosted` is fixed at 30% terminal background opacity
with System Blur and opaque explicit cell backgrounds. Applying it preserves an
imported image and scaling mode for a later switch back to Image. Selecting
Image or changing an individual control produces custom preset state; Frosted
never combines System Blur and Image. It never changes the active theme and is
never selected from locale, language, region, input source, or CJK font. The
opaque sidebar remains outside every backdrop-backed content plane.

The effect host must use a public semantic behind-window AppKit material hosted
below terminal content. It must not put Liquid Glass behind terminal content,
use private Core Animation filters, capture the screen as a feedback loop,
implement blur in a renderer shader, or expose a configurable blur radius.
Public native material keeps blur and power behavior in AppKit/WindowServer,
adapts to system appearance and accessibility, and leaves all five renderer
contracts unchanged.

## Consequences

- The default request remains opacity `1.0`, explicit-cell opacity off, source
  `none`, no imported image, and an opaque sidebar, preserving existing opaque
  rendering and idle behavior in every locale and input configuration.
- Direct transparency can be implemented once in frame semantics and then
  proven equivalent across all five backends instead of becoming a Slug-only
  feature.
- Retained full frames, repeated damage, and scroll blits remain alpha-stable;
  repeated drawing cannot make a 70% background drift toward opaque.
- Nonopaque Vector and Slug frames retain one private `rgba16Float` working
  texture per final ring slot (8 additional bytes per pixel per slot) and add
  one full-surface resolve pass. Always-opaque activation, memory use, shader
  compilation, and frame encoding remain on the original direct path.
- Semantic foreground and application-selected background content remains
  legible by default. Users can separately opt explicit and inverse cell
  backgrounds into opacity.
- The sidebar remains one cohesive opaque navigation surface at every terminal
  opacity and backdrop setting; terminal-only opacity changes do not rebuild its
  memoized frame commands.
- Renderer switching, prewarming, resizing, view reconstruction, session
  selection, accessibility changes, and full-screen transitions must apply the
  current effective state before presentation without changing terminal session
  identity.
- Headless PNGs preserve alpha and use the same producers and backend contract,
  making alpha, override, and mixed-version behavior autonomously verifiable.
- Image backgrounds remain outside frame production. A private managed import
  survives relaunch without retaining an external path, and Fill, Fit, and
  Stretch can change live without changing terminal session identity.
- A settings or accessibility change may invalidate, wake, and present once;
  translucency does not create a periodic render source and preserves ADR
  0018/0026 idle and presenter invariants.

## Applies To New Code

- New terminal-content producers must receive background-compositing policy
  through their frame request. Sidebar/navigation producers remain opaque and
  must not consume terminal opacity. No producer reads `UserDefaults`, AppKit
  state, or renderer type.
- New renderers and renderer fast paths must support both replace and
  source-over semantics, full overwrite reset, partial transparent erasure,
  alpha-preserving scroll blits/readback, and live surface-opacity changes.
- Additions to snapshot transport must preserve explicit-background identity
  and negotiate writer capability; color equality is never a substitute.
- Any new RGB-subpixel path must resolve to grayscale when its destination is
  not known opaque.
- Any background source remains outside frame production and renderer code.
  New backdrop sources must not add renderer textures, renderer settings reads,
  or per-frame decoding. Changing the native-material constraints, managed-
  image ownership, scaling definitions, `Frosted` definition, or the direct-
  opacity exclusions requires an ADR amendment and corresponding product
  contract update.
