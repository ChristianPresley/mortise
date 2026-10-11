//! `mortise new`: writes a small working site to start from, in one of a
//! few starters, with a workflow that publishes it to GitHub Pages.

const std = @import("std");
const Io = std.Io;
const SiteDir = @import("SiteDir.zig");
const version = @import("root.zig").version;

pub const Error = error{DirectoryNotEmpty} || Io.Dir.CreateDirPathOpenError || SiteDir.WriteError ||
    Io.Dir.Iterator.Error || error{NameTooLong};

/// What kind of site to start.
pub const Starter = enum {
    /// Posts, a paginated home page, and an about page.
    blog,
    /// Documentation with a sidebar, breadcrumbs, and previous/next links.
    docs,
    /// A grid of project pages with an about page.
    portfolio,
};

/// "blog, docs, portfolio", for messages.
pub const starter_names = blk: {
    var s: []const u8 = "";
    for (std.meta.fieldNames(Starter)) |n| s = s ++ (if (s.len == 0) "" else ", ") ++ n;
    break :blk s;
};

/// Today's date as `YYYY-MM-DD` in UTC, from the real-time clock.
pub fn today(io: Io, buf: *[10]u8) []const u8 {
    const now = Io.Clock.real.now(io);
    const secs: u64 = @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_s)));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch unreachable;
}

/// Creates a new site in `path`, which must not exist or must be empty.
/// `date` (`YYYY-MM-DD`) names the blog's welcome post.
pub fn create(io: Io, path: []const u8, date: []const u8, starter: Starter) Error!void {
    var site = try SiteDir.openOrCreate(io, path);
    defer site.close();
    var it = site.dir.iterate();
    if (try it.next(io) != null) return error.DirectoryNotEmpty;

    for (common) |f| try site.writeFile(f[0], f[1]);
    switch (starter) {
        .blog => {
            for (blog) |f| try site.writeFile(f[0], f[1]);
            var name_buf: [64]u8 = undefined;
            const post = std.fmt.bufPrint(&name_buf, "_posts/{s}-welcome.md", .{date}) catch return error.NameTooLong;
            try site.writeFile(post, welcome_post);
        },
        .docs => for (docs) |f| try site.writeFile(f[0], f[1]),
        .portfolio => for (portfolio) |f| try site.writeFile(f[0], f[1]),
    }
}

const File = struct { []const u8, []const u8 };

/// Files every starter gets.
const common = [_]File{
    .{ ".gitignore",
        \\_site/
        \\.mortise-staging/
        \\
    },
    .{ ".github/workflows/pages.yml", pages_workflow },
    .{ "_layouts/base.html",
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>{% if page.title %}{{ page.title }} | {% endif %}{{ site.title }}</title>
        \\<link rel="stylesheet" href="{{ site.baseurl }}/mortise.css">
        \\<link rel="stylesheet" href="{{ site.baseurl }}/css/site.css">
        \\{% if site.theme or site.theme_tokens %}<link rel="stylesheet" href="{{ site.baseurl }}/theme.css">{% endif %}
        \\</head>
        \\<body>
        \\{% include "header.html" %}
        \\<main>
        \\{{ content }}
        \\</main>
        \\</body>
        \\</html>
        \\
    },
    .{ "_includes/header.html",
        \\<header>
        \\<a class="brand" href="{{ site.baseurl }}/">{{ site.title }}</a>
        \\<nav>
        \\{%- for item in site.nav %} <a href="{{ item.url }}"{% if item.url == page.url %} class="current"{% endif %}>{{ item.title }}</a>{% endfor -%}
        \\</nav>
        \\{{ site.scheme_toggle }}
        \\</header>
        \\
    },
};

/// Publishes the site to GitHub Pages with a released Mortise binary.
const pages_workflow =
    \\# Builds the site with Mortise and publishes it to GitHub Pages on every
    \\# push to main. In the repository's Settings > Pages, set the source to
    \\# "GitHub Actions". For a project site (https://USER.github.io/REPO/),
    \\# also set `baseurl: /REPO` in _config.yml.
    \\name: pages
    \\
    \\on:
    \\  push:
    \\    branches: [main]
    \\  workflow_dispatch:
    \\
    \\permissions:
    \\  contents: read
    \\  pages: write
    \\  id-token: write
    \\
    \\concurrency:
    \\  group: pages
    \\  cancel-in-progress: true
    \\
    \\env:
    \\  MORTISE_VERSION:
++ " " ++ version ++ "\n" ++
    \\
    \\jobs:
    \\  build:
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - uses: actions/checkout@v4
    \\
    \\      # The official release binary, checked against its SHA256SUMS.
    \\      - name: Install Mortise ${{ env.MORTISE_VERSION }}
    \\        run: |
    \\          base="https://github.com/ChristianPresley/mortise/releases/download/v${MORTISE_VERSION}"
    \\          file="mortise-${MORTISE_VERSION}-x86_64-linux.tar.gz"
    \\          cd "$RUNNER_TEMP"
    \\          curl -sSfL -o "$file" "$base/$file"
    \\          curl -sSfL -o SHA256SUMS "$base/SHA256SUMS"
    \\          grep " $file\$" SHA256SUMS | sha256sum -c -
    \\          tar -xzf "$file"
    \\          echo "$RUNNER_TEMP/mortise-${MORTISE_VERSION}-x86_64-linux" >> "$GITHUB_PATH"
    \\
    \\      - name: Build
    \\        run: mortise build
    \\
    \\      - uses: actions/upload-pages-artifact@v3
    \\        with:
    \\          path: _site
    \\
    \\  deploy:
    \\    needs: build
    \\    runs-on: ubuntu-latest
    \\    environment:
    \\      name: github-pages
    \\      url: ${{ steps.deployment.outputs.page_url }}
    \\    steps:
    \\      - id: deployment
    \\        uses: actions/deploy-pages@v4
    \\
;

/// The stylesheet all starters share, before their own rules.
const base_css =
    \\/* Colors come from theme_tokens in _config.yml, through theme.css. */
    \\html { background: var(--m-bg, #fff); }
    \\body { max-width: 46rem; margin: 2rem auto; padding: 0 1rem; font: 17px/1.6 system-ui, sans-serif; color: var(--m-text, #1d1d1f); }
    \\a { color: var(--m-accent, #0b57d0); }
    \\img { max-width: 100%; height: auto; }
    \\header { display: flex; flex-wrap: wrap; gap: .5rem 1.5rem; justify-content: space-between; align-items: baseline; padding-bottom: .75rem; border-bottom: 1px solid var(--m-border, #e5e5e5); }
    \\header .brand { font-weight: 700; color: inherit; text-decoration: none; }
    \\header nav { display: flex; flex-wrap: wrap; gap: .25rem 1rem; }
    \\header nav a { color: var(--m-muted, #6e6e73); text-decoration: none; }
    \\header nav a.current { color: inherit; font-weight: 600; }
    \\.date, small { color: var(--m-muted, #6e6e73); }
    \\pre { background: var(--m-surface, #f6f8fa); padding: 1rem; overflow-x: auto; border-radius: 6px; }
    \\.hl-keyword { color: light-dark(#a626a4, #d197e0); }
    \\.hl-literal, .hl-number { color: light-dark(#986801, #e5c07b); }
    \\.hl-string { color: light-dark(#50a14f, #98c379); }
    \\.hl-comment { color: light-dark(#a0a1a7, #7f848e); font-style: italic; }
    \\.hl-builtin { color: light-dark(#4078f2, #61afef); }
    \\
;

const blog = [_]File{
    .{ "_config.yml",
        \\# Site settings, available to templates as site.*
        \\title: My Mortise Site
        \\description: Built with Mortise
        \\# Set url to turn on feed.xml and sitemap.xml:
        \\# url: https://example.com
        \\# Pick a built-in theme, such as visor, phosphor or codex:
        \\# theme: visor
        \\# Colors, written to theme.css as --m-NAME variables. A pair is a light
        \\# and a dark color: the site follows the reader's setting, and
        \\# site.scheme_toggle lets them pick. The build warns about low contrast.
        \\theme_tokens:
        \\  bg: ["#ffffff", "#15161a"]
        \\  surface: ["#f6f8fa", "#1f2128"]
        \\  text: ["#1d1d1f", "#e8e8ed"]
        \\  muted: ["#6e6e73", "#a1a1aa"]
        \\  accent: ["#0b57d0", "#8ab4f8"]
        \\  border: ["#e5e5e5", "#33353d"]
        \\
    },
    .{ "_layouts/post.html",
        \\---
        \\layout: base
        \\---
        \\<article>
        \\<h1>{{ page.title }}</h1>
        \\<p class="date">{{ page.date | date }}</p>
        \\{{ content }}
        \\</article>
        \\
    },
    .{ "index.html",
        \\---
        \\title: Home
        \\layout: base
        \\paginate: 10
        \\# The site title in the header already links here.
        \\nav: false
        \\---
        \\<h1>{{ site.title }}</h1>
        \\<ul>
        \\{%- for post in paginator.posts %}
        \\<li><a href="{{ post.url }}">{{ post.title }}</a> <small>{{ post.date | date }}</small></li>
        \\{%- endfor %}
        \\</ul>
        \\{% if paginator.previous_url %}<a href="{{ paginator.previous_url }}">Newer</a>{% endif %}
        \\{% if paginator.next_url %}<a href="{{ paginator.next_url }}">Older</a>{% endif %}
        \\
    },
    .{ "about.md",
        \\---
        \\title: About
        \\layout: base
        \\---
        \\# About
        \\
        \\This site is built with [Mortise](https://github.com/ChristianPresley/mortise).
        \\
    },
    .{ "css/site.css", base_css },
};

const welcome_post =
    \\---
    \\title: Welcome
    \\layout: post
    \\tags: [mortise]
    \\---
    \\This is your first post. Edit it in `_posts/`, or run `mortise serve`
    \\and watch the browser reload as you save.
    \\
    \\```zig
    \\const std = @import("std");
    \\```
    \\
    \\> [!TIP]
    \\> Callouts, cards, buttons, and more are built in. See
    \\> [the components docs](https://github.com/ChristianPresley/mortise/blob/main/docs/components.md).
    \\
;

const docs = [_]File{
    .{ "_config.yml",
        \\# Site settings, available to templates as site.*
        \\title: My Project
        \\description: Documentation built with Mortise
        \\# Set url to turn on the sitemap:
        \\# url: https://example.com
        \\# Pick a built-in theme, such as codex, grid or phosphor:
        \\# theme: codex
        \\# Colors, written to theme.css as --m-NAME variables. A pair is a light
        \\# and a dark color: the site follows the reader's setting, and
        \\# site.scheme_toggle lets them pick. The build warns about low contrast.
        \\theme_tokens:
        \\  bg: ["#ffffff", "#15161a"]
        \\  surface: ["#f6f8fa", "#1f2128"]
        \\  text: ["#1d1d1f", "#e8e8ed"]
        \\  muted: ["#6e6e73", "#a1a1aa"]
        \\  accent: ["#0b57d0", "#8ab4f8"]
        \\  border: ["#e5e5e5", "#33353d"]
        \\
    },
    .{ "_layouts/doc.html",
        \\---
        \\layout: base
        \\---
        \\<div class="docs">
        \\<aside class="sidebar">
        \\<ul>
        \\{%- for item in site.nav %}
        \\<li><a href="{{ item.url }}"{% if item.url == page.url %} class="current"{% endif %}>{{ item.title }}</a>
        \\{%- if item.children %}
        \\<ul>
        \\{%- for child in item.children %}
        \\<li><a href="{{ child.url }}"{% if child.url == page.url %} class="current"{% endif %}>{{ child.title }}</a></li>
        \\{%- endfor %}
        \\</ul>
        \\{%- endif %}
        \\</li>
        \\{%- endfor %}
        \\</ul>
        \\</aside>
        \\<article>
        \\{% if page.breadcrumbs %}<nav class="breadcrumbs">{% for crumb in page.breadcrumbs %}<a href="{{ crumb.url }}">{{ crumb.title }}</a> › {% endfor %}{{ page.title }}</nav>{% endif %}
        \\{{ content }}
        \\<nav class="pager">
        \\{%- if page.previous %}<a href="{{ page.previous.url }}">← {{ page.previous.title }}</a>{% else %}<span></span>{% endif %}
        \\{%- if page.next %}<a href="{{ page.next.url }}">{{ page.next.title }} →</a>{% endif %}
        \\</nav>
        \\</article>
        \\</div>
        \\
    },
    .{ "index.md",
        \\---
        \\title: Home
        \\layout: base
        \\nav: false
        \\---
        \\# My Project
        \\
        \\A one-line description of what it does and who it is for.
        \\
        \\:::actions
        \\[Get started](docs/getting-started/) [Read the docs](docs/)
        \\:::
        \\
        \\::::grid
        \\:::card Fast
        \\Say what makes it worth using.
        \\:::
        \\:::card Simple
        \\And a second reason.
        \\:::
        \\:::card Free
        \\And a third.
        \\:::
        \\::::
        \\
    },
    .{ "docs/index.md",
        \\---
        \\title: Documentation
        \\layout: doc
        \\weight: 1
        \\---
        \\# Documentation
        \\
        \\Start with [Getting started](getting-started/), then read about
        \\[configuration](configuration/). Pages in `docs/` appear in the
        \\sidebar, ordered by the `weight` in their frontmatter.
        \\
    },
    .{ "docs/getting-started.md",
        \\---
        \\title: Getting started
        \\layout: doc
        \\weight: 1
        \\---
        \\# Getting started
        \\
        \\:::steps
        \\1. Install the project.
        \\2. Run it once.
        \\3. Read [Configuration](../configuration/) to make it your own.
        \\:::
        \\
        \\```sh title="Install"
        \\echo "replace this with your install command"
        \\```
        \\
        \\> [!NOTE]
        \\> Callouts, tabs, code titles and more are built in. See the
        \\> [components](https://github.com/ChristianPresley/mortise/blob/main/docs/components.md).
        \\
    },
    .{ "docs/configuration.md",
        \\---
        \\title: Configuration
        \\layout: doc
        \\weight: 2
        \\---
        \\# Configuration
        \\
        \\| Setting | Default | Meaning |
        \\| ------- | ------- | ------- |
        \\| `name`  | none    | What the setting does. |
        \\
        \\## Next steps
        \\
        \\Add a page by creating a Markdown file in `docs/`; it joins the
        \\sidebar and the previous/next links on its own.
        \\
    },
    .{ "css/site.css", base_css ++
        \\body { max-width: 64rem; }
        \\.docs { display: grid; grid-template-columns: 13rem 1fr; gap: 2.5rem; margin-top: 1.5rem; }
        \\.sidebar ul { list-style: none; margin: 0; padding: 0; }
        \\.sidebar ul ul { margin: .2rem 0 .4rem .9rem; }
        \\.sidebar a { display: block; padding: .2rem .5rem; border-radius: 6px; color: inherit; text-decoration: none; }
        \\.sidebar a.current { background: #eef3fd; color: #0b57d0; font-weight: 600; }
        \\.breadcrumbs { color: #6e6e73; font-size: .9rem; }
        \\.breadcrumbs a { color: inherit; }
        \\.pager { display: flex; justify-content: space-between; margin-top: 3rem; padding-top: 1rem; border-top: 1px solid #e5e5e5; }
        \\@media (max-width: 760px) { .docs { grid-template-columns: 1fr; } }
        \\
    },
};

const portfolio = [_]File{
    .{ "_config.yml",
        \\# Site settings, available to templates as site.*
        \\title: Your Name
        \\description: Things I have made
        \\# Pick a built-in theme, such as cyberdeck, grid or cockpit:
        \\# theme: cyberdeck
        \\# Colors, written to theme.css as --m-NAME variables. A pair is a light
        \\# and a dark color: the site follows the reader's setting, and
        \\# site.scheme_toggle lets them pick. The build warns about low contrast.
        \\theme_tokens:
        \\  bg: ["#ffffff", "#15161a"]
        \\  surface: ["#f6f8fa", "#1f2128"]
        \\  text: ["#1d1d1f", "#e8e8ed"]
        \\  muted: ["#6e6e73", "#a1a1aa"]
        \\  accent: ["#0b57d0", "#8ab4f8"]
        \\  border: ["#e5e5e5", "#33353d"]
        \\
    },
    .{ "_layouts/project.html",
        \\---
        \\layout: base
        \\---
        \\<article class="project">
        \\<p class="date">{{ page.year }} · {{ page.role }}</p>
        \\<h1>{{ page.title }}</h1>
        \\<p class="lead">{{ page.summary }}</p>
        \\{{ content }}
        \\<p><a href="{{ site.baseurl }}/">← All projects</a></p>
        \\</article>
        \\
    },
    .{ "index.html",
        \\---
        \\title: Work
        \\layout: base
        \\nav: false
        \\---
        \\<h1>{{ site.title }}</h1>
        \\<p class="lead">{{ site.description }}</p>
        \\<div class="projects">
        \\{%- for p in site.pages %}{% if p.layout == "project" %}
        \\<a class="project-card" href="{{ p.url }}">
        \\<small>{{ p.year }}</small>
        \\<strong>{{ p.title }}</strong>
        \\<span>{{ p.summary }}</span>
        \\</a>
        \\{%- endif %}{% endfor %}
        \\</div>
        \\
    },
    .{ "projects/index.md",
        \\---
        \\title: Projects
        \\layout: base
        \\nav: false
        \\permalink: /projects/
        \\---
        \\Every project is on the [home page](../).
        \\
    },
    .{ "projects/first.md",
        \\---
        \\title: The first project
        \\layout: project
        \\year: 2025
        \\role: Design and code
        \\summary: One sentence on what it is and why it mattered.
        \\nav: false
        \\---
        \\Tell the story: the problem, what you tried, and how it turned out.
        \\Add images under `images/` and show them with `![alt](../../images/name.png)`.
        \\
    },
    .{ "projects/second.md",
        \\---
        \\title: The second project
        \\layout: project
        \\year: 2024
        \\role: Research
        \\summary: Another project, in a sentence.
        \\nav: false
        \\---
        \\Projects are Markdown files in `projects/` with `layout: project`.
        \\The home page lists every one of them.
        \\
    },
    .{ "about.md",
        \\---
        \\title: About
        \\layout: base
        \\---
        \\# About
        \\
        \\A short introduction, and how to reach you.
        \\
    },
    .{ "css/site.css", base_css ++
        \\body { max-width: 56rem; }
        \\.lead { font-size: 1.15rem; color: #48484d; }
        \\.projects { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr)); gap: 1rem; margin-top: 2rem; }
        \\.project-card { display: flex; flex-direction: column; gap: .35rem; padding: 1.1rem 1.2rem; border: 1px solid #e5e5e5; border-radius: 10px; color: inherit; text-decoration: none; transition: border-color .15s, transform .15s; }
        \\.project-card:hover { border-color: #0b57d0; transform: translateY(-2px); }
        \\.project-card span { color: #6e6e73; font-size: .95rem; }
        \\
    },
};

const testing = std.testing;

fn expectBuilds(starter: Starter, expect: []const []const u8) !void {
    const pipeline = @import("pipeline.zig");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/site", .{root});
    defer testing.allocator.free(path);

    try create(testing.io, path, "2024-05-06", starter);
    try testing.expectError(error.DirectoryNotEmpty, create(testing.io, path, "2024-05-06", starter));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var src = try SiteDir.open(testing.io, path);
    defer src.close();
    var diag: pipeline.Diagnostic = .{};
    const site = pipeline.build(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("{s}: {f}\n", .{ @tagName(starter), diag });
        return err;
    };
    for (expect) |p| {
        if (site.find(p) == null) {
            std.debug.print("{s} starter is missing {s}\n", .{ @tagName(starter), p });
            return error.TestExpectedOutput;
        }
    }
    // Hidden files stay out of the site.
    try testing.expect(site.find(".github/workflows/pages.yml") == null);
    const workflow = try src.readFile(arena.allocator(), ".github/workflows/pages.yml");
    try testing.expect(std.mem.indexOf(u8, workflow, "MORTISE_VERSION: " ++ version ++ "\n") != null);
}

test "every starter builds" {
    try expectBuilds(.blog, &.{ "index.html", "2024/05/06/welcome/index.html", "about/index.html" });
    try expectBuilds(.docs, &.{ "index.html", "docs/index.html", "docs/getting-started/index.html", "docs/configuration/index.html", "mortise.css" });
    try expectBuilds(.portfolio, &.{ "index.html", "projects/first/index.html", "projects/second/index.html", "about/index.html" });
    try testing.expectEqualStrings("blog, docs, portfolio", starter_names);
}

test "today is a date" {
    var buf: [10]u8 = undefined;
    const d = today(testing.io, &buf);
    try testing.expect(@import("template.zig").parseDate(d) != null);
}
