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

On the development machine, keeping printable ASCII and a sentence of
accented text, arrows, quotes and ligatures shrank Arial from 1.0 MB to
395 KB, Segoe UI from 960 KB to 375 KB, Consolas from 453 KB to 118 KB,
and Georgia from 220 KB to 100 KB. Text drawn with each subset was pixel
for pixel the same as with the whole font.

## Formats

| Input              | Output                    |
| ------------------ | ------------------------- |
| `.ttf`, `.otf` with TrueType outlines | the same format |
| `.woff`            | `.woff`, tables compressed again |
| `.woff2`           | not supported; list the `.ttf` or `.woff` |
| CFF outlines (most `.otf`) | not supported      |

A listed file that is not part of the site, or a font that cannot be
subset, fails the build with the reason.
