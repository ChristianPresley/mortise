//! Full-build benchmark: how long `mortise build` takes on a large site,
//! and the same site built by Hugo when `hugo` is on the PATH.
//!
//! Usage: zig build bench-build -- [PAGES] [RUNS]
//!
//! Defaults: 10000 pages, 5 runs. The benchmark writes two equivalent
//! sites under zig-out/: a Mortise site and a Hugo site with the same
//! posts, layouts and tag pages. Each run is a complete build from source,
//! including writing every output file; the median is reported.

const std = @import("std");
const Io = std.Io;
const mortise = @import("mortise");
const SiteDir = mortise.SiteDir;

const mortise_dir = "zig-out/bench-build/mortise";
const hugo_dir = "zig-out/bench-build/hugo";
const tag_names = [_][]const u8{ "zig", "web", "build", "markdown", "templates", "server", "design", "notes", "release", "guide" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const pages = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 10000;
    const runs = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 5;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;

    try Io.Dir.cwd().deleteTree(io, "zig-out/bench-build");
    try generate(io, arena, pages);
    try out.print("Generated {d} posts in {s} and {s}\n", .{ pages, mortise_dir, hugo_dir });
    try out.flush();

    // Mortise: build in this process, as `mortise build` does.
    var src = try SiteDir.open(io, mortise_dir);
    defer src.close();
    const times = try arena.alloc(u64, runs);
    var outputs: usize = 0;
    for (times) |*t| {
        var build_arena: mortise.BuildArena = .init(gpa);
        defer build_arena.deinit();
        const start = Io.Clock.Timestamp.now(io, .awake);
        var diag: mortise.pipeline.Diagnostic = .{};
        const site = mortise.pipeline.build(build_arena.begin(), src, &diag) catch |err| {
            std.debug.print("build failed: {f}\n", .{diag});
            return err;
        };
        const built = Io.Clock.Timestamp.now(io, .awake);
        try mortise.pipeline.writeOutputDir(site, src, &diag);
        const done = Io.Clock.Timestamp.now(io, .awake);
        t.* = @intCast(start.durationTo(done).raw.nanoseconds);
        try out.print("  run: build {d:.0} ms, write {d:.0} ms\n", .{ nsToMs(@intCast(start.durationTo(built).raw.nanoseconds)), nsToMs(@intCast(built.durationTo(done).raw.nanoseconds)) });
        try out.flush();
        outputs = site.outputs.len;
    }
    const m = median(times);
    try out.print("mortise: {d} outputs, median {d:.0} ms over {d} runs ({d:.0} pages/s)\n", .{ outputs, nsToMs(m), runs, @as(f64, @floatFromInt(pages)) / (nsToMs(m) / 1000) });
    try out.flush();

    // `mortise build --in-place`: into an empty `_site`, then again with
    // nothing changed, then after one post changed.
    try src.deleteTree(mortise.pipeline.output_dir);
    const in_place = try arena.alloc(u64, runs + 2);
    for (in_place, 0..) |*t, k| {
        // Post 0 is dated 2001-09-09; its title changes, as an edit would.
        if (k == runs + 1) try src.writeFile("_posts/2001-09-09-post-0.md", "---\ntitle: Post number zero\nlayout: post\ntags: [zig, zig]\n---\nChanged.\n");
        var build_arena: mortise.BuildArena = .init(gpa);
        defer build_arena.deinit();
        const start = Io.Clock.Timestamp.now(io, .awake);
        var diag: mortise.pipeline.Diagnostic = .{};
        const site = try mortise.pipeline.build(build_arena.begin(), src, &diag);
        try mortise.pipeline.writeOutputInPlace(site, src, &diag);
        t.* = @intCast(start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds);
    }
    try out.print("mortise --in-place: empty _site {d:.0} ms, unchanged rebuild median {d:.0} ms over {d} runs, one post changed {d:.0} ms\n", .{ nsToMs(in_place[0]), nsToMs(median(in_place[1 .. runs + 1])), runs, nsToMs(in_place[runs + 1]) });
    try out.flush();

    // Hugo, if installed, each run into an empty `public/`, as a fresh
    // checkout builds. (Removing the old output is not timed for Hugo,
    // while Mortise's write time includes replacing the previous `_site`.)
    var hugo_times: std.ArrayList(u64) = .empty;
    for (0..runs) |_| {
        Io.Dir.cwd().deleteTree(io, hugo_dir ++ "/public") catch {};
        const start = Io.Clock.Timestamp.now(io, .awake);
        var child = std.process.spawn(io, .{ .argv = &.{ "hugo", "--quiet", "--source", hugo_dir }, .stdout = .ignore, .stderr = .ignore }) catch {
            try out.writeAll("hugo: not found on PATH; install Hugo to compare\n");
            break;
        };
        const term = try child.wait(io);
        if (term != .exited or term.exited != 0) {
            try out.writeAll("hugo: build failed\n");
            break;
        }
        try hugo_times.append(arena, @intCast(start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds));
    }
    if (hugo_times.items.len > 0) {
        const hm = median(hugo_times.items);
        try out.print("hugo:    median {d:.0} ms over {d} runs into an empty public/ ({d:.0} pages/s)\n", .{ nsToMs(hm), hugo_times.items.len, @as(f64, @floatFromInt(pages)) / (nsToMs(hm) / 1000) });
    }
    try out.flush();
}

fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// The text of post `i`: a few paragraphs with emphasis, links, a list and
/// a code block, like a typical blog post.
fn body(arena: std.mem.Allocator, i: usize) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\Post {d} is about *building sites* with **static generators**. It links
        \\to [the docs](https://example.com/docs/) and to [post {d}](/posts/{d}/).
        \\
        \\## Details
        \\
        \\- First, write Markdown.
        \\- Then, run the build.
        \\- Finally, publish the `_site` folder.
        \\
        \\```zig
        \\const answer: u32 = {d};
        \\```
        \\
        \\A closing paragraph with a little more text so the page has some
        \\weight, as real posts do. Number {d} of the series.
        \\
    , .{ i, (i + 1), (i + 1), i, i });
}

fn generate(io: Io, arena: std.mem.Allocator, pages: usize) !void {
    var m = try SiteDir.openOrCreate(io, mortise_dir);
    defer m.close();
    var h = try SiteDir.openOrCreate(io, hugo_dir);
    defer h.close();

    // Mortise: a base layout with navigation, a post layout, tag pages, and
    // a home page with the ten newest posts.
    try m.writeFile("_config.yml", "title: Benchmark\nurl: https://example.com\n");
    try m.writeFile("_layouts/base.html",
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8"><title>{{ page.title }} | {{ site.title }}</title></head>
        \\<body><header><a href="/">{{ site.title }}</a></header><main>{{ content }}</main></body></html>
        \\
    );
    try m.writeFile("_layouts/post.html",
        \\---
        \\layout: base
        \\---
        \\<article><h1>{{ page.title }}</h1><p>{{ page.date | date }}{% for t in page.tags %} #{{ t }}{% endfor %}</p>{{ content }}</article>
        \\
    );
    try m.writeFile("_layouts/tag.html",
        \\---
        \\layout: base
        \\---
        \\<h1>{{ page.tag }}</h1><ul>{% for p in page.posts %}<li><a href="{{ p.url }}">{{ p.title }}</a></li>{% endfor %}</ul>
        \\
    );
    try m.writeFile("index.html",
        \\---
        \\title: Home
        \\layout: base
        \\paginate: 10
        \\---
        \\<ul>{% for p in paginator.posts %}<li><a href="{{ p.url }}">{{ p.title }}</a></li>{% endfor %}</ul>
        \\
    );

    // Hugo: the same templates in Go template syntax.
    try h.writeFile("hugo.toml", "baseURL = 'https://example.com/'\ntitle = 'Benchmark'\n[pagination]\npagerSize = 10\n");
    try h.writeFile("layouts/_default/baseof.html",
        \\<!doctype html>
        \\<html lang="en"><head><meta charset="utf-8"><title>{{ .Title }} | {{ .Site.Title }}</title></head>
        \\<body><header><a href="/">{{ .Site.Title }}</a></header><main>{{ block "main" . }}{{ end }}</main></body></html>
        \\
    );
    try h.writeFile("layouts/_default/single.html",
        \\{{ define "main" }}<article><h1>{{ .Title }}</h1><p>{{ .Date.Format "January 2, 2006" }}{{ range .Params.tags }} #{{ . }}{{ end }}</p>{{ .Content }}</article>{{ end }}
        \\
    );
    try h.writeFile("layouts/_default/list.html",
        \\{{ define "main" }}<h1>{{ .Title }}</h1><ul>{{ range .Pages }}<li><a href="{{ .RelPermalink }}">{{ .Title }}</a></li>{{ end }}</ul>{{ end }}
        \\
    );
    try h.writeFile("layouts/index.html",
        \\{{ define "main" }}<ul>{{ range (.Paginate (where .Site.RegularPages "Type" "posts")).Pages }}<li><a href="{{ .RelPermalink }}">{{ .Title }}</a></li>{{ end }}</ul>{{ end }}
        \\
    );

    for (0..pages) |i| {
        // Dates spread over about 27 years, one post a day.
        const day = (std.time.epoch.EpochSeconds{ .secs = 1_000_000_000 + @as(u64, i) * 86400 }).getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const date = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 });
        const tags = try std.fmt.allocPrint(arena, "[{s}, {s}]", .{ tag_names[i % tag_names.len], tag_names[(i / 7) % tag_names.len] });
        const text = try body(arena, i);
        const mfile = try std.fmt.allocPrint(arena, "_posts/{s}-post-{d}.md", .{ date, i });
        try m.writeFile(mfile, try std.fmt.allocPrint(arena, "---\ntitle: Post number {d}\nlayout: post\ntags: {s}\n---\n{s}", .{ i, tags, text }));
        const hfile = try std.fmt.allocPrint(arena, "content/posts/post-{d}.md", .{i});
        try h.writeFile(hfile, try std.fmt.allocPrint(arena, "---\ntitle: Post number {d}\ndate: {s}\ntags: {s}\n---\n{s}", .{ i, date, tags, text }));
    }
}
