//! The site pipeline: turns a source tree into a list of output files.
//!
//! Source layout (paths starting with `_` or `.` are never published):
//!
//!   _config.yml          site settings, available as `site.*`
//!   _layouts/NAME.html   layouts, chosen with `layout: NAME`
//!   _includes/NAME       templates for `{% include "NAME" %}`
//!   _posts/YYYY-MM-DD-slug.md   posts, published at /YYYY/MM/DD/slug/
//!   **/*.md              pages: about.md -> /about/, docs/index.md -> /docs/
//!   **/*.html            templates if they start with frontmatter,
//!                        otherwise copied as-is
//!   everything else      copied as-is
//!
//! The pipeline does no output I/O: it returns the file list so the
//! `build` command can write it to disk and the dev server can serve it
//! from memory. Everything is allocated from the build's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const SiteDir = @import("SiteDir.zig");
const sitepath = @import("path.zig");
const markdown = @import("markdown.zig");
const frontmatter = @import("frontmatter.zig");
const template = @import("template.zig");
const Value = template.Value;
const Entry = template.Entry;

pub const config_path = "_config.yml";
pub const output_dir = "_site";
pub const max_layout_depth = 16;

/// Where a build failed. `path` is a source site path; `line` is 1-based,
/// or 0 when the error is not tied to a line.
pub const Diagnostic = struct {
    path: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",

    pub fn format(d: Diagnostic, w: *Writer) Writer.Error!void {
        if (d.path.len == 0) return w.writeAll(d.message);
        if (d.line == 0) return w.print("{s}: {s}", .{ d.path, d.message });
        return w.print("{s}:{d}: {s}", .{ d.path, d.line, d.message });
    }
};

pub const Error = error{BuildFailed} || Allocator.Error;

pub const Output = struct {
    /// Site path inside the output directory.
    path: []const u8,
    /// Source site path this output comes from.
    source: []const u8,
    data: union(enum) {
        /// Rendered contents.
        bytes: []const u8,
        /// Copy the source file unchanged.
        copy,
    },
};

/// Which source files one output was built from, for incremental rebuilds.
pub const Deps = struct {
    output: []const u8,
    /// Source site paths read to produce the output, besides `_config.yml`,
    /// which every rendered page depends on.
    sources: []const []const u8,
    /// Whether rendering read `site.posts` or `site.pages`, so that the
    /// output changes whenever any page or post does.
    reads_collections: bool,
};

pub const Site = struct {
    /// Every output file, sorted by path.
    outputs: []const Output,
    /// Rendered outputs and the sources each one read.
    deps: []const Deps,
    pages: usize,
    posts: usize,
    static_files: usize,
    /// Pages rendered by the build that produced this site. An incremental
    /// rebuild reuses the rest from the previous build.
    rendered: usize,
    /// Whether this site was built from scratch, sharing no memory with an
    /// earlier build.
    full: bool,
    /// The site's URL prefix from `baseurl` in `_config.yml`, such as
    /// `/blog`, or "" when the site is served from the root. Page URLs
    /// include it; output paths do not.
    baseurl: []const u8,
    /// What `rebuild` needs to update this site. An incrementally rebuilt
    /// site shares memory with the site it came from, so that site's
    /// arena must outlive this one.
    state: State,

    pub fn find(s: Site, path: []const u8) ?Output {
        var lo: usize = 0;
        var hi = s.outputs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            switch (std.mem.order(u8, s.outputs[mid].path, path)) {
                .eq => return s.outputs[mid],
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }
};

const State = struct {
    config_fields: frontmatter.Map,
    baseurl: []const u8,
    /// Every page and post, in `pageOrder`.
    pages: []const Page,
    /// Files copied unchanged.
    statics: []const Output,
};

const Page = struct {
    source: []const u8,
    is_post: bool,
    is_markdown: bool,
    fields: frontmatter.Map,
    body: []const u8,
    body_line: usize,
    /// Public URL, including the site's baseurl.
    url: []const u8,
    out_path: []const u8,
    /// For posts, the `YYYY-MM-DD` date that orders the post and forms its
    /// URL: frontmatter `date` if set, otherwise the file name's date.
    date: []const u8 = "",
    /// Rendered Markdown, or null for HTML templates.
    html: ?[]const u8,
    object: template.Object = .{},
    /// Set once rendered: the output and what it depended on.
    output: []const u8 = "",
    sources: []const []const u8 = &.{},
    reads_collections: bool = false,
};

const Layout = struct {
    tpl: *const template.Template,
    parent: ?[]const u8,
};

const Builder = struct {
    arena: Allocator,
    src: SiteDir,
    diag: *Diagnostic,
    site: template.Object = .{},
    templates: std.StringHashMapUnmanaged(*const template.Template) = .empty,
    layouts: std.StringHashMapUnmanaged(Layout) = .empty,
    /// Lines to add to a template's line numbers to get file line numbers,
    /// for templates that follow frontmatter.
    line_offsets: std.StringHashMapUnmanaged(usize) = .empty,
    /// Sources read while rendering the current page.
    deps: std.ArrayList([]const u8) = .empty,
    /// Whether a template used by the current page reads site collections.
    reads_collections: bool = false,
    baseurl: []const u8 = "",

    fn fail(b: *Builder, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) Error {
        b.diag.* = .{
            .path = path,
            .line = line,
            .message = std.fmt.allocPrint(b.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.BuildFailed;
    }

    fn read(b: *Builder, path: []const u8) Error![]const u8 {
        return b.src.readFile(b.arena, path) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => b.fail(path, 0, "cannot read file: {s}", .{@errorName(err)}),
        };
    }

    fn exists(b: *Builder, path: []const u8) bool {
        b.src.dir.access(b.src.io, path, .{}) catch return false;
        return true;
    }

    fn addDep(b: *Builder, path: []const u8) Allocator.Error!void {
        for (b.deps.items) |d| if (std.mem.eql(u8, d, path)) return;
        try b.deps.append(b.arena, path);
    }

    fn useTemplate(b: *Builder, tpl: *const template.Template) void {
        b.reads_collections = b.reads_collections or tpl.reads_collections;
    }

    fn templateFail(b: *Builder, d: template.Diagnostic) Error {
        const offset = b.line_offsets.get(d.template) orelse 0;
        b.diag.* = .{ .path = d.template, .line = d.line + offset, .message = d.message };
        return error.BuildFailed;
    }
};

/// Builds the site in `src` from scratch. On `error.BuildFailed`, `diag`
/// says why.
pub fn build(arena: Allocator, src: SiteDir, diag: *Diagnostic) Error!Site {
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag };

    var bad: ?[]const u8 = null;
    const listing = src.listFiles(arena, &bad) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return b.fail(bad.?, 0, "file name is not portable across platforms; rename it", .{}),
        else => return b.fail("", 0, "cannot list the source directory: {s}", .{@errorName(err)}),
    };

    var pages: std.ArrayList(Page) = .empty;
    var statics: std.ArrayList(Output) = .empty;
    // The config comes first: page URLs depend on its `baseurl`.
    var config_fields: frontmatter.Map = .{};
    for (listing.files) |path| {
        if (std.mem.eql(u8, path, config_path)) config_fields = try loadConfig(&b);
    }
    b.baseurl = try baseUrl(&b, config_fields);

    for (listing.files) |path| {
        if (std.mem.eql(u8, path, config_path)) continue;
        if (std.mem.startsWith(u8, path, "_posts/")) {
            if (!std.mem.eql(u8, sitepath.extension(path), ".md")) continue;
            if (try loadPage(&b, path, true)) |p| try pages.append(arena, p);
            continue;
        }
        if (sitepath.hasHiddenComponent(path)) continue;

        const ext = sitepath.extension(path);
        if (std.mem.eql(u8, ext, ".md")) {
            if (try loadPage(&b, path, false)) |p| try pages.append(arena, p);
        } else if (std.mem.eql(u8, ext, ".html") and try startsWithFrontmatter(&b, path)) {
            if (try loadPage(&b, path, false)) |p| try pages.append(arena, p);
        } else {
            try statics.append(arena, .{ .path = path, .source = path, .data = .copy });
        }
    }
    std.mem.sortUnstable(Page, pages.items, {}, pageOrder);
    return finish(&b, config_fields, pages.items, statics.items, null);
}

/// Updates `prev` after the source files in `changed` were modified,
/// re-rendering only the outputs that depend on them:
///
///   - a changed page or post re-renders itself and every page whose
///     templates read `site.posts` or `site.pages`;
///   - a changed layout or include re-renders the pages that used it;
///   - a changed static file needs nothing, since it is copied when served
///     or written.
///
/// Anything whose effect is unclear falls back to a full `build`: the site
/// config, a file being added or removed, a page whose URL or draft status
/// changed, a static `.html` file gaining frontmatter, or a watcher
/// overflow. The result shares memory with `prev`.
pub fn rebuild(arena: Allocator, src: SiteDir, prev: *const Site, changed: []const []const u8, diag: *Diagnostic) Error!Site {
    const st = prev.state;
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag, .baseurl = st.baseurl };

    var dirty_templates: std.ArrayList([]const u8) = .empty;
    var dirty_pages: std.ArrayList(usize) = .empty;
    for (changed) |path| {
        if (std.mem.eql(u8, path, config_path) or std.mem.eql(u8, path, "*")) return build(arena, src, diag);
        if (std.mem.startsWith(u8, path, "_layouts/") or std.mem.startsWith(u8, path, "_includes/")) {
            try dirty_templates.append(arena, path);
            continue;
        }
        if (findPage(st.pages, path)) |i| {
            if (!b.exists(path)) return build(arena, src, diag);
            try dirty_pages.append(arena, i);
            continue;
        }
        if (findStatic(st.statics, path)) {
            if (!b.exists(path)) return build(arena, src, diag);
            if (std.mem.eql(u8, sitepath.extension(path), ".html") and try startsWithFrontmatter(&b, path)) {
                return build(arena, src, diag);
            }
            continue;
        }
        // Unpublished files such as `_drafts/` never affect the output, as
        // long as they are not new pages in disguise.
        if (sitepath.hasHiddenComponent(path) and !std.mem.startsWith(u8, path, "_posts/")) continue;
        // Something unknown that no longer exists, such as an editor's
        // temporary file that was renamed over a page, changed nothing,
        // unless it was a directory holding known files.
        if (!b.exists(path) and !containsKnown(st, path)) continue;
        return build(arena, src, diag);
    }

    const pages = try arena.dupe(Page, st.pages);
    for (dirty_pages.items) |i| {
        const old = pages[i];
        const fresh = (try loadPage(&b, old.source, old.is_post)) orelse return build(arena, src, diag);
        if (!std.mem.eql(u8, fresh.out_path, old.out_path)) return build(arena, src, diag);
        pages[i] = fresh;
    }

    const render = try arena.alloc(bool, pages.len);
    for (pages, render, 0..) |p, *r, i| {
        r.* = std.mem.indexOfScalar(usize, dirty_pages.items, i) != null or
            (dirty_pages.items.len > 0 and p.reads_collections) or
            usesAny(p.sources, dirty_templates.items);
    }
    return finish(&b, st.config_fields, pages, st.statics, render);
}

fn findPage(pages: []const Page, path: []const u8) ?usize {
    for (pages, 0..) |p, i| if (std.mem.eql(u8, p.source, path)) return i;
    return null;
}

fn findStatic(statics: []const Output, path: []const u8) bool {
    for (statics) |o| if (std.mem.eql(u8, o.source, path)) return true;
    return false;
}

/// Whether any known page or static file lives under directory `dir`.
fn containsKnown(st: State, dir: []const u8) bool {
    for (st.pages) |p| if (isUnder(p.source, dir)) return true;
    for (st.statics) |o| if (isUnder(o.source, dir)) return true;
    return false;
}

fn isUnder(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
}

fn usesAny(sources: []const []const u8, paths: []const []const u8) bool {
    for (sources) |s| {
        for (paths) |p| if (std.mem.eql(u8, s, p)) return true;
    }
    return false;
}

fn loadConfig(b: *Builder) Error!frontmatter.Map {
    var fd: frontmatter.Diagnostic = .{};
    return frontmatter.parseFile(b.arena, try b.read(config_path), &fd) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFrontmatter => b.fail(config_path, fd.line, "{s}", .{fd.message}),
    };
}

/// Reads and normalizes `baseurl` from the config: "" for the root,
/// otherwise a path starting with `/` and without a trailing `/`.
fn baseUrl(b: *Builder, config_fields: frontmatter.Map) Error![]const u8 {
    const v = config_fields.get("baseurl") orelse return "";
    const fail_msg = "'baseurl' must be a path such as /blog";
    if (v != .string) return b.fail(config_path, 0, fail_msg, .{});
    const raw = std.mem.trimEnd(u8, v.string, "/");
    if (raw.len == 0) return "";
    if (raw[0] != '/') return b.fail(config_path, 0, fail_msg, .{});
    _ = sitepath.normalize(b.arena, raw[1..]) catch return b.fail(config_path, 0, fail_msg, .{});
    return raw;
}

/// Renders the pages selected by `render` (all when null) and assembles the
/// site. `pages` must be in `pageOrder`.
fn finish(b: *Builder, config_fields: frontmatter.Map, pages: []Page, statics: []const Output, render: ?[]const bool) Error!Site {
    const arena = b.arena;

    // Pages and posts are visible to every template through `site`.
    var post_values: std.ArrayList(Value) = .empty;
    var page_values: std.ArrayList(Value) = .empty;
    var post_count: usize = 0;
    for (pages) |*p| {
        if (p.object.entries.len == 0) p.object = try pageObject(arena, p);
        if (p.is_post) {
            try post_values.append(arena, .{ .object = p.object });
            post_count += 1;
        } else {
            try page_values.append(arena, .{ .object = p.object });
        }
    }

    var site_entries: std.ArrayList(Entry) = .empty;
    for (config_fields.entries) |e| {
        if (std.mem.eql(u8, e.key, "posts") or std.mem.eql(u8, e.key, "pages")) {
            return b.fail(config_path, 0, "'{s}' is set by Mortise; use another key", .{e.key});
        }
        if (std.mem.eql(u8, e.key, "baseurl")) {
            try site_entries.append(arena, .{ .key = e.key, .value = .{ .string = b.baseurl } });
            continue;
        }
        try site_entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    try site_entries.append(arena, .{ .key = "posts", .value = .{ .list = post_values.items } });
    try site_entries.append(arena, .{ .key = "pages", .value = .{ .list = page_values.items } });
    b.site = .{ .entries = site_entries.items };

    var rendered: usize = 0;
    var outputs: std.ArrayList(Output) = .empty;
    try outputs.appendSlice(arena, statics);
    const deps = try arena.alloc(Deps, pages.len);
    for (pages, deps, 0..) |*p, *d, i| {
        if (render == null or render.?[i]) {
            b.deps = .empty;
            b.reads_collections = false;
            try b.addDep(p.source);
            p.output = try renderPage(b, p);
            p.sources = b.deps.items;
            p.reads_collections = b.reads_collections;
            rendered += 1;
        }
        try outputs.append(arena, .{ .path = p.out_path, .source = p.source, .data = .{ .bytes = p.output } });
        d.* = .{ .output = p.out_path, .sources = p.sources, .reads_collections = p.reads_collections };
    }

    std.mem.sortUnstable(Output, outputs.items, {}, outputOrder);
    for (outputs.items[0..outputs.items.len -| 1], outputs.items[@min(1, outputs.items.len)..]) |a, c| {
        if (std.mem.eql(u8, a.path, c.path)) {
            return b.fail(c.source, 0, "writes to '{s}', which '{s}' also writes to", .{ c.path, a.source });
        }
    }

    return .{
        .outputs = outputs.items,
        .deps = deps,
        .pages = pages.len - post_count,
        .posts = post_count,
        .static_files = statics.len,
        .rendered = rendered,
        .full = render == null,
        .baseurl = b.baseurl,
        .state = .{ .config_fields = config_fields, .baseurl = b.baseurl, .pages = pages, .statics = statics },
    };
}

fn startsWithFrontmatter(b: *Builder, path: []const u8) Error!bool {
    const data = try b.read(path);
    const d = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
    return std.mem.startsWith(u8, d, "---\n") or std.mem.startsWith(u8, d, "---\r\n");
}

/// Reads and parses a page or post. Returns null for drafts.
fn loadPage(b: *Builder, path: []const u8, is_post: bool) Error!?Page {
    const arena = b.arena;
    const data = try b.read(path);
    var fd: frontmatter.Diagnostic = .{};
    const doc = frontmatter.parse(arena, data, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
    };
    if (doc.fields.get("draft")) |d| {
        if (d != .boolean) return b.fail(path, fieldLine(data, "draft"), "'draft' must be true or false", .{});
        if (d.boolean) return null;
    }

    const is_markdown = std.mem.eql(u8, sitepath.extension(path), ".md");
    var page: Page = .{
        .source = path,
        .is_post = is_post,
        .is_markdown = is_markdown,
        .fields = doc.fields,
        .body = doc.body,
        .body_line = doc.body_line,
        .url = undefined,
        .out_path = undefined,
        .html = if (is_markdown) try markdown.toHtml(arena, doc.body) else null,
    };

    if (is_post) {
        const base = sitepath.basename(path);
        const name_date = if (base.len > 11) template.parseDate(base[0..10]) else null;
        if (name_date == null or base[10] != '-' or sitepath.stem(base).len <= 11) {
            return b.fail(path, 0, "post file names must look like YYYY-MM-DD-slug.md", .{});
        }
        page.date = base[0..10];
        // A frontmatter date overrides the file name's, as in Jekyll.
        if (doc.fields.get("date")) |d| {
            if (d != .string or template.parseDate(d.string) == null) {
                return b.fail(path, fieldLine(data, "date"), "'date' must look like YYYY-MM-DD", .{});
            }
            page.date = d.string[0..10];
        }
    }

    if (doc.fields.get("permalink")) |pl| {
        const line = fieldLine(data, "permalink");
        if (pl != .string or pl.string.len == 0 or pl.string[0] != '/') {
            return b.fail(path, line, "'permalink' must be a string starting with '/'", .{});
        }
        page.url = pl.string;
    } else if (is_post) {
        const d = page.date;
        page.url = try std.fmt.allocPrint(arena, "/{s}/{s}/{s}/{s}/", .{ d[0..4], d[5..7], d[8..10], sitepath.stem(path)[11..] });
    } else if (is_markdown) {
        const stem_path = path[0 .. path.len - ".md".len];
        if (std.mem.eql(u8, sitepath.basename(stem_path), "index")) {
            const dir = sitepath.dirname(stem_path);
            page.url = if (dir) |d| try std.fmt.allocPrint(arena, "/{s}/", .{d}) else "/";
        } else {
            page.url = try std.fmt.allocPrint(arena, "/{s}/", .{stem_path});
        }
    } else {
        page.url = if (std.mem.eql(u8, sitepath.basename(path), "index.html"))
            (if (sitepath.dirname(path)) |d| try std.fmt.allocPrint(arena, "/{s}/", .{d}) else "/")
        else
            try std.fmt.allocPrint(arena, "/{s}", .{path});
    }

    const out_raw = if (std.mem.endsWith(u8, page.url, "/"))
        try std.fmt.allocPrint(arena, "{s}index.html", .{page.url})
    else
        page.url;
    page.out_path = sitepath.normalize(arena, out_raw[1..]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return b.fail(path, fieldLine(data, "permalink"), "invalid output path '{s}': {s}", .{ out_raw, @errorName(err) }),
    };
    if (b.baseurl.len > 0) page.url = try std.mem.concat(arena, u8, &.{ b.baseurl, page.url });
    return page;
}

/// Best-effort line number of `key:` in a file's frontmatter, or 0.
fn fieldLine(data: []const u8, key: []const u8) usize {
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        if (n > 1 and std.mem.startsWith(u8, std.mem.trimEnd(u8, line, "\r"), "---")) return 0;
        if (std.mem.startsWith(u8, line, key) and line.len > key.len and line[key.len] == ':') return n;
    }
    return 0;
}

/// Posts newest first, then pages by path.
fn pageOrder(_: void, a: Page, c: Page) bool {
    if (a.is_post != c.is_post) return a.is_post;
    if (a.is_post) {
        switch (std.mem.order(u8, a.date, c.date)) {
            .gt => return true,
            .lt => return false,
            .eq => {},
        }
    }
    return std.mem.lessThan(u8, a.source, c.source);
}

fn outputOrder(_: void, a: Output, c: Output) bool {
    return switch (std.mem.order(u8, a.path, c.path)) {
        .lt => true,
        .gt => false,
        .eq => std.mem.lessThan(u8, a.source, c.source),
    };
}

fn pageObject(arena: Allocator, p: *const Page) Allocator.Error!template.Object {
    var entries: std.ArrayList(Entry) = .empty;
    for (p.fields.entries) |e| {
        if (isComputedKey(e.key)) continue;
        try entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    try entries.append(arena, .{ .key = "url", .value = .{ .string = p.url } });
    try entries.append(arena, .{ .key = "path", .value = .{ .string = p.source } });
    if (p.is_post) {
        const base = sitepath.basename(p.source);
        if (p.fields.get("date") == null) {
            try entries.append(arena, .{ .key = "date", .value = .{ .string = p.date } });
        }
        try entries.append(arena, .{ .key = "slug", .value = .{ .string = sitepath.stem(base)[11..] } });
    }
    if (p.html) |h| try entries.append(arena, .{ .key = "content", .value = .{ .html = h } });
    return .{ .entries = entries.items };
}

fn isComputedKey(key: []const u8) bool {
    for ([_][]const u8{ "url", "path", "slug", "content" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

fn convert(arena: Allocator, v: frontmatter.Value) Allocator.Error!Value {
    return switch (v) {
        .string => |s| .{ .string = s },
        .int => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .boolean => |x| .{ .boolean = x },
        .list => |l| blk: {
            const out = try arena.alloc(Value, l.len);
            for (l, out) |item, *o| o.* = try convert(arena, item);
            break :blk .{ .list = out };
        },
        .map => |m| blk: {
            const out = try arena.alloc(Entry, m.entries.len);
            for (m.entries, out) |e, *o| o.* = .{ .key = e.key, .value = try convert(arena, e.value) };
            break :blk .{ .object = .{ .entries = out } };
        },
    };
}

fn renderPage(b: *Builder, p: *const Page) Error![]const u8 {
    const arena = b.arena;
    var content: []const u8 = undefined;
    if (p.html) |h| {
        content = h;
    } else {
        try b.line_offsets.put(arena, p.source, p.body_line - 1);
        var td: template.Diagnostic = .{};
        const tpl = try arena.create(template.Template);
        tpl.* = template.parse(arena, p.source, p.body, &td) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TemplateSyntax => return b.templateFail(td),
        };
        content = try renderTemplate(b, tpl, p, null);
    }

    var layout_name: ?[]const u8 = null;
    var name_from: []const u8 = p.source;
    if (p.fields.get("layout")) |l| {
        if (l != .string) return b.fail(p.source, 0, "'layout' must be a string", .{});
        layout_name = l.string;
    }
    var depth: usize = 0;
    while (layout_name) |name| : (depth += 1) {
        if (depth >= max_layout_depth) {
            return b.fail(name_from, 0, "layouts nested more than {d} deep (does '{s}' use itself?)", .{ max_layout_depth, name });
        }
        const layout = try loadLayout(b, name, name_from);
        content = try renderTemplate(b, layout.tpl, p, content);
        name_from = layout.tpl.name;
        layout_name = layout.parent;
    }
    return content;
}

fn renderTemplate(b: *Builder, tpl: *const template.Template, p: *const Page, content: ?[]const u8) Error![]const u8 {
    var entries: [3]Entry = .{
        .{ .key = "site", .value = .{ .object = b.site } },
        .{ .key = "page", .value = .{ .object = p.object } },
        .{ .key = "content", .value = .{ .html = content orelse "" } },
    };
    const root: template.Object = .{ .entries = entries[0..if (content != null) 3 else 2] };
    b.useTemplate(tpl);
    var td: template.Diagnostic = .{};
    return template.renderAlloc(b.arena, tpl, root, .{ .ctx = b, .loadFn = loadInclude }, &td) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.OutOfMemory,
        error.TemplateRender, error.TemplateSyntax => b.templateFail(td),
        error.TemplateNotFound => b.fail(td.template, td.line, "{s}", .{td.message}),
    };
}

fn loadLayout(b: *Builder, name: []const u8, used_by: []const u8) Error!Layout {
    const arena = b.arena;
    const path = try std.fmt.allocPrint(arena, "_layouts/{s}{s}", .{ name, if (std.mem.endsWith(u8, name, ".html")) "" else ".html" });
    try b.addDep(path);
    if (b.layouts.get(path)) |l| return l;

    const data = b.src.readFile(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return b.fail(used_by, 0, "layout '{s}' not found (looked for {s})", .{ name, path }),
        else => return b.fail(path, 0, "cannot read file: {s}", .{@errorName(err)}),
    };
    var fd: frontmatter.Diagnostic = .{};
    const doc = frontmatter.parse(arena, data, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
    };
    try b.line_offsets.put(arena, path, doc.body_line - 1);
    var td: template.Diagnostic = .{};
    const tpl = try arena.create(template.Template);
    tpl.* = template.parse(arena, path, doc.body, &td) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TemplateSyntax => return b.templateFail(td),
    };
    var parent: ?[]const u8 = null;
    if (doc.fields.get("layout")) |l| {
        if (l != .string) return b.fail(path, fieldLine(data, "layout"), "'layout' must be a string", .{});
        parent = l.string;
    }
    const layout: Layout = .{ .tpl = tpl, .parent = parent };
    try b.layouts.put(arena, path, layout);
    return layout;
}

fn loadInclude(ctx: *anyopaque, name: []const u8, diag: *template.Diagnostic) template.Loader.LoadError!*const template.Template {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    const arena = b.arena;
    const raw = try std.fmt.allocPrint(arena, "_includes/{s}", .{name});
    const path = sitepath.normalize(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    // An include name with `..` must not reach outside `_includes/`.
    if (!std.mem.startsWith(u8, path, "_includes/")) return error.TemplateNotFound;
    try b.addDep(path);
    if (b.templates.get(path)) |t| {
        b.useTemplate(t);
        return t;
    }

    const data = b.src.readFile(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    const tpl = try arena.create(template.Template);
    tpl.* = try template.parse(arena, path, data, diag);
    try b.templates.put(arena, path, tpl);
    b.useTemplate(tpl);
    return tpl;
}

/// Writes every output into `out`, copying static files from `src`.
pub fn writeSite(site: Site, src: SiteDir, out: SiteDir, diag: *Diagnostic) error{BuildFailed}!void {
    for (site.outputs) |o| {
        const result = switch (o.data) {
            .bytes => |bytes| out.writeFile(o.path, bytes),
            .copy => src.copyFileTo(o.source, out, o.path),
        };
        result catch |err| {
            diag.* = .{ .path = o.path, .message = @errorName(err) };
            return error.BuildFailed;
        };
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestSite = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init(files: []const struct { []const u8, []const u8 }) !TestSite {
        const t: TestSite = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .arena = .init(testing.allocator) };
        const site = SiteDir.borrow(testing.io, t.tmp.dir);
        for (files) |f| try site.writeFile(f[0], f[1]);
        return t;
    }

    fn deinit(t: *TestSite) void {
        t.arena.deinit();
        t.tmp.cleanup();
    }

    fn build(t: *TestSite, diag: *Diagnostic) Error!Site {
        return @import("pipeline.zig").build(t.arena.allocator(), SiteDir.borrow(testing.io, t.tmp.dir), diag);
    }

    fn output(t: *TestSite, path: []const u8) ![]const u8 {
        var diag: Diagnostic = .{};
        const site = t.build(&diag) catch |err| {
            std.debug.print("build failed: {f}\n", .{diag});
            return err;
        };
        const o = site.find(path) orelse return error.TestUnexpectedResult;
        return o.data.bytes;
    }
};

fn expectBuildError(files: []const struct { []const u8, []const u8 }, path: []const u8, line: usize, part: []const u8) !void {
    var t: TestSite = try .init(files);
    defer t.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.BuildFailed, t.build(&diag));
    testing.expectEqualStrings(path, diag.path) catch |err| {
        std.debug.print("diagnostic: {f}\n", .{diag});
        return err;
    };
    testing.expectEqual(line, diag.line) catch |err| {
        std.debug.print("diagnostic: {f}\n", .{diag});
        return err;
    };
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "pages, posts, layouts, and static files" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Test Site\n" },
        .{ "_layouts/base.html", "<title>{{ page.title }} | {{ site.title }}</title>{{ content }}" },
        .{ "_layouts/post.html", "---\nlayout: base\n---\n<article>{{ content }}</article>" },
        .{ "_includes/footer.html", "<footer>{{ site.title }}</footer>" },
        .{ "index.html", "---\ntitle: Home\nlayout: base\n---\n{% for p in site.posts %}<a href=\"{{ p.url }}\">{{ p.title }}</a>{% endfor %}{% include \"footer.html\" %}" },
        .{ "about.md", "---\ntitle: About\n---\n# About *me*\n" },
        .{ "docs/index.md", "Docs home\n" },
        .{ "_posts/2024-01-05-hello.md", "---\ntitle: Hello\nlayout: post\n---\nFirst post.\n" },
        .{ "_posts/2024-03-01-second.md", "---\ntitle: Second\nlayout: post\n---\nSecond post.\n" },
        .{ "_posts/2024-02-01-draft.md", "---\ntitle: Draft\ndraft: true\n---\nHidden.\n" },
        .{ "css/site.css", "body{}" },
        .{ "plain.html", "<p>not a template {{ x }}</p>" },
        .{ "_drafts/ignored.md", "x" },
        .{ ".hidden/x.txt", "x" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);

    const paths = [_][]const u8{
        "2024/01/05/hello/index.html",
        "2024/03/01/second/index.html",
        "about/index.html",
        "css/site.css",
        "docs/index.html",
        "index.html",
        "plain.html",
    };
    try testing.expectEqual(paths.len, site.outputs.len);
    for (paths, site.outputs) |p, o| try testing.expectEqualStrings(p, o.path);
    try testing.expectEqual(@as(usize, 3), site.pages);
    try testing.expectEqual(@as(usize, 2), site.posts);
    try testing.expectEqual(@as(usize, 2), site.static_files);

    try testing.expectEqualStrings(
        "<title>Home | Test Site</title><a href=\"/2024/03/01/second/\">Second</a><a href=\"/2024/01/05/hello/\">Hello</a><footer>Test Site</footer>",
        site.find("index.html").?.data.bytes,
    );
    try testing.expectEqualStrings(
        "<title>Hello | Test Site</title><article><p>First post.</p>\n</article>",
        site.find("2024/01/05/hello/index.html").?.data.bytes,
    );
    try testing.expectEqualStrings("<h1>About <em>me</em></h1>\n", site.find("about/index.html").?.data.bytes);
    try testing.expect(site.find("plain.html").?.data == .copy);

    // The home page depends on itself, its layout, and the include it used.
    for (site.deps) |d| {
        if (!std.mem.eql(u8, d.output, "index.html")) continue;
        try testing.expectEqual(@as(usize, 3), d.sources.len);
        try testing.expectEqualStrings("index.html", d.sources[0]);
        try testing.expectEqualStrings("_includes/footer.html", d.sources[1]);
        try testing.expectEqualStrings("_layouts/base.html", d.sources[2]);
    }
}

test "permalink override" {
    var t: TestSite = try .init(&.{
        .{ "notes.md", "---\npermalink: /custom/path/\n---\nx\n" },
        .{ "feed.html", "---\npermalink: /feed.xml\n---\n<feed/>" },
    });
    defer t.deinit();
    try testing.expectEqualStrings("<p>x</p>\n", try t.output("custom/path/index.html"));
    try testing.expectEqualStrings("<feed/>", try t.output("feed.xml"));
}

test "build errors carry path and line" {
    try expectBuildError(&.{.{ "a.md", "---\ntitle: x\ntitle: y\n---\n" }}, "a.md", 3, "duplicate key");
    try expectBuildError(&.{.{ "_config.yml", "title: a\nposts: 1\n" }}, "_config.yml", 0, "set by Mortise");
    try expectBuildError(&.{.{ "_posts/hello.md", "x" }}, "_posts/hello.md", 0, "YYYY-MM-DD-slug.md");
    try expectBuildError(&.{.{ "a.md", "---\nlayout: nope\n---\n" }}, "a.md", 0, "layout 'nope' not found");
    try expectBuildError(&.{
        .{ "a.md", "---\nlayout: l\n---\n" },
        .{ "_layouts/l.html", "---\ntitle: t\n---\n\n{{ page.title | shout }}" },
    }, "_layouts/l.html", 5, "unknown filter");
    try expectBuildError(&.{.{ "p.html", "---\ntitle: t\n---\nline 4\n{% include \"missing.html\" %}" }}, "p.html", 5, "not found");
    try expectBuildError(&.{
        .{ "p.html", "---\nx: 1\n---\n{% include \"bad.html\" %}" },
        .{ "_includes/bad.html", "ok\n{% if %}" },
    }, "_includes/bad.html", 2, "missing condition");
    try expectBuildError(&.{
        .{ "a.md", "---\nlayout: loop\n---\n" },
        .{ "_layouts/loop.html", "---\nlayout: loop\n---\n{{ content }}" },
    }, "_layouts/loop.html", 0, "nested more than");
    try expectBuildError(&.{
        .{ "a.md", "x" },
        .{ "b.md", "---\npermalink: /a/\n---\n" },
    }, "b.md", 0, "also writes to");
    try expectBuildError(&.{.{ "a.md", "---\npermalink: /../x/\n---\n" }}, "a.md", 2, "invalid output path");
    try expectBuildError(&.{.{ "a.md", "---\ndraft: yes\n---\n" }}, "a.md", 2, "'draft' must be true or false");
}

fn expectSameOutputs(a: Site, b: Site) !void {
    try testing.expectEqual(a.outputs.len, b.outputs.len);
    for (a.outputs, b.outputs) |x, y| {
        try testing.expectEqualStrings(x.path, y.path);
        switch (x.data) {
            .copy => try testing.expect(y.data == .copy),
            .bytes => |bytes| try testing.expectEqualStrings(bytes, y.data.bytes),
        }
    }
}

test "incremental rebuild re-renders only affected outputs" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Inc\n" },
        .{ "_layouts/base.html", "<title>{{ page.title }}</title>{{ content }}" },
        .{ "_layouts/post.html", "---\nlayout: base\n---\n<article>{{ content }}</article>" },
        .{ "_includes/list.html", "{% for p in site.posts %}[{{ p.title }}]{% endfor %}" },
        .{ "index.html", "---\ntitle: Home\nlayout: base\n---\n{% include \"list.html\" %}" },
        .{ "about.md", "---\ntitle: About\nlayout: base\n---\nAbout.\n" },
        .{ "_posts/2024-01-01-a.md", "---\ntitle: A\nlayout: post\n---\nA body.\n" },
        .{ "_posts/2024-02-01-b.md", "---\ntitle: B\nlayout: post\n---\nB body.\n" },
        .{ "css/site.css", "body{}" },
        .{ "_drafts/idea.md", "later" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};

    var site = try t.build(&diag);
    try testing.expectEqual(@as(usize, 4), site.rendered);

    // A post's body: the post and the index, which lists posts.
    try src.writeFile("_posts/2024-01-01-a.md", "---\ntitle: A2\nlayout: post\n---\nNew body.\n");
    site = try rebuild(a, src, &site, &.{"_posts/2024-01-01-a.md"}, &diag);
    try testing.expectEqual(@as(usize, 2), site.rendered);
    try testing.expectEqualStrings("<title>A2</title><article><p>New body.</p>\n</article>", site.find("2024/01/01/a/index.html").?.data.bytes);
    try testing.expectEqualStrings("<title>Home</title>[B][A2]", site.find("index.html").?.data.bytes);

    // An include: only the page that uses it.
    try src.writeFile("_includes/list.html", "{% for p in site.posts %}<{{ p.title }}>{% endfor %}");
    site = try rebuild(a, src, &site, &.{"_includes/list.html"}, &diag);
    try testing.expectEqual(@as(usize, 1), site.rendered);
    try testing.expectEqualStrings("<title>Home</title><B><A2>", site.find("index.html").?.data.bytes);

    // The post layout: only the posts.
    try src.writeFile("_layouts/post.html", "---\nlayout: base\n---\n<main>{{ content }}</main>");
    site = try rebuild(a, src, &site, &.{"_layouts/post.html"}, &diag);
    try testing.expectEqual(@as(usize, 2), site.rendered);

    // A shared layout: every page using it.
    try src.writeFile("_layouts/base.html", "<h1>{{ page.title }}</h1>{{ content }}");
    site = try rebuild(a, src, &site, &.{"_layouts/base.html"}, &diag);
    try testing.expectEqual(@as(usize, 4), site.rendered);

    // A static file or an unpublished draft: nothing to render.
    try src.writeFile("css/site.css", "body{color:red}");
    try src.writeFile("_drafts/idea.md", "still later");
    site = try rebuild(a, src, &site, &.{ "css/site.css", "_drafts/idea.md" }, &diag);
    try testing.expectEqual(@as(usize, 0), site.rendered);

    // Unclear effects fall back to a full build.
    try src.writeFile("_config.yml", "title: Changed\n");
    site = try rebuild(a, src, &site, &.{"_config.yml"}, &diag);
    try testing.expectEqual(@as(usize, 4), site.rendered);
    try src.writeFile("_posts/2024-03-01-c.md", "---\ntitle: C\nlayout: post\n---\nC.\n");
    site = try rebuild(a, src, &site, &.{"_posts/2024-03-01-c.md"}, &diag);
    try testing.expectEqual(@as(usize, 5), site.rendered);
    try src.writeFile("about.md", "---\ntitle: About\nlayout: base\npermalink: /me/\n---\nAbout.\n");
    site = try rebuild(a, src, &site, &.{"about.md"}, &diag);
    try testing.expectEqual(@as(usize, 5), site.rendered);
    try testing.expect(site.find("me/index.html") != null);

    // After all that, the result matches a build from scratch.
    try src.writeFile("_posts/2024-02-01-b.md", "---\ntitle: B2\nlayout: post\n---\nB2 body.\n");
    site = try rebuild(a, src, &site, &.{"_posts/2024-02-01-b.md"}, &diag);
    try testing.expectEqual(@as(usize, 2), site.rendered);
    try expectSameOutputs(try t.build(&diag), site);
}

test "incremental rebuild reports errors in changed files" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/base.html", "{{ content }}" },
        .{ "a.md", "---\nlayout: base\n---\nA\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);

    try src.writeFile("_layouts/base.html", "{% if %}");
    try testing.expectError(error.BuildFailed, rebuild(t.arena.allocator(), src, &site, &.{"_layouts/base.html"}, &diag));
    try testing.expectEqualStrings("_layouts/base.html", diag.path);

    try src.writeFile("a.md", "---\nlayout: base\nlayout: x\n---\n");
    try testing.expectError(error.BuildFailed, rebuild(t.arena.allocator(), src, &site, &.{"a.md"}, &diag));
    try testing.expectEqualStrings("a.md", diag.path);
    try testing.expectEqual(@as(usize, 3), diag.line);
}

test "incremental rebuild ignores vanished temporary files but not vanished directories" {
    var t: TestSite = try .init(&.{
        .{ "a.md", "A\n" },
        .{ "docs/b.md", "B\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = try t.build(&diag);

    // An editor wrote a.md.tmp and renamed it over a.md.
    try src.writeFile("a.md", "A2\n");
    site = try rebuild(t.arena.allocator(), src, &site, &.{ "a.md.tmp", "a.md" }, &diag);
    try testing.expect(!site.full);
    try testing.expectEqual(@as(usize, 1), site.rendered);

    // A directory with pages in it disappeared in one event.
    try src.deleteTree("docs");
    site = try rebuild(t.arena.allocator(), src, &site, &.{"docs"}, &diag);
    try testing.expect(site.full);
    try testing.expect(site.find("docs/b/index.html") == null);
}

test "baseurl prefixes page URLs but not output paths" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "baseurl: /blog/\n" },
        .{ "index.html", "---\nx: 1\n---\n{{ site.baseurl }}|{% for p in site.posts %}{{ p.url }}{% endfor %}|{{ page.url }}" },
        .{ "_posts/2024-01-05-a.md", "A\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expectEqualStrings("/blog", site.baseurl);
    try testing.expectEqualStrings("/blog|/blog/2024/01/05/a/|/blog/", site.find("index.html").?.data.bytes);
    try testing.expect(site.find("2024/01/05/a/index.html") != null);

    try expectBuildError(&.{.{ "_config.yml", "baseurl: blog\n" }}, "_config.yml", 0, "'baseurl' must be a path");
    try expectBuildError(&.{.{ "_config.yml", "baseurl: /../x\n" }}, "_config.yml", 0, "'baseurl' must be a path");
}

test "a frontmatter date overrides the file name date" {
    var t: TestSite = try .init(&.{
        .{ "index.html", "---\nx: 1\n---\n{% for p in site.posts %}{{ p.url }} {% endfor %}" },
        .{ "_posts/2024-01-05-a.md", "---\ndate: 2024-06-01\n---\nA\n" },
        .{ "_posts/2024-03-01-b.md", "B\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    // Post a is now the newest, published under its frontmatter date.
    try testing.expectEqualStrings("/2024/06/01/a/ /2024/03/01/b/ ", site.find("index.html").?.data.bytes);

    try expectBuildError(&.{.{ "_posts/2024-01-05-a.md", "---\ndate: soon\n---\n" }}, "_posts/2024-01-05-a.md", 2, "'date' must look like YYYY-MM-DD");
}
