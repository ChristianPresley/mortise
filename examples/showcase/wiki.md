---
title: Wiki
layout: doc
weight: 4
---
# Wiki elements

Elements that reference sites and wikis lean on, written in plain
Markdown. Wrap a phrase in double equals signs to ==highlight== it.

## Wikilinks

Link pages by name with double brackets: [[Install]] finds the page
titled Install, [[docs/configuration|the configuration page]] names one
by path, and [[Components#Callouts]] jumps to a heading. A name that
matches no page, such as [[Roadmap]], is marked instead of breaking.
Each page lists the pages that link to it under "Linked from".

## Task lists

- [x] Markdown subset and fixtures
- [x] Live reload with an error overlay
- [x] Components and code groups
- [ ] Your next feature

## Math

With `math: true` in `_config.yml`, TeX between dollar signs becomes
MathML the browser typesets itself: the roots of $ax^2 + bx + c = 0$ are

$$
x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}
$$

A `math` code block is always display math:

```math
\sum_{k=1}^{n} k = \frac{n(n+1)}{2} \qquad
|x| = \begin{cases} x & x \geq 0 \\ -x & x < 0 \end{cases} \qquad
\det \begin{pmatrix} a & b \\ c & d \end{pmatrix} = ad - bc
```

Prices such as $5 or $10 stay as they are.

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
