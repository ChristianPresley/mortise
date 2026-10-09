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
