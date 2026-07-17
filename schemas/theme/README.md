# Laban Terminal Theme Files

A Laban theme file is a JSON document named `<theme-name>.laban-theme.json`. It
describes a complete 16-color ANSI palette plus the chrome colors that Laban
uses for sidebars, tabs, cursors, and selections.

## Schema

`laban-theme.schema.json` is the authoritative contract. The short version:

```json
{
  "version": 1,
  "name": "My Theme",
  "isDark": true,
  "colors": {
    "bg0": "#103C48FF",
    "bg1": "#174956FF",
    "bg2": "#2D5B69FF",
    "fg0": "#ADBCBCFF",
    "fg1": "#CAD8D9FF",
    "dim0": "#72898FFF",
    "red": "#FA5750FF",
    "blue": "#4695F7FF",
    "cursor": "#ADBCBCFF",
    "selectionBg": "#325B6680",
    "ansi16": [
      "#174956FF", "#FA5750FF", "#75B938FF", "#DBB32DFF",
      "#4695F7FF", "#F275BEFF", "#41C7B9FF", "#72898FFF",
      "#325B66FF", "#FF665CFF", "#84C747FF", "#EBC13DFF",
      "#58A3FFFF", "#FF84CDFF", "#53D6C7FF", "#CAD8D9FF"
    ]
  }
}
```

## Color format

Colors are hex strings. The leading `#` or `0x` is optional. Six-digit values
are treated as fully opaque; eight-digit values include alpha (`RRGGBBAA`).

## Chrome colors

- `bg0` — terminal canvas background.
- `bg1` — sidebar background.
- `bg2` — active-tab pill background.
- `fg0` — default chrome foreground.
- `fg1` — strong chrome foreground (active tab).
- `dim0` — secondary chrome foreground.
- `red` — status badge / error accent.
- `blue` — active-tab accent and link underline.
- `cursor` — terminal cursor color.
- `selectionBg` — selection background. May include alpha.

## ANSI palette

`ansi16` is the 16-color palette in OSC 4 order:

0–7: black, red, green, yellow, blue, magenta, cyan, white.  
8–15: bright equivalents.

## Examples

The `examples/` directory contains a JSON export of every bundled Laban theme.
Use them as starting points for your own themes.

## Importing

In Laban, open **Settings → Appearance** and click **Import Theme…**. The name
in the file must be unique and must not collide with a bundled theme name or
another imported theme. Imported themes are copied into Laban's private
`~/Library/Application Support/Laban/themes/` directory and persist across
launches.
