//! `mortise check`: finds broken internal links in a built site.
//!
//! Every HTML output is scanned for `href` and `src` attributes. A link to
//! another page of the site must name an output that exists, and a
//! `#fragment` must name an `id` (or an `<a name>`) on the target page.
//! Links with a scheme (`https:`, `mailto:`, `data:`), protocol-relative
//! links (`//host/...`) and links into `/__` (dev server endpoints) are
//! not checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const SiteDir = @import("SiteDir.zig");
const sitepath = @import("path.zig");
const pipeline = @import("pipeline.zig");

pub const Problem = struct {
    /// Output path of the page with the link.
    page: []const u8,
    /// Source site path of that page.
    source: []const u8,
    /// 1-based line of the link in the page's HTML.
    line: usize,
    /// The link as written.
    url: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// No output answers the link's path.
        missing_page,
        /// The target page exists but has no element with the fragment's id.
        missing_anchor,
        /// An absolute link outside the site's `baseurl`.
        outside_baseurl,
    };

    pub fn format(p: Problem, w: *Writer) Writer.Error!void {
        try w.print("{s}:{d}: ", .{ p.page, p.line });
        switch (p.kind) {
            .missing_page => try w.print("broken link \"{s}\": no such page or file", .{p.url}),
            .missing_anchor => try w.print("broken link \"{s}\": no element with that id", .{p.url}),
            .outside_baseurl => try w.print("broken link \"{s}\": outside baseurl", .{p.url}),
        }
        if (!std.mem.eql(u8, p.source, p.page)) try w.print(" (from {s})", .{p.source});
    }
};

pub const Report = struct {
    problems: []const Problem,
    /// HTML pages scanned.
    pages: usize,
    /// Internal links checked.
    links: usize,
};

/// One link or anchor found in a page.
const Attr = struct {
    value: []const u8,
    line: usize,
};

const Scan = struct {
    links: []const Attr,
    ids: []const []const u8,
};

/// Checks every HTML output of `site`. `src` reads the HTML files the site
/// copies unchanged.
pub fn check(arena: Allocator, site: pipeline.Site, src: SiteDir) Allocator.Error!Report {
    var scans: std.StringHashMapUnmanaged(Scan) = .empty;
    for (site.outputs) |out| {
        if (!isHtml(out.path)) continue;
        const html = switch (out.data) {
            .bytes => |b| b,
            .copy => src.readFile(arena, out.source) catch continue,
        };
        try scans.put(arena, out.path, try scan(arena, html));
    }

    var problems: std.ArrayList(Problem) = .empty;
    var links: usize = 0;
    for (site.outputs) |out| {
        const page = scans.get(out.path) orelse continue;
        for (page.links) |link| {
            const kind = try checkLink(arena, site, &scans, out.path, page, link.value) orelse continue;
            links += 1;
            if (kind == .ok) continue;
            try problems.append(arena, .{
                .page = out.path,
                .source = out.source,
                .line = link.line,
                .url = link.value,
                .kind = switch (kind) {
                    .ok => unreachable,
                    .missing_page => .missing_page,
                    .missing_anchor => .missing_anchor,
                    .outside_baseurl => .outside_baseurl,
                },
            });
        }
    }
    return .{ .problems = problems.items, .pages = scans.count(), .links = links };
}

const Result = enum { ok, missing_page, missing_anchor, outside_baseurl };

/// Returns null for links that are not checked.
fn checkLink(
    arena: Allocator,
    site: pipeline.Site,
    scans: *const std.StringHashMapUnmanaged(Scan),
    page_path: []const u8,
    page: Scan,
    raw: []const u8,
) Allocator.Error!?Result {
    const url = std.mem.trim(u8, raw, " \t\r\n");
    if (url.len == 0 or hasScheme(url) or std.mem.startsWith(u8, url, "//")) return null;

    const hash = std.mem.indexOfScalar(u8, url, '#');
    const before_hash = url[0 .. hash orelse url.len];
    const fragment = if (hash) |h| url[h + 1 ..] else "";
    const path_part = before_hash[0 .. std.mem.indexOfScalar(u8, before_hash, '?') orelse before_hash.len];

    // A link to the page itself, such as `#install`.
    if (path_part.len == 0) {
        if (fragment.len == 0) return null;
        const id = try percentDecode(arena, fragment);
        return if (hasId(page, id)) .ok else .missing_anchor;
    }

    const decoded = try percentDecode(arena, path_part);
    var rel: []const u8 = undefined;
    if (decoded[0] == '/') {
        const base = site.baseurl;
        if (base.len > 0) {
            const inside = std.mem.startsWith(u8, decoded, base) and
                (decoded.len == base.len or decoded[base.len] == '/');
            if (!inside) return .outside_baseurl;
        }
        rel = decoded[base.len..];
        if (std.mem.startsWith(u8, rel, "/__")) return null;
        rel = std.mem.trimStart(u8, rel, "/");
    } else {
        const dir = sitepath.dirname(page_path) orelse "";
        rel = if (dir.len == 0) decoded else try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, decoded });
    }

    const target = (try resolve(arena, site, rel, decoded[decoded.len - 1] == '/')) orelse return .missing_page;
    if (fragment.len == 0) return .ok;
    const target_scan = scans.get(target) orelse return .ok;
    return if (hasId(target_scan, try percentDecode(arena, fragment))) .ok else .missing_anchor;
}

/// Finds the output a site-relative link names, the way `mortise serve`
/// and static hosts do: `dir/` serves `dir/index.html`, and `dir` redirects
/// there.
fn resolve(arena: Allocator, site: pipeline.Site, rel: []const u8, trailing_slash: bool) Allocator.Error!?[]const u8 {
    const norm = try normalizeUrlPath(arena, rel) orelse return null;
    if (trailing_slash or norm.len == 0) {
        const index = if (norm.len == 0) "index.html" else try std.fmt.allocPrint(arena, "{s}/index.html", .{norm});
        return if (site.find(index)) |o| o.path else null;
    }
    if (site.find(norm)) |o| return o.path;
    const index = try std.fmt.allocPrint(arena, "{s}/index.html", .{norm});
    if (site.find(index)) |o| return o.path;
    return null;
}

/// Resolves `.` and `..` segments. Returns null when `..` climbs above the
/// site root.
fn normalizeUrlPath(arena: Allocator, p: []const u8) Allocator.Error!?[]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    return try std.mem.join(arena, "/", parts.items);
}

fn hasId(s: Scan, id: []const u8) bool {
    for (s.ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

fn isHtml(p: []const u8) bool {
    return std.mem.endsWith(u8, p, ".html") or std.mem.endsWith(u8, p, ".htm");
}

/// Whether `url` starts with a URL scheme such as `https:` or `mailto:`.
fn hasScheme(url: []const u8) bool {
    if (url.len == 0 or !std.ascii.isAlphabetic(url[0])) return false;
    for (url[1..]) |c| {
        if (c == ':') return true;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    return false;
}

fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                out.appendAssumeCapacity(b);
                i += 2;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(s[i]);
    }
    return out.items;
}

/// Collects `href`/`src` values and `id`/`name` anchors from HTML. Skips
/// comments and the bodies of `<script>` and `<style>`.
fn scan(arena: Allocator, html: []const u8) Allocator.Error!Scan {
    var links: std.ArrayList(Attr) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var line: usize = 1;
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '\n') line += 1;
        if (c != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            const end = std.mem.indexOfPos(u8, html, i + 4, "-->") orelse html.len;
            line += std.mem.count(u8, html[i..end], "\n");
            i = @min(html.len, end + 3);
            continue;
        }
        i += 1;
        if (i >= html.len or !std.ascii.isAlphabetic(html[i])) continue;
        const name_start = i;
        while (i < html.len and (std.ascii.isAlphanumeric(html[i]) or html[i] == '-')) i += 1;
        const tag = html[name_start..i];
        const is_a = std.ascii.eqlIgnoreCase(tag, "a");

        // Attributes, up to the closing `>`.
        while (i < html.len and html[i] != '>') {
            if (html[i] == '\n') line += 1;
            if (std.ascii.isWhitespace(html[i]) or html[i] == '/') {
                i += 1;
                continue;
            }
            const an_start = i;
            while (i < html.len and !std.ascii.isWhitespace(html[i]) and html[i] != '=' and html[i] != '>' and html[i] != '/') i += 1;
            const attr = html[an_start..i];
            if (attr.len == 0) {
                i += 1;
                continue;
            }
            while (i < html.len and html[i] == ' ') i += 1;
            if (i >= html.len or html[i] != '=') continue;
            i += 1;
            while (i < html.len and html[i] == ' ') i += 1;
            if (i >= html.len) break;
            const attr_line = line;
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
            if (std.ascii.eqlIgnoreCase(attr, "href") or std.ascii.eqlIgnoreCase(attr, "src")) {
                try links.append(arena, .{ .value = try unescape(arena, value), .line = attr_line });
            } else if (std.ascii.eqlIgnoreCase(attr, "id") or (is_a and std.ascii.eqlIgnoreCase(attr, "name"))) {
                try ids.append(arena, try unescape(arena, value));
            }
        }
        i += 1;

        // Raw text elements: nothing inside is markup.
        if (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style")) {
            const close = if (tag.len == 6) "</script" else "</style";
            const end = indexOfIgnoreCase(html, i, close) orelse html.len;
            line += std.mem.count(u8, html[@min(i, html.len)..end], "\n");
            i = end;
        }
    }
    return .{ .links = links.items, .ids = ids.items };
}

fn indexOfIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Decodes the character references Mortise and Markdown output use in
/// attribute values.
fn unescape(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') {
            const refs = [_]struct { []const u8, u8 }{
                .{ "&amp;", '&' }, .{ "&quot;", '"' }, .{ "&#39;", '\'' }, .{ "&#x27;", '\'' },
                .{ "&lt;", '<' },  .{ "&gt;", '>' },
            };
            for (refs) |r| {
                if (std.mem.startsWith(u8, s[i..], r[0])) {
                    out.appendAssumeCapacity(r[1]);
                    i += r[0].len;
                    continue :outer;
                }
            }
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.items;
}

const testing = std.testing;

test "scan finds links and ids with lines, skipping scripts and comments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try scan(arena,
        \\<h2 id="intro">Hi</h2>
        \\<!-- <a href="/commented.html"> -->
        \\<a class=x href="/a.html?x=1&amp;y=2#top">a</a><img
        \\  src='img.png'>
        \\<script>var s = "<a href='/no.html'>";</script>
        \\<a name=old>old</a><p name="nope">
    );
    try testing.expectEqual(@as(usize, 2), s.links.len);
    try testing.expectEqualStrings("/a.html?x=1&y=2#top", s.links[0].value);
    try testing.expectEqual(@as(usize, 3), s.links[0].line);
    try testing.expectEqualStrings("img.png", s.links[1].value);
    try testing.expectEqual(@as(usize, 4), s.links[1].line);
    try testing.expectEqual(@as(usize, 2), s.ids.len);
    try testing.expectEqualStrings("intro", s.ids[0]);
    try testing.expectEqualStrings("old", s.ids[1]);
}

test "hasScheme and percentDecode" {
    try testing.expect(hasScheme("https://example.com"));
    try testing.expect(hasScheme("mailto:a@b.c"));
    try testing.expect(!hasScheme("/a:b"));
    try testing.expect(!hasScheme("docs/a.html"));
    try testing.expectEqualStrings("a b", try percentDecode(testing.allocator, "a b"));
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const d = try percentDecode(arena_state.allocator(), "caf%C3%A9%2");
    try testing.expectEqualStrings("caf\xc3\xa9%2", d);
}

fn testSite(outputs: []const pipeline.Output, baseurl: []const u8) pipeline.Site {
    return .{
        .outputs = outputs,
        .deps = &.{},
        .pages = outputs.len,
        .posts = 0,
        .static_files = 0,
        .rendered = outputs.len,
        .full = true,
        .baseurl = baseurl,
        .state = undefined,
    };
}

test "check reports missing pages and anchors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Outputs are sorted by path, as in a built site.
    const site = testSite(&.{
        .{ .path = "css/site.css", .source = "css/site.css", .data = .copy },
        .{ .path = "docs/index.html", .source = "docs/index.md", .data = .{ .bytes =
        \\<h1 id="top">Docs</h1>
        \\<a href="../index.html#welcome">ok</a> <a href="/docs/#top">ok</a>
        \\<a href="setup.html">missing</a> <a href="#nowhere">bad anchor</a>
        \\<a href="/index.html#gone">bad anchor</a> <a href="https://x.dev/">external</a>
        \\<a href="/css/site.css">ok</a> <a href="/docs">ok</a> <a href="../../x.html">above root</a>
        \\<a href="/__reload">dev</a> <a href="mailto:a@b.c">mail</a> <a href="#">top</a>
        } },
        .{ .path = "index.html", .source = "index.md", .data = .{ .bytes = "<p id=\"welcome\"><a href=\"docs/\">docs</a>" } },
    }, "");
    const report = try check(arena, site, undefined);
    try testing.expectEqual(@as(usize, 2), report.pages);
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (report.problems) |p| try w.print("{f}\n", .{p});
    try testing.expectEqualStrings(
        \\docs/index.html:3: broken link "setup.html": no such page or file (from docs/index.md)
        \\docs/index.html:3: broken link "#nowhere": no element with that id (from docs/index.md)
        \\docs/index.html:4: broken link "/index.html#gone": no element with that id (from docs/index.md)
        \\docs/index.html:5: broken link "../../x.html": no such page or file (from docs/index.md)
        \\
    , w.buffered());
}

test "check honours baseurl" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const site = testSite(&.{
        .{ .path = "index.html", .source = "index.md", .data = .{ .bytes = "<a href=\"/blog/\">ok</a><a href=\"/blog\">ok</a><a href=\"/about.html\">out</a><a href=\"/blogger/\">out</a>" } },
    }, "/blog");
    const report = try check(arena, site, undefined);
    try testing.expectEqual(@as(usize, 2), report.problems.len);
    try testing.expectEqual(Problem.Kind.outside_baseurl, report.problems[0].kind);
    try testing.expectEqualStrings("/blogger/", report.problems[1].url);
}
