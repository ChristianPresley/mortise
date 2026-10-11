//! Site search: with `search: true` in `_config.yml`, the build writes
//! `search-index.json`, an inverted index of every page, and `search.js`,
//! a small client that loads the index on first use and answers queries in
//! the browser. `{{ site.search_box }}` puts the search button in a layout;
//! Ctrl+K (or Cmd+K, or `/`) opens the search dialog anywhere.
//!
//! Pages are indexed by section: the text before the first heading, then
//! each `h2` and `h3` with an id, so results link to the heading that
//! matched. Terms are lowercase words; title and heading words weigh more
//! than body words. The client matches query words as prefixes, keeps
//! sections that match every word, and ranks them with BM25.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const index_path = "search-index.json";
pub const script_path = "search.js";
pub const script = @embedFile("search.js");

/// Words that say nothing about a page.
const stop_words = [_][]const u8{
    "a",    "an",   "and", "are",   "as",   "at",    "be",    "but",  "by",   "for", "if",
    "in",   "into", "is",  "it",    "its",  "no",    "not",   "of",   "on",   "or",  "so",
    "such", "that", "the", "their", "then", "there", "these", "they", "this", "to",  "was",
    "will", "with", "you", "your",  "we",   "our",   "can",   "from", "has",
};

/// How much a word counts by where it appears.
const title_weight = 4;
const heading_weight = 3;
const body_weight = 1;

pub const Section = struct {
    /// "Page" for the text before the first heading, else "Page › Heading".
    title: []const u8,
    /// The page URL, with `#id` for a heading's section.
    url: []const u8,
    excerpt: []const u8,
    /// Each distinct term with its weighted count.
    terms: []const Term,
    /// Weighted length, for BM25's length normalization.
    len: u32,
};

pub const Term = struct { term: []const u8, weight: u32 };

/// Splits a page's HTML into sections at `<h2 id=...>` and `<h3 id=...>`
/// and analyzes each. `page_title` and `url` describe the page.
pub fn sections(arena: Allocator, page_title: []const u8, url: []const u8, html: []const u8) Allocator.Error![]const Section {
    var out: std.ArrayList(Section) = .empty;
    var start: usize = 0;
    var heading_text: ?[]const u8 = null;
    var heading_id: []const u8 = "";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "<h")) |at| {
        i = at + 2;
        if (at + 3 >= html.len) break;
        const level = html[at + 2];
        if (level != '2' and level != '3') continue;
        const tag_end = std.mem.indexOfScalarPos(u8, html, at, '>') orelse break;
        const id = attr(html[at..tag_end], "id") orelse continue;
        const close = std.mem.indexOfPos(u8, html, tag_end, "</h") orelse break;
        try addSection(arena, &out, page_title, url, heading_text, heading_id, html[start..at]);
        heading_text = try plainText(arena, html[tag_end + 1 .. close]);
        heading_id = id;
        start = close;
        i = close;
    }
    try addSection(arena, &out, page_title, url, heading_text, heading_id, html[start..]);
    return out.items;
}

fn addSection(arena: Allocator, out: *std.ArrayList(Section), page_title: []const u8, url: []const u8, heading: ?[]const u8, id: []const u8, html: []const u8) Allocator.Error!void {
    const body = try plainText(arena, html);
    if (heading == null and body.len == 0 and page_title.len == 0) return;
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var len: u32 = 0;
    // The page title counts in its first section only, so a page's every
    // section does not match its title.
    if (heading) |h| {
        len += try count(arena, &counts, h, heading_weight);
    } else {
        len += try count(arena, &counts, page_title, title_weight);
    }
    len += try count(arena, &counts, body, body_weight);
    var terms = try arena.alloc(Term, counts.count());
    for (counts.keys(), counts.values(), 0..) |k, v, n| terms[n] = .{ .term = k, .weight = v };
    try out.append(arena, .{
        .title = if (heading) |h| try std.fmt.allocPrint(arena, "{s} \u{203a} {s}", .{ page_title, h }) else page_title,
        .url = if (heading != null) try std.fmt.allocPrint(arena, "{s}#{s}", .{ url, id }) else url,
        .excerpt = try excerpt(arena, body, 160),
        .terms = terms,
        .len = len,
    });
}

/// Adds the terms of `text` to `counts`, each `weight` times. Returns the
/// weighted number of words.
fn count(arena: Allocator, counts: *std.StringArrayHashMapUnmanaged(u32), text: []const u8, weight: u32) Allocator.Error!u32 {
    var total: u32 = 0;
    var it: Words = .{ .text = text };
    while (it.next()) |raw| {
        const w = try std.ascii.allocLowerString(arena, raw);
        if (isStopWord(w)) continue;
        const gop = try counts.getOrPut(arena, w);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += weight;
        total += weight;
    }
    return total;
}

/// Words: runs of ASCII letters and digits and non-ASCII bytes, so words
/// in other scripts stay whole. Single ASCII letters are skipped.
const Words = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *Words) ?[]const u8 {
        while (true) {
            while (it.i < it.text.len and !isWordByte(it.text[it.i])) it.i += 1;
            if (it.i >= it.text.len) return null;
            const start = it.i;
            while (it.i < it.text.len and isWordByte(it.text[it.i])) it.i += 1;
            const w = it.text[start..it.i];
            if (w.len == 1 and std.ascii.isAlphabetic(w[0])) continue;
            return w;
        }
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn isStopWord(w: []const u8) bool {
    for (stop_words) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// The value of attribute `name` in a start tag, or null.
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |at| {
        i = at + name.len;
        if (at == 0 or tag[at - 1] != ' ') continue;
        if (i + 1 >= tag.len or tag[i] != '=' or tag[i + 1] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, i + 2, '"') orelse return null;
        return tag[i + 2 .. end];
    }
    return null;
}

/// The text of `html`: tags removed (with the contents of `script`,
/// `style`, `nav`, `header`, `footer`, `button` and `h1`, which repeats
/// the page title, and the `#` of heading anchors), common character
/// references decoded, whitespace collapsed. Block elements separate
/// words; inline ones such as `<code>` do not.
pub fn plainText(arena: Allocator, html: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            const tag = html[i + 1 .. end];
            const skip = [_][]const u8{ "script", "style", "nav", "header", "footer", "button", "h1" };
            var skipped = false;
            for (skip) |s| {
                if (std.mem.startsWith(u8, tag, s) and (tag.len == s.len or tag[s.len] == ' ' or tag[s.len] == '>')) {
                    const close = try std.fmt.allocPrint(arena, "</{s}>", .{s});
                    i = if (std.mem.indexOfPos(u8, html, end, close)) |e| e + close.len else html.len;
                    skipped = true;
                    break;
                }
            }
            if (skipped) continue;
            // A heading anchor's "#".
            if (std.mem.startsWith(u8, tag, "a class=\"mt-anchor\"")) {
                i = if (std.mem.indexOfPos(u8, html, end, "</a>")) |e| e + 4 else html.len;
                continue;
            }
            if (isBlockTag(tag) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') try out.append(arena, ' ');
            i = end + 1;
            continue;
        }
        if (c == '&') {
            const refs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" } };
            const matched = for (refs) |r| {
                if (std.mem.startsWith(u8, html[i..], r[0])) {
                    try out.appendSlice(arena, r[1]);
                    i += r[0].len;
                    break true;
                }
            } else false;
            if (matched) continue;
        }
        const ch: u8 = if (std.ascii.isWhitespace(c)) ' ' else c;
        if (ch != ' ' or (out.items.len > 0 and out.items[out.items.len - 1] != ' ')) try out.append(arena, ch);
        i += 1;
    }
    return std.mem.trim(u8, out.items, " ");
}

fn isBlockTag(tag: []const u8) bool {
    const start: usize = if (tag.len > 0 and tag[0] == '/') 1 else 0;
    var end = start;
    while (end < tag.len and std.ascii.isAlphanumeric(tag[end])) end += 1;
    const name = tag[start..end];
    const blocks = [_][]const u8{ "p", "div", "br", "li", "ul", "ol", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th", "pre", "blockquote", "dt", "dd", "dl", "table", "section", "article", "figure", "figcaption", "hr", "summary", "details", "aside" };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

/// Up to about `max` bytes of `text`, cut at a word.
fn excerpt(arena: Allocator, text: []const u8, max: usize) Allocator.Error![]const u8 {
    if (text.len <= max) return text;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    if (std.mem.lastIndexOfScalar(u8, text[0..cut], ' ')) |sp| if (sp > max / 2) {
        cut = sp;
    };
    return std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, text[0..cut], " ,.;:"), "\u{2026}" });
}

/// The index file: `docs` lists each section as `[title, url, excerpt,
/// length]`; `terms` lists each term, sorted, with its postings as a flat
/// array of section number and weight pairs.
pub fn indexJson(arena: Allocator, all: []const Section) Allocator.Error![]const u8 {
    var postings: std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .empty;
    for (all, 0..) |s, n| {
        for (s.terms) |t| {
            const gop = try postings.getOrPut(arena, t.term);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, @intCast(n));
            try gop.value_ptr.append(arena, t.weight);
        }
    }
    const keys = try arena.dupe([]const u8, postings.keys());
    std.mem.sortUnstable([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    (blk: {
        w.writeAll("{\"v\":1,\"docs\":[") catch |e| break :blk e;
        for (all, 0..) |s, n| {
            if (n > 0) w.writeByte(',') catch |e| break :blk e;
            w.writeByte('[') catch |e| break :blk e;
            std.json.Stringify.value(s.title, .{}, w) catch |e| break :blk e;
            w.writeByte(',') catch |e| break :blk e;
            std.json.Stringify.value(s.url, .{}, w) catch |e| break :blk e;
            w.writeByte(',') catch |e| break :blk e;
            std.json.Stringify.value(s.excerpt, .{}, w) catch |e| break :blk e;
            w.print(",{d}]", .{s.len}) catch |e| break :blk e;
        }
        w.writeAll("],\"terms\":[") catch |e| break :blk e;
        for (keys, 0..) |k, n| {
            if (n > 0) w.writeByte(',') catch |e| break :blk e;
            w.writeByte('[') catch |e| break :blk e;
            std.json.Stringify.value(k, .{}, w) catch |e| break :blk e;
            for (postings.get(k).?.items) |v| w.print(",{d}", .{v}) catch |e| break :blk e;
            w.writeByte(']') catch |e| break :blk e;
        }
        w.writeAll("]}\n") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.written();
}

/// The search button for `{{ site.search_box }}`. It stays hidden until
/// the script runs, so pages without JavaScript show no dead button.
pub fn box(arena: Allocator, baseurl: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena,
        \\<button type="button" class="mt-search-button" data-mt-search hidden aria-label="Search (Ctrl+K)"><span>Search</span> <kbd>Ctrl K</kbd></button>
        \\<script src="{s}/{s}" data-index="{s}/{s}" defer></script>
        \\
    , .{ baseurl, script_path, baseurl, index_path });
}

const testing = std.testing;

test "sections split at headings with ids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sections(a, "Guide", "/guide/",
        \\<p>Intro about <em>zig</em> builds.</p>
        \\<h2 id="install">Install <a class="mt-anchor" href="#install">#</a></h2>
        \\<p>Run the installer &amp; wait.</p>
        \\<h4 id="x">Small</h4><p>still install</p>
        \\<h3 id="faq">FAQ</h3><p>Questions.</p>
    );
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqualStrings("Guide", s[0].title);
    try testing.expectEqualStrings("/guide/", s[0].url);
    try testing.expectEqualStrings("Intro about zig builds.", s[0].excerpt);
    try testing.expectEqualStrings("Guide \u{203a} Install", s[1].title);
    try testing.expectEqualStrings("/guide/#install", s[1].url);
    try testing.expectEqualStrings("Run the installer & wait. Small still install", s[1].excerpt);
    try testing.expectEqualStrings("/guide/#faq", s[2].url);
    // "install" is heading-weighted in its section; "the" is a stop word.
    var install: u32 = 0;
    for (s[1].terms) |t| {
        if (std.mem.eql(u8, t.term, "install")) install = t.weight;
        try testing.expect(!std.mem.eql(u8, t.term, "the"));
    }
    try testing.expectEqual(@as(u32, heading_weight + body_weight), install);
}

test "plainText drops navigation and scripts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Body text", try plainText(arena.allocator(), "<header><a>Home</a></header><nav>x</nav><main>Body <b>text</b></main><script>var a</script><footer>f</footer>"));
}

test "indexJson lists sections and sorted postings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = [_]Section{
        .{ .title = "A", .url = "/a/", .excerpt = "x", .terms = &.{ .{ .term = "zig", .weight = 2 }, .{ .term = "build", .weight = 1 } }, .len = 3 },
        .{ .title = "B \"q\"", .url = "/b/", .excerpt = "y", .terms = &.{.{ .term = "zig", .weight = 1 }}, .len = 1 },
    };
    try testing.expectEqualStrings(
        "{\"v\":1,\"docs\":[[\"A\",\"/a/\",\"x\",3],[\"B \\\"q\\\"\",\"/b/\",\"y\",1]],\"terms\":[[\"build\",0,1],[\"zig\",0,2,1,1]]}\n",
        try indexJson(a, &docs),
    );
}
