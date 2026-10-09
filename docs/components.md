# Components

Mortise turns a few extra Markdown forms into styled components. They are
plain HTML with `mt-` classes and need no JavaScript. Their styles live in
`mortise.css`, which every build writes to the site root when at least one
page uses a component. Link it from your layout:

```html
<link rel="stylesheet" href="{{ site.baseurl }}/mortise.css">
```

Set `components_css: false` in `_config.yml` to skip the file and style the
classes yourself, or put your own `mortise.css` in the site, which takes
precedence. The showcase site's [components page](../examples/showcase/components.md)
uses every component.

## Callouts

GitHub's alert syntax: a block quote whose first line is a marker.

```markdown
> [!NOTE]
> Useful information.
```

Markers: `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`
(any case). Output: `<div class="mt-callout mt-callout-note">` with a
`<p class="mt-callout-title">` and the content. Any other marker leaves the
block quote as it is.

## Containers

A container starts with three or more colons and a name, optionally
followed by a title, and ends at a line of at least as many colons. Its
content is Markdown. Nest containers by giving the outer one more colons.

| Container                | Renders as                                         |
| ------------------------ | -------------------------------------------------- |
| `:::card Title`          | A bordered card; the title is optional             |
| `::::grid`               | A responsive grid, usually holding `:::card`s      |
| `:::details Summary`     | A `<details>` disclosure with that summary         |
| `:::figure Caption`      | A `<figure>` with the content and a `<figcaption>` |
| `:::actions`             | Its links as buttons; the first is the primary one |
| `:::steps`               | Its ordered list as numbered steps                 |

```markdown
::::grid
:::card Fast
Incremental rebuilds.
:::
:::card Portable
Linux, macOS, and Windows.
:::
::::

:::actions
[Get started](/docs/) [Read more](/about/)
:::
```

Unknown names (`:::foo`) are not containers and stay paragraph text.

## Tabs and code groups

Tabs work without JavaScript: each tab is a radio button and its label,
and CSS shows the selected panel. A group holds up to 8 tabs.

```markdown
::::tabs
:::tab Overview
Any Markdown.
:::
:::tab Install
1. Install Zig.
:::
::::
```

`:::code-group` turns the code blocks inside it into tabs, labeled by each
block's `title` or else its language:

````markdown
:::code-group
```sh title="macOS"
brew install zig
```
```sh title="Windows"
winget install zig.zig
```
:::
````

Inside `:::tabs`, anything that is not a `:::tab` is left out.

## Code block options

After the language, a fence takes options (see the
[Markdown spec](markdown.md#fenced-code-blocks)):

````markdown
```zig title="src/main.zig" {4-5} lineNumbers
...
```
````

| Option        | Effect                                                   |
| ------------- | -------------------------------------------------------- |
| `title="..."` | A file-name bar above the code                           |
| `{2,4-6}`     | Marks those lines (1-based, inclusive ranges)            |
| `lineNumbers` | Numbers every line (CSS counters, so copying skips them) |

The language `diff` colors lines starting with `+`, `-`, and `@@`. Code
with options is wrapped in `<div class="mt-code">`, and each line is a
`<span class="mt-line">` with `mt-line-marked`, `mt-line-add`,
`mt-line-del`, or `mt-line-hunk` as needed.

## Inline components

| Syntax         | Renders as                                   |
| -------------- | -------------------------------------------- |
| `:badge[New]`  | `<span class="mt-badge">New</span>`          |
| `:kbd[Ctrl]`   | `<kbd class="mt-kbd">Ctrl</kbd>`             |

The text is escaped and may not contain `]`.

## Theming

`mortise.css` mixes its neutral colors from the surrounding text color, so
components fit light and dark sites as they are. Override these variables
in your stylesheet to change the rest:

| Variable          | Used for                              |
| ----------------- | ------------------------------------- |
| `--mt-accent`     | Primary button, steps, badges         |
| `--mt-accent-text`| Text on the accent color              |
| `--mt-radius`     | Corner radius                         |
| `--mt-note`, `--mt-tip`, `--mt-important`, `--mt-warning`, `--mt-caution` | Callout colors |
