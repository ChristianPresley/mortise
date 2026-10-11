//! Code included from files: the `<<< path` Markdown directive.
//!
//!   <<< _snippets/server.zig                  the whole file
//!   <<< _snippets/server.zig:10-30            lines 10 to 30
//!   <<< _snippets/server.zig:10-              line 10 to the end
//!   <<< _snippets/server.zig#accept           the region named `accept`
//!   <<< _snippets/server.zig#accept {2} title="Accept" lineNumbers
//!
//! A region starts on a line containing `#region NAME` and ends on the
//! matching line containing `#endregion`, so it works in any comment
//! syntax (`// #region accept`, `# #region accept`, `<!-- #region x -->`).
//! Region marker lines are left out of the result, including those of
//! regions nested inside it. The extracted lines lose their common
//! indentation. Everything after the path is code block options, as on a
//! fence: `{lines}`, `title="..."`, `lineNumbers`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Spec = struct {
    path: []const u8,
    select: Select = .all,
    /// Code block options after the path.
    meta: []const u8 = "",

    pub const Select = union(enum) {
        all,
        /// 1-based and inclusive; `end` null means to the end of the file.
        lines: struct { start: usize, end: ?usize },
        region: []const u8,
    };
};

/// Parses the text after `<<<`. Returns null when there is no path.
pub fn parseSpec(text: []const u8) ?Spec {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return null;
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    var target = t[0..end];
    var spec: Spec = .{ .path = target, .meta = std.mem.trim(u8, t[end..], " \t") };
    if (std.mem.indexOfScalar(u8, target, '#')) |h| {
        spec.path = target[0..h];
        spec.select = .{ .region = target[h + 1 ..] };
    } else if (std.mem.lastIndexOfScalar(u8, target, ':')) |c| {
        const range = target[c + 1 ..];
        const dash = std.mem.indexOfScalar(u8, range, '-');
        const start = std.fmt.parseInt(usize, range[0 .. dash orelse range.len], 10) catch return spec;
        var stop: ?usize = start;
        if (dash) |d| {
            stop = if (d + 1 == range.len) null else std.fmt.parseInt(usize, range[d + 1 ..], 10) catch return spec;
        }
        target = target[0..c];
        spec.path = target;
        spec.select = .{ .lines = .{ .start = start, .end = stop } };
    }
    if (spec.path.len == 0) return null;
    return spec;
}

pub const ExtractError = error{ BadRange, NoSuchRegion, UnclosedRegion } || Allocator.Error;

/// The selected lines of `text`, dedented, ending with a newline.
pub fn extract(arena: Allocator, text: []const u8, select: Spec.Select) ExtractError![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        try lines.append(arena, std.mem.trimEnd(u8, raw, "\r"));
    }
    // A final newline does not start another line.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    const all = lines.items;

    var picked: std.ArrayList([]const u8) = .empty;
    switch (select) {
        .all => for (all) |l| {
            if (!isMarker(l)) try picked.append(arena, l);
        },
        .lines => |r| {
            const stop = r.end orelse all.len;
            if (r.start == 0 or r.start > stop or r.start > all.len or stop > all.len) return error.BadRange;
            try picked.appendSlice(arena, all[r.start - 1 .. stop]);
        },
        .region => |name| {
            const start = for (all, 0..) |l, i| {
                if (regionName(l)) |n| if (std.mem.eql(u8, n, name)) break i;
            } else return error.NoSuchRegion;
            var depth: usize = 1;
            var i = start + 1;
            while (i < all.len) : (i += 1) {
                const l = all[i];
                if (regionName(l) != null) {
                    depth += 1;
                } else if (isEndRegion(l)) {
                    depth -= 1;
                    if (depth == 0) break;
                } else {
                    try picked.append(arena, l);
                }
            } else return error.UnclosedRegion;
        },
    }
    return dedent(arena, picked.items);
}

fn isMarker(line: []const u8) bool {
    return regionName(line) != null or isEndRegion(line);
}

/// The NAME of a line containing `#region NAME`.
fn regionName(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, "#region") orelse return null;
    const rest = line[at + "#region".len ..];
    if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) return null;
    const name_start = std.mem.trimStart(u8, rest, " \t");
    var n: usize = 0;
    while (n < name_start.len and (std.ascii.isAlphanumeric(name_start[n]) or name_start[n] == '-' or name_start[n] == '_' or name_start[n] == '.')) n += 1;
    if (n == 0) return null;
    return name_start[0..n];
}

fn isEndRegion(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "#endregion") != null;
}

fn dedent(arena: Allocator, lines: []const []const u8) Allocator.Error![]const u8 {
    var common: ?usize = null;
    for (lines) |l| {
        var n: usize = 0;
        while (n < l.len and (l[n] == ' ' or l[n] == '\t')) n += 1;
        if (n == l.len) continue; // blank lines do not count
        common = if (common) |c| @min(c, n) else n;
    }
    const cut = common orelse 0;
    var out: std.ArrayList(u8) = .empty;
    for (lines) |l| {
        try out.appendSlice(arena, if (l.len >= cut) l[cut..] else "");
        try out.append(arena, '\n');
    }
    return out.items;
}

/// The code block language for a file name, from its extension.
pub fn language(path: []const u8) []const u8 {
    const base = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    const ext = base[dot + 1 ..];
    const map = [_][2][]const u8{
        .{ "h", "c" },         .{ "hpp", "cpp" },  .{ "cc", "cpp" },  .{ "rs", "rust" },
        .{ "py", "python" },   .{ "mjs", "js" },   .{ "cjs", "js" },  .{ "yml", "yaml" },
        .{ "md", "markdown" }, .{ "htm", "html" }, .{ "bash", "sh" }, .{ "zsh", "sh" },
        .{ "zon", "zig" },     .{ "tsx", "ts" },   .{ "jsx", "js" },
    };
    for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    return ext;
}

const testing = std.testing;

test "parseSpec" {
    const a = parseSpec("  src/a.zig  ").?;
    try testing.expectEqualStrings("src/a.zig", a.path);
    try testing.expect(a.select == .all);
    const b = parseSpec("src/a.zig:3-5 {1} title=\"A\"").?;
    try testing.expectEqualStrings("src/a.zig", b.path);
    try testing.expectEqual(@as(usize, 3), b.select.lines.start);
    try testing.expectEqual(@as(?usize, 5), b.select.lines.end);
    try testing.expectEqualStrings("{1} title=\"A\"", b.meta);
    try testing.expectEqual(@as(?usize, null), parseSpec("a.zig:7-").?.select.lines.end);
    try testing.expectEqual(@as(?usize, 7), parseSpec("a.zig:7").?.select.lines.end);
    try testing.expectEqualStrings("main", parseSpec("a.zig#main").?.select.region);
    // A colon that is not a range stays in the path.
    try testing.expectEqualStrings("c:x", parseSpec("c:x").?.path);
    try testing.expect(parseSpec("   ") == null);
    try testing.expect(parseSpec("#x") == null);
}

test "extract lines and regions" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn main() void {
        \\    // #region body
        \\    const a = 1;
        \\    // #region inner
        \\    _ = a;
        \\    // #endregion
        \\    // #endregion body
        \\}
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("const a = 1;\n_ = a;\n", try extract(a, src, .{ .region = "body" }));
    try testing.expectEqualStrings("_ = a;\n", try extract(a, src, .{ .region = "inner" }));
    try testing.expectEqualStrings("pub fn main() void {\n    // #region body\n", try extract(a, src, .{ .lines = .{ .start = 3, .end = 4 } }));
    try testing.expectEqualStrings("}\n", try extract(a, src, .{ .lines = .{ .start = 10, .end = null } }));
    // The whole file drops region markers.
    try testing.expect(std.mem.indexOf(u8, try extract(a, src, .all), "#region") == null);
    try testing.expectError(error.BadRange, extract(a, src, .{ .lines = .{ .start = 9, .end = 11 } }));
    try testing.expectError(error.BadRange, extract(a, src, .{ .lines = .{ .start = 0, .end = 1 } }));
    try testing.expectError(error.NoSuchRegion, extract(a, src, .{ .region = "bod" }));
    try testing.expectError(error.UnclosedRegion, extract(a, "# #region x\nhi\n", .{ .region = "x" }));
}

test "language" {
    try testing.expectEqualStrings("zig", language("src/main.zig"));
    try testing.expectEqualStrings("rust", language("a/b.rs"));
    try testing.expectEqualStrings("yaml", language("_config.yml"));
    try testing.expectEqualStrings("", language("Makefile"));
    try testing.expectEqualStrings("", language("dir.v2/Makefile"));
}
