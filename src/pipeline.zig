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
const feeds = @import("feeds.zig");
const data_files = @import("data.zig");
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
    site_url: ?[]const u8,
    options: Options,
    data: Value,
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
    /// Table of contents of the Markdown's level 2 and 3 headings, as HTML,
    /// or null when there are none.
    toc: ?[]const u8 = null,
    object: template.Object = .{},
    /// Set once rendered: the output and what it depended on.
    output: []const u8 = "",
    /// Pages 2 and up of a paginated page.
    extra_outputs: []const Output = &.{},
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
    /// Absolute site URL from `url` in the config, needed for the feed and
    /// sitemap; null when unset.
    site_url: ?[]const u8 = null,
    options: Options = .{},
    /// `site.data`, from the files in `_data/`.
    data: Value = .{ .object = .{} },
    /// The `paginator` variable while rendering one page of a paginated
    /// page, or null.
    paginator: ?template.Object = null,

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
    return buildWith(arena, src, .{}, diag);
}

pub const Options = struct {
    /// Publish pages and posts marked `draft: true`.
    drafts: bool = false,
};

/// `build` with options.
pub fn buildWith(arena: Allocator, src: SiteDir, options: Options, diag: *Diagnostic) Error!Site {
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag, .options = options };

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
    b.site_url = try siteUrl(&b, config_fields);
    b.data = try loadData(&b, listing.files);

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
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag, .baseurl = st.baseurl, .site_url = st.site_url, .data = st.data, .options = st.options };

    var dirty_templates: std.ArrayList([]const u8) = .empty;
    var dirty_pages: std.ArrayList(usize) = .empty;
    for (changed) |path| {
        // The config and data files feed `site`, which any page may read.
        if (std.mem.eql(u8, path, config_path) or std.mem.eql(u8, path, "*") or
            std.mem.startsWith(u8, path, data_files.dir_prefix)) return buildWith(arena, src, st.options, diag);
        if (std.mem.startsWith(u8, path, "_layouts/") or std.mem.startsWith(u8, path, "_includes/")) {
            try dirty_templates.append(arena, path);
            continue;
        }
        if (findPage(st.pages, path)) |i| {
            if (!b.exists(path)) return buildWith(arena, src, st.options, diag);
            try dirty_pages.append(arena, i);
            continue;
        }
        if (findStatic(st.statics, path)) {
            if (!b.exists(path)) return buildWith(arena, src, st.options, diag);
            if (std.mem.eql(u8, sitepath.extension(path), ".html") and try startsWithFrontmatter(&b, path)) {
                return buildWith(arena, src, st.options, diag);
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
        return buildWith(arena, src, st.options, diag);
    }

    const pages = try arena.dupe(Page, st.pages);
    for (dirty_pages.items) |i| {
        const old = pages[i];
        const fresh = (try loadPage(&b, old.source, old.is_post)) orelse return buildWith(arena, src, st.options, diag);
        if (!std.mem.eql(u8, fresh.out_path, old.out_path)) return buildWith(arena, src, st.options, diag);
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

/// Loads every data file into the value of `site.data`.
fn loadData(b: *Builder, files: []const []const u8) Error!Value {
    var tree: data_files.Tree = .{ .arena = b.arena };
    for (files) |path| {
        if (!data_files.isDataFile(path)) continue;
        var dd: data_files.Diagnostic = .{};
        const value = data_files.parse(b.arena, path, try b.read(path), &dd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidData => return b.fail(path, dd.line, "{s}", .{dd.message}),
        };
        if (!try tree.add(path, value)) {
            return b.fail(path, 0, "its name clashes with another data file or directory", .{});
        }
    }
    return tree.toObject();
}

/// Reads and normalizes `url` from the config, or null when unset.
fn siteUrl(b: *Builder, config_fields: frontmatter.Map) Error!?[]const u8 {
    const v = config_fields.get("url") orelse return null;
    if (v != .string) return b.fail(config_path, 0, "'url' must be an absolute URL such as https://example.com", .{});
    return feeds.normalizeSiteUrl(v.string) orelse
        b.fail(config_path, 0, "'url' must be an absolute URL such as https://example.com", .{});
}

fn stringField(m: frontmatter.Map, key: []const u8) ?[]const u8 {
    const v = m.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Whether config switch `key` (such as `feed: false`) is on. Defaults on.
fn enabled(b: *Builder, config_fields: frontmatter.Map, key: []const u8) Error!bool {
    const v = config_fields.get(key) orelse return true;
    if (v != .boolean) return b.fail(config_path, 0, "'{s}' must be true or false", .{key});
    return v.boolean;
}

fn hasOutput(outputs: []const Output, path: []const u8) bool {
    for (outputs) |o| if (std.mem.eql(u8, o.path, path)) return true;
    return false;
}

/// Adds the Atom feed and the sitemap, unless the config turns them off or
/// the site already has a file at that path.
fn addGenerated(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map, pages: []const Page, url: []const u8) Error!void {
    const arena = b.arena;
    const title = stringField(config_fields, "title") orelse "";
    const site: feeds.Site = .{
        .url = url,
        .baseurl = b.baseurl,
        .title = title,
        .author = stringField(config_fields, "author") orelse title,
    };
    var posts: std.ArrayList(feeds.Entry) = .empty;
    var listed: std.ArrayList(feeds.Entry) = .empty;
    for (pages) |p| {
        const entry: feeds.Entry = .{
            .title = stringField(p.fields, "title") orelse "",
            .url = p.url,
            .date = p.date,
            .html = p.html orelse "",
        };
        if (p.is_post) try posts.append(arena, entry);
        const opted_out = if (p.fields.get("sitemap")) |v| v == .boolean and !v.boolean else false;
        if (!opted_out and !std.mem.eql(u8, p.out_path, "404.html")) try listed.append(arena, entry);
    }
    if (try enabled(b, config_fields, "feed") and posts.items.len > 0 and !hasOutput(outputs.items, feeds.feed_path)) {
        try outputs.append(arena, .{ .path = feeds.feed_path, .source = config_path, .data = .{ .bytes = try feeds.atom(arena, site, posts.items) } });
    }
    if (try enabled(b, config_fields, "sitemap") and !hasOutput(outputs.items, feeds.sitemap_path)) {
        try outputs.append(arena, .{ .path = feeds.sitemap_path, .source = config_path, .data = .{ .bytes = try feeds.sitemap(arena, site, listed.items) } });
    }
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
        if (std.mem.eql(u8, e.key, "posts") or std.mem.eql(u8, e.key, "pages") or
            std.mem.eql(u8, e.key, "data") or std.mem.eql(u8, e.key, "tags"))
        {
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
    try site_entries.append(arena, .{ .key = "data", .value = b.data });
    const tag_pages = b.exists(tag_layout);
    const tags = try tagIndex(arena, pages, if (tag_pages) b.baseurl else null);
    try site_entries.append(arena, .{ .key = "tags", .value = tags });
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
            try renderPaginated(b, p, post_values.items);
            p.sources = b.deps.items;
            p.reads_collections = b.reads_collections;
            rendered += 1;
        }
        try outputs.append(arena, .{ .path = p.out_path, .source = p.source, .data = .{ .bytes = p.output } });
        try outputs.appendSlice(arena, p.extra_outputs);
        d.* = .{ .output = p.out_path, .sources = p.sources, .reads_collections = p.reads_collections };
    }

    if (tag_pages) try addTagPages(b, &outputs, tags.list);
    if (b.site_url) |url| try addGenerated(b, &outputs, config_fields, pages, url);

    std.mem.sortUnstable(Output, outputs.items, {}, outputOrder);
    for (outputs.items[0..outputs.items.len -| 1], outputs.items[@min(1, outputs.items.len)..]) |a, c| {
        if (std.mem.eql(u8, a.path, c.path)) {
            return b.fail(c.source, 0, "writes to '{s}', which '{s}' also writes to", .{ c.path, a.source });
        }
    }
    try checkCaseCollisions(b, outputs.items);

    return .{
        .outputs = outputs.items,
        .deps = deps,
        .pages = pages.len - post_count,
        .posts = post_count,
        .static_files = statics.len,
        .rendered = rendered,
        .full = render == null,
        .baseurl = b.baseurl,
        .state = .{ .config_fields = config_fields, .baseurl = b.baseurl, .site_url = b.site_url, .options = b.options, .data = b.data, .pages = pages, .statics = statics },
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
        if (d.boolean and !b.options.drafts) return null;
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
        .html = null,
    };
    if (is_markdown) {
        const rendered = try markdown.toDocument(arena, doc.body);
        page.html = rendered.html;
        page.toc = try tocHtml(arena, rendered.headings);
    }

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
    if (p.html) |h| {
        try entries.append(arena, .{ .key = "content", .value = .{ .html = h } });
        if (p.toc) |toc| try entries.append(arena, .{ .key = "toc", .value = .{ .html = toc } });
        // The excerpt is frontmatter `excerpt` if set, else the first
        // paragraph of the rendered Markdown.
        if (p.fields.get("excerpt") == null) {
            if (firstParagraph(h)) |para| try entries.append(arena, .{ .key = "excerpt", .value = .{ .html = para } });
        }
    }
    return .{ .entries = entries.items };
}

/// A nested list of links to the level 2 and 3 headings, or null when
/// there are none:
///
///   <ul class="toc"><li><a href="#a">A</a><ul><li>...</li></ul></li></ul>
fn tocHtml(arena: Allocator, headings: []const markdown.Heading) Allocator.Error!?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeToc(&aw.writer, headings) catch return error.OutOfMemory;
    const html = try aw.toOwnedSlice();
    return if (html.len == 0) null else html;
}

fn writeToc(w: *std.Io.Writer, headings: []const markdown.Heading) std.Io.Writer.Error!void {
    var started = false;
    var open = false; // a level 2 <li> is open
    var nested = false; // a <ul> of level 3 items is open inside it
    for (headings) |h| {
        if (h.level != 2 and h.level != 3) continue;
        if (!started) try w.writeAll("<ul class=\"toc\">\n");
        started = true;
        if (h.level == 3 and open) {
            if (!nested) try w.writeAll("\n<ul>\n");
            nested = true;
            try tocLink(w, h);
            try w.writeAll("</li>\n");
            continue;
        }
        if (nested) try w.writeAll("</ul>\n");
        if (open) try w.writeAll("</li>\n");
        nested = false;
        try tocLink(w, h);
        // A level 2 item stays open for its level 3 children.
        open = h.level == 2;
        if (!open) try w.writeAll("</li>\n");
    }
    if (nested) try w.writeAll("</ul>\n");
    if (open) try w.writeAll("</li>\n");
    if (started) try w.writeAll("</ul>\n");
}

fn tocLink(w: *std.Io.Writer, h: markdown.Heading) std.Io.Writer.Error!void {
    try w.writeAll("<li><a href=\"#");
    try markdown.escapeHtml(w, h.id);
    try w.writeAll("\">");
    try markdown.escapeHtml(w, h.text);
    try w.writeAll("</a>");
}

/// The first `<p>...</p>` element of rendered Markdown, or null.
fn firstParagraph(html: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, html, "<p>") orelse return null;
    const end = std.mem.indexOfPos(u8, html, start, "</p>") orelse return null;
    return html[start .. end + "</p>".len];
}

/// The tags in a page's `tags` field, which is a list of strings or one
/// string. Non-string items are skipped.
fn pageTags(arena: Allocator, p: *const Page) Allocator.Error![]const []const u8 {
    const v = p.fields.get("tags") orelse return &.{};
    switch (v) {
        .string => |s| return arena.dupe([]const u8, &.{s}),
        .list => |l| {
            var out: std.ArrayList([]const u8) = .empty;
            for (l) |item| if (item == .string) try out.append(arena, item.string);
            return out.items;
        },
        else => return &.{},
    }
}

/// Layout that turns on generated tag pages at `/tags/<slug>/`.
pub const tag_layout = "_layouts/tag.html";

/// `site.tags`: one object per tag, sorted by name, with the tag's posts
/// newest first. When tag pages are generated, each also has its `url`
/// and `slug`.
fn tagIndex(arena: Allocator, pages: []const Page, tag_pages_base: ?[]const u8) Allocator.Error!Value {
    // Tags that differ only in case or punctuation ("Zig Lang", "zig-lang")
    // are one tag, named as in the newest post that uses it, so each gets
    // one page.
    var names: std.ArrayList([]const u8) = .empty;
    var slugs: std.ArrayList([]const u8) = .empty;
    var lists: std.ArrayList(std.ArrayList(Value)) = .empty;
    for (pages) |*p| {
        if (!p.is_post) continue;
        for (try pageTags(arena, p)) |tag| {
            const slug = try markdown.slugify(arena, tag);
            const i = for (slugs.items, 0..) |s, i| {
                if (std.mem.eql(u8, s, slug)) break i;
            } else blk: {
                try names.append(arena, tag);
                try slugs.append(arena, slug);
                try lists.append(arena, .empty);
                break :blk names.items.len - 1;
            };
            try lists.items[i].append(arena, .{ .object = p.object });
        }
    }
    const Tag = struct { name: []const u8, posts: []const Value };
    const tags = try arena.alloc(Tag, names.items.len);
    for (tags, names.items, lists.items) |*t, n, l| t.* = .{ .name = n, .posts = l.items };
    std.mem.sortUnstable(Tag, tags, {}, struct {
        fn lt(_: void, a: Tag, b: Tag) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    const out = try arena.alloc(Value, tags.len);
    for (tags, out) |t, *o| {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.append(arena, .{ .key = "name", .value = .{ .string = t.name } });
        try entries.append(arena, .{ .key = "posts", .value = .{ .list = t.posts } });
        if (tag_pages_base) |base| {
            const slug = try markdown.slugify(arena, t.name);
            try entries.append(arena, .{ .key = "slug", .value = .{ .string = slug } });
            try entries.append(arena, .{ .key = "url", .value = .{ .string = try std.fmt.allocPrint(arena, "{s}/tags/{s}/", .{ base, slug }) } });
        }
        o.* = .{ .object = .{ .entries = entries.items } };
    }
    return .{ .list = out };
}

/// Renders one page per tag with the `tag` layout, which sees `page.tag`,
/// `page.title` (both the tag name), `page.posts`, and `page.url`.
fn addTagPages(b: *Builder, outputs: *std.ArrayList(Output), tags: []const Value) Error!void {
    const arena = b.arena;
    const layout_field = try arena.dupe(frontmatter.Entry, &.{.{ .key = "layout", .value = .{ .string = "tag" } }});
    for (tags) |tag| {
        const t = tag.object;
        const slug = t.get("slug").?.string;
        var page: Page = .{
            .source = tag_layout,
            .is_post = false,
            .is_markdown = false,
            .fields = .{ .entries = layout_field },
            .body = "",
            .body_line = 1,
            .url = t.get("url").?.string,
            .out_path = try std.fmt.allocPrint(arena, "tags/{s}/index.html", .{slug}),
            .html = "",
        };
        const entries = try arena.alloc(Entry, 4);
        entries[0] = .{ .key = "title", .value = t.get("name").? };
        entries[1] = .{ .key = "tag", .value = t.get("name").? };
        entries[2] = .{ .key = "posts", .value = t.get("posts").? };
        entries[3] = .{ .key = "url", .value = .{ .string = page.url } };
        page.object = .{ .entries = entries };
        b.deps = .empty;
        const html = try renderPage(b, &page);
        try outputs.append(arena, .{ .path = page.out_path, .source = tag_layout, .data = .{ .bytes = html } });
    }
}

fn isComputedKey(key: []const u8) bool {
    for ([_][]const u8{ "url", "path", "slug", "content", "toc" }) |k| {
        if (std.mem.eql(u8, key, k)) return true;
    }
    return false;
}

const convert = data_files.fromFrontmatter;

/// Renders `p` into `p.output`. A page with `paginate: N` in its
/// frontmatter is rendered once per N posts: page 1 at its own URL and page
/// k at `<url>page/k/`, each with a `paginator` variable.
fn renderPaginated(b: *Builder, p: *Page, posts: []const Value) Error!void {
    p.extra_outputs = &.{};
    const field = p.fields.get("paginate") orelse {
        p.output = try renderPage(b, p);
        return;
    };
    if (field != .int or field.int < 1) return b.fail(p.source, 0, "'paginate' must be a positive number of posts per page", .{});
    if (!std.mem.endsWith(u8, p.out_path, "index.html") or !std.mem.endsWith(u8, p.url, "/")) {
        return b.fail(p.source, 0, "a paginated page must have a URL ending in '/'", .{});
    }
    const arena = b.arena;
    const per: usize = @intCast(field.int);
    const total_pages = @max(1, (posts.len + per - 1) / per);
    const dir_out = p.out_path[0 .. p.out_path.len - "index.html".len];

    var extra: std.ArrayList(Output) = .empty;
    defer b.paginator = null;
    for (1..total_pages + 1) |k| {
        const first = (k - 1) * per;
        const slice = posts[@min(first, posts.len)..@min(first + per, posts.len)];
        const entries = try arena.alloc(Entry, 7);
        entries[0] = .{ .key = "posts", .value = .{ .list = slice } };
        entries[1] = .{ .key = "page", .value = .{ .int = @intCast(k) } };
        entries[2] = .{ .key = "per_page", .value = .{ .int = @intCast(per) } };
        entries[3] = .{ .key = "total_pages", .value = .{ .int = @intCast(total_pages) } };
        entries[4] = .{ .key = "total_posts", .value = .{ .int = @intCast(posts.len) } };
        entries[5] = .{ .key = "previous_url", .value = .{ .string = if (k > 1) try pageUrl(arena, p.url, k - 1) else "" } };
        entries[6] = .{ .key = "next_url", .value = .{ .string = if (k < total_pages) try pageUrl(arena, p.url, k + 1) else "" } };
        b.paginator = .{ .entries = entries };
        // The paginator lists posts, so this page changes when any post does.
        b.reads_collections = true;
        const html = try renderPage(b, p);
        if (k == 1) {
            p.output = html;
        } else {
            const path = try std.fmt.allocPrint(arena, "{s}page/{d}/index.html", .{ dir_out, k });
            try extra.append(arena, .{ .path = path, .source = p.source, .data = .{ .bytes = html } });
        }
    }
    p.extra_outputs = extra.items;
}

/// URL of page `k` of a paginated page at `base` (which ends in `/`).
fn pageUrl(arena: Allocator, base: []const u8, k: usize) Allocator.Error![]const u8 {
    if (k == 1) return base;
    return std.fmt.allocPrint(arena, "{s}page/{d}/", .{ base, k });
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
    var entries: [4]Entry = undefined;
    var n: usize = 0;
    entries[n] = .{ .key = "site", .value = .{ .object = b.site } };
    n += 1;
    entries[n] = .{ .key = "page", .value = .{ .object = p.object } };
    n += 1;
    if (content) |c| {
        entries[n] = .{ .key = "content", .value = .{ .html = c } };
        n += 1;
    }
    if (b.paginator) |pg| {
        entries[n] = .{ .key = "paginator", .value = .{ .object = pg } };
        n += 1;
    }
    const root: template.Object = .{ .entries = entries[0..n] };
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

/// Fails when two outputs differ only in letter case. They would overwrite
/// each other on the case-insensitive file systems Windows and macOS use by
/// default, so a site that builds on Linux would break there.
fn checkCaseCollisions(b: *Builder, outputs: []const Output) Error!void {
    const Item = struct { folded: []const u8, out: Output };
    const items = try b.arena.alloc(Item, outputs.len);
    for (outputs, items) |o, *it| it.* = .{ .folded = try std.ascii.allocLowerString(b.arena, o.path), .out = o };
    std.mem.sortUnstable(Item, items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return std.mem.lessThan(u8, x.folded, y.folded);
        }
    }.lt);
    for (items[0..items.len -| 1], items[@min(1, items.len)..]) |x, y| {
        if (std.mem.eql(u8, x.folded, y.folded)) {
            return b.fail(y.out.source, 0, "output '{s}' differs from '{s}' (from '{s}') only in letter case; they would overwrite each other on Windows and macOS", .{ y.out.path, x.out.path, x.out.source });
        }
    }
}

/// Hidden directory inside the site where `writeOutputDir` stages output.
pub const staging_dir = ".mortise-staging";

/// Writes the site to `_site` inside `src` so that a failure never leaves
/// a half-written `_site`: everything is written to a hidden staging
/// directory first, which replaces `_site` only once every file is in it.
pub fn writeOutputDir(site: Site, src: SiteDir, diag: *Diagnostic) error{BuildFailed}!void {
    src.deleteTree(staging_dir) catch |err| return ioFail(diag, staging_dir, err);
    {
        var stage = src.openSub(staging_dir) catch |err| return ioFail(diag, staging_dir, err);
        defer stage.close();
        writeSite(site, src, stage, diag) catch |err| {
            src.deleteTree(staging_dir) catch {};
            return err;
        };
    }
    src.deleteTree(output_dir) catch |err| return ioFail(diag, output_dir, err);
    src.dir.rename(staging_dir, src.dir, output_dir, src.io) catch |err| return ioFail(diag, output_dir, err);
}

fn ioFail(diag: *Diagnostic, path: []const u8, err: anyerror) error{BuildFailed} {
    diag.* = .{ .path = path, .message = @errorName(err) };
    return error.BuildFailed;
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
    try testing.expectEqualStrings("<h1 id=\"about-me\">About <em>me</em></h1>\n", site.find("about/index.html").?.data.bytes);
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

test "drafts are published only when asked" {
    var t: TestSite = try .init(&.{
        .{ "_posts/2024-01-01-a.md", "---\ndraft: true\n---\nA\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    try testing.expectEqual(@as(usize, 0), (try t.build(&diag)).posts);
    const with = try buildWith(t.arena.allocator(), SiteDir.borrow(testing.io, t.tmp.dir), .{ .drafts = true }, &diag);
    try testing.expectEqual(@as(usize, 1), with.posts);
}

test "a tag layout generates one page per tag" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/tag.html", "<h1>{{ page.tag }}</h1>{% for p in page.posts %}[{{ p.slug }}]{% endfor %}" },
        .{ "index.html", "---\nx: 1\n---\n{% for t in site.tags %}<a href=\"{{ t.url }}\">{{ t.name }}</a>{% endfor %}" },
        .{ "_posts/2024-01-01-a.md", "---\ntags: [Zig Lang, web]\n---\nA\n" },
        .{ "_posts/2024-01-02-b.md", "---\ntags: web\n---\nB\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = try t.build(&diag);
    try testing.expectEqualStrings("<h1>Zig Lang</h1>[a]", site.find("tags/zig-lang/index.html").?.data.bytes);
    try testing.expectEqualStrings("<h1>web</h1>[b][a]", site.find("tags/web/index.html").?.data.bytes);
    try testing.expectEqualStrings("<a href=\"/tags/zig-lang/\">Zig Lang</a><a href=\"/tags/web/\">web</a>", site.find("index.html").?.data.bytes);

    // Tag pages follow incremental rebuilds.
    try src.writeFile("_posts/2024-01-02-b.md", "---\ntags: [web, zig lang]\n---\nB\n");
    site = rebuild(t.arena.allocator(), src, &site, &.{"_posts/2024-01-02-b.md"}, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    // "zig lang" and "Zig Lang" are one tag, named as in the newest post.
    try testing.expectEqualStrings("<h1>zig lang</h1>[b][a]", site.find("tags/zig-lang/index.html").?.data.bytes);
}

test "page.toc lists level 2 and 3 headings" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/l.html", "{{ page.toc }}" },
        .{ "a.md", "---\nlayout: l\n---\n# Title\n## One\n### One A\n### One B\n## Two\n#### Deep\n" },
        .{ "b.md", "---\nlayout: l\n---\nNo headings.\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expectEqualStrings(
        "<ul class=\"toc\">\n<li><a href=\"#one\">One</a>\n<ul>\n<li><a href=\"#one-a\">One A</a></li>\n<li><a href=\"#one-b\">One B</a></li>\n</ul>\n</li>\n<li><a href=\"#two\">Two</a></li>\n</ul>\n",
        site.find("a/index.html").?.data.bytes,
    );
    try testing.expectEqualStrings("", site.find("b/index.html").?.data.bytes);
}

test "excerpts and tags" {
    var t: TestSite = try .init(&.{
        .{ "index.html", "---\nx: 1\n---\n{% for t in site.tags %}[{{ t.name }}:{% for p in t.posts %}{{ p.slug }}{% endfor %}]{% endfor %}{% for p in site.posts %}({{ p.excerpt }}){% endfor %}" },
        .{ "_posts/2024-01-01-a.md", "---\ntags: [zig, web]\n---\n# Title\n\nFirst *para*.\n\nSecond.\n" },
        .{ "_posts/2024-01-02-b.md", "---\ntags: zig\nexcerpt: Custom.\n---\nBody.\n" },
        .{ "_posts/2024-01-03-c.md", "No tags.\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expectEqualStrings(
        "[web:a][zig:ba](<p>No tags.</p>)(Custom.)(<p>First <em>para</em>.</p>)",
        site.find("index.html").?.data.bytes,
    );
}

test "a page with paginate is split across pages of posts" {
    var t: TestSite = try .init(&.{
        .{ "index.html", "---\npaginate: 2\n---\n{{ paginator.page }}/{{ paginator.total_pages }}:{% for p in paginator.posts %}{{ p.slug }}{% endfor %} <{{ paginator.previous_url }}|{{ paginator.next_url }}>" },
        .{ "_posts/2024-01-01-a.md", "A\n" },
        .{ "_posts/2024-01-02-b.md", "B\n" },
        .{ "_posts/2024-01-03-c.md", "C\n" },
        .{ "_posts/2024-01-04-d.md", "D\n" },
        .{ "_posts/2024-01-05-e.md", "E\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = try t.build(&diag);
    try testing.expectEqualStrings("1/3:ed <|/page/2/>", site.find("index.html").?.data.bytes);
    try testing.expectEqualStrings("2/3:cb </|/page/3/>", site.find("page/2/index.html").?.data.bytes);
    try testing.expectEqualStrings("3/3:a </page/2/|>", site.find("page/3/index.html").?.data.bytes);

    // Editing a post re-renders every page of the paginated page.
    try src.writeFile("_posts/2024-01-01-a.md", "A2\n");
    site = try rebuild(t.arena.allocator(), src, &site, &.{"_posts/2024-01-01-a.md"}, &diag);
    try testing.expect(!site.full);
    try testing.expect(site.find("page/3/index.html") != null);

    try expectBuildError(&.{.{ "x.html", "---\npaginate: 0\n---\n" }}, "x.html", 0, "'paginate' must be");
    try expectBuildError(&.{.{ "feed.html", "---\npaginate: 2\npermalink: /feed.xml\n---\n" }}, "feed.html", 0, "URL ending in '/'");
}

test "data files are available as site.data" {
    var t: TestSite = try .init(&.{
        .{ "_data/nav.json", "[{\"title\": \"Home\", \"url\": \"/\"}, {\"title\": \"About\", \"url\": \"/about/\"}]" },
        .{ "_data/team/lead.yml", "name: Ada\n" },
        .{ "index.html", "---\nx: 1\n---\n{% for n in site.data.nav %}<a href=\"{{ n.url }}\">{{ n.title }}</a>{% endfor %} {{ site.data.team.lead.name }}" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = try t.build(&diag);
    try testing.expectEqualStrings("<a href=\"/\">Home</a><a href=\"/about/\">About</a> Ada", site.find("index.html").?.data.bytes);

    // Editing a data file rebuilds everything that might read it.
    try src.writeFile("_data/team/lead.yml", "name: Grace\n");
    site = try rebuild(t.arena.allocator(), src, &site, &.{"_data/team/lead.yml"}, &diag);
    try testing.expect(site.full);
    try testing.expect(std.mem.endsWith(u8, site.find("index.html").?.data.bytes, " Grace"));

    try expectBuildError(&.{.{ "_data/a.json", "{\n\"a\": 1,\n}" }}, "_data/a.json", 3, "invalid JSON");
    try expectBuildError(&.{ .{ "_data/a.json", "1" }, .{ "_data/a.yml", "b: 1\n" } }, "_data/a.yml", 0, "clashes");
    try expectBuildError(&.{.{ "_config.yml", "data: 1\n" }}, "_config.yml", 0, "set by Mortise");
}

test "outputs that differ only in case are rejected" {
    var t: TestSite = try .init(&.{
        .{ "about.md", "---\npermalink: /About/\n---\n" },
        .{ "docs.md", "---\npermalink: /about/\n---\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.BuildFailed, t.build(&diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "only in letter case") != null);
}

test "writeOutputDir replaces _site only after a complete write" {
    var t: TestSite = try .init(&.{
        .{ "index.md", "new\n" },
        .{ "_site/stale.html", "old" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try writeOutputDir(site, src, &diag);
    const a = t.arena.allocator();
    try testing.expectEqualStrings("<p>new</p>\n", try src.readFile(a, "_site/index.html"));
    try testing.expectError(error.FileNotFound, src.readFile(a, "_site/stale.html"));
    try testing.expectError(error.FileNotFound, src.readFile(a, staging_dir ++ "/index.html"));
}

test "feed and sitemap are generated when the site has a url" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: T\nurl: https://example.com/\n" },
        .{ "about.md", "---\ntitle: About\n---\nA\n" },
        .{ "hidden.md", "---\nsitemap: false\n---\nH\n" },
        .{ "_posts/2024-01-05-a.md", "---\ntitle: A\n---\nA\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const feed = site.find("feed.xml").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, feed, "<link href=\"https://example.com/2024/01/05/a/\"/>") != null);
    const map = site.find("sitemap.xml").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, map, "<loc>https://example.com/about/</loc>") != null);
    try testing.expect(std.mem.indexOf(u8, map, "hidden") == null);

    // No url, no generated files; switches turn them off; a site's own
    // file at the same path wins.
    var t2: TestSite = try .init(&.{.{ "_posts/2024-01-05-a.md", "A\n" }});
    defer t2.deinit();
    const s2 = try t2.build(&diag);
    try testing.expect(s2.find("feed.xml") == null and s2.find("sitemap.xml") == null);

    var t3: TestSite = try .init(&.{
        .{ "_config.yml", "url: https://example.com\nfeed: false\n" },
        .{ "_posts/2024-01-05-a.md", "A\n" },
        .{ "sitemap.xml", "<mine/>" },
    });
    defer t3.deinit();
    const s3 = try t3.build(&diag);
    try testing.expect(s3.find("feed.xml") == null);
    try testing.expect(s3.find("sitemap.xml").?.data == .copy);

    try expectBuildError(&.{.{ "_config.yml", "url: example.com\n" }}, "_config.yml", 0, "'url' must be an absolute URL");
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
