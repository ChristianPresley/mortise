//! Accessibility lint for built HTML, run by `mortise check`.
//!
//! Each page is scanned once for problems that can be found from markup
//! alone: a missing `lang` or `<title>`, images without `alt`, links and
//! buttons without an accessible name, form controls without a label,
//! frames without a title, heading levels that skip, and repeated ids.
//! Colors, focus order and anything that needs a browser are not checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Issue = struct {
    /// Output path of the page.
    page: []const u8,
    /// Source site path of that page.
    source: []const u8,
    /// 1-based line in the page's HTML.
    line: usize,
    kind: Kind,
    /// The element's `src`, `href`, id or type, or the heading levels.
    detail: []const u8 = "",

    pub const Kind = enum {
        missing_lang,
        missing_title,
        image_without_alt,
        unnamed_link,
        unnamed_button,
        unlabeled_control,
        untitled_frame,
        skipped_heading,
        duplicate_id,
    };

    pub fn format(p: Issue, w: *Writer) Writer.Error!void {
        try w.print("{s}:{d}: ", .{ p.page, p.line });
        switch (p.kind) {
            .missing_lang => try w.writeAll("<html> has no lang attribute"),
            .missing_title => try w.writeAll("page has no <title>"),
            .image_without_alt => try w.print("image \"{s}\" has no alt text; use alt=\"\" if it is decorative", .{p.detail}),
            .unnamed_link => try w.print("link \"{s}\" has no text, alt text or aria-label", .{p.detail}),
            .unnamed_button => try w.writeAll("<button> has no text or aria-label"),
            .unlabeled_control => try w.print("<{s}> has no <label>, aria-label or title", .{p.detail}),
            .untitled_frame => try w.print("<iframe src=\"{s}\"> has no title", .{p.detail}),
            .skipped_heading => try w.print("heading levels skip: {s}", .{p.detail}),
            .duplicate_id => try w.print("id \"{s}\" is used more than once", .{p.detail}),
        }
        if (!std.mem.eql(u8, p.source, p.page)) try w.print(" (from {s})", .{p.source});
    }
};

const Attr = struct { name: []const u8, value: ?[]const u8 };

fn attr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value orelse "";
    return null;
}

fn nonEmpty(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.trim(u8, s, " \t\r\n").len > 0;
}

/// Whether an element is named by its attributes alone.
fn namedByAttrs(attrs: []const Attr) bool {
    return nonEmpty(attr(attrs, "aria-label")) or nonEmpty(attr(attrs, "aria-labelledby")) or nonEmpty(attr(attrs, "title"));
}

fn isHidden(attrs: []const Attr) bool {
    const h = attr(attrs, "aria-hidden") orelse return false;
    return std.ascii.eqlIgnoreCase(h, "true");
}

/// A link or button whose content is still being read.
const Open = struct {
    tag: enum { a, button },
    line: usize,
    detail: []const u8,
    named: bool,
};

/// A control that needs a `<label for>` to be named.
const Pending = struct { id: []const u8, line: usize, detail: []const u8 };

/// Appends the problems in one page's HTML to `issues`.
pub fn lint(arena: Allocator, page: []const u8, source: []const u8, html: []const u8, issues: *std.ArrayList(Issue)) Allocator.Error!void {
    const first = issues.items.len;
    var open: std.ArrayList(Open) = .empty;
    var pending: std.ArrayList(Pending) = .empty;
    var label_for: std.ArrayList([]const u8) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var label_depth: usize = 0;
    var hidden_depth: usize = 0;
    var hidden_tag: []const u8 = "";
    var heading: u8 = 0;
    var html_line: ?usize = null;
    var has_lang = false;
    var has_title = false;
    var in_title = false;

    const report = struct {
        fn add(a: Allocator, list: *std.ArrayList(Issue), pg: []const u8, src: []const u8, line: usize, kind: Issue.Kind, detail: []const u8) Allocator.Error!void {
            try list.append(a, .{ .page = pg, .source = src, .line = line, .kind = kind, .detail = detail });
        }
    }.add;

    var attrs: std.ArrayList(Attr) = .empty;
    var line: usize = 1;
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
            const text = html[i..end];
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
                if (hidden_depth == 0) for (open.items) |*o| {
                    o.named = true;
                };
                if (in_title) has_title = true;
            }
            line += std.mem.count(u8, text, "\n");
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
            line += std.mem.count(u8, html[i..end], "\n");
            i = @min(html.len, end + 3);
            continue;
        }
        const tag_line = line;
        i += 1;
        const closing = i < html.len and html[i] == '/';
        if (closing) i += 1;
        if (i >= html.len or !std.ascii.isAlphabetic(html[i])) {
            // `<!doctype>` and stray `<`: skip to the next `>`.
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            line += std.mem.count(u8, html[i..end], "\n");
            i = @min(html.len, end + 1);
            continue;
        }
        const name_start = i;
        while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '-')) i += 1;
        const tag = html[name_start..i];

        attrs.clearRetainingCapacity();
        while (i < html.len and html[i] != '>') {
            if (html[i] == '\n') line += 1;
            if (std.ascii.isWhitespace(html[i]) or html[i] == '/') {
                i += 1;
                continue;
            }
            const an_start = i;
            while (i < html.len and !std.ascii.isWhitespace(html[i]) and html[i] != '=' and html[i] != '>' and html[i] != '/') i += 1;
            const an = html[an_start..i];
            if (an.len == 0) {
                i += 1;
                continue;
            }
            while (i < html.len and html[i] == ' ') i += 1;
            if (i >= html.len or html[i] != '=') {
                try attrs.append(arena, .{ .name = an, .value = null });
                continue;
            }
            i += 1;
            while (i < html.len and html[i] == ' ') i += 1;
            if (i >= html.len) break;
            var value: []const u8 = undefined;
            if (html[i] == '"' or html[i] == '\'') {
                const q = html[i];
                const end = std.mem.indexOfScalarPos(u8, html, i + 1, q) orelse html.len;
                value = html[i + 1 .. end];
                line += std.mem.count(u8, value, "\n");
                i = @min(html.len, end + 1);
            } else {
                const start = i;
                while (i < html.len and !std.ascii.isWhitespace(html[i]) and html[i] != '>') i += 1;
                value = html[start..i];
            }
            try attrs.append(arena, .{ .name = an, .value = value });
        }
        const self_closing = i > 0 and i < html.len and html[i - 1] == '/';
        i += 1;
        const is = struct {
            fn f(t: []const u8, n: []const u8) bool {
                return std.ascii.eqlIgnoreCase(t, n);
            }
        }.f;

        if (closing) {
            if (hidden_depth > 0 and is(tag, hidden_tag)) hidden_depth -= 1;
            if (is(tag, "title")) in_title = false;
            if (is(tag, "label")) label_depth -|= 1;
            if (is(tag, "a") or is(tag, "button")) {
                // Close the innermost open element of this kind.
                var k = open.items.len;
                while (k > 0) {
                    k -= 1;
                    const o = open.items[k];
                    if ((o.tag == .a) != is(tag, "a")) continue;
                    if (!o.named) try report(arena, issues, page, source, o.line, if (o.tag == .a) .unnamed_link else .unnamed_button, o.detail);
                    _ = open.orderedRemove(k);
                    break;
                }
            }
            continue;
        }

        const a = attrs.items;
        if (attr(a, "id")) |id| if (id.len > 0) {
            const gop = try ids.getOrPut(arena, id);
            if (gop.found_existing) try report(arena, issues, page, source, tag_line, .duplicate_id, id);
        };
        // Content inside aria-hidden elements does not name anything.
        if (isHidden(a) and !self_closing and !isVoid(tag)) {
            if (hidden_depth == 0) hidden_tag = tag;
            if (is(tag, hidden_tag)) hidden_depth += 1;
        }

        if (is(tag, "html")) {
            html_line = tag_line;
            has_lang = nonEmpty(attr(a, "lang"));
        } else if (is(tag, "title")) {
            in_title = true;
        } else if (is(tag, "img")) {
            const alt = attr(a, "alt");
            const role = attr(a, "role") orelse "";
            if (alt == null and !isHidden(a) and !std.mem.eql(u8, role, "presentation") and !std.mem.eql(u8, role, "none")) {
                try report(arena, issues, page, source, tag_line, .image_without_alt, attr(a, "src") orelse "");
            }
            if (nonEmpty(alt) and hidden_depth == 0) for (open.items) |*o| {
                o.named = true;
            };
        } else if (is(tag, "svg")) {
            if (namedByAttrs(a) and hidden_depth == 0) for (open.items) |*o| {
                o.named = true;
            };
        } else if (is(tag, "a")) {
            if (attr(a, "href")) |href| {
                try open.append(arena, .{ .tag = .a, .line = tag_line, .detail = href, .named = namedByAttrs(a) or isHidden(a) });
            }
        } else if (is(tag, "button")) {
            try open.append(arena, .{ .tag = .button, .line = tag_line, .detail = "", .named = namedByAttrs(a) or isHidden(a) });
        } else if (is(tag, "label")) {
            label_depth += 1;
            if (attr(a, "for")) |f| try label_for.append(arena, f);
        } else if (is(tag, "input") or is(tag, "select") or is(tag, "textarea")) {
            const t = attr(a, "type") orelse "text";
            const exempt = is(tag, "input") and (is(t, "hidden") or is(t, "submit") or is(t, "reset") or is(t, "button") or is(t, "image"));
            const detail = if (is(tag, "input")) try std.fmt.allocPrint(arena, "input type=\"{s}\"", .{t}) else tag;
            if (!exempt and label_depth == 0 and !namedByAttrs(a) and !isHidden(a)) {
                if (attr(a, "id")) |id| {
                    try pending.append(arena, .{ .id = id, .line = tag_line, .detail = detail });
                } else {
                    try report(arena, issues, page, source, tag_line, .unlabeled_control, detail);
                }
            }
        } else if (is(tag, "iframe")) {
            if (!nonEmpty(attr(a, "title")) and !namedByAttrs(a)) try report(arena, issues, page, source, tag_line, .untitled_frame, attr(a, "src") orelse "");
        } else if (tag.len == 2 and (tag[0] == 'h' or tag[0] == 'H') and tag[1] >= '1' and tag[1] <= '6') {
            const level = tag[1] - '0';
            if (heading > 0 and level > heading + 1) {
                try report(arena, issues, page, source, tag_line, .skipped_heading, try std.fmt.allocPrint(arena, "<h{d}> follows <h{d}>", .{ level, heading }));
            }
            heading = level;
        }

        // Raw text elements: nothing inside is markup.
        if (is(tag, "script") or is(tag, "style")) {
            const close = if (tag.len == 6) "</script" else "</style";
            const end = indexOfIgnoreCase(html, i, close) orelse html.len;
            line += std.mem.count(u8, html[@min(i, html.len)..end], "\n");
            i = end;
        }
    }

    for (pending.items) |p| {
        const labelled = for (label_for.items) |f| {
            if (std.mem.eql(u8, f, p.id)) break true;
        } else false;
        if (!labelled) try report(arena, issues, page, source, p.line, .unlabeled_control, p.detail);
    }
    // Fragments without <html>, such as redirect stubs, are not documents.
    if (html_line) |l| {
        if (!has_lang) try report(arena, issues, page, source, l, .missing_lang, "");
        if (!has_title) try report(arena, issues, page, source, l, .missing_title, "");
    }
    std.mem.sort(Issue, issues.items[first..], {}, struct {
        fn lt(_: void, x: Issue, y: Issue) bool {
            const o = std.mem.order(u8, x.page, y.page);
            return if (o != .eq) o == .lt else x.line < y.line;
        }
    }.lt);
}

/// Elements that never have content or a closing tag.
fn isVoid(tag: []const u8) bool {
    for ([_][]const u8{ "area", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" }) |v| {
        if (std.ascii.eqlIgnoreCase(tag, v)) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

const testing = std.testing;

fn lintString(html: []const u8) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var issues: std.ArrayList(Issue) = .empty;
    try lint(arena, "p.html", "p.md", html, &issues);
    var aw: Writer.Allocating = .init(testing.allocator);
    for (issues.items) |p| try aw.writer.print("{f}\n", .{p});
    return aw.toOwnedSlice();
}

test "lint reports each kind of problem with its line" {
    const out = try lintString(
        \\<!doctype html>
        \\<html><head><title> </title></head><body>
        \\<h1 id="a">T</h1><h3 id="a">Skip</h3>
        \\<img src="x.png"><img src="d.png" alt=""><img src="h.png" aria-hidden="true">
        \\<a href="/e/"></a> <a href="/i/"><img src="i.png" alt="Icon"></a> <a href="/l/" aria-label="L"><svg></svg></a>
        \\<a href="/h/"><span aria-hidden="true">#</span></a> <a name="old"></a>
        \\<button><svg aria-hidden="true"></svg></button> <button>OK</button>
        \\<input id="q"> <label for="q2">Q</label><input id="q2"> <label>N <input></label>
        \\<input type="hidden"><textarea></textarea><select aria-label="S"></select>
        \\<iframe src="/v/"></iframe><script>"<img src=s.png>"</script>
        \\</body></html>
    );
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\p.html:2: <html> has no lang attribute (from p.md)
        \\p.html:2: page has no <title> (from p.md)
        \\p.html:3: id "a" is used more than once (from p.md)
        \\p.html:3: heading levels skip: <h3> follows <h1> (from p.md)
        \\p.html:4: image "x.png" has no alt text; use alt="" if it is decorative (from p.md)
        \\p.html:5: link "/e/" has no text, alt text or aria-label (from p.md)
        \\p.html:6: link "/h/" has no text, alt text or aria-label (from p.md)
        \\p.html:7: <button> has no text or aria-label (from p.md)
        \\p.html:8: <input type="text"> has no <label>, aria-label or title (from p.md)
        \\p.html:9: <textarea> has no <label>, aria-label or title (from p.md)
        \\p.html:10: <iframe src="/v/"> has no title (from p.md)
        \\
    , out);
}

test "a fragment without <html> needs no lang or title" {
    const out = try lintString("<p>Hi <a href=\"/x/\">there</a></p>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}
