//! Markdown subset to HTML. The supported subset is specified in
//! docs/markdown.md; anything outside it renders as literal text.
//!
//! Rendering never fails on input: every byte sequence is valid Markdown.
//! All memory comes from the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const highlight = @import("highlight.zig");

pub const Error = Allocator.Error || Writer.Error;

/// Renders `src` to HTML. The result is allocated with `arena`.
pub fn toHtml(arena: Allocator, src: []const u8) Allocator.Error![]u8 {
    return (try toDocument(arena, src)).html;
}

pub const Heading = struct {
    level: u8,
    /// The heading's anchor id.
    id: []const u8,
    /// The heading's plain text, without markup.
    text: []const u8,
};

pub const Document = struct {
    html: []u8,
    /// Every heading, in document order.
    headings: []const Heading,
    /// Whether the document uses a component (callout, container, badge,
    /// or key) that needs `components_css`.
    uses_components: bool,
};

/// The stylesheet for components, written to the site as `mortise.css`.
pub const components_css = @embedFile("components.css");

/// Renders `src` and also returns its headings, for tables of contents.
pub fn toDocument(arena: Allocator, src: []const u8) Allocator.Error!Document {
    var aw: Writer.Allocating = .init(arena);
    var r: Renderer = .{ .arena = arena };
    // An allocating writer only fails when it runs out of memory.
    renderWith(&r, src, &aw.writer) catch return error.OutOfMemory;
    const html = try aw.toOwnedSlice();
    // Every component's markup carries an mt- class.
    const uses = std.mem.indexOf(u8, html, "class=\"mt-") != null;
    return .{ .html = html, .headings = r.headings.items, .uses_components = uses };
}

/// Renders `src` to HTML on `w`. Scratch memory comes from `arena`.
pub fn render(arena: Allocator, src: []const u8, w: *Writer) Error!void {
    var r: Renderer = .{ .arena = arena };
    try renderWith(&r, src, w);
}

fn renderWith(r: *Renderer, src: []const u8, w: *Writer) Error!void {
    const lines = try splitLines(r.arena, src);
    const doc = try parseBlocks(r.arena, lines);
    var aw: Writer.Allocating = .init(r.arena);
    renderBlocks(r, doc.blocks, false, &aw.writer) catch return error.OutOfMemory;
    try finishFootnotes(r, aw.written(), w);
}

/// Surrounds a footnote label in rendered HTML until it is numbered.
const fn_marker = "\x01mt-fn\x01";

/// `[^label]` at the start of `s`: the label, or null.
fn footnoteRef(s: []const u8) ?[]const u8 {
    if (s.len < 4 or s[1] != '^') return null;
    const close = std.mem.indexOfScalarPos(u8, s, 2, ']') orelse return null;
    const label = s[2..close];
    if (label.len == 0) return null;
    for (label) |c| if (c <= ' ' or c == '[') return null;
    return label;
}

/// Replaces footnote placeholders in `html` with numbered references, in
/// order of first use, and appends the footnotes. References to labels
/// with no definition are written back as literal text.
fn finishFootnotes(r: *Renderer, html: []const u8, w: *Writer) Error!void {
    var order: std.ArrayList([]const u8) = .empty;
    var refs: std.StringHashMapUnmanaged(usize) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, fn_marker)) |start| {
        try w.writeAll(html[i..start]);
        const label_start = start + fn_marker.len;
        const end = std.mem.indexOfPos(u8, html, label_start, fn_marker) orelse html.len;
        const label = html[label_start..end];
        i = @min(end + fn_marker.len, html.len);
        if (!r.footnotes.contains(label)) {
            try w.print("[^{s}]", .{label});
            continue;
        }
        const n = for (order.items, 0..) |l, k| {
            if (std.mem.eql(u8, l, label)) break k + 1;
        } else blk: {
            try order.append(r.arena, label);
            break :blk order.items.len;
        };
        const gop = try refs.getOrPut(r.arena, label);
        const use = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        gop.value_ptr.* = use;
        const id_suffix = if (use > 1) try std.fmt.allocPrint(r.arena, "-{d}", .{use}) else "";
        try w.writeAll("<sup class=\"mt-fnref\" id=\"fnref-");
        try escapeHtml(w, label);
        try w.writeAll(id_suffix);
        try w.writeAll("\"><a href=\"#fn-");
        try escapeHtml(w, label);
        try w.print("\">{d}</a></sup>", .{n});
    }
    try w.writeAll(html[i..]);
    if (order.items.len == 0) return;
    try w.writeAll("<section class=\"mt-footnotes\">\n<ol>\n");
    for (order.items) |label| {
        try w.writeAll("<li id=\"fn-");
        try escapeHtml(w, label);
        try w.writeAll("\">\n");
        // The back link goes inside the last paragraph when there is one.
        const content = r.footnotes.get(label).?;
        const in_para = std.mem.endsWith(u8, content, "</p>\n");
        try w.writeAll(if (in_para) content[0 .. content.len - "</p>\n".len] else content);
        try w.writeAll(if (in_para) " " else "");
        try w.writeAll("<a class=\"mt-fnback\" href=\"#fnref-");
        try escapeHtml(w, label);
        try w.writeAll("\" aria-label=\"Back to the text\">↩</a>");
        try w.writeAll(if (in_para) "</p>\n</li>\n" else "\n</li>\n");
    }
    try w.writeAll("</ol>\n</section>\n");
}

/// A URL-friendly slug of `text`, as used for heading ids: lowercase ASCII
/// letters and digits, `-` and `_`, spaces as `-`, other punctuation
/// dropped, non-ASCII bytes kept. Empty text gives "section".
pub fn slugify(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
    for (text) |c| switch (c) {
        'A'...'Z' => try slug.append(arena, c + 32),
        'a'...'z', '0'...'9', '-', '_', 0x80...0xff => try slug.append(arena, c),
        ' ', '\t', '\n' => try slug.append(arena, '-'),
        else => {},
    };
    return if (slug.items.len == 0) "section" else slug.items;
}

// ---------------------------------------------------------------------------
// Blocks

const Block = union(enum) {
    heading: struct { level: u8, text: []const u8 },
    paragraph: []const u8,
    code: Code,
    list: List,
    quote: []const Block,
    thematic_break,
    table: Table,
    callout: struct { kind: CalloutKind, children: []const Block },
    /// `[^label]: text`; rendered at the end of the document.
    footnote_def: struct { label: []const u8, children: []const Block },
    /// `Term` followed by `: Definition` lines.
    definitions: []const Definition,
    container: struct { kind: ContainerKind, title: []const u8, children: []const Block },
};

const Code = struct { info: []const u8, meta: []const u8 = "", text: []const u8 };

const Definition = struct { term: []const u8, defs: []const []const u8 };

/// Options from a code fence's info string after the language:
///
///   ```zig title="build.zig" {2,4-6} lineNumbers
const CodeMeta = struct {
    title: []const u8 = "",
    /// Highlighted line ranges, 1-based and inclusive.
    marked: []const [2]usize = &.{},
    line_numbers: bool = false,

    fn parse(arena: Allocator, meta: []const u8) Allocator.Error!CodeMeta {
        var m: CodeMeta = .{};
        var ranges: std.ArrayList([2]usize) = .empty;
        var i: usize = 0;
        while (i < meta.len) {
            while (i < meta.len and (meta[i] == ' ' or meta[i] == '\t')) i += 1;
            if (i >= meta.len) break;
            const rest = meta[i..];
            if (std.mem.startsWith(u8, rest, "title=") and rest.len > 6 and (rest[6] == '"' or rest[6] == '\'')) {
                const q = rest[6];
                const close = std.mem.indexOfScalarPos(u8, rest, 7, q) orelse rest.len;
                m.title = rest[7..close];
                i += @min(close + 1, rest.len);
                continue;
            }
            if (rest[0] == '{') {
                const close = std.mem.indexOfScalar(u8, rest, '}') orelse rest.len;
                var parts = std.mem.splitScalar(u8, rest[1..close], ',');
                while (parts.next()) |part| {
                    const p = std.mem.trim(u8, part, " ");
                    const dash = std.mem.indexOfScalar(u8, p, '-');
                    const a = std.fmt.parseInt(usize, p[0 .. dash orelse p.len], 10) catch continue;
                    const b = if (dash) |d| std.fmt.parseInt(usize, p[d + 1 ..], 10) catch a else a;
                    try ranges.append(arena, .{ @min(a, b), @max(a, b) });
                }
                i += @min(close + 1, rest.len);
                continue;
            }
            const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            const word = rest[0..end];
            if (std.mem.eql(u8, word, "lineNumbers") or std.mem.eql(u8, word, "showLineNumbers")) m.line_numbers = true;
            i += end;
        }
        m.marked = ranges.items;
        return m;
    }

    fn isMarked(m: CodeMeta, line: usize) bool {
        for (m.marked) |r| if (line >= r[0] and line <= r[1]) return true;
        return false;
    }
};

/// GitHub-style alerts: a block quote whose first line is `[!NOTE]` etc.
pub const CalloutKind = enum {
    note,
    tip,
    important,
    warning,
    caution,

    fn label(k: CalloutKind) []const u8 {
        return switch (k) {
            .note => "Note",
            .tip => "Tip",
            .important => "Important",
            .warning => "Warning",
            .caution => "Caution",
        };
    }
};

/// Fenced containers: `:::card Title` ... `:::`.
pub const ContainerKind = enum {
    card,
    grid,
    details,
    figure,
    actions,
    steps,
    /// Tabs: holds `:::tab Label` containers.
    tabs,
    tab,
    /// Tabs whose panels are the code blocks inside, labeled by title.
    code_group,

    fn fromName(name: []const u8) ?ContainerKind {
        if (std.mem.eql(u8, name, "code-group")) return .code_group;
        if (std.mem.eql(u8, name, "code_group")) return null;
        return std.meta.stringToEnum(ContainerKind, name);
    }
};

const Align = enum { none, left, center, right };

const Table = struct {
    aligns: []const Align,
    header: []const []const u8,
    /// Each row has exactly `aligns.len` cells.
    rows: []const []const []const u8,
};

const List = struct {
    ordered: bool,
    start: u32,
    tight: bool,
    items: []const []const Block,
};

const Parsed = struct {
    blocks: []const Block,
    /// A blank line separated two of the top-level blocks.
    blank_between: bool,
};

/// Splits into lines without terminators, dropping a trailing `\r`, and
/// expands tabs in leading whitespace to the next multiple of four columns.
fn splitLines(arena: Allocator, src: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        try lines.append(arena, try expandLeadingTabs(arena, line));
    }
    // A final newline does not start another line.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return lines.items;
}

fn expandLeadingTabs(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var ws: usize = 0;
    while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) ws += 1;
    if (std.mem.indexOfScalar(u8, line[0..ws], '\t') == null) return line;
    var out: std.ArrayList(u8) = .empty;
    for (line[0..ws]) |c| {
        if (c == '\t') {
            try out.appendNTimes(arena, ' ', 4 - out.items.len % 4);
        } else try out.append(arena, ' ');
    }
    try out.appendSlice(arena, line[ws..]);
    return out.items;
}

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    return i;
}

fn isBlank(line: []const u8) bool {
    for (line) |c| if (c != ' ' and c != '\t') return false;
    return true;
}

fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimStart(u8, s, " \t");
}

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimEnd(u8, s, " \t");
}

fn parseBlocks(arena: Allocator, lines: []const []const u8) Allocator.Error!Parsed {
    var blocks: std.ArrayList(Block) = .empty;
    var blank_between = false;
    var pending_blank = false;
    var i: usize = 0;
    while (i < lines.len) {
        const line = lines[i];
        if (isBlank(line)) {
            pending_blank = blocks.items.len > 0;
            i += 1;
            continue;
        }
        if (pending_blank) blank_between = true;
        pending_blank = false;

        if (fenceStart(line)) |f| {
            i = try parseFence(arena, lines, i, f, &blocks);
        } else if (isThematicBreak(line)) {
            try blocks.append(arena, .thematic_break);
            i += 1;
        } else if (quoteContent(line) != null) {
            i = try parseQuote(arena, lines, i, &blocks);
        } else if (footnoteDefStart(line)) |fd| {
            i = try parseFootnoteDef(arena, lines, i, fd, &blocks);
        } else if (isDefinitionStart(lines, i)) {
            i = try parseDefinitions(arena, lines, i, &blocks);
        } else if (containerStart(line)) |c| {
            i = try parseContainer(arena, lines, i, c, &blocks);
        } else if (try tableStart(arena, lines, i)) |t| {
            i = try parseTable(arena, lines, i, t, &blocks);
        } else if (atxHeading(line)) |h| {
            try blocks.append(arena, h);
            i += 1;
        } else if (listMarker(line)) |m| {
            i = try parseList(arena, lines, i, m, &blocks);
        } else {
            i = try parseParagraph(arena, lines, i, &blocks);
        }
    }
    return .{ .blocks = blocks.items, .blank_between = blank_between };
}

const Fence = struct {
    indent: usize,
    char: u8,
    len: usize,
    /// The info string's first word: the language.
    info: []const u8,
    /// The rest of the info string: `title="..."`, `{1,3-5}`, `lineNumbers`.
    meta: []const u8,
};

fn fenceStart(line: []const u8) ?Fence {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return null;
    const c = line[ind];
    if (c != '`' and c != '~') return null;
    var n: usize = 0;
    while (ind + n < line.len and line[ind + n] == c) n += 1;
    if (n < 3) return null;
    const rest = std.mem.trim(u8, line[ind + n ..], " \t");
    if (c == '`' and std.mem.indexOfScalar(u8, rest, '`') != null) return null;
    const word_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    return .{ .indent = ind, .char = c, .len = n, .info = rest[0..word_end], .meta = std.mem.trim(u8, rest[word_end..], " \t") };
}

fn isFenceClose(line: []const u8, f: Fence) bool {
    const ind = indentOf(line);
    if (ind > 3) return false;
    var n: usize = 0;
    while (ind + n < line.len and line[ind + n] == f.char) n += 1;
    return n >= f.len and isBlank(line[ind + n ..]);
}

fn parseFence(arena: Allocator, lines: []const []const u8, start: usize, f: Fence, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var text: std.ArrayList(u8) = .empty;
    var j = start + 1;
    while (j < lines.len) : (j += 1) {
        const line = lines[j];
        if (isFenceClose(line, f)) {
            j += 1;
            break;
        }
        // Remove up to the fence's own indentation from each content line.
        const strip = @min(f.indent, indentOf(line));
        try text.appendSlice(arena, line[strip..]);
        try text.append(arena, '\n');
    }
    try out.append(arena, .{ .code = .{ .info = f.info, .meta = f.meta, .text = text.items } });
    return j;
}

fn atxHeading(line: []const u8) ?Block {
    const ind = indentOf(line);
    if (ind > 3) return null;
    var level: usize = 0;
    while (ind + level < line.len and line[ind + level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    const after = line[ind + level ..];
    if (after.len > 0 and after[0] != ' ' and after[0] != '\t') return null;

    var content = std.mem.trim(u8, after, " \t");
    // Strip an optional closing sequence of `#`s preceded by a space.
    var k = content.len;
    while (k > 0 and content[k - 1] == '#') k -= 1;
    if (k == 0) {
        content = "";
    } else if (k < content.len and (content[k - 1] == ' ' or content[k - 1] == '\t')) {
        content = trimRight(content[0..k]);
    }
    return .{ .heading = .{ .level = @intCast(level), .text = content } };
}

const Marker = struct {
    ordered: bool,
    /// The bullet character, or the `.`/`)` delimiter of an ordered marker.
    char: u8,
    start: u32,
    /// Column where the item's content begins; continuation lines must be
    /// indented at least this far.
    content_col: usize,
    empty: bool,
};

fn listMarker(line: []const u8) ?Marker {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return null;
    const rest = line[ind..];
    var m: Marker = .{ .ordered = false, .char = 0, .start = 1, .content_col = 0, .empty = false };
    var mlen: usize = 0;
    switch (rest[0]) {
        '-', '*', '+' => {
            m.char = rest[0];
            mlen = 1;
        },
        '0'...'9' => {
            while (mlen < rest.len and mlen < 9 and std.ascii.isDigit(rest[mlen])) mlen += 1;
            if (mlen >= rest.len or (rest[mlen] != '.' and rest[mlen] != ')')) return null;
            m.ordered = true;
            m.char = rest[mlen];
            m.start = std.fmt.parseInt(u32, rest[0..mlen], 10) catch return null;
            mlen += 1;
        },
        else => return null,
    }
    const after = rest[mlen..];
    if (after.len == 0 or isBlank(after)) {
        if (after.len > 0 and after[0] != ' ' and after[0] != '\t') return null;
        m.empty = true;
        m.content_col = ind + mlen + 1;
        return m;
    }
    if (after[0] != ' ') return null;
    var spaces = indentOf(after);
    // Five or more spaces after the marker: the content starts one column in.
    if (spaces > 4) spaces = 1;
    m.content_col = ind + mlen + spaces;
    return m;
}

/// Whether `line` starts a block that may interrupt a paragraph.
fn interruptsParagraph(line: []const u8) bool {
    if (fenceStart(line) != null or atxHeading(line) != null) return true;
    if (isThematicBreak(line) or quoteContent(line) != null or containerStart(line) != null) return true;
    if (footnoteDefStart(line) != null) return true;
    if (listMarker(line)) |m| return !m.empty and (!m.ordered or m.start == 1);
    return false;
}

fn parseList(arena: Allocator, lines: []const []const u8, start: usize, first: Marker, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var items: std.ArrayList([]const Block) = .empty;
    var tight = true;
    var i = start;
    var end_of_list = start;

    while (i < lines.len) {
        const mk = listMarker(lines[i]) orelse break;
        if (mk.ordered != first.ordered or mk.char != first.char) break;

        var item_lines: std.ArrayList([]const u8) = .empty;
        const head = lines[i];
        try item_lines.append(arena, if (mk.empty) "" else head[@min(mk.content_col, head.len)..]);
        var in_paragraph = !mk.empty;

        var j = i + 1;
        while (j < lines.len) : (j += 1) {
            const l = lines[j];
            if (isBlank(l)) {
                // An empty item may not begin with a blank line.
                if (mk.empty and j == i + 1) break;
                try item_lines.append(arena, "");
                in_paragraph = false;
                continue;
            }
            if (indentOf(l) >= mk.content_col) {
                const inner = l[mk.content_col..];
                try item_lines.append(arena, inner);
                in_paragraph = !(fenceStart(inner) != null or atxHeading(inner) != null);
                continue;
            }
            // Lazy continuation of a paragraph.
            if (in_paragraph and !interruptsParagraph(l) and listMarker(l) == null) {
                try item_lines.append(arena, trimLeft(l));
                continue;
            }
            break;
        }

        var used = item_lines.items.len;
        while (used > 1 and item_lines.items[used - 1].len == 0) used -= 1;
        const trailing_blanks = item_lines.items.len - used;

        const parsed = try parseBlocks(arena, item_lines.items[0..used]);
        if (parsed.blank_between) tight = false;
        try items.append(arena, parsed.blocks);

        end_of_list = j - trailing_blanks;
        i = j;
        if (trailing_blanks > 0 and i < lines.len) {
            if (listMarker(lines[i])) |next| {
                if (next.ordered == first.ordered and next.char == first.char) tight = false;
            }
        }
    }

    try out.append(arena, .{ .list = .{
        .ordered = first.ordered,
        .start = first.start,
        .tight = tight,
        .items = items.items,
    } });
    // Leave trailing blank lines to the caller so it can see them.
    return end_of_list;
}

fn parseParagraph(arena: Allocator, lines: []const []const u8, start: usize, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, trimLeft(lines[start]));
    var j = start + 1;
    while (j < lines.len) : (j += 1) {
        const l = lines[j];
        // A setext underline turns the paragraph so far into a heading. It
        // is checked first because `---` would otherwise be a thematic break.
        if (setextLevel(l)) |level| {
            try out.append(arena, .{ .heading = .{ .level = level, .text = trimRight(text.items) } });
            return j + 1;
        }
        if (isBlank(l) or interruptsParagraph(l)) break;
        try text.append(arena, '\n');
        try text.appendSlice(arena, trimLeft(l));
    }
    try out.append(arena, .{ .paragraph = trimRight(text.items) });
    return j;
}

/// 1 for a `===` underline, 2 for `---`, null otherwise.
fn setextLevel(line: []const u8) ?u8 {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return null;
    const c = line[ind];
    if (c != '=' and c != '-') return null;
    const rest = trimRight(line[ind..]);
    for (rest) |x| if (x != c) return null;
    return if (c == '=') 1 else 2;
}

/// Splits a table row into trimmed cells. Leading and trailing pipes are
/// optional; `\|` is a literal pipe inside a cell.
fn splitRow(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var row = std.mem.trim(u8, line, " \t");
    if (row.len > 0 and row[0] == '|') row = row[1..];
    if (row.len > 0 and row[row.len - 1] == '|' and (row.len < 2 or row[row.len - 2] != '\\')) row = row[0 .. row.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var cell: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < row.len) : (i += 1) {
        if (row[i] == '\\' and i + 1 < row.len and row[i + 1] == '|') {
            try cell.append(arena, '|');
            i += 1;
        } else if (row[i] == '|') {
            try cells.append(arena, std.mem.trim(u8, cell.items, " \t"));
            cell = .empty;
        } else try cell.append(arena, row[i]);
    }
    try cells.append(arena, std.mem.trim(u8, cell.items, " \t"));
    return cells.items;
}

/// Parses a delimiter row such as `| :-- | :-: | --: |`.
fn delimiterRow(arena: Allocator, line: []const u8) Allocator.Error!?[]const Align {
    if (std.mem.indexOfScalar(u8, line, '-') == null) return null;
    const cells = try splitRow(arena, line);
    const aligns = try arena.alloc(Align, cells.len);
    for (cells, aligns) |c, *a| {
        if (c.len == 0) return null;
        const left = c[0] == ':';
        const right = c[c.len - 1] == ':';
        const dashes = c[@intFromBool(left) .. c.len - @intFromBool(right and c.len > 1)];
        if (dashes.len == 0) return null;
        for (dashes) |x| if (x != '-') return null;
        a.* = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return aligns;
}

/// A table starts with a header row containing `|`, followed by a
/// delimiter row with the same number of cells.
fn tableStart(arena: Allocator, lines: []const []const u8, i: usize) Allocator.Error!?[]const Align {
    if (i + 1 >= lines.len or indentOf(lines[i]) > 3) return null;
    if (std.mem.indexOfScalar(u8, lines[i], '|') == null) return null;
    const aligns = (try delimiterRow(arena, lines[i + 1])) orelse return null;
    if ((try splitRow(arena, lines[i])).len != aligns.len) return null;
    return aligns;
}

fn parseTable(arena: Allocator, lines: []const []const u8, start: usize, aligns: []const Align, out: *std.ArrayList(Block)) Allocator.Error!usize {
    const header = try splitRow(arena, lines[start]);
    var rows: std.ArrayList([]const []const u8) = .empty;
    var j = start + 2;
    while (j < lines.len) : (j += 1) {
        const l = lines[j];
        if (isBlank(l) or (interruptsParagraph(l) and std.mem.indexOfScalar(u8, l, '|') == null)) break;
        const cells = try splitRow(arena, l);
        // Pad short rows and drop extra cells so every row fits the header.
        const row = try arena.alloc([]const u8, aligns.len);
        for (row, 0..) |*cell, k| cell.* = if (k < cells.len) cells[k] else "";
        try rows.append(arena, row);
    }
    try out.append(arena, .{ .table = .{ .aligns = aligns, .header = header, .rows = rows.items } });
    return j;
}

/// Three or more `-`, `*`, or `_`, optionally separated by spaces.
fn isThematicBreak(line: []const u8) bool {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len) return false;
    const c = line[ind];
    if (c != '-' and c != '*' and c != '_') return false;
    var n: usize = 0;
    for (line[ind..]) |x| {
        if (x == c) {
            n += 1;
        } else if (x != ' ' and x != '\t') return false;
    }
    return n >= 3;
}

/// The text after a block quote marker (`>` and one optional space), or
/// null if `line` does not start a quote.
fn quoteContent(line: []const u8) ?[]const u8 {
    const ind = indentOf(line);
    if (ind > 3 or ind >= line.len or line[ind] != '>') return null;
    const rest = line[ind + 1 ..];
    return if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest;
}

fn parseQuote(arena: Allocator, lines: []const []const u8, start: usize, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var inner: std.ArrayList([]const u8) = .empty;
    var j = start;
    var in_paragraph = false;
    while (j < lines.len) : (j += 1) {
        const l = lines[j];
        if (quoteContent(l)) |content| {
            try inner.append(arena, content);
            in_paragraph = !isBlank(content) and fenceStart(content) == null;
            continue;
        }
        // Lazy continuation of a paragraph inside the quote.
        if (in_paragraph and !isBlank(l) and !interruptsParagraph(l)) {
            try inner.append(arena, l);
            continue;
        }
        break;
    }
    // `> [!NOTE]` on the first line makes the quote a callout.
    if (inner.items.len > 0) {
        if (calloutMarker(inner.items[0])) |kind| {
            const parsed = try parseBlocks(arena, inner.items[1..]);
            try out.append(arena, .{ .callout = .{ .kind = kind, .children = parsed.blocks } });
            return j;
        }
    }
    const parsed = try parseBlocks(arena, inner.items);
    try out.append(arena, .{ .quote = parsed.blocks });
    return j;
}

const FootnoteDefStart = struct { label: []const u8, first: []const u8 };

/// `[^label]: text` with at most three spaces of indentation.
fn footnoteDefStart(line: []const u8) ?FootnoteDefStart {
    const ind = indentOf(line);
    if (ind > 3) return null;
    const rest = line[ind..];
    const label = footnoteRef(rest) orelse return null;
    const after = rest[label.len + 3 ..];
    if (after.len == 0 or after[0] != ':') return null;
    return .{ .label = label, .first = trimLeft(after[1..]) };
}

/// A footnote's content is its first line plus following lines indented
/// four spaces (blank lines allowed between them), parsed as blocks.
fn parseFootnoteDef(arena: Allocator, lines: []const []const u8, start: usize, fd: FootnoteDefStart, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var inner: std.ArrayList([]const u8) = .empty;
    try inner.append(arena, fd.first);
    var j = start + 1;
    var end = j;
    while (j < lines.len) : (j += 1) {
        const l = lines[j];
        if (isBlank(l)) {
            try inner.append(arena, "");
            continue;
        }
        if (indentOf(l) >= 4) {
            try inner.append(arena, l[4..]);
            end = j + 1;
            continue;
        }
        // Lazy continuation of the first paragraph.
        if (end == j and !interruptsParagraph(l)) {
            try inner.append(arena, trimLeft(l));
            end = j + 1;
            continue;
        }
        break;
    }
    const used = inner.items.len - (j - end);
    const parsed = try parseBlocks(arena, inner.items[0..used]);
    try out.append(arena, .{ .footnote_def = .{ .label = fd.label, .children = parsed.blocks } });
    return end;
}

/// A definition list starts with a term line followed by a `: ` line.
fn isDefinitionStart(lines: []const []const u8, i: usize) bool {
    if (i + 1 >= lines.len or isBlank(lines[i]) or indentOf(lines[i]) > 3 or interruptsParagraph(lines[i])) return false;
    return definitionText(lines[i + 1]) != null;
}

fn definitionText(line: []const u8) ?[]const u8 {
    const ind = indentOf(line);
    if (ind > 3 or ind + 1 >= line.len or line[ind] != ':' or (line[ind + 1] != ' ' and line[ind + 1] != '\t')) return null;
    return trimLeft(line[ind + 1 ..]);
}

fn parseDefinitions(arena: Allocator, lines: []const []const u8, start: usize, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var items: std.ArrayList(Definition) = .empty;
    var j = start;
    while (isDefinitionStart(lines, j)) {
        const term = std.mem.trim(u8, lines[j], " \t");
        j += 1;
        var defs: std.ArrayList([]const u8) = .empty;
        while (j < lines.len) : (j += 1) {
            const d = definitionText(lines[j]) orelse break;
            try defs.append(arena, d);
        }
        try items.append(arena, .{ .term = term, .defs = defs.items });
        // A blank line may separate entries.
        if (j < lines.len and isBlank(lines[j]) and isDefinitionStart(lines, j + 1)) j += 1;
    }
    try out.append(arena, .{ .definitions = items.items });
    return j;
}

fn calloutMarker(line: []const u8) ?CalloutKind {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 4 or !std.mem.startsWith(u8, t, "[!") or t[t.len - 1] != ']') return null;
    const name = t[2 .. t.len - 1];
    inline for (std.meta.fields(CalloutKind)) |f| {
        if (std.ascii.eqlIgnoreCase(name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

const ContainerStart = struct { colons: usize, kind: ContainerKind, title: []const u8 };

/// `:::name optional title`, indented at most three spaces. Only the known
/// container names start a container; anything else is paragraph text.
fn containerStart(line: []const u8) ?ContainerStart {
    const ind = indentOf(line);
    if (ind > 3) return null;
    const rest = line[ind..];
    const colons = runLength(rest, 0, ':');
    if (colons < 3) return null;
    const after = std.mem.trim(u8, rest[colons..], " \t");
    const name_end = std.mem.indexOfAny(u8, after, " \t") orelse after.len;
    const kind = ContainerKind.fromName(after[0..name_end]) orelse return null;
    return .{ .colons = colons, .kind = kind, .title = std.mem.trim(u8, after[name_end..], " \t") };
}

/// A closing fence: only colons, at least as many as the opening fence.
/// Nest containers by giving the outer one more colons.
fn isContainerClose(line: []const u8, colons: usize) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len >= colons and runLength(t, 0, ':') == t.len;
}

fn parseContainer(arena: Allocator, lines: []const []const u8, start: usize, c: ContainerStart, out: *std.ArrayList(Block)) Allocator.Error!usize {
    var j = start + 1;
    while (j < lines.len and !isContainerClose(lines[j], c.colons)) j += 1;
    const parsed = try parseBlocks(arena, lines[start + 1 .. j]);
    try out.append(arena, .{ .container = .{ .kind = c.kind, .title = c.title, .children = parsed.blocks } });
    // Skip the closing fence; an unclosed container runs to the end.
    return @min(j + 1, lines.len);
}

/// State for rendering one document.
const Renderer = struct {
    arena: Allocator,
    /// Heading ids already used, so each id in the document is unique.
    ids: std.StringHashMapUnmanaged(void) = .empty,
    headings: std.ArrayList(Heading) = .empty,
    /// Tab groups rendered so far, for unique radio names and ids.
    tab_groups: usize = 0,
    /// Rendered footnote content by label.
    footnotes: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// A unique id for a heading whose plain text is `text` (see
    /// `slugify`). Repeats get `-1`, `-2`, and so on.
    fn headingId(r: *Renderer, text: []const u8) Allocator.Error![]const u8 {
        const base = try slugify(r.arena, text);
        var id: []const u8 = base;
        var n: usize = 1;
        while (r.ids.contains(id)) : (n += 1) {
            id = try std.fmt.allocPrint(r.arena, "{s}-{d}", .{ base, n });
        }
        try r.ids.put(r.arena, id, {});
        return id;
    }
};

/// Whether paragraph text starts a task list item: `[ ] ` (false) or
/// `[x] ` / `[X] ` (true).
fn taskMarker(text: []const u8) ?bool {
    if (text.len < 4 or text[0] != '[' or text[2] != ']' or text[3] != ' ') return null;
    return switch (text[1]) {
        ' ' => false,
        'x', 'X' => true,
        else => null,
    };
}

/// Renders tabs without JavaScript: one radio input and label per tab,
/// then one panel per tab; CSS shows the panel whose input is checked.
/// `:::tabs` takes its tabs from `:::tab Label` children; `:::code-group`
/// takes them from its code blocks, labeled by `title="..."` or language.
fn renderTabs(r: *Renderer, kind: ContainerKind, children: []const Block, w: *Writer) Error!void {
    const arena = r.arena;
    const Tab = struct { label: []const u8, body: []const Block };
    var tabs: std.ArrayList(Tab) = .empty;
    for (children, 0..) |child, i| {
        switch (kind) {
            .tabs => if (child == .container and child.container.kind == .tab) {
                const t = child.container;
                try tabs.append(arena, .{ .label = if (t.title.len > 0) t.title else "Tab", .body = t.children });
            },
            else => if (child == .code) {
                const meta = try CodeMeta.parse(arena, child.code.meta);
                const label = if (meta.title.len > 0) meta.title else if (child.code.info.len > 0) child.code.info else "Code";
                try tabs.append(arena, .{ .label = label, .body = children[i .. i + 1] });
            },
        }
    }
    r.tab_groups += 1;
    const group = r.tab_groups;
    try w.print("<div class=\"mt-tabs{s}\">\n", .{if (kind == .code_group) " mt-code-group" else ""});
    for (tabs.items, 0..) |t, k| {
        try w.print("<input type=\"radio\" class=\"mt-tab-input\" name=\"mt-tabs-{d}\" id=\"mt-tabs-{d}-{d}\"{s}>", .{ group, group, k, if (k == 0) " checked" else "" });
        try w.print("<label class=\"mt-tab-label\" for=\"mt-tabs-{d}-{d}\">", .{ group, k });
        try renderInline(arena, t.label, w);
        try w.writeAll("</label>\n");
    }
    for (tabs.items) |t| {
        try w.writeAll("<div class=\"mt-tab-panel\">\n");
        try renderBlocks(r, t.body, false, w);
        try w.writeAll("</div>\n");
    }
    try w.writeAll("</div>\n");
}

/// Renders a fenced code block. Without options it is a plain
/// `<pre><code>`. With a title, marked lines, line numbers, or the `diff`
/// language, it is wrapped in `<div class="mt-code">` and every line is a
/// `<span class="mt-line">` so lines can be numbered and styled by CSS.
fn renderCode(arena: Allocator, c: Code, w: *Writer) Error!void {
    const info = try unescapeBackslashes(arena, c.info);
    const meta = try CodeMeta.parse(arena, c.meta);
    const is_diff = std.mem.eql(u8, info, "diff");
    const enhanced = is_diff or meta.title.len > 0 or meta.marked.len > 0 or meta.line_numbers;

    if (enhanced) {
        try w.writeAll(if (meta.line_numbers) "<div class=\"mt-code mt-code-numbered\">\n" else "<div class=\"mt-code\">\n");
        if (meta.title.len > 0) {
            try w.writeAll("<div class=\"mt-code-title\">");
            try escapeHtml(w, meta.title);
            try w.writeAll("</div>\n");
        }
    }
    try w.writeAll("<pre><code");
    if (info.len > 0) {
        try w.writeAll(" class=\"language-");
        try escapeHtml(w, info);
        try w.writeAll("\"");
    }
    try w.writeAll(">");
    if (!enhanced) {
        try highlight.write(w, info, c.text);
        return w.writeAll("</code></pre>\n");
    }

    // Highlight the whole block, then split it into lines. Highlight spans
    // can cross lines (block comments), so open spans are closed at each
    // line end and reopened on the next line.
    var aw: Writer.Allocating = .init(arena);
    highlight.write(&aw.writer, info, c.text) catch return error.OutOfMemory;
    const html = aw.written();
    var open: std.ArrayList([]const u8) = .empty;
    var raw_lines = std.mem.splitScalar(u8, c.text, '\n');
    var html_lines = std.mem.splitScalar(u8, html, '\n');
    var number: usize = 0;
    while (html_lines.next()) |line_html| {
        const raw = raw_lines.next() orelse "";
        // The text ends with a newline; nothing follows the last one.
        if (html_lines.peek() == null and line_html.len == 0) break;
        number += 1;
        var class: []const u8 = "mt-line";
        if (meta.isMarked(number)) {
            class = "mt-line mt-line-marked";
        } else if (is_diff and raw.len > 0) {
            class = switch (raw[0]) {
                '+' => "mt-line mt-line-add",
                '-' => "mt-line mt-line-del",
                '@' => "mt-line mt-line-hunk",
                else => "mt-line",
            };
        }
        try w.print("<span class=\"{s}\">", .{class});
        for (open.items) |tag| try w.writeAll(tag);
        try w.writeAll(line_html);
        try trackSpans(arena, &open, line_html);
        for (open.items) |_| try w.writeAll("</span>");
        try w.writeAll("</span>\n");
    }
    try w.writeAll("</code></pre>\n</div>\n");
}

/// Updates the stack of open `<span ...>` tags after `html`.
fn trackSpans(arena: Allocator, open: *std.ArrayList([]const u8), html: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return;
        const tag = html[lt .. gt + 1];
        if (std.mem.startsWith(u8, tag, "</span")) {
            _ = open.pop();
        } else if (std.mem.startsWith(u8, tag, "<span")) {
            try open.append(arena, tag);
        }
        i = gt + 1;
    }
}

fn writeCell(arena: Allocator, w: *Writer, tag: []const u8, text: []const u8, a: Align) Error!void {
    try w.print("<{s}", .{tag});
    if (a != .none) try w.print(" align=\"{s}\"", .{@tagName(a)});
    try w.writeAll(">");
    try renderInline(arena, text, w);
    try w.print("</{s}>\n", .{tag});
}

fn renderBlocks(r: *Renderer, blocks: []const Block, tight: bool, w: *Writer) Error!void {
    for (blocks) |b| try renderBlock(r, b, tight, w);
}

fn renderBlock(r: *Renderer, b: Block, tight: bool, w: *Writer) Error!void {
    const arena = r.arena;
    switch (b) {
        .thematic_break => try w.writeAll("<hr />\n"),
        .footnote_def => |f| {
            // Collected now, written at the end by `finishFootnotes`. The
            // first definition of a label wins.
            if (r.footnotes.contains(f.label)) return;
            var aw: Writer.Allocating = .init(arena);
            renderBlocks(r, f.children, false, &aw.writer) catch return error.OutOfMemory;
            try r.footnotes.put(arena, f.label, try aw.toOwnedSlice());
        },
        .definitions => |items| {
            try w.writeAll("<dl class=\"mt-dl\">\n");
            for (items) |item| {
                try w.writeAll("<dt>");
                try renderInline(arena, item.term, w);
                try w.writeAll("</dt>\n");
                for (item.defs) |d| {
                    try w.writeAll("<dd>");
                    try renderInline(arena, d, w);
                    try w.writeAll("</dd>\n");
                }
            }
            try w.writeAll("</dl>\n");
        },
        .callout => |c| {
            try w.print("<div class=\"mt-callout mt-callout-{s}\" role=\"note\">\n<p class=\"mt-callout-title\">{s}</p>\n", .{ @tagName(c.kind), c.kind.label() });
            try renderBlocks(r, c.children, false, w);
            try w.writeAll("</div>\n");
        },
        .container => |c| switch (c.kind) {
            .tabs, .code_group => try renderTabs(r, c.kind, c.children, w),
            .details => {
                try w.writeAll("<details class=\"mt-details\">\n<summary>");
                try renderInline(arena, if (c.title.len > 0) c.title else "Details", w);
                try w.writeAll("</summary>\n");
                try renderBlocks(r, c.children, false, w);
                try w.writeAll("</details>\n");
            },
            .figure => {
                try w.writeAll("<figure class=\"mt-figure\">\n");
                try renderBlocks(r, c.children, false, w);
                if (c.title.len > 0) {
                    try w.writeAll("<figcaption>");
                    try renderInline(arena, c.title, w);
                    try w.writeAll("</figcaption>\n");
                }
                try w.writeAll("</figure>\n");
            },
            else => {
                try w.print("<div class=\"mt-{s}\">\n", .{@tagName(c.kind)});
                if (c.title.len > 0) {
                    try w.print("<p class=\"mt-{s}-title\">", .{@tagName(c.kind)});
                    try renderInline(arena, c.title, w);
                    try w.writeAll("</p>\n");
                }
                try renderBlocks(r, c.children, false, w);
                try w.writeAll("</div>\n");
            },
        },
        .table => |t| {
            try w.writeAll("<table>\n<thead>\n<tr>\n");
            for (t.header, t.aligns) |cell, a| try writeCell(arena, w, "th", cell, a);
            try w.writeAll("</tr>\n</thead>\n");
            if (t.rows.len > 0) {
                try w.writeAll("<tbody>\n");
                for (t.rows) |row| {
                    try w.writeAll("<tr>\n");
                    for (row, t.aligns) |cell, a| try writeCell(arena, w, "td", cell, a);
                    try w.writeAll("</tr>\n");
                }
                try w.writeAll("</tbody>\n");
            }
            try w.writeAll("</table>\n");
        },
        .quote => |children| {
            try w.writeAll("<blockquote>\n");
            try renderBlocks(r, children, false, w);
            try w.writeAll("</blockquote>\n");
        },
        .heading => |h| {
            const nodes = try parseInlines(arena, h.text);
            try w.print("<h{d} id=\"", .{h.level});
            const text = try plainText(arena, nodes);
            const id = try r.headingId(text);
            try r.headings.append(arena, .{ .level = h.level, .id = id, .text = text });
            try escapeHtml(w, id);
            try w.writeAll("\">");
            for (nodes) |n| try renderNode(n, w);
            try w.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |p| {
            if (tight) {
                try renderInline(arena, p, w);
            } else {
                try w.writeAll("<p>");
                try renderInline(arena, p, w);
                try w.writeAll("</p>\n");
            }
        },
        .code => |c| try renderCode(arena, c, w),
        .list => |l| {
            if (!l.ordered) {
                try w.writeAll("<ul>\n");
            } else if (l.start != 1) {
                try w.print("<ol start=\"{d}\">\n", .{l.start});
            } else {
                try w.writeAll("<ol>\n");
            }
            for (l.items) |children| {
                // Task list item: `- [ ] text` or `- [x] text`.
                const task = if (children.len > 0 and children[0] == .paragraph) taskMarker(children[0].paragraph) else null;
                if (task) |done| {
                    try w.print("<li class=\"mt-task\"><input type=\"checkbox\" disabled{s}> ", .{if (done) " checked" else ""});
                } else try w.writeAll("<li>");
                for (children, 0..) |child, idx| {
                    if (l.tight and child == .paragraph) {
                        try renderInline(arena, if (idx == 0 and task != null) child.paragraph[4..] else child.paragraph, w);
                        if (idx + 1 < children.len) try w.writeAll("\n");
                    } else {
                        if (idx == 0) try w.writeAll("\n");
                        const block: Block = if (idx == 0 and task != null) .{ .paragraph = child.paragraph[4..] } else child;
                        try renderBlock(r, block, l.tight, w);
                    }
                }
                try w.writeAll("</li>\n");
            }
            try w.writeAll(if (l.ordered) "</ol>\n" else "</ul>\n");
        },
    }
}

// ---------------------------------------------------------------------------
// Inlines

const Delim = struct {
    char: u8,
    /// Characters not yet consumed by an emphasis match.
    count: usize,
    /// Run length before any matching, for the "multiple of 3" rule.
    orig: usize,
    can_open: bool,
    can_close: bool,
    active: bool = true,
    /// Sizes (1 = em, 2 = strong) of matches where this run closed, in order.
    closes: std.ArrayList(u8) = .empty,
    /// Sizes of matches where this run opened, innermost first.
    opens: std.ArrayList(u8) = .empty,
};

const Bracket = struct {
    image: bool,
    /// False once a link has been formed after it: links do not nest.
    active: bool = true,
    /// False once this bracket has been matched or given up on.
    live: bool = true,
};

const Inline = union(enum) {
    text: []const u8,
    code: []const u8,
    /// Already-rendered HTML, with the plain text it stands for (image alt).
    raw: struct { html: []const u8, plain: []const u8 = "" },
    delim: *Delim,
    bracket: *Bracket,
};

const InlineParser = struct {
    arena: Allocator,
    s: []const u8,
    nodes: std.ArrayList(Inline) = .empty,

    fn add(p: *InlineParser, node: Inline) Allocator.Error!void {
        try p.nodes.append(p.arena, node);
    }

    fn addText(p: *InlineParser, t: []const u8) Allocator.Error!void {
        if (t.len > 0) try p.add(.{ .text = t });
    }
};

fn renderInline(arena: Allocator, s: []const u8, w: *Writer) Error!void {
    const nodes = try parseInlines(arena, s);
    for (nodes) |n| try renderNode(n, w);
}

fn parseInlines(arena: Allocator, s: []const u8) Allocator.Error![]const Inline {
    var p: InlineParser = .{ .arena = arena, .s = s };
    var text_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        switch (s[i]) {
            '\\' => {
                if (i + 1 < s.len and isAsciiPunct(s[i + 1])) {
                    try p.addText(s[text_start..i]);
                    try p.addText(s[i + 1 .. i + 2]);
                    i += 2;
                    text_start = i;
                } else i += 1;
            },
            '`' => {
                const n = runLength(s, i, '`');
                if (findBacktickRun(s, i + n, n)) |close| {
                    try p.addText(s[text_start..i]);
                    try p.add(.{ .code = try codeSpanContent(arena, s[i + n .. close]) });
                    i = close + n;
                    text_start = i;
                } else i += n;
            },
            '*', '_', '~' => {
                const c = s[i];
                const n = runLength(s, i, c);
                // Strikethrough uses one or two tildes; longer runs are text.
                if (c == '~' and n > 2) {
                    i += n;
                    continue;
                }
                try p.addText(s[text_start..i]);
                const before: u8 = if (i == 0) ' ' else s[i - 1];
                const after: u8 = if (i + n >= s.len) ' ' else s[i + n];
                const left = !isSpace(after) and (!isAsciiPunct(after) or isSpace(before) or isAsciiPunct(before));
                const right = !isSpace(before) and (!isAsciiPunct(before) or isSpace(after) or isAsciiPunct(after));
                const d = try arena.create(Delim);
                d.* = .{
                    .char = c,
                    .count = n,
                    .orig = n,
                    .can_open = if (c != '_') left else left and (!right or isAsciiPunct(before)),
                    .can_close = if (c != '_') right else right and (!left or isAsciiPunct(after)),
                };
                try p.add(.{ .delim = d });
                i += n;
                text_start = i;
            },
            '!' => {
                if (i + 1 < s.len and s[i + 1] == '[') {
                    try p.addText(s[text_start..i]);
                    try addBracket(&p, true);
                    i += 2;
                    text_start = i;
                } else i += 1;
            },
            '[' => {
                try p.addText(s[text_start..i]);
                if (footnoteRef(s[i..])) |label| {
                    // A placeholder that `finishFootnotes` numbers once the
                    // whole document is rendered.
                    try p.add(.{ .raw = .{ .html = try std.mem.concat(arena, u8, &.{ fn_marker, label, fn_marker }) } });
                    i += label.len + 3;
                    text_start = i;
                    continue;
                }
                try addBracket(&p, false);
                i += 1;
                text_start = i;
            },
            ']' => {
                try p.addText(s[text_start..i]);
                i = try closeBracket(&p, i);
                text_start = i;
            },
            ':' => {
                if (inlineComponent(s[i..])) |comp| {
                    try p.addText(s[text_start..i]);
                    try p.add(.{ .raw = try inlineComponentHtml(arena, comp) });
                    i += comp.len;
                    text_start = i;
                } else i += 1;
            },
            '<' => {
                if (autolink(s[i..])) |len| {
                    try p.addText(s[text_start..i]);
                    try p.add(.{ .raw = try autolinkHtml(arena, s[i + 1 .. i + len - 1]) });
                    i += len;
                    text_start = i;
                } else i += 1;
            },
            '\n' => {
                const before = s[text_start..i];
                if (std.mem.endsWith(u8, before, "\\")) {
                    // Hard line break: a backslash at the end of the line.
                    try p.addText(before[0 .. before.len - 1]);
                    try p.add(.{ .raw = .{ .html = "<br />\n", .plain = "\n" } });
                } else if (std.mem.endsWith(u8, before, "  ")) {
                    // Hard line break: two or more spaces at the end.
                    try p.addText(trimRight(before));
                    try p.add(.{ .raw = .{ .html = "<br />\n", .plain = "\n" } });
                } else {
                    // Soft line break: drop trailing spaces before it.
                    try p.addText(trimRight(before));
                    try p.add(.{ .text = "\n" });
                }
                i += 1;
                while (i < s.len and s[i] == ' ') i += 1;
                text_start = i;
            },
            else => i += 1,
        }
    }
    try p.addText(s[text_start..]);
    try processEmphasis(arena, p.nodes.items, 0);
    return p.nodes.items;
}

const InlineComponent = struct { name: []const u8, text: []const u8, len: usize };

/// `:badge[text]` or `:kbd[text]` at the start of `s`. The text may not
/// contain `]` or a newline.
fn inlineComponent(s: []const u8) ?InlineComponent {
    for ([_][]const u8{ "badge", "kbd" }) |name| {
        if (s.len < name.len + 3 or !std.mem.eql(u8, s[1 .. 1 + name.len], name) or s[1 + name.len] != '[') continue;
        const start = name.len + 2;
        const close = std.mem.indexOfAnyPos(u8, s, start, "]\n") orelse return null;
        if (s[close] != ']' or close == start) return null;
        return .{ .name = name, .text = s[start..close], .len = close + 1 };
    }
    return null;
}

fn inlineComponentHtml(arena: Allocator, c: InlineComponent) Allocator.Error!@FieldType(Inline, "raw") {
    var aw: Writer.Allocating = .init(arena);
    writeInlineComponent(&aw.writer, c) catch return error.OutOfMemory;
    return .{ .html = try aw.toOwnedSlice(), .plain = c.text };
}

fn writeInlineComponent(w: *Writer, c: InlineComponent) Writer.Error!void {
    if (std.mem.eql(u8, c.name, "kbd")) {
        try w.writeAll("<kbd class=\"mt-kbd\">");
        try escapeHtml(w, c.text);
        return w.writeAll("</kbd>");
    }
    try w.writeAll("<span class=\"mt-badge\">");
    try escapeHtml(w, c.text);
    try w.writeAll("</span>");
}

/// Length of an autolink (`<https://...>` or `<name@example.com>`) at the
/// start of `s`, including the angle brackets, or null.
fn autolink(s: []const u8) ?usize {
    const close = std.mem.indexOfScalar(u8, s, '>') orelse return null;
    const inner = s[1..close];
    if (inner.len == 0) return null;
    for (inner) |c| if (c <= ' ' or c == '<' or c == 0x7f) return null;
    if (isUriAutolink(inner) or isEmailAutolink(inner)) return close + 1;
    return null;
}

/// A scheme of 2-32 letters, digits, `+`, `.`, or `-` starting with a
/// letter, then `:`.
fn isUriAutolink(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon < 2 or colon > 32 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-')) return false;
    }
    return true;
}

fn isEmailAutolink(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    for (s[0..at]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ".!#$%&'*+/=?^_`{|}~-", c) != null)) return false;
    }
    var labels = std.mem.splitScalar(u8, s[at + 1 ..], '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    }
    return true;
}

fn autolinkHtml(arena: Allocator, target: []const u8) Allocator.Error!@FieldType(Inline, "raw") {
    var aw: Writer.Allocating = .init(arena);
    writeAutolink(&aw.writer, target, !isUriAutolink(target)) catch return error.OutOfMemory;
    return .{ .html = try aw.toOwnedSlice(), .plain = target };
}

fn writeAutolink(w: *Writer, target: []const u8, email: bool) Writer.Error!void {
    try w.writeAll("<a href=\"");
    if (email) try w.writeAll("mailto:");
    try escapeHtml(w, target);
    try w.writeAll("\">");
    try escapeHtml(w, target);
    try w.writeAll("</a>");
}

fn addBracket(p: *InlineParser, image: bool) Allocator.Error!void {
    const b = try p.arena.create(Bracket);
    b.* = .{ .image = image };
    try p.add(.{ .bracket = b });
}

/// Handles `]` at `s[i]`. Returns the index to continue scanning from.
fn closeBracket(p: *InlineParser, i: usize) Allocator.Error!usize {
    const nodes = p.nodes.items;
    var k = nodes.len;
    const opener_idx: usize = while (k > 0) {
        k -= 1;
        if (nodes[k] == .bracket and nodes[k].bracket.live) break k;
    } else {
        try p.add(.{ .text = "]" });
        return i + 1;
    };
    const b = nodes[opener_idx].bracket;
    const tail = if (b.active) parseLinkTail(p.s, i + 1) else null;
    const link = tail orelse {
        b.live = false;
        try p.add(.{ .text = "]" });
        return i + 1;
    };
    b.live = false;

    const arena = p.arena;
    try processEmphasis(arena, p.nodes.items, opener_idx + 1);
    const dest = try unescapeBackslashes(arena, link.dest);
    const title = if (link.title) |t| try unescapeBackslashes(arena, t) else null;

    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (b.image) {
        const alt = try plainText(arena, p.nodes.items[opener_idx + 1 ..]);
        writeImage(w, dest, alt, title) catch return error.OutOfMemory;
        p.nodes.shrinkRetainingCapacity(opener_idx);
        try p.add(.{ .raw = .{ .html = try aw.toOwnedSlice(), .plain = alt } });
    } else {
        writeLinkOpen(w, dest, title) catch return error.OutOfMemory;
        p.nodes.items[opener_idx] = .{ .raw = .{ .html = try aw.toOwnedSlice() } };
        try p.add(.{ .raw = .{ .html = "</a>" } });
        // No links inside links: earlier `[` openers can no longer form one.
        for (p.nodes.items[0..opener_idx]) |n| {
            if (n == .bracket and !n.bracket.image) n.bracket.active = false;
        }
    }
    return link.end;
}

fn writeImage(w: *Writer, dest: []const u8, alt: []const u8, title: ?[]const u8) Writer.Error!void {
    try w.writeAll("<img src=\"");
    try escapeUrl(w, dest);
    try w.writeAll("\" alt=\"");
    try escapeHtml(w, alt);
    try w.writeAll("\"");
    if (title) |t| {
        try w.writeAll(" title=\"");
        try escapeHtml(w, t);
        try w.writeAll("\"");
    }
    try w.writeAll(" />");
}

fn writeLinkOpen(w: *Writer, dest: []const u8, title: ?[]const u8) Writer.Error!void {
    try w.writeAll("<a href=\"");
    try escapeUrl(w, dest);
    try w.writeAll("\"");
    if (title) |t| {
        try w.writeAll(" title=\"");
        try escapeHtml(w, t);
        try w.writeAll("\"");
    }
    try w.writeAll(">");
}

const LinkTail = struct { dest: []const u8, title: ?[]const u8, end: usize };

/// Parses `(destination "title")` starting at `s[pos]`.
fn parseLinkTail(s: []const u8, pos: usize) ?LinkTail {
    if (pos >= s.len or s[pos] != '(') return null;
    var p = skipLinkSpace(s, pos + 1);

    var dest: []const u8 = "";
    if (p < s.len and s[p] == '<') {
        const start = p + 1;
        var q = start;
        while (q < s.len and s[q] != '>') : (q += 1) {
            if (s[q] == '\n' or s[q] == '<') return null;
            if (s[q] == '\\' and q + 1 < s.len) q += 1;
        }
        if (q >= s.len) return null;
        dest = s[start..q];
        p = q + 1;
    } else {
        const start = p;
        var depth: usize = 0;
        while (p < s.len) {
            const c = s[p];
            if (c == '\\' and p + 1 < s.len and isAsciiPunct(s[p + 1])) {
                p += 2;
                continue;
            }
            if (c <= ' ') break;
            if (c == '(') depth += 1;
            if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
            }
            p += 1;
        }
        if (depth != 0) return null;
        dest = s[start..p];
    }

    const before_title = p;
    p = skipLinkSpace(s, p);
    var title: ?[]const u8 = null;
    if (p > before_title and p < s.len and (s[p] == '"' or s[p] == '\'' or s[p] == '(')) {
        const close: u8 = if (s[p] == '(') ')' else s[p];
        const start = p + 1;
        var q = start;
        while (q < s.len and s[q] != close) : (q += 1) {
            if (s[q] == '\\' and q + 1 < s.len) q += 1;
        }
        if (q >= s.len) return null;
        title = s[start..q];
        p = skipLinkSpace(s, q + 1);
    }
    if (p >= s.len or s[p] != ')') return null;
    return .{ .dest = dest, .title = title, .end = p + 1 };
}

fn skipLinkSpace(s: []const u8, start: usize) usize {
    var p = start;
    var newlines: usize = 0;
    while (p < s.len) : (p += 1) {
        switch (s[p]) {
            ' ', '\t' => {},
            '\n' => {
                newlines += 1;
                if (newlines > 1) break;
            },
            else => break,
        }
    }
    return p;
}

/// Resolves `*` and `_` runs in `nodes[bottom..]` into emphasis, following
/// the CommonMark delimiter algorithm.
fn processEmphasis(arena: Allocator, nodes: []const Inline, bottom: usize) Allocator.Error!void {
    var ci = bottom;
    while (ci < nodes.len) : (ci += 1) {
        if (nodes[ci] != .delim) continue;
        const closer = nodes[ci].delim;
        if (!closer.active or !closer.can_close) continue;

        while (closer.count > 0) {
            var oi = ci;
            const opener: *Delim = while (oi > bottom) {
                oi -= 1;
                if (nodes[oi] != .delim) continue;
                const o = nodes[oi].delim;
                if (!o.active or !o.can_open or o.char != closer.char or o.count == 0) continue;
                // Strikethrough runs only match runs of the same length.
                if (closer.char == '~') {
                    if (o.count != closer.count) continue;
                    break o;
                }
                const both = o.can_close or closer.can_open;
                if (both and (o.orig + closer.orig) % 3 == 0 and !(o.orig % 3 == 0 and closer.orig % 3 == 0)) continue;
                break o;
            } else break;

            const n: u8 = if (closer.char == '~')
                @intCast(closer.count)
            else if (opener.count >= 2 and closer.count >= 2) 2 else 1;
            opener.count -= n;
            closer.count -= n;
            try opener.opens.append(arena, n);
            try closer.closes.append(arena, n);
            for (nodes[oi + 1 .. ci]) |between| {
                if (between == .delim) between.delim.active = false;
            }
            if (opener.count == 0) opener.active = false;
        }
        if (closer.count == 0 or !closer.can_open) closer.active = false;
    }
    for (nodes[bottom..]) |n| {
        if (n == .delim) n.delim.active = false;
    }
}

fn renderNode(n: Inline, w: *Writer) Writer.Error!void {
    switch (n) {
        .text => |t| try escapeHtml(w, t),
        .code => |c| {
            try w.writeAll("<code>");
            try escapeHtml(w, c);
            try w.writeAll("</code>");
        },
        .raw => |r| try w.writeAll(r.html),
        .bracket => |b| try w.writeAll(if (b.image) "![" else "["),
        .delim => |d| {
            const strike = d.char == '~';
            for (d.closes.items) |size| try w.writeAll(if (strike) "</del>" else if (size == 2) "</strong>" else "</em>");
            try w.splatByteAll(d.char, d.count);
            var k = d.opens.items.len;
            while (k > 0) {
                k -= 1;
                try w.writeAll(if (strike) "<del>" else if (d.opens.items[k] == 2) "<strong>" else "<em>");
            }
        },
    }
}

fn plainText(arena: Allocator, nodes: []const Inline) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (nodes) |n| switch (n) {
        .text, .code => |t| try out.appendSlice(arena, t),
        .raw => |r| try out.appendSlice(arena, r.plain),
        .bracket => |b| try out.appendSlice(arena, if (b.image) "![" else "["),
        .delim => |d| try out.appendNTimes(arena, d.char, d.count),
    };
    return out.items;
}

fn runLength(s: []const u8, start: usize, c: u8) usize {
    var n: usize = 0;
    while (start + n < s.len and s[start + n] == c) n += 1;
    return n;
}

/// Finds a run of exactly `n` backticks at or after `from`.
fn findBacktickRun(s: []const u8, from: usize, n: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] == '`') {
            const len = runLength(s, i, '`');
            if (len == n) return i;
            i += len;
        } else i += 1;
    }
    return null;
}

fn codeSpanContent(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    const content = try arena.dupe(u8, raw);
    for (content) |*c| {
        if (c.* == '\n') c.* = ' ';
    }
    const all_spaces = std.mem.indexOfNone(u8, content, " ") == null;
    if (!all_spaces and content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
        return content[1 .. content.len - 1];
    }
    return content;
}

fn unescapeBackslashes(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and isAsciiPunct(s[i + 1])) i += 1;
        try out.append(arena, s[i]);
    }
    return out.items;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c;
}

fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

/// Escapes text for HTML element content and double-quoted attributes.
pub fn escapeHtml(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// Escapes a URL for an attribute: spaces become `%20`, then HTML escaping.
fn escapeUrl(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c != ' ') continue;
        try escapeHtml(w, s[start..i]);
        try w.writeAll("%20");
        start = i + 1;
    }
    try escapeHtml(w, s[start..]);
}

// ---------------------------------------------------------------------------
// Tests. The fixture suite in test/fixtures/markdown/ covers the subset
// end to end; these check individual rules.

const testing = std.testing;

fn expectHtml(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try toHtml(arena.allocator(), src));
}

test "headings" {
    try expectHtml("<h1 id=\"title\">Title</h1>\n", "# Title");
    try expectHtml("<h3 id=\"three\">Three</h3>\n", "### Three ###");
    try expectHtml("<h2 id=\"a\">a#</h2>\n", "## a#");
    try expectHtml("<h1 id=\"section\"></h1>\n", "#");
}

test "heading ids are slugs, unique within a document" {
    try expectHtml(
        "<h2 id=\"zig-016-notes\">Zig 0.16: notes</h2>\n<h2 id=\"zig-016-notes-1\">Zig 0.16: <em>notes</em></h2>\n<h2 id=\"café\">Café!</h2>\n",
        "## Zig 0.16: notes\n## Zig 0.16: *notes*\n## Café!",
    );
    try expectHtml("<p>#nospace</p>\n", "#nospace");
    try expectHtml("<p>####### seven</p>\n", "####### seven");
}

test "paragraphs and soft breaks" {
    try expectHtml("<p>one\ntwo</p>\n<p>three</p>\n", "one \n  two\n\nthree\n");
    try expectHtml("<p>one<br />\ntwo<br />\nthree</p>\n", "one  \ntwo\\\nthree");
    try expectHtml("<p>a</p>\n<h2 id=\"b\">b</h2>\n", "a\n## b");
}

test "fenced code" {
    try expectHtml("<pre><code class=\"language-text\">const a = 1 &lt; 2;\n</code></pre>\n", "```text\nconst a = 1 < 2;\n```");
    try expectHtml("<pre><code class=\"language-zig\"><span class=\"hl-keyword\">const</span> a = <span class=\"hl-number\">1</span>;\n</code></pre>\n", "```zig\nconst a = 1;\n```");
    try expectHtml("<pre><code>x\n\ny\n</code></pre>\n", "~~~~\nx\n\ny\n~~~~~");
    try expectHtml("<pre><code>a\n```\n</code></pre>\n", "````\na\n```\n````");
    // An unclosed fence runs to the end of the document.
    try expectHtml("<pre><code>open\n</code></pre>\n", "```\nopen");
    // Fence indentation is removed from content lines.
    try expectHtml("<pre><code>a\n b\n</code></pre>\n", "  ```\n  a\n   b\n  ```");
}

test "lists" {
    try expectHtml("<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n", "- a\n- b");
    try expectHtml("<ol start=\"3\">\n<li>c</li>\n<li>d</li>\n</ol>\n", "3. c\n4. d");
    try expectHtml("<ul>\n<li>\n<p>a</p>\n</li>\n<li>\n<p>b</p>\n</li>\n</ul>\n", "- a\n\n- b");
    try expectHtml("<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n", "- a\n  - b");
    try expectHtml("<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>\n", "- a\n+ b");
    try expectHtml("<ul>\n<li>a\nlazy</li>\n</ul>\n", "- a\nlazy");
    try expectHtml("<ul>\n<li></li>\n</ul>\n", "-");
    // Only an ordered list starting at 1 may interrupt a paragraph.
    try expectHtml("<p>text\n2. no</p>\n", "text\n2. no");
}

test "emphasis" {
    try expectHtml("<p><em>a</em> <strong>b</strong></p>\n", "*a* **b**");
    try expectHtml("<p><em>a</em> <strong>b</strong></p>\n", "_a_ __b__");
    try expectHtml("<p><em><strong>a</strong></em></p>\n", "***a***");
    try expectHtml("<p>snake_case_name</p>\n", "snake_case_name");
    try expectHtml("<p>a * b * c</p>\n", "a * b * c");
    try expectHtml("<p><em>a</em>*</p>\n", "*a**");
    try expectHtml("<p><em>a <strong>b</strong></em></p>\n", "*a **b***");
}

test "inline code" {
    try expectHtml("<p><code>a &lt; b</code></p>\n", "`a < b`");
    try expectHtml("<p><code>`x`</code></p>\n", "`` `x` ``");
    try expectHtml("<p><code>*no em*</code></p>\n", "`*no em*`");
    try expectHtml("<p>`unclosed</p>\n", "`unclosed");
}

test "links and images" {
    try expectHtml("<p><a href=\"/a\">x</a></p>\n", "[x](/a)");
    try expectHtml("<p><a href=\"/a\" title=\"T\">x <em>y</em></a></p>\n", "[x *y*](/a \"T\")");
    try expectHtml("<p><a href=\"/a%20b\">x</a></p>\n", "[x](</a b>)");
    try expectHtml("<p><a href=\"/f(1)\">x</a></p>\n", "[x](/f(1))");
    try expectHtml("<p><img src=\"/i.png\" alt=\"an image\" /></p>\n", "![an *image*](/i.png)");
    try expectHtml("<p>[not a link]</p>\n", "[not a link]");
    try expectHtml("<p>[a <a href=\"/b\">b</a>](/c)</p>\n", "[a [b](/b)](/c)");
    try expectHtml("<p><a href=\"/x\"><img src=\"/i\" alt=\"i\" /></a></p>\n", "[![i](/i)](/x)");
}

test "escaping" {
    try expectHtml("<p>*not em* &lt;b&gt; &amp;amp;</p>\n", "\\*not em\\* <b> &amp;");
    try expectHtml("<p>\\a</p>\n", "\\a");
}

test "CRLF and tabs" {
    try expectHtml("<p>a\nb</p>\n", "a\r\nb\r\n");
    try expectHtml("<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul>\n</li>\n</ul>\n", "- a\n\t- b");
}
