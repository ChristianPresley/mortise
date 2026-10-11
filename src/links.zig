//! Wikilinks and backlinks.
//!
//! Markdown writes `[[Target]]` as a link to a placeholder URL (see
//! `markdown.wikilink_prefix`). Once every page is loaded, `resolve` points
//! each one at the page it names: by path (`[[docs/install]]`), by title
//! (`[[Getting Started]]`), or by file name (`[[install]]`), comparing
//! titles and names as slugs so case and punctuation do not matter. A
//! `#Heading` part becomes the heading's anchor. A name that matches no
//! page renders as a `wikilink-missing` link without an `href`; one that
//! matches several pages fails the build.
//!
//! `page.backlinks` lists the pages that link to a page, through wikilinks
//! or ordinary Markdown links.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pipeline = @import("pipeline.zig");
const markdown = @import("markdown.zig");
const template = @import("template.zig");
const Page = pipeline.Page;

/// Why `resolve` failed: the page with the wikilink and a message.
pub const Failure = struct { path: []const u8 = "", message: []const u8 = "" };

/// The URLs of the internal links in `html`, resolved against the page at
/// `page_url`, without fragments or queries.
pub fn targets(arena: Allocator, html: []const u8, page_url: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, "href=\"")) |start| {
        const vs = start + "href=\"".len;
        const end = std.mem.indexOfScalarPos(u8, html, vs, '"') orelse break;
        i = end + 1;
        var url = html[vs..end];
        if (url.len == 0 or url[0] == '#' or std.mem.startsWith(u8, url, "//")) continue;
        if (hasScheme(url)) continue;
        if (std.mem.indexOfAny(u8, url, "?#")) |k| url = url[0..k];
        const joined = if (url[0] == '/') url else try std.mem.concat(arena, u8, &.{ page_url[0 .. (std.mem.lastIndexOfScalar(u8, page_url, '/') orelse 0) + 1], url });
        const norm = try normalize(arena, try unescape(arena, joined)) orelse continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, norm)) break;
        } else try out.append(arena, norm);
    }
    return out.items;
}

fn hasScheme(url: []const u8) bool {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    for (url[1..]) |c| {
        if (c == ':') return true;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

/// Resolves `.` and `..` in an absolute URL path. Null when it climbs
/// above the root.
fn normalize(arena: Allocator, url: []const u8) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, url, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    const slash = if (std.mem.endsWith(u8, url, "/") and parts.items.len > 0) "/" else "";
    return try std.mem.concat(arena, u8, &.{ "/", try std.mem.join(arena, "/", parts.items), slash });
}

fn unescape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    outer: while (i < s.len) {
        for ([_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' } }) |r| {
            if (std.mem.startsWith(u8, s[i..], r[0])) {
                out.appendAssumeCapacity(r[1]);
                i += r[0].len;
                continue :outer;
            }
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.items;
}

/// For each page, the indices of the pages linking to it.
pub const Backlinks = struct {
    from: []std.ArrayList(usize),
};

const ambiguous = std.math.maxInt(usize);

/// Every name a wikilink may use for page `p`.
fn names(arena: Allocator, p: *const Page, baseurl: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    // Paths: the source without its extension, and the URL.
    const src = p.source;
    const stem_path = src[0 .. std.mem.lastIndexOfScalar(u8, src, '.') orelse src.len];
    try out.append(arena, try std.mem.concat(arena, u8, &.{ "path:", stem_path }));
    const url = std.mem.trim(u8, if (std.mem.startsWith(u8, p.url, baseurl)) p.url[baseurl.len..] else p.url, "/");
    if (url.len > 0) try out.append(arena, try std.mem.concat(arena, u8, &.{ "path:", url }));
    // Slugs: the title and the file name (a post's without its date, an
    // index page's directory name).
    if (p.fields.get("title")) |t| if (t == .string) {
        try out.append(arena, try std.mem.concat(arena, u8, &.{ "slug:", try markdown.slugify(arena, t.string) }));
    };
    var base = if (std.mem.lastIndexOfScalar(u8, stem_path, '/')) |k| stem_path[k + 1 ..] else stem_path;
    if (std.mem.eql(u8, base, "index")) {
        base = if (std.mem.lastIndexOfScalar(u8, url, '/')) |k| url[k + 1 ..] else url;
    } else if (p.is_post and base.len > 11) base = base[11..];
    if (base.len > 0) try out.append(arena, try std.mem.concat(arena, u8, &.{ "slug:", try markdown.slugify(arena, base) }));
}

/// Points every wikilink at its page, updating `html` (and clearing `base`
/// so it is rebuilt) for the pages that have wikilinks. Returns the links
/// between pages for `addBacklinks`. On an ambiguous wikilink, sets
/// `failure` and returns early.
pub fn resolve(arena: Allocator, pages: []Page, baseurl: []const u8, failure: *Failure) Allocator.Error!Backlinks {
    const from = try arena.alloc(std.ArrayList(usize), pages.len);
    @memset(from, .empty);
    const result: Backlinks = .{ .from = from };

    var by_url: std.StringHashMapUnmanaged(usize) = .empty;
    for (pages, 0..) |*p, i| {
        try by_url.put(arena, p.url, i);
        // `/docs/x` and `/docs/x/` name the same page.
        if (std.mem.endsWith(u8, p.url, "/") and p.url.len > 1) try by_url.put(arena, p.url[0 .. p.url.len - 1], i);
    }
    for (pages, 0..) |p, i| for (p.link_targets) |t| {
        const j = by_url.get(t) orelse continue;
        if (j != i) try from[j].append(arena, i);
    };

    var any = false;
    for (pages) |p| any = any or p.wikilink_html != null;
    if (!any) return result;

    var index: std.StringHashMapUnmanaged(usize) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    for (pages, 0..) |*p, i| {
        keys.clearRetainingCapacity();
        try names(arena, p, baseurl, &keys);
        for (keys.items) |k| {
            const gop = try index.getOrPut(arena, k);
            if (!gop.found_existing) gop.value_ptr.* = i else if (gop.value_ptr.* != i) gop.value_ptr.* = ambiguous;
        }
    }

    const open = "<a class=\"wikilink\" href=\"" ++ markdown.wikilink_prefix;
    for (pages, 0..) |*p, i| {
        const raw = p.wikilink_html orelse continue;
        var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, raw, pos, open)) |start| {
            const ts = start + open.len;
            const te = std.mem.indexOfPos(u8, raw, ts, "\">") orelse break;
            try out.appendSlice(arena, raw[pos..start]);
            pos = te + 2;
            const target = try unescape(arena, raw[ts..te]);
            const hash = std.mem.indexOfScalar(u8, target, '#');
            const name = std.mem.trim(u8, target[0 .. hash orelse target.len], " /");
            const frag = if (hash) |h| try markdown.slugify(arena, target[h + 1 ..]) else "";
            var page_url: []const u8 = "";
            if (name.len > 0) {
                const j = try lookup(arena, &index, name) orelse {
                    try out.appendSlice(arena, "<a class=\"wikilink wikilink-missing\" title=\"No page named ");
                    try appendEscaped(arena, &out, name);
                    try out.appendSlice(arena, "\">");
                    continue;
                };
                if (j == ambiguous) {
                    failure.* = .{ .path = p.source, .message = try ambiguity(arena, pages, name) };
                    return result;
                }
                page_url = pages[j].url;
                if (j != i) try from[j].append(arena, i);
            }
            try out.appendSlice(arena, "<a class=\"wikilink\" href=\"");
            try appendEscaped(arena, &out, page_url);
            if (frag.len > 0) {
                try out.append(arena, '#');
                try appendEscaped(arena, &out, frag);
            }
            try out.appendSlice(arena, "\">");
        }
        try out.appendSlice(arena, raw[pos..]);
        p.html = out.items;
        p.base = .{};
    }
    return result;
}

/// The page a wikilink name refers to: a path first, then a slug.
fn lookup(arena: Allocator, index: *const std.StringHashMapUnmanaged(usize), name: []const u8) Allocator.Error!?usize {
    var path = name;
    for ([_][]const u8{ ".md", ".html" }) |ext| {
        if (std.mem.endsWith(u8, path, ext)) path = path[0 .. path.len - ext.len];
    }
    if (index.get(try std.mem.concat(arena, u8, &.{ "path:", path }))) |j| return j;
    return index.get(try std.mem.concat(arena, u8, &.{ "slug:", try markdown.slugify(arena, name) }));
}

fn ambiguity(arena: Allocator, pages: []const Page, name: []const u8) Allocator.Error![]const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    var keys: std.ArrayList([]const u8) = .empty;
    const slug = try std.mem.concat(arena, u8, &.{ "slug:", try markdown.slugify(arena, name) });
    for (pages) |*p| {
        keys.clearRetainingCapacity();
        try names(arena, p, "", &keys);
        for (keys.items) |k| if (std.mem.eql(u8, k, slug)) {
            try matches.append(arena, p.source);
            break;
        };
    }
    const list = try std.mem.join(arena, ", ", matches.items);
    return std.fmt.allocPrint(arena, "wikilink [[{s}]] could mean any of {s}; write a path instead, such as [[{s}]]", .{
        name, list, matches.items[0][0 .. std.mem.lastIndexOfScalar(u8, matches.items[0], '.') orelse matches.items[0].len],
    });
}

fn appendEscaped(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '"' => try out.appendSlice(arena, "&quot;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        '>' => try out.appendSlice(arena, "&gt;"),
        else => try out.append(arena, c),
    };
}

/// Adds `page.backlinks` to every page: the pages linking to it, each
/// `{title, url}`, ordered by title.
pub fn addBacklinks(arena: Allocator, pages: []Page, bl: *Backlinks) Allocator.Error!void {
    for (pages, bl.from) |*p, *list| {
        std.mem.sortUnstable(usize, list.items, pages, struct {
            fn lt(ps: []Page, a: usize, b: usize) bool {
                const o = std.mem.order(u8, pipeline.navTitle(&ps[a]), pipeline.navTitle(&ps[b]));
                return if (o != .eq) o == .lt else a < b;
            }
        }.lt);
        var items: std.ArrayList(template.Value) = .empty;
        var prev: ?usize = null;
        for (list.items) |j| {
            if (prev == j) continue;
            prev = j;
            const e = try arena.alloc(template.Entry, 2);
            e[0] = .{ .key = "title", .value = .{ .string = pipeline.navTitle(&pages[j]) } };
            e[1] = .{ .key = "url", .value = .{ .string = pages[j].url } };
            try items.append(arena, .{ .object = .{ .entries = e } });
        }
        var entries: std.ArrayList(template.Entry) = .empty;
        try entries.appendSlice(arena, p.object.entries);
        try entries.append(arena, .{ .key = "backlinks", .value = .{ .list = items.items } });
        p.object = .{ .entries = entries.items };
    }
}

const testing = std.testing;

test "targets resolves internal links" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const t = try targets(a,
        \\<a href="../b/">b</a> <a href="/c/#x">c</a> <a href="https://x.dev/">x</a>
        \\<a href="#top">top</a> <a href="d.html?q=1">d</a> <a href="../b/">again</a> <a href="../../up">up</a> <a href="../../../above">above</a>
    , "/docs/a/");
    try testing.expectEqual(@as(usize, 4), t.len);
    try testing.expectEqualStrings("/docs/b/", t[0]);
    try testing.expectEqualStrings("/c/", t[1]);
    try testing.expectEqualStrings("/docs/a/d.html", t[2]);
    try testing.expectEqualStrings("/up", t[3]);
}
