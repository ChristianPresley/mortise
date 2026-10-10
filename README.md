# mortise

Mortise is a static site generator written in pure Zig 0.16 with zero
third-party dependencies. Build Markdown and templates into plain HTML, with a
dev server that reloads your browser when you save. A simple alternative to
Jekyll and Hugo.

## Requirements

- Zig **0.16.0** exactly (pinned in `build.zig.zon`, enforced by `build.zig`,
  and used by CI). Get it from <https://ziglang.org/download/>.
- Nothing else. Mortise has no third-party dependencies.

## Build and test

```sh
zig build                         # builds zig-out/bin/mortise
zig build test                    # unit, fixture, and end-to-end tests
zig build -Doptimize=ReleaseFast  # optimized binary
zig build render-gallery          # renders example graphics to zig-out/render-gallery
```

### Working on Mortise itself

Run these two commands in separate terminals:

```sh
zig build dev --watch -fincremental
zig-out/bin/mortise serve examples/showcase --restart-on-rebuild
```

The first recompiles Mortise after every save to a `.zig` file. On x86_64
it uses Zig's own backend instead of LLVM, and incremental compilation
takes roughly 60 to 150 ms per change. The second restarts the dev server
whenever that binary changes, and open pages reload on their own. On a
Windows desktop a Zig edit reached the reloaded page in about 0.9 s,
against more than 3 s for a full LLVM build before restarting by hand.
Most of that time goes to copying the 27 MB debug binary and starting it.

## Usage

```sh
mortise new my-site                              # create a starter site
mortise build [SITE_DIR] [--drafts]              # build SITE_DIR (default .) into SITE_DIR/_site
mortise serve [SITE_DIR] [--port N] [--drafts]   # dev server on http://localhost:4000/
mortise version
```

`new` writes a small working site: a layout, a post layout, a header
include, a paginated home page, an about page, a welcome post, and a
stylesheet with colors for highlighted code. `--drafts` publishes pages and
posts marked `draft: true`.

`build` deletes and rewrites `SITE_DIR/_site` on every run.

`serve` builds the site into memory, serves it on `127.0.0.1` only, and
watches the source tree. After each save it rebuilds and the open browser
tabs reload. If a build fails, the browser shows an overlay with the file,
line, and message while the server keeps serving the last successful
build; the next good save clears it. A save that only changes stylesheets
swaps them into the open page without reloading it, so scroll position and
form input are kept.

Rebuilds are incremental: a change re-renders only the pages that depend
on it (the page itself, pages using a changed layout or include, and pages
that list posts or pages), and falls back to a full rebuild when the effect
is unclear. With 1,000 pages a save reaches the browser in about 11 ms on
Linux and 16 ms on Windows; see [bench/](bench/README.md). The reload script is added to HTML responses by the server
only; it never appears in `build` output.

## Example

[`examples/showcase/`](examples/showcase) is a small site that uses every
feature: data-driven navigation, pagination, excerpts, tags, a feed and
sitemap, tables, highlighted code, a 404 page, and a draft. Try it with:

```sh
zig build run -- serve examples/showcase
```

## Site layout

```
my-site/
  _config.yml                  site settings, available as site.*
  _layouts/base.html           layouts, chosen with `layout: base`
  _includes/nav.html           partials for {% include "nav.html" %}
  _posts/2024-01-05-hello.md   posts, published at /2024/01/05/hello/
  index.html                   a template page (it starts with frontmatter)
  about.md                     a Markdown page, published at /about/
  css/site.css                 copied as-is
```

- Paths starting with `_` or `.` are never published.
- Markdown pages publish to `name/index.html`; `index.md` publishes to its
  directory's `index.html`.
- `.html` files that start with `---` frontmatter are rendered as templates;
  other files are copied unchanged.
- `permalink: /some/path/` in frontmatter overrides the output location, and
  `draft: true` leaves a page or post out.
- A post's frontmatter `date: YYYY-MM-DD` overrides the date in its file
  name, both for ordering and for its URL.
- `baseurl: /blog` in `_config.yml` serves the site under a path prefix:
  page URLs start with it, `serve` serves under it, and templates can link
  to static files with `{{ site.baseurl }}/css/site.css`.
- Markdown pages get `page.excerpt`: frontmatter `excerpt` if set,
  otherwise the first paragraph of the rendered content.
- Posts can set `tags: [zig, web]` (or one tag as a string). `site.tags`
  lists every tag, sorted by name, each with `name` and its `posts`, newest
  first.
- [OpenAPI reference pages](docs/openapi.md): each `_api/NAME.json`
  OpenAPI 3 document becomes a static page at `/api/NAME/` with every
  operation, parameter, schema, and an example body.
- Code blocks with titles, marked lines, line numbers, and diffs; tabs and
  code groups; task lists, footnotes, and definition lists; and
  `page.breadcrumbs`, `page.previous`/`page.next`, and `site.nav` for
  wiki-style navigation. See [components](docs/components.md) and
  [templates](docs/templates.md#navigation).
- [Rendered graphics](docs/rendering.md): each `_render/PATH.yml` spec
  draws an image at `/PATH.png` during the build: starfields, HUD panel
  frames for CSS `border-image`, radar scopes, planets, and hologram
  wireframes, with sprite-sheet CSS animations for the animated ones.
- Two built-in [themes](docs/themes.md), picked with `theme:` in
  `_config.yml`: `visor`, a helmet heads-up display with a shield meter
  and HUD panel frames, and `lcars`, a starship console frame. Both draw
  their art with the built-in renderer and add no fonts or scripts.
- Built-in [components](docs/components.md): callouts (`> [!NOTE]`),
  cards, grids, details, figures, buttons, and steps (`:::card Title` ...
  `:::`), plus `:badge[New]` and `:kbd[Ctrl]`, styled by a `mortise.css`
  the build writes when a page uses them.
- Fenced code in Zig, C/C++, Rust, Go, JavaScript/TypeScript, Python,
  shell, JSON, and YAML is syntax-highlighted at build time with
  `hl-*` classes for your stylesheet; see the
  [Markdown subset](docs/markdown.md#fenced-code-blocks).
- Add `_layouts/tag.html` to generate a page per tag at `/tags/<slug>/`.
  The layout sees `page.tag` and `page.posts`, and each `site.tags` entry
  gains a `url`. Tags differing only in case or punctuation are merged.
- Markdown pages get `page.toc`, a nested list linking to their level 2
  and 3 headings.
- Headings get anchor ids from their text, so `## Getting started` can be
  linked as `#getting-started`.
- `paginate: 10` in a page's frontmatter splits it across pages of 10 posts
  (`/`, `/page/2/`, ...) with a `paginator` variable; see the
  [template syntax](docs/templates.md#pagination).
- Files in `_data/` are available as `site.data`: `_data/nav.json` becomes
  `site.data.nav` and `_data/team/lead.yml` becomes `site.data.team.lead`.
  YAML data files use the frontmatter subset; JSON files may hold any JSON,
  including lists of objects.
- `url: https://example.com` in `_config.yml` turns on two generated files:
  an Atom feed of the 20 newest posts at `feed.xml` and a sitemap of every
  page at `sitemap.xml`. Set `feed: false` or `sitemap: false` to skip one,
  or `sitemap: false` in a page's frontmatter to leave that page out. A file
  of your own at either path takes precedence. The feed's author is
  `author` from the config, or the site title.
- Templates see `site` (config values plus `site.posts`, newest first, and
  `site.pages`), `page` (frontmatter plus `url`, `path`, and for posts `date`
  and `slug`), and in layouts `content`.

See the [Markdown subset](docs/markdown.md),
[frontmatter format](docs/frontmatter.md),
[template syntax](docs/templates.md), and
[known limitations](docs/limitations.md).

## Source layout

| Path                  | Contents                                          |
| --------------------- | ------------------------------------------------- |
| `src/path.zig`        | Canonical, portable site paths                    |
| `src/SiteDir.zig`     | Filesystem access by site path through `std.Io`   |
| `src/BuildArena.zig`  | Arena-per-build allocation policy                 |
| `src/markdown.zig`    | Markdown subset to HTML                           |
| `src/frontmatter.zig` | Restricted YAML frontmatter                       |
| `src/template.zig`    | Template engine                                   |
| `src/pipeline.zig`    | Source tree to output files                       |
| `src/watch.zig`       | Native file watchers                              |
| `src/server.zig`      | Dev server and Server-Sent Events live reload     |
| `src/main.zig`        | Command-line entry point                          |
| `src/restart.zig`     | `serve --restart-on-rebuild` supervisor           |
| `src/themes/`         | Built-in themes (`theme:` in `_config.yml`)       |
| `render/`             | CPU renderer for build-time graphics; see [render/README.md](render/README.md) |
| `test/`               | Fixture and end-to-end tests and their inputs     |
| `bench/`              | Save-to-reload latency benchmark and results      |
