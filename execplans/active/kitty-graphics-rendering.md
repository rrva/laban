# Render Kitty graphics protocol images

This ExecPlan is a living document maintained in accordance with `PLANS.md`
at the repository root. Keep `Progress` and `Validation and Acceptance`
current as work proceeds. A fresh contributor must be able to finish the work
from this file alone.

## Purpose / Big Picture

The Kitty graphics protocol lets a program running in a terminal show pixel
images inline: plots, file previews, diagrams, screenshots. The program sends
escape sequences that begin with `ESC _ G` (an "APC" sequence; APC stands for
Application Program Command). These carry image data or references plus
placement instructions ("show image 7 at the cursor, 20 columns by 10 rows,
behind the text"). Tools that use it include `kitten icat`, `timg`, `chafa`,
`yazi`, matplotlib's kitty backend, and agent multiplexers such as `herdr`,
which forward images from their panes to the host terminal.

Today Laban shows none of these images. Worse, it tells programs that it can:
Laban's terminal library answers the protocol's "do you support graphics?"
query with OK, so programs send images that never appear, with no fallback to
text art. Laban also reports `TERM_PROGRAM=ghostty` by default (see
`Sources/LabanCore/TerminalIdentitySettings.swift`). Many tools read that as
"Kitty graphics available" without asking.

After this plan:

- `printf` of a Kitty graphics sequence in a Laban tab shows the image at the
  cursor, in the default renderer (Slug Glyph) and every other selectable
  renderer. The image scrolls with its text, is cropped when partly off
  screen, respects the protocol's z-order (behind cell backgrounds, between
  backgrounds and text, or above text), and is removed when the program
  deletes it or the screen is cleared.
- Animated images play. Images placed with Unicode placeholders, the mode
  that makes images work inside tmux, render.
- The headless debug runtime renders the same images, so fixtures, screenshots
  and capture/replay can verify the behavior without a window.
- Until rendering lands, Laban stops claiming support it lacks (Milestone 0).

How to see it working at the end: run `scripts/kitty-graphics-demo` in a
Laban tab. It draws a red, green, blue and white 2×2 checker scaled to 8×4
cells, a PNG, a semi-transparent image behind text, and a short animation.
Compare with the screenshots stored under the artifacts named in
`Validation and Acceptance`.

## Progress

- [x] (2026-09-24) Milestone 0: stop answering Kitty graphics queries until
  rendering exists (storage limit 0 in `laban_session_create`), with
  `testKittyGraphicsQueryGetsNoReplyWhileRenderingIsDisabled`. All 207
  `LabanTerminalCoreTests` pass.
- [x] (2026-09-24) Milestone 1: terminal core, in
  `Sources/LabanTerminalCore/kitty_graphics.c`:
  - the gate (`laban_set_kitty_graphics_enabled`, else
    `LABAN_KITTY_GRAPHICS=1`; `laband` forces it off);
  - an ImageIO PNG decoder that returns straight alpha;
  - the medium policy (shared memory and temp files on, plain `file` off) and
    the 64 MB-per-screen limit;
  - sorted `LabanImagePlacement`s in `LabanSnapshot`;
  - `laban_session_kitty_image_copy`;
  - full damage whenever the visible placement signature differs from the
    last rendered one.

  `LabanKittyGraphicsTests` (9 tests) pass. A mutation that disables the
  damage marking makes the damage test fail. Full `swift test`: 3,322 passed.
  The 14 failures are exactly the ones that already fail on `main`.
- [x] (2026-09-24) Milestone 2:
  - `FrameCommand.texturedQuad` gained `layer` and `sourceRect`;
  - `FrameImageStore` (LabanRenderer) and `KittyImagePublisher` (LabanCore,
    run from `Session.snapshot()`) publish pixels;
  - `FrameProducer` emits each layer at its place in the command stream and
    in `overlayCommands`, clipped to the grid;
  - `SoftwareRenderer` draws the quads;
  - `/debug/render` has a `kittyGraphics` block;
  - captures save image pixels (`images/image-<id>.rgba`) and renderer replay
    loads them;
  - fixtures gained `terminal.kittyGraphics` and cell-based `is`/`not` pixel
    probes, which `laban-agent` enforces (exit 1 on failure);
  - `fixtures/kitty-graphics.fixture.json` passes, and fails all four image
    probes with the gate off.

  New tests: `KittyGraphicsFrameTests` (8), `SoftwareRendererImageTests` (3),
  `KittyGraphicsHeadlessTests` (2) and 2 `FixtureRunnerTests`. Full
  `swift test`: 3,340 passed; the same 14 failures that already fail on
  `main`.
- [x] (2026-09-24) Milestone 3: Metal renderers.
  - `KittyImageTextureCache` / `KittyImageQuad` (LabanRenderer) upload each
    image generation once per renderer and drop textures unused for 120
    frames.
  - `image_fragment` (Shaders.metal) and `vectorImageFragment`
    (VectorGlyphShaders.metal) sample with the uv clamped to the crop's
    whole-pixel bounds inset by half a texel.
  - `MetalRenderer` draws the images in the classic, gpuDriven-commands and
    gpuDriven-payload paths. Slug draws them on its opaque sRGB target and,
    through `SlugTranslucentPipelines.image`, on the translucent linear
    rgba16Float target.
  - The layers interleave with the background batches at a split index
    recorded where the first below-background quad appears.
  - `KittyImageParityTests` passes for software, classic, gpuDriven
    (commands and payload), Slug and translucent Slug, including a
    partial-damage repaint. Mutations (Slug without above-text images;
    classic without the split) fail it in every affected path.
  - `KittyGraphicsHeadlessTests.testMetalRenderersDrawTheFixtureImageWhereSoftwareDoes`
    drives the real FrameProducer path in the headless runtime. Disabling the
    Metal image path makes 1800/1800 image pixels differ for each renderer.
  - Full `swift test`: 3,343 passed; the same 14 failures that already fail
    on `main`.
- [ ] Milestone 4 (prototype first): animation playback and Unicode
  placeholders through a local libghostty-vt patch.
- [x] (2026-09-24) Milestone 5 (code and docs):
  - `KittyGraphicsSettings` (default on; `LabanKittyGraphicsEnabled` user
    default, with the `LABAN_KITTY_GRAPHICS` env override) is applied at
    startup by `AppDelegate`, `HeadlessDebugRuntime` and `laban-agent`;
    `laband` forces it off;
  - `scripts/kitty-graphics-demo` (checker, chunked 64x64 PNG from
    `fixtures/kitty-graphics/gradient-disc-64.png`, translucent z=-1 bar
    under text), whose output renders correctly in a headless run;
  - spec.md now describes the behavior; new ADR 0035 with an index line;
    ADR 0004 rule 2 is marked superseded;
  - agent-multiplexer plan M3/M4 are checked off;
  - `KittyGraphicsSettingsTests` (3). Full `swift test`: 3,348 passed; the
    same 14 failures that already fail on `main`.
- [ ] Milestone 5 (installed app): run `scripts/kitty-graphics-demo`,
  scroll/`clear`/delete, and show an image inside a herdr pane.
- [ ] Review Gate passed.

## Decision Log

- Decision: Laban's C terminal core owns all image state. Swift receives an
  owned list of visible placements with each snapshot, plus a separate call
  that copies one image's pixels on a renderer cache miss.
  Rationale: ADR 0004 forbids handing borrowed libghostty pointers to Swift.
  Copying every visible image's pixels into every snapshot would cost
  megabytes per frame. Placements are small; pixels change only when an
  image's generation changes (see Context), so a copy per generation suffices.
  Date/Author: 2026-09-24 / Claude.

- Decision: Reuse the existing `FrameCommand.texturedQuad` case, extended with
  a z-layer and a source rectangle, instead of adding a new command.
  Rationale: `texturedQuad` is already threaded through every renderer, the
  capture serializer, `RenderJournal` and `HeadlessDebugRuntime`, as a no-op.
  `docs/product/mvp.md` reserved it for exactly this purpose.
  Date/Author: 2026-09-24 / Claude.

- Decision: Enable the direct, shared-memory and temporary-file transmission
  mediums. Keep the plain `file` medium disabled.
  Rationale: The `file` medium lets whatever writes to the PTY make Laban read
  any local path it can read. That includes a remote host over SSH, or a
  malicious file being `cat`-ed. The image would then be displayed on screen.
  Shared memory and temp files need a program running locally as the same user
  to create the object; for temp files, upstream only accepts paths inside the
  temp directory and deletes the file after reading. Upstream Ghostty enables
  all four because it treats the PTY as trusted. Laban takes the conservative
  side, and this can be revisited with evidence of tools that need `file`.
  Date/Author: 2026-09-24 / Claude.

- Decision: Set the image storage limit to 64 MB per screen when enabled.
  Rationale: Each tab has a primary and an alternate screen, and users keep
  many tabs open. Upstream's app default of 320 MB per screen is sized for
  single-window use. Under the protocol, exceeding the limit evicts the oldest
  images, which degrades gracefully. The limit is a named constant so a later
  setting can expose it.
  Date/Author: 2026-09-24 / Claude.

- Decision: Get animation and Unicode placeholders from a local libghostty-vt
  patch (0004) that exposes upstream's existing Zig logic through two C
  functions, and offer the patch upstream.
  Rationale: As of pin `7c40388b` the public C API has no way to advance
  animation frames (`ImageStorage.animationTick` in
  `src/terminal/kitty/graphics_storage.zig:1057` is Zig-only). It also cannot
  resolve placeholder cells into placements
  (`src/terminal/kitty/graphics_unicode.zig:22` `placementIterator` is
  Zig-only). Re-implementing placeholder decoding in Laban would be a
  hand-written escape-protocol decoder, which ADR 0001 forbids, and it would
  drift from upstream. The patch regime (ADR 0011, `patches/`) already exists
  for this.
  Date/Author: 2026-09-24 / Claude.

- Decision: Tier 2 `laband` multi-client sessions do not show images in this
  plan. Their libghostty instance keeps the storage limit at 0.
  Rationale: Only Tier 2 ships snapshots across a process boundary, over the
  fixed-layout `LBNDSS01` shared-memory ring
  (`Sources/LabanCore/LabandSnapshotRingLayout.swift`), which has no room for
  images. The default GUI tab path parses in-process, including the `labpty`
  tier. Keeping Tier 2 at 0 keeps it honest, answering no queries. Extending
  the ring is a separate, ABI-versioned change under ADR 0006.
  Date/Author: 2026-09-24 / Claude.

- Decision: Pixels reach renderers through a process-wide
  `FrameImageStore` in LabanRenderer, keyed by `resourceId` = libghostty image
  generation, rather than through a new `RendererBackend` API.
  Rationale: LabanRenderer cannot depend on LabanCore, and generation stamps
  are unique across the whole process, so one store serves every session and
  renderer without collisions or protocol changes. `KittyImagePublisher`
  (one per `Session`, called from `Session.snapshot()`, the single snapshot
  funnel) copies each generation once. It retires ids unreferenced for 120
  snapshots and removes everything when the session closes.
  Date/Author: 2026-09-24 / Claude.

- Decision: Captures store each image's pixels once, as
  `images/image-<id>.rgba` (an 8-byte width/height header plus RGBA), and
  renderer replay loads them into the store.
  Rationale: Replay runs in a process that never held the images. Without the
  pixels, replayed image frames mismatch; `KittyGraphicsHeadlessTests` proves
  both directions.
  Date/Author: 2026-09-24 / Claude.

## Surprises & Discoveries

- Observation: `laban-agent` and `HeadlessDebugRuntime` created sessions
  without cell pixel sizes and never resized them, so image quads would have
  been silently skipped headless.
  Resolution: `laban_session_create` now forwards a supplied cell size to
  `ghostty_terminal_resize`, and both headless paths supply the font's cell
  size at creation. `testNoCellPixelGeometryMeansNoQuads` pins the skip
  behavior.

- Observation: Smooth scaling blends pixels from outside a source crop into
  the crop's edge. `SoftwareRendererImageTests.testSourceRectCropsTheImage`
  caught it.
  Resolution: the software renderer crops the CGImage to the whole-pixel
  bounds of the source rect, then maps any fractional remainder by clipping.
  Metal (Milestone 3) needs the same care: clamp sampling to the crop,
  inset by half a texel.

- Observation: Before Milestone 0, Laban acknowledged both graphics queries
  and transmits it never drew.
  Evidence: `testKittyGraphicsQueryGetsNoReplyWhileRenderingIsDisabled`
  failed before the fix with replies `ESC _Gi=31;OK ESC \` (to the `a=q`
  query) and `ESC _Gi=32;OK ESC \` (to an `a=T` transmit), and passes after.

- Observation: libghostty only knows the cell pixel size through
  `ghostty_terminal_resize`; `laban_session_create` does not pass it. Until
  the first resize, placements have no pixel size. Real tabs resize
  immediately. Tests call `laban_session_resize` after create.
  Evidence: `LabanKittyGraphicsTests.makeSession`.

- Observation: Damage uses the planned full-damage fallback. A 64-bit FNV-1a
  signature over the sorted, zero-padded placement records (geometry plus
  image generation) is compared against the last rendered signature, using
  the snapshot-observed / rendered-committed pattern that `snapshot.c`
  already uses for screen swaps and viewport scrolls. Row-precise image
  damage is left for Milestone 3, if profiling asks for it.

- Observation: Slug draws the cursor in the same batch as background
  solids, before any text, so an above-text image covers a cursor underneath
  it. `MetalRenderer` draws the cursor in a later pass and keeps it on top.
  The protocol moves the cursor past a placement by default (unless `C=1`),
  so this only shows when a program deliberately parks the cursor on an
  image. Recorded rather than fixed: moving Slug's cursor after text would
  change cursor appearance for every frame.

- Observation: In opaque mode Slug routes replace-compositing background
  rects into the source-over `solids` batch; only the translucent path uses
  `replaceSolids`. The below-background split therefore records both counts.

## Context and Orientation

Terms used below:

- **libghostty-vt**: the terminal state machine from the Ghostty project that
  Laban embeds (ADR 0001). `scripts/fetch-libghostty-vt` builds it from source
  at a pinned commit (currently `7c40388b`, ADR 0034) into
  `.external/libghostty-vt/`. Its C headers are in
  `.external/libghostty-vt/zig-out/include/ghostty/vt/`. Kitty graphics parsing,
  image storage, placement bookkeeping, eviction and protocol replies all
  happen inside it.
- **Image vs placement**: an *image* is pixel data with an id. A *placement*
  shows an image somewhere on the grid, at a size, with a crop, at a z-index.
  One image can have many placements.
- **z-index / layer**: placements with `z < INT32_MIN/2` draw below cell
  background colors. `z < 0` draws above backgrounds but below text. `z >= 0`
  draws above text. Upstream exposes these as `GHOSTTY_KITTY_PLACEMENT_LAYER_
  BELOW_BG`, `_BELOW_TEXT` and `_ABOVE_TEXT` (`kitty_graphics.h:278-281`).
- **Virtual placement / Unicode placeholder**: a placement with no grid
  position. The program instead prints the private-use character U+10EEEE in
  cells, with combining diacritics encoding the row and column, and the image
  id in the cell's foreground color. The terminal draws the matching slice of
  the image in each such cell. This survives tmux, because tmux just sees
  text.
- **Generation counters**: `GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION`
  (`kitty_graphics.h:166`) changes whenever anything in a terminal's image
  storage changes. `GHOSTTY_KITTY_IMAGE_DATA_GENERATION` changes whenever one
  image's pixels change, including each animation frame. Renderers key texture
  caches on (image id, image generation).
- **Snapshot**: `LabanSnapshot`
  (`Sources/LabanTerminalCore/include/LabanTerminalCore.h:90-171`) is the owned
  copy of visible terminal state that `laban_session_snapshot`
  (`Sources/LabanTerminalCore/snapshot.c:202`) produces for Swift. Swift never
  sees libghostty handles (ADR 0004).

How the pieces fit. For a normal tab, libghostty runs inside `LabanApp`, even
when the PTY lives in the `labpty` daemon (bytes come back over a byte ring;
see `Sources/LabanCore/Session.swift`). Each frame:

1. `laban_session_snapshot` updates libghostty's render state and copies rows,
   cells, dirty rows and hyperlinks into a `LabanSnapshot`.
2. `Sources/LabanCore/FrameProducer.swift` turns the snapshot into
   `[FrameCommand]`, or into a `TerminalCellPayload` on the GPU cell path.
   `Sources/LabanCore/TerminalSurfaceController.swift` (`makeFrame`,
   `damage(snapshot:)`) decides what changed.
3. A renderer backend draws. `RendererSelection`
   (`Sources/LabanRenderer/RendererSelection.swift`) picks one of:
   - `SlugGlyphRenderer` (default, ADR 0032);
   - `MetalRenderer` in `classic` or `gpuDriven` mode;
   - `SoftwareRenderer`, used by headless runs and by capture replay
     (`Sources/LabanDebug/CaptureReplayRunner.swift:403` replays through a
     fresh `SoftwareRenderer` and compares PNG hashes).

   `vectorGlyph` is retired (ADR 0033) and out of scope.

`FrameCommand.texturedQuad(rect:resourceId:source:)`
(`Sources/LabanRenderer/FrameCommand.swift:245`) and `FrameSource.image`
(line 76) exist, but every renderer ignores them:
`SoftwareRenderer.swift:120-123`, `MetalRenderer.swift:3765` and `:4036`,
`SlugGlyphRenderer.swift:2285`.

Draw order today, in both Metal renderers: clear/erase with the default
background, then explicit cell backgrounds (`replaceSolid`/`solid` pipelines),
then glyphs (`glyph`, then `colorGlyph`), then, in a separate pass after a
blit, the cursor (`MetalRenderer.swift:1378-1407`). `SlugGlyphRenderer.render`
(`SlugGlyphRenderer.swift:1395`) has the same shape. Images slot in as three
buckets:

- below-background: after the clear, before the explicit cell backgrounds;
- below-text: after the cell backgrounds, before the glyphs;
- above-text: after the glyphs, before the cursor pass.

ADR 0026 limits Metal renderers to one frame in flight. A texture referenced
by a submitted frame must not be destroyed until that frame's command buffer
completes; `docs/product/spec.md:139` states the same rule.

Session options are set in `laban_session_create`
(`Sources/LabanTerminalCore/session_lifecycle.c`, right after
`ghostty_terminal_new`, next to `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`).
The PNG decoder is different. `ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, ...)`
(`sys.h:165`) is process-global and must be installed once, before any
terminal decodes a PNG. The callback receives PNG bytes and a
`GhosttyAllocator`, and must return RGBA pixels allocated through that
allocator (`sys.h:106-155`).

Library defaults matter here (`src/terminal/Terminal.zig:296-305`). The
library build sets a 10 MB image storage limit, so Kitty graphics are **on**
unless the embedder sets the limit to 0. Laban installs the `WRITE_PTY`
callback, so query and "OK" replies reach programs. The file, temp-file and
shared-memory mediums default to off (`graphics_image.zig:100-103`). Without
a PNG decoder, PNG images (`f=100`) fail. Raw RGB/RGBA (`f=24`/`f=32`) are
accepted and stored, but never drawn.

A minimal test sequence used throughout this plan (a 2×2 RGB image; `f=24`
is RGB, `s`/`v` are pixel width and height, `a=T` means transmit and display,
`c`/`r` are the columns and rows to scale into, `q=2` suppresses replies):

    ESC _ G a=T,f=24,s=2,v=2,c=8,r=4,q=2 ; <base64 of FF0000 00FF00 0000FF FFFFFF> ESC \

The base64 of those 12 bytes is `/wAAAP8AAAD/////`. The query form is
`ESC _ G i=31,s=1,v=1,a=q,t=d,f=24 ; AAAA ESC \`. A terminal that supports
graphics replies `ESC _ G i=31 ; OK ESC \`.

## Plan of Work

### Milestone 0: stop claiming support

In `laban_session_create`, set `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`
to 0 (input type `uint64_t*`, `terminal.h:1350-1361`). A limit of 0 disables
the protocol entirely: no storage, no replies. Add
`testKittyGraphicsQueryGetsNoReplyWhileRenderingIsDisabled` to
`Tests/LabanTerminalCoreTests/LabanSessionTests.swift`. It writes the query
sequence above and asserts `drainResponse` is empty. Record, in Surprises,
that the test fails before the change (the reply is
`ESC _ G i=31;OK ESC \`) and passes after. This milestone ships on its own,
immediately.

### Milestone 1: terminal core

All C work is in `Sources/LabanTerminalCore`.

1. **Enablement gate.** Add `laban_kitty_graphics_enabled()` to
   `session_internal.h`. It returns true when the environment variable
   `LABAN_KITTY_GRAPHICS=1` is set or the Swift side has called the new
   `laban_set_kitty_graphics_enabled(bool)`. When enabled,
   `laban_session_create` sets:
   - the storage limit to `LABAN_KITTY_IMAGE_STORAGE_LIMIT` (64,000,000);
   - `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM` to true;
   - `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE` to the per-user temp
     directory from `confstr(_CS_DARWIN_USER_TEMP_DIR, ...)`.

   It leaves `..._MEDIUM_FILE` false. When disabled, the limit stays 0 from
   Milestone 0. The gate lets Milestones 1–4 land without user-visible change.
   Milestone 5 turns it on by default. Sessions created in Tier 2 `laband`
   always pass disabled.
2. **PNG decoder.** New file `kitty_png.c`. It installs, under `pthread_once`,
   a `GhosttySysDecodePngFn` that decodes with ImageIO
   (`CGImageSourceCreateWithData`, `CGImageSourceCreateImageAtIndex`). It
   draws into a `CGBitmapContext` with `kCGImageAlphaPremultipliedLast`,
   because CoreGraphics cannot draw into straight-alpha RGBA. It then converts
   in place to straight (non-premultiplied) alpha with
   `vImageUnpremultiplyData_RGBA8888`, since upstream stores straight RGBA, and
   copies the result into a buffer from the provided `GhosttyAllocator`. Reject images larger than 10,000×10,000
   pixels. Call the `pthread_once` from `laban_session_create` before the first
   terminal is created. Link `ImageIO`, `CoreGraphics` and `Accelerate` to
   `LabanTerminalCore` in `Package.swift`.
3. **Placements in the snapshot.** Add to `LabanSnapshot`:

       typedef struct {
           uint32_t image_id;
           uint32_t placement_id;
           uint64_t image_generation;   /* key for texture caches */
           int32_t  layer;              /* 1 below bg, 2 below text, 3 above text */
           int32_t  z;                  /* original z for stable ordering */
           int32_t  viewport_col, viewport_row; /* may be negative */
           uint32_t x_offset_px, y_offset_px;   /* offset within first cell */
           uint32_t pixel_width, pixel_height;  /* destination size */
           uint32_t source_x, source_y, source_width, source_height;
       } LabanImagePlacement;

       LabanImagePlacement *image_placements; /* owned, may be NULL */
       size_t image_placement_count;
       uint64_t kitty_graphics_generation;

   In `laban_session_snapshot`, after `ghostty_render_state_update`, and only
   when enabled:
   - get the handle with
     `ghostty_terminal_get(..., GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, ...)`;
   - read the storage generation;
   - iterate placements with a `GhosttyKittyGraphicsPlacementIterator` (reuse
     one per session, allocated at create and freed at destroy);
   - for each, call `ghostty_kitty_graphics_placement_render_info`
     (`kitty_graphics.h:462-487`, `:859-863`), skip `!viewport_visible`, and
     read the image generation from
     `ghostty_kitty_graphics_image` / `..._image_get`.

   Sort by (layer, z, image_id, placement_id) so every renderer draws in the
   same order. `laban_snapshot_destroy` frees the array.
4. **Damage.** Record the previous frame's storage generation and placement
   list in the session. If the generation changed, or any placement's viewport
   rectangle differs, mark every row that the old and new rectangles cover as
   dirty. A full-damage fallback is acceptable in the first cut. Scrolling
   already forces full damage (`snapshot.c:650-674`).
5. **Pixel copy.** Add
   `int laban_session_kitty_image_copy(LabanSession *s, uint32_t image_id,
   uint64_t expected_generation, LabanKittyImage *out)` and
   `void laban_kitty_image_free(LabanKittyImage *img)`.
   `LabanKittyImage` is `{ uint32_t width, height; uint64_t generation;
   uint8_t *rgba; }`, always straight-alpha RGBA8, converted from
   RGB/GRAY/GRAY_ALPHA as needed. The function takes the session lock, looks
   the image up and copies its pixels. It returns -1 if the image is gone or
   its generation differs from `expected_generation`; the caller then retries
   on the next frame. Pending images (`DATA_PTR` reported as
   `GHOSTTY_NO_VALUE`) also return -1.

Tests in `Tests/LabanTerminalCoreTests/LabanKittyGraphicsTests.swift`:

- the 2×2 RGB sequence yields one placement with layer 3, `grid 8×4`, and
  source rect `0,0,2,2`;
- `laban_session_kitty_image_copy` returns
  `FF0000FF 00FF00FF 0000FFFF FFFFFFFF`;
- a 1×1 PNG (`f=100`) decodes;
- `a=d` (delete) removes the placement;
- the query sequence replies `OK`;
- with the gate off, nothing is stored and nothing replies;
- scrolling 100 lines moves `viewport_row` by -100 or makes the placement
  invisible.

### Milestone 2: frame commands, software renderer, headless

1. Extend `FrameCommand.texturedQuad` to
   `texturedQuad(rect: CGRect, sourceRect: CGRect, resourceId: UInt64,
   layer: ImageLayer, source: FrameSource)`. Add
   `ImageLayer: UInt8 { belowBackground, belowText, aboveText }` in
   `FrameCommand.swift`. Update every `switch` that lists `.texturedQuad`
   (`grep -rn texturedQuad Sources`). Update `DebugFrameCommandSerializer`,
   `CaptureRecorder`, `RenderJournal` and
   `schemas/debug/frame-commands.schema.json` with the new fields.
2. New `Sources/LabanCore/KittyImageRegistry.swift`, one per session. It
   converts snapshot placements into `texturedQuad` commands, with points
   computed from the cell size and the offsets. `resourceId` is a stable
   64-bit hash of (session identity, image_id, image_generation). The registry
   exposes `pixels(for resourceId) -> KittyImagePixels?`, which calls
   `laban_session_kitty_image_copy` and keeps the last copy for each live
   resource. It drops entries no placement references for 120 consecutive
   frames. `FrameProducer` emits the commands in the command path.
   - **Cell payload path:** images are not cells. Emit them as the side-list
     of commands that the payload path already carries for overlays. Find the
     mechanism with `grep -n "overlay" Sources/LabanCore/FrameProducer.swift`
     and follow the find/selection overlay precedent; see
     `testCellPayloadModeKeepsFindOverlayOnPayloadPath`.
3. `SoftwareRenderer`: draw each quad with `CGContext.draw(CGImage)`, clipped
   to `rect` and cropped to `sourceRect`, into three buckets matching the Metal
   order above. Build the CGImage from registry pixels with straight alpha
   (`CGImageAlphaInfo.last`).
4. Headless parity. `HeadlessDebugRuntime` gets pixels through the same
   registry. Add a `kittyGraphics` object to the session debug state (and to
   `schemas/debug/session.schema.json`):

       { "enabled": bool, "storageGeneration": int, "placementCount": int,
         "visiblePlacementCount": int, "imageCount": int, "storedBytes": int }

   `storedBytes` is the sum of `GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN` over the
   images the visible placements reference. Upstream exposes no total-usage
   getter at this pin; the configured limit is reported separately as
   `storageLimitBytes`.
5. Fixture: extend `$defs.pixelProbe` in `schemas/fixture.schema.json` with an
   optional `is` (RGBA array) and `tolerance` (0–255). The existing `not` stays
   valid; exactly one of `is`/`not` is required. Teach `FixtureRunner`
   (`Sources/LabanCore`) to check `is`. Add
   `fixtures/kitty-graphics.fixture.json`. It writes the 2×2 image sequence,
   waits 2 frames, and probes the centre of each quadrant of the 8×4-cell
   rectangle for the red, green, blue and white colours (tolerance 8). It also
   probes one cell outside the image for "not red".

### Milestone 3: Metal renderers

1. New `Sources/LabanRenderer/KittyImageTextureCache.swift`. It maps
   `resourceId` to `MTLTexture` (`.rgba8Unorm`, straight alpha uploaded as-is).
   It uploads on miss from registry pixels via `MTLTexture.replace` with a
   shared staging copy. It retires textures unreferenced for 120 frames, and
   destroys them only in the completion handler of the command buffer that
   last referenced them (ADR 0026 one-frame-in-flight rule; spec.md:139).
   Uploads cost memory bandwidth, so do them before encoding and count them in
   `RenderJournal`.
2. A shared Metal function pair, `kittyImageVertex`/`kittyImageFragment`, in
   the renderers' existing `.metal` source. One instanced quad per placement
   samples the texture with the normalised source rect. It uses linear
   filtering, since scaled images should not look blocky, and outputs
   premultiplied source-over. Image pixels ignore terminal background opacity
   (ADR 0028): they are content, like glyphs.
3. `SlugGlyphRenderer.render` and `MetalRenderer.encodeContentPass` bucket
   `texturedQuad` by layer and draw each bucket at the insertion points listed
   in Context. On partial-damage frames, images intersecting damaged rows must
   be redrawn. Simplest correct rule: if any image intersects the damage,
   extend the damage to that image's rows.
4. Parity test `Tests/LabanRendererTests/KittyImageParityTests.swift`: render
   the fixture's frame through `software`, `classic`, `gpuDriven` (when
   `isAvailableOnCurrentOS`) and `slugGlyph`, then probe the same pixels. A
   second case puts text over a below-text image and asserts the glyph pixel
   differs from the image pixel. A third case puts an above-text image over
   text and asserts the image pixel wins.

### Milestone 4 (prototype, then promote): animation and placeholders

Prototype first, in the vendored checkout only. Write
`patches/libghostty-vt-0004-kitty-animation-and-placeholder-c-api.patch`
adding to `kitty_graphics.h`:

    /* Advance animations to now_ms (monotonic). Returns GHOSTTY_SUCCESS and
       sets *out_next_due_ms to the delay until the next frame, or
       GHOSTTY_NO_VALUE when nothing is animating. */
    GhosttyResult ghostty_terminal_kitty_animation_tick(
        GhosttyTerminal t, uint64_t now_ms, uint64_t *out_next_due_ms);

    /* Iterate placements resolved from Unicode placeholder cells in the
       current viewport; yields the same GhosttyKittyGraphicsPlacementRenderInfo
       plus image id, one entry per contiguous run. */
    GhosttyResult ghostty_kitty_graphics_placeholder_iterator_new(...);
    bool ghostty_kitty_graphics_placeholder_next(...);
    GhosttyResult ghostty_kitty_graphics_placeholder_render_info(...);

Implement them as thin wrappers over `ImageStorage.animationTick`
(`graphics_storage.zig:1057`) and `graphics_unicode.placementIterator`
(`graphics_unicode.zig:22`). Mirror how Ghostty's own renderer calls them
(`src/renderer/image.zig` `kittyUpdate`, `src/renderer/generic.zig:1420-1445`).

Promotion criteria: the C test harness shows
- a 2-frame animation (`a=f`, `a=a`) whose image generation changes after the
  tick at the frame gap and stops when the animation stops;
- a placeholder run printed as text that yields a render info covering those
  cells.

If either wrapper needs more than about 150 lines of Zig, or touches
non-kitty files beyond `lib_vt.zig` exports, stop. Record why in Surprises
and ask upstream for the API first. Ship Milestones 0–3 and 5 without
animation and placeholders; images then show their first frame and
placeholder cells show nothing.

Once promoted:
- add the patch to `PATCH_ORDER` in `scripts/fetch-libghostty-vt` and to the
  order check in `scripts/check-dependencies`, and document it in
  `THIRD_PARTY_LICENSES.md`;
- `laban_session_snapshot` calls the tick with `clock_gettime_nsec_np
  (CLOCK_UPTIME_RAW)/1e6`, appends placeholder placements, and exposes
  `next_animation_due_ms` in `LabanSnapshot`;
- `TerminalSurfaceController` schedules a wake at that time through the
  existing frame wake mechanism. Find it with
  `grep -n "FrameWakeSource" Sources`, and add a wake source
  `kittyAnimation`, so a parked display link (ADR 0026, the display-link
  full-park plan) wakes for the next frame and parks again when nothing
  animates;
- open an upstream Ghostty discussion or PR offering the two functions, and
  record the link here.

### Milestone 5: turn it on, document, verify in the app

1. Default the gate on. Keep `LabanKittyGraphicsEnabled` as a user default
   that can turn it off, read in `AppDelegate` and `HeadlessDebugRuntime`,
   with no settings UI in this plan.
2. `scripts/kitty-graphics-demo` (POSIX sh plus `base64`; no Python) prints:
   - the 2×2 checker;
   - a small checked-in PNG (`fixtures/kitty-graphics/laban-logo-64.png`);
   - a 50%-alpha image behind a line of text (`z=-1`);
   - a 3-frame animation;
   - a placeholder image if Milestone 4 shipped.
3. Docs:
   - `docs/product/spec.md:139` gains the concrete behavior: supported
     actions, the mediums policy, the 64 MB limit, layers, animation, and
     that Tier 2 is excluded.
   - New ADR `docs/adr/0035-kitty-graphics-rendering.md` records the core
     ownership, snapshot/pixel-copy split, `texturedQuad` reuse, medium
     policy and Tier 2 exclusion, with an index line in `docs/adr/README.md`.
   - ADR 0004's "Applies To New Code" rule 2 is annotated as superseded by
     ADR 0035.
   - `execplans/active/agent-multiplexer-terminal-capability-gaps.md` M4
     points here.
4. Build and install with `LABAN_WMO_PROFILE=1 ./scripts/install-app`, then
   restart with `scripts/restart-app --scroll-debug` (see
   `docs/process/agent-operating-guide.md`). Run the demo. Run herdr with an
   image-producing command inside a herdr pane and confirm the image appears.

## Concrete Steps

From the repository root:

    swift build --build-tests
    swift test --filter LabanKittyGraphicsTests
    swift test --filter LabanSessionTests
    swift test --filter KittyImageParityTests
    swift test --filter FixtureRunnerTests
    ./scripts/check-dependencies
    ./scripts/check
    LABAN_WMO_PROFILE=1 ./scripts/install-app && ./scripts/restart-app --scroll-debug

Headless fixture run, as in `scripts/smoke-runtime`:

    .build/debug/laban-agent --headless --fixture=fixtures/kitty-graphics.fixture.json \
      --artifacts=/tmp/kitty-fixture
    # expect exit 0 and /tmp/kitty-fixture/screenshot.png showing the checker

Update this section with real transcripts as milestones land.

## Validation and Acceptance

- Milestone 0: `testKittyGraphicsQueryGetsNoReplyWhileRenderingIsDisabled`
  fails before the change (reply `ESC _ G i=31;OK ESC \`) and passes after.
- Milestone 1: `LabanKittyGraphicsTests` pass. With the gate off, the whole
  existing `LabanSessionTests` suite passes unchanged.
- Milestone 2: `fixtures/kitty-graphics.fixture.json` passes in the headless
  runtime. Its capture replays with an identical PNG hash through
  `CaptureReplayRunner`.
- Milestone 3: `KittyImageParityTests` pass for every renderer available on
  the machine. A Slug screenshot of the fixture from `/debug/screenshot`
  matches the software one on all probes within tolerance 8.
- Milestone 4: animation and placeholder tests pass, or Surprises records why
  the prototype was not promoted.
- Milestone 5, in the installed app:
  - `scripts/kitty-graphics-demo` shows all images;
  - the checker scrolls away and back intact;
  - `clear` removes it;
  - `printf '\e_Ga=d\e\\'` deletes all images;
  - the animation plays and CPU returns to idle when it ends (check the
    display link parks in `GET /debug/state`);
  - an image shown inside a herdr pane appears.

  Screenshots from `/debug/screenshot` are saved under
  `~/Library/Logs/Laban/` and referenced here.

## Idempotence and Recovery

Every milestone is additive and gated until Milestone 5. To back out a
partial state, unset `LABAN_KITTY_GRAPHICS` and set
`LabanKittyGraphicsEnabled` to false. The storage limit then returns to 0 and
no image code runs. The patch in Milestone 4 is applied by
`scripts/fetch-libghostty-vt` like the others. Rerunning the script resets the
vendored checkout to the pin and reapplies all patches.

## Interfaces and Dependencies

- libghostty-vt `7c40388b` public Kitty graphics API (`kitty_graphics.h`),
  `GHOSTTY_SYS_OPT_DECODE_PNG` (`sys.h`), and patch 0004 if promoted.
- macOS ImageIO, CoreGraphics, Accelerate (`vImage`) for PNG decoding.
- New C surface in `LabanTerminalCore.h`: `LabanImagePlacement`, the three
  `LabanSnapshot` fields, `LabanKittyImage`, `laban_session_kitty_image_copy`,
  `laban_kitty_image_free`, `laban_set_kitty_graphics_enabled`, and after
  Milestone 4 `next_animation_due_ms`.
- New Swift: `ImageLayer`, the extended `FrameCommand.texturedQuad`,
  `KittyImageRegistry` (LabanCore), `KittyImageTextureCache` (LabanRenderer).

## Review Gate

A fresh agent performs these checks after Milestone 5 (see `PLANS.md`,
"Review gate and review-fix loop").

- [ ] Run `swift test --filter LabanKittyGraphicsTests`,
  `swift test --filter KittyImageParityTests` and
  `swift test --filter LabanSessionTests`; expect 0 failures in each.
- [ ] Run `grep -rn "GhosttyKittyGraphics\|ghostty_kitty_graphics" Sources |
  grep -v "Sources/LabanTerminalCore/"`; expect zero hits (ADR 0004: only the
  C core touches libghostty handles).
- [ ] Run `grep -n "KITTY_IMAGE_MEDIUM_FILE" Sources/LabanTerminalCore/*.c`;
  expect every hit to set the value to false.
- [ ] Run `grep -rn "case .texturedQuad" Sources/LabanRenderer | grep -v
  VectorGlyphRenderer.swift`; expect no hit whose body is only `break`.
  `VectorGlyphRenderer` is retired (ADR 0033) and not selectable, so it is
  excluded: also run `grep -n 'filter { $0 != .vectorGlyph }'
  Sources/LabanRenderer/RendererSelection.swift` and expect exactly one hit
  (`selectableCases` leaves it out).
- [ ] Run the headless fixture command in Concrete Steps; expect exit 0.
  Then copy `fixtures/kitty-graphics.fixture.json` to a temporary file with
  `"kittyGraphics": false` and run the same command on the copy; expect exit
  1 with four `pixel probe failed` lines (the image is absent). The fixture's
  `terminal.kittyGraphics` overrides the user default, so the user default
  cannot serve as this control.
- [ ] Run `./scripts/check-dependencies`; expect `check-dependencies passed`.
- [ ] Open `docs/adr/0035-kitty-graphics-rendering.md`; expect sections
  Status, Context, Decision, Consequences, Applies To New Code, and an index
  line for it in `docs/adr/README.md`.

Review status: NOT REVIEWED (re-review pending after review 1)

Review 1 (FAILED 2026-09-24T22:03Z at 2bfe2b8a). Findings (filled in by the
review agent):

- PASS tests: `swift test --skip-build --filter` each exit 0; LabanKittyGraphicsTests
  9 tests, KittyImageParityTests 2 tests, LabanSessionTests 113 tests, 0 failures.
- PASS ADR 0004 grep: zero hits outside `Sources/LabanTerminalCore/`.
- PASS file medium: single hit `Sources/LabanTerminalCore/kitty_graphics.c:141`,
  set from `bool file_medium = false;` (line 139).
- FAIL texturedQuad: `Sources/LabanRenderer/VectorGlyphRenderer.swift:1501` is
  `case .texturedQuad, .waveRegion:` followed only by `break`. The other hits
  (MetalRenderer.swift:3017/3874/4150, SlugGlyphRenderer.swift:2355,
  SoftwareRenderer.swift:121) draw the image. Plan line 310 calls `vectorGlyph`
  retired (ADR 0033) and out of scope, but the gate item has no exclusion. Fix
  it by drawing images there, or by rewording the gate item to exclude
  VectorGlyphRenderer explicitly and giving the reason.
- PASS fixture: the committed fixture exits 0. The copy with
  `"kittyGraphics": false` exits 1 with exactly 4 `pixel probe failed` lines
  (cells [2,1] [6,1] [2,3] [6,3] got 103C48FF).
- PASS `./scripts/check-dependencies` printed `check-dependencies passed`.
- PASS ADR: 0035 has Status, Context, Decision, Consequences, and Applies To New
  Code; it is indexed at `docs/adr/README.md:43`.
