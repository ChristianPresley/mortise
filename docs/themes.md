# Themes

Mortise has nine built-in themes. Pick one in `_config.yml`:

```yaml
theme: visor   # or: lcars, phosphor, cyberdeck, freighter, grid, codex, cockpit, scanvisor
```

To see them all, build the [theme gallery](#theme-gallery).

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

Themes are CSS, sometimes with a few images that Mortise's
[renderer](rendering.md) draws during the build, written to `/theme/`.
They add no web fonts or scripts; each names a stack of fonts common on
Windows, macOS and Linux and falls back to the system's. Every animation
stops when the visitor asks for reduced motion. A site's own file at a
`/theme/` path replaces the rendered one; the specs are in
`src/themes/visor/` and `src/themes/lcars/`.

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

## phosphor

A monochrome CRT terminal.

- Every element in one monospace face, glowing green on a dark tube, with
  scanlines, a slow refresh band, and darkened, curved corners.
- The header reads like a prompt (`user@Site:~$`) and nav links like
  paths (`./docs`); the current one is shown in inverse video.
- Headings keep the text size and are marked with `##` and `###`; `h1`
  types itself out and ends in a blinking block cursor.
- Boxes are text-mode frames, lists use `*`, rules are rows of dashes,
  quotes start with `>`, and syntax colors become brightness and style.
- Retint it with the `text`, `muted` and `accent` tokens: amber
  (`#ffb000`) and white (`#e8e8e8`) monitors work as well as green.

## cyberdeck

A hacker's deck in a neon city.

- Magenta and cyan light on a violet-black field crossed by faint
  diagonal lines, with a yellow accent strip under the header.
- Nav links are notched tabs; hovering one, or a button, glitches it.
- `h1` arrives with a short glitch and split color edges; each `h2` gets a
  hex section code (`0x01`) and a magenta-to-cyan underline.
- Panels have two corners cut off and a gradient neon edge. Tags, badges
  and buttons share the notch.

## freighter

The mainframe terminal of an old commercial hauler.

- Uppercase, widely tracked monospace on a graph-paper screen, with
  scanlines and a hazard-striped strip above the header.
- The ship's name is an inverse-video plate followed by blinking status
  lights.
- `h1` carries an `INTERFACE //` label; `h2` headings are inverse-video
  labels.
- Boxes are thick ruled frames with a hard shadow; warnings and cautions
  get a hazard-striped edge. Amber marks numbers, quotes and alerts.

## grid

The inside of a computer world, drawn in light.

- A glowing floor grid in perspective runs to a horizon at the bottom of
  the window and slowly scrolls towards the reader.
- Thin, widely tracked uppercase headings; a light trail draws itself
  under `h1`.
- Panels, tables, buttons and nav links are rounded and traced in cyan
  light; orange marks tags, `h3` headings, numbers and highlights.

## codex

The encyclopedia of a starship's computer.

- Holographic blue on deep navy over a faint hexagon lattice, with thin
  headings that resolve into place.
- Rules end in glowing nodes; each `h2` sits on one.
- Entry panels have a cut top-left corner and a lit top edge. Orange
  marks the current page, buttons and quotes.
- The wiki sidebar reads as the codex index.

## cockpit

The flight deck of a trading ship.

- Orange vector light on black, framed by canopy struts in the top
  corners (on windows wider than 900 pixels) and the edge of the dash
  along the bottom.
- Extended uppercase readouts; `h1` flickers on like a powering display,
  and each `h2` runs into a fading line.
- Console panels with an orange top edge and bevelled lower corners;
  ice blue for links and quotes.

## scanvisor

A bounty hunter's helmet visor in scan mode.

- An orange frame curves around the edges of the window like the rim of the
  visor, with a faint reflection on the glass.
- The site name is an energy readout (`ENERGY 99`) with a row of reserve
  tanks; nav links are rounded visor-mode buttons, the current one lit
  orange.
- `h1` locks on with a targeting reticle; each `h2` reads `SCAN ▸`.
- Callouts are scan-data panels: striped glass, a `SCAN DATA` label, and a
  scan line that sweeps down them.
- Steps are energy tanks, and `<progress>` bars are segmented energy
  meters.
- Panels are visor glass with orange corner nubs; teal marks data and orange
  marks what can be used.

## Theme gallery

`zig build theme-gallery` builds the showcase with every built-in theme
into `zig-out/theme-gallery/NAME/` and writes an index that previews them
side by side, with links to each theme's pages. Each copy is built under
the base URL `/NAME`, so serve the folder as a site root:

```sh
zig build theme-gallery
zig-out/bin/mortise serve zig-out/theme-gallery
```

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
`success`, `danger`). Of the others, `cyberdeck`, `freighter`, `grid`, `codex`,
`cockpit` and `scanvisor` use `accent2` for their second color, `cyberdeck` adds
`warning` and `success`, and `phosphor`, `freighter`, `cyberdeck`, `cockpit` and
`scanvisor` add `danger`. Your own CSS can use them too:
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

## Theme layouts

Built-in themes come with layouts and includes, so a site can be only
content and a `theme:` line:

```yaml
# _config.yml
title: Field Notes
theme: visor
```

```markdown
---
layout: post
title: First light
---
```

| Layout     | Use                                                        |
| ---------- | ---------------------------------------------------------- |
| `default`  | The page frame: head, header with `site.nav`, `{{ content }}`, footer |
| `page`     | `default` with the page title as a heading                 |
| `post`     | `default` with title, date, tags and previous/next links   |
| `home`     | `default` with the site title, description and every post  |

The includes are `head.html` (stylesheets and feed link), `header.html`
(site name, navigation, and `site.scheme_toggle`) and `footer.html`. A
site's own file with the same path, such as `_includes/footer.html` or
`_layouts/post.html`, replaces the theme's file and nothing else, so a site
can change one piece and keep the rest. The layouts follow the hooks below,
and a small base stylesheet (every rule inside `:where()`, so a site's own
CSS always wins) lays the page out.

## Site themes

A site can define its own theme in `_themes/NAME/` and pick it with
`theme: NAME`:

```
_themes/night/
  theme.yml        base: visor
  theme.css        rules added after the base theme's stylesheet
  tokens.yml       tokens that replace or add to the base's
  _layouts/...     layouts that replace the base's, one file at a time
  _includes/...
```

`base` names the theme this one builds on: a built-in theme or another
site theme, up to eight deep. The result is the base's stylesheet followed
by the new one (with every `@import` moved to the top), the base's tokens
with the new ones applied, the base's rendered images, and the base's
layouts and includes except those the new theme has. A site theme named
like a built-in one (`_themes/visor/`) takes its place. The site's own
`_layouts/` and `_includes/` still win over every theme, and
`theme_tokens:` in `_config.yml` still applies last.

Edits under `_themes/` rebuild the whole site.
