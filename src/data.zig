//! Data files: `_data/**/*.yml` and `_data/**/*.json`, exposed to templates
//! as `site.data`. `_data/authors.json` becomes `site.data.authors`, and
//! `_data/menus/main.yml` becomes `site.data.menus.main`.
//!
//! YAML files use the frontmatter subset (a top-level mapping). JSON files
//! may hold any JSON value, including lists of objects, which the YAML
//! subset cannot express.

const std = @import("std");
const Allocator = std.mem.Allocator;
const template = @import("template.zig");
const frontmatter = @import("frontmatter.zig");
const sitepath = @import("path.zig");
const Value = template.Value;
const Entry = template.Entry;

pub const dir_prefix = "_data/";

pub const Error = error{InvalidData} || Allocator.Error;

/// Where a data file failed to parse.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// Whether `path` is a data file the site loads.
pub fn isDataFile(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir_prefix)) return false;
    const ext = sitepath.extension(path);
    return std.mem.eql(u8, ext, ".yml") or std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".json");
}

/// Parses one data file's contents.
pub fn parse(arena: Allocator, path: []const u8, contents: []const u8, diag: *Diagnostic) Error!Value {
    if (std.mem.eql(u8, sitepath.extension(path), ".json")) return parseJson(arena, contents, diag);
    var fd: frontmatter.Diagnostic = .{};
    const map = frontmatter.parseFile(arena, contents, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => {
            diag.* = .{ .line = fd.line, .message = fd.message };
            return error.InvalidData;
        },
    };
    return fromFrontmatter(arena, .{ .map = map });
}

fn parseJson(arena: Allocator, contents: []const u8, diag: *Diagnostic) Error!Value {
    var scanner = std.json.Scanner.initCompleteInput(arena, contents);
    var jd: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&jd);
    const v = std.json.parseFromTokenSourceLeaky(std.json.Value, arena, &scanner, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.* = .{
                .line = @intCast(jd.getLine()),
                .message = std.fmt.allocPrint(arena, "invalid JSON ({s})", .{@errorName(err)}) catch "invalid JSON",
            };
            return error.InvalidData;
        },
    };
    return fromJson(arena, v);
}

fn fromJson(arena: Allocator, v: std.json.Value) Allocator.Error!Value {
    return switch (v) {
        .null => .nil,
        .bool => |b| .{ .boolean = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string, .string => |s| .{ .string = s },
        .array => |a| blk: {
            const out = try arena.alloc(Value, a.items.len);
            for (a.items, out) |item, *o| o.* = try fromJson(arena, item);
            break :blk .{ .list = out };
        },
        .object => |o| blk: {
            const out = try arena.alloc(Entry, o.count());
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                out[i] = .{ .key = e.key_ptr.*, .value = try fromJson(arena, e.value_ptr.*) };
            }
            break :blk .{ .object = .{ .entries = out } };
        },
    };
}

/// Converts a frontmatter value to a template value.
pub fn fromFrontmatter(arena: Allocator, v: frontmatter.Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = s },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .boolean => |x| .{ .boolean = x },
        .list => |l| blk: {
            const out = try arena.alloc(Value, l.len);
            for (l, out) |item, *o| o.* = try fromFrontmatter(arena, item);
            break :blk .{ .list = out };
        },
        .map => |m| blk: {
            const out = try arena.alloc(Entry, m.entries.len);
            for (m.entries, out) |e, *o| o.* = .{ .key = e.key, .value = try fromFrontmatter(arena, e.value) };
            break :blk .{ .object = .{ .entries = out } };
        },
    };
}

/// Builds `site.data` from parsed files, nesting by directory.
pub const Tree = struct {
    arena: Allocator,
    root: Node = .{},

    const Node = struct {
        names: std.ArrayList([]const u8) = .empty,
        children: std.ArrayList(Child) = .empty,
    };
    const Child = union(enum) { node: *Node, value: Value };

    /// Adds the value of data file `path` (a site path under `_data/`).
    /// Returns false if the name clashes with another data file or directory.
    pub fn add(t: *Tree, path: []const u8, value: Value) Allocator.Error!bool {
        const rel = path[dir_prefix.len..];
        const without_ext = rel[0 .. rel.len - sitepath.extension(rel).len];
        var node = &t.root;
        var it = std.mem.splitScalar(u8, without_ext, '/');
        var seg = it.next().?;
        while (it.next()) |next| : (seg = next) {
            node = switch (try t.child(node, seg)) {
                .node => |n| n,
                .value => return false,
            };
        }
        for (node.names.items) |n| if (std.mem.eql(u8, n, seg)) return false;
        try node.names.append(t.arena, seg);
        try node.children.append(t.arena, .{ .value = value });
        return true;
    }

    /// The child of `node` named `name`, created as a directory if missing.
    fn child(t: *Tree, node: *Node, name: []const u8) Allocator.Error!Child {
        for (node.names.items, node.children.items) |n, c| {
            if (std.mem.eql(u8, n, name)) return c;
        }
        const n = try t.arena.create(Node);
        n.* = .{};
        try node.names.append(t.arena, name);
        try node.children.append(t.arena, .{ .node = n });
        return .{ .node = n };
    }

    pub fn toObject(t: *Tree) Allocator.Error!Value {
        return toValue(t.arena, &t.root);
    }

    fn toValue(arena: Allocator, node: *const Node) Allocator.Error!Value {
        const out = try arena.alloc(Entry, node.names.items.len);
        for (node.names.items, node.children.items, out) |n, c, *o| {
            o.* = .{ .key = n, .value = switch (c) {
                .value => |v| v,
                .node => |sub| try toValue(arena, sub),
            } };
        }
        return .{ .object = .{ .entries = out } };
    }
};

const testing = std.testing;

test "json and yaml data files nest into one object" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};

    const nav = try parse(arena, "_data/nav.json", "[{\"title\": \"Home\", \"url\": \"/\"}, {\"title\": \"About\", \"url\": \"/about/\"}]", &diag);
    const site = try parse(arena, "_data/menus/footer.yml", "copyright: 2024\nlinks: [a, b]\n", &diag);
    var tree: Tree = .{ .arena = arena };
    try testing.expect(try tree.add("_data/nav.json", nav));
    try testing.expect(try tree.add("_data/menus/footer.yml", site));
    try testing.expect(!try tree.add("_data/nav.yml", .nil));

    const data = (try tree.toObject()).object;
    const items = data.get("nav").?.list;
    try testing.expectEqualStrings("About", items[1].object.get("title").?.string);
    const footer = data.get("menus").?.object.get("footer").?.object;
    try testing.expectEqual(@as(i64, 2024), footer.get("copyright").?.int);
}

test "data file errors carry a line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidData, parse(arena_state.allocator(), "_data/a.json", "{\n\"a\": 1,\n}", &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectError(error.InvalidData, parse(arena_state.allocator(), "_data/a.yml", "a: 1\na: 2\n", &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    try testing.expect(isDataFile("_data/x/y.json"));
    try testing.expect(!isDataFile("_data/readme.md"));
}
