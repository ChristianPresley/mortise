---
title: Wiki
layout: doc
weight: 4
---
# Wiki elements

Elements that reference sites and wikis lean on, written in plain
Markdown. Wrap a phrase in double equals signs to ==highlight== it.

## Task lists

- [x] Markdown subset and fixtures
- [x] Live reload with an error overlay
- [x] Components and code groups
- [ ] Your next feature

## Footnotes

Mortise builds every page at once[^speed], and a save reaches the browser
in about 11 ms on Linux[^bench]. Footnotes are numbered in order of first
use, and each one links back to where it was cited[^speed].

## Definitions

Layout
: A template in `_layouts/` that wraps page content.

Include
: A partial template in `_includes/`, used with `{% include %}`.
: Includes see the variables of the template that uses them.

Front matter
: The settings between `---` lines at the top of a page.

[^speed]: Incremental rebuilds only render the pages a change affects.
[^bench]: Measured by `zig build bench` with 1,000 pages. See
    `bench/README.md` for every platform.
