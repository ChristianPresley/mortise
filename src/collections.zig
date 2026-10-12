//! Jekyll collections: folders such as `_recipes/` named in `_config.yml`
//! whose documents are listed as `site.recipes` and, with `output: true`,
//! published as pages.
//!
//! ```yaml
//! collections:
//!   recipes:
//!     output: true
//!     sort_by: title
//!   staff:
//! ```
//!
//! `collections: [recipes, staff]` names collections with the default
//! settings. The mapping form nests deeper than the frontmatter subset
//! allows, so it is read with the YAML reader (`yaml.takeBlock`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const yaml = @import("yaml.zig");

pub const Collection = struct {
    /// The folder's name without its leading `_`.
    label: []const u8,
    /// Whether its documents are written as pages. Off by default, as in
    /// Jekyll.
    output: bool = false,
    /// The front matter field that orders `site.LABEL`; by `date`, then
    /// path, without one.
    sort_by: ?[]const u8 = null,
    /// A permalink template for its documents' URLs.
    permalink: ?[]const u8 = null,

    /// `_LABEL/`, the folder holding the documents.
    pub fn dir(c: Collection, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "_{s}/", .{c.label});
    }
};

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidCollections};

/// Names `site` already uses, which a collection would hide.
const reserved = [_][]const u8{
    "posts",     "pages",      "data",        "tags",          "nav",          "apis",       "menus",
    "versions",  "taxonomies", "collections", "time",          "lang",         "languages",  "i18n",
    "baseurl",   "icon_tags",  "search_box",  "scheme_toggle", "static_files", "categories", "html_pages",
    "documents",
};

/// Checks a collection's name: letters, digits, `-` and `_`, and not a
/// name `site` already uses. Returns the problem, or null.
pub fn badLabel(label: []const u8) ?[]const u8 {
    if (label.len == 0) return "a collection needs a name";
    for (label) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) {
        return "a collection's name may hold only letters, digits, '-' and '_'";
    };
    for (reserved) |r| if (std.mem.eql(u8, r, label)) return "that name is taken by site's own variables; choose another";
    return null;
}

fn fail(diag: *Diagnostic, line: usize, message: []const u8) Error {
    diag.* = .{ .line = line, .message = message };
    return error.InvalidCollections;
}

/// Names from the flow form, `collections: [a, b]`.
pub fn fromNames(arena: Allocator, names: []const []const u8, line: usize, diag: *Diagnostic) Error![]const Collection {
    var out: std.ArrayList(Collection) = .empty;
    for (names) |n| {
        if (badLabel(n)) |msg| return fail(diag, line, msg);
        try out.append(arena, .{ .label = n });
    }
    return out.items;
}

/// Reads a `collections:` block from `yaml.takeBlock`. `first_line` is
/// the number of its first line in the config, for messages.
pub fn parse(arena: Allocator, block: []const u8, first_line: usize, diag: *Diagnostic) Error![]const Collection {
    var yd: yaml.Diagnostic = .{};
    const doc = yaml.parse(arena, block, &yd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidYaml => return fail(diag, first_line + yd.line - 1, yd.message),
    };
    const shape = "'collections' must list names, or map each name to its settings such as 'output: true'";
    var out: std.ArrayList(Collection) = .empty;
    switch (doc.object.get("collections") orelse .null) {
        .null => {},
        .array => |a| for (a.items) |item| {
            if (item != .string) return fail(diag, first_line, shape);
            if (badLabel(item.string)) |msg| return fail(diag, first_line, msg);
            try out.append(arena, .{ .label = item.string });
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                var c: Collection = .{ .label = e.key_ptr.* };
                if (badLabel(c.label)) |msg| return fail(diag, first_line, msg);
                switch (e.value_ptr.*) {
                    .null => {},
                    .object => |settings| {
                        var sit = settings.iterator();
                        while (sit.next()) |s| {
                            const key = s.key_ptr.*;
                            const v = s.value_ptr.*;
                            if (std.mem.eql(u8, key, "output")) {
                                if (v != .bool) return fail(diag, first_line, "a collection's 'output' must be true or false");
                                c.output = v.bool;
                            } else if (std.mem.eql(u8, key, "sort_by")) {
                                if (v != .string) return fail(diag, first_line, "a collection's 'sort_by' must name a front matter field");
                                c.sort_by = v.string;
                            } else if (std.mem.eql(u8, key, "permalink")) {
                                if (v != .string) return fail(diag, first_line, "a collection's 'permalink' must be a string such as /:collection/:name/");
                                c.permalink = v.string;
                            } else {
                                // Other settings are the collection's own
                                // values in Jekyll; Mortise has no use for
                                // them yet.
                                return fail(diag, first_line, try std.fmt.allocPrint(arena, "a collection's settings are output, sort_by and permalink, not '{s}'", .{key}));
                            }
                        }
                    },
                    else => return fail(diag, first_line, shape),
                }
                try out.append(arena, c);
            }
        },
        else => return fail(diag, first_line, shape),
    }
    return out.items;
}

/// The collection whose folder holds site path `path`, if any.
pub fn find(all: []const Collection, path: []const u8) ?*const Collection {
    if (path.len < 2 or path[0] != '_') return null;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    for (all) |*c| if (std.mem.eql(u8, c.label, path[1..slash])) return c;
    return null;
}

const testing = std.testing;

test "parse reads names and settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const cs = try parse(a, "collections:\n  recipes:\n    output: true\n    sort_by: title\n  staff:\n", 3, &diag);
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqualStrings("recipes", cs[0].label);
    try testing.expect(cs[0].output);
    try testing.expectEqualStrings("title", cs[0].sort_by.?);
    try testing.expectEqualStrings("staff", cs[1].label);
    try testing.expect(!cs[1].output);
    const list = try parse(a, "collections:\n  - recipes\n  - staff\n", 3, &diag);
    try testing.expectEqual(@as(usize, 2), list.len);

    try testing.expectError(error.InvalidCollections, parse(a, "collections:\n  posts:\n    output: true\n", 3, &diag));
    try testing.expectEqualStrings("that name is taken by site's own variables; choose another", diag.message);
    try testing.expectError(error.InvalidCollections, parse(a, "collections:\n  a:\n    output: yes please\n", 3, &diag));
    try testing.expectError(error.InvalidCollections, parse(a, "collections:\n  a:\n    layout: x\n", 3, &diag));
    try testing.expectError(error.InvalidCollections, parse(a, "collections:\n  a b:\n", 3, &diag));
}

test "find matches the collection's folder" {
    const all = [_]Collection{ .{ .label = "recipes" }, .{ .label = "staff" } };
    try testing.expectEqualStrings("staff", find(&all, "_staff/ada.md").?.label);
    try testing.expect(find(&all, "_recipes") == null);
    try testing.expect(find(&all, "recipes/a.md") == null);
    try testing.expect(find(&all, "_other/a.md") == null);
}
