//! A YAML 1.2 reader for data documents such as OpenAPI specs. It
//! produces `std.json.Value`, keeping mapping keys in document order.
//!
//! Supported: block mappings and sequences at any depth (including a
//! sequence at its key's indentation and mappings inside sequence items),
//! flow collections (`[a, b]`, `{a: 1}`), plain, single- and double-quoted
//! scalars, literal and folded block scalars (`|`, `>`, with `+` and `-`
//! chomping), comments, anchors and aliases (`&a`, `*a`), merge keys
//! (`<<`), the `!!str` tag, and the `---` and `...` markers of a single
//! document. Not supported: several documents in one file, complex keys
//! (`? key`), and tags other than the core ones, which are ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidYaml};

/// Parses a YAML document.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!Value {
    var p: Parser = .{ .arena = arena, .diag = diag };
    try p.splitLines(src);
    p.skipBlank();
    if (p.i >= p.lines.items.len) return .null;
    const v = try p.node(0);
    p.skipBlank();
    if (p.i < p.lines.items.len) return p.fail(p.lines.items[p.i].number, "unexpected content; check the indentation", .{});
    return v;
}

const Line = struct {
    number: usize,
    indent: usize,
    /// The line after its indentation, without a trailing comment.
    text: []const u8,
    /// The line as written, for block scalars, which keep comments and
    /// spacing.
    raw: []const u8,
};

const Parser = struct {
    arena: Allocator,
    diag: *Diagnostic,
    lines: std.ArrayList(Line) = .empty,
    i: usize = 0,
    anchors: std.StringHashMapUnmanaged(Value) = .empty,

    fn fail(p: *Parser, line: usize, comptime fmt: []const u8, args: anytype) Error {
        p.diag.* = .{ .line = line, .message = try std.fmt.allocPrint(p.arena, fmt, args) };
        return error.InvalidYaml;
    }

    fn splitLines(p: *Parser, src_in: []const u8) Error!void {
        var src = src_in;
        if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..];
        var it = std.mem.splitScalar(u8, src, '\n');
        var n: usize = 0;
        while (it.next()) |raw_line| {
            n += 1;
            const raw = std.mem.trimEnd(u8, raw_line, "\r");
            var indent: usize = 0;
            while (indent < raw.len and raw[indent] == ' ') indent += 1;
            if (indent < raw.len and raw[indent] == '\t') return p.fail(n, "tabs cannot indent YAML; use spaces", .{});
            const text = std.mem.trimEnd(u8, stripComment(raw[indent..]), " \t");
            // Document markers; only one document is read.
            if (indent == 0 and (std.mem.eql(u8, text, "---") or std.mem.startsWith(u8, text, "--- "))) {
                if (p.lines.items.len > 0 and hasContent(p.lines.items)) return p.fail(n, "only one YAML document per file is supported", .{});
                const rest = std.mem.trim(u8, text[3..], " ");
                if (rest.len > 0) try p.lines.append(p.arena, .{ .number = n, .indent = 0, .text = rest, .raw = rest });
                continue;
            }
            if (indent == 0 and std.mem.eql(u8, text, "...")) break;
            if (indent == 0 and text.len > 0 and text[0] == '%') continue; // %YAML directives
            try p.lines.append(p.arena, .{ .number = n, .indent = indent, .text = text, .raw = raw });
        }
    }

    fn hasContent(lines: []const Line) bool {
        for (lines) |l| if (l.text.len > 0) return true;
        return false;
    }

    fn skipBlank(p: *Parser) void {
        while (p.i < p.lines.items.len and p.lines.items[p.i].text.len == 0) p.i += 1;
    }

    /// The node starting at the current line, indented at least `min`.
    fn node(p: *Parser, min: usize) Error!Value {
        p.skipBlank();
        const l = p.lines.items[p.i];
        if (l.indent < min) return .null;
        if (isSeqItem(l.text)) return p.sequence(l.indent);
        if (mapKey(l.text) != null) return p.mapping(l.indent);
        // A scalar or flow collection, possibly running over several lines.
        p.i += 1;
        return p.inlineValue(l.text, l.number, l.indent);
    }

    fn sequence(p: *Parser, indent: usize) Error!Value {
        var items: std.json.Array = .init(p.arena);
        while (true) {
            p.skipBlank();
            if (p.i >= p.lines.items.len) break;
            const l = p.lines.items[p.i];
            if (l.indent != indent or !isSeqItem(l.text)) {
                if (l.indent > indent) return p.fail(l.number, "unexpected indentation in a list", .{});
                break;
            }
            const rest = std.mem.trimStart(u8, l.text[1..], " ");
            if (rest.len == 0) {
                // The item is the block below.
                p.i += 1;
                p.skipBlank();
                const v = if (p.i < p.lines.items.len and p.lines.items[p.i].indent > indent) try p.node(indent + 1) else Value.null;
                try items.append(v);
                continue;
            }
            // `- key: value` starts a mapping whose keys line up after the
            // dash; `- - x` a nested list. Rewrite the line as if the item
            // started on its own line at that column.
            const column = indent + (l.text.len - rest.len);
            if (isSeqItem(rest) or mapKey(rest) != null) {
                p.lines.items[p.i] = .{ .number = l.number, .indent = column, .text = rest, .raw = l.raw };
                try items.append(try p.node(column));
                continue;
            }
            p.i += 1;
            try items.append(try p.inlineValue(rest, l.number, column));
        }
        return .{ .array = items };
    }

    fn mapping(p: *Parser, indent: usize) Error!Value {
        var map: std.json.ObjectMap = .empty;
        // Keys that came from a merge, which the mapping's own keys replace.
        var merged: std.StringHashMapUnmanaged(void) = .empty;
        while (true) {
            p.skipBlank();
            if (p.i >= p.lines.items.len) break;
            const l = p.lines.items[p.i];
            if (l.indent < indent) break;
            if (l.indent > indent) return p.fail(l.number, "unexpected indentation", .{});
            if (isSeqItem(l.text)) break;
            const k = mapKey(l.text) orelse return p.fail(l.number, "expected 'key: value'", .{});
            const key = try p.keyText(l.text[0..k.end], l.number);
            const rest = std.mem.trimStart(u8, l.text[k.after..], " ");
            p.i += 1;
            var value: Value = undefined;
            if (rest.len == 0 or isAnchorOnly(rest)) {
                // The value is the block below: deeper, or a list at the
                // key's own indentation.
                p.skipBlank();
                const below = if (p.i < p.lines.items.len) p.lines.items[p.i] else null;
                if (below) |b| {
                    if (b.indent > indent or (b.indent == indent and isSeqItem(b.text))) {
                        value = try p.node(if (b.indent > indent) indent + 1 else indent);
                    } else value = .null;
                } else value = .null;
                if (rest.len > 0) try p.anchors.put(p.arena, rest[1..], value);
            } else {
                value = try p.inlineValue(rest, l.number, indent);
            }
            if (std.mem.eql(u8, key, "<<")) {
                // Merge keys: the mapping (or list of mappings) supplies
                // keys this mapping does not set itself.
                const sources: []const Value = if (value == .array) value.array.items else &.{value};
                for (sources) |s| {
                    if (s != .object) return p.fail(l.number, "'<<' must merge a mapping", .{});
                    var it = s.object.iterator();
                    while (it.next()) |e| if (!map.contains(e.key_ptr.*)) {
                        try map.put(p.arena, e.key_ptr.*, e.value_ptr.*);
                        try merged.put(p.arena, e.key_ptr.*, {});
                    };
                }
                continue;
            }
            if (map.contains(key) and !merged.remove(key)) return p.fail(l.number, "duplicate key '{s}'", .{key});
            try map.put(p.arena, key, value);
        }
        return .{ .object = map };
    }

    fn keyText(p: *Parser, raw: []const u8, line: usize) Error![]const u8 {
        const t = std.mem.trim(u8, raw, " ");
        if (t.len > 0 and (t[0] == '"' or t[0] == '\'')) {
            const v = try p.quoted(t, line);
            return v;
        }
        return t;
    }

    /// A value written after `key:` or `- `: an anchor, alias, block
    /// scalar, flow collection, quoted or plain scalar. Flow collections
    /// and quoted and plain scalars may continue on following lines that
    /// are indented more than `indent`.
    fn inlineValue(p: *Parser, text_in: []const u8, line: usize, indent: usize) Error!Value {
        var text = text_in;
        var anchor: ?[]const u8 = null;
        if (text[0] == '&') {
            const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            anchor = text[1..end];
            text = std.mem.trimStart(u8, text[end..], " ");
        }
        var str_tag = false;
        if (std.mem.startsWith(u8, text, "!!")) {
            const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
            str_tag = std.mem.eql(u8, text[0..end], "!!str");
            text = std.mem.trimStart(u8, text[end..], " ");
        }
        const v: Value = blk: {
            if (text.len == 0) break :blk .null;
            if (text[0] == '*') {
                break :blk p.anchors.get(text[1..]) orelse return p.fail(line, "unknown alias '{s}'", .{text});
            }
            if (text[0] == '|' or text[0] == '>') break :blk try p.blockScalar(text, line, indent);
            if (text[0] == '[' or text[0] == '{') {
                const all = try p.continued(text, indent, true);
                var f: Flow = .{ .p = p, .s = all, .line = line };
                const fv = try f.value();
                f.skipSpace();
                if (f.i < f.s.len) return p.fail(line, "unexpected text after a flow collection", .{});
                break :blk fv;
            }
            if (text[0] == '"' or text[0] == '\'') {
                const all = try p.continued(text, indent, false);
                break :blk .{ .string = try p.quoted(all, line) };
            }
            const all = try p.continued(text, indent, false);
            break :blk if (str_tag) .{ .string = all } else try plainScalar(p.arena, all);
        };
        if (anchor) |a| try p.anchors.put(p.arena, a, v);
        return v;
    }

    /// `text` plus any continuation lines (indented more than `indent`),
    /// joined with spaces. For flow collections, lines are added until the
    /// brackets balance.
    fn continued(p: *Parser, text: []const u8, indent: usize, flow: bool) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.arena, text);
        while (p.i < p.lines.items.len) {
            if (flow and balanced(out.items)) break;
            const l = p.lines.items[p.i];
            if (l.text.len == 0) {
                if (flow) {
                    p.i += 1;
                    continue;
                }
                break;
            }
            // A flow collection runs until its brackets close, however its
            // lines are indented (JSON's closing brace sits at column 0).
            if (!flow and l.indent <= indent) break;
            if (!flow and (mapKey(l.text) != null or isSeqItem(l.text))) break;
            try out.append(p.arena, ' ');
            try out.appendSlice(p.arena, l.text);
            p.i += 1;
        }
        return out.items;
    }

    fn blockScalar(p: *Parser, header: []const u8, line: usize, parent: usize) Error!Value {
        const folded = header[0] == '>';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: ?usize = null;
        for (header[1..]) |c| switch (c) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '1'...'9' => explicit = c - '0',
            ' ' => {},
            else => return p.fail(line, "invalid block scalar header '{s}'", .{header}),
        };
        // The content's indentation is the first non-blank line's, unless
        // the header gives it.
        var indent: ?usize = if (explicit) |e| parent + e else null;
        var lines: std.ArrayList([]const u8) = .empty;
        while (p.i < p.lines.items.len) {
            const l = p.lines.items[p.i];
            const blank = std.mem.trim(u8, l.raw, " ").len == 0;
            if (!blank) {
                if (indent == null) {
                    if (l.indent <= parent) break;
                    indent = l.indent;
                }
                if (l.indent < indent.?) break;
            }
            try lines.append(p.arena, if (blank) "" else l.raw[indent.?..]);
            p.i += 1;
        }
        // Trailing blank lines belong to chomping, not content.
        var content_end = lines.items.len;
        while (content_end > 0 and lines.items[content_end - 1].len == 0) content_end -= 1;
        var out: std.ArrayList(u8) = .empty;
        for (lines.items[0..content_end], 0..) |text, k| {
            if (k > 0) {
                const prev = lines.items[k - 1];
                // Folding joins lines of normal text with a space. Each
                // blank line becomes one line break, and more-indented
                // lines keep theirs.
                if (!folded or text.len == 0) {
                    try out.append(p.arena, '\n');
                } else if (prev.len == 0) {
                    // The blank lines before gave the breaks.
                } else if (prev[0] == ' ' or text[0] == ' ') {
                    try out.append(p.arena, '\n');
                } else try out.append(p.arena, ' ');
            }
            try out.appendSlice(p.arena, text);
        }
        switch (chomp) {
            .strip => {},
            .clip => if (content_end > 0) try out.append(p.arena, '\n'),
            .keep => {
                if (content_end > 0) try out.append(p.arena, '\n');
                for (lines.items[content_end..]) |_| try out.append(p.arena, '\n');
            },
        }
        return .{ .string = out.items };
    }

    fn quoted(p: *Parser, t: []const u8, line: usize) Error![]const u8 {
        const q = t[0];
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 1;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (q == '\'' and c == '\'') {
                if (i + 1 < t.len and t[i + 1] == '\'') {
                    try out.append(p.arena, '\'');
                    i += 1;
                    continue;
                }
                if (std.mem.trim(u8, t[i + 1 ..], " ").len > 0) return p.fail(line, "unexpected text after a quoted string", .{});
                return out.items;
            }
            if (q == '"' and c == '"') {
                if (std.mem.trim(u8, t[i + 1 ..], " ").len > 0) return p.fail(line, "unexpected text after a quoted string", .{});
                return out.items;
            }
            if (q == '"' and c == '\\' and i + 1 < t.len) {
                i += 1;
                switch (t[i]) {
                    'n' => try out.append(p.arena, '\n'),
                    't' => try out.append(p.arena, '\t'),
                    'r' => try out.append(p.arena, '\r'),
                    '0' => try out.append(p.arena, 0),
                    '"', '\\', '/', ' ' => try out.append(p.arena, t[i]),
                    'x', 'u', 'U' => {
                        const len: usize = switch (t[i]) {
                            'x' => 2,
                            'u' => 4,
                            else => 8,
                        };
                        if (i + len >= t.len) return p.fail(line, "incomplete escape in a string", .{});
                        const cp = std.fmt.parseInt(u21, t[i + 1 .. i + 1 + len], 16) catch return p.fail(line, "invalid escape in a string", .{});
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return p.fail(line, "invalid character in a string", .{});
                        try out.appendSlice(p.arena, buf[0..n]);
                        i += len;
                    },
                    else => return p.fail(line, "unknown escape '\\{c}'", .{t[i]}),
                }
                continue;
            }
            try out.append(p.arena, c);
        }
        return p.fail(line, "a quoted string is not closed", .{});
    }
};

/// Flow collections: `[a, b]` and `{a: 1, b: [2]}`.
const Flow = struct {
    p: *Parser,
    s: []const u8,
    i: usize = 0,
    line: usize,

    fn skipSpace(f: *Flow) void {
        while (f.i < f.s.len and (f.s[f.i] == ' ' or f.s[f.i] == '\t')) f.i += 1;
    }

    fn value(f: *Flow) Error!Value {
        f.skipSpace();
        if (f.i >= f.s.len) return f.p.fail(f.line, "unexpected end of a flow collection", .{});
        switch (f.s[f.i]) {
            '[' => {
                f.i += 1;
                var items: std.json.Array = .init(f.p.arena);
                while (true) {
                    f.skipSpace();
                    if (f.i < f.s.len and f.s[f.i] == ']') {
                        f.i += 1;
                        return .{ .array = items };
                    }
                    try items.append(try f.value());
                    f.skipSpace();
                    if (f.i < f.s.len and f.s[f.i] == ',') {
                        f.i += 1;
                        continue;
                    }
                    if (f.i < f.s.len and f.s[f.i] == ']') continue;
                    return f.p.fail(f.line, "expected ',' or ']' in a list", .{});
                }
            },
            '{' => {
                f.i += 1;
                var map: std.json.ObjectMap = .empty;
                while (true) {
                    f.skipSpace();
                    if (f.i < f.s.len and f.s[f.i] == '}') {
                        f.i += 1;
                        return .{ .object = map };
                    }
                    const key_v = try f.scalar(true);
                    const key = if (key_v == .string) key_v.string else try std.json.Stringify.valueAlloc(f.p.arena, key_v, .{});
                    f.skipSpace();
                    var v: Value = .null;
                    if (f.i < f.s.len and f.s[f.i] == ':') {
                        f.i += 1;
                        f.skipSpace();
                        if (f.i < f.s.len and f.s[f.i] != ',' and f.s[f.i] != '}') v = try f.value();
                    }
                    try map.put(f.p.arena, key, v);
                    f.skipSpace();
                    if (f.i < f.s.len and f.s[f.i] == ',') {
                        f.i += 1;
                        continue;
                    }
                    if (f.i < f.s.len and f.s[f.i] == '}') continue;
                    return f.p.fail(f.line, "expected ',' or '}}' in a mapping", .{});
                }
            },
            else => return f.scalar(false),
        }
    }

    fn scalar(f: *Flow, is_key: bool) Error!Value {
        f.skipSpace();
        const s = f.s;
        if (f.i < s.len and (s[f.i] == '"' or s[f.i] == '\'')) {
            const q = s[f.i];
            var j = f.i + 1;
            while (j < s.len) : (j += 1) {
                if (s[j] == '\\' and q == '"') {
                    j += 1;
                    continue;
                }
                if (s[j] == q) {
                    if (q == '\'' and j + 1 < s.len and s[j + 1] == '\'') {
                        j += 1;
                        continue;
                    }
                    break;
                }
            }
            if (j >= s.len) return f.p.fail(f.line, "a quoted string is not closed", .{});
            const v = try f.p.quoted(s[f.i .. j + 1], f.line);
            f.i = j + 1;
            return .{ .string = v };
        }
        if (f.i < s.len and s[f.i] == '*') {
            const start = f.i + 1;
            var j = start;
            while (j < s.len and s[j] != ',' and s[j] != ']' and s[j] != '}' and s[j] != ' ') j += 1;
            f.i = j;
            return f.p.anchors.get(s[start..j]) orelse f.p.fail(f.line, "unknown alias '*{s}'", .{s[start..j]});
        }
        const start = f.i;
        while (f.i < s.len) : (f.i += 1) {
            const c = s[f.i];
            if (c == ',' or c == ']' or c == '}') break;
            if (c == ':' and (f.i + 1 >= s.len or s[f.i + 1] == ' ' or is_key)) break;
        }
        const text = std.mem.trim(u8, s[start..f.i], " ");
        return if (is_key) .{ .string = text } else plainScalar(f.p.arena, text);
    }
};

/// Removes a `#` comment, which must follow whitespace and not be inside
/// quotes.
fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        if ((c == '"' or c == '\'') and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '[' or s[i - 1] == '{' or s[i - 1] == ',' or s[i - 1] == ':')) {
            quote = c;
            continue;
        }
        if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) return s[0..i];
    }
    return s;
}

fn isSeqItem(t: []const u8) bool {
    return t.len > 0 and t[0] == '-' and (t.len == 1 or t[1] == ' ');
}

fn isAnchorOnly(t: []const u8) bool {
    return t.len > 1 and t[0] == '&' and std.mem.indexOfScalar(u8, t, ' ') == null;
}

const KeyEnd = struct { end: usize, after: usize };

/// Where the key of a `key: value` line ends, or null when the line is not
/// a mapping entry. Quoted keys may contain colons.
fn mapKey(t: []const u8) ?KeyEnd {
    if (t.len == 0 or t[0] == '[' or t[0] == '{' or (t[0] == '-' and isSeqItem(t))) return null;
    var i: usize = 0;
    if (t[0] == '"' or t[0] == '\'') {
        const q = t[0];
        i = 1;
        while (i < t.len and t[i] != q) : (i += 1) {
            if (q == '"' and t[i] == '\\') i += 1;
        }
        i += 1;
        if (i < t.len and t[i] == ':' and (i + 1 == t.len or t[i + 1] == ' ')) return .{ .end = i, .after = i + 1 };
        return null;
    }
    while (i < t.len) : (i += 1) {
        if (t[i] == ':' and (i + 1 == t.len or t[i + 1] == ' ')) return .{ .end = i, .after = i + 1 };
        if (t[i] == '#' and i > 0 and t[i - 1] == ' ') return null;
    }
    return null;
}

fn balanced(s: []const u8) bool {
    var depth: isize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => quote = c,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            else => {},
        }
    }
    return depth <= 0;
}

/// A plain scalar's value: null, a boolean, a number, or a string.
fn plainScalar(arena: Allocator, t: []const u8) Allocator.Error!Value {
    _ = arena;
    if (t.len == 0 or std.mem.eql(u8, t, "~") or std.mem.eql(u8, t, "null") or std.mem.eql(u8, t, "Null") or std.mem.eql(u8, t, "NULL")) return .null;
    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "True") or std.mem.eql(u8, t, "TRUE")) return .{ .bool = true };
    if (std.mem.eql(u8, t, "false") or std.mem.eql(u8, t, "False") or std.mem.eql(u8, t, "FALSE")) return .{ .bool = false };
    if (std.fmt.parseInt(i64, t, 10)) |n| return .{ .integer = n } else |_| {}
    if (std.mem.startsWith(u8, t, "0x")) if (std.fmt.parseInt(i64, t[2..], 16)) |n| return .{ .integer = n } else |_| {};
    if (std.mem.startsWith(u8, t, "0o")) if (std.fmt.parseInt(i64, t[2..], 8)) |n| return .{ .integer = n } else |_| {};
    for ([_]struct { []const u8, f64 }{ .{ ".inf", std.math.inf(f64) }, .{ "+.inf", std.math.inf(f64) }, .{ "-.inf", -std.math.inf(f64) }, .{ ".nan", std.math.nan(f64) } }) |sp| {
        if (std.ascii.eqlIgnoreCase(t, sp[0])) return .{ .float = sp[1] };
    }
    // Floats need a digit, so words like "e" or "-" stay strings.
    if (std.mem.indexOfAny(u8, t, "0123456789") != null and std.mem.indexOfNone(u8, t, "0123456789+-.eE") == null) {
        if (std.fmt.parseFloat(f64, t)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = t };
}

const testing = std.testing;

fn parseJson(arena: Allocator, src: []const u8) ![]const u8 {
    var diag: Diagnostic = .{};
    const v = parse(arena, src, &diag) catch |err| {
        std.debug.print("yaml error at line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

test "block mappings, sequences and scalars" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(
        \\{"openapi":"3.0.3","info":{"title":"Pets: an API","version":1.5},"tags":[{"name":"pets","x":null},"plain"],"list":["a","b"],"n":42,"ok":true,"q":"it's","esc":"a\nbé"}
    ,
        try parseJson(a,
            \\# A comment
            \\openapi: 3.0.3
            \\info:
            \\  title: "Pets: an API"   # trailing comment
            \\  version: 1.5
            \\tags:
            \\  - name: pets
            \\    x: ~
            \\  - plain
            \\list:
            \\- a
            \\- b
            \\n: 42
            \\ok: true
            \\q: 'it''s'
            \\esc: "a\nb\u00e9"
        ),
    );
}

test "flow collections, block scalars, anchors and merges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(
        \\{"flow":[1,"two",{"three":3,"four":[4]}],"lit":"line 1\n  indented\nline 3\n","fold":"one two\nthree","base":{"a":1,"b":2},"copy":{"a":1,"b":20},"alias":{"a":1,"b":2},"str":"123"}
    ,
        try parseJson(a,
            \\flow: [1, two, {three: 3,
            \\   four: [4]}]
            \\lit: |
            \\  line 1
            \\    indented
            \\  line 3
            \\fold: >-
            \\  one
            \\  two
            \\
            \\  three
            \\base: &b
            \\  a: 1
            \\  b: 2
            \\copy:
            \\  <<: *b
            \\  b: 20
            \\alias: *b
            \\str: !!str 123
        ),
    );
}

test "errors name the line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "a: 1\n\tb: 2", 2, "tabs cannot indent" },
        .{ "a: 1\na: 2", 2, "duplicate key 'a'" },
        .{ "a:\n  b: 1\n c: 2", 3, "unexpected" },
        .{ "a: *nope", 1, "unknown alias" },
        .{ "a: \"open", 1, "not closed" },
        .{ "a: [1, 2", 1, "expected ',' or ']'" },
        .{ "a: 1\n---\nb: 2", 2, "only one YAML document" },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidYaml, parse(a, c[0], &diag));
        try testing.expectEqual(c[1], diag.line);
        if (std.mem.indexOf(u8, diag.message, c[2]) == null) {
            std.debug.print("expected '{s}' in '{s}'\n", .{ c[2], diag.message });
            return error.TestUnexpectedResult;
        }
    }
}
