//! Frontmatter: a restricted YAML subset between `---` lines at the top of
//! a content file.
//!
//! Supported:
//!   - A mapping of keys (`[A-Za-z0-9_-]+`) to values at the top level.
//!   - Scalars: strings (plain, "double" or 'single' quoted), integers,
//!     floats, and the booleans `true` and `false`.
//!   - Lists of scalars, as a block (`- item` lines) or flow (`[a, b]`).
//!   - One nesting level: a top-level key may hold a mapping of scalars or
//!     lists.
//!   - `#` comments on their own line or after a value.
//!
//! Everything else (anchors, aliases, tags, block scalars `|` and `>`,
//! flow mappings, null, deeper nesting, tabs in indentation, duplicate keys)
//! is rejected with the line number of the offending line.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    list: []const Value,
    map: Map,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .int => |i| i == b.int,
            .float => |f| f == b.float,
            .boolean => |x| x == b.boolean,
            .list => |l| blk: {
                if (l.len != b.list.len) break :blk false;
                for (l, b.list) |x, y| if (!x.eql(y)) break :blk false;
                break :blk true;
            },
            .map => |m| m.eql(b.map),
        };
    }
};

pub const Entry = struct { key: []const u8, value: Value };

/// An ordered mapping. Lookups are linear; frontmatter maps are small.
pub const Map = struct {
    entries: []const Entry = &.{},

    pub fn get(m: Map, key: []const u8) ?Value {
        for (m.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    pub fn eql(a: Map, b: Map) bool {
        if (a.entries.len != b.entries.len) return false;
        for (a.entries, b.entries) |x, y| {
            if (!std.mem.eql(u8, x.key, y.key) or !x.value.eql(y.value)) return false;
        }
        return true;
    }
};

pub const Document = struct {
    fields: Map,
    /// The content after the closing `---` line (or the whole file if it has
    /// no frontmatter).
    body: []const u8,
    /// 1-based line number of the first body line in the original file.
    body_line: usize,
};

/// Where and why parsing failed. `message` is static or arena-allocated.
pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{InvalidFrontmatter} || Allocator.Error;

const Line = struct {
    /// 1-based line number in the file.
    number: usize,
    indent: usize,
    /// Text after the indentation, with any trailing `\r` removed.
    text: []const u8,
};

const Parser = struct {
    arena: Allocator,
    diag: *Diagnostic,

    fn fail(p: Parser, line: usize, comptime fmt: []const u8, args: anytype) Error {
        p.diag.line = line;
        p.diag.message = std.fmt.allocPrint(p.arena, fmt, args) catch "out of memory while reporting an error";
        return error.InvalidFrontmatter;
    }
};

/// Splits `src` into frontmatter and body and parses the frontmatter.
/// On `error.InvalidFrontmatter`, `diag` holds the line and message.
pub fn parse(arena: Allocator, src_in: []const u8, diag: *Diagnostic) Error!Document {
    const p: Parser = .{ .arena = arena, .diag = diag };
    var src = src_in;
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];

    var it = std.mem.splitScalar(u8, src, '\n');
    const first = it.next() orelse "";
    if (!isDelimiter(first)) return .{ .fields = .{}, .body = src, .body_line = 1 };

    var lines: std.ArrayList(Line) = .empty;
    var number: usize = 1;
    const closed = while (it.next()) |raw| {
        number += 1;
        if (isDelimiter(raw)) break true;
        const text = std.mem.trimEnd(u8, raw, "\r");
        var indent: usize = 0;
        while (indent < text.len and (text[indent] == ' ' or text[indent] == '\t')) : (indent += 1) {
            if (text[indent] == '\t') return p.fail(number, "tabs are not allowed in frontmatter indentation; use spaces", .{});
        }
        const rest = text[indent..];
        // Skip blank and comment-only lines.
        if (rest.len == 0 or rest[0] == '#') continue;
        try lines.append(arena, .{ .number = number, .indent = indent, .text = std.mem.trimEnd(u8, rest, " ") });
    } else false;
    if (!closed) return p.fail(1, "frontmatter is not closed; add a '---' line after it", .{});

    const body_start = @min(it.index orelse src.len, src.len);
    const fields = try parseMapping(p, lines.items, 0, true);
    return .{ .fields = fields, .body = src[body_start..], .body_line = number + 1 };
}

fn isDelimiter(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \r"), "---");
}

/// Parses lines that all sit at `lines[0].indent` as `key: value` pairs.
fn parseMapping(p: Parser, lines: []const Line, depth: usize, top: bool) Error!Map {
    var entries: std.ArrayList(Entry) = .empty;
    if (lines.len == 0) return .{};
    const indent = lines[0].indent;
    if (top and indent != 0) return p.fail(lines[0].number, "top-level keys must not be indented", .{});

    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        if (line.indent != indent) return p.fail(line.number, "unexpected indentation", .{});
        if (std.mem.startsWith(u8, line.text, "- ") or std.mem.eql(u8, line.text, "-")) {
            return p.fail(line.number, "expected 'key: value', found a list item", .{});
        }
        const colon = findKeyColon(line.text) orelse
            return p.fail(line.number, "expected 'key: value'", .{});
        const key = line.text[0..colon];
        try checkKey(p, line.number, key);
        for (entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return p.fail(line.number, "duplicate key '{s}'", .{key});
        }
        const rest = std.mem.trimStart(u8, line.text[colon + 1 ..], " ");

        // A value on the same line.
        if (rest.len != 0 and rest[0] != '#') {
            const value = try parseInlineValue(p, line.number, rest);
            try entries.append(p.arena, .{ .key = key, .value = value });
            i += 1;
            continue;
        }

        // A block value on the following, more-indented lines.
        var j = i + 1;
        while (j < lines.len and lines[j].indent > indent) j += 1;
        const block = lines[i + 1 .. j];
        if (block.len == 0) {
            return p.fail(line.number, "key '{s}' has no value; use \"\" for an empty string", .{key});
        }
        const is_list = isListItem(block[0].text);
        if (depth >= 1 and !is_list) {
            return p.fail(block[0].number, "only one level of nesting is supported", .{});
        }
        const value: Value = if (is_list)
            .{ .list = try parseBlockList(p, block) }
        else
            .{ .map = try parseMapping(p, block, depth + 1, false) };
        try entries.append(p.arena, .{ .key = key, .value = value });
        i = j;
    }
    return .{ .entries = entries.items };
}

fn isListItem(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "- ") or std.mem.eql(u8, text, "-");
}

fn parseBlockList(p: Parser, lines: []const Line) Error![]const Value {
    var items: std.ArrayList(Value) = .empty;
    const indent = lines[0].indent;
    for (lines) |line| {
        if (line.indent != indent) return p.fail(line.number, "unexpected indentation in list", .{});
        if (!isListItem(line.text)) return p.fail(line.number, "expected a list item starting with '- '", .{});
        const rest = std.mem.trimStart(u8, line.text[1..], " ");
        if (rest.len == 0 or rest[0] == '#') return p.fail(line.number, "empty list item; use \"\" for an empty string", .{});
        if (rest[0] == '[') return p.fail(line.number, "lists inside lists are not supported", .{});
        if (findKeyColon(rest) != null) return p.fail(line.number, "mappings inside lists are not supported", .{});
        try items.append(p.arena, try parseScalar(p, line.number, rest));
    }
    return items.items;
}

/// Finds the `:` that ends a key: followed by a space or the end of line.
fn findKeyColon(text: []const u8) ?usize {
    if (text.len == 0 or text[0] == '"' or text[0] == '\'') return null;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) return i;
        if (text[i] == ' ' and i + 1 < text.len and text[i + 1] == '#') return null;
    }
    return null;
}

fn checkKey(p: Parser, line: usize, key: []const u8) Error!void {
    if (key.len == 0) return p.fail(line, "empty key", .{});
    for (key) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
            return p.fail(line, "invalid key '{s}': keys may contain only letters, digits, '_' and '-'", .{key});
        }
    }
}

fn parseInlineValue(p: Parser, line: usize, text: []const u8) Error!Value {
    if (text[0] == '[') {
        return .{ .list = try parseFlowList(p, line, text) };
    }
    return parseScalar(p, line, text);
}

fn parseFlowList(p: Parser, line: usize, text: []const u8) Error![]const Value {
    var items: std.ArrayList(Value) = .empty;
    var i: usize = 1;
    var expect_item = true;
    while (true) {
        while (i < text.len and text[i] == ' ') i += 1;
        if (i >= text.len) return p.fail(line, "unterminated list; add ']'", .{});
        const c = text[i];
        if (c == ']') {
            if (expect_item and items.items.len > 0) return p.fail(line, "trailing ',' in list", .{});
            i += 1;
            break;
        }
        if (!expect_item) {
            if (c != ',') return p.fail(line, "expected ',' or ']' in list", .{});
            i += 1;
            expect_item = true;
            continue;
        }
        if (c == ',') return p.fail(line, "empty item in list", .{});
        if (c == '[') return p.fail(line, "lists inside lists are not supported", .{});
        if (c == '{') return p.fail(line, "mappings inside lists are not supported", .{});

        const start = i;
        if (c == '"' or c == '\'') {
            i = (try quotedEnd(p, line, text, i)) + 1;
        } else {
            while (i < text.len and text[i] != ',' and text[i] != ']') i += 1;
        }
        const raw = std.mem.trimEnd(u8, text[start..i], " ");
        try items.append(p.arena, try parseScalar(p, line, raw));
        expect_item = false;
    }
    try expectEnd(p, line, text[i..]);
    return items.items;
}

/// Index of the closing quote of the quoted string starting at `text[start]`.
fn quotedEnd(p: Parser, line: usize, text: []const u8, start: usize) Error!usize {
    const q = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (q == '"' and text[i] == '\\') {
            i += 1;
            continue;
        }
        if (text[i] == q) {
            // '' inside a single-quoted string is an escaped quote.
            if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1;
                continue;
            }
            return i;
        }
    }
    return p.fail(line, "unterminated quoted string", .{});
}

/// Only whitespace or a comment may follow a complete value.
fn expectEnd(p: Parser, line: usize, rest: []const u8) Error!void {
    const t = std.mem.trimStart(u8, rest, " ");
    if (t.len == 0) return;
    if (t[0] == '#' and t.len < rest.len) return;
    return p.fail(line, "unexpected text after value: '{s}'", .{t});
}

fn parseScalar(p: Parser, line: usize, text: []const u8) Error!Value {
    const c = text[0];
    if (c == '"' or c == '\'') {
        const end = try quotedEnd(p, line, text, 0);
        try expectEnd(p, line, text[end + 1 ..]);
        return .{ .string = try unquote(p, line, text[0 .. end + 1]) };
    }
    switch (c) {
        '{' => return p.fail(line, "flow mappings ('{{...}}') are not supported", .{}),
        '&' => return p.fail(line, "anchors ('&') are not supported", .{}),
        '*' => return p.fail(line, "aliases ('*') are not supported", .{}),
        '!' => return p.fail(line, "tags ('!') are not supported", .{}),
        '|', '>' => return p.fail(line, "block scalars ('|' and '>') are not supported", .{}),
        '%', '@', '`', ']', '}', ',' => return p.fail(line, "a value may not start with '{c}'; quote it", .{c}),
        else => {},
    }

    // Plain scalar: ends at a comment.
    var end = text.len;
    if (std.mem.indexOf(u8, text, " #")) |k| end = k;
    const plain = std.mem.trimEnd(u8, text[0..end], " ");
    if (std.mem.indexOf(u8, plain, ": ") != null or std.mem.endsWith(u8, plain, ":")) {
        return p.fail(line, "a plain value may not contain ': '; quote it", .{});
    }

    if (std.mem.eql(u8, plain, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, plain, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, plain, "null") or std.mem.eql(u8, plain, "~")) {
        return p.fail(line, "null is not supported; leave the key out instead", .{});
    }
    if (looksLikeInt(plain)) {
        const n = std.fmt.parseInt(i64, plain, 10) catch
            return p.fail(line, "integer '{s}' is out of range", .{plain});
        return .{ .int = n };
    }
    if (looksLikeFloat(plain)) {
        const f = std.fmt.parseFloat(f64, plain) catch
            return p.fail(line, "invalid number '{s}'", .{plain});
        return .{ .float = f };
    }
    return .{ .string = plain };
}

fn looksLikeInt(s: []const u8) bool {
    const digits = if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s[1..] else s;
    if (digits.len == 0) return false;
    for (digits) |d| if (!std.ascii.isDigit(d)) return false;
    return true;
}

fn looksLikeFloat(s: []const u8) bool {
    const body = if (s.len > 0 and (s[0] == '-' or s[0] == '+')) s[1..] else s;
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse return false;
    return looksLikeInt(body[0..dot]) and looksLikeInt(body[dot + 1 ..]) and
        body[0] != '-' and body[0] != '+';
}

fn unquote(p: Parser, line: usize, quoted: []const u8) Error![]const u8 {
    const q = quoted[0];
    const inner = quoted[1 .. quoted.len - 1];
    if (q == '\'') {
        if (std.mem.indexOf(u8, inner, "''") == null) return inner;
        return std.mem.replaceOwned(u8, p.arena, inner, "''", "'");
    }
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return inner;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] != '\\') {
            try out.append(p.arena, inner[i]);
            continue;
        }
        i += 1;
        const e = inner[i];
        try out.append(p.arena, switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'n' => '\n',
            't' => '\t',
            else => return p.fail(line, "unsupported escape '\\{c}' in string", .{e}),
        });
    }
    return out.items;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseOk(arena: Allocator, src: []const u8) !Document {
    var diag: Diagnostic = .{};
    return parse(arena, src, &diag) catch |err| {
        std.debug.print("unexpected error at line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
}

fn expectFail(src: []const u8, line: usize, message_part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidFrontmatter, parse(arena.allocator(), src, &diag));
    testing.expectEqual(line, diag.line) catch |err| {
        std.debug.print("message: {s}\n", .{diag.message});
        return err;
    };
    if (std.mem.indexOf(u8, diag.message, message_part) == null) {
        std.debug.print("expected message containing '{s}', got '{s}'\n", .{ message_part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "no frontmatter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseOk(arena.allocator(), "# Hello\n");
    try testing.expectEqual(@as(usize, 0), doc.fields.entries.len);
    try testing.expectEqualStrings("# Hello\n", doc.body);
    try testing.expectEqual(@as(usize, 1), doc.body_line);
}

test "scalars" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseOk(arena.allocator(),
        \\---
        \\title: Hello, world   # trailing comment
        \\quoted: "a \"b\" \\ c\n"
        \\single: 'it''s'
        \\date: 2024-01-05
        \\count: 42
        \\neg: -7
        \\ratio: 1.5
        \\draft: false
        \\yes_is_text: yes
        \\url: https://example.com/a#frag
        \\
        \\# a comment line
        \\---
        \\Body here.
        \\
    );
    const f = doc.fields;
    try testing.expectEqualStrings("Hello, world", f.get("title").?.string);
    try testing.expectEqualStrings("a \"b\" \\ c\n", f.get("quoted").?.string);
    try testing.expectEqualStrings("it's", f.get("single").?.string);
    try testing.expectEqualStrings("2024-01-05", f.get("date").?.string);
    try testing.expectEqual(@as(i64, 42), f.get("count").?.int);
    try testing.expectEqual(@as(i64, -7), f.get("neg").?.int);
    try testing.expectEqual(@as(f64, 1.5), f.get("ratio").?.float);
    try testing.expectEqual(false, f.get("draft").?.boolean);
    try testing.expectEqualStrings("yes", f.get("yes_is_text").?.string);
    try testing.expectEqualStrings("https://example.com/a#frag", f.get("url").?.string);
    try testing.expectEqualStrings("Body here.\n", doc.body);
    try testing.expectEqual(@as(usize, 15), doc.body_line);
}

test "lists and one level of nesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseOk(arena.allocator(),
        \\---
        \\tags: [zig, "static sites", 3]
        \\empty: []
        \\authors:
        \\  - Ada
        \\  - 'Grace'
        \\author:
        \\  name: Ada
        \\  links: [a, b]
        \\  langs:
        \\    - zig
        \\---
    );
    const f = doc.fields;
    const tags = f.get("tags").?.list;
    try testing.expectEqual(@as(usize, 3), tags.len);
    try testing.expectEqualStrings("static sites", tags[1].string);
    try testing.expectEqual(@as(i64, 3), tags[2].int);
    try testing.expectEqual(@as(usize, 0), f.get("empty").?.list.len);
    try testing.expectEqualStrings("Grace", f.get("authors").?.list[1].string);
    const author = f.get("author").?.map;
    try testing.expectEqualStrings("Ada", author.get("name").?.string);
    try testing.expectEqual(@as(usize, 2), author.get("links").?.list.len);
    try testing.expectEqualStrings("", doc.body);
}

test "CRLF and BOM" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const doc = try parseOk(arena.allocator(), "\xEF\xBB\xBF---\r\ntitle: Hi\r\n---\r\nBody\r\n");
    try testing.expectEqualStrings("Hi", doc.fields.get("title").?.string);
    try testing.expectEqualStrings("Body\r\n", doc.body);
}

test "errors carry line numbers" {
    try expectFail("---\ntitle: a\n", 1, "not closed");
    try expectFail("---\ntitle: a\ntitle: b\n---\n", 3, "duplicate key 'title'");
    try expectFail("---\n\ttitle: a\n---\n", 2, "tabs");
    try expectFail("---\n  title: a\n---\n", 2, "must not be indented");
    try expectFail("---\ntitle:\n---\n", 2, "has no value");
    try expectFail("---\na: &x 1\n---\n", 2, "anchors");
    try expectFail("---\na: *x\n---\n", 2, "aliases");
    try expectFail("---\na: |\n  text\n---\n", 2, "block scalars");
    try expectFail("---\na: {b: 1}\n---\n", 2, "flow mappings");
    try expectFail("---\na: null\n---\n", 2, "null");
    try expectFail("---\na: b: c\n---\n", 2, "quote it");
    try expectFail("---\na: [1, [2]]\n---\n", 2, "inside lists");
    try expectFail("---\na: [1, 2\n---\n", 2, "unterminated");
    try expectFail("---\na: [1,]\n---\n", 2, "trailing");
    try expectFail("---\na: \"x\" y\n---\n", 2, "unexpected text");
    try expectFail("---\na: \"\\q\"\n---\n", 2, "unsupported escape");
    try expectFail("---\na: 99999999999999999999\n---\n", 2, "out of range");
    try expectFail("---\nbad key: 1\n---\n", 2, "invalid key");
    try expectFail("---\njust text\n---\n", 2, "expected 'key: value'");
    try expectFail("---\n- a\n---\n", 2, "list item");
    try expectFail("---\na:\n  b:\n    c: 1\n---\n", 4, "one level of nesting");
    try expectFail("---\na:\n  - x\n  y: 1\n---\n", 4, "expected a list item");
    try expectFail("---\na:\n  - x\n   - y\n---\n", 4, "unexpected indentation");
    try expectFail("---\na:\n  -\n---\n", 3, "empty list item");
    try expectFail("---\na:\n  - k: v\n---\n", 3, "mappings inside lists");
}
