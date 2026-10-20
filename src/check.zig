//! `mortise check`: finds broken links and unused files in a built site.
//!
//! Every HTML output is scanned for `href` and `src` attributes. A link to
//! another page of the site must name an output that exists, and a
//! `#fragment` must name an `id` (or an `<a name>`) on the target page.
//! Links to the site's own `url` count as internal. Other links with a
//! scheme (`mailto:`, `data:`), protocol-relative links (`//host/...`) and
//! links into `/__` (dev server endpoints) are not checked; `http:` and
//! `https:` links are collected for `checkExternal`, which fetches them
//! when asked to (`mortise check --external`).
//!
//! A file the site copies unchanged from its sources is unused when no
//! page or stylesheet refers to it: not through `href`, `src`, `srcset`,
//! `poster`, `data` or a `<meta content>`, nor through `url()` or
//! `@import` in a stylesheet, a `<style>` element or a `style` attribute.
//! Files at the top of the site (`robots.txt`, `CNAME`, `favicon.ico`)
//! are never reported: hosts and browsers fetch those by name.
//!
//! `check: ignore:` in the config lists patterns, with `*` matching any
//! run of characters, for links and files to leave alone.
//!
//! The same pass runs the accessibility lint in a11y.zig on every page.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const SiteDir = @import("SiteDir.zig");
const sitepath = @import("path.zig");
const pipeline = @import("pipeline.zig");
const a11y = @import("a11y.zig");

pub const Problem = struct {
    /// Output path of the page with the link, or of the unused file.
    page: []const u8,
    /// Source site path of that page or file.
    source: []const u8,
    /// 1-based line of the link in the page's HTML; 0 for unused files.
    line: usize,
    /// The link as written.
    url: []const u8,
    kind: Kind,
    /// For external links, what went wrong, such as `404 Not Found`.
    detail: []const u8 = "",

    pub const Kind = enum {
        /// No output answers the link's path.
        missing_page,
        /// The target page exists but has no element with the fragment's id.
        missing_anchor,
        /// An absolute link outside the site's `baseurl`.
        outside_baseurl,
        /// A copied file that nothing refers to.
        unused_file,
        /// An `http:` or `https:` link that failed when fetched.
        external,
    };

    pub fn format(p: Problem, w: *Writer) Writer.Error!void {
        if (p.kind == .unused_file) {
            try w.print("{s}: unused file: no page or stylesheet refers to it", .{p.page});
        } else {
            try w.print("{s}:{d}: ", .{ p.page, p.line });
            switch (p.kind) {
                .missing_page => try w.print("broken link \"{s}\": no such page or file", .{p.url}),
                .missing_anchor => try w.print("broken link \"{s}\": no element with that id", .{p.url}),
                .outside_baseurl => try w.print("broken link \"{s}\": outside baseurl", .{p.url}),
                .external => try w.print("broken external link \"{s}\": {s}", .{ p.url, p.detail }),
                .unused_file => unreachable,
            }
        }
        if (!std.mem.eql(u8, p.source, p.page)) try w.print(" (from {s})", .{p.source});
    }
};

pub const Report = struct {
    /// Broken internal links, then unused files.
    problems: []const Problem,
    /// HTML pages scanned.
    pages: usize,
    /// Internal links checked.
    links: usize,
    /// How many of `problems` are unused files.
    unused: usize = 0,
    /// Accessibility problems, by page and line.
    a11y: []const a11y.Issue = &.{},
    /// Every `http:` and `https:` link not ignored, for `checkExternal`.
    external: []const Link = &.{},
};

/// An external link and where it was found.
pub const Link = struct {
    page: []const u8,
    source: []const u8,
    line: usize,
    url: []const u8,
};

/// One link or anchor found in a page.
const Attr = struct {
    value: []const u8,
    line: usize,
};

const Scan = struct {
    links: []const Attr,
    ids: []const []const u8,
    /// Other references to files: `srcset`, `poster`, `data` and `content`
    /// values, and `url()` and `@import` in inline CSS.
    refs: []const []const u8 = &.{},
};

/// Checks every HTML output of `site`. `src` reads the HTML files the site
/// copies unchanged.
pub fn check(arena: Allocator, site: pipeline.Site, src: SiteDir) Allocator.Error!Report {
    var scans: std.StringHashMapUnmanaged(Scan) = .empty;
    var issues: std.ArrayList(a11y.Issue) = .empty;
    // Output paths something refers to.
    var used: std.StringHashMapUnmanaged(void) = .empty;
    for (site.outputs) |out| {
        const css = std.mem.endsWith(u8, out.path, ".css");
        if (!isHtml(out.path) and !css) continue;
        const text = switch (out.data) {
            .bytes => |b| b,
            .copy => src.readFile(arena, out.source) catch continue,
        };
        if (css) {
            var refs: std.ArrayList([]const u8) = .empty;
            try cssRefs(arena, text, &refs);
            for (refs.items) |r| try markUsed(arena, site, out.path, r, &used);
            continue;
        }
        const s = try scan(arena, text);
        try scans.put(arena, out.path, s);
        for (s.refs) |r| try markUsed(arena, site, out.path, r, &used);
        try a11y.lint(arena, out.path, out.source, text, &issues);
    }

    var problems: std.ArrayList(Problem) = .empty;
    var external: std.ArrayList(Link) = .empty;
    var links: usize = 0;
    for (site.outputs) |out| {
        const page = scans.get(out.path) orelse continue;
        for (page.links) |link| {
            const raw = std.mem.trim(u8, link.value, " \t\r\n");
            if (ignored(site.check_ignore, raw)) continue;
            const url = selfRelative(site, raw) orelse raw;
            if (url.ptr == raw.ptr and isWeb(url)) {
                try external.append(arena, .{ .page = out.path, .source = out.source, .line = link.line, .url = raw });
                continue;
            }
            try markUsed(arena, site, out.path, url, &used);
            const kind = try checkLink(arena, site, &scans, out.path, page, url) orelse continue;
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

    var unused: usize = 0;
    for (site.outputs) |out| {
        if (out.data != .copy or isHtml(out.path) or std.mem.indexOfScalar(u8, out.path, '/') == null) continue;
        if (used.contains(out.path) or ignoredPath(site.check_ignore, out.path)) continue;
        try problems.append(arena, .{ .page = out.path, .source = out.source, .line = 0, .url = out.path, .kind = .unused_file });
        unused += 1;
    }
    return .{
        .problems = problems.items,
        .pages = scans.count(),
        .links = links,
        .unused = unused,
        .a11y = issues.items,
        .external = external.items,
    };
}

/// `url` as a root-relative link when it points into the site's own `url`
/// (`https://example.com/a/` becomes `/a/`), else null.
fn selfRelative(site: pipeline.Site, url: []const u8) ?[]const u8 {
    const base = site.site_url orelse return null;
    if (base.len == 0 or !std.ascii.startsWithIgnoreCase(url, base)) return null;
    const rest = url[base.len..];
    if (rest.len == 0) return "/";
    return if (rest[0] == '/' or rest[0] == '?' or rest[0] == '#') rest else null;
}

fn isWeb(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

/// Records the output `raw`, written in `from_path`, refers to, if any.
fn markUsed(arena: Allocator, site: pipeline.Site, from_path: []const u8, raw: []const u8, used: *std.StringHashMapUnmanaged(void)) Allocator.Error!void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const url = selfRelative(site, trimmed) orelse trimmed;
    if (url.len == 0 or hasScheme(url) or std.mem.startsWith(u8, url, "//")) return;
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    if (end == 0) return;
    const decoded = try percentDecode(arena, url[0..end]);
    var rel: []const u8 = undefined;
    if (decoded[0] == '/') {
        const base = site.baseurl;
        if (!std.mem.startsWith(u8, decoded, base)) return;
        rel = std.mem.trimStart(u8, decoded[base.len..], "/");
    } else {
        const dir = sitepath.dirname(from_path) orelse "";
        rel = if (dir.len == 0) decoded else try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, decoded });
    }
    const target = (try resolve(arena, site, rel, decoded[decoded.len - 1] == '/')) orelse return;
    try used.put(arena, target, {});
}

/// Whether `url` matches a pattern of `check: ignore:`.
fn ignored(patterns: []const []const u8, url: []const u8) bool {
    for (patterns) |p| if (globMatch(p, url)) return true;
    return false;
}

/// Whether the output `path` matches a pattern, written with or without
/// a leading `/`.
fn ignoredPath(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (globMatch(std.mem.trimStart(u8, p, "/"), path)) return true;
    }
    return false;
}

/// Matches `s` against `pattern`, where `*` stands for any run of
/// characters (including `/`) and everything else for itself.
fn globMatch(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var resume_at: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            resume_at = i;
        } else if (p < pattern.len and pattern[p] == s[i]) {
            p += 1;
            i += 1;
        } else if (star) |st| {
            p = st + 1;
            resume_at += 1;
            i = resume_at;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Adds the targets of `url(...)` and `@import "..."` in `css` to `refs`.
fn cssRefs(arena: Allocator, css: []const u8, refs: *std.ArrayList([]const u8)) Allocator.Error!void {
    var i: usize = 0;
    while (i < css.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(css[i..], "url(")) {
            const start = i + 4;
            const end = std.mem.indexOfScalarPos(u8, css, start, ')') orelse return;
            try refs.append(arena, std.mem.trim(u8, css[start..end], " \t\r\n\"'"));
            i = end;
        } else if (std.ascii.startsWithIgnoreCase(css[i..], "@import")) {
            var j = i + 7;
            while (j < css.len and std.ascii.isWhitespace(css[j])) j += 1;
            if (j < css.len and (css[j] == '"' or css[j] == '\'')) {
                const end = std.mem.indexOfScalarPos(u8, css, j + 1, css[j]) orelse return;
                try refs.append(arena, css[j + 1 .. end]);
                i = end;
            }
        }
    }
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

/// Collects `href`/`src` values and `id`/`name` anchors from HTML, plus
/// the other references listed at `Scan.refs`. Skips comments and the
/// bodies of `<script>` and `<style>`, except for the stylesheet's
/// references.
fn scan(arena: Allocator, html: []const u8) Allocator.Error!Scan {
    var links: std.ArrayList(Attr) = .empty;
    var ids: std.ArrayList([]const u8) = .empty;
    var refs: std.ArrayList([]const u8) = .empty;
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
            } else if (std.ascii.eqlIgnoreCase(attr, "srcset")) {
                // Candidates are `URL [descriptor]`, separated by commas.
                var it = std.mem.splitScalar(u8, try unescape(arena, value), ',');
                while (it.next()) |cand| {
                    const t = std.mem.trim(u8, cand, " \t\r\n");
                    try refs.append(arena, t[0 .. std.mem.indexOfAny(u8, t, " \t\r\n") orelse t.len]);
                }
            } else if (std.ascii.eqlIgnoreCase(attr, "poster") or std.ascii.eqlIgnoreCase(attr, "data") or std.ascii.eqlIgnoreCase(attr, "content")) {
                try refs.append(arena, try unescape(arena, value));
            } else if (std.ascii.eqlIgnoreCase(attr, "style")) {
                try cssRefs(arena, try unescape(arena, value), &refs);
            }
        }
        i += 1;

        // Raw text elements: nothing inside is markup.
        if (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style")) {
            const close = if (tag.len == 6) "</script" else "</style";
            const end = indexOfIgnoreCase(html, i, close) orelse html.len;
            const body = html[@min(i, html.len)..end];
            if (tag.len == 5) try cssRefs(arena, body, &refs);
            line += std.mem.count(u8, body, "\n");
            i = end;
        }
    }
    return .{ .links = links.items, .ids = ids.items, .refs = refs.items };
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

pub const ExternalOptions = struct {
    /// How long one request may take, redirects included.
    timeout: Io.Duration = .fromSeconds(15),
    /// Requests in flight at once.
    workers: usize = 8,
};

/// What fetching one URL gave.
const Outcome = union(enum) {
    ok,
    status: std.http.Status,
    failed: anyerror,
    timed_out,
};

/// Fetches each distinct URL of `links` (without its `#fragment`) and
/// returns a problem for every link whose URL failed: a status of 400 or
/// more after up to five redirects, a network error, or no answer within
/// `options.timeout`. Only the response's headers are read, not its body.
pub fn checkExternal(arena: Allocator, gpa: Allocator, io: Io, links: []const Link, options: ExternalOptions) Allocator.Error![]const Problem {
    var urls: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (links) |l| try urls.put(arena, withoutFragment(l.url), {});
    const outcomes = try arena.alloc(Outcome, urls.count());

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const Worker = struct {
        fn run(c: *std.http.Client, t_io: Io, all: []const []const u8, out: []Outcome, first: usize, step: usize, timeout: Io.Duration) void {
            var k = first;
            while (k < all.len) : (k += step) out[k] = fetchWithTimeout(c, t_io, all[k], timeout);
        }
    };
    const workers = @max(1, @min(options.workers, outcomes.len));
    var group: Io.Group = .init;
    for (0..workers) |k| {
        group.concurrent(io, Worker.run, .{ &client, io, urls.keys(), outcomes, k, workers, options.timeout }) catch
            Worker.run(&client, io, urls.keys(), outcomes, k, workers, options.timeout);
    }
    group.await(io) catch group.cancel(io);

    var problems: std.ArrayList(Problem) = .empty;
    for (links) |l| {
        const detail: []const u8 = switch (outcomes[urls.getIndex(withoutFragment(l.url)).?]) {
            .ok => continue,
            .status => |s| try std.fmt.allocPrint(arena, "{d} {s}", .{ @intFromEnum(s), s.phrase() orelse "" }),
            .failed => |e| @errorName(e),
            .timed_out => "no answer in time",
        };
        try problems.append(arena, .{ .page = l.page, .source = l.source, .line = l.line, .url = l.url, .kind = .external, .detail = std.mem.trimEnd(u8, detail, " ") });
    }
    return problems.items;
}

fn withoutFragment(url: []const u8) []const u8 {
    return url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];
}

/// `fetchUrl` raced against a timer.
fn fetchWithTimeout(client: *std.http.Client, io: Io, url: []const u8, timeout: Io.Duration) Outcome {
    const Race = union(enum) { fetched: Outcome, timer: Io.Cancelable!void };
    var buf: [2]Race = undefined;
    var select: Io.Select(Race) = .init(io, &buf);
    select.concurrent(.fetched, fetchUrl, .{ client, url }) catch return fetchUrl(client, url);
    select.concurrent(.timer, Io.sleep, .{ io, timeout, .awake }) catch {};
    const first = select.await() catch {
        select.cancelDiscard();
        return .timed_out;
    };
    select.cancelDiscard();
    return switch (first) {
        .fetched => |o| o,
        .timer => .timed_out,
    };
}

/// Sends GET and reads only the status line and headers, following up to
/// five redirects, then closes the connection without reading the body.
/// (GET rather than HEAD, which some servers answer wrongly and which
/// `std.http.Client.fetch` in Zig 0.16 crashes on.)
fn fetchUrl(client: *std.http.Client, url: []const u8) Outcome {
    const uri = std.Uri.parse(url) catch |err| return .{ .failed = err };
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "mortise-check" } },
    }) catch |err| return .{ .failed = err };
    defer req.deinit();
    req.sendBodiless() catch |err| return .{ .failed = err };
    var redirect_buf: [8 * 1024]u8 = undefined;
    const response = req.receiveHead(&redirect_buf) catch |err| return .{ .failed = err };
    const status = response.head.status;
    return if (@intFromEnum(status) < 400) .ok else .{ .status = status };
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
        .{ .path = "css/site.css", .source = "css/site.css", .data = .{ .bytes = "body{}" } },
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

test "unused files: copied files nothing refers to, outside the site root" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var site = testSite(&.{
        .{ .path = "CNAME", .source = "CNAME", .data = .copy },
        .{ .path = "css/fonts/a.woff2", .source = "css/fonts/a.woff2", .data = .copy },
        .{ .path = "css/more.css", .source = "css/more.css", .data = .{ .bytes = "body{}" } },
        .{ .path = "css/site.css", .source = "css/site.css", .data = .{ .bytes = "@import \"more.css\";\n@font-face{src:url( 'fonts/a.woff2' )}\n" } },
        .{ .path = "downloads/kept.zip", .source = "downloads/kept.zip", .data = .copy },
        .{ .path = "downloads/old.zip", .source = "downloads/old.zip", .data = .copy },
        .{ .path = "img/bg.png", .source = "img/bg.png", .data = .copy },
        .{ .path = "img/card.png", .source = "img/card.png", .data = .copy },
        .{ .path = "img/hero.480w.jpg", .source = "img/hero.jpg", .data = .copy },
        .{ .path = "img/hero.jpg", .source = "img/hero.jpg", .data = .copy },
        .{ .path = "img/inline.svg", .source = "img/inline.svg", .data = .copy },
        .{ .path = "img/poster.jpg", .source = "img/poster.jpg", .data = .copy },
        .{ .path = "img/unused.png", .source = "img/unused.png", .data = .copy },
        .{ .path = "index.html", .source = "index.md", .data = .{ .bytes =
        \\<link rel="stylesheet" href="/css/site.css">
        \\<meta property="og:image" content="https://example.com/img/card.png">
        \\<img src="img/hero.jpg" srcset="img/hero.480w.jpg 480w, img/hero.jpg 960w">
        \\<video poster="/img/poster.jpg"></video><div style="background:url(/img/bg.png)"></div>
        \\<style>.x{background:url("img/inline.svg")}</style>
        } },
    }, "");
    site.site_url = "https://example.com";
    site.check_ignore = &.{"/downloads/kept*"};
    const report = try check(arena, site, undefined);
    try testing.expectEqual(@as(usize, 2), report.unused);
    try testing.expectEqual(@as(usize, 2), report.problems.len);
    try testing.expectEqualStrings("downloads/old.zip", report.problems[0].page);
    try testing.expectEqualStrings("img/unused.png", report.problems[1].page);
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try w.print("{f}", .{report.problems[1]});
    try testing.expectEqualStrings("img/unused.png: unused file: no page or stylesheet refers to it", w.buffered());
}

test "links to the site's own url are internal; others are collected or ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var site = testSite(&.{
        .{ .path = "index.html", .source = "index.md", .data = .{ .bytes =
        \\<a href="https://example.com/">home</a> <a href="https://example.com/gone/">gone</a>
        \\<a href="https://zig.dev/a#x">ext</a> <a href="http://skip.test/x">ignored</a>
        } },
    }, "");
    site.site_url = "https://example.com";
    site.check_ignore = &.{"http://skip.test/*"};
    const report = try check(arena, site, undefined);
    try testing.expectEqual(@as(usize, 1), report.problems.len);
    try testing.expectEqualStrings("https://example.com/gone/", report.problems[0].url);
    try testing.expectEqual(@as(usize, 1), report.external.len);
    try testing.expectEqualStrings("https://zig.dev/a#x", report.external[0].url);
    try testing.expectEqual(@as(usize, 2), report.external[0].line);
}

test "globMatch" {
    try testing.expect(globMatch("https://x.dev/*", "https://x.dev/a/b"));
    try testing.expect(globMatch("*.pdf", "docs/a.pdf"));
    try testing.expect(globMatch("a*b*c", "aXbYbZc"));
    try testing.expect(!globMatch("a*b*c", "aXbYbZ"));
    try testing.expect(globMatch("exact", "exact"));
    try testing.expect(!globMatch("exact", "exactly"));
    try testing.expect(globMatch("*", ""));
}

/// A tiny HTTP server for `checkExternal`'s test: `/ok` answers 200,
/// `/moved` redirects to `/ok`, `/slow` waits past the test's timeout,
/// and anything else is 404.
const TestServer = struct {
    fn serve(listener: *Io.net.Server, io: Io) Io.Cancelable!void {
        var group: Io.Group = .init;
        defer group.cancel(io);
        while (true) {
            const stream = listener.accept(io) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            group.concurrent(io, answer, .{ stream, io }) catch answer(stream, io) catch {};
        }
    }

    fn answer(stream: Io.net.Stream, io: Io) Io.Cancelable!void {
        defer stream.close(io);
        var rbuf: [1024]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var w = stream.writer(io, &wbuf);
        const first = r.interface.takeDelimiterExclusive('\n') catch return;
        var parts = std.mem.splitScalar(u8, first, ' ');
        _ = parts.next();
        const path = parts.next() orelse return;
        const slow = std.mem.eql(u8, path, "/slow");
        const reply = if (std.mem.eql(u8, path, "/ok"))
            "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
        else if (std.mem.eql(u8, path, "/moved"))
            "HTTP/1.1 301 Moved Permanently\r\nlocation: /ok\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        else if (slow)
            "HTTP/1.1 200 OK\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
        else
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n";
        // The rest of the request.
        while (true) {
            const line = r.interface.takeDelimiterExclusive('\n') catch return;
            if (std.mem.trim(u8, line, "\r").len == 0) break;
        }
        if (slow) try io.sleep(.fromSeconds(5), .awake);
        w.interface.writeAll(reply) catch return;
        w.interface.flush() catch return;
    }
};

test "checkExternal reports failed statuses, timeouts and refused connections" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    // A port nothing listens on: take one, then close it.
    var closed = try address.listen(io, .{ .reuse_address = true });
    const closed_port = closed.socket.address.getPort();
    closed.deinit(io);

    var server = try io.concurrent(TestServer.serve, .{ &listener, io });
    defer server.cancel(io) catch {};

    const at = struct {
        fn url(a: Allocator, p: u16, path: []const u8) ![]const u8 {
            return std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ p, path });
        }
    }.url;
    const links = [_]Link{
        .{ .page = "a.html", .source = "a.md", .line = 1, .url = try at(arena, port, "/ok") },
        .{ .page = "a.html", .source = "a.md", .line = 2, .url = try at(arena, port, "/moved#part") },
        .{ .page = "a.html", .source = "a.md", .line = 3, .url = try at(arena, port, "/missing") },
        .{ .page = "b.html", .source = "b.md", .line = 9, .url = try at(arena, port, "/missing") },
        .{ .page = "a.html", .source = "a.md", .line = 4, .url = try at(arena, port, "/slow") },
        .{ .page = "a.html", .source = "a.md", .line = 5, .url = try at(arena, closed_port, "/") },
    };
    const problems = try checkExternal(arena, testing.allocator, io, &links, .{ .timeout = .fromMilliseconds(1500) });
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    for (problems[0..3]) |p| try w.print("{s}:{d} {s}\n", .{ p.page, p.line, p.detail });
    try testing.expectEqualStrings(
        \\a.html:3 404 Not Found
        \\b.html:9 404 Not Found
        \\a.html:4 no answer in time
        \\
    , w.buffered());
    // Linux and macOS refuse at once; Windows retries a closed local port
    // for about two seconds, past this test's timeout.
    try testing.expectEqual(@as(usize, 4), problems.len);
    try testing.expectEqual(@as(usize, 5), problems[3].line);
    const refused = std.mem.eql(u8, problems[3].detail, "ConnectionRefused") or std.mem.eql(u8, problems[3].detail, "no answer in time");
    try testing.expect(refused);
}
