# Search

Mortise can add full-text search to a site with no server and no
third-party service. Turn it on in `_config.yml`:

```yaml
search: true
```

and put the search button in a layout, usually in the header:

```html
<header>
  ...
  {{ site.search_box }}
</header>
```

The build then writes two files:

- `search-index.json`: an inverted index of every page.
- `search.js`: a small client (about 7 KB, 2.5 KB compressed) that loads
  the index the first time a reader searches and answers queries in the
  browser.

Readers open the search dialog with the button, **Ctrl+K** (**Cmd+K** on a
Mac) or **/**. Arrow keys move through the results, Enter opens one and
Escape closes the dialog. Without JavaScript the button stays hidden.

## What is indexed

Each page is split into sections: the text before its first `h2` or `h3`
heading, then each heading with an id and the text below it. Markdown
headings always have ids, so results link straight to the matching
section, as in `/docs/install/#requirements`, and show "Page › Heading" as
their title.

- Markdown pages index their rendered content. HTML template pages index
  the `<main>` element of their output, or the whole page when there is
  none.
- Navigation, headers, footers, scripts, styles, buttons and the page's
  `h1` (it repeats the title) are left out.
- Words in the page title and in headings count more than words in the
  text.
- Common English words (*the*, *and*, *of* ...) are not indexed.
- `search: false` in a page's frontmatter leaves the page out; the 404
  page is always left out.

## How queries work

A query is split into words. Every word must match (a section must contain
all of them), and each word matches as a prefix, so `inst` finds
*install* and *installer*. Exact words rank above longer ones that start
with them. Sections are ranked with BM25, which favors words that are rare
across the site and frequent in a short section. The first 12 results
are shown, with the query words highlighted.

## Styling

The dialog uses the [design tokens](themes.md#design-tokens) when the
site has them (`--m-surface`, `--m-text`, `--m-border`, `--m-accent`) and
the browser's own colors otherwise. Its parts have classes to style:
`.mt-search-button`, `dialog.mt-search`, `.mt-search input`,
`.mt-search li a` (`[aria-selected=true]` for the current result),
`.mt-search .t` (title), `.mt-search .e` (excerpt) and `mark`.

## Index format

```json
{"v": 1,
 "docs": [["Guide › Install", "/guide/#install", "Download the…", 42], ...],
 "terms": [["install", 0, 4, 7, 1], ...]}
```

`docs` lists every section as title, URL, excerpt and weighted length.
`terms` is sorted; each entry is a term followed by pairs of a section
number and the term's weighted count in it.
