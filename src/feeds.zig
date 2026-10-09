//! Generated XML outputs: an Atom feed of recent posts and a sitemap of
//! every page. Both need absolute URLs, so the pipeline only produces them
//! when `_config.yml` sets `url`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const escapeXml = @import("markdown.zig").escapeHtml;

pub const feed_path = "feed.xml";
pub const sitemap_path = "sitemap.xml";
/// Posts in the feed, newest first.
pub const feed_limit = 20;

pub const Site = struct {
    /// Absolute site URL without a trailing slash, such as
    /// `https://example.com`.
    url: []const u8,
    /// Path prefix, such as `/blog`, or "".
    baseurl: []const u8,
    title: []const u8,
    /// Feed author; defaults to the title.
    author: []const u8,
};

pub const Entry = struct {
    title: []const u8,
    /// Root-relative URL, including the baseurl.
    url: []const u8,
    /// `YYYY-MM-DD`, or "" when unknown.
    date: []const u8,
    /// Rendered HTML of the entry's body.
    html: []const u8,
};

/// Renders an Atom 1.0 feed (RFC 4287) of `posts`, which must be newest
/// first. Times are midnight UTC on each post's date; there is no clock in
/// the output, so builds stay reproducible.
pub fn atom(arena: Allocator, site: Site, posts: []const Entry) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(arena);
    writeAtom(&aw.writer, site, posts[0..@min(posts.len, feed_limit)]) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeAtom(w: *Writer, site: Site, posts: []const Entry) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");
    try element(w, "title", site.title);
    try w.print("<link href=\"{s}{s}/\"/>\n", .{ site.url, site.baseurl });
    try w.print("<link rel=\"self\" href=\"{s}{s}/{s}\"/>\n", .{ site.url, site.baseurl, feed_path });
    try w.print("<id>{s}{s}/</id>\n", .{ site.url, site.baseurl });
    try w.print("<updated>{s}T00:00:00Z</updated>\n", .{if (posts.len > 0 and posts[0].date.len > 0) posts[0].date else "1970-01-01"});
    try w.writeAll("<author>");
    try element(w, "name", site.author);
    try w.writeAll("</author>\n");
    for (posts) |p| {
        try w.writeAll("<entry>\n");
        try element(w, "title", p.title);
        try w.print("<link href=\"{s}{s}\"/>\n<id>{s}{s}</id>\n", .{ site.url, p.url, site.url, p.url });
        try w.print("<updated>{s}T00:00:00Z</updated>\n", .{if (p.date.len > 0) p.date else "1970-01-01"});
        try w.writeAll("<content type=\"html\">");
        try escapeXml(w, p.html);
        try w.writeAll("</content>\n</entry>\n");
    }
    try w.writeAll("</feed>\n");
}

/// Renders a sitemap (sitemaps.org protocol 0.9) listing `pages`.
pub fn sitemap(arena: Allocator, site: Site, pages: []const Entry) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(arena);
    writeSitemap(&aw.writer, site, pages) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeSitemap(w: *Writer, site: Site, pages: []const Entry) Writer.Error!void {
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    for (pages) |p| {
        try w.writeAll("<url><loc>");
        try escapeXml(w, site.url);
        try escapeXml(w, p.url);
        try w.writeAll("</loc>");
        if (p.date.len > 0) try w.print("<lastmod>{s}</lastmod>", .{p.date});
        try w.writeAll("</url>\n");
    }
    try w.writeAll("</urlset>\n");
}

fn element(w: *Writer, name: []const u8, text: []const u8) Writer.Error!void {
    try w.print("<{s}>", .{name});
    try escapeXml(w, text);
    try w.print("</{s}>\n", .{name});
}

/// Validates and normalizes a site URL: `http://` or `https://`, no
/// trailing slash, no spaces or quotes. Returns null if invalid.
pub fn normalizeSiteUrl(raw: []const u8) ?[]const u8 {
    const url = std.mem.trimEnd(u8, raw, "/");
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return null;
    if (rest.len == 0) return null;
    for (url) |c| switch (c) {
        0...0x20, '"', '<', '>', '\\', 0x7f => return null,
        else => {},
    };
    return url;
}

const testing = std.testing;

test "atom feed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const site: Site = .{ .url = "https://example.com", .baseurl = "/blog", .title = "A & B", .author = "Ada" };
    const out = try atom(arena.allocator(), site, &.{
        .{ .title = "Second <post>", .url = "/blog/2024/02/01/b/", .date = "2024-02-01", .html = "<p>B</p>\n" },
        .{ .title = "First", .url = "/blog/2024/01/01/a/", .date = "2024-01-01", .html = "<p>A</p>\n" },
    });
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<title>A &amp; B</title>
        \\<link href="https://example.com/blog/"/>
        \\<link rel="self" href="https://example.com/blog/feed.xml"/>
        \\<id>https://example.com/blog/</id>
        \\<updated>2024-02-01T00:00:00Z</updated>
        \\<author><name>Ada</name>
        \\</author>
        \\<entry>
        \\<title>Second &lt;post&gt;</title>
        \\<link href="https://example.com/blog/2024/02/01/b/"/>
        \\<id>https://example.com/blog/2024/02/01/b/</id>
        \\<updated>2024-02-01T00:00:00Z</updated>
        \\<content type="html">&lt;p&gt;B&lt;/p&gt;
        \\</content>
        \\</entry>
        \\<entry>
        \\<title>First</title>
        \\<link href="https://example.com/blog/2024/01/01/a/"/>
        \\<id>https://example.com/blog/2024/01/01/a/</id>
        \\<updated>2024-01-01T00:00:00Z</updated>
        \\<content type="html">&lt;p&gt;A&lt;/p&gt;
        \\</content>
        \\</entry>
        \\</feed>
        \\
    , out);
}

test "sitemap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const site: Site = .{ .url = "https://example.com", .baseurl = "", .title = "T", .author = "T" };
    const out = try sitemap(arena.allocator(), site, &.{
        .{ .title = "", .url = "/", .date = "", .html = "" },
        .{ .title = "", .url = "/a&b/", .date = "2024-01-01", .html = "" },
    });
    try testing.expectEqualStrings(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        \\<url><loc>https://example.com/</loc></url>
        \\<url><loc>https://example.com/a&amp;b/</loc><lastmod>2024-01-01</lastmod></url>
        \\</urlset>
        \\
    , out);
}

test "normalizeSiteUrl" {
    try testing.expectEqualStrings("https://example.com", normalizeSiteUrl("https://example.com/").?);
    try testing.expectEqualStrings("http://localhost:4000", normalizeSiteUrl("http://localhost:4000").?);
    try testing.expect(normalizeSiteUrl("example.com") == null);
    try testing.expect(normalizeSiteUrl("https://") == null);
    try testing.expect(normalizeSiteUrl("https://a b") == null);
}
