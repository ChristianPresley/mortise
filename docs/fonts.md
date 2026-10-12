# Font subsetting

A site that ships its own fonts can have `mortise build` shrink them to
the characters its pages use. List the font files in `_config.yml`:

```yaml
fonts:
  subset: [fonts/inter.woff, fonts/code.ttf]
  keep: "→€…"    # optional: characters to keep though no page uses them
```

`mortise build` collects every character in the text of the site's HTML
pages (not markup, scripts or styles), adds printable ASCII and `keep`,
and writes each listed font with only the glyphs for those characters.
The file keeps its name and format, so your `@font-face` rules need no
change. `mortise serve` serves the whole fonts, so text you are writing
never misses a glyph.

## What is kept

- The glyphs the kept characters map to, `.notdef`, and the parts of
  composite glyphs.
- Every glyph the font's substitutions can produce from those, so
  ligatures (`ffi`, `fl`), alternates and other `GSUB` features keep
  working.
- Kerning, positioning, hinting and metrics. Glyph ids do not change, so
  every table that refers to them stays valid.

The character map lists only the kept characters, unused glyphs have no
outline, glyph names are dropped (`post` format 3), and a digital
signature, which would no longer match, is removed.

In a font with CFF outlines (most `.otf` files), an unused glyph's
outline becomes `endchar`, which draws nothing, and subroutines no kept
glyph calls, local or global, become `return`. Mortise follows each kept
glyph's outline through the subroutines it calls, counting its stem hints
so hint masks are read correctly, and handles both name-keyed and
CID-keyed fonts (each of a CID font's font dictionaries has its own
subroutines). Subroutines keep their numbers, so the calls in kept
outlines need no change.

On the development machine, keeping printable ASCII and a sentence of
accented text, arrows, quotes and ligatures shrank Arial from 1.0 MB to
395 KB, Segoe UI from 960 KB to 375 KB, Consolas from 453 KB to 118 KB,
and Georgia from 220 KB to 100 KB. Text drawn with each subset was pixel
for pixel the same as with the whole font.

## Formats

| Input              | Output                    |
| ------------------ | ------------------------- |
| `.ttf`, `.otf` with TrueType or CFF outlines | the same format |
| `.woff`            | `.woff`, tables compressed again |
| `.woff2`           | not supported as input; list the `.ttf`, `.otf` or `.woff`, and set `woff2: true` for WOFF2 output |
| CFF2 outlines (variable `.otf`) | not supported |

A listed file that is not part of the site, or a font that cannot be
subset, fails the build with the reason.

## WOFF2

With `woff2: true`, `mortise build` also writes each subset font as WOFF2
beside it, `fonts/inter.ttf` as `fonts/inter.woff2`, compressed with
Mortise's own Brotli encoder:

```yaml
fonts:
  subset: [fonts/inter.ttf]
  woff2: true
```

List the WOFF2 file first in `@font-face`, and keep the original as the
fallback; `mortise serve` writes no WOFF2, so the browser uses the
original there:

```css
@font-face {
  font-family: Inter;
  src: url("/fonts/inter.woff2") format("woff2"), url("/fonts/inter.ttf");
}
```

On the development machine, with the same page text as above, the WOFF2
files came to 166 KB for Arial (397 KB subset, 1.0 MB whole), 59 KB for
Georgia (101 KB, 220 KB) and 52 KB for Consolas (120 KB, 453 KB), and
Edge drew them the same as the installed fonts. The three took 27 ms
with the subsetting in a release build.

TrueType outlines get WOFF2's `glyf` transform: each glyph is split into
streams of contour counts, point counts, flags, packed coordinate deltas,
composite records, boxes and instructions, which compress better than
the glyphs as written, and `loca` is left for the browser to rebuild. On
whole fonts the transform took Georgia's WOFF2 from 134 KB to 122 KB,
Arial's from 561 KB to 503 KB and Consolas's from 245 KB to 213 KB, and
every printable Latin character drawn in Edge was pixel for pixel the
same as with the TrueType file. A font with a glyph the transform cannot
read keeps its tables as they are.

The Brotli encoder finds repeats with hash chains, looks one byte ahead
before taking a match, reuses recent distances at no cost, and writes
blocks it cannot shrink as they are. Its output is about the size of the
reference encoder's default quality but larger than its best (Georgia
whole, without the transform: 131 KB against 118 KB); see
[limitations](limitations.md#fonts).
