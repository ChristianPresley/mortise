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

- A rendered starfield with a teal nebula, under a faint hexagon grid,
  scanlines, and the curve of a visor at the edges.
- A sticky HUD bar: the site name with a blinking cursor, angled nav
  buttons, and a segmented shield meter along its bottom edge that charges
  as the page loads.
- A rendered motion tracker in the bottom-right corner, with a sweep and
  blips, behind the content. It hides on narrower windows.
- Headings read like mission objectives: `OBJ-01 //` above each `h2`, and
  a diamond waypoint before each `h3` (not in API references or
  component titles).
- Cards and the contents box sit in a rendered HUD frame with chamfered
  corners; code blocks, callouts, and API operations are panels with
  corner brackets.
- A rendered targeting-reticle cursor that turns amber over links.

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
