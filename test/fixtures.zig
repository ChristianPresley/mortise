//! Fixture-driven tests. Paths come from the build script so the tests do
//! not depend on the working directory they run in.

const std = @import("std");
const mortise = @import("mortise");
const paths = @import("test_paths");

const testing = std.testing;
const Io = std.Io;

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
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
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
