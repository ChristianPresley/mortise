//! Fixture-driven tests. Paths come from the build script so the tests do
//! not depend on the working directory they run in.

const std = @import("std");
const mortise = @import("mortise");
const paths = @import("test_paths");

const testing = std.testing;
const Io = std.Io;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "site-basic builds to the expected output" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = try mortise.SiteDir.open(io, paths.site_basic);
    defer src.close();
    var expected = try mortise.SiteDir.open(io, paths.site_basic_expected);
    defer expected.close();

    var diag: mortise.pipeline.Diagnostic = .{};
    const site = mortise.pipeline.build(arena, src, &diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };

    // Write to a temporary directory exactly as `mortise build` does.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const out = mortise.SiteDir.borrow(io, tmp.dir);
    try mortise.pipeline.writeSite(site, src, out, &diag);

    var bad: ?[]const u8 = null;
    const want = try expected.listFiles(arena, &bad);
    const got = try out.listFiles(arena, &bad);
    var failures: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < want.files.len or j < got.files.len) {
        const order: std.math.Order = if (i == want.files.len) .gt else if (j == got.files.len) .lt else std.mem.order(u8, want.files[i], got.files[j]);
        switch (order) {
            .lt => {
                std.debug.print("missing output: {s}\n", .{want.files[i]});
                failures += 1;
                i += 1;
            },
            .gt => {
                std.debug.print("unexpected output: {s}\n", .{got.files[j]});
                failures += 1;
                j += 1;
            },
            .eq => {
                const w = try expected.readFile(arena, want.files[i]);
                const g = try out.readFile(arena, got.files[j]);
                if (!std.mem.eql(u8, w, g)) {
                    std.debug.print("\n{s} differs\n--- expected\n{s}--- got\n{s}---\n", .{ want.files[i], w, g });
                    failures += 1;
                }
                // `build` output must never carry dev-server code.
                if (std.mem.indexOf(u8, g, "__reload") != null or std.mem.indexOf(u8, g, "EventSource") != null) {
                    std.debug.print("{s} contains dev-server code\n", .{got.files[j]});
                    failures += 1;
                }
                i += 1;
                j += 1;
            },
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "the showcase example builds" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var src = try mortise.SiteDir.open(testing.io, paths.showcase);
    defer src.close();
    var diag: mortise.pipeline.Diagnostic = .{};
    const site = mortise.pipeline.build(arena_state.allocator(), src, &diag) catch |err| {
        std.debug.print("showcase failed to build: {f}\n", .{diag});
        return err;
    };
    for ([_][]const u8{ "index.html", "page/2/index.html", "tags/index.html", "docs/index.html", "404.html", "feed.xml", "sitemap.xml" }) |p| {
        if (site.find(p) == null) {
            std.debug.print("showcase is missing {s}\n", .{p});
            return error.TestExpectedOutput;
        }
    }
}

test "markdown fixtures" {
    const io = testing.io;
    var dir = try Io.Dir.cwd().openDir(io, paths.markdown_fixtures, .{ .iterate = true });
    defer dir.close(io);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sortUnstable([]const u8, names.items, {}, lessThan);
    try testing.expect(names.items.len > 0);

    var failures: usize = 0;
    for (names.items) |name| {
        const stem = name[0 .. name.len - ".md".len];
        const src = try dir.readFileAlloc(io, name, arena, .limited(1 << 20));
        const expected_name = try std.mem.concat(arena, u8, &.{ stem, ".html" });
        const expected = try dir.readFileAlloc(io, expected_name, arena, .limited(1 << 20));
        const got = try mortise.markdown.toHtml(arena, src);
        if (!std.mem.eql(u8, expected, got)) {
            failures += 1;
            std.debug.print("\nmarkdown fixture '{s}' differs\n--- expected\n{s}--- got\n{s}---\n", .{ name, expected, got });
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
