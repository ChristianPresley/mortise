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
paragraph, as does any line that starts a heading, a fenced code block, or a
list (see "Lists" for which list markers may interrupt a paragraph).

### Headings

ATX headings only: one to six `#` characters, indented by at most three
spaces, followed by a space, a tab, or the end of the line. An optional
closing run of `#` characters preceded by a space is removed. Heading text is
parsed for inlines.

```markdown
# Title
## Section ##
```

Setext headings (text underlined with `===` or `---`) are not supported.

### Fenced code blocks

A fence is three or more backticks or tildes, indented by at most three
spaces. The first word after the opening fence is the info string and becomes
`class="language-<word>"`; a backtick fence's info string may not contain
backticks. The block ends at a line holding a fence of the same character
that is at least as long as the opening one, or at the end of the document.
Each content line loses up to as many leading spaces as the opening fence had.
Content is HTML-escaped and never parsed for inlines.

````markdown
```zig
const x = 1;
```
````

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

## Inlines

### Emphasis

`*text*` and `_text_` render as `<em>`; `**text**` and `__text__` render as
`<strong>`. Matching follows CommonMark's delimiter-run rules, including
left/right flanking, the "multiple of three" rule, and the rule that `_`
does not create emphasis inside a word, so `snake_case_name` stays plain.

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

### Images

`![alt](source "title")` renders as `<img src="..." alt="..." />`. The alt
text is the plain text of the bracketed content, with emphasis markup
removed. Images may appear inside link text.

### Backslash escapes

A backslash before any ASCII punctuation character produces that character
literally and stops it from acting as markup. A backslash before anything
else is a literal backslash.

### HTML escaping

`&`, `<`, `>` and `"` are always escaped in text. Raw HTML is never passed
through.

## Not supported

These render as plain paragraph text:

- Block quotes (`>`), thematic breaks (`---`, `***`), setext headings.
- Indented code blocks (four-space indented lines become paragraph text).
- Raw HTML blocks and inline HTML, which are escaped instead.
- Reference-style links and link reference definitions, autolinks
  (`<https://...>`).
- HTML entities and numeric character references (`&amp;` renders as
  `&amp;amp;`).
- Hard line breaks (trailing two spaces or a trailing backslash).
- Tables, task lists, strikethrough, footnotes, and other extensions.
