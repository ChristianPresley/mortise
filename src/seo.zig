//! The `{{ seo }}` head tags: description, canonical link, Open Graph and
//! Twitter card tags, and JSON-LD structured data (schema.org `BlogPosting`
//! for posts, `WebSite` for the home page, `WebPage` otherwise, plus a
//! `BreadcrumbList`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const escapeHtml = @import("markdown.zig").escapeHtml;

pub const Crumb = struct { title: []const u8, url: []const u8 };

pub const Input = struct {
    site_title: []const u8,
    /// Absolute site URL without a trailing slash, or null when unknown;
    /// then URLs stay root-relative and there is no canonical link.
    site_url: ?[]const u8,
    /// The page's URL, including the baseurl.
    url: []const u8,
    /// The page title; empty for none.
    title: []const u8,
    description: []const u8,
    is_post: bool = false,
    /// Whether this is the site's home page.
    is_home: bool = false,
    /// `YYYY-MM-DD`, or "".
    published: []const u8 = "",
    modified: []const u8 = "",
    author: []const u8 = "",
    /// The share image: root-relative or absolute URL, or "".
    image: []const u8 = "",
    image_alt: []const u8 = "",
    /// Width and height of the image when known (generated cards).
    image_size: ?[2]u32 = null,
    /// `@handle` for `twitter:site`, or "".
    twitter: []const u8 = "",
    breadcrumbs: []const Crumb = &.{},
};

/// The head tags for one page.
pub fn head(arena: Allocator, in: Input) Allocator.Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    writeHead(arena, &aw.writer, in) catch return error.OutOfMemory;
    return aw.written();
}

fn writeHead(arena: Allocator, w: *Writer, in: Input) (Writer.Error || Allocator.Error)!void {
    const page_url = try absolute(arena, in.site_url, in.url);
    const title = if (in.title.len > 0) in.title else in.site_title;
    if (in.description.len > 0) try meta(w, "name", "description", in.description);
    if (in.site_url != null) {
        try w.writeAll("<link rel=\"canonical\" href=\"");
        try escapeHtml(w, page_url);
        try w.writeAll("\">\n");
    }
    try meta(w, "property", "og:type", if (in.is_post) "article" else "website");
    try meta(w, "property", "og:title", title);
    if (in.description.len > 0) try meta(w, "property", "og:description", in.description);
    try meta(w, "property", "og:url", page_url);
    if (in.site_title.len > 0) try meta(w, "property", "og:site_name", in.site_title);
    const image = if (in.image.len > 0) try absolute(arena, in.site_url, in.image) else "";
    if (image.len > 0) {
        try meta(w, "property", "og:image", image);
        if (in.image_size) |s| {
            try meta(w, "property", "og:image:width", try std.fmt.allocPrint(arena, "{d}", .{s[0]}));
            try meta(w, "property", "og:image:height", try std.fmt.allocPrint(arena, "{d}", .{s[1]}));
        }
        if (in.image_alt.len > 0) try meta(w, "property", "og:image:alt", in.image_alt);
    }
    if (in.is_post and in.published.len > 0) try meta(w, "property", "article:published_time", in.published);
    if (in.is_post and in.modified.len > 0) try meta(w, "property", "article:modified_time", in.modified);
    try meta(w, "name", "twitter:card", if (image.len > 0) "summary_large_image" else "summary");
    if (in.twitter.len > 0) try meta(w, "name", "twitter:site", in.twitter);

    // JSON-LD in a script element: JSON-escaped, and `<` written as <
    // so no string can close the element.
    try w.writeAll("<script type=\"application/ld+json\">");
    try w.writeAll("{\"@context\":\"https://schema.org\",\"@graph\":[{\"@type\":");
    try json(w, if (in.is_post) "BlogPosting" else if (in.is_home) "WebSite" else "WebPage");
    try w.writeAll(if (in.is_post) ",\"headline\":" else ",\"name\":");
    try json(w, title);
    try w.writeAll(",\"url\":");
    try json(w, page_url);
    if (in.description.len > 0) {
        try w.writeAll(",\"description\":");
        try json(w, in.description);
    }
    if (image.len > 0) {
        try w.writeAll(",\"image\":");
        try json(w, image);
    }
    if (in.is_post) {
        if (in.published.len > 0) {
            try w.writeAll(",\"datePublished\":");
            try json(w, in.published);
        }
        try w.writeAll(",\"dateModified\":");
        try json(w, if (in.modified.len > 0) in.modified else in.published);
        if (in.author.len > 0) {
            try w.writeAll(",\"author\":{\"@type\":\"Person\",\"name\":");
            try json(w, in.author);
            try w.writeAll("}");
        }
        try w.writeAll(",\"mainEntityOfPage\":{\"@type\":\"WebPage\",\"@id\":");
        try json(w, page_url);
        try w.writeAll("}");
    }
    try w.writeAll("}");
    if (in.breadcrumbs.len > 0) {
        try w.writeAll(",{\"@type\":\"BreadcrumbList\",\"itemListElement\":[");
        for (in.breadcrumbs, 0..) |c, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"@type\":\"ListItem\",\"position\":{d},\"name\":", .{i + 1});
            try json(w, c.title);
            try w.writeAll(",\"item\":");
            try json(w, try absolute(arena, in.site_url, c.url));
            try w.writeAll("}");
        }
        try w.print(",{{\"@type\":\"ListItem\",\"position\":{d},\"name\":", .{in.breadcrumbs.len + 1});
        try json(w, title);
        try w.writeAll("}]}");
    }
    try w.writeAll("]}</script>\n");
}

fn meta(w: *Writer, attr: []const u8, name: []const u8, content: []const u8) Writer.Error!void {
    try w.print("<meta {s}=\"{s}\" content=\"", .{ attr, name });
    try escapeHtml(w, content);
    try w.writeAll("\">\n");
}

/// `url` made absolute with the site URL, unless it already is or there
/// is no site URL.
fn absolute(arena: Allocator, site_url: ?[]const u8, url: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://")) return url;
    const base = site_url orelse return url;
    if (url.len > 0 and url[0] == '/') return std.mem.concat(arena, u8, &.{ base, url });
    return std.mem.concat(arena, u8, &.{ base, "/", url });
}

/// A JSON string, safe inside a `<script>` element.
fn json(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '<' => try w.writeAll("\\u003c"),
        '>' => try w.writeAll("\\u003e"),
        '&' => try w.writeAll("\\u0026"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// A description for a page without one: the start of its text, cut at a
/// word near `max` characters.
pub fn summarize(arena: Allocator, html: []const u8, max: usize) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len and out.items.len < max * 2) : (i += 1) {
        const c = html[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
            // Block elements separate words; inline ones such as <em> do not.
            if (isBlockTag(html[i + 1 .. end]) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(arena, ' ');
            }
            i = end;
            continue;
        }
        if (c == '&') {
            const refs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" } };
            for (refs) |r| if (std.mem.startsWith(u8, html[i..], r[0])) {
                try out.appendSlice(arena, r[1]);
                i += r[0].len - 1;
                break;
            } else try out.append(arena, c);
            continue;
        }
        const ch: u8 = if (c == '\n' or c == '\t' or c == '\r') ' ' else c;
        if (ch == ' ' and (out.items.len == 0 or out.items[out.items.len - 1] == ' ')) continue;
        try out.append(arena, ch);
    }
    var text = std.mem.trim(u8, out.items, " ");
    if (text.len <= max) return text;
    var cut = max;
    while (cut > 0 and (text[cut] & 0xC0) == 0x80) cut -= 1;
    if (std.mem.lastIndexOfScalar(u8, text[0..cut], ' ')) |sp| {
        if (sp > max / 2) cut = sp;
    }
    text = std.mem.trimEnd(u8, text[0..cut], " ,;:.-");
    return std.mem.concat(arena, u8, &.{ text, "\u{2026}" });
}

fn isBlockTag(body: []const u8) bool {
    const start: usize = if (body.len > 0 and body[0] == '/') 1 else 0;
    var end = start;
    while (end < body.len and std.ascii.isAlphanumeric(body[end])) end += 1;
    const name = body[start..end];
    for ([_][]const u8{ "p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th", "pre", "blockquote", "dt", "dd" }) |b| {
        if (std.ascii.eqlIgnoreCase(name, b)) return true;
    }
    return false;
}

const testing = std.testing;

test "a post's head tags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try head(arena.allocator(), .{
        .site_title = "Blog & Co",
        .site_url = "https://example.com",
        .url = "/blog/2024/01/05/hi/",
        .title = "Hi \"there\" </script>",
        .description = "A short post.",
        .is_post = true,
        .published = "2024-01-05",
        .author = "Ada",
        .image = "/blog/social/hi.png",
        .image_size = .{ 1200, 630 },
        .twitter = "@mortise",
        .breadcrumbs = &.{.{ .title = "Home", .url = "/blog/" }},
    });
    try testing.expectEqualStrings(
        \\<meta name="description" content="A short post.">
        \\<link rel="canonical" href="https://example.com/blog/2024/01/05/hi/">
        \\<meta property="og:type" content="article">
        \\<meta property="og:title" content="Hi &quot;there&quot; &lt;/script&gt;">
        \\<meta property="og:description" content="A short post.">
        \\<meta property="og:url" content="https://example.com/blog/2024/01/05/hi/">
        \\<meta property="og:site_name" content="Blog &amp; Co">
        \\<meta property="og:image" content="https://example.com/blog/social/hi.png">
        \\<meta property="og:image:width" content="1200">
        \\<meta property="og:image:height" content="630">
        \\<meta property="article:published_time" content="2024-01-05">
        \\<meta name="twitter:card" content="summary_large_image">
        \\<meta name="twitter:site" content="@mortise">
        \\<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"BlogPosting","headline":"Hi \"there\" \u003c/script\u003e","url":"https://example.com/blog/2024/01/05/hi/","description":"A short post.","image":"https://example.com/blog/social/hi.png","datePublished":"2024-01-05","dateModified":"2024-01-05","author":{"@type":"Person","name":"Ada"},"mainEntityOfPage":{"@type":"WebPage","@id":"https://example.com/blog/2024/01/05/hi/"}},{"@type":"BreadcrumbList","itemListElement":[{"@type":"ListItem","position":1,"name":"Home","item":"https://example.com/blog/"},{"@type":"ListItem","position":2,"name":"Hi \"there\" \u003c/script\u003e"}]}]}</script>
        \\
    , out);
}

test "without a site URL, URLs stay relative and there is no canonical link" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try head(arena.allocator(), .{ .site_title = "S", .site_url = null, .url = "/", .title = "", .description = "", .is_home = true });
    try testing.expect(std.mem.indexOf(u8, out, "canonical") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<meta property=\"og:title\" content=\"S\">") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"@type\":\"WebSite\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "content=\"summary\"") != null);
}

test "summarize strips tags and cuts at a word" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Hello world &", try summarize(a, "<p>Hello <em>world</em> &amp;</p>\n", 160));
    try testing.expectEqualStrings("one two three\u{2026}", try summarize(a, "<p>one two three four five</p>", 16));
}
