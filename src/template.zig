//! The Mortise template engine. Syntax is specified in docs/templates.md.
//!
//!   {{ page.title }}                 output, HTML-escaped by default
//!   {{ content }}                    values marked as HTML are not escaped
//!   {{ page.title | upper }}         filters (built-ins only)
//!   {% if a and not b %}...{% elif c == "x" %}...{% else %}...{% endif %}
//!   {% for post in site.posts | limit(5) %}...{{ loop.index }}...{% endfor %}
//!   {% include "card.html" title=page.title %}
//!   {% extends "base.html" %}{% block main %}...{{ super }}...{% endblock %}
//!   {# comment #}
//!   {%- ... -%}                      `-` trims whitespace on that side
//!
//! Templates are parsed once into a node tree and rendered many times.
//! Syntax errors and render errors both carry the template name and line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const escapeHtml = markdown.escapeHtml;

// ---------------------------------------------------------------------------
// Values

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    /// Text, escaped on output.
    string: []const u8,
    /// Trusted HTML, written as-is.
    html: []const u8,
    list: []const Value,
    object: Object,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0,
            .string, .html => |s| s.len > 0,
            .list => |l| l.len > 0,
            .object => true,
        };
    }

    fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nothing",
            .boolean => "a boolean",
            .int, .float => "a number",
            .string, .html => "a string",
            .list => "a list",
            .object => "an object",
        };
    }

    fn eql(a: Value, b: Value) bool {
        const as = a.text();
        const bs = b.text();
        if (as != null and bs != null) return std.mem.eql(u8, as.?, bs.?);
        return switch (a) {
            .nil => b == .nil,
            .boolean => |x| b == .boolean and b.boolean == x,
            .int => |x| switch (b) {
                .int => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .float => |x| switch (b) {
                .int => |y| x == @as(f64, @floatFromInt(y)),
                .float => |y| x == y,
                else => false,
            },
            else => false,
        };
    }

    fn text(v: Value) ?[]const u8 {
        return switch (v) {
            .string, .html => |s| s,
            else => null,
        };
    }
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Object = struct {
    entries: []const Entry = &.{},

    pub fn get(o: Object, key: []const u8) ?Value {
        for (o.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Syntax tree

const Expr = union(enum) {
    path: []const []const u8,
    string: []const u8,
    int: i64,
    boolean: bool,
};

const Filter = struct {
    kind: FilterKind,
    args: []const Expr = &.{},
};

pub const FilterKind = enum {
    /// Marks a string as trusted HTML so it is not escaped.
    raw,
    upper,
    lower,
    /// `default("x")`: the argument when the value is falsy.
    default,
    /// Formats a `YYYY-MM-DD` date as `January 5, 2024`, or with a format
    /// such as `date("%Y-%m")`: `%Y` year, `%m` month (01), `%d` day (05),
    /// `%e` day (5), `%B` month name, `%b` short month name, `%%` a `%`.
    date,
    /// A URL-friendly slug: `Hello, World!` becomes `hello-world`.
    slugify,
    /// `truncate(n)` or `truncate(n, "...")`: at most n characters of text,
    /// cut at a word boundary, with `…` (or the second argument) appended.
    truncate,
    /// Renders a Markdown string to HTML.
    markdownify,
    /// The value as JSON, safe inside `<script>`.
    json,
    /// `where("key")` keeps list items whose `key` is truthy;
    /// `where("key", value)` keeps items whose `key` equals `value` or, for
    /// a list field, contains it.
    where,
    /// `sort` sorts a list; `sort("key")` sorts objects by a field.
    sort,
    /// `group_by("key")`: a list of `{ name, items }`, in first-seen order.
    /// `group_by("date", "%Y")` groups by a formatted date.
    group_by,
    /// `limit(n)`: the first n items of a list.
    limit,
    /// Reverses a list.
    reverse,
    /// Minutes to read the text at 200 words a minute, at least 1.
    reading_time,
    /// Words in the text, ignoring HTML tags.
    word_count,
    /// A readable dump of any value, for debugging templates.
    dump,
    /// Items in a list, fields in an object, or bytes in a string.
    size,
    /// `join` or `join(", ")`: list items as one string.
    join,
    first,
    last,
    /// Removes HTML tags, leaving the text.
    strip_html,
    /// `"css/site.css" | asset`: the URL of a static file of the site, with
    /// the baseurl and, in `build`, a content hash in its name.
    asset,
    /// `"js/app.js" | sri`: a Subresource Integrity hash for `integrity=`.
    sri,

    /// The minimum and maximum number of arguments.
    fn arity(k: FilterKind) [2]usize {
        return switch (k) {
            .default, .limit => .{ 1, 1 },
            .truncate, .where, .group_by => .{ 1, 2 },
            .sort, .join, .date => .{ 0, 1 },
            else => .{ 0, 0 },
        };
    }
};

/// The built-in filter names, for error messages.
const filter_names = blk: {
    var s: []const u8 = "";
    for (std.meta.fieldNames(FilterKind), 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n;
    break :blk s;
};

const Comparison = struct {
    negate: bool,
    left: Expr,
    op: enum { truthy, eq, ne },
    right: Expr = .{ .boolean = false },
};

/// `or` of `and` groups.
const Condition = []const []const Comparison;

const Node = union(enum) {
    text: []const u8,
    output: struct { expr: Expr, filters: []const Filter, line: usize },
    @"if": struct { branches: []const Branch, line: usize },
    @"for": struct { name: []const u8, iter: Expr, filters: []const Filter, body: []const Node, line: usize },
    include: struct { name: []const u8, args: []const Arg = &.{}, line: usize },
    /// `{% block NAME %}...{% endblock %}`: content a child template can
    /// replace.
    block: struct { name: []const u8, body: []const Node, line: usize },
    /// `{{ super }}` inside a block: the block's content one template up.
    super: usize,
};

/// `name=expression` after an include's name.
const Arg = struct { name: []const u8, expr: Expr };

pub const BlockDef = struct { name: []const u8, body: []const Node };

const Branch = struct {
    /// Null for `else`.
    cond: ?Condition,
    body: []const Node,
};

pub const Template = struct {
    name: []const u8,
    nodes: []const Node,
    /// Names passed to `{% include %}`, for dependency tracking.
    includes: []const []const u8,
    /// Whether any expression reads `site.posts`, `site.pages`, or
    /// `site.tags`, whose contents change whenever any page or post does.
    reads_collections: bool,
    /// Whether any expression reads `seo`, the page's head tags.
    reads_seo: bool = false,
    /// The parent named by `{% extends %}`, or null.
    extends: ?[]const u8 = null,
    extends_line: usize = 0,
    /// Every block in the template, at any depth.
    blocks: []const BlockDef = &.{},

    fn findBlock(t: *const Template, name: []const u8) ?[]const Node {
        for (t.blocks) |b| if (std.mem.eql(u8, b.name, name)) return b.body;
        return null;
    }
};

pub const Diagnostic = struct {
    /// Template name (as given to `parse`) where the error occurred.
    template: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{TemplateSyntax} || Allocator.Error;

// ---------------------------------------------------------------------------
// Parsing

const TagKind = enum { output, statement };

const Token = union(enum) {
    text: []const u8,
    tag: struct { kind: TagKind, body: []const u8, line: usize },
};

const Parser = struct {
    arena: Allocator,
    name: []const u8,
    diag: *Diagnostic,
    tokens: []const Token,
    pos: usize = 0,
    includes: std.ArrayList([]const u8) = .empty,
    reads_collections: bool = false,
    reads_seo: bool = false,
    extends: ?[]const u8 = null,
    extends_line: usize = 0,
    blocks: std.ArrayList(BlockDef) = .empty,
    /// How deep inside `if`, `for` and `block` the parser is; `extends`
    /// must be at the top.
    depth: usize = 0,
    /// Blocks open around the current position, for `{{ super }}`.
    block_depth: usize = 0,

    fn fail(p: *Parser, line: usize, comptime fmt: []const u8, args: anytype) ParseError {
        p.diag.* = .{
            .template = p.name,
            .line = line,
            .message = std.fmt.allocPrint(p.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.TemplateSyntax;
    }
};

/// Parses `src`. `name` identifies the template in error messages.
pub fn parse(arena: Allocator, name: []const u8, src: []const u8, diag: *Diagnostic) ParseError!Template {
    var p: Parser = .{ .arena = arena, .name = name, .diag = diag, .tokens = &.{} };
    p.tokens = try tokenize(&p, src);
    var end: ?Stmt = null;
    const nodes = try parseNodes(&p, &end);
    if (end) |e| return p.fail(e.line, "unexpected '{s}'", .{e.keyword});
    return .{
        .name = name,
        .nodes = nodes,
        .includes = p.includes.items,
        .reads_collections = p.reads_collections,
        .reads_seo = p.reads_seo,
        .extends = p.extends,
        .extends_line = p.extends_line,
        .blocks = p.blocks.items,
    };
}

fn tokenize(p: *Parser, src: []const u8) ParseError![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var line: usize = 1;
    var trim_next = false;
    while (i < src.len) {
        const open = std.mem.indexOfScalarPos(u8, src, i, '{');
        const start = open orelse src.len;
        if (open != null and start + 1 < src.len and (src[start + 1] == '{' or src[start + 1] == '%' or src[start + 1] == '#')) {
            var text = src[i..start];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            const kind_char = src[start + 1];
            const trim_prev = start + 2 < src.len and src[start + 2] == '-';
            if (trim_prev) text = std.mem.trimEnd(u8, text, " \t\r\n");
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            line += std.mem.count(u8, src[i..start], "\n");

            const close_seq: []const u8 = switch (kind_char) {
                '{' => "}}",
                '%' => "%}",
                else => "#}",
            };
            const body_start = start + 2 + @intFromBool(trim_prev);
            const close = findClose(src, body_start, close_seq, kind_char == '#') orelse
                return p.fail(line, "unclosed '{{{c}' tag; expected '{s}'", .{ kind_char, close_seq });
            var body_end = close;
            trim_next = close > body_start and src[close - 1] == '-';
            if (trim_next) body_end -= 1;
            if (kind_char != '#') {
                try tokens.append(p.arena, .{ .tag = .{
                    .kind = if (kind_char == '{') .output else .statement,
                    .body = std.mem.trim(u8, src[body_start..body_end], " \t\r\n"),
                    .line = line,
                } });
            }
            line += std.mem.count(u8, src[start..close], "\n");
            i = close + 2;
        } else if (open) |o| {
            // A lone `{`: keep scanning past it.
            const next = o + 1;
            var text = src[i..next];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            trim_next = false;
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            line += std.mem.count(u8, src[i..next], "\n");
            i = next;
        } else {
            var text = src[i..];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            i = src.len;
        }
    }
    return tokens.items;
}

/// Finds `close` after `from`, skipping over quoted strings in tags.
fn findClose(src: []const u8, from: usize, close: []const u8, is_comment: bool) ?usize {
    var i = from;
    var quote: u8 = 0;
    while (i + 1 < src.len) : (i += 1) {
        const c = src[i];
        if (!is_comment) {
            if (quote != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                continue;
            }
        }
        if (c == close[0] and src[i + 1] == close[1]) return i;
    }
    return null;
}

const Stmt = struct { keyword: []const u8, rest: []const u8, line: usize };

fn splitStmt(body: []const u8, line: usize) Stmt {
    const sp = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
    return .{ .keyword = body[0..sp], .rest = std.mem.trim(u8, body[sp..], " \t\r\n"), .line = line };
}

/// Parses nodes until the end of input or a block-ending statement, which
/// is stored in `end`.
fn parseNodes(p: *Parser, end: *?Stmt) ParseError![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    end.* = null;
    while (p.pos < p.tokens.len) {
        const tok = p.tokens[p.pos];
        p.pos += 1;
        switch (tok) {
            .text => |t| try nodes.append(p.arena, .{ .text = t }),
            .tag => |tag| switch (tag.kind) {
                .output => try nodes.append(p.arena, try parseOutput(p, tag.body, tag.line)),
                .statement => {
                    const st = splitStmt(tag.body, tag.line);
                    if (std.mem.eql(u8, st.keyword, "if")) {
                        try nodes.append(p.arena, try parseIf(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "for")) {
                        try nodes.append(p.arena, try parseFor(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "include")) {
                        try nodes.append(p.arena, try parseInclude(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "block")) {
                        try nodes.append(p.arena, try parseBlock(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "extends")) {
                        try parseExtends(p, st, nodes.items);
                    } else if (isBlockEnd(st.keyword)) {
                        end.* = st;
                        return nodes.items;
                    } else {
                        return p.fail(st.line, "unknown statement '{s}'", .{st.keyword});
                    }
                },
            },
        }
    }
    return nodes.items;
}

fn isBlockEnd(keyword: []const u8) bool {
    for ([_][]const u8{ "elif", "else", "endif", "endfor", "endblock" }) |k| {
        if (std.mem.eql(u8, keyword, k)) return true;
    }
    return false;
}

fn parseIf(p: *Parser, first: Stmt) ParseError!Node {
    var branches: std.ArrayList(Branch) = .empty;
    var cond: ?Condition = try parseCondition(p, first.rest, first.line);
    var seen_else = false;
    while (true) {
        var end: ?Stmt = null;
        p.depth += 1;
        const body = try parseNodes(p, &end);
        p.depth -= 1;
        try branches.append(p.arena, .{ .cond = cond, .body = body });
        const e = end orelse return p.fail(first.line, "'if' is not closed; add '{{% endif %}}'", .{});
        if (std.mem.eql(u8, e.keyword, "endif")) {
            if (e.rest.len != 0) return p.fail(e.line, "'endif' takes no arguments", .{});
            break;
        }
        if (seen_else) return p.fail(e.line, "unexpected '{s}' after 'else'", .{e.keyword});
        if (std.mem.eql(u8, e.keyword, "elif")) {
            cond = try parseCondition(p, e.rest, e.line);
        } else if (std.mem.eql(u8, e.keyword, "else")) {
            if (e.rest.len != 0) return p.fail(e.line, "'else' takes no arguments", .{});
            cond = null;
            seen_else = true;
        } else {
            return p.fail(e.line, "unexpected '{s}' inside 'if'", .{e.keyword});
        }
    }
    return .{ .@"if" = .{ .branches = branches.items, .line = first.line } };
}

fn parseFor(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const name_tok = try lx.next();
    if (name_tok != .ident) return p.fail(st.line, "expected a loop variable name after 'for'", .{});
    const name = name_tok.ident;
    if (std.mem.indexOfScalar(u8, name, '.') != null or std.mem.eql(u8, name, "loop")) {
        return p.fail(st.line, "invalid loop variable name '{s}'", .{name});
    }
    const in_tok = try lx.next();
    if (in_tok != .ident or !std.mem.eql(u8, in_tok.ident, "in")) return p.fail(st.line, "expected 'in' after the loop variable", .{});
    const iter = try parseExpr(&lx);
    const filters = try parseFilters(p, &lx, st.line, "the loop expression");

    var end: ?Stmt = null;
    p.depth += 1;
    const body = try parseNodes(p, &end);
    p.depth -= 1;
    const e = end orelse return p.fail(st.line, "'for' is not closed; add '{{% endfor %}}'", .{});
    if (!std.mem.eql(u8, e.keyword, "endfor")) return p.fail(e.line, "unexpected '{s}' inside 'for'", .{e.keyword});
    if (e.rest.len != 0) return p.fail(e.line, "'endfor' takes no arguments", .{});
    return .{ .@"for" = .{ .name = name, .iter = iter, .filters = filters, .body = body, .line = st.line } };
}

fn parseInclude(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const t = try lx.next();
    if (t != .string) return p.fail(st.line, "'include' expects a quoted template name", .{});
    // Arguments: `name=expression` pairs, bound while the include renders.
    var args: std.ArrayList(Arg) = .empty;
    while (true) {
        const name_tok = try lx.next();
        if (name_tok == .end) break;
        if (name_tok != .ident or std.mem.indexOfScalar(u8, name_tok.ident, '.') != null) {
            return p.fail(st.line, "expected name=value arguments after the include name", .{});
        }
        if (try lx.next() != .assign) return p.fail(st.line, "expected '=' after '{s}'", .{name_tok.ident});
        try args.append(p.arena, .{ .name = name_tok.ident, .expr = try parseExpr(&lx) });
    }
    try p.includes.append(p.arena, t.string);
    return .{ .include = .{ .name = t.string, .args = args.items, .line = st.line } };
}

fn parseBlock(p: *Parser, st: Stmt) ParseError!Node {
    const name = st.rest;
    if (name.len == 0 or !validName(name)) return p.fail(st.line, "'block' needs a name, as in {{% block content %}}", .{});
    for (p.blocks.items) |b| {
        if (std.mem.eql(u8, b.name, name)) return p.fail(st.line, "block '{s}' is defined twice", .{name});
    }
    // Reserve the block's place, so parents list before their children.
    const index = p.blocks.items.len;
    try p.blocks.append(p.arena, .{ .name = name, .body = &.{} });
    var end: ?Stmt = null;
    p.depth += 1;
    p.block_depth += 1;
    const body = try parseNodes(p, &end);
    p.block_depth -= 1;
    p.depth -= 1;
    const e = end orelse return p.fail(st.line, "block '{s}' is not closed; add '{{% endblock %}}'", .{name});
    if (!std.mem.eql(u8, e.keyword, "endblock")) return p.fail(e.line, "unexpected '{s}' inside block '{s}'", .{ e.keyword, name });
    if (e.rest.len != 0 and !std.mem.eql(u8, e.rest, name)) return p.fail(e.line, "'endblock {s}' closes block '{s}'", .{ e.rest, name });
    p.blocks.items[index].body = body;
    return .{ .block = .{ .name = name, .body = body, .line = st.line } };
}

fn parseExtends(p: *Parser, st: Stmt, before: []const Node) ParseError!void {
    if (p.extends != null) return p.fail(st.line, "a template can extend only one parent", .{});
    const ok = p.depth == 0 and p.blocks.items.len == 0 and for (before) |n| {
        if (n != .text or std.mem.trim(u8, n.text, " \t\r\n").len != 0) break false;
    } else true;
    if (!ok) return p.fail(st.line, "'extends' must come first in a template", .{});
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const t = try lx.next();
    if (t != .string) return p.fail(st.line, "'extends' expects a quoted layout name, as in {{% extends \"base.html\" %}}", .{});
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the layout name", .{});
    p.extends = t.string;
    p.extends_line = st.line;
}

fn validName(s: []const u8) bool {
    for (s) |c| if (!isIdentChar(c)) return false;
    return true;
}

fn parseOutput(p: *Parser, body: []const u8, line: usize) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = body, .line = line };
    if (body.len == 0) return p.fail(line, "empty output tag", .{});
    if (std.mem.eql(u8, body, "super")) {
        if (p.block_depth == 0) return p.fail(line, "'super' works only inside a block", .{});
        return .{ .super = line };
    }
    const expr = try parseExpr(&lx);
    const filters = try parseFilters(p, &lx, line, "the tag");
    return .{ .output = .{ .expr = expr, .filters = filters, .line = line } };
}

/// Parses `| name(args)` filters up to the end of `lx`.
fn parseFilters(p: *Parser, lx: *Lexer, line: usize, what: []const u8) ParseError![]const Filter {
    var filters: std.ArrayList(Filter) = .empty;
    while (true) {
        const t = try lx.next();
        switch (t) {
            .end => break,
            .pipe => {},
            else => return p.fail(line, "expected '|' or the end of {s}", .{what}),
        }
        const name_tok = try lx.next();
        if (name_tok != .ident) return p.fail(line, "expected a filter name after '|'", .{});
        const kind = std.meta.stringToEnum(FilterKind, name_tok.ident) orelse
            return p.fail(line, "unknown filter '{s}'; the built-in filters are " ++ filter_names, .{name_tok.ident});
        var args: std.ArrayList(Expr) = .empty;
        if (lx.peekByte() == '(') {
            _ = try lx.next();
            while (true) {
                try args.append(p.arena, try parseExpr(lx));
                switch (try lx.next()) {
                    .comma => continue,
                    .rparen => break,
                    else => return p.fail(line, "expected ',' or ')' after a filter argument", .{}),
                }
            }
        }
        const min, const max = kind.arity();
        if (args.items.len < min) {
            return p.fail(line, "filter '{s}' needs {s}", .{ @tagName(kind), if (min == 1 and max == 1) "an argument, as in default(\"x\")" else "an argument" });
        }
        if (args.items.len > max) {
            if (max == 0) return p.fail(line, "filter '{s}' takes no argument", .{@tagName(kind)});
            return p.fail(line, "filter '{s}' takes at most {d} argument{s}", .{ @tagName(kind), max, if (max == 1) "" else "s" });
        }
        try filters.append(p.arena, .{ .kind = kind, .args = args.items });
    }
    return filters.items;
}

fn parseCondition(p: *Parser, src: []const u8, line: usize) ParseError!Condition {
    if (src.len == 0) return p.fail(line, "missing condition", .{});
    var lx: Lexer = .{ .p = p, .src = src, .line = line };
    var groups: std.ArrayList([]const Comparison) = .empty;
    var group: std.ArrayList(Comparison) = .empty;
    while (true) {
        var cmp: Comparison = .{ .negate = false, .left = undefined, .op = .truthy };
        if (lx.peekKeyword("not")) {
            _ = try lx.next();
            cmp.negate = true;
        }
        cmp.left = try parseExpr(&lx);
        var t = try lx.next();
        if (t == .eq or t == .ne) {
            cmp.op = if (t == .eq) .eq else .ne;
            cmp.right = try parseExpr(&lx);
            t = try lx.next();
        }
        try group.append(p.arena, cmp);
        switch (t) {
            .end => break,
            .ident => |w| {
                if (std.mem.eql(u8, w, "and")) continue;
                if (std.mem.eql(u8, w, "or")) {
                    try groups.append(p.arena, group.items);
                    group = .empty;
                    continue;
                }
                return p.fail(line, "unexpected '{s}' in condition", .{w});
            },
            .assign => return p.fail(line, "unexpected '='; did you mean '=='?", .{}),
            else => return p.fail(line, "unexpected token in condition", .{}),
        }
    }
    try groups.append(p.arena, group.items);
    return groups.items;
}

fn parseExpr(lx: *Lexer) ParseError!Expr {
    const t = try lx.next();
    return switch (t) {
        .ident => |id| blk: {
            if (std.mem.eql(u8, id, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, id, "false")) break :blk .{ .boolean = false };
            var segs: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, id, '.');
            while (it.next()) |s| {
                if (s.len == 0) return lx.p.fail(lx.line, "invalid variable name '{s}'", .{id});
                try segs.append(lx.p.arena, s);
            }
            const path = segs.items;
            if (path.len >= 2 and std.mem.eql(u8, path[0], "site") and
                (std.mem.eql(u8, path[1], "posts") or std.mem.eql(u8, path[1], "pages") or
                    std.mem.eql(u8, path[1], "tags") or std.mem.eql(u8, path[1], "nav") or
                    std.mem.eql(u8, path[1], "apis") or std.mem.eql(u8, path[1], "taxonomies") or
                    std.mem.eql(u8, path[1], "menus")))
            {
                lx.p.reads_collections = true;
            }
            // Navigation fields depend on other pages' titles and URLs.
            if (path.len >= 2 and std.mem.eql(u8, path[0], "page") and
                (std.mem.eql(u8, path[1], "breadcrumbs") or std.mem.eql(u8, path[1], "previous") or
                    std.mem.eql(u8, path[1], "next") or std.mem.eql(u8, path[1], "related") or
                    std.mem.eql(u8, path[1], "menus") or std.mem.eql(u8, path[1], "backlinks")))
            {
                lx.p.reads_collections = true;
            }
            // The head tags hold breadcrumbs, which depend on other pages.
            if (std.mem.eql(u8, path[0], "seo")) {
                lx.p.reads_seo = true;
                lx.p.reads_collections = true;
            }
            break :blk .{ .path = path };
        },
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .end => lx.p.fail(lx.line, "expected an expression", .{}),
        else => lx.p.fail(lx.line, "expected a variable, string, or number", .{}),
    };
}

const Tok = union(enum) {
    end,
    ident: []const u8,
    string: []const u8,
    int: i64,
    pipe,
    lparen,
    rparen,
    comma,
    /// A single `=`, in include arguments.
    assign,
    eq,
    ne,
};

const Lexer = struct {
    p: *Parser,
    src: []const u8,
    line: usize,
    i: usize = 0,

    fn skipSpace(lx: *Lexer) void {
        while (lx.i < lx.src.len and std.ascii.isWhitespace(lx.src[lx.i])) lx.i += 1;
    }

    fn peekByte(lx: *Lexer) u8 {
        lx.skipSpace();
        return if (lx.i < lx.src.len) lx.src[lx.i] else 0;
    }

    fn peekKeyword(lx: *Lexer, kw: []const u8) bool {
        lx.skipSpace();
        const rest = lx.src[lx.i..];
        if (!std.mem.startsWith(u8, rest, kw)) return false;
        return rest.len == kw.len or !isIdentChar(rest[kw.len]);
    }

    fn next(lx: *Lexer) ParseError!Tok {
        lx.skipSpace();
        if (lx.i >= lx.src.len) return .end;
        const s = lx.src;
        const c = s[lx.i];
        switch (c) {
            '|' => {
                lx.i += 1;
                return .pipe;
            },
            '(' => {
                lx.i += 1;
                return .lparen;
            },
            ')' => {
                lx.i += 1;
                return .rparen;
            },
            ',' => {
                lx.i += 1;
                return .comma;
            },
            '=', '!' => {
                if (lx.i + 1 < s.len and s[lx.i + 1] == '=') {
                    lx.i += 2;
                    return if (c == '=') .eq else .ne;
                }
                if (c == '=') {
                    lx.i += 1;
                    return .assign;
                }
                return lx.p.fail(lx.line, "unexpected '!'; did you mean '!='?", .{});
            },
            '"', '\'' => {
                lx.i += 1;
                var out: std.ArrayList(u8) = .empty;
                while (lx.i < s.len and s[lx.i] != c) : (lx.i += 1) {
                    if (s[lx.i] == '\\' and lx.i + 1 < s.len) lx.i += 1;
                    try out.append(lx.p.arena, s[lx.i]);
                }
                if (lx.i >= s.len) return lx.p.fail(lx.line, "unterminated string", .{});
                lx.i += 1;
                return .{ .string = out.items };
            },
            '0'...'9', '-' => {
                const start = lx.i;
                lx.i += 1;
                while (lx.i < s.len and std.ascii.isDigit(s[lx.i])) lx.i += 1;
                const n = std.fmt.parseInt(i64, s[start..lx.i], 10) catch
                    return lx.p.fail(lx.line, "invalid number '{s}'", .{s[start..lx.i]});
                return .{ .int = n };
            },
            else => {
                if (!(std.ascii.isAlphabetic(c) or c == '_')) {
                    return lx.p.fail(lx.line, "unexpected character '{c}'", .{c});
                }
                const start = lx.i;
                while (lx.i < s.len and (isIdentChar(s[lx.i]) or s[lx.i] == '.')) lx.i += 1;
                return .{ .ident = s[start..lx.i] };
            },
        }
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// ---------------------------------------------------------------------------
// Rendering

/// Resolves include names to parsed templates.
pub const Loader = struct {
    ctx: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, name: []const u8, diag: *Diagnostic) LoadError!*const Template,
    /// Resolves `{% extends %}` names, which name layouts; null uses
    /// `loadFn`.
    extendsFn: ?*const fn (ctx: *anyopaque, name: []const u8, diag: *Diagnostic) LoadError!*const Template = null,

    pub const LoadError = error{ TemplateNotFound, TemplateSyntax } || Allocator.Error;

    fn load(l: Loader, name: []const u8, diag: *Diagnostic) LoadError!*const Template {
        return l.loadFn(l.ctx, name, diag);
    }

    fn loadParent(l: Loader, name: []const u8, diag: *Diagnostic) LoadError!*const Template {
        return (l.extendsFn orelse l.loadFn)(l.ctx, name, diag);
    }
};

/// How many templates an `extends` chain may hold.
const max_extends_depth = 16;

pub const RenderError = error{ TemplateRender, TemplateSyntax, TemplateNotFound } || Allocator.Error || Writer.Error;

const max_include_depth = 32;

const Binding = struct { name: []const u8, value: Value };

const Renderer = struct {
    arena: Allocator,
    loader: ?Loader,
    diag: *Diagnostic,
    root: Object,
    scope: std.ArrayList(Binding) = .empty,
    template: []const u8 = "",
    depth: usize = 0,
    strict: bool = false,
    assets: ?Assets = null,
    /// The `extends` chain being rendered, most derived template first.
    /// Each block renders from the first template that defines it.
    chain: []const *const Template = &.{},
    /// The block being rendered and where `{{ super }}` continues.
    super: ?struct { name: []const u8, next: usize } = null,

    fn fail(r: *Renderer, line: usize, comptime fmt: []const u8, args: anytype) RenderError {
        r.diag.* = .{
            .template = r.template,
            .line = line,
            .message = std.fmt.allocPrint(r.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.TemplateRender;
    }
};

pub const RenderOptions = struct {
    /// Fail on undefined variables instead of rendering nothing: an output
    /// tag whose value is undefined (unless a `default` filter follows),
    /// and a loop over a variable whose first name is unknown. Conditions
    /// stay lenient, so `{% if page.subtitle %}` works on every page.
    strict: bool = false,
    /// Answers the `asset` and `sri` filters; without one they fail.
    assets: ?Assets = null,
};

/// Looks up static files for the `asset` and `sri` filters.
pub const Assets = struct {
    ctx: *anyopaque,
    /// The answer for `path` (as written in the template), or null with a
    /// reason in `why`.
    lookupFn: *const fn (ctx: *anyopaque, path: []const u8, kind: Kind, why: *[]const u8) Allocator.Error!?[]const u8,

    pub const Kind = enum { url, sri };
};

/// Renders `tpl` with `root` as the top-level variables.
pub fn render(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, w: *Writer, diag: *Diagnostic) RenderError!void {
    return renderWith(arena, tpl, root, loader, .{}, w, diag);
}

/// `render` with options.
pub fn renderWith(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, options: RenderOptions, w: *Writer, diag: *Diagnostic) RenderError!void {
    var r: Renderer = .{ .arena = arena, .loader = loader, .diag = diag, .root = root, .template = tpl.name, .strict = options.strict, .assets = options.assets };
    // Follow `extends` to the root template, which supplies the page; the
    // templates below it only fill its blocks.
    var chain: std.ArrayList(*const Template) = .empty;
    try chain.append(arena, tpl);
    var cur = tpl;
    while (cur.extends) |parent_name| {
        if (chain.items.len >= max_extends_depth) {
            r.template = cur.name;
            return r.fail(cur.extends_line, "templates extend each other more than {d} deep (does '{s}' extend itself?)", .{ max_extends_depth, parent_name });
        }
        const loader_ = loader orelse {
            r.template = cur.name;
            return r.fail(cur.extends_line, "'extends' is not available here", .{});
        };
        const saved_diag = r.diag.*;
        const parent = loader_.loadParent(parent_name, r.diag) catch |err| switch (err) {
            error.TemplateNotFound => {
                r.diag.* = saved_diag;
                r.template = cur.name;
                return r.fail(cur.extends_line, "the layout '{s}' to extend was not found", .{parent_name});
            },
            else => |e| return e,
        };
        cur = parent;
        try chain.append(arena, cur);
    }
    r.chain = chain.items;
    r.template = cur.name;
    try renderNodes(&r, cur.nodes, w);
}

/// Renders block `name` from the first template in the chain at or after
/// `start` that defines it.
fn renderBlock(r: *Renderer, name: []const u8, start: usize, w: *Writer) RenderError!void {
    for (r.chain[@min(start, r.chain.len)..], start..) |t, i| {
        const body = t.findBlock(name) orelse continue;
        const outer_template = r.template;
        const outer_super = r.super;
        r.template = t.name;
        r.super = .{ .name = name, .next = i + 1 };
        defer {
            r.template = outer_template;
            r.super = outer_super;
        }
        return renderNodes(r, body, w);
    }
}

/// Renders to a newly allocated string.
pub fn renderAlloc(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, diag: *Diagnostic) RenderError![]u8 {
    return renderAllocWith(arena, tpl, root, loader, .{}, diag);
}

/// `renderAlloc` with options.
pub fn renderAllocWith(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, options: RenderOptions, diag: *Diagnostic) RenderError![]u8 {
    var aw: Writer.Allocating = .init(arena);
    try renderWith(arena, tpl, root, loader, options, &aw.writer, diag);
    return aw.toOwnedSlice();
}

fn renderNodes(r: *Renderer, nodes: []const Node, w: *Writer) RenderError!void {
    for (nodes) |node| switch (node) {
        .text => |t| try w.writeAll(t),
        .output => |o| {
            var v = try evalExpr(r, o.expr);
            if (r.strict and o.expr == .path and !hasDefault(o.filters)) {
                if (resolve(r, o.expr.path) == null) return undefinedVariable(r, o.expr.path, o.line);
            }
            for (o.filters) |f| v = try applyFilter(r, f, v, o.line);
            try writeValue(r, v, w, o.line);
        },
        .@"if" => |n| {
            for (n.branches) |b| {
                const take = if (b.cond) |c| try evalCondition(r, c) else true;
                if (take) {
                    try renderNodes(r, b.body, w);
                    break;
                }
            }
        },
        .@"for" => |n| {
            if (r.strict and n.iter == .path and !isBound(r, n.iter.path[0])) {
                return undefinedVariable(r, n.iter.path[0..1], n.line);
            }
            var iter = try evalExpr(r, n.iter);
            for (n.filters) |f| iter = try applyFilter(r, f, iter, n.line);
            const items: []const Value = switch (iter) {
                .nil => &.{},
                .list => |l| l,
                else => return r.fail(n.line, "cannot loop over {s}", .{iter.typeName()}),
            };
            const base = r.scope.items.len;
            defer r.scope.shrinkRetainingCapacity(base);
            try r.scope.appendNTimes(r.arena, .{ .name = "", .value = .nil }, 2);
            for (items, 0..) |item, idx| {
                const loop_entries = try r.arena.alloc(Entry, 4);
                loop_entries[0] = .{ .key = "index", .value = .{ .int = @intCast(idx + 1) } };
                loop_entries[1] = .{ .key = "index0", .value = .{ .int = @intCast(idx) } };
                loop_entries[2] = .{ .key = "first", .value = .{ .boolean = idx == 0 } };
                loop_entries[3] = .{ .key = "last", .value = .{ .boolean = idx + 1 == items.len } };
                r.scope.items[base] = .{ .name = "loop", .value = .{ .object = .{ .entries = loop_entries } } };
                r.scope.items[base + 1] = .{ .name = n.name, .value = item };
                try renderNodes(r, n.body, w);
            }
        },
        .include => |inc| {
            const loader = r.loader orelse return r.fail(inc.line, "includes are not available here", .{});
            if (r.depth >= max_include_depth) {
                return r.fail(inc.line, "includes nested more than {d} deep (is '{s}' including itself?)", .{ max_include_depth, inc.name });
            }
            const saved_diag = r.diag.*;
            const child = loader.load(inc.name, r.diag) catch |err| switch (err) {
                error.TemplateNotFound => {
                    r.diag.* = saved_diag;
                    return r.fail(inc.line, "included template '{s}' was not found", .{inc.name});
                },
                else => |e| return e,
            };
            // Arguments are evaluated where the include is, then bound for
            // the included template only.
            const base = r.scope.items.len;
            defer r.scope.shrinkRetainingCapacity(base);
            for (inc.args) |a| {
                const v = try evalExpr(r, a.expr);
                try r.scope.append(r.arena, .{ .name = a.name, .value = v });
            }
            const outer = r.template;
            const outer_chain = r.chain;
            const outer_super = r.super;
            // An included template's blocks are its own, not the page's.
            r.chain = &.{child};
            r.super = null;
            r.template = child.name;
            r.depth += 1;
            try renderNodes(r, child.nodes, w);
            r.depth -= 1;
            r.template = outer;
            r.chain = outer_chain;
            r.super = outer_super;
        },
        .block => |b| {
            if (r.chain.len == 0) return renderNodes(r, b.body, w);
            try renderBlock(r, b.name, 0, w);
        },
        .super => {
            const s = r.super orelse return;
            try renderBlock(r, s.name, s.next, w);
        },
    };
}

fn lookup(r: *Renderer, path: []const []const u8) Value {
    return resolve(r, path) orelse .nil;
}

/// The value at `path`, or null when it is undefined.
fn resolve(r: *Renderer, path: []const []const u8) ?Value {
    const first = path[0];
    var v: Value = blk: {
        var k = r.scope.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, r.scope.items[k].name, first)) break :blk r.scope.items[k].value;
        }
        break :blk r.root.get(first) orelse return null;
    };
    for (path[1..]) |seg| v = field(v, seg) orelse return null;
    return v;
}

fn field(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// The value at a dotted `key` path inside `v`.
fn fieldPath(v: Value, key: []const u8) ?Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| cur = field(cur, seg) orelse return null;
    return cur;
}

fn isBound(r: *Renderer, name: []const u8) bool {
    for (r.scope.items) |b| if (std.mem.eql(u8, b.name, name)) return true;
    return r.root.get(name) != null;
}

fn hasDefault(filters: []const Filter) bool {
    for (filters) |f| if (f.kind == .default) return true;
    return false;
}

fn undefinedVariable(r: *Renderer, path: []const []const u8, line: usize) RenderError {
    const name = try std.mem.join(r.arena, ".", path);
    if (!isBound(r, path[0])) {
        return r.fail(line, "undefined variable '{s}' (strict mode); add a default, as in {{{{ {s} | default(\"\") }}}}", .{ name, name });
    }
    return r.fail(line, "'{s}' is not defined (strict mode); guard it with {{% if {s} %}} or add | default(\"\")", .{ name, name });
}

fn evalExpr(r: *Renderer, e: Expr) RenderError!Value {
    return switch (e) {
        .path => |p| lookup(r, p),
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .boolean => |b| .{ .boolean = b },
    };
}

fn evalCondition(r: *Renderer, cond: Condition) RenderError!bool {
    for (cond) |group| {
        var all = true;
        for (group) |cmp| {
            const left = try evalExpr(r, cmp.left);
            var result = switch (cmp.op) {
                .truthy => left.truthy(),
                .eq => left.eql(try evalExpr(r, cmp.right)),
                .ne => !left.eql(try evalExpr(r, cmp.right)),
            };
            if (cmp.negate) result = !result;
            if (!result) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

fn applyFilter(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!Value {
    switch (f.kind) {
        .raw => return switch (v) {
            .string => |s| .{ .html = s },
            else => v,
        },
        .upper, .lower => {
            const s = v.text() orelse switch (v) {
                .nil => return v,
                else => return r.fail(line, "filter '{s}' expects a string, got {s}", .{ @tagName(f.kind), v.typeName() }),
            };
            const out = try r.arena.alloc(u8, s.len);
            if (f.kind == .upper) _ = std.ascii.upperString(out, s) else _ = std.ascii.lowerString(out, s);
            return if (v == .html) .{ .html = out } else .{ .string = out };
        },
        .default => return if (v.truthy()) v else try evalExpr(r, f.args[0]),
        .date => {
            const s = v.text() orelse switch (v) {
                .nil => return v,
                else => return r.fail(line, "filter 'date' expects a date string, got {s}", .{v.typeName()}),
            };
            const d = parseDate(s) orelse return r.fail(line, "filter 'date' expects YYYY-MM-DD, got '{s}'", .{s});
            if (f.args.len == 0) {
                return .{ .string = try std.fmt.allocPrint(r.arena, "{s} {d}, {d}", .{ month_names[d.month - 1], d.day, d.year }) };
            }
            return .{ .string = try formatDate(r, d, try stringArg(r, f, 0, line), line) };
        },
        .slugify => {
            const s = try textArg(r, f, v, line) orelse return v;
            return .{ .string = try slug(r.arena, s) };
        },
        .truncate => {
            const s = try plainText(r, try textArg(r, f, v, line) orelse return v, v == .html);
            const n = try intArg(r, f, 0, line);
            const suffix = if (f.args.len > 1) try stringArg(r, f, 1, line) else "…";
            return .{ .string = try truncate(r.arena, s, n, suffix) };
        },
        .markdownify => {
            const s = try textArg(r, f, v, line) orelse return v;
            return .{ .html = try markdown.toHtml(r.arena, s) };
        },
        .json => {
            var aw: Writer.Allocating = .init(r.arena);
            try writeJson(&aw.writer, v, null, 0);
            return .{ .html = try scriptSafe(r.arena, aw.written()) };
        },
        .dump => {
            var json: Writer.Allocating = .init(r.arena);
            try writeJson(&json.writer, v, 2, 0);
            var aw: Writer.Allocating = .init(r.arena);
            try aw.writer.writeAll("<pre class=\"mortise-dump\"><code>");
            try escapeHtml(&aw.writer, json.written());
            try aw.writer.writeAll("</code></pre>");
            return .{ .html = aw.written() };
        },
        .where => {
            const items = try listArg(r, f, v, line) orelse return v;
            const key = try stringArg(r, f, 0, line);
            const want: ?Value = if (f.args.len > 1) try evalExpr(r, f.args[1]) else null;
            var out: std.ArrayList(Value) = .empty;
            for (items) |item| {
                const got = fieldPath(item, key) orelse continue;
                const keep = if (want) |w| switch (got) {
                    .list => |l| for (l) |x| {
                        if (x.eql(w)) break true;
                    } else false,
                    else => got.eql(w),
                } else got.truthy();
                if (keep) try out.append(r.arena, item);
            }
            return .{ .list = out.items };
        },
        .sort => {
            const items = try listArg(r, f, v, line) orelse return v;
            const key: ?[]const u8 = if (f.args.len > 0) try stringArg(r, f, 0, line) else null;
            const sorted = try r.arena.dupe(Value, items);
            std.mem.sort(Value, sorted, key, sortLess);
            return .{ .list = sorted };
        },
        .group_by => {
            const items = try listArg(r, f, v, line) orelse return v;
            const key = try stringArg(r, f, 0, line);
            const date_fmt: ?[]const u8 = if (f.args.len > 1) try stringArg(r, f, 1, line) else null;
            var names: std.ArrayList(Value) = .empty;
            var groups: std.ArrayList(std.ArrayList(Value)) = .empty;
            for (items) |item| {
                var name = fieldPath(item, key) orelse Value.nil;
                if (date_fmt) |df| {
                    const d = parseDate(name.text() orelse "") orelse
                        return r.fail(line, "filter 'group_by' with a date format needs '{s}' to be a YYYY-MM-DD date", .{key});
                    name = .{ .string = try formatDate(r, d, df, line) };
                }
                const idx = for (names.items, 0..) |n, i| {
                    if (n.eql(name)) break i;
                } else blk: {
                    try names.append(r.arena, name);
                    try groups.append(r.arena, .empty);
                    break :blk names.items.len - 1;
                };
                try groups.items[idx].append(r.arena, item);
            }
            const out = try r.arena.alloc(Value, names.items.len);
            for (out, names.items, groups.items) |*o, n, g| {
                const entries = try r.arena.alloc(Entry, 2);
                entries[0] = .{ .key = "name", .value = n };
                entries[1] = .{ .key = "items", .value = .{ .list = g.items } };
                o.* = .{ .object = .{ .entries = entries } };
            }
            return .{ .list = out };
        },
        .limit => {
            const items = try listArg(r, f, v, line) orelse return v;
            const n = try intArg(r, f, 0, line);
            return .{ .list = items[0..@min(items.len, n)] };
        },
        .reverse => {
            const items = try listArg(r, f, v, line) orelse return v;
            const out = try r.arena.dupe(Value, items);
            std.mem.reverse(Value, out);
            return .{ .list = out };
        },
        .first, .last => {
            const items = try listArg(r, f, v, line) orelse return v;
            if (items.len == 0) return .nil;
            return if (f.kind == .first) items[0] else items[items.len - 1];
        },
        .size => return .{ .int = @intCast(switch (v) {
            .nil => 0,
            .string, .html => |s| s.len,
            .list => |l| l.len,
            .object => |o| o.entries.len,
            else => return r.fail(line, "filter 'size' expects a list, object or string, got {s}", .{v.typeName()}),
        }) },
        .join => {
            const items = try listArg(r, f, v, line) orelse return v;
            const sep = if (f.args.len > 0) try stringArg(r, f, 0, line) else " ";
            var aw: Writer.Allocating = .init(r.arena);
            for (items, 0..) |item, i| {
                if (i > 0) try aw.writer.writeAll(sep);
                switch (item) {
                    .nil => {},
                    .boolean => |b| try aw.writer.writeAll(if (b) "true" else "false"),
                    .int => |n| try aw.writer.print("{d}", .{n}),
                    .float => |x| try aw.writer.print("{d}", .{x}),
                    .string, .html => |s| try aw.writer.writeAll(s),
                    .list, .object => return r.fail(line, "filter 'join' cannot join {s}", .{item.typeName()}),
                }
            }
            return .{ .string = aw.written() };
        },
        .reading_time, .word_count => {
            const s = try plainText(r, try textArg(r, f, v, line) orelse return .{ .int = 0 }, v == .html);
            const words = countWords(s);
            if (f.kind == .word_count) return .{ .int = @intCast(words) };
            return .{ .int = @intCast(@max(1, (words + 199) / 200)) };
        },
        .strip_html => {
            const s = try textArg(r, f, v, line) orelse return v;
            return .{ .string = try plainText(r, s, true) };
        },
        .asset, .sri => {
            const path = v.text() orelse return r.fail(line, "filter '{s}' expects a file path such as \"css/site.css\", got {s}", .{ @tagName(f.kind), v.typeName() });
            const assets = r.assets orelse return r.fail(line, "filter '{s}' is not available here", .{@tagName(f.kind)});
            var why: []const u8 = "";
            const answer = try assets.lookupFn(assets.ctx, path, if (f.kind == .asset) .url else .sri, &why);
            return .{ .string = answer orelse return r.fail(line, "filter '{s}': '{s}' {s}", .{ @tagName(f.kind), path, why }) };
        },
    }
}

fn formatDate(r: *Renderer, d: Date, fmt: []const u8, line: usize) RenderError![]const u8 {
    var aw: Writer.Allocating = .init(r.arena);
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%' or i + 1 == fmt.len) {
            try aw.writer.writeByte(fmt[i]);
            continue;
        }
        i += 1;
        switch (fmt[i]) {
            'Y' => try aw.writer.print("{d:0>4}", .{d.year}),
            'm' => try aw.writer.print("{d:0>2}", .{d.month}),
            'd' => try aw.writer.print("{d:0>2}", .{d.day}),
            'e' => try aw.writer.print("{d}", .{d.day}),
            'B' => try aw.writer.writeAll(month_names[d.month - 1]),
            'b' => try aw.writer.writeAll(month_names[d.month - 1][0..3]),
            '%' => try aw.writer.writeByte('%'),
            else => return r.fail(line, "date format does not know '%{c}'; use %Y, %m, %d, %e, %B, %b or %%", .{fmt[i]}),
        }
    }
    return aw.written();
}

/// The text of `v`, null when it is missing, or an error for other types.
fn textArg(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!?[]const u8 {
    return v.text() orelse switch (v) {
        .nil => null,
        else => r.fail(line, "filter '{s}' expects a string, got {s}", .{ @tagName(f.kind), v.typeName() }),
    };
}

fn listArg(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!?[]const Value {
    return switch (v) {
        .nil => null,
        .list => |l| l,
        else => r.fail(line, "filter '{s}' expects a list, got {s}", .{ @tagName(f.kind), v.typeName() }),
    };
}

fn intArg(r: *Renderer, f: Filter, i: usize, line: usize) RenderError!usize {
    const a = try evalExpr(r, f.args[i]);
    if (a != .int or a.int < 0) return r.fail(line, "filter '{s}' expects a whole number, got {s}", .{ @tagName(f.kind), a.typeName() });
    return @intCast(a.int);
}

fn stringArg(r: *Renderer, f: Filter, i: usize, line: usize) RenderError![]const u8 {
    const a = try evalExpr(r, f.args[i]);
    return a.text() orelse r.fail(line, "filter '{s}' expects a string argument, got {s}", .{ @tagName(f.kind), a.typeName() });
}

/// `s` without HTML tags and with common character references decoded,
/// when `is_html`; otherwise `s` unchanged.
fn plainText(r: *Renderer, s: []const u8, is_html: bool) Allocator.Error![]const u8 {
    if (!is_html) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        const c = s[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '>') orelse s.len;
            // Block tags separate words; inline tags such as <code> do not.
            if (isBlockTag(s[i + 1 .. end]) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(r.arena, ' ');
            }
            i = end + 1;
            continue;
        }
        if (c == '&') {
            for ([_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" } }) |e| {
                if (std.mem.startsWith(u8, s[i..], e[0])) {
                    try out.appendSlice(r.arena, e[1]);
                    i += e[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(r.arena, if (c == '\n' or c == '\t' or c == '\r') ' ' else c);
        i += 1;
    }
    // Collapse the runs of spaces that tags and newlines leave.
    var w: usize = 0;
    for (out.items) |c| {
        if (c == ' ' and (w == 0 or out.items[w - 1] == ' ')) continue;
        out.items[w] = c;
        w += 1;
    }
    return std.mem.trimEnd(u8, out.items[0..w], " ");
}

/// Whether the tag body (`/p`, `li class="x"`, `br/`) names an element
/// that starts a new line of text.
fn isBlockTag(body: []const u8) bool {
    const name_start: usize = if (body.len > 0 and body[0] == '/') 1 else 0;
    var end = name_start;
    while (end < body.len and std.ascii.isAlphanumeric(body[end])) end += 1;
    const name = body[name_start..end];
    const blocks = [_][]const u8{
        "p",  "div", "br", "li", "ul", "ol", "h1",    "h2",         "h3",      "h4",     "h5",  "h6",      "tr",     "td",
        "th", "pre", "hr", "dt", "dd", "dl", "table", "blockquote", "section", "header", "nav", "article", "figure",
    };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (s) |c| {
        const space = std.ascii.isWhitespace(c);
        if (!space and !in_word) n += 1;
        in_word = !space;
    }
    return n;
}

/// Lowercase ASCII letters and digits joined by single `-`; other ASCII
/// is a separator and non-ASCII bytes are kept.
fn slug(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', 0x80...0xff => {
            if (dash and out.items.len > 0) try out.append(arena, '-');
            dash = false;
            try out.append(arena, std.ascii.toLower(c));
        },
        '\'' => {},
        else => dash = true,
    };
    return out.items;
}

/// At most `n` characters (code points) of `s`, cut back to a word boundary
/// when one is near, with `suffix` appended when anything was removed.
fn truncate(arena: Allocator, s: []const u8, n: usize, suffix: []const u8) Allocator.Error![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < n) : (count += 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    if (i >= s.len) return s;
    var cut = @min(i, s.len);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |sp| {
        // Prefer a word boundary unless it throws away most of the text.
        if (sp * 2 >= cut) cut = sp;
    }
    const kept = std.mem.trimEnd(u8, s[0..cut], " ,;:.");
    return std.mem.concat(arena, u8, &.{ kept, suffix });
}

/// Writes `v` as JSON, indented by `indent` spaces per level when set.
fn writeJson(w: *Writer, v: Value, indent: ?usize, level: usize) Writer.Error!void {
    switch (v) {
        .nil => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |x| if (std.math.isFinite(x)) try w.print("{d}", .{x}) else try w.writeAll("null"),
        .string, .html => |s| try writeJsonString(w, s),
        .list => |l| {
            if (l.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (l, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, indent, level + 1);
                try writeJson(w, item, indent, level + 1);
            }
            try newline(w, indent, level);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.entries.len == 0) return w.writeAll("{}");
            try w.writeByte('{');
            for (o.entries, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, indent, level + 1);
                try writeJsonString(w, e.key);
                try w.writeAll(if (indent != null) ": " else ":");
                try writeJson(w, e.value, indent, level + 1);
            }
            try newline(w, indent, level);
            try w.writeByte('}');
        },
    }
}

fn newline(w: *Writer, indent: ?usize, level: usize) Writer.Error!void {
    const n = indent orelse return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', n * level);
}

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Makes JSON safe to place inside `<script>`: `<`, `>` and `&` become
/// `\u` escapes, so the text can never close the element, and so do the
/// line separators U+2028 and U+2029.
fn scriptSafe(arena: Allocator, json: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        switch (c) {
            '<' => try out.appendSlice(arena, "\\u003c"),
            '>' => try out.appendSlice(arena, "\\u003e"),
            '&' => try out.appendSlice(arena, "\\u0026"),
            0xe2 => if (i + 2 < json.len and json[i + 1] == 0x80 and (json[i + 2] == 0xa8 or json[i + 2] == 0xa9)) {
                try out.appendSlice(arena, if (json[i + 2] == 0xa8) "\\u2028" else "\\u2029");
                i += 2;
            } else try out.append(arena, c),
            else => try out.append(arena, c),
        }
    }
    return out.items;
}

/// Orders values for `sort`: numbers numerically, strings by bytes,
/// booleans false first, missing values last.
fn sortLess(key: ?[]const u8, a: Value, b: Value) bool {
    const x = if (key) |k| fieldPath(a, k) orelse Value.nil else a;
    const y = if (key) |k| fieldPath(b, k) orelse Value.nil else b;
    const rx = rank(x);
    const ry = rank(y);
    if (rx != ry) return rx < ry;
    return switch (x) {
        .boolean => |p| !p and y.boolean,
        .int, .float => number(x) < number(y),
        .string, .html => |s| std.mem.order(u8, s, y.text().?) == .lt,
        else => false,
    };
}

fn rank(v: Value) u8 {
    return switch (v) {
        .boolean => 0,
        .int, .float => 1,
        .string, .html => 2,
        .list, .object => 3,
        .nil => 4,
    };
}

fn number(v: Value) f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |x| x,
        else => 0,
    };
}

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub const Date = struct { year: u16, month: u8, day: u8 };

/// Parses the `YYYY-MM-DD` prefix of `s`. Anything after the date (a time,
/// for example) is ignored.
pub fn parseDate(s: []const u8) ?Date {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    if (s.len > 10 and s[10] != ' ' and s[10] != 'T') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn writeValue(r: *Renderer, v: Value, w: *Writer, line: usize) RenderError!void {
    switch (v) {
        .nil => {},
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try escapeHtml(w, s),
        .html => |s| try w.writeAll(s),
        .list, .object => return r.fail(line, "cannot output {s}; loop over it or pick a field", .{v.typeName()}),
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestLoader = struct {
    arena: Allocator,
    files: []const struct { []const u8, []const u8 },
    parsed: std.StringHashMapUnmanaged(*const Template) = .empty,

    fn loader(t: *TestLoader) Loader {
        return .{ .ctx = t, .loadFn = load };
    }

    fn load(ctx: *anyopaque, name: []const u8, diag: *Diagnostic) Loader.LoadError!*const Template {
        const t: *TestLoader = @ptrCast(@alignCast(ctx));
        if (t.parsed.get(name)) |tpl| return tpl;
        for (t.files) |f| {
            if (!std.mem.eql(u8, f[0], name)) continue;
            const tpl = try t.arena.create(Template);
            tpl.* = try parse(t.arena, f[0], f[1], diag);
            try t.parsed.put(t.arena, name, tpl);
            return tpl;
        }
        return error.TemplateNotFound;
    }
};

fn testRoot() Object {
    const S = struct {
        const posts = [_]Value{
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "First" } }, .{ .key = "url", .value = .{ .string = "/a/" } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "Second & more" } }, .{ .key = "url", .value = .{ .string = "/b/" } } } } },
        };
        const page = [_]Entry{
            .{ .key = "title", .value = .{ .string = "<Hello>" } },
            .{ .key = "date", .value = .{ .string = "2024-01-05" } },
            .{ .key = "draft", .value = .{ .boolean = false } },
            .{ .key = "count", .value = .{ .int = 3 } },
            .{ .key = "ratio", .value = .{ .float = 1.5 } },
            .{ .key = "tags", .value = .{ .list = &.{ .{ .string = "zig" }, .{ .string = "web" } } } },
        };
        const root = [_]Entry{
            .{ .key = "page", .value = .{ .object = .{ .entries = &page } } },
            .{ .key = "content", .value = .{ .html = "<p>Body</p>" } },
            .{ .key = "posts", .value = .{ .list = &posts } },
            .{ .key = "empty", .value = .{ .list = &.{} } },
            .{ .key = "pages", .value = .{ .list = &pages } },
        };
        const pages = [_]Value{
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "x" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "zig" }} } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "y" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "go" }} } } } } },
        };
    };
    return .{ .entries = &S.root };
}

fn expectRender(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = parse(arena.allocator(), "test.html", src, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    var tl: TestLoader = .{ .arena = arena.allocator(), .files = &.{
        .{ "nav.html", "<nav>{{ page.title }}</nav>" },
        .{ "item.html", "<li>{{ post.title }}</li>" },
        .{ "card.html", "<div class=\"card\">{{ title }}{% if count %} ({{ count }}){% endif %}</div>" },
        .{ "base.html", "<title>{% block title %}Site{% endblock %}</title><main>{% block main %}base main{% endblock %}</main><footer>{% block footer %}(c){% endblock %}</footer>" },
        .{ "doc.html", "{% extends \"base.html\" %}{% block main %}<article>{% block body %}doc body{% endblock %}</article>{% endblock %}" },
    } };
    const out = renderAlloc(arena.allocator(), &tpl, testRoot(), tl.loader(), &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectParseError(src: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.TemplateSyntax, parse(arena.allocator(), "bad.html", src, &diag));
    try testing.expectEqualStrings("bad.html", diag.template);
    testing.expectEqual(line, diag.line) catch |err| {
        std.debug.print("message: {s}\n", .{diag.message});
        return err;
    };
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

fn expectRenderError(src: []const u8, template: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "main.html", src, &diag);
    var tl: TestLoader = .{ .arena = arena.allocator(), .files = &.{
        .{ "self.html", "x{% include \"self.html\" %}" },
        .{ "loop.html", "{% extends \"loop.html\" %}" },
        .{ "broken.html", "\n{{ page.tags }}" },
    } };
    try testing.expectError(error.TemplateRender, renderAlloc(arena.allocator(), &tpl, testRoot(), tl.loader(), &diag));
    try testing.expectEqualStrings(template, diag.template);
    try testing.expectEqual(line, diag.line);
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "output and escaping" {
    try expectRender("<h1>&lt;Hello&gt;</h1>", "<h1>{{ page.title }}</h1>");
    try expectRender("<p>Body</p>", "{{ content }}");
    try expectRender("<Hello>", "{{ page.title | raw }}");
    try expectRender("3 1.5 false", "{{ page.count }} {{ page.ratio }} {{ page.draft }}");
    try expectRender("[]", "[{{ missing }}{{ page.missing.deeper }}]");
    try expectRender("a { b } c", "a { b } c");
    try expectRender("lit", "{{ \"lit\" }}");
}

test "filters" {
    try expectRender("&lt;HELLO&gt;", "{{ page.title | upper }}");
    try expectRender("&lt;hello&gt;", "{{ page.title | lower }}");
    try expectRender("Untitled", "{{ missing | default(\"Untitled\") }}");
    try expectRender("&lt;Hello&gt;", "{{ page.title | default(\"x\") }}");
    try expectRender("January 5, 2024", "{{ page.date | date }}");
    try expectRender("<HELLO>", "{{ page.title | upper | raw }}");
}

test "text filters" {
    try expectRender("hello-world-zig-0-16", "{{ \"Hello, World! Zig 0.16\" | slugify }}");
    try expectRender("its-ok", "{{ \"  It's ok! \" | slugify }}");
    try expectRender("2024/01/05 5 Jan January 100%", "{{ page.date | date(\"%Y/%m/%d %e %b %B 100%%\") }}");
    try expectRender("The quick…", "{{ \"The quick brown fox\" | truncate(12) }}");
    try expectRender("The quick brown fox", "{{ \"The quick brown fox\" | truncate(50) }}");
    try expectRender("The...", "{{ \"The quick brown fox\" | truncate(6, \"...\") }}");
    try expectRender("Body", "{{ content | strip_html }}");
    try expectRender("Set url, then a b", "{{ \"<p>Set <code>url</code>, then</p><p>a<br>b</p>\" | raw | strip_html }}");
    try expectRender("<p><em>hi</em> &amp; bye</p>\n", "{{ \"*hi* & bye\" | markdownify }}");
    try expectRender("1", "{{ content | reading_time }}");
    try expectRender("2 1", "{{ \"<p>one</p><p>two</p>\" | raw | word_count }} {{ content | word_count }}");
    try expectRender("7", "{{ page.title | size }}");
}

test "list filters" {
    try expectRender("web zig", "{{ page.tags | sort | join }}");
    try expectRender("zig, web", "{{ page.tags | join(\", \") }}");
    try expectRender("web", "{{ page.tags | reverse | first }}");
    try expectRender("web 2", "{{ page.tags | last }} {{ page.tags | size }}");
    try expectRender("Second &amp; more,First,", "{% for p in posts | sort(\"url\") | reverse %}{{ p.title }},{% endfor %}");
    try expectRender("First", "{% for p in posts | where(\"url\", \"/a/\") %}{{ p.title }}{% endfor %}");
    try expectRender("First", "{% for p in posts | limit(1) %}{{ p.title }}{% endfor %}");
    try expectRender("2", "{{ posts | where(\"title\") | size }}");
    try expectRender("/a/:First;/b/:Second &amp; more;", "{% for g in posts | group_by(\"url\") %}{{ g.name }}:{% for p in g.items %}{{ p.title }}{% endfor %};{% endfor %}");
    try expectRender("a", "{% for p in grouped | sort %}{% endfor %}a");
}

test "where matches list fields by membership" {
    try expectRender("x", "{% for p in pages | where(\"tags\", \"zig\") %}{{ p.name }}{% endfor %}");
}

test "json and dump" {
    try expectRender("[\"zig\",\"web\"]", "{{ page.tags | json }}");
    try expectRender("\"\\u003cHello\\u003e\"", "{{ page.title | json }}");
    try expectRender("{\"title\":\"First\",\"url\":\"/a/\"}", "{{ posts | first | json }}");
    try expectRender("<pre class=\"mortise-dump\"><code>[\n  &quot;zig&quot;,\n  &quot;web&quot;\n]</code></pre>", "{{ page.tags | dump }}");
}

test "filter argument errors" {
    try expectParseError("{{ x | truncate }}", 1, "needs an argument");
    try expectParseError("{{ x | limit(1, 2) }}", 1, "at most 1 argument");
    try expectParseError("{{ x | where(\"a\" \"b\") }}", 1, "expected ',' or ')'");
    try expectRenderError("{{ page.tags | truncate(3) }}", "main.html", 1, "expects a string");
    try expectRenderError("{{ page.title | limit(2) }}", "main.html", 1, "expects a list");
    try expectRenderError("{{ page.tags | limit(\"2\") }}", "main.html", 1, "whole number");
}

test "strict mode" {
    try expectRenderStrict("Untitled|", "{{ page.subtitle | default(\"Untitled\") }}|{% if page.subtitle %}{{ page.subtitle }}{% endif %}");
    try expectRenderStrict("", "{% for t in page.missing %}{{ t }}{% endfor %}");
    try expectStrictError("\n{{ page.titel }}", 2, "'page.titel' is not defined");
    try expectStrictError("{{ pgae.title }}", 1, "undefined variable 'pgae.title'");
    try expectStrictError("{% for p in sit.posts %}{% endfor %}", 1, "undefined variable 'sit'");
    try expectStrictError("{% for t in page.tags %}{{ t.name }}{% endfor %}", 1, "'t.name' is not defined");
}

fn expectRenderStrict(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "s.html", src, &diag);
    const out = renderAllocWith(arena.allocator(), &tpl, testRoot(), null, .{ .strict = true }, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectStrictError(src: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "s.html", src, &diag);
    // Lenient rendering of the same template succeeds.
    _ = try renderAlloc(arena.allocator(), &tpl, testRoot(), null, &diag);
    try testing.expectError(error.TemplateRender, renderAllocWith(arena.allocator(), &tpl, testRoot(), null, .{ .strict = true }, &diag));
    try testing.expectEqual(line, diag.line);
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "conditionals" {
    try expectRender("yes", "{% if page.title %}yes{% endif %}");
    try expectRender("no", "{% if page.draft %}yes{% else %}no{% endif %}");
    try expectRender("b", "{% if missing %}a{% elif page.count == 3 %}b{% else %}c{% endif %}");
    try expectRender("ok", "{% if not page.draft and page.count != 4 %}ok{% endif %}");
    try expectRender("ok", "{% if missing or page.title == \"<Hello>\" %}ok{% endif %}");
    try expectRender("", "{% if empty %}x{% endif %}");
}

test "loops" {
    try expectRender("1:First,2:Second &amp; more.", "{% for p in posts %}{{ loop.index }}:{{ p.title }}{% if not loop.last %},{% endif %}{% endfor %}.");
    try expectRender("", "{% for p in empty %}x{% endfor %}");
    try expectRender("", "{% for p in missing %}x{% endfor %}");
    try expectRender("zig web ", "{% for t in page.tags %}{{ t }} {% endfor %}");
}

test "includes share scope" {
    try expectRender("<nav>&lt;Hello&gt;</nav>", "{% include \"nav.html\" %}");
    try expectRender("<ul><li>First</li><li>Second &amp; more</li></ul>", "<ul>{% for post in posts %}{% include \"item.html\" %}{% endfor %}</ul>");
}

test "include arguments" {
    try expectRender("<div class=\"card\">&lt;Hello&gt; (3)</div>", "{% include \"card.html\" title=page.title count=page.count %}");
    try expectRender("<div class=\"card\">Fixed</div>", "{% include \"card.html\" title=\"Fixed\" %}");
    // Arguments last only for the include.
    try expectRender("<div class=\"card\">x</div>[]", "{% include \"card.html\" title='x' %}[{{ title }}]");
    try expectRender("<div class=\"card\">First</div><div class=\"card\">Second &amp; more</div>", "{% for p in posts %}{% include \"card.html\" title=p.title %}{% endfor %}");
}

test "extends and blocks" {
    // A child fills the parent's blocks; the rest keeps its defaults.
    try expectRender("<title>Home</title><main>Hi</main><footer>(c)</footer>", "{% extends \"base.html\" %}{% block title %}Home{% endblock %}{% block main %}Hi{% endblock main %}");
    // Text outside blocks in a child is ignored.
    try expectRender("<title>Site</title><main>base main</main><footer>(c)</footer>", "{% extends \"base.html\" %}ignored");
    // super renders the parent's content of the block.
    try expectRender("<title>Home | Site</title><main>base main</main><footer>(c) 2024</footer>", "{% extends \"base.html\" %}{% block title %}Home | {{ super }}{% endblock %}{% block footer %}{{ super }} 2024{% endblock %}");
    // Three levels: a block from the grandchild fills a block the middle
    // template added inside one of the root's.
    try expectRender("<title>Site</title><main><article>mine, then doc body</article></main><footer>(c)</footer>", "{% extends \"doc.html\" %}{% block body %}mine, then {{ super }}{% endblock %}");
    // Without extends, blocks render in place.
    try expectRender("a[b]c", "a[{% block x %}b{% endblock %}]c");
}

test "extends errors" {
    try expectParseError("<p>\n{% extends \"base.html\" %}", 2, "must come first");
    try expectParseError("{% extends \"a.html\" %}{% extends \"b.html\" %}", 1, "only one parent");
    try expectParseError("{% block a %}{% endblock %}{% block a %}{% endblock %}", 1, "defined twice");
    try expectParseError("{% block a %}", 1, "is not closed");
    try expectParseError("{% block a %}{% endblock b %}", 1, "closes block 'a'");
    try expectParseError("{{ super }}", 1, "only inside a block");
    try expectParseError("{% include \"x.html\" a %}", 1, "expected '=' after 'a'");
    try expectRenderError("{% extends \"nope.html\" %}", "main.html", 1, "was not found");
    try expectRenderError("{% extends \"loop.html\" %}", "loop.html", 1, "more than 16 deep");
}

test "whitespace control and comments" {
    try expectRender("<ul>\n  <li>zig</li>\n  <li>web</li>\n</ul>",
        \\<ul>
        \\  {%- for t in page.tags %}
        \\  <li>{{ t }}</li>
        \\  {%- endfor %}
        \\</ul>
    );
    try expectRender("a|b", "a  {{- \"|\" -}}  \n b");
    try expectRender("ab", "a{# a comment with }} inside #}b");
}

test "templates record whether they read site collections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const a = try parse(arena.allocator(), "a", "{% for p in site.posts %}{{ p.title }}{% endfor %}", &diag);
    try testing.expect(a.reads_collections);
    const b = try parse(arena.allocator(), "b", "{% if site.pages %}x{% endif %}", &diag);
    try testing.expect(b.reads_collections);
    const c = try parse(arena.allocator(), "c", "{{ site.title }} {{ page.posts }}", &diag);
    try testing.expect(!c.reads_collections);
}

test "includes are recorded for dependency tracking" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "t", "{% include \"a.html\" %}{% if x %}{% include 'b.html' %}{% endif %}", &diag);
    try testing.expectEqual(@as(usize, 2), tpl.includes.len);
    try testing.expectEqualStrings("b.html", tpl.includes[1]);
}

test "syntax errors" {
    try expectParseError("a\n{{ page.title", 2, "unclosed");
    try expectParseError("{% if x %}\nno end", 1, "'if' is not closed");
    try expectParseError("{% for x in y %}", 1, "'for' is not closed");
    try expectParseError("\n\n{% endif %}", 3, "unexpected 'endif'");
    try expectParseError("{% if x %}{% else %}{% elif y %}{% endif %}", 1, "after 'else'");
    try expectParseError("{% if x %}{% endfor %}", 1, "inside 'if'");
    try expectParseError("{{ x | shout }}", 1, "unknown filter 'shout'");
    try expectParseError("{{ x | default }}", 1, "needs an argument");
    try expectParseError("{{ x | upper(1) }}", 1, "takes no argument");
    try expectParseError("{% render x %}", 1, "unknown statement");
    try expectParseError("{% include nav %}", 1, "quoted template name");
    try expectParseError("{% for in y %}", 1, "expected 'in'");
    try expectParseError("{% if x = 1 %}{% endif %}", 1, "did you mean '=='");
    try expectParseError("{{ }}", 1, "empty output tag");
    try expectParseError("{{ \"open }}", 1, "unclosed");
}

test "render errors name the template and line" {
    try expectRenderError("\n{{ posts }}", "main.html", 2, "cannot output a list");
    try expectRenderError("{% for x in page.title %}{% endfor %}", "main.html", 1, "cannot loop over a string");
    try expectRenderError("{% include \"missing.html\" %}", "main.html", 1, "was not found");
    try expectRenderError("{% include \"self.html\" %}", "self.html", 1, "nested more than");
    try expectRenderError("{% include \"broken.html\" %}", "broken.html", 2, "cannot output a list");
    try expectRenderError("{{ page.count | upper }}", "main.html", 1, "expects a string");
    try expectRenderError("{{ page.title | date }}", "main.html", 1, "expects YYYY-MM-DD");
}

test "parseDate" {
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, parseDate("2024-02-29").?);
    try testing.expect(parseDate("2023-02-29") == null);
    try testing.expect(parseDate("2024-13-01") == null);
    try testing.expect(parseDate("2024-01-05T10:00:00Z") != null);
    try testing.expect(parseDate("2024-01-05x") == null);
    try testing.expect(parseDate("Jan 5") == null);
}
