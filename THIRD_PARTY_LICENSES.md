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
- **Pinned commit:** `46d54ed673a004df09078bee56e809421a82370e`
- **License:** MIT

Laban applies two small local patches to the pinned source before building.
Both live as reviewable diffs under [`patches/`](patches/) and are applied by
the fetch script:

- `libghostty-vt-0001-alt-screen-clear-uses-primary-pen.patch` — clears the
  alternate screen with the primary screen's pen (see
  [`docs/adr/0011-libghostty-alt-screen-clear-uses-primary-pen.md`](docs/adr/0011-libghostty-alt-screen-clear-uses-primary-pen.md)).
- `libghostty-vt-0002-stream-log-scope-and-mode-debug.patch` — renames the log
  scope and downgrades unimplemented-mode warnings to debug.

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

## Swift packages (Apache License 2.0)

`LabanApp` depends on
[swift-profile-recorder](https://github.com/apple/swift-profile-recorder),
which resolves the dependency graph below. All of these are statically linked
into the shipped binary, and all are licensed under the Apache License 2.0.
Several carry a `NOTICE.txt` whose attributions are incorporated here by
reference; each is reproduced verbatim in that package's checkout under
`.build/checkouts/<package>/`.

Exact resolved versions are pinned in [`Package.resolved`](Package.resolved).

| Package | Upstream |
| --- | --- |
| swift-algorithms | https://github.com/apple/swift-algorithms |
| swift-argument-parser | https://github.com/apple/swift-argument-parser |
| swift-asn1 | https://github.com/apple/swift-asn1 |
| swift-async-algorithms | https://github.com/apple/swift-async-algorithms |
| swift-atomics | https://github.com/apple/swift-atomics |
| swift-certificates | https://github.com/apple/swift-certificates |
| swift-collections | https://github.com/apple/swift-collections |
| swift-configuration | https://github.com/apple/swift-configuration |
| swift-crypto | https://github.com/apple/swift-crypto |
| swift-http-structured-headers | https://github.com/apple/swift-http-structured-headers |
| swift-http-types | https://github.com/apple/swift-http-types |
| swift-log | https://github.com/apple/swift-log |
| swift-nio | https://github.com/apple/swift-nio |
| swift-nio-extras | https://github.com/apple/swift-nio-extras |
| swift-nio-http2 | https://github.com/apple/swift-nio-http2 |
| swift-nio-ssl | https://github.com/apple/swift-nio-ssl |
| swift-numerics | https://github.com/apple/swift-numerics |
| swift-profile-recorder | https://github.com/apple/swift-profile-recorder |
| swift-protobuf | https://github.com/apple/swift-protobuf |
| swift-service-lifecycle | https://github.com/swift-server/swift-service-lifecycle |
| swift-system | https://github.com/apple/swift-system |

The Apache License 2.0 is reproduced in full in
[`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt).

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
