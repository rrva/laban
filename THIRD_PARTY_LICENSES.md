# Third-Party Licenses

Laban is MIT licensed (see [`LICENSE`](LICENSE)). The distributed application
links and bundles the third-party components listed below. Their license
notices are reproduced here in full, as their licenses require.

---

## libghostty-vt (Ghostty)

The terminal VT parsing core. Fetched and built from source at build time by
[`scripts/fetch-libghostty-vt`](scripts/fetch-libghostty-vt) into
`.external/libghostty-vt/` (not vendored into this repository), then statically
linked into the shipped binary.

- **Upstream:** https://github.com/ghostty-org/ghostty
- **Pinned commit:** `7c40388b2c63b7dcc5d6c9b9804e40fb2574444f`
- **License:** MIT

Laban applies three small local patches to the pinned source before building.
All three live as reviewable diffs under [`patches/`](patches/) and are applied by
the fetch script:

- `libghostty-vt-0001-alt-screen-clear-uses-primary-pen.patch` — clears the
  alternate screen with the primary screen's pen (see
  [`docs/adr/0011-libghostty-alt-screen-clear-uses-primary-pen.md`](docs/adr/0011-libghostty-alt-screen-clear-uses-primary-pen.md)).
- `libghostty-vt-0002-stream-log-scope-and-mode-debug.patch` — renames the log
  scope and downgrades unimplemented-mode warnings to debug.
- `libghostty-vt-0003-decxcpr-cursor-position-report.patch` — answers DECXCPR
  (`CSI ? 6 n`) with the DEC-private `CSI ? row ; col R` form (see
  [`docs/adr/0019-libghostty-answers-decxcpr.md`](docs/adr/0019-libghostty-answers-decxcpr.md)).

```
MIT License

Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Sparkle

In-app updates. The only SwiftPM dependency; `Sparkle.framework` is embedded
in the app bundle.

- **Upstream:** https://github.com/sparkle-project/Sparkle
- **Version:** pinned in [`Package.resolved`](Package.resolved)
- **License:** MIT, with the notices of the components Sparkle bundles
  (bsdiff, sais, ed25519 and others), reproduced in full in
  [`licenses/Sparkle-LICENSE.txt`](licenses/Sparkle-LICENSE.txt).

---

## Theme presets

The bundled theme presets under
[`Sources/LabanApp/Resources/ThemeExamples/`](Sources/LabanApp/Resources/ThemeExamples/)
adapt color palettes originated by other projects. Only the color values are
reused; no upstream code is included, and each preset is an independent
reimplementation in Laban's own theme format.

| Preset | Origin | License |
| --- | --- | --- |
| Selenized Light / Dark (Selenized Light is Laban's default) | Jan Warchoł, [`jan-warchol/selenized`](https://github.com/jan-warchol/selenized) | MIT |
| Rosé Pine, Rosé Pine Dawn | [`rose-pine/palette`](https://github.com/rose-pine/palette) | MIT |
| Catppuccin Latte / Mocha | [`catppuccin/catppuccin`](https://github.com/catppuccin/catppuccin) (© 2021 Catppuccin) | MIT |
| Dracula | [`dracula/dracula-theme`](https://github.com/dracula/dracula-theme) (© Dracula Theme) | MIT |
| Nord | [`nordtheme/nord`](https://github.com/nordtheme/nord) (© 2016-present Sven Greb) | MIT |
| Tokyo Night Storm | [`enkia/tokyo-night-vscode-theme`](https://github.com/enkia/tokyo-night-vscode-theme) | MIT |
| Gruvbox Dark | [`morhetz/gruvbox`](https://github.com/morhetz/gruvbox) | MIT/X11, per its README; the repository ships no `LICENSE` file |

`Terminal Basic` is Laban's own preset and is covered by Laban's MIT license.

---

## JetBrains Mono

The bundled monospace font
([`Sources/LabanRenderer/Resources/JetBrainsMono-Regular.ttf`](Sources/LabanRenderer/Resources/JetBrainsMono-Regular.ttf)).

- **License:** SIL Open Font License 1.1
- **Full text:** [`Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt`](Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt)

---

## Acknowledgements

Credits that carry no license obligation:

- **Slug** — the Slug Glyph renderer implements Eric Lengyel's Slug algorithm
  ("GPU-Centered Font Rendering Directly from Glyph Outlines", *Journal of
  Computer Graphics Techniques*, 2017). Laban's implementation is its own; the
  algorithm's patent was dedicated to the public domain (see
  `docs/adr/0027-slug-glyph-renderer.md`).
