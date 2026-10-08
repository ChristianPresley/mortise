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
```

## Usage

```sh
mortise build [SITE_DIR]               # build SITE_DIR (default .) into SITE_DIR/_site
mortise serve [SITE_DIR] [--port N]    # dev server on http://localhost:4000/
mortise version
```

`build` deletes and rewrites `SITE_DIR/_site` on every run.

`serve` builds the site into memory, serves it on `127.0.0.1` only, and
watches the source tree. After each save it rebuilds and the open browser
tabs reload. If a build fails, the browser shows an overlay with the file,
line, and message while the server keeps serving the last successful
build; the next good save clears it. The reload script is added to HTML responses by the server
only; it never appears in `build` output.

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
| `test/`               | Fixture and end-to-end tests and their inputs     |
| `bench/`              | Save-to-reload latency benchmark and results      |
