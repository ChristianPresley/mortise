//! Jekyll's front matter defaults: a `defaults:` list in `_config.yml`
//! whose entries give front matter values to the files their scope
//! matches.
//!
//! ```yaml
//! defaults:
//!   - scope:
//!       path: ""
//!       type: posts
//!     values:
//!       layout: post
//! ```
//!
//! The list nests deeper than the frontmatter subset allows, so `split`
//! takes it out of the config text and `parse` reads it with the YAML
//! reader. A file's own front matter wins over every default.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frontmatter = @import("frontmatter.zig");
const yaml = @import("yaml.zig");

pub const Default = struct {
    /// A path relative to the site, "" for every file. With `*`, a pattern
    /// for the whole path, where `*` matches within one path segment.
    path: []const u8 = "",
    /// `posts`, `pages`, or a collection's name; null for every type.
    type: ?[]const u8 = null,
    values: frontmatter.Map = .{},
};

pub const Split = struct {
    /// The config without the `defaults:` block, whose lines are blank so
    /// the other lines keep their numbers.
    rest: []const u8,
    /// The block, from its `defaults:` line, or null without one.
    block: ?[]const u8 = null,
    /// 1-based number of the `defaults:` line.
    line: usize = 0,
};

/// Takes a top-level `defaults:` key and the lines under it (indented, or
/// starting with `-`) out of config text.
pub fn split(arena: Allocator, src: []const u8) Allocator.Error!Split {
    var start: ?usize = null;
    var end: usize = src.len;
    var line_start: usize = 0;
    var number: usize = 0;
    var line_no: usize = 0;
    while (line_start < src.len) {
        const nl = std.mem.indexOfScalarPos(u8, src, line_start, '\n');
        const line_end = nl orelse src.len;
        const line = std.mem.trimEnd(u8, src[line_start..line_end], "\r");
        number += 1;
        if (start == null) {
            if (isDefaultsKey(line)) {
                start = line_start;
                line_no = number;
            }
        } else if (line.len > 0 and line[0] != ' ' and line[0] != '-' and line[0] != '#') {
            end = line_start;
            break;
        }
        line_start = if (nl) |n| n + 1 else src.len;
    }
    const s = start orelse return .{ .rest = src };
    const block = src[s..end];
    // Keep the line endings so the remaining lines keep their numbers.
    var rest: std.ArrayList(u8) = .empty;
    try rest.appendSlice(arena, src[0..s]);
    for (block) |c| if (c == '\n') try rest.append(arena, '\n');
    try rest.appendSlice(arena, src[end..]);
    return .{ .rest = rest.items, .block = block, .line = line_no };
}

fn isDefaultsKey(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "defaults:")) return false;
    const after = std.mem.trim(u8, line["defaults:".len..], " \t");
    return after.len == 0 or after[0] == '#';
}

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidDefaults};

/// Reads a block from `split`. `first_line` is the number of its first
/// line in the config, for messages.
pub fn parse(arena: Allocator, block: []const u8, first_line: usize, diag: *Diagnostic) Error![]const Default {
    var yd: yaml.Diagnostic = .{};
    const doc = yaml.parse(arena, block, &yd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidYaml => {
            diag.* = .{ .line = first_line + yd.line - 1, .message = yd.message };
            return error.InvalidDefaults;
        },
    };
    const fail = struct {
        fn f(d: *Diagnostic, line: usize, message: []const u8) Error {
            d.* = .{ .line = line, .message = message };
            return error.InvalidDefaults;
        }
    }.f;
    const shape = "'defaults' must be a list of entries with 'scope' and 'values', such as:\n  - scope:\n      type: posts\n    values:\n      layout: post";
    const list = switch (doc.object.get("defaults") orelse .null) {
        .null => return &.{},
        .array => |a| a.items,
        else => return fail(diag, first_line, shape),
    };
    var out: std.ArrayList(Default) = .empty;
    for (list) |item| {
        if (item != .object) return fail(diag, first_line, shape);
        var d: Default = .{};
        if (item.object.get("scope")) |scope| switch (scope) {
            .null => {},
            .object => |o| {
                if (o.get("path")) |p| switch (p) {
                    .string => |s| d.path = trimPath(s),
                    .null => {},
                    else => return fail(diag, first_line, "a default's 'scope.path' must be a string such as \"_posts\""),
                };
                if (o.get("type")) |t| switch (t) {
                    .string => |s| d.type = s,
                    .null => {},
                    else => return fail(diag, first_line, "a default's 'scope.type' must be posts, pages or a collection's name"),
                };
            },
            else => return fail(diag, first_line, shape),
        };
        const values = item.object.get("values") orelse return fail(diag, first_line, "each default needs 'values'");
        if (values != .object) return fail(diag, first_line, "a default's 'values' must be a mapping such as 'layout: post'");
        d.values = try toMap(arena, values.object);
        try out.append(arena, d);
    }
    return out.items;
}

/// Without a leading `./` or `/` and a trailing `/`.
fn trimPath(p: []const u8) []const u8 {
    var s = p;
    if (std.mem.startsWith(u8, s, "./")) s = s[2..];
    s = std.mem.trimStart(u8, s, "/");
    return std.mem.trimEnd(u8, s, "/");
}

fn toMap(arena: Allocator, o: std.json.ObjectMap) Allocator.Error!frontmatter.Map {
    var entries: std.ArrayList(frontmatter.Entry) = .empty;
    var it = o.iterator();
    while (it.next()) |e| {
        // A null value sets nothing.
        const v = try toValue(arena, e.value_ptr.*) orelse continue;
        try entries.append(arena, .{ .key = e.key_ptr.*, .value = v });
    }
    return .{ .entries = entries.items };
}

fn toValue(arena: Allocator, v: std.json.Value) Allocator.Error!?frontmatter.Value {
    return switch (v) {
        .null => null,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string, .string => |s| .{ .string = s },
        .array => |a| blk: {
            var items: std.ArrayList(frontmatter.Value) = .empty;
            for (a.items) |x| if (try toValue(arena, x)) |item| try items.append(arena, item);
            break :blk .{ .list = items.items };
        },
        .object => |o| .{ .map = try toMap(arena, o) },
    };
}

/// Whether `d` applies to the file at site path `path` of type `kind`.
pub fn matches(d: Default, path: []const u8, kind: []const u8) bool {
    if (d.type) |t| if (!std.mem.eql(u8, t, kind)) return false;
    if (d.path.len == 0) return true;
    if (std.mem.indexOfScalar(u8, d.path, '*') != null) return glob(d.path, path);
    if (!std.mem.startsWith(u8, path, d.path)) return false;
    return path.len == d.path.len or path[d.path.len] == '/';
}

/// `*` matches any run of characters other than `/`.
fn glob(pattern: []const u8, s: []const u8) bool {
    if (pattern.len == 0) return s.len == 0;
    if (pattern[0] == '*') {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (glob(pattern[1..], s[i..])) return true;
            if (i >= s.len or s[i] == '/') return false;
        }
    }
    return s.len > 0 and s[0] == pattern[0] and glob(pattern[1..], s[1..]);
}

/// Jekyll's rule for which of two matching scopes wins: the longer path,
/// then one with a type over one without, then the later one.
fn hasPrecedence(old: Default, new: Default) bool {
    if (new.path.len != old.path.len) return new.path.len >= old.path.len;
    if (new.type != null) return true;
    return old.type == null;
}

/// `fields` over the defaults that match: a file's own front matter wins.
pub fn apply(arena: Allocator, all: []const Default, path: []const u8, kind: []const u8, fields: frontmatter.Map) Allocator.Error!frontmatter.Map {
    var merged: frontmatter.Map = .{};
    var winner: ?Default = null;
    var any = false;
    for (all) |d| {
        if (!matches(d, path, kind)) continue;
        any = true;
        if (winner == null or hasPrecedence(winner.?, d)) {
            merged = try deepMerge(arena, merged, d.values);
            winner = d;
        } else {
            merged = try deepMerge(arena, d.values, merged);
        }
    }
    if (!any) return fields;
    return deepMerge(arena, merged, fields);
}

/// `over` on top of `base`; mappings both hold are merged key by key.
fn deepMerge(arena: Allocator, base: frontmatter.Map, over: frontmatter.Map) Allocator.Error!frontmatter.Map {
    var entries: std.ArrayList(frontmatter.Entry) = .empty;
    try entries.appendSlice(arena, base.entries);
    for (over.entries) |e| {
        for (entries.items) |*existing| {
            if (!std.mem.eql(u8, existing.key, e.key)) continue;
            existing.value = if (existing.value == .map and e.value == .map)
                .{ .map = try deepMerge(arena, existing.value.map, e.value.map) }
            else
                e.value;
            break;
        } else try entries.append(arena, e);
    }
    return .{ .entries = entries.items };
}

const testing = std.testing;

test "split takes the defaults block out and keeps line numbers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "title: T\ndefaults:\n  - scope:\n      type: posts\n    values:\n      layout: post\n# note\nliquid: true\n";
    const s = try split(a, src);
    // A comment at the margin is part of the block.
    try testing.expectEqualStrings("title: T\n\n\n\n\n\n\nliquid: true\n", s.rest);
    try testing.expectEqual(@as(usize, 2), s.line);
    try testing.expect(std.mem.startsWith(u8, s.block.?, "defaults:\n"));
    // A sequence at the key's own indentation belongs to it too.
    const s2 = try split(a, "defaults:\n- values:\n    a: 1\nz: 2");
    try testing.expectEqualStrings("\n\n\nz: 2", s2.rest);
    const none = try split(a, "title: T\ndefaults_x: 1\n");
    try testing.expect(none.block == null);
}

test "parse reads scopes and values" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const ds = try parse(a, "defaults:\n  - scope:\n      path: \"/notes/\"\n    values:\n      layout: note\n      author: {name: Ada}\n      x: null\n  - values:\n      comments: true\n", 4, &diag);
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqualStrings("notes", ds[0].path);
    try testing.expect(ds[0].type == null);
    try testing.expectEqualStrings("note", ds[0].values.get("layout").?.string);
    try testing.expectEqualStrings("Ada", ds[0].values.get("author").?.map.get("name").?.string);
    try testing.expect(ds[0].values.get("x") == null);
    try testing.expect(ds[1].values.get("comments").?.boolean);

    try testing.expectError(error.InvalidDefaults, parse(a, "defaults:\n  - scope: {}\n", 7, &diag));
    try testing.expectEqualStrings("each default needs 'values'", diag.message);
    try testing.expectEqual(@as(usize, 7), diag.line);
    try testing.expectError(error.InvalidDefaults, parse(a, "defaults:\n  - values: [1\n", 7, &diag));
    try testing.expectEqual(@as(usize, 8), diag.line);
}

test "matches by path and type" {
    const posts: Default = .{ .type = "posts" };
    try testing.expect(matches(posts, "_posts/2024-01-01-a.md", "posts"));
    try testing.expect(!matches(posts, "about.md", "pages"));
    const notes: Default = .{ .path = "notes" };
    try testing.expect(matches(notes, "notes/a.md", "pages"));
    try testing.expect(matches(notes, "notes", "pages"));
    try testing.expect(!matches(notes, "notes2/a.md", "pages"));
    const pattern: Default = .{ .path = "docs/*/index.md" };
    try testing.expect(matches(pattern, "docs/v1/index.md", "pages"));
    try testing.expect(!matches(pattern, "docs/v1/x/index.md", "pages"));
}

test "apply: longer paths and typed scopes win, front matter wins over all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = frontmatter.Entry;
    const all = [_]Default{
        .{ .path = "notes", .values = .{ .entries = &[_]e{.{ .key = "layout", .value = .{ .string = "note" } }} } },
        // Shorter path, later: loses to the one above.
        .{ .values = .{ .entries = &[_]e{
            .{ .key = "layout", .value = .{ .string = "default" } },
            .{ .key = "author", .value = .{ .map = .{ .entries = &[_]e{ .{ .key = "name", .value = .{ .string = "Ada" } }, .{ .key = "site", .value = .{ .string = "a.org" } } } } } },
        } } },
    };
    const own: frontmatter.Map = .{ .entries = &[_]e{
        .{ .key = "title", .value = .{ .string = "T" } },
        .{ .key = "author", .value = .{ .map = .{ .entries = &[_]e{.{ .key = "name", .value = .{ .string = "Bo" } }} } } },
    } };
    const m = try apply(a, &all, "notes/x.md", "pages", own);
    try testing.expectEqualStrings("note", m.get("layout").?.string);
    try testing.expectEqualStrings("T", m.get("title").?.string);
    try testing.expectEqualStrings("Bo", m.get("author").?.map.get("name").?.string);
    try testing.expectEqualStrings("a.org", m.get("author").?.map.get("site").?.string);
    const other = try apply(a, &all, "about.md", "pages", .{});
    try testing.expectEqualStrings("default", other.get("layout").?.string);
    // Equal paths: a typed scope wins over an untyped one.
    const typed = [_]Default{
        .{ .type = "posts", .values = .{ .entries = &[_]e{.{ .key = "layout", .value = .{ .string = "post" } }} } },
        .{ .values = .{ .entries = &[_]e{.{ .key = "layout", .value = .{ .string = "default" } }} } },
    };
    try testing.expectEqualStrings("post", (try apply(a, &typed, "_posts/a.md", "posts", .{})).get("layout").?.string);
}
