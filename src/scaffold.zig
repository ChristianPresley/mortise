//! `mortise new`: writes a small working site to start from.

const std = @import("std");
const Io = std.Io;
const SiteDir = @import("SiteDir.zig");

pub const Error = error{DirectoryNotEmpty} || Io.Dir.CreateDirPathOpenError || SiteDir.WriteError ||
    Io.Dir.Iterator.Error || error{NameTooLong};

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
/// `date` (`YYYY-MM-DD`) names the welcome post.
pub fn create(io: Io, path: []const u8, date: []const u8) Error!void {
    var site = try SiteDir.openOrCreate(io, path);
    defer site.close();
    var it = site.dir.iterate();
    if (try it.next(io) != null) return error.DirectoryNotEmpty;

    for (files) |f| try site.writeFile(f[0], f[1]);
    var name_buf: [64]u8 = undefined;
    const post = std.fmt.bufPrint(&name_buf, "_posts/{s}-welcome.md", .{date}) catch return error.NameTooLong;
    try site.writeFile(post, welcome_post);
}

const files = [_]struct { []const u8, []const u8 }{
    .{ "_config.yml",
        \\# Site settings, available to templates as site.*
        \\title: My Mortise Site
        \\description: Built with Mortise
        \\# Set url to turn on feed.xml and sitemap.xml:
        \\# url: https://example.com
        \\
    },
    .{ "_layouts/base.html",
        \\<!doctype html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>{% if page.title %}{{ page.title }} | {% endif %}{{ site.title }}</title>
        \\<link rel="stylesheet" href="{{ site.baseurl }}/mortise.css">
        \\<link rel="stylesheet" href="{{ site.baseurl }}/css/site.css">
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
    .{ "_includes/header.html",
        \\<header>
        \\<a class="brand" href="{{ site.baseurl }}/">{{ site.title }}</a>
        \\<nav>
        \\{%- for p in site.pages %}{% if p.title and p.nav != false %} <a href="{{ p.url }}">{{ p.title }}</a>{% endif %}{% endfor -%}
        \\</nav>
        \\</header>
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
    .{ "css/site.css",
        \\body { max-width: 42rem; margin: 2rem auto; padding: 0 1rem; font: 17px/1.6 system-ui, sans-serif; color: #1d1d1f; }
        \\a { color: #0b57d0; }
        \\header { display: flex; justify-content: space-between; align-items: baseline; padding-bottom: .75rem; border-bottom: 1px solid #e5e5e5; }
        \\header .brand { font-weight: 700; color: inherit; text-decoration: none; }
        \\header nav a { margin-left: 1rem; color: #6e6e73; text-decoration: none; }
        \\.date, small { color: #6e6e73; }
        \\pre { background: #f6f8fa; padding: 1rem; overflow-x: auto; border-radius: 6px; }
        \\.hl-keyword { color: #a626a4; }
        \\.hl-literal, .hl-number { color: #986801; }
        \\.hl-string { color: #50a14f; }
        \\.hl-comment { color: #a0a1a7; font-style: italic; }
        \\.hl-builtin { color: #4078f2; }
        \\
    },
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

const testing = std.testing;

test "a new site builds" {
    const pipeline = @import("pipeline.zig");
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/site", .{root});
    defer testing.allocator.free(path);

    try create(testing.io, path, "2024-05-06");
    try testing.expectError(error.DirectoryNotEmpty, create(testing.io, path, "2024-05-06"));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var src = try SiteDir.open(testing.io, path);
    defer src.close();
    var diag: pipeline.Diagnostic = .{};
    const site = pipeline.build(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expect(site.find("2024/05/06/welcome/index.html") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("index.html").?.data.bytes, "Welcome") != null);
}

test "today is a date" {
    var buf: [10]u8 = undefined;
    const d = today(testing.io, &buf);
    try testing.expect(@import("template.zig").parseDate(d) != null);
}
