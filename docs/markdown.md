# Mortise Markdown subset

Mortise renders a documented subset of [CommonMark](https://spec.commonmark.org/).
Within the subset, output follows CommonMark's rules and its reference HTML
renderer's formatting. Anything outside the subset is not an error: it
renders as literal, HTML-escaped text inside a paragraph.

The fixtures in `test/fixtures/markdown/` are the executable form of this
spec. Each `name.md` must render exactly to `name.html`.

## Input

- Lines end with `\n` or `\r\n`.
- Tabs in a line's leading whitespace count to the next multiple of four
  columns. Tabs elsewhere are kept as-is.
- Input is treated as bytes. UTF-8 passes through unchanged; Unicode
  whitespace and punctuation are treated as ordinary letters when deciding
  emphasis.

## Blocks

### Paragraphs

Consecutive non-blank lines form a paragraph. Leading whitespace on each
line and trailing whitespace on the last line are removed. Line breaks inside
a paragraph are kept as newlines (soft breaks). A blank line ends the
paragraph, as does any line that starts a heading, a fenced code block, a
block quote, a thematic break, or a list (see "Lists" for which list
markers may interrupt a paragraph).

### Headings

**ATX headings:** one to six `#` characters, indented by at most three
spaces, followed by a space, a tab, or the end of the line. An optional
closing run of `#` characters preceded by a space is removed. Heading text is
parsed for inlines.

```markdown
# Title
## Section ##
```

**Setext headings:** a paragraph followed by a line of only `=` (level 1)
or only `-` (level 2) characters, indented by at most three spaces. The
underline wins over a thematic break, so `---` under text makes a heading.

```markdown
Title
=====
```

### Thematic breaks

Three or more `-`, `*`, or `_` characters on a line of their own, optionally
separated by spaces and indented by at most three spaces, render as
`<hr />`. A thematic break takes precedence over a list item, so `- - -`
is a break.

### Block quotes

Lines starting with `>` (indented by at most three spaces, with one
optional space after the marker) form a block quote. The text after the
markers is parsed as blocks, so quotes can contain lists, code, and other
quotes. A line without `>` directly after paragraph text in a quote
continues that paragraph (lazy continuation).

### Fenced code blocks

A fence is three or more backticks or tildes, indented by at most three
spaces. The first word after the opening fence is the info string and becomes
`class="language-<word>"`; a backtick fence's info string may not contain
backticks. The block ends at a line holding a fence of the same character
that is at least as long as the opening one, or at the end of the document.
Each content line loses up to as many leading spaces as the opening fence had.
Content is HTML-escaped and never parsed for inlines.

When the info string names a supported language, tokens are wrapped in
`<span class="hl-...">` at build time, with the classes `hl-keyword`,
`hl-literal`, `hl-string`, `hl-number`, `hl-comment`, and `hl-builtin`.
Supported: `zig`, `c`/`h`/`cpp`/`c++`/`cc`, `rust`/`rs`, `go`,
`js`/`javascript`/`ts`/`typescript`/`jsx`/`tsx`, `python`/`py`,
`sh`/`bash`/`shell`/`zsh`, `json`, and `yaml`/`yml`. Mortise ships no
stylesheet; style the classes in your site's CSS. Other languages are
escaped without spans.

The rest of the info string after the language may hold options:
`title="file.zig"` (or single quotes), line ranges to mark such as
`{2,4-6}`, and `lineNumbers` (or `showLineNumbers`). With any option, or
with the language `diff`, the block is wrapped in a `mt-code` container
and each line in a `mt-line` span; see [components](components.md#code-block-options).
Unknown options are ignored.

A block whose language is `chart` is not code: it is drawn as a chart (see
[components](components.md#charts)).

````markdown
```zig
const x = 1;
```
````

### Code from files

A line holding `<<<`, a space and a file path (indented by at most three
spaces) becomes a fenced code block with the file's contents. The
language comes from the file's extension (`.zig`, `.rs`, `.py`, `.yml`, …).

```markdown
<<< _snippets/server.zig                 the whole file
<<< _snippets/server.zig:10-30           lines 10 to 30 (also :10, :10-)
<<< _snippets/server.zig#accept          a named region
<<< _snippets/server.zig#accept {2} title="server.zig" lineNumbers
```

- A path starting with `/` is relative to the site root; any other path is
  relative to the page's directory. It cannot lead outside the site.
  Keep snippets in an unpublished directory such as `_snippets/` unless
  you also want them copied into the output.
- A region runs from a line containing `#region NAME` to its matching
  `#endregion`, in any comment syntax (`// #region accept`,
  `# #region accept`, `<!-- #region accept -->`). Marker lines are left
  out, including those of nested regions, and so are all markers when
  including a whole file.
- The included lines lose their common indentation.
- Options after the path work as on a fence: `{lines}` to mark (counted
  within the included lines), `title="..."`, `lineNumbers`.
- A missing file, a line range past the end, or an unknown region stops the
  build with the page's file and line. The page is rebuilt when an included
  file changes.

### Lists

- **Bullet markers:** `-`, `+` or `*`.
- **Ordered markers:** one to nine digits followed by `.` or `)`. The first
  item's number becomes the `start` attribute when it is not 1.
- A marker is indented by at most three spaces and followed by at least one
  space, or by the end of the line for an empty item.
- An item's content begins at the first non-space character after the
  marker (if five or more spaces follow the marker, content begins one space
  after it). Following lines indented at least that far belong to the item
  and are parsed as blocks, so items can hold paragraphs, code blocks, and
  nested lists.
- A non-indented line directly after paragraph text in an item continues
  that paragraph (lazy continuation).
- Changing the bullet character or the ordered delimiter starts a new list.
- A list is **loose** when a blank line separates two items or two blocks
  inside one item. Loose items wrap their paragraphs in `<p>`; tight items
  do not.
- A list may interrupt a paragraph only if its first item is not empty and,
  when ordered, starts at 1.

### Tables

GitHub-style tables: a header row containing `|`, then a delimiter row of
`---` cells with the same number of cells, then body rows until a blank
line or another block. Leading and trailing pipes are optional, and `\|`
is a literal pipe inside a cell. Colons in the delimiter row set column
alignment (`:--` left, `:-:` center, `--:` right), written as an `align`
attribute. Short body rows are padded with empty cells and extra cells are
dropped. Cells are parsed for inlines.

```markdown
| Name | Count |
| :--- | ----: |
| a    |     1 |
```

## Inlines

### Emphasis

`*text*` and `_text_` render as `<em>`; `**text**` and `__text__` render as
`<strong>`. Matching follows CommonMark's delimiter-run rules, including
left/right flanking, the "multiple of three" rule, and the rule that `_`
does not create emphasis inside a word, so `snake_case_name` stays plain.

### Strikethrough

`~~text~~` or `~text~` renders as `<del>`. The opening and closing runs
must have the same length; runs of three or more tildes are literal text.

### Highlight

`==text==` renders as `<mark>`. Only runs of exactly two equals signs
count, and like emphasis they cannot open before a space or close after
one, so `a == b` and `===x===` stay literal.

### Inline code

A run of N backticks opens a code span that closes at the next run of
exactly N backticks. Newlines inside become spaces. If the content both
begins and ends with a space and is not all spaces, one space is removed
from each end. Content is HTML-escaped and never parsed further. An
unmatched backtick run is literal text.

### Links

Inline links only: `[text](destination)` or `[text](destination "title")`.

- The destination is either `<...>` (may contain spaces, no newlines) or a
  run of non-space characters with balanced parentheses.
- The title may be wrapped in `"..."`, `'...'` or `(...)`.
- Link text is parsed for inlines. Links may not contain other links: an
  inner link wins and the outer brackets are literal text.
- Spaces in the destination are written as `%20`; no other URL
  normalization is done.

### Wikilinks

`[[Name]]` links to another page of the site by name, written on one line
without brackets inside:

| Written                    | Links to                                          |
| -------------------------- | ------------------------------------------------- |
| `[[Getting Started]]`      | The page titled "Getting Started"                 |
| `[[install]]`              | The page whose file is `install.md` (or `install/index.md`) |
| `[[docs/install]]`         | The page at that path or URL, the most exact form |
| `[[Install#Linux]]`        | The `#linux` heading on that page                 |
| `[[#Usage]]`               | The `#usage` heading on this page                 |
| `[[Install\|the setup guide]]` | That page, with the label "the setup guide"   |

Titles and file names are compared as slugs, so case and punctuation do
not matter; a post's file name is matched without its date. Paths are
tried first. The link text is the name as written (`Install › Linux` for
a heading), or the label after `|`, which may hold inline Markdown.

The output is `<a class="wikilink" href="URL">`. A name that matches no
page becomes `<a class="wikilink wikilink-missing" title="No page named
...">` without an `href`, for a stylesheet to mark. A name that matches
more than one page fails the build, listing them, so the link never points
at the wrong one.

### Math

A fenced block with the language `math` holds TeX and is typeset as
display math. With `math: true` in `_config.yml`, so is `$$...$$`, and
`$...$` is inline math. A single `$` opens only before a non-space and
closes only after one, and not just before a digit, so `$5 or $10`
stays text; `\$` is always a dollar sign.

```markdown
The roots of $ax^2 + bx + c = 0$ are

$$
x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
$$
```

The build turns TeX into MathML, which browsers typeset themselves: no
scripts or web fonts. Each `<math>` element keeps the TeX as an
annotation. `mortise.css` gives math a font with a math table
(`font-family: math`), so large operators and brackets stretch.

The supported TeX covers:

| Kind          | Commands                                                         |
| ------------- | ---------------------------------------------------------------- |
| Structure     | `^`, `_`, `{...}`, `\frac`, `\dfrac`, `\tfrac`, `\binom`, `\sqrt`, `\sqrt[n]` |
| Letters       | Greek (`\alpha`... `\Omega`, `\varepsilon`...), `\infty`, `\partial`, `\nabla`, `\ell`, `\hbar`, `\emptyset` |
| Operators     | `\pm`, `\times`, `\cdot`, `\div`, `\cup`, `\cap`, `\wedge`, `\vee`, ... |
| Relations     | `\leq`, `\geq`, `\neq`, `\approx`, `\equiv`, `\sim`, `\in`, `\subset`, `\to`, `\Rightarrow`, `\iff`, ... |
| Big operators | `\sum`, `\prod`, `\int`, `\iint`, `\oint`, `\bigcup`, `\bigcap`, ... |
| Functions     | `\sin`, `\cos`, `\log`, `\ln`, `\exp`, `\lim`, `\max`, `\min`, `\det`, `\operatorname{...}`, ... |
| Text and fonts| `\text`, `\mathbf`, `\mathit`, `\mathrm`, `\mathbb`, `\mathcal`, `\mathfrak`, `\mathsf`, `\mathtt`, `\boldsymbol` |
| Accents       | `\hat`, `\bar`, `\overline`, `\vec`, `\tilde`, `\dot`, `\ddot`, `\underline`, ... |
| Fences        | `\left( ... \right)`, with `.`, `\{`, `\langle`, `\lfloor`, `\vert`, ... |
| Spacing       | `\,`, `\:`, `\;`, `\!`, `\quad`, `\qquad` |
| Environments  | `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`, `cases`, `aligned`, `array` |

Anything else, such as an unknown command or an unclosed brace, fails the
build with the file, the formula and the reason.

### Images

`![alt](source "title")` renders as `<img src="..." alt="..." />`. The alt
text is the plain text of the bracketed content, with emphasis markup
removed. Images may appear inside link text.

### Autolinks

`<https://example.com>` and any other `<scheme:...>` with a scheme of 2 to
32 letters, digits, `+`, `.`, or `-` renders as a link to itself.
`<name@example.com>` renders as a `mailto:` link. Anything else in angle
brackets is escaped text.

### Hard line breaks

A line inside a paragraph that ends with two or more spaces, or with a
backslash, is followed by `<br />`. Other line breaks are soft and kept as
newlines.

### Backslash escapes

A backslash before any ASCII punctuation character produces that character
literally and stops it from acting as markup. A backslash before anything
else is a literal backslash.

### HTML escaping

`&`, `<`, `>` and `"` are always escaped in text. Raw HTML is never passed
through.

## Not supported

These render as plain paragraph text:

- Indented code blocks (four-space indented lines become paragraph text).
- Raw HTML blocks and inline HTML, which are escaped instead.
- Reference-style links and link reference definitions.
- HTML entities and numeric character references (`&amp;` renders as
  `&amp;amp;`).
- Extensions other than tables, strikethrough, highlight, wikilinks, math, task lists, footnotes,
  definition lists, and the [components](components.md).
