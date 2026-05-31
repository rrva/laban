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

## JetBrains Mono

The bundled monospace font
([`Sources/LabanRenderer/Resources/JetBrainsMono-Regular.ttf`](Sources/LabanRenderer/Resources/JetBrainsMono-Regular.ttf)).

- **License:** SIL Open Font License 1.1
- **Full text:** [`Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt`](Sources/LabanRenderer/Resources/JetBrainsMono-OFL.txt)
