//! Save-to-reload latency benchmark.
//!
//! Generates a site with N posts, starts the dev server and the native file
//! watcher exactly as `mortise serve` does, connects a Server-Sent Events
//! client to /__reload, and then repeatedly edits one post. Each sample is
//! the time from the end of the file write to the moment the client has
//! read the `reload` event: watcher notification, rebuild, and event
//! delivery, which is everything between a save and the browser reloading
//! except the browser's own page load.
//!
//! Usage: zig build bench -- [PAGES] [RUNS] [--full]
//!
//! Defaults: 1000 pages, 30 runs, incremental rebuilds. `--full` makes the
//! server rebuild the whole site on every change, for comparison.

const std = @import("std");
const Io = std.Io;
const mortise = @import("mortise");
const SiteDir = mortise.SiteDir;

const site_dir = "zig-out/bench-site";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var numbers: [2]?usize = .{ null, null };
    var count: usize = 0;
    var full = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (count < numbers.len) {
            numbers[count] = try std.fmt.parseInt(usize, arg, 10);
            count += 1;
        } else return error.TooManyArguments;
    }
    const pages = numbers[0] orelse 1000;
    const runs = numbers[1] orelse 30;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_writer.interface;

    try Io.Dir.cwd().deleteTree(io, site_dir);
    try generateSite(io, arena, pages);
    const root = try Io.Dir.cwd().realPathFileAlloc(io, site_dir, arena);

    const server = try mortise.server.Server.init(gpa, io, root, .{ .port = 0, .incremental = !full });
    defer server.deinit();
    const full_build_ms = nsToMs(server.last_build_ns);
    var watcher = try mortise.watch.Watcher.init(gpa, io, root);
    defer watcher.deinit();
    try server.start();
    try server.watch(&watcher);

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(server.port) };
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var wbuf: [256]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.writeAll("GET /__reload?since=1 HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try w.interface.flush();
    var rbuf: [0]u8 = .{};
    var r = stream.reader(io, &rbuf);
    var seen: std.ArrayList(u8) = .empty;
    try readUntil(&r.interface, arena, &seen, 0, "retry: 1000");

    const samples = try arena.alloc(f64, runs);
    const site = SiteDir.borrow(io, try Io.Dir.cwd().openDir(io, site_dir, .{}));
    for (samples, 0..) |*sample, k| {
        // Let the previous rebuild settle so runs do not overlap.
        try io.sleep(.fromMilliseconds(150), .awake);
        const body = try std.fmt.allocPrint(arena, "---\ntitle: Post 0 edit {d}\nlayout: post\n---\nEdited body {d}.\n", .{ k, k });
        const mark = seen.items.len;
        try site.writeFile("_posts/2024-01-01-post-0.md", body);
        const start = Io.Clock.Timestamp.now(io, .awake);
        try readUntil(&r.interface, arena, &seen, mark, "event: reload\n");
        const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
        sample.* = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
    }

    std.mem.sortUnstable(f64, samples, {}, std.sort.asc(f64));
    try out.print(
        \\Mortise save-to-reload latency
        \\  platform:     {s}-{s}, watcher: {s}
        \\  rebuilds:     {s}
        \\  site:         {d} posts + 1 index page
        \\  full build:   {d:.1} ms (initial)
        \\  runs:         {d}
        \\  min:          {d:.1} ms
        \\  median:       {d:.1} ms
        \\  p95:          {d:.1} ms
        \\  max:          {d:.1} ms
        \\
    , .{
        @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag), watcher.backendName(),
        if (full) "full" else "incremental",
        pages,                                 full_build_ms,                       runs,
        samples[0],                            samples[runs / 2],                   samples[@min(runs - 1, (runs * 95) / 100)],
        samples[runs - 1],
    });
    try out.flush();
    try Io.Dir.cwd().deleteTree(io, site_dir);
}

fn nsToMs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

fn readUntil(r: *Io.Reader, gpa: std.mem.Allocator, seen: *std.ArrayList(u8), from: usize, needle: []const u8) !void {
    while (std.mem.indexOfPos(u8, seen.items, from, needle) == null) {
        var chunk: [4096]u8 = undefined;
        var vec = [_][]u8{&chunk};
        const n = try r.readVec(&vec);
        if (n == 0) return error.EndOfStream;
        try seen.appendSlice(gpa, chunk[0..n]);
    }
}

fn generateSite(io: Io, arena: std.mem.Allocator, pages: usize) !void {
    var root = try SiteDir.openOrCreate(io, site_dir);
    defer root.close();
    try root.writeFile("_config.yml", "title: Benchmark\n");
    try root.writeFile("_layouts/base.html",
        \\<!doctype html><html><head><title>{{ page.title }} | {{ site.title }}</title></head>
        \\<body>{% include "nav.html" %}<main>{{ content }}</main></body></html>
    );
    try root.writeFile("_layouts/post.html", "---\nlayout: base\n---\n<article><h1>{{ page.title }}</h1>{{ content }}</article>");
    try root.writeFile("_includes/nav.html", "<nav><a href=\"/\">Home</a></nav>");
    try root.writeFile("index.html",
        \\---
        \\title: Home
        \\layout: base
        \\---
        \\<ul>{% for p in site.posts %}<li><a href="{{ p.url }}">{{ p.title }}</a></li>{% endfor %}</ul>
    );
    for (0..pages) |i| {
        const path = try std.fmt.allocPrint(arena, "_posts/2024-01-01-post-{d}.md", .{i});
        const body = try std.fmt.allocPrint(arena,
            \\---
            \\title: Post {d}
            \\layout: post
            \\tags: [bench, zig]
            \\---
            \\# Heading {d}
            \\
            \\Some *emphasis*, **strong text**, `code`, and a [link](/about/).
            \\
            \\- one
            \\- two
            \\- three
            \\
            \\```zig
            \\const x = {d};
            \\```
            \\
        , .{ i, i, i });
        try root.writeFile(path, body);
    }
}
