//! Jekyll permalinks: URL templates such as `/:categories/:year/:title/`
//! and the named styles that stand for them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const datetime = @import("datetime.zig");

/// The template a named style stands for, as in Jekyll, or null when
/// `name` is not a style.
pub fn style(name: []const u8) ?[]const u8 {
    const styles = [_][2][]const u8{
        .{ "date", "/:categories/:year/:month/:day/:title:output_ext" },
        .{ "pretty", "/:categories/:year/:month/:day/:title/" },
        .{ "ordinal", "/:categories/:year/:y_day/:title:output_ext" },
        .{ "weekdate", "/:categories/:year/W:week/:short_day/:title:output_ext" },
        .{ "none", "/:categories/:title:output_ext" },
    };
    for (styles) |s| if (std.mem.eql(u8, s[0], name)) return s[1];
    return null;
}

/// A placeholder's value.
pub const Var = struct { name: []const u8, value: []const u8 };

/// The date placeholders, from `dt`.
pub fn dateVars(arena: Allocator, dt: datetime.DateTime) Allocator.Error![]const Var {
    const formats = [_][2][]const u8{
        .{ "year", "%Y" },       .{ "month", "%m" },      .{ "day", "%d" },
        .{ "hour", "%H" },       .{ "minute", "%M" },     .{ "second", "%S" },
        .{ "i_day", "%-d" },     .{ "i_month", "%-m" },   .{ "short_month", "%b" },
        .{ "long_month", "%B" }, .{ "short_year", "%y" }, .{ "y_day", "%j" },
        .{ "w_year", "%G" },     .{ "week", "%V" },       .{ "w_day", "%u" },
        .{ "short_day", "%a" },  .{ "long_day", "%A" },
    };
    const vars = try arena.alloc(Var, formats.len);
    for (formats, vars) |f, *v| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        var unknown: u8 = 0;
        datetime.format(&aw.writer, dt, f[1], .ruby, &unknown) catch return error.OutOfMemory;
        v.* = .{ .name = f[0], .value = aw.written() };
    }
    return vars;
}

/// Replaces each `:name` in `template` with its value from `vars`, the
/// longest name that matches, and collapses the `//` that empty values
/// leave. A `:name` with no value stays as written.
pub fn expand(arena: Allocator, template: []const u8, vars: []const []const Var) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != ':') {
            try out.append(arena, template[i]);
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < template.len and (std.ascii.isLower(template[end]) or template[end] == '_')) end += 1;
        // The longest known name: `:titlefoo` is `:title` then `foo`.
        var n = end;
        const found: ?[]const u8 = while (n > i + 1) : (n -= 1) {
            if (lookup(vars, template[i + 1 .. n])) |v| break v;
        } else null;
        if (found) |v| {
            try out.appendSlice(arena, v);
            i = n;
        } else {
            try out.append(arena, ':');
            i += 1;
        }
    }
    // Empty values, such as no categories, leave doubled slashes.
    var clean: std.ArrayList(u8) = .empty;
    if (out.items.len == 0 or out.items[0] != '/') try clean.append(arena, '/');
    for (out.items) |c| {
        if (c == '/' and clean.items.len > 0 and clean.items[clean.items.len - 1] == '/') continue;
        try clean.append(arena, c);
    }
    return clean.items;
}

fn lookup(vars: []const []const Var, name: []const u8) ?[]const u8 {
    for (vars) |set| for (set) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}

/// Whether a template has placeholders, and so is not a plain URL.
pub fn hasPlaceholders(template: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, template, i, ':')) |c| : (i = c + 1) {
        if (c + 1 < template.len and std.ascii.isLower(template[c + 1])) return true;
    }
    return false;
}

const testing = std.testing;

test "styles expand as in Jekyll" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dates = try dateVars(a, .{ .year = 2024, .month = 1, .day = 5 });
    const post = [_]Var{ .{ .name = "title", .value = "hello-world" }, .{ .name = "categories", .value = "tech/zig" }, .{ .name = "output_ext", .value = ".html" } };
    const vars = [_][]const Var{ dates, &post };
    try testing.expectEqualStrings("/tech/zig/2024/01/05/hello-world.html", try expand(a, style("date").?, &vars));
    try testing.expectEqualStrings("/tech/zig/2024/01/05/hello-world/", try expand(a, style("pretty").?, &vars));
    try testing.expectEqualStrings("/tech/zig/2024/005/hello-world.html", try expand(a, style("ordinal").?, &vars));
    try testing.expectEqualStrings("/tech/zig/2024/W01/Fri/hello-world.html", try expand(a, style("weekdate").?, &vars));
    try testing.expectEqualStrings("/tech/zig/hello-world.html", try expand(a, style("none").?, &vars));
    try testing.expect(style("fancy") == null);
}

test "expand: empty values, longest names, unknown names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dates = try dateVars(a, .{ .year = 2024, .month = 3, .day = 9 });
    const post = [_]Var{ .{ .name = "title", .value = "x" }, .{ .name = "categories", .value = "" } };
    const vars = [_][]const Var{ dates, &post };
    try testing.expectEqualStrings("/2024/3/9/x/", try expand(a, "/:categories/:year/:i_month/:i_day/:title/", &vars));
    try testing.expectEqualStrings("/blog/x-24.html", try expand(a, "blog/:title-:short_year.html", &vars));
    try testing.expectEqualStrings("/Mar/March/x:nope/", try expand(a, "/:short_month/:long_month/:title:nope/", &vars));
    try testing.expect(hasPlaceholders("/:title/"));
    try testing.expect(!hasPlaceholders("/about/"));
    try testing.expect(!hasPlaceholders("/a:1/"));
}
