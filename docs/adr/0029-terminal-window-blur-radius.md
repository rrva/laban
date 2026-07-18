# ADR 0029: Terminal Window Blur Uses a Configurable CGS Radius

Date: 2026-07-17

## Status

Accepted. Supplements and narrowly reverses the ADR 0028 prohibition on
private filters and configurable blur radius for the terminal window
background only. Implementation remains tracked in
`execplans/active/terminal-background-transparency.md`.

## Context

ADR 0028 shipped System Blur through one public
`NSVisualEffectView.material = .underWindowBackground` child behind terminal
content. Full-display measurements and user comparison with Terminal.app show
why that material cannot reproduce Terminal.app's Opacity 80% / Blur 20%
behavior: the material applies a strong fixed blur and its own
appearance-adaptive tint before Laban's themed canvas alpha is composited, so
recognizable wallpaper and window detail is flattened into a milky wash.
Lowering Laban's canvas opacity exposes more backdrop but also washes out the
theme; raising it hides the backdrop behind both the canvas and the material
tint.

Terminal.app's useful model is different: a mostly opaque themed canvas plus a
light, tint-free, radius-controlled blur behind the window. The public macOS
material and Liquid Glass APIs do not expose that radius control. The private
`CGSSetWindowBackgroundBlurRadius` entrypoint is the established non-App-Store
mechanism used by terminal emulators for this behavior. The user explicitly
accepted private API risk for this feature.

## Decision

System Blur primarily uses the private CGS window-background blur entrypoint,
resolved at runtime with `dlopen`/`dlsym`, and maps Laban's persisted unit
blur value directly to an integer radius from 0 through 100. The renderer does
not learn about blur; it continues to own only the themed terminal canvas
alpha through the ADR 0028 replace/source-over contract.

The Appearance settings expose a persisted Background blur slider. The
`Frosted` preset is exactly 80% terminal background opacity, 20% blur, System
Blur, and opaque explicit cell backgrounds. Custom slider values remain
literal, and changing either slider derives Custom.

Blur stays an AppKit/WindowServer concern. Laban does not capture the screen,
does not add a renderer blur pass, and does not put Liquid Glass behind
terminal content. The existing public `.underWindowBackground` material
remains only as a compatibility fallback when the private symbols or call are
unavailable; debug state distinguishes that fallback through the window-blur
availability/radius fields and the AppKit backdrop-child fields.

## Consequences

- The default request remains opacity 1, blur 0, source `none`, explicit-cell
  opacity off, and an opaque sidebar.
- Frosted now preserves recognizable background detail like Terminal.app
  instead of multiplying Laban's tint by the fixed material tint.
- The private API is unavailable to Mac App Store distribution and may change
  in a future macOS release. Failure resolves to the previous public material,
  never to a crash or silent unblurred fallback.
- Window-level blur is reset to radius 0 whenever None, Image, opacity 100%,
  Reduce Transparency, or native full screen is effective.
- `/debug/transparency`, headless action decoding, and `laban-agent` expose
  requested/effective blur so the behavior remains autonomously verifiable.
- Renderer, IME, explicit-cell, image, persistence, and idle contracts from
  ADR 0028 remain unchanged.

## Applies To New Code

- Do not add another blur implementation, radius mapping, screen-capture path,
  renderer shader, or per-frame backdrop update. Use the coordinator-owned
  window-blur controller.
- Do not statically link private CGS symbols; keep runtime resolution and the
  public-material fallback.
- New transparency diagnostics must preserve requested/effective blur and the
  private/fallback distinction.
- Changes to the Frosted values, blur-radius mapping, fallback policy, or
  Liquid Glass prohibition require an ADR amendment and product-contract
  update.
