# Themes

Mortise has two built-in themes. Pick one in `_config.yml`:

```yaml
theme: visor   # or: lcars
```

The build then writes the theme's stylesheet to `/theme.css`, and
templates can read the name as `site.theme`. Link the stylesheet after
your own, so the theme wins:

```html
<link rel="stylesheet" href="{{ site.baseurl }}/css/site.css">
{% if site.theme %}<link rel="stylesheet" href="{{ site.baseurl }}/theme.css">{% endif %}
```

`mortise new` writes a layout that already does this. A site that has its
own `theme.css` keeps it; Mortise does not overwrite it, which is also the
quickest way to tweak a theme: copy it into the site and edit it while
`serve` swaps your changes in live. An unknown theme name fails the build
with the config line and the list of themes.

Themes are CSS plus a few images that Mortise's [renderer](rendering.md)
draws during the build, written to `/theme/`. They add no web fonts or
scripts, and every animation stops when the visitor asks for reduced
motion. A site's own file at a `/theme/` path replaces the rendered one;
the specs are in `src/themes/visor/` and `src/themes/lcars/`.

## visor

A helmet heads-up display, inspired by first-person sci-fi shooters.

- A dark gradient background with a soft cyan glow at the top, faint
  scanlines, and the curve of a visor at the edges.
- A sticky HUD bar: the site name with a blinking cursor, angled nav
  buttons, and a segmented shield meter along its bottom edge that charges
  as the page loads.
- Headings read like mission objectives: `OBJ-01 //` above each `h2`, and
  a diamond waypoint before each `h3` (not in API references or
  component titles).
- Cards and the contents box sit in a rendered HUD frame with chamfered
  corners; code blocks, callouts, and API operations are panels with
  corner brackets.
- The visitor's normal mouse pointer.

## lcars

A starship computer console, inspired by sci-fi television.

- A black field framed by an orange elbow that joins a segmented bar along
  the top to a segmented column down the left, with console numbers. A
  second elbow joins the column to the footer bar.
- A viewscreen in the column shows a rendered planet, and a rendered
  hologram turns in the bottom-right corner on wide windows.
- Nav links and buttons are rounded console pills in cycling colors; the
  current page is gold.
- `h1` and `h2` run into rounded color bars, and each `h2` gets a section
  code such as `01-A`.
- Code blocks, cards, callouts, code groups, tabs, and API operations sit
  in console frames. Table headers are colored blocks with rounded ends.
- The wiki sidebar becomes a stack of console buttons.
- A strip of blinking cells in the footer, as if the console were
  thinking.

## What themes style

Themes style HTML elements, Mortise's [components](components.md) and
[API pages](openapi.md), and these layout hooks, which the starter site
and the showcase use:

| Hook                       | Used for                                |
| -------------------------- | --------------------------------------- |
| `body > header`            | The site header                         |
| `header .brand`            | The site name in the header             |
| `header nav a`, `a.current`| Header links and the current page       |
| `body > main`              | Page content                            |
| `body > footer`            | The site footer                         |
| `.wiki-nav`, `.wiki-nav-title` | A sidebar of `site.nav` links       |
| `.toc-box`                 | A box holding `page.toc`                |
| `.breadcrumbs`, `.here`    | Breadcrumbs and the current page        |
| `.pager .prev`, `.next`    | Previous and next links                 |
| `.posts`, `.tag`, `.lead`, `.meta` | Post lists, tags, and intro text |

Anything else keeps the site's own styles. Theme rules start with
`:root body`, so they win over a site stylesheet's ordinary selectors.

## Design tokens

Every theme's colors are named design tokens, kept in
`src/themes/NAME/tokens.yml`. The build writes them at the top of
`/theme.css` (after any `@import`) as CSS custom properties named
`--m-NAME`, and the theme's rules use those properties, so changing a
token recolors the whole theme:

```yaml
theme: visor
theme_tokens:
  accent: "#ffb347"     # amber instead of cyan
  bg: "#05060a"
```

Every theme defines `bg`, `surface`, `text`, `muted`, `accent` and
`border`; `visor` adds `accent2`, `success`, `important` and `danger`, and
`lcars` its console palette (`peach`, `gold`, `lilac`, `violet`, `blue`,
`success`, `danger`). Your own CSS can use them too:
`color: var(--m-accent)`. New names in `theme_tokens` become new
properties.

### Light and dark

A token may hold a light and a dark color. With `scheme: both`, or when a
site sets `theme_tokens` without a theme, such pairs are written with
CSS `light-dark()`, and the page follows the reader's system setting:

```yaml
theme_tokens:
  bg: ["#ffffff", "#15161a"]
  text: ["#1d1d1f", "#e8e8ed"]
  accent: ["#0b57d0", "#8ab4f8"]
```

`{{ site.scheme_toggle }}` adds an Auto / Light / Dark switch for readers.
It works without JavaScript (the token CSS reacts to the checked button
through `:has()`); a few lines of script remember the choice between
pages. It is empty for single-scheme themes: `visor` and `lcars` are
`scheme: dark` only. The starter site from `mortise new` uses a light and
dark token set and shows the switch in its header.

### Contrast check

The build checks the resolved tokens against WCAG 2.2: `text` on `bg` and
on `surface`, and `muted` on `bg`, need 4.5:1; `accent` on `bg` needs 3:1
(links, large text and controls). Each pair is checked in every scheme in
use, and a pair that falls short is printed as a warning with the config
line, for example:

```
warning: _config.yml:3: low contrast: 'muted' on 'bg' is 1.32:1 in the dark scheme; WCAG asks for 4.5:1
```

Warnings do not stop the build.
