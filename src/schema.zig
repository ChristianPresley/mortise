//! Frontmatter schemas: files in `_schemas/` describe the fields pages
//! must or may have, and the build checks every page against its schema.
//!
//!   _schemas/posts.yml   every post
//!   _schemas/pages.yml   every page that is not a post
//!   _schemas/docs.yml    pages under docs/ (instead of pages.yml)
//!
//! Each key is a field name; its value is a map of rules:
//!
//!   title:
//!     type: string        string, int, number, bool, date, list or map
//!     required: true
//!   status:
//!     type: string
//!     enum: [draft, review, published]
//!     default: draft      filled in when the page leaves the field out
//!   weight:
//!     type: int
//!     min: 0
//!     max: 100
//!
//! A field the schema does not mention is allowed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const frontmatter = @import("frontmatter.zig");
const Value = frontmatter.Value;

pub const dir_prefix = "_schemas/";

pub const Type = enum { string, int, number, bool, date, list, map };

pub const Field = struct {
    name: []const u8,
    type: ?Type = null,
    required: bool = false,
    @"enum": ?[]const Value = null,
    default: ?Value = null,
    min: ?f64 = null,
    max: ?f64 = null,
};

pub const Schema = struct {
    /// The schema file, for messages.
    path: []const u8,
    fields: []const Field,
};

pub const Diagnostic = struct {
    /// The field with the problem; empty when it is the file.
    key: []const u8 = "",
    message: []const u8 = "",
};

pub const Error = error{InvalidSchema} || Allocator.Error;

/// Reads a schema file's parsed frontmatter map.
pub fn parse(arena: Allocator, path: []const u8, map: frontmatter.Map, diag: *Diagnostic) Error!Schema {
    var fields: std.ArrayList(Field) = .empty;
    for (map.entries) |e| {
        var f: Field = .{ .name = e.key };
        if (e.value != .map) return fail(diag, e.key, "must be a map of rules such as `type: string`");
        for (e.value.map.entries) |rule| {
            const v = rule.value;
            if (std.mem.eql(u8, rule.key, "type")) {
                f.type = if (v == .string) std.meta.stringToEnum(Type, v.string) else null;
                if (f.type == null) return fail(diag, e.key, "has a 'type' that is not string, int, number, bool, date, list or map");
            } else if (std.mem.eql(u8, rule.key, "required")) {
                if (v != .boolean) return fail(diag, e.key, "has a 'required' that is not true or false");
                f.required = v.boolean;
            } else if (std.mem.eql(u8, rule.key, "enum")) {
                if (v != .list or v.list.len == 0) return fail(diag, e.key, "has an 'enum' that is not a list of values");
                f.@"enum" = v.list;
            } else if (std.mem.eql(u8, rule.key, "default")) {
                f.default = v;
            } else if (std.mem.eql(u8, rule.key, "min") or std.mem.eql(u8, rule.key, "max")) {
                const n: f64 = switch (v) {
                    .int => |i| @floatFromInt(i),
                    .float => |x| x,
                    else => return fail(diag, e.key, "has a 'min' or 'max' that is not a number"),
                };
                if (rule.key[1] == 'i') f.min = n else f.max = n;
            } else {
                diag.* = .{ .key = e.key, .message = try std.fmt.allocPrint(arena, "has an unknown rule '{s}'; the rules are type, required, enum, default, min and max", .{rule.key}) };
                return error.InvalidSchema;
            }
        }
        // A default must itself pass the field's rules.
        if (f.default) |d| if (try problem(arena, f, d)) |msg| {
            diag.* = .{ .key = e.key, .message = try std.fmt.allocPrint(arena, "has a default that {s}", .{msg}) };
            return error.InvalidSchema;
        };
        try fields.append(arena, f);
    }
    return .{ .path = path, .fields = fields.items };
}

fn fail(diag: *Diagnostic, key: []const u8, message: []const u8) Error {
    diag.* = .{ .key = key, .message = message };
    return error.InvalidSchema;
}

pub const Problem = struct {
    /// The field; its line is the field's line in the page.
    key: []const u8,
    message: []const u8,
    /// Whether the field is missing, so there is no line to point at.
    missing: bool = false,
};

/// Checks `fields` against the schema. Returns the first problem, or
/// null; on success, `out` holds the fields with defaults filled in.
pub fn check(arena: Allocator, s: Schema, fields: frontmatter.Map, out: *frontmatter.Map) Allocator.Error!?Problem {
    var entries: std.ArrayList(frontmatter.Entry) = .empty;
    try entries.appendSlice(arena, fields.entries);
    for (s.fields) |f| {
        const v = fields.get(f.name) orelse {
            if (f.default) |d| {
                try entries.append(arena, .{ .key = f.name, .value = d });
                continue;
            }
            if (f.required) return .{ .key = f.name, .message = try std.fmt.allocPrint(arena, "'{s}' is required by {s}", .{ f.name, s.path }), .missing = true };
            continue;
        };
        if (try problem(arena, f, v)) |msg| {
            return .{ .key = f.name, .message = try std.fmt.allocPrint(arena, "'{s}' {s} ({s})", .{ f.name, msg, s.path }) };
        }
    }
    out.* = .{ .entries = entries.items };
    return null;
}

/// What is wrong with `v` for field `f`, or null.
fn problem(arena: Allocator, f: Field, v: Value) Allocator.Error!?[]const u8 {
    if (f.type) |t| {
        const ok = switch (t) {
            .string => v == .string,
            .int => v == .int,
            .number => v == .int or v == .float,
            .bool => v == .boolean,
            .date => v == .string and isDate(v.string),
            .list => v == .list,
            .map => v == .map,
        };
        if (!ok) return try std.fmt.allocPrint(arena, "must be {s}", .{switch (t) {
            .string => "text",
            .int => "a whole number",
            .number => "a number",
            .bool => "true or false",
            .date => "a date such as 2024-01-05",
            .list => "a list",
            .map => "a map",
        }});
    }
    if (f.@"enum") |choices| {
        for (choices) |c| {
            if (c.eql(v)) break;
        } else {
            var aw: std.Io.Writer.Allocating = .init(arena);
            for (choices, 0..) |c, i| {
                if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
                writeScalar(&aw.writer, c) catch return error.OutOfMemory;
            }
            return try std.fmt.allocPrint(arena, "must be one of: {s}", .{aw.written()});
        }
    }
    const n: ?f64 = switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |x| x,
        else => null,
    };
    if (n) |x| {
        if (f.min) |m| if (x < m) return try std.fmt.allocPrint(arena, "must be at least {d}", .{m});
        if (f.max) |m| if (x > m) return try std.fmt.allocPrint(arena, "must be at most {d}", .{m});
    }
    return null;
}

fn writeScalar(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        .int => |i| try w.print("{d}", .{i}),
        .float => |x| try w.print("{d}", .{x}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        else => try w.writeAll("..."),
    }
}

fn isDate(s: []const u8) bool {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    return s.len == 10 or s[10] == ' ' or s[10] == 'T';
}

/// The schema as JSON Schema (draft 2020-12), for editors that validate
/// frontmatter.
pub fn jsonSchema(arena: Allocator, s: Schema, title: []const u8) Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    (blk: {
        w.writeAll("{\n  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",\n  \"title\": ") catch |e| break :blk e;
        std.json.Stringify.value(title, .{}, w) catch |e| break :blk e;
        w.writeAll(",\n  \"type\": \"object\",\n  \"properties\": {") catch |e| break :blk e;
        for (s.fields, 0..) |f, i| {
            w.writeAll(if (i == 0) "\n    " else ",\n    ") catch |e| break :blk e;
            std.json.Stringify.value(f.name, .{}, w) catch |e| break :blk e;
            w.writeAll(": {") catch |e| break :blk e;
            var first = true;
            if (f.type) |t| {
                const name = switch (t) {
                    .string, .date => "string",
                    .int => "integer",
                    .number => "number",
                    .bool => "boolean",
                    .list => "array",
                    .map => "object",
                };
                w.print("\"type\": \"{s}\"", .{name}) catch |e| break :blk e;
                if (t == .date) w.writeAll(", \"pattern\": \"^\\\\d{4}-\\\\d{2}-\\\\d{2}\"") catch |e| break :blk e;
                first = false;
            }
            if (f.@"enum") |choices| {
                w.writeAll(if (first) "\"enum\": [" else ", \"enum\": [") catch |e| break :blk e;
                for (choices, 0..) |c, n| {
                    if (n > 0) w.writeAll(", ") catch |e| break :blk e;
                    writeJsonScalar(w, c) catch |e| break :blk e;
                }
                w.writeAll("]") catch |e| break :blk e;
                first = false;
            }
            if (f.default) |d| {
                w.writeAll(if (first) "\"default\": " else ", \"default\": ") catch |e| break :blk e;
                writeJsonScalar(w, d) catch |e| break :blk e;
                first = false;
            }
            if (f.min) |m| {
                w.print("{s}\"minimum\": {d}", .{ if (first) "" else ", ", m }) catch |e| break :blk e;
                first = false;
            }
            if (f.max) |m| w.print("{s}\"maximum\": {d}", .{ if (first) "" else ", ", m }) catch |e| break :blk e;
            w.writeAll("}") catch |e| break :blk e;
        }
        w.writeAll("\n  },\n  \"required\": [") catch |e| break :blk e;
        var n: usize = 0;
        for (s.fields) |f| {
            if (!f.required) continue;
            if (n > 0) w.writeAll(", ") catch |e| break :blk e;
            std.json.Stringify.value(f.name, .{}, w) catch |e| break :blk e;
            n += 1;
        }
        w.writeAll("]\n}\n") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.written();
}

fn writeJsonScalar(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .string => |s| std.json.Stringify.value(s, .{}, w) catch return error.WriteFailed,
        .int => |i| try w.print("{d}", .{i}),
        .float => |x| try w.print("{d}", .{x}),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        else => try w.writeAll("null"),
    }
}

const testing = std.testing;

fn parseMap(arena: Allocator, src: []const u8) !frontmatter.Map {
    var fd: frontmatter.Diagnostic = .{};
    return frontmatter.parseFile(arena, src, &fd);
}

const test_schema =
    \\title:
    \\  type: string
    \\  required: true
    \\status:
    \\  type: string
    \\  enum: [draft, review, published]
    \\  default: draft
    \\weight:
    \\  type: int
    \\  min: 0
    \\  max: 100
    \\date:
    \\  type: date
    \\
;

test "check: required fields, types, enums, defaults and ranges" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const s = try parse(a, "_schemas/posts.yml", try parseMap(a, test_schema), &d);
    var out: frontmatter.Map = .{};

    try testing.expect(try check(a, s, try parseMap(a, "title: Hi\nweight: 3\nextra: kept\n"), &out) == null);
    try testing.expectEqualStrings("draft", out.get("status").?.string);
    try testing.expectEqualStrings("kept", out.get("extra").?.string);

    const missing = (try check(a, s, try parseMap(a, "weight: 3\n"), &out)).?;
    try testing.expect(missing.missing);
    try testing.expectEqualStrings("'title' is required by _schemas/posts.yml", missing.message);

    const bad_enum = (try check(a, s, try parseMap(a, "title: x\nstatus: done\n"), &out)).?;
    try testing.expectEqualStrings("'status' must be one of: draft, review, published (_schemas/posts.yml)", bad_enum.message);
    const bad_type = (try check(a, s, try parseMap(a, "title: 3\n"), &out)).?;
    try testing.expectEqualStrings("'title' must be text (_schemas/posts.yml)", bad_type.message);
    const too_big = (try check(a, s, try parseMap(a, "title: x\nweight: 101\n"), &out)).?;
    try testing.expectEqualStrings("'weight' must be at most 100 (_schemas/posts.yml)", too_big.message);
    const bad_date = (try check(a, s, try parseMap(a, "title: x\ndate: soon\n"), &out)).?;
    try testing.expectEqualStrings("'date' must be a date such as 2024-01-05 (_schemas/posts.yml)", bad_date.message);
}

test "parse rejects broken schemas" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidSchema, parse(a, "s", try parseMap(a, "title: string\n"), &d));
    try testing.expectEqualStrings("title", d.key);
    try testing.expectError(error.InvalidSchema, parse(a, "s", try parseMap(a, "x:\n  type: text\n"), &d));
    try testing.expectError(error.InvalidSchema, parse(a, "s", try parseMap(a, "x:\n  type: int\n  default: no\n"), &d));
    try testing.expectEqualStrings("has a default that must be a whole number", d.message);
    try testing.expectError(error.InvalidSchema, parse(a, "s", try parseMap(a, "x:\n  requird: true\n"), &d));
}

test "jsonSchema" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const s = try parse(a, "_schemas/posts.yml", try parseMap(a, test_schema), &d);
    const out = try jsonSchema(a, s, "posts");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    const props = parsed.object.get("properties").?.object;
    try testing.expectEqualStrings("integer", props.get("weight").?.object.get("type").?.string);
    try testing.expectEqual(@as(i64, 100), props.get("weight").?.object.get("maximum").?.integer);
    try testing.expectEqualStrings("title", parsed.object.get("required").?.array.items[0].string);
}
