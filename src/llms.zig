//! Text for language models, following llmstxt.org: with `llms: true` in
//! `_config.yml`, every Markdown page also gets a plain Markdown twin at
//! its URL plus `index.html.md` (`/docs/install/index.html.md`), and the
//! site gets `/llms.txt`, an index of its pages linking to the twins, and
//! `/llms-full.txt`, every twin in one file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const index_path = "llms.txt";
pub const full_path = "llms-full.txt";

pub const Page = struct {
    title: []const u8,
    /// Root-relative URL, including the baseurl.
    url: []const u8,
    /// A short description from the page's frontmatter, or "".
    description: []const u8,
    /// `YYYY-MM-DD` for posts, else "".
    date: []const u8,
    is_post: bool,
    /// The page's Markdown without frontmatter, or null for template pages.
    markdown: ?[]const u8,
};

/// The output path of a page's Markdown twin, from the page's own output
/// path: `docs/install/index.html` gives `docs/install/index.html.md`.
pub fn twinPath(arena: Allocator, out_path: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}.md", .{out_path});
}

/// The URL of a page's twin: `/docs/install/` gives
/// `/docs/install/index.html.md`, `/about.html` gives `/about.html.md`.
fn twinUrl(arena: Allocator, url: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}.md", .{ url, if (std.mem.endsWith(u8, url, "/")) "index.html" else "" });
}

/// A twin's text: the Markdown, under the page title as a level-one
/// heading unless it already starts with one.
pub fn twin(arena: Allocator, p: Page) Allocator.Error![]const u8 {
    const md = std.mem.trimStart(u8, p.markdown orelse "", "\r\n");
    if (std.mem.startsWith(u8, md, "# ") or p.title.len == 0) return md;
    return std.fmt.allocPrint(arena, "# {s}\n\n{s}", .{ p.title, md });
}

/// `/llms.txt`: the site's title and description, then links to every
/// page (to its Markdown twin when it has one) and every post.
/// `site_url` makes the links absolute; it may be "".
pub fn index(arena: Allocator, title: []const u8, description: []const u8, site_url: []const u8, pages: []const Page) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(arena);
    writeIndex(arena, &aw.writer, title, description, site_url, pages) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeIndex(arena: Allocator, w: *Writer, title: []const u8, description: []const u8, site_url: []const u8, pages: []const Page) (Allocator.Error || Writer.Error)!void {
    try w.print("# {s}\n", .{if (title.len > 0) title else "Site"});
    if (description.len > 0) try w.print("\n> {s}\n", .{description});
    for ([_]bool{ false, true }) |posts| {
        var any = false;
        for (pages) |p| {
            if (p.is_post != posts) continue;
            if (!any) try w.print("\n## {s}\n\n", .{if (posts) "Posts" else "Pages"});
            any = true;
            const url = if (p.markdown != null) try twinUrl(arena, p.url) else p.url;
            try w.print("- [{s}]({s}{s})", .{ if (p.title.len > 0) p.title else p.url, site_url, url });
            if (p.date.len > 0 and p.description.len > 0) {
                try w.print(": {s}, {s}", .{ p.date, p.description });
            } else if (p.date.len > 0 or p.description.len > 0) {
                try w.print(": {s}{s}", .{ p.date, p.description });
            }
            try w.writeByte('\n');
        }
    }
}

/// `/llms-full.txt`: every page's twin, each after a line with its URL.
pub fn full(arena: Allocator, site_url: []const u8, pages: []const Page) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    var first = true;
    for (pages) |p| {
        if (p.markdown == null) continue;
        if (!first) w.writeAll("\n---\n\n") catch return error.OutOfMemory;
        first = false;
        w.print("URL: {s}{s}\n\n", .{ site_url, p.url }) catch return error.OutOfMemory;
        w.writeAll(std.mem.trimEnd(u8, try twin(arena, p), "\r\n")) catch return error.OutOfMemory;
        w.writeByte('\n') catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "llms.txt, twins, and the full file" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const pages = [_]Page{
        .{ .title = "Hello", .url = "/2024/01/02/hello/", .description = "", .date = "2024-01-02", .is_post = true, .markdown = "Hi.\n" },
        .{ .title = "Install", .url = "/docs/install/", .description = "Get it running", .date = "", .is_post = false, .markdown = "# Install it\n\nRun it.\n" },
        .{ .title = "Home", .url = "/", .description = "", .date = "", .is_post = false, .markdown = null },
    };
    try testing.expectEqualStrings(
        \\# Docs
        \\
        \\> All about it
        \\
        \\## Pages
        \\
        \\- [Install](https://x.dev/docs/install/index.html.md): Get it running
        \\- [Home](https://x.dev/)
        \\
        \\## Posts
        \\
        \\- [Hello](https://x.dev/2024/01/02/hello/index.html.md): 2024-01-02
        \\
    , try index(a, "Docs", "All about it", "https://x.dev", &pages));
    try testing.expectEqualStrings("# Hello\n\nHi.\n", try twin(a, pages[0]));
    try testing.expectEqualStrings("# Install it\n\nRun it.\n", try twin(a, pages[1]));
    try testing.expectEqualStrings("docs/install/index.html.md", try twinPath(a, "docs/install/index.html"));
    try testing.expectEqualStrings(
        \\URL: /2024/01/02/hello/
        \\
        \\# Hello
        \\
        \\Hi.
        \\
        \\---
        \\
        \\URL: /docs/install/
        \\
        \\# Install it
        \\
        \\Run it.
        \\
    , try full(a, "", &pages));
}
