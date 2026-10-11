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
const gzip = @import("gzip.zig");
const search = @import("search.zig");
const data_files = @import("data.zig");
const openapi = @import("openapi.zig");
const themes = @import("themes.zig");
const tokens = @import("tokens.zig");
const icons = @import("icons.zig");
const assets = @import("assets.zig");
const redirects = @import("redirects.zig");
const git = @import("git.zig");
const seo = @import("seo.zig");
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
    /// Pages and posts left out of this build, by reason.
    skipped: Skipped = .{},
    /// Problems that do not stop the build, such as low color contrast.
    warnings: []const Diagnostic = &.{},
    /// `gzip: true` in the config: writing the site also writes `.gz`
    /// copies of text files (see gzip.zig).
    gzip: bool = false,
    /// What `rebuild` needs to update this site. An incrementally rebuilt
    /// site shares memory with the site it came from, so that site's
    /// arena must outlive this one.
    state: State,

    /// Whether `path` is a file in `src` that this site did not read: a new
    /// page or file, or an editor's temporary file. Templates, data files
    /// and the config count as read.
    pub fn isNewFile(s: Site, src: SiteDir, path: []const u8) bool {
        if (std.mem.eql(u8, path, config_path)) return false;
        for ([_][]const u8{ "_layouts/", "_includes/", data_files.dir_prefix, assets.dir_prefix }) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return false;
        }
        for (s.outputs) |o| if (std.mem.eql(u8, o.source, path)) return false;
        src.dir.access(src.io, path, .{}) catch return false;
        return true;
    }

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

pub const Skipped = struct {
    /// `draft: true`, without `--drafts`.
    drafts: usize = 0,
    /// Posts dated after today, without `--future`.
    future: usize = 0,
    /// Pages and posts whose `expires` date has come.
    expired: usize = 0,

    pub fn total(s: Skipped) usize {
        return s.drafts + s.future + s.expired;
    }

    /// `2 drafts, 1 future post` and so on, leaving out zero counts.
    pub fn format(s: Skipped, w: *Writer) Writer.Error!void {
        var first = true;
        const parts = [_]struct { usize, []const u8, []const u8 }{
            .{ s.drafts, "draft", "drafts" },
            .{ s.future, "future post", "future posts" },
            .{ s.expired, "expired page", "expired pages" },
        };
        for (parts) |p| {
            if (p[0] == 0) continue;
            if (!first) try w.writeAll(", ");
            first = false;
            try w.print("{d} {s}", .{ p[0], if (p[0] == 1) p[1] else p[2] });
        }
    }
};

const State = struct {
    skipped: Skipped,
    config_fields: frontmatter.Map,
    baseurl: []const u8,
    site_url: ?[]const u8,
    options: Options,
    data: Value,
    history: History,
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
    /// Whether the Markdown uses a component that needs `mortise.css`.
    uses_components: bool = false,
    /// For an OpenAPI page, the rendered reference (for `site.apis`).
    api: ?openapi.Rendered = null,
    /// The page's own fields, without navigation; computed once per load.
    base: template.Object = .{},
    /// `base` plus `breadcrumbs`, `previous`, and `next`, recomputed by
    /// every build because they depend on other pages.
    object: template.Object = .{},
    /// Set once rendered: the output and what it depended on.
    output: []const u8 = "",
    /// Pages 2 and up of a paginated page.
    extra_outputs: []const Output = &.{},
    /// Old URLs from frontmatter `aliases`, without the baseurl, each
    /// with the output path of its redirect page.
    aliases: []const AliasPath = &.{},
    /// `YYYY-MM-DD` of the last change, from frontmatter `updated`, else
    /// from Git history with `git_dates: true`, or "".
    updated: []const u8 = "",
    /// Files the Markdown includes with `<<< path`.
    included_files: []const []const u8 = &.{},
    /// The page's `edit_url` from the config, with `{path}` filled in.
    edit_url: []const u8 = "",
    sources: []const []const u8 = &.{},
    reads_collections: bool = false,
    /// Whether the page's templates output `seo`, so it gets a card.
    uses_seo: bool = false,
    /// The page's search sections, kept from the render that produced
    /// `output` (see search.zig).
    search_sections: []const search.Section = &.{},
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
    /// Pages and posts left out so far.
    skipped: Skipped = .{},
    /// Publish posts dated after `options.today`.
    future: bool = false,
    /// Whether a template used by the current page reads `seo`.
    reads_seo: bool = false,
    seo_config: SeoConfig = .{},
    /// The `seo` head tags of the page being rendered.
    current_seo: []const u8 = "",
    /// The URL of the page being rendered when it differs from the
    /// page's own: page 2 and up of a paginated page.
    page_url: ?[]const u8 = null,
    baseurl: []const u8 = "",
    /// Absolute site URL from `url` in the config, needed for the feed and
    /// sitemap; null when unset.
    site_url: ?[]const u8 = null,
    options: Options = .{},
    /// Heading anchors and copy buttons, from `_config.yml`.
    markdown_options: markdown.Options = .{},
    history: History = .{},
    /// `site.data`, from the files in `_data/`.
    data: Value = .{ .object = .{} },
    /// The `paginator` variable while rendering one page of a paginated
    /// page, or null.
    paginator: ?template.Object = null,
    /// Whether templates fail on undefined variables.
    strict: bool = false,
    /// The site's design tokens, or null without a theme or theme_tokens.
    token_set: ?tokens.Set = null,
    warnings: std.ArrayList(Diagnostic) = .empty,

    fn fail(b: *Builder, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) Error {
        b.diag.* = .{
            .path = path,
            .line = line,
            .message = std.fmt.allocPrint(b.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.BuildFailed;
    }

    fn warn(b: *Builder, path: []const u8, line: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try b.warnings.append(b.arena, .{ .path = path, .line = line, .message = try std.fmt.allocPrint(b.arena, fmt, args) });
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
        b.reads_seo = b.reads_seo or tpl.reads_seo;
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
    /// Keeps rendered assets between builds. Without one, every build
    /// renders them again, which suits one-off builds.
    render_cache: ?*assets.Cache = null,
    /// Fail on undefined template variables (`--strict`). Null leaves it
    /// to `strict:` in `_config.yml`, then to `strict_by_default`.
    strict: ?bool = null,
    /// Strict mode when neither the options nor the config say: on in
    /// `serve`, where a typo should show up at once, off in `build`.
    strict_by_default: bool = false,
    /// Today's date as `YYYY-MM-DD`, for scheduled and expiring posts.
    /// When empty, nothing is left out for its date.
    today: []const u8 = "",
    /// Publish posts dated after `today` (`--future`, or `future: true`
    /// in `_config.yml`).
    future: bool = false,
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
    b.markdown_options = try markdownOptions(&b, config_fields);
    b.future = try showFuture(&b, config_fields);
    b.history = try loadHistory(&b, config_fields, listing.files);
    b.data = try loadData(&b, listing.files);

    for (listing.files) |path| {
        if (std.mem.eql(u8, path, config_path)) continue;
        if (std.mem.startsWith(u8, path, "_posts/")) {
            if (!std.mem.eql(u8, sitepath.extension(path), ".md")) continue;
            if (try loadPage(&b, path, true)) |p| try pages.append(arena, p);
            continue;
        }
        if (openapi.isSpec(path)) {
            try pages.append(arena, try loadApiPage(&b, path));
            continue;
        }
        if (assets.isSpec(path)) {
            try addRendered(&b, &statics, path, assets.outputStem(path), try b.read(path));
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
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag, .baseurl = st.baseurl, .site_url = st.site_url, .data = st.data, .options = st.options, .skipped = st.skipped, .history = st.history };
    b.markdown_options = try markdownOptions(&b, st.config_fields);
    b.future = try showFuture(&b, st.config_fields);

    var dirty_templates: std.ArrayList([]const u8) = .empty;
    var dirty_pages: std.ArrayList(usize) = .empty;
    for (changed) |path| {
        // The config and data files feed `site`, which any page may read.
        // Render specs are cheap to rebuild from scratch thanks to the
        // render cache, which keeps every unchanged asset.
        if (std.mem.eql(u8, path, config_path) or std.mem.eql(u8, path, "*") or
            std.mem.startsWith(u8, path, data_files.dir_prefix) or
            std.mem.startsWith(u8, path, assets.dir_prefix)) return buildWith(arena, src, st.options, diag);
        // Pages that include the file with `<<<` load again; the file's
        // own role, if any, is handled below.
        for (st.pages, 0..) |p, i| {
            for (p.included_files) |f| {
                if (std.mem.eql(u8, f, path) and std.mem.indexOfScalar(usize, dirty_pages.items, i) == null) try dirty_pages.append(arena, i);
            }
        }
        if (std.mem.startsWith(u8, path, "_layouts/") or std.mem.startsWith(u8, path, "_includes/")) {
            try dirty_templates.append(arena, path);
            continue;
        }
        if (findPage(st.pages, path)) |i| {
            if (!b.exists(path)) return buildWith(arena, src, st.options, diag);
            if (std.mem.indexOfScalar(usize, dirty_pages.items, i) == null) try dirty_pages.append(arena, i);
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
        // A new API spec adds a page.
        if (openapi.isSpec(path)) return buildWith(arena, src, st.options, diag);
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

/// Whether to publish future-dated posts: `--future`, or `future: true`.
fn showFuture(b: *Builder, config_fields: frontmatter.Map) Error!bool {
    if (b.options.future) return true;
    const v = config_fields.get("future") orelse return false;
    if (v != .boolean) return b.fail(config_path, 0, "'future' must be true or false", .{});
    return v.boolean;
}

/// What the site's Git repository says about its pages.
const History = struct {
    /// Source path to `YYYY-MM-DD` of its last commit, with
    /// `git_dates: true`.
    dates: std.StringHashMapUnmanaged([10]u8) = .empty,
    /// The site directory's path inside the repository.
    prefix: []const u8 = "",
    /// `edit_url` from the config, with `{path}` to fill in.
    edit_url: ?[]const u8 = null,
};

/// Reads `git_dates` and `edit_url`, and with `git_dates: true` the last
/// commit date of every page in the repository holding the site. A site
/// outside any repository gets no dates.
fn loadHistory(b: *Builder, config_fields: frontmatter.Map, files: []const []const u8) Error!History {
    var h: History = .{};
    if (config_fields.get("edit_url")) |v| {
        if (v != .string or std.mem.indexOf(u8, v.string, "{path}") == null) {
            return b.fail(config_path, 0, "'edit_url' must be a URL containing {{path}}, such as https://github.com/me/site/edit/main/{{path}}", .{});
        }
        h.edit_url = v.string;
    }
    const want_dates = if (config_fields.get("git_dates")) |v| blk: {
        if (v != .boolean) return b.fail(config_path, 0, "'git_dates' must be true or false", .{});
        break :blk v.boolean;
    } else false;
    if (!want_dates and h.edit_url == null) return h;

    const io = b.src.io;
    const abs = b.src.dir.realPathFileAlloc(io, ".", b.arena) catch return h;
    var found = (git.discover(b.arena, io, abs) catch |err| return gitFail(b, err)) orelse return h;
    defer found.repo.close();
    h.prefix = found.prefix;
    if (!want_dates) return h;

    var wanted: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        const ext = sitepath.extension(f);
        if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".html")) try wanted.append(b.arena, f);
    }
    h.dates = git.lastChanged(&found.repo, found.prefix, .{ .wanted = wanted.items }) catch |err| return gitFail(b, err);
    return h;
}

fn gitFail(b: *Builder, err: git.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => b.fail(config_path, 0, "cannot read the Git history for git_dates: {s}; set git_dates: false to build without it", .{@errorName(err)}),
    };
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

/// Path of the built-in component stylesheet in the output.
pub const components_css_path = "mortise.css";

/// Writes the component stylesheet when any page uses a component, unless
/// the config sets `components_css: false` or the site has its own file
/// at that path.
fn addComponentsCss(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map, pages: []const Page) Error!void {
    const used = for (pages) |p| {
        if (p.uses_components) break true;
    } else false;
    if (!used or !try enabled(b, config_fields, "components_css") or hasOutput(outputs.items, components_css_path)) return;
    try outputs.append(b.arena, .{ .path = components_css_path, .source = config_path, .data = .{ .bytes = markdown.components_css } });
}

/// Writes `/theme.css`: the design tokens, then the stylesheet of the
/// theme named by `theme:` in the config, unless the site has its own
/// file at that path.
fn addThemeCss(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map) Error!void {
    const set = b.token_set orelse return;
    const theme = try configTheme(b, config_fields);
    if (theme) |t| try addThemeAssets(b, outputs, t, fieldLine(try b.read(config_path), "theme"));
    if (hasOutput(outputs.items, themes.css_path)) return;
    const token_css = try tokens.css(b.arena, set);
    const css = if (theme) |t| try insertAfterImports(b.arena, t.css, token_css) else token_css;
    try outputs.append(b.arena, .{ .path = themes.css_path, .source = config_path, .data = .{ .bytes = css } });
}

/// The theme named by `theme:`, or null when there is none.
fn configTheme(b: *Builder, config_fields: frontmatter.Map) Error!?themes.Theme {
    const v = config_fields.get("theme") orelse return null;
    const line = fieldLine(try b.read(config_path), "theme");
    if (v != .string) return b.fail(config_path, line, "'theme' must be the name of a theme: {s}", .{themes.names});
    return themes.find(v.string) orelse
        b.fail(config_path, line, "unknown theme '{s}'; the themes are: {s}", .{ v.string, themes.names });
}

/// The design tokens of the theme, with `theme_tokens:` from the config
/// applied, or null for a site with neither. Warns about low contrast.
fn tokenSet(b: *Builder, config_fields: frontmatter.Map) Error!?tokens.Set {
    const theme = try configTheme(b, config_fields);
    const overrides = config_fields.get("theme_tokens");
    if (theme == null and overrides == null) return null;
    var d: tokens.Diagnostic = .{};
    var set: tokens.Set = .{ .scheme = .both, .tokens = &.{} };
    if (theme) |t| {
        var fd: frontmatter.Diagnostic = .{};
        const fields = frontmatter.parseFile(b.arena, t.tokens, &fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFrontmatter => return b.fail(config_path, 0, "theme '{s}' has broken tokens: line {d}: {s}", .{ t.name, fd.line, fd.message }),
        };
        set = tokens.parse(b.arena, fields, &d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTokens => return b.fail(config_path, 0, "theme '{s}' has a broken token '{s}': {s}", .{ t.name, d.key, d.message }),
        };
    }
    if (overrides) |o| {
        const data = try b.read(config_path);
        if (o != .map) return b.fail(config_path, fieldLine(data, "theme_tokens"), "'theme_tokens' must be a map of token names to colors", .{});
        set = tokens.override(b.arena, set, o.map, &d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTokens => return b.fail(config_path, nestedLine(data, "theme_tokens", d.key), "theme_tokens: '{s}' {s}", .{ d.key, d.message }),
        };
    }
    const line = fieldLine(try b.read(config_path), if (overrides != null) "theme_tokens" else "theme");
    for (try tokens.check(b.arena, set)) |f| {
        try b.warn(config_path, line, "low contrast: '{s}' on '{s}' is {d:.2}:1 in the {s} scheme; WCAG asks for {d}:1", .{ f.fg, f.bg, f.ratio, f.scheme, f.needed });
    }
    return set;
}

/// The line of `key` indented under the top-level `parent` key.
fn nestedLine(data: []const u8, parent: []const u8, key: []const u8) usize {
    const start = fieldLine(data, parent);
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: usize = 0;
    while (it.next()) |l| {
        n += 1;
        if (n <= start) continue;
        const t = std.mem.trimStart(u8, l, " ");
        if (t.len == l.len and t.len > 0) break; // the next top-level key
        if (std.mem.startsWith(u8, t, key) and t.len > key.len and t[key.len] == ':') return n;
    }
    return start;
}

/// `css` with `insert` placed after its leading `@import` rules, which
/// must come first in a stylesheet.
fn insertAfterImports(arena: Allocator, css: []const u8, insert: []const u8) Allocator.Error![]const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < css.len) {
        // Skip whitespace and comments.
        if (std.ascii.isWhitespace(css[i])) {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, css[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, css, i + 2, "*/")) |e| e + 2 else css.len;
            continue;
        }
        if (!std.mem.startsWith(u8, css[i..], "@import")) break;
        i = if (std.mem.indexOfScalarPos(u8, css, i, ';')) |e| e + 1 else css.len;
        pos = i;
    }
    if (pos > 0 and pos < css.len and css[pos] == '\n') pos += 1;
    return std.mem.concat(arena, u8, &.{ css[0..pos], if (pos > 0) "\n" else "", insert, "\n", css[pos..] });
}

/// Renders a theme's images into `/theme/`, except those the site
/// replaces with its own file.
fn addThemeAssets(b: *Builder, outputs: *std.ArrayList(Output), theme: themes.Theme, line: usize) Error!void {
    for (theme.assets) |a| {
        const name = try std.fmt.allocPrint(b.arena, "{s}/{s}", .{ themes.assets_dir, a.name });
        const png = try std.fmt.allocPrint(b.arena, "{s}.png", .{name});
        if (hasOutput(outputs.items, png)) continue;
        var d: assets.Diagnostic = .{};
        const out = assets.renderCached(b.options.render_cache, b.arena, b.src.io, name, a.spec, &d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSpec => return b.fail(config_path, line, "theme '{s}', asset '{s}', line {d}: {s}", .{ theme.name, a.name, d.line, d.message }),
        };
        try appendRendered(b, outputs, config_path, name, out);
    }
}

/// Site-wide settings for `{{ seo }}` and social cards.
const SeoConfig = struct {
    site_title: []const u8 = "",
    description: []const u8 = "",
    author: []const u8 = "",
    twitter: []const u8 = "",
    /// Draw a card for pages that output `seo` and set no `image`.
    cards: bool = true,
    card_style: []const u8 = "plain",
};

/// The directory social cards are written to.
pub const cards_dir = "social";

fn seoConfig(b: *Builder, config_fields: frontmatter.Map) Error!SeoConfig {
    var c: SeoConfig = .{
        .site_title = stringField(config_fields, "title") orelse "",
        .description = stringField(config_fields, "description") orelse "",
        .author = stringField(config_fields, "author") orelse "",
        .cards = try enabled(b, config_fields, "social_cards"),
    };
    if (stringField(config_fields, "twitter")) |t| {
        c.twitter = if (t.len > 0 and t[0] != '@') try std.mem.concat(b.arena, u8, &.{ "@", t }) else t;
    }
    // Cards match the theme when it has a card style of its own.
    if (stringField(config_fields, "theme")) |t| {
        if (std.meta.stringToEnum(@import("render").card.Style, t) != null) c.card_style = t;
    }
    if (config_fields.get("social_card_style")) |v| {
        if (v != .string or std.meta.stringToEnum(@import("render").card.Style, v.string) == null) {
            return b.fail(config_path, fieldLine(try b.read(config_path), "social_card_style"), "'social_card_style' must be plain, visor or lcars", .{});
        }
        c.card_style = v.string;
    }
    return c;
}

/// Whether `p` gets a generated social card.
fn hasCard(b: *const Builder, p: *const Page) bool {
    if (!b.seo_config.cards or p.fields.get("image") != null) return false;
    if (p.fields.get("card")) |v| if (v == .boolean and !v.boolean) return false;
    return !std.mem.eql(u8, p.out_path, "404.html");
}

/// `social/docs/install.png` for `docs/install/index.html`.
fn cardPath(arena: Allocator, out_path: []const u8) Allocator.Error![]const u8 {
    var stem = out_path;
    if (std.mem.endsWith(u8, stem, "/index.html")) {
        stem = stem[0 .. stem.len - "/index.html".len];
    } else if (std.mem.endsWith(u8, stem, ".html")) {
        stem = stem[0 .. stem.len - ".html".len];
    }
    if (std.mem.eql(u8, stem, "index.html") or stem.len == 0) stem = "index";
    return std.fmt.allocPrint(arena, "{s}/{s}.png", .{ cards_dir, stem });
}

/// The `seo` head tags for `p`.
fn seoFor(b: *Builder, p: *const Page) Error![]const u8 {
    const arena = b.arena;
    const c = b.seo_config;
    var description = stringField(p.fields, "description") orelse "";
    if (description.len == 0) {
        if (p.html) |h| description = try seo.summarize(arena, firstParagraph(h) orelse h, 160);
    }
    if (description.len == 0) description = c.description;
    var image: []const u8 = "";
    var image_size: ?[2]u32 = null;
    if (stringField(p.fields, "image")) |img| {
        image = if (img.len > 0 and img[0] != '/' and std.mem.indexOf(u8, img, "://") == null)
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.baseurl, img })
        else
            img;
    } else if (hasCard(b, p)) {
        image = try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.baseurl, try cardPath(arena, p.out_path) });
        image_size = .{ 1200, 630 };
    }
    var crumbs: std.ArrayList(seo.Crumb) = .empty;
    if (p.object.get("breadcrumbs")) |bc| if (bc == .list) for (bc.list) |item| {
        if (item != .object) continue;
        const t = item.object.get("title") orelse continue;
        const u = item.object.get("url") orelse continue;
        if (t != .string or u != .string) continue;
        try crumbs.append(arena, .{ .title = t.string, .url = u.string });
    };
    const updated = if (p.object.get("updated")) |v| (if (v == .string) v.string else "") else "";
    const title = stringField(p.fields, "title") orelse "";
    return seo.head(arena, .{
        .site_title = c.site_title,
        .site_url = b.site_url,
        .url = b.page_url orelse p.url,
        .title = title,
        .description = description,
        .is_post = p.is_post,
        .is_home = std.mem.eql(u8, p.out_path, "index.html") and b.page_url == null,
        .published = p.date,
        .modified = if (template.parseDate(updated) != null) updated[0..10] else "",
        .author = stringField(p.fields, "author") orelse c.author,
        .image = image,
        .image_alt = stringField(p.fields, "image_alt") orelse title,
        .image_size = image_size,
        .twitter = c.twitter,
        .breadcrumbs = crumbs.items,
    });
}

/// Draws a social card for every page that outputs `seo` and has no
/// `image` of its own.
fn addCards(b: *Builder, outputs: *std.ArrayList(Output), pages: []const Page) Error!void {
    const arena = b.arena;
    var jobs: std.ArrayList(assets.Job) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    for (pages) |*p| {
        if (!p.uses_seo or !hasCard(b, p)) continue;
        const path = try cardPath(arena, p.out_path);
        if (hasOutput(outputs.items, path)) continue;
        const title = stringField(p.fields, "title") orelse navTitle(p);
        const label = if (p.is_post) p.date else if (b.site_url) |u| try std.mem.concat(arena, u8, &.{ hostOf(u), p.url }) else p.url;
        var spec: std.ArrayList(u8) = .empty;
        try spec.print(arena, "kind: card\nstyle: {s}\ntitle: ", .{b.seo_config.card_style});
        try yamlString(arena, &spec, title);
        try spec.appendSlice(arena, "\nsubtitle: ");
        try yamlString(arena, &spec, b.seo_config.site_title);
        try spec.appendSlice(arena, "\nlabel: ");
        try yamlString(arena, &spec, label);
        try spec.append(arena, '\n');
        try jobs.append(arena, .{ .name = path[0 .. path.len - ".png".len], .source = spec.items });
        try sources.append(arena, p.source);
    }
    // Cards are independent, so they render concurrently.
    assets.renderMany(b.options.render_cache, arena, b.src.io, jobs.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => for (jobs.items, sources.items) |j, src| {
            if (j.diag.message.len > 0) return b.fail(src, 0, "cannot draw the social card: {s}", .{j.diag.message});
        } else return b.fail("", 0, "cannot draw a social card", .{}),
    };
    for (jobs.items, sources.items) |j, src| try appendRendered(b, outputs, src, j.name, j.result);
}

fn hostOf(url: []const u8) []const u8 {
    const rest = url[(std.mem.indexOf(u8, url, "://") orelse return url) + 3 ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
}

/// `s` as a double-quoted frontmatter string.
fn yamlString(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    try out.append(arena, '"');
    for (s) |c| switch (c) {
        '"', '\\' => {
            try out.append(arena, '\\');
            try out.append(arena, c);
        },
        '\n', '\r', '\t' => try out.append(arena, ' '),
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
}

/// Reads `icons:` from the config, or null when the site wants none.
fn iconConfig(b: *Builder, config_fields: frontmatter.Map) Error!?icons.Config {
    var d: icons.Diagnostic = .{};
    return icons.config(b.arena, config_fields.get("icons"), stringField(config_fields, "title") orelse "", stringField(config_fields, "theme"), &d) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidIcons => b.fail(config_path, fieldLine(try b.read(config_path), "icons"), "icons: '{s}' {s}", .{ d.key, d.message }),
    };
}

/// Draws the site icons and writes them with the web app manifest, except
/// files the site has itself.
fn addIcons(b: *Builder, outputs: *std.ArrayList(Output), c: icons.Config) Error!void {
    const arena = b.arena;
    if (!hasOutput(outputs.items, icons.ico_path)) {
        var images: [icons.ico_sizes.len]@import("render").icon.IcoImage = undefined;
        for (icons.ico_sizes, &images) |size, *im| {
            const name = try std.fmt.allocPrint(arena, "favicon-{d}", .{size});
            im.* = .{ .size = size, .png = (try renderIcon(b, name, try icons.spec(arena, c, size))).png };
        }
        const ico = try @import("render").icon.ico(arena, &images);
        try outputs.append(arena, .{ .path = icons.ico_path, .source = config_path, .data = .{ .bytes = ico } });
    }
    for (icons.pngs) |p| {
        if (hasOutput(outputs.items, p.path)) continue;
        const out = try renderIcon(b, p.path, try icons.spec(arena, c, p.size));
        try outputs.append(arena, .{ .path = p.path, .source = config_path, .data = .{ .bytes = out.png } });
    }
    if (!hasOutput(outputs.items, icons.manifest_path)) {
        try outputs.append(arena, .{ .path = icons.manifest_path, .source = config_path, .data = .{ .bytes = try icons.manifest(arena, c, b.baseurl) } });
    }
}

fn renderIcon(b: *Builder, name: []const u8, spec: []const u8) Error!assets.Rendered {
    var d: assets.Diagnostic = .{};
    return assets.renderCached(b.options.render_cache, b.arena, b.src.io, name, spec, &d) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSpec => b.fail(config_path, fieldLine(try b.read(config_path), "icons"), "cannot draw the site icon: {s}", .{d.message}),
    };
}

/// Renders the spec `spec` read from `source` into `NAME.png`, plus
/// `NAME.css` for kinds that need it.
fn addRendered(b: *Builder, outputs: *std.ArrayList(Output), source: []const u8, name: []const u8, spec: []const u8) Error!void {
    var d: assets.Diagnostic = .{};
    const out = assets.renderCached(b.options.render_cache, b.arena, b.src.io, name, spec, &d) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => return b.fail(source, d.line, "{s}", .{d.message}),
    };
    try appendRendered(b, outputs, source, name, out);
}

fn appendRendered(b: *Builder, outputs: *std.ArrayList(Output), source: []const u8, name: []const u8, out: assets.Rendered) Error!void {
    const png = try std.fmt.allocPrint(b.arena, "{s}.png", .{name});
    try outputs.append(b.arena, .{ .path = png, .source = source, .data = .{ .bytes = out.png } });
    if (out.css) |css| {
        const css_path = try std.fmt.allocPrint(b.arena, "{s}.css", .{name});
        try outputs.append(b.arena, .{ .path = css_path, .source = source, .data = .{ .bytes = css } });
    }
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
        if (p.is_post) {
            var feed_entry = entry;
            feed_entry.html = try withoutPageControls(arena, entry.html);
            try posts.append(arena, feed_entry);
        }
        const opted_out = if (p.fields.get("sitemap")) |v| v == .boolean and !v.boolean else false;
        if (!opted_out and !std.mem.eql(u8, p.out_path, "404.html")) {
            var listed_entry = entry;
            // The sitemap's lastmod is the last change, when known.
            if (p.updated.len > 0) listed_entry.date = p.updated;
            try listed.append(arena, listed_entry);
        }
    }
    if (try enabled(b, config_fields, "feed") and posts.items.len > 0 and !hasOutput(outputs.items, feeds.feed_path)) {
        try outputs.append(arena, .{ .path = feeds.feed_path, .source = config_path, .data = .{ .bytes = try feeds.atom(arena, site, posts.items) } });
    }
    const has_sitemap = try enabled(b, config_fields, "sitemap");
    if (has_sitemap and !hasOutput(outputs.items, feeds.sitemap_path)) {
        try outputs.append(arena, .{ .path = feeds.sitemap_path, .source = config_path, .data = .{ .bytes = try feeds.sitemap(arena, site, listed.items) } });
    }
    if (try enabled(b, config_fields, "robots") and !hasOutput(outputs.items, redirects.robots_path)) {
        const sitemap_url = if (has_sitemap) try std.fmt.allocPrint(arena, "{s}{s}/{s}", .{ url, b.baseurl, feeds.sitemap_path }) else null;
        try outputs.append(arena, .{ .path = redirects.robots_path, .source = config_path, .data = .{ .bytes = try redirects.robots(arena, sitemap_url) } });
    }
}

/// Renders the pages selected by `render` (all when null) and assembles the
/// site. `pages` must be in `pageOrder`.
fn finish(b: *Builder, config_fields: frontmatter.Map, pages: []Page, statics: []const Output, render: ?[]const bool) Error!Site {
    const arena = b.arena;
    b.strict = b.options.strict orelse blk: {
        const v = config_fields.get("strict") orelse break :blk b.options.strict_by_default;
        if (v != .boolean) return b.fail(config_path, 0, "'strict' must be true or false", .{});
        break :blk v.boolean;
    };

    // Pages and posts are visible to every template through `site`.
    var post_values: std.ArrayList(Value) = .empty;
    var page_values: std.ArrayList(Value) = .empty;
    var post_count: usize = 0;
    for (pages) |*p| {
        if (p.base.entries.len == 0) p.base = try pageObject(arena, p);
    }
    try addNavigation(arena, pages);
    for (pages) |*p| {
        if (p.is_post) {
            try post_values.append(arena, .{ .object = p.object });
            post_count += 1;
        } else {
            try page_values.append(arena, .{ .object = p.object });
        }
    }

    b.token_set = try tokenSet(b, config_fields);
    var site_entries: std.ArrayList(Entry) = .empty;
    // A light/dark switch, for token sets with both schemes.
    const toggle = if (b.token_set) |s| (if (s.scheme == .both) tokens.scheme_toggle_html else "") else "";
    try site_entries.append(arena, .{ .key = "scheme_toggle", .value = .{ .html = toggle } });
    for (config_fields.entries) |e| {
        if (std.mem.eql(u8, e.key, "posts") or std.mem.eql(u8, e.key, "pages") or
            std.mem.eql(u8, e.key, "data") or std.mem.eql(u8, e.key, "tags") or std.mem.eql(u8, e.key, "nav") or
            std.mem.eql(u8, e.key, "apis"))
        {
            return b.fail(config_path, 0, "'{s}' is set by Mortise; use another key", .{e.key});
        }
        if (std.mem.eql(u8, e.key, "baseurl")) {
            try site_entries.append(arena, .{ .key = e.key, .value = .{ .string = b.baseurl } });
            continue;
        }
        try site_entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    // Always defined, so templates can use it in strict mode.
    if (config_fields.get("baseurl") == null) try site_entries.append(arena, .{ .key = "baseurl", .value = .{ .string = "" } });
    try site_entries.append(arena, .{ .key = "posts", .value = .{ .list = post_values.items } });
    try site_entries.append(arena, .{ .key = "pages", .value = .{ .list = page_values.items } });
    try site_entries.append(arena, .{ .key = "data", .value = b.data });
    try site_entries.append(arena, .{ .key = "nav", .value = try navTree(arena, pages, b.baseurl) });
    try site_entries.append(arena, .{ .key = "apis", .value = try apiIndex(arena, pages) });
    const tag_pages = b.exists(tag_layout);
    const tags = try tagIndex(arena, pages, if (tag_pages) b.baseurl else null);
    try site_entries.append(arena, .{ .key = "tags", .value = tags });
    const icon_config = try iconConfig(b, config_fields);
    const icon_tags = if (icon_config) |c| try icons.tags(arena, c, b.baseurl) else "";
    try site_entries.append(arena, .{ .key = "icon_tags", .value = .{ .html = icon_tags } });
    const has_search = if (config_fields.get("search")) |v| (if (v == .boolean) v.boolean else return b.fail(config_path, fieldLine(try b.read(config_path), "search"), "'search' must be true or false", .{})) else false;
    try site_entries.append(arena, .{ .key = "search_box", .value = .{ .html = if (has_search) try search.box(arena, b.baseurl) else "" } });
    b.site = .{ .entries = site_entries.items };

    var rendered: usize = 0;
    var outputs: std.ArrayList(Output) = .empty;
    try outputs.appendSlice(arena, statics);
    const deps = try arena.alloc(Deps, pages.len);
    b.seo_config = try seoConfig(b, config_fields);
    for (pages, deps, 0..) |*p, *d, i| {
        if (render == null or render.?[i]) {
            b.deps = .empty;
            b.reads_collections = false;
            b.reads_seo = false;
            try b.addDep(p.source);
            for (p.included_files) |f| try b.addDep(f);
            try renderPaginated(b, p, post_values.items);
            p.sources = b.deps.items;
            p.reads_collections = b.reads_collections;
            p.uses_seo = b.reads_seo;
            p.search_sections = if (has_search) try searchSections(arena, p) else &.{};
            rendered += 1;
        }
        try outputs.append(arena, .{ .path = p.out_path, .source = p.source, .data = .{ .bytes = p.output } });
        try outputs.appendSlice(arena, p.extra_outputs);
        d.* = .{ .output = p.out_path, .sources = p.sources, .reads_collections = p.reads_collections };
    }

    if (tag_pages) try addTagPages(b, &outputs, tags.list);
    try addCards(b, &outputs, pages);
    try addComponentsCss(b, &outputs, config_fields, pages);
    try addThemeCss(b, &outputs, config_fields);
    try addAliases(b, &outputs, config_fields, pages);
    if (icon_config) |c| try addIcons(b, &outputs, c);
    if (has_search) try addSearch(b, &outputs, pages);
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
        .skipped = b.skipped,
        .state = .{ .skipped = b.skipped, .config_fields = config_fields, .baseurl = b.baseurl, .site_url = b.site_url, .options = b.options, .data = b.data, .history = b.history, .pages = pages, .statics = statics },
        .warnings = b.warnings.items,
        .gzip = if (config_fields.get("gzip")) |v| (if (v == .boolean) v.boolean else return b.fail(config_path, fieldLine(try b.read(config_path), "gzip"), "'gzip' must be true or false", .{})) else false,
    };
}

fn startsWithFrontmatter(b: *Builder, path: []const u8) Error!bool {
    const data = try b.read(path);
    const d = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
    return std.mem.startsWith(u8, d, "---\n") or std.mem.startsWith(u8, d, "---\r\n");
}

/// Reads and parses a page or post. Returns null for drafts.
fn loadPage(b: *Builder, path: []const u8, is_post: bool) Error!?Page {
    if (openapi.isSpec(path)) return try loadApiPage(b, path);
    const arena = b.arena;
    const data = try b.read(path);
    var fd: frontmatter.Diagnostic = .{};
    const doc = frontmatter.parse(arena, data, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
    };
    if (doc.fields.get("draft")) |d| {
        if (d != .boolean) return b.fail(path, fieldLine(data, "draft"), "'draft' must be true or false", .{});
        if (d.boolean and !b.options.drafts) {
            b.skipped.drafts += 1;
            return null;
        }
    }
    if (doc.fields.get("expires")) |e| {
        if (e != .string or template.parseDate(e.string) == null) {
            return b.fail(path, fieldLine(data, "expires"), "'expires' must look like YYYY-MM-DD", .{});
        }
        // Gone from the expiry date on.
        if (b.options.today.len > 0 and std.mem.order(u8, b.options.today, e.string[0..10]) != .lt) {
            b.skipped.expired += 1;
            return null;
        }
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
        var inc: FileIncluder = .{ .b = b, .page = path };
        var md_options = b.markdown_options;
        md_options.includer = .{ .ctx = &inc, .readFn = FileIncluder.read };
        const rendered = try markdown.toDocumentWith(arena, doc.body, md_options);
        if (rendered.include_error) |e| {
            const at = std.mem.indexOf(u8, doc.body, e.directive[4..]) orelse 0;
            return b.fail(path, doc.body_line + std.mem.count(u8, doc.body[0..at], "\n"), "{s}", .{e.message});
        }
        page.html = rendered.html;
        page.toc = try tocHtml(arena, rendered.headings);
        page.uses_components = rendered.uses_components;
        page.included_files = inc.files.items;
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
        // A post dated after today waits for its day, unless `--future`.
        if (!b.future and b.options.today.len > 0 and std.mem.order(u8, page.date, b.options.today) == .gt) {
            b.skipped.future += 1;
            return null;
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

    if (doc.fields.get("updated")) |d| {
        if (d != .string or template.parseDate(d.string) == null) {
            return b.fail(path, fieldLine(data, "updated"), "'updated' must look like YYYY-MM-DD", .{});
        }
        page.updated = d.string[0..10];
    } else if (b.history.dates.get(path)) |d| {
        page.updated = try arena.dupe(u8, &d);
    }
    if (b.history.edit_url) |tpl| {
        const repo_path = if (b.history.prefix.len == 0) path else try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.history.prefix, path });
        page.edit_url = try std.mem.replaceOwned(u8, arena, tpl, "{path}", repo_path);
    }
    if (doc.fields.get("aliases")) |al| {
        const line = fieldLine(data, "aliases");
        const items: []const frontmatter.Value = switch (al) {
            .list => |l| l,
            .string => &.{al},
            else => return b.fail(path, line, "'aliases' must be a list of paths such as [/old-url/]", .{}),
        };
        var aliases: std.ArrayList(AliasPath) = .empty;
        for (items) |item| {
            if (item != .string) return b.fail(path, line, "'aliases' must be a list of paths such as [/old-url/]", .{});
            if (redirects.invalidAlias(item.string)) |msg| return b.fail(path, line, "{s}: '{s}'", .{ msg, item.string });
            const raw = if (std.mem.endsWith(u8, item.string, "/"))
                try std.fmt.allocPrint(arena, "{s}index.html", .{item.string})
            else if (std.mem.endsWith(u8, item.string, ".html"))
                item.string
            else
                try std.fmt.allocPrint(arena, "{s}/index.html", .{item.string});
            const out = sitepath.normalize(arena, raw[1..]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return b.fail(path, line, "invalid alias '{s}': {s}", .{ item.string, @errorName(err) }),
            };
            try aliases.append(arena, .{ .url = item.string, .out_path = out });
        }
        page.aliases = aliases.items;
    }
    return page;
}

const AliasPath = struct {
    /// As written in frontmatter, such as `/old-url/`.
    url: []const u8,
    out_path: []const u8,
};

/// Writes a redirect page for every alias, and `_redirects` listing them
/// unless `redirects: false`.
fn addAliases(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map, pages: []const Page) Error!void {
    const arena = b.arena;
    var all: std.ArrayList(redirects.Alias) = .empty;
    for (pages) |p| {
        for (p.aliases) |a| {
            const canonical = if (b.site_url) |u| try std.mem.concat(arena, u8, &.{ u, p.url }) else p.url;
            try outputs.append(arena, .{ .path = a.out_path, .source = p.source, .data = .{ .bytes = try redirects.stub(arena, p.url, canonical) } });
            try all.append(arena, .{ .from = try std.mem.concat(arena, u8, &.{ b.baseurl, a.url }), .to = p.url });
        }
    }
    if (all.items.len > 0 and try enabled(b, config_fields, "redirects") and !hasOutput(outputs.items, redirects.redirects_path)) {
        try outputs.append(arena, .{ .path = redirects.redirects_path, .source = config_path, .data = .{ .bytes = try redirects.redirectsFile(arena, all.items) } });
    }
}

/// Reads files for one page's `<<< path` directives: `/path` from the
/// site root, any other path from the page's directory, never outside the
/// site. Records each file read, for incremental rebuilds.
const FileIncluder = struct {
    b: *Builder,
    page: []const u8,
    files: std.ArrayList([]const u8) = .empty,

    fn read(ctx: *anyopaque, raw: []const u8, why: *[]const u8) ?[]const u8 {
        const self: *FileIncluder = @ptrCast(@alignCast(ctx));
        const arena = self.b.arena;
        const joined = if (raw.len > 0 and raw[0] == '/')
            raw[1..]
        else if (sitepath.dirname(self.page)) |dir|
            std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, raw }) catch return oom(why)
        else
            raw;
        const path = sitepath.normalize(arena, joined) catch |err| {
            why.* = switch (err) {
                error.OutOfMemory => "out of memory",
                error.EscapesRoot => "the path leads outside the site",
                else => "not a valid site path",
            };
            return null;
        };
        if (std.mem.eql(u8, path, self.page)) {
            why.* = "a page cannot include itself";
            return null;
        }
        const data = self.b.src.readFile(arena, path) catch |err| {
            why.* = if (err == error.FileNotFound) "no such file" else @errorName(err);
            return null;
        };
        self.files.append(arena, path) catch return oom(why);
        return data;
    }

    fn oom(why: *[]const u8) ?[]const u8 {
        why.* = "out of memory";
        return null;
    }
};

/// Turns `_api/NAME.json` into a page at `/api/NAME/` holding the rendered
/// reference, laid out with `_layouts/api.html`, else `_layouts/doc.html`,
/// else no layout. `page.toc` lists its tags and operations.
fn loadApiPage(b: *Builder, path: []const u8) Error!Page {
    const arena = b.arena;
    var od: openapi.Diagnostic = .{};
    const r = openapi.render(arena, try b.read(path), &od) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => return b.fail(path, od.line, "{s}", .{od.message}),
    };
    var fields: std.ArrayList(frontmatter.Entry) = .empty;
    try fields.append(arena, .{ .key = "title", .value = .{ .string = r.title } });
    if (r.description.len > 0) try fields.append(arena, .{ .key = "description", .value = .{ .string = r.description } });
    for ([_][]const u8{ "api", "doc" }) |name| {
        const layout_path = try std.fmt.allocPrint(arena, "_layouts/{s}.html", .{name});
        if (b.exists(layout_path)) {
            try fields.append(arena, .{ .key = "layout", .value = .{ .string = name } });
            break;
        }
    }
    const name = sitepath.stem(path);
    const url = try std.fmt.allocPrint(arena, "{s}/api/{s}/", .{ b.baseurl, name });
    return .{
        .source = path,
        .is_post = false,
        .is_markdown = true,
        .fields = .{ .entries = fields.items },
        .body = "",
        .body_line = 1,
        .url = url,
        .out_path = try std.fmt.allocPrint(arena, "api/{s}/index.html", .{name}),
        .html = r.html,
        .toc = if (r.toc.len > 0) r.toc else null,
        .uses_components = true,
        .api = r,
    };
}

/// `site.apis`: every OpenAPI page in URL order with its operations, so a
/// layout can list them all with their methods.
fn apiIndex(arena: Allocator, pages: []const Page) Allocator.Error!Value {
    var apis: std.ArrayList(Value) = .empty;
    for (pages) |*p| {
        const r = p.api orelse continue;
        const ops = try arena.alloc(Value, r.operations.len);
        for (r.operations, ops) |op, *o| {
            const e = try arena.alloc(Entry, 6);
            e[0] = .{ .key = "method", .value = .{ .string = op.method } };
            e[1] = .{ .key = "path", .value = .{ .string = op.path } };
            e[2] = .{ .key = "summary", .value = .{ .string = op.summary } };
            e[3] = .{ .key = "tag", .value = .{ .string = op.tag } };
            e[4] = .{ .key = "url", .value = .{ .string = try std.fmt.allocPrint(arena, "{s}#{s}", .{ p.url, op.id }) } };
            e[5] = .{ .key = "deprecated", .value = .{ .boolean = op.deprecated } };
            o.* = .{ .object = .{ .entries = e } };
        }
        // The same operations grouped by tag; operations come tag by tag.
        var groups: std.ArrayList(Value) = .empty;
        var start: usize = 0;
        while (start < ops.len) {
            var end = start + 1;
            while (end < ops.len and std.mem.eql(u8, r.operations[end].tag, r.operations[start].tag)) end += 1;
            const g = try arena.alloc(Entry, 2);
            g[0] = .{ .key = "name", .value = .{ .string = r.operations[start].tag } };
            g[1] = .{ .key = "operations", .value = .{ .list = ops[start..end] } };
            try groups.append(arena, .{ .object = .{ .entries = g } });
            start = end;
        }
        const e = try arena.alloc(Entry, 6);
        e[0] = .{ .key = "title", .value = .{ .string = r.title } };
        e[1] = .{ .key = "url", .value = .{ .string = p.url } };
        e[2] = .{ .key = "version", .value = .{ .string = r.version } };
        e[3] = .{ .key = "description", .value = .{ .html = try markdown.toHtml(arena, r.description) } };
        e[4] = .{ .key = "operations", .value = .{ .list = ops } };
        e[5] = .{ .key = "tags", .value = .{ .list = groups.items } };
        try apis.append(arena, .{ .object = .{ .entries = e } });
    }
    std.mem.sortUnstable(Value, apis.items, {}, apiLess);
    return .{ .list = apis.items };
}

fn apiLess(_: void, a: Value, b: Value) bool {
    return std.mem.lessThan(u8, a.object.entries[1].value.string, b.object.entries[1].value.string);
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
    // `updated` from Git history; frontmatter `updated` is already a field.
    if (p.updated.len > 0 and p.fields.get("updated") == null) {
        try entries.append(arena, .{ .key = "updated", .value = .{ .string = p.updated } });
    }
    if (p.edit_url.len > 0 and p.fields.get("edit_url") == null) {
        try entries.append(arena, .{ .key = "edit_url", .value = .{ .string = p.edit_url } });
    }
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

/// A page's title for navigation: its `title`, else the last URL segment,
/// else "Home".
fn navTitle(p: *const Page) []const u8 {
    if (stringField(p.fields, "title")) |t| return t;
    const trimmed = std.mem.trim(u8, p.url, "/");
    if (trimmed.len == 0) return "Home";
    return trimmed[(std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed) + 1 ..];
}

/// `weight` from frontmatter orders navigation; pages without one sort
/// after those with one.
fn navWeight(p: *const Page) i64 {
    const v = p.fields.get("weight") orelse return std.math.maxInt(i64);
    return if (v == .int) v.int else std.math.maxInt(i64);
}

fn navLink(arena: Allocator, p: *const Page) Allocator.Error!Value {
    const entries = try arena.alloc(Entry, 2);
    entries[0] = .{ .key = "title", .value = .{ .string = navTitle(p) } };
    entries[1] = .{ .key = "url", .value = .{ .string = p.url } };
    return .{ .object = .{ .entries = entries } };
}

/// The URL directory a page lives in: `/docs/guide/` for both
/// `/docs/guide/setup/` and `/docs/guide/page.html`; "" for the root.
fn parentUrl(url: []const u8) []const u8 {
    const trimmed = if (url.len > 1 and url[url.len - 1] == '/') url[0 .. url.len - 1] else url;
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "";
    return trimmed[0 .. slash + 1];
}

fn pageAtUrl(pages: []const Page, url: []const u8) ?*const Page {
    for (pages) |*p| if (!p.is_post and std.mem.eql(u8, p.url, url)) return p;
    return null;
}

/// Sets each page's `object` to its fields plus navigation:
///
///   page.breadcrumbs  ancestor pages by URL, root first, as {title, url}
///   page.previous     for posts, the next older post; for pages, the
///   page.next         previous and next page in the same URL directory,
///                     ordered by `weight` then title
fn addNavigation(arena: Allocator, pages: []Page) Allocator.Error!void {
    for (pages, 0..) |*p, i| {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.base.entries);

        // Breadcrumbs: every existing page whose URL is a prefix directory.
        var crumbs: std.ArrayList(Value) = .empty;
        var dir = parentUrl(p.url);
        var stack: std.ArrayList(Value) = .empty;
        while (dir.len > 0) : (dir = parentUrl(dir)) {
            if (pageAtUrl(pages, dir)) |anc| try stack.append(arena, try navLink(arena, anc));
            if (dir.len == 1) break;
        }
        var k = stack.items.len;
        while (k > 0) {
            k -= 1;
            try crumbs.append(arena, stack.items[k]);
        }
        try entries.append(arena, .{ .key = "breadcrumbs", .value = .{ .list = crumbs.items } });

        var prev: ?*const Page = null;
        var next: ?*const Page = null;
        if (p.is_post) {
            // Posts are newest first: the next item is older.
            if (i + 1 < pages.len and pages[i + 1].is_post) prev = &pages[i + 1];
            if (i > 0 and pages[i - 1].is_post) next = &pages[i - 1];
        } else {
            const siblings = try siblingPages(arena, pages, p);
            for (siblings, 0..) |s, si| {
                if (s != p) continue;
                if (si > 0) prev = siblings[si - 1];
                if (si + 1 < siblings.len) next = siblings[si + 1];
            }
        }
        try entries.append(arena, .{ .key = "previous", .value = if (prev) |q| try navLink(arena, q) else .nil });
        try entries.append(arena, .{ .key = "next", .value = if (next) |q| try navLink(arena, q) else .nil });
        p.object = .{ .entries = entries.items };
    }
}

/// Pages in the same URL directory as `p` (not counting the directory's
/// own index page), in navigation order.
fn siblingPages(arena: Allocator, pages: []const Page, p: *const Page) Allocator.Error![]const *const Page {
    const dir = parentUrl(p.url);
    var out: std.ArrayList(*const Page) = .empty;
    if (std.mem.eql(u8, p.url, "/") or dir.len == 0) return out.items;
    for (pages) |*q| {
        if (q.is_post or isHiddenFromNav(q)) continue;
        if (std.mem.eql(u8, parentUrl(q.url), dir) and !std.mem.eql(u8, q.url, "/")) try out.append(arena, q);
    }
    std.mem.sortUnstable(*const Page, out.items, {}, navLess);
    return out.items;
}

fn isHiddenFromNav(p: *const Page) bool {
    const v = p.fields.get("nav") orelse return false;
    return v == .boolean and !v.boolean;
}

fn navLess(_: void, a: *const Page, b: *const Page) bool {
    const wa = navWeight(a);
    const wb = navWeight(b);
    if (wa != wb) return wa < wb;
    return std.mem.lessThan(u8, navTitle(a), navTitle(b));
}

/// `site.nav`: the non-post pages as a tree by URL, each node
/// {title, url, children}, ordered by `weight` then title. The home page
/// is not in the tree; pages with `nav: false` are left out.
fn navTree(arena: Allocator, pages: []const Page, baseurl: []const u8) Allocator.Error!Value {
    const root = try std.fmt.allocPrint(arena, "{s}/", .{baseurl});
    return navChildren(arena, pages, root);
}

fn navChildren(arena: Allocator, pages: []const Page, dir: []const u8) Allocator.Error!Value {
    var kids: std.ArrayList(*const Page) = .empty;
    for (pages) |*q| {
        if (q.is_post or isHiddenFromNav(q) or std.mem.eql(u8, q.url, dir)) continue;
        // The nearest ancestor page decides where a page hangs in the tree.
        var anc = parentUrl(q.url);
        while (anc.len > dir.len and pageAtUrl(pages, anc) == null) anc = parentUrl(anc);
        if (std.mem.eql(u8, anc, dir)) try kids.append(arena, q);
    }
    std.mem.sortUnstable(*const Page, kids.items, {}, navLess);
    const out = try arena.alloc(Value, kids.items.len);
    for (kids.items, out) |q, *o| {
        const entries = try arena.alloc(Entry, 3);
        entries[0] = .{ .key = "title", .value = .{ .string = navTitle(q) } };
        entries[1] = .{ .key = "url", .value = .{ .string = q.url } };
        entries[2] = .{ .key = "children", .value = if (std.mem.endsWith(u8, q.url, "/")) try navChildren(arena, pages, q.url) else .{ .list = &.{} } };
        o.* = .{ .object = .{ .entries = entries } };
    }
    return .{ .list = out };
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

/// The search sections of a rendered page, or none for pages that opt
/// out with `search: false` and for the 404 page.
fn searchSections(arena: Allocator, p: *const Page) Allocator.Error![]const search.Section {
    if (p.fields.get("search")) |v| if (v == .boolean and !v.boolean) return &.{};
    if (std.mem.eql(u8, p.out_path, "404.html")) return &.{};
    // Markdown pages index their content; template pages the `<main>` of
    // their output, else its body.
    const html = p.html orelse blk: {
        const out = p.output;
        if (std.mem.indexOf(u8, out, "<main")) |m| {
            const start = (std.mem.indexOfScalarPos(u8, out, m, '>') orelse m) + 1;
            const end = std.mem.lastIndexOf(u8, out, "</main>") orelse out.len;
            break :blk out[@min(start, end)..end];
        }
        break :blk out;
    };
    return search.sections(arena, navTitle(p), p.url, html);
}

/// Writes the search index of every page's sections and the client.
fn addSearch(b: *Builder, outputs: *std.ArrayList(Output), pages: []const Page) Error!void {
    var all: std.ArrayList(search.Section) = .empty;
    for (pages) |p| try all.appendSlice(b.arena, p.search_sections);
    if (!hasOutput(outputs.items, search.index_path)) {
        try outputs.append(b.arena, .{ .path = search.index_path, .source = config_path, .data = .{ .bytes = try search.indexJson(b.arena, all.items) } });
    }
    if (!hasOutput(outputs.items, search.script_path)) {
        try outputs.append(b.arena, .{ .path = search.script_path, .source = config_path, .data = .{ .bytes = search.script } });
    }
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
        b.page_url = if (k > 1) try pageUrl(arena, p.url, k) else null;
        defer b.page_url = null;
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
    b.current_seo = try seoFor(b, p);
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
    if (b.markdown_options.copy_buttons and std.mem.indexOf(u8, content, "class=\"mt-copy\"") != null) {
        content = try insertBeforeBodyEnd(b.arena, content, markdown.copy_script);
    }
    return content;
}

/// `html` with `snippet` inserted before its last `</body>`, or appended
/// when it has none.
fn insertBeforeBodyEnd(arena: Allocator, html: []const u8, snippet: []const u8) Allocator.Error![]const u8 {
    const at = std.mem.lastIndexOf(u8, html, "</body>") orelse html.len;
    return std.mem.concat(arena, u8, &.{ html[0..at], snippet, html[at..] });
}

/// `html` without heading anchors and copy buttons, which mean nothing
/// in a feed reader.
fn withoutPageControls(arena: Allocator, html: []const u8) Allocator.Error![]const u8 {
    const button = "<button type=\"button\" class=\"mt-copy\" hidden>Copy</button>";
    const anchor = " <a class=\"mt-anchor\" href=\"";
    if (std.mem.indexOf(u8, html, button) == null and std.mem.indexOf(u8, html, anchor) == null) return html;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], button)) {
            i += button.len;
        } else if (std.mem.startsWith(u8, html[i..], anchor)) {
            const end = std.mem.indexOfPos(u8, html, i, "</a>") orelse html.len;
            i = @min(html.len, end + "</a>".len);
        } else {
            try out.append(arena, html[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Reads `heading_anchors` and `copy_code` (both on by default).
fn markdownOptions(b: *Builder, config_fields: frontmatter.Map) Error!markdown.Options {
    return .{
        .heading_anchors = try enabled(b, config_fields, "heading_anchors"),
        .copy_buttons = try enabled(b, config_fields, "copy_code"),
    };
}

fn renderTemplate(b: *Builder, tpl: *const template.Template, p: *const Page, content: ?[]const u8) Error![]const u8 {
    var entries: [5]Entry = undefined;
    var n: usize = 0;
    entries[n] = .{ .key = "site", .value = .{ .object = b.site } };
    n += 1;
    entries[n] = .{ .key = "seo", .value = .{ .html = b.current_seo } };
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
    return template.renderAllocWith(b.arena, tpl, root, .{ .ctx = b, .loadFn = loadInclude, .extendsFn = loadExtends }, .{ .strict = b.strict }, &td) catch |err| switch (err) {
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

/// Loads the layout a `{% extends "NAME" %}` names: `_layouts/NAME`, with
/// `.html` added when missing.
fn loadExtends(ctx: *anyopaque, name: []const u8, diag: *template.Diagnostic) template.Loader.LoadError!*const template.Template {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    const raw = try std.fmt.allocPrint(b.arena, "_layouts/{s}{s}", .{ name, if (std.mem.endsWith(u8, name, ".html")) "" else ".html" });
    const path = sitepath.normalize(b.arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    if (!std.mem.startsWith(u8, path, "_layouts/") or !b.exists(path)) return error.TemplateNotFound;
    const layout = loadLayout(b, name, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BuildFailed => {
            diag.* = .{ .template = b.diag.path, .line = b.diag.line, .message = b.diag.message };
            return error.TemplateSyntax;
        },
    };
    b.useTemplate(layout.tpl);
    return layout.tpl;
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

/// Writes every output into `out`, copying static files from `src`, and
/// `.gz` copies of text files when the site asks for them.
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
        if (site.gzip) writeGzip(o, src, out) catch |err| {
            diag.* = .{ .path = o.path, .message = @errorName(err) };
            return error.BuildFailed;
        };
    }
}

/// Writes `PATH.gz` for a text output over the size threshold.
fn writeGzip(o: Output, src: SiteDir, out: SiteDir) !void {
    // Outputs are written one after another, so a scratch arena per file
    // keeps memory flat.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (!gzip.wanted(o.path, gzip.min_size)) return;
    const data = switch (o.data) {
        .bytes => |bytes| bytes,
        .copy => try src.readFile(arena, o.source),
    };
    if (!gzip.wanted(o.path, data.len)) return;
    const gz_path = try std.mem.concat(arena, u8, &.{ o.path, ".gz" });
    try out.writeFile(gz_path, try gzip.compress(arena, data));
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

test "a theme writes its stylesheet and is visible to templates" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: T\ntheme: lcars\n" },
        .{ "index.html", "---\n---\n{% if site.theme %}<link href=\"/theme.css\" data-theme=\"{{ site.theme }}\">{% endif %}" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expectEqualStrings("<link href=\"/theme.css\" data-theme=\"lcars\">", site.find("index.html").?.data.bytes);
    // The tokens come right after the theme's @import, then the theme.
    const css = site.find(themes.css_path).?.data.bytes;
    const import_end = std.mem.indexOf(u8, css, "@import url(\"theme/hologram.css\");").? + 34;
    const tokens_at = std.mem.indexOf(u8, css, "/* Design tokens").?;
    try testing.expect(tokens_at > import_end and tokens_at < import_end + 4);
    try testing.expect(std.mem.indexOf(u8, css, "  --m-accent: #ff9c3c;\n") != null);
    try testing.expect(std.mem.endsWith(u8, css, themes.find("lcars").?.css[import_end..]));
}

test "theme_tokens override a theme's tokens, and low contrast warns" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "theme: visor\ntheme_tokens:\n  accent: \"#ff9c00\"\n  muted: \"#222222\"\n" },
        .{ "index.html", "---\n---\n[{{ site.scheme_toggle }}]" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const css = site.find(themes.css_path).?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, css, "  --m-accent: #ff9c00;\n") != null);
    try testing.expect(std.mem.startsWith(u8, css, "/* Design tokens"));
    // A dark-only theme has no scheme switch.
    try testing.expectEqualStrings("[]", site.find("index.html").?.data.bytes);
    try testing.expectEqual(@as(usize, 1), site.warnings.len);
    try testing.expectEqualStrings("_config.yml", site.warnings[0].path);
    try testing.expectEqual(@as(usize, 2), site.warnings[0].line);
    try testing.expect(std.mem.startsWith(u8, site.warnings[0].message, "low contrast: 'muted' on 'bg' is 1."));

    // Tokens without a theme, in light and dark, with the switch.
    var t2: TestSite = try .init(&.{
        .{ "_config.yml", "theme_tokens:\n  bg: [\"#ffffff\", \"#111111\"]\n  text: [\"#111111\", \"#eeeeee\"]\n" },
        .{ "index.html", "---\n---\n{{ site.scheme_toggle }}" },
    });
    defer t2.deinit();
    const s2 = try t2.build(&diag);
    try testing.expect(std.mem.indexOf(u8, s2.find(themes.css_path).?.data.bytes, "--m-bg: light-dark(#ffffff, #111111);") != null);
    try testing.expect(std.mem.startsWith(u8, s2.find("index.html").?.data.bytes, "<fieldset class=\"mt-scheme\">"));
    try testing.expectEqual(@as(usize, 0), s2.warnings.len);

    try expectBuildError(&.{.{ "_config.yml", "theme: visor\ntheme_tokens:\n  bg: \"#000\"\n  accent: cyan\n" }}, "_config.yml", 4, "theme_tokens: 'accent' must be a color");
}

test "an unknown theme names the config line and the themes" {
    try expectBuildError(&.{
        .{ "_config.yml", "title: T\ntheme: borg\n" },
        .{ "index.md", "hi\n" },
    }, "_config.yml", 2, "unknown theme 'borg'; the themes are: visor, lcars");
}

test "render specs become images, with CSS for animated kinds" {
    var t: TestSite = try .init(&.{
        .{ "_render/img/stars.yml", "kind: starfield\nwidth: 32\nheight: 16\n" },
        .{ "_render/radar.yml", "kind: radar\nsize: 24\nframes: 2\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const stars = site.find("img/stars.png").?;
    try testing.expectEqualStrings("_render/img/stars.yml", stars.source);
    try testing.expect(std.mem.startsWith(u8, stars.data.bytes, "\x89PNG"));
    try testing.expect(site.find("img/stars.css") == null);
    try testing.expect(site.find("radar.png") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("radar.css").?.data.bytes, "url(\"radar.png\")") != null);
    // The specs themselves are not published.
    try testing.expect(site.find("_render/radar.yml") == null);
}

test "a bad render spec names its file and line" {
    try expectBuildError(&.{
        .{ "_render/stars.yml", "kind: starfield\nwidth: 2\n" },
    }, "_render/stars.yml", 2, "'width' must be a whole number from 8 to 4096");
    try expectBuildError(&.{
        .{ "_render/stars.yml", "kind: starfield\n" },
        .{ "stars.png", "not really" },
    }, "stars.png", 0, "writes to 'stars.png', which '_render/stars.yml' also writes to");
}

test "the render cache keeps unchanged assets across rebuilds" {
    var t: TestSite = try .init(&.{
        .{ "_render/a.yml", "kind: reticle\nsize: 16\n" },
        .{ "_render/b.yml", "kind: reticle\nsize: 24\n" },
        .{ "index.md", "hi\n" },
    });
    defer t.deinit();
    var cache: assets.Cache = .init(testing.allocator);
    defer cache.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const first = try buildWith(t.arena.allocator(), src, .{ .render_cache = &cache }, &diag);
    try src.writeFile("_render/b.yml", "kind: reticle\nsize: 32\n");
    const second = try rebuild(t.arena.allocator(), src, &first, &.{"_render/b.yml"}, &diag);
    try testing.expectEqual(first.find("a.png").?.data.bytes.ptr, second.find("a.png").?.data.bytes.ptr);
    try testing.expect(first.find("b.png").?.data.bytes.ptr != second.find("b.png").?.data.bytes.ptr);
    // Editing a page does not touch the assets at all.
    try src.writeFile("index.md", "hello\n");
    const third = try rebuild(t.arena.allocator(), src, &second, &.{"index.md"}, &diag);
    try testing.expect(!third.full);
    try testing.expectEqual(second.find("b.png").?.data.bytes.ptr, third.find("b.png").?.data.bytes.ptr);
}

test "theme assets render into /theme/ unless the site overrides them" {
    var t: TestSite = try .init(&.{
        .{ "theme/dot.png", "mine" },
    });
    defer t.deinit();
    var b: Builder = .{ .arena = t.arena.allocator(), .src = SiteDir.borrow(testing.io, t.tmp.dir), .diag = undefined };
    var diag: Diagnostic = .{};
    b.diag = &diag;
    const theme: themes.Theme = .{ .name = "test", .css = "", .assets = &.{
        .{ .name = "dot", .spec = "kind: reticle\nsize: 16\n" },
        .{ .name = "scope", .spec = "kind: radar\nsize: 16\nframes: 2\n" },
    } };
    var outputs: std.ArrayList(Output) = .empty;
    try outputs.append(b.arena, .{ .path = "theme/dot.png", .source = "theme/dot.png", .data = .copy });
    try addThemeAssets(&b, &outputs, theme, 3);
    try testing.expectEqual(@as(usize, 3), outputs.items.len);
    try testing.expectEqualStrings("theme/scope.png", outputs.items[1].path);
    try testing.expectEqualStrings("theme/scope.css", outputs.items[2].path);
    try testing.expect(std.mem.indexOf(u8, outputs.items[2].data.bytes, ".scope {") != null);

    const bad: themes.Theme = .{ .name = "test", .css = "", .assets = &.{.{ .name = "x", .spec = "kind: radar\nsize: 1\n" }} };
    try testing.expectError(error.BuildFailed, addThemeAssets(&b, &outputs, bad, 3));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expect(std.mem.indexOf(u8, diag.message, "theme 'test', asset 'x', line 2: 'size' must be") != null);
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
        // For the heading anchor on the about page.
        "mortise.css",
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
    try testing.expectEqualStrings("<h1 id=\"about-me\">About <em>me</em> <a class=\"mt-anchor\" href=\"#about-me\" aria-label=\"Link to this section\">#</a></h1>\n", site.find("about/index.html").?.data.bytes);
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

test "mortise.css is written only when a page uses a component" {
    var with: TestSite = try .init(&.{.{ "a.md", "> [!NOTE]\n> Hi.\n" }});
    defer with.deinit();
    var diag: Diagnostic = .{};
    const s1 = try with.build(&diag);
    try testing.expect(std.mem.startsWith(u8, s1.find(components_css_path).?.data.bytes, "/* Mortise components"));

    var without: TestSite = try .init(&.{.{ "a.md", "Plain.\n" }});
    defer without.deinit();
    try testing.expect((try without.build(&diag)).find(components_css_path) == null);

    var off: TestSite = try .init(&.{
        .{ "_config.yml", "components_css: false\n" },
        .{ "a.md", ":badge[x]\n" },
    });
    defer off.deinit();
    try testing.expect((try off.build(&diag)).find(components_css_path) == null);
}

test "breadcrumbs, previous and next, and the navigation tree" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/l.html", "{% for c in page.breadcrumbs %}{{ c.title }}>{% endfor %}|{{ page.previous.title }}|{{ page.next.title }}" },
        .{ "_layouts/tree.html", "{% for a in site.nav %}[{{ a.title }}{% for b in a.children %}({{ b.title }}{% for c in b.children %}<{{ c.title }}>{% endfor %}){% endfor %}]{% endfor %}" },
        .{ "index.md", "---\nlayout: tree\n---\n" },
        .{ "docs/index.md", "---\ntitle: Docs\nlayout: l\n---\n" },
        .{ "docs/b.md", "---\ntitle: Beta\nlayout: l\nweight: 2\n---\n" },
        .{ "docs/a.md", "---\ntitle: Alpha\nlayout: l\nweight: 1\n---\n" },
        .{ "docs/z.md", "---\ntitle: Zed\nlayout: l\n---\n" },
        .{ "docs/guide/setup.md", "---\ntitle: Setup\nlayout: l\n---\n" },
        .{ "about.md", "---\ntitle: About\nnav: false\n---\n" },
        .{ "_posts/2024-01-01-old.md", "---\ntitle: Old\nlayout: l\n---\n" },
        .{ "_posts/2024-02-01-new.md", "---\ntitle: New\nlayout: l\n---\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    // Weighted pages first, then by title; the section index is not a sibling.
    try testing.expectEqualStrings("Home>Docs>|Alpha|Zed", site.find("docs/b/index.html").?.data.bytes);
    try testing.expectEqualStrings("Home>Docs>||Beta", site.find("docs/a/index.html").?.data.bytes);
    try testing.expectEqualStrings("Home>||", site.find("docs/index.html").?.data.bytes);
    // A page under a directory with no index hangs from the nearest page.
    try testing.expectEqualStrings("Home>Docs>||", site.find("docs/guide/setup/index.html").?.data.bytes);
    // Posts: previous is older, next is newer.
    try testing.expectEqualStrings("Home>|Old|", site.find("2024/02/01/new/index.html").?.data.bytes);
    try testing.expectEqualStrings("Home>||New", site.find("2024/01/01/old/index.html").?.data.bytes);
    try testing.expectEqualStrings("[Docs(Alpha)(Beta)(Setup)(Zed)]", site.find("index.html").?.data.bytes);
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

test "aliases write redirect pages and a _redirects file" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "url: https://example.com\nbaseurl: /blog\n" },
        .{ "new.md", "---\ntitle: New\naliases: [/old/, /older.html, /oldest]\nupdated: 2024-03-01\n---\nN\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const stub = site.find("old/index.html").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, stub, "content=\"0; url=/blog/new/\"") != null);
    try testing.expect(std.mem.indexOf(u8, stub, "<link rel=\"canonical\" href=\"https://example.com/blog/new/\">") != null);
    try testing.expect(site.find("older.html") != null);
    try testing.expect(site.find("oldest/index.html") != null);
    try testing.expectEqualStrings(
        "# Generated by Mortise from frontmatter aliases.\n/blog/old/ /blog/new/ 301\n/blog/older.html /blog/new/ 301\n/blog/oldest /blog/new/ 301\n",
        site.find("_redirects").?.data.bytes,
    );
    try testing.expectEqualStrings("User-agent: *\nAllow: /\n\nSitemap: https://example.com/blog/sitemap.xml\n", site.find("robots.txt").?.data.bytes);
    try testing.expect(std.mem.indexOf(u8, site.find("sitemap.xml").?.data.bytes, "<lastmod>2024-03-01</lastmod>") != null);

    // Switches turn the generated files off.
    var t2: TestSite = try .init(&.{
        .{ "_config.yml", "url: https://example.com\nredirects: false\nrobots: false\n" },
        .{ "new.md", "---\naliases: /old/\n---\nN\n" },
    });
    defer t2.deinit();
    const s2 = try t2.build(&diag);
    try testing.expect(s2.find("old/index.html") != null);
    try testing.expect(s2.find("_redirects") == null and s2.find("robots.txt") == null);

    try expectBuildError(&.{.{ "a.md", "---\naliases: [old/]\n---\n" }}, "a.md", 2, "must be a path starting with '/'");
    try expectBuildError(&.{.{ "a.md", "---\nupdated: soon\n---\n" }}, "a.md", 2, "'updated' must look like YYYY-MM-DD");
    try expectBuildError(&.{
        .{ "a.md", "---\naliases: [/b/]\n---\n" },
        .{ "b.md", "B\n" },
    }, "b.md", 0, "also writes to");
}

test "heading anchors and copy buttons, on by default" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/base.html", "<html><body>{{ content }}</body></html>" },
        .{ "a.md", "---\nlayout: base\n---\n## Install\n\n```sh\nzig build\n```\n" },
        .{ "b.md", "---\nlayout: base\n---\nNo code.\n" },
    });
    defer t.deinit();
    const a = try t.output("a/index.html");
    try testing.expect(std.mem.indexOf(u8, a, "<h2 id=\"install\">Install <a class=\"mt-anchor\" href=\"#install\"") != null);
    try testing.expect(std.mem.indexOf(u8, a, "<pre><button type=\"button\" class=\"mt-copy\" hidden>Copy</button><code class=\"language-sh\">") != null);
    // The copy script goes before </body>, once, and only where needed.
    try testing.expect(std.mem.endsWith(u8, a, "</script>\n</body></html>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, a, "<script>"));
    try testing.expect(std.mem.indexOf(u8, try t.output("b/index.html"), "<script>") == null);

    var t2: TestSite = try .init(&.{
        .{ "_config.yml", "heading_anchors: false\ncopy_code: false\n" },
        .{ "a.md", "## Install\n\n```sh\nzig build\n```\n" },
    });
    defer t2.deinit();
    try testing.expectEqualStrings(
        "<h2 id=\"install\">Install</h2>\n<pre><code class=\"language-sh\">zig build\n</code></pre>\n",
        try t2.output("a/index.html"),
    );
}

test "<<< includes code from files and rebuilds when they change" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "copy_code: false\n" },
        .{ "_snippets/hello.zig", "const std = @import(\"std\");\n\npub fn main() void {\n    // #region greet\n    std.debug.print(\"hi\", .{});\n    // #endregion greet\n}\n" },
        .{ "docs/guide.md", "# Guide\n\n<<< /_snippets/hello.zig#greet\n\n<<< ../_snippets/hello.zig:1 title=\"first line\"\n" },
        .{ "other.md", "Other.\n" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = try t.build(&diag);
    const guide = site.find("docs/guide/index.html").?.data.bytes;
    // The region, dedented, without its markers.
    try testing.expect(std.mem.indexOf(u8, guide, "<pre><code class=\"language-zig\">std.debug.print(") != null);
    try testing.expect(std.mem.indexOf(u8, guide, "<div class=\"mt-code-title\">first line</div>") != null);
    try testing.expect(std.mem.indexOf(u8, guide, "#region") == null);
    // The snippet is a dependency of the page that includes it.
    for (site.deps) |d| {
        if (std.mem.eql(u8, d.output, "docs/guide/index.html")) try testing.expectEqualStrings("_snippets/hello.zig", d.sources[1]);
    }

    // Editing the snippet re-renders only the page that includes it.
    try src.writeFile("_snippets/hello.zig", "// #region greet\nchanged();\n// #endregion\n");
    site = try rebuild(a, src, &site, &.{"_snippets/hello.zig"}, &diag);
    try testing.expectEqual(@as(usize, 1), site.rendered);
    try testing.expect(std.mem.indexOf(u8, site.find("docs/guide/index.html").?.data.bytes, "changed") != null);

    // A region that disappears is an error on the directive's line.
    try src.writeFile("_snippets/hello.zig", "nothing here\n");
    try testing.expectError(error.BuildFailed, rebuild(a, src, &site, &.{"_snippets/hello.zig"}, &diag));
    try testing.expectEqualStrings("docs/guide.md", diag.path);
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expectEqualStrings("'/_snippets/hello.zig' has no '#region greet'", diag.message);

    try expectBuildError(&.{.{ "a.md", "---\nt: 1\n---\nText\n\n<<< missing.zig\n" }}, "a.md", 6, "cannot include 'missing.zig': no such file");
    try expectBuildError(&.{.{ "a.md", "<<< ../../etc/passwd\n" }}, "a.md", 1, "outside the site");
    try expectBuildError(&.{ .{ "a.md", "<<< b.txt:2-9\n" }, .{ "b.txt", "one\ntwo\n" } }, "a.md", 1, "'b.txt' has no lines 2-9; it has 2");
}

test "future posts wait for their date and expired pages are left out" {
    var t: TestSite = try .init(&.{
        .{ "_posts/2024-01-01-past.md", "Past.\n" },
        .{ "_posts/2024-06-01-today.md", "Today.\n" },
        .{ "_posts/2024-01-02-moved.md", "---\ndate: 2024-12-01\n---\nScheduled by its frontmatter date.\n" },
        .{ "_posts/2025-01-01-next-year.md", "Next year.\n" },
        .{ "sale.md", "---\nexpires: 2024-06-01\n---\nGone today.\n" },
        .{ "promo.md", "---\nexpires: 2024-06-02\n---\nStill here.\n" },
        .{ "draft.md", "---\ndraft: true\n---\nDraft.\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const a = t.arena.allocator();

    const site = try buildWith(a, src, .{ .today = "2024-06-01" }, &diag);
    try testing.expect(site.find("2024/01/01/past/index.html") != null);
    try testing.expect(site.find("2024/06/01/today/index.html") != null);
    try testing.expect(site.find("2024/12/01/moved/index.html") == null);
    try testing.expect(site.find("2025/01/01/next-year/index.html") == null);
    try testing.expect(site.find("sale/index.html") == null);
    try testing.expect(site.find("promo/index.html") != null);
    try testing.expectEqual(Skipped{ .drafts = 1, .future = 2, .expired = 1 }, site.skipped);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1 draft, 2 future posts, 1 expired page", try std.fmt.bufPrint(&buf, "{f}", .{site.skipped}));

    // An incremental rebuild keeps the counts.
    try src.writeFile("promo.md", "---\nexpires: 2024-06-02\n---\nStill here, edited.\n");
    const again = try rebuild(a, src, &site, &.{"promo.md"}, &diag);
    try testing.expectEqual(site.skipped, again.skipped);

    // --future publishes them; no date publishes everything but drafts.
    const future = try buildWith(a, src, .{ .today = "2024-06-01", .future = true }, &diag);
    try testing.expect(future.find("2025/01/01/next-year/index.html") != null);
    try testing.expectEqual(Skipped{ .drafts = 1, .expired = 1 }, future.skipped);
    try testing.expectEqual(Skipped{ .drafts = 1 }, (try buildWith(a, src, .{}, &diag)).skipped);

    try expectBuildError(&.{.{ "a.md", "---\nexpires: never\n---\n" }}, "a.md", 2, "'expires' must look like YYYY-MM-DD");
}

test "git_dates and edit_url come from the repository holding the site" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "repo/.git/objects");
    var objects = try tmp.dir.openDir(io, "repo/.git/objects", .{});
    defer objects.close(io);
    var site_dir = try tmp.dir.createDirPathOpen(io, "repo/site", .{ .open_options = .{ .iterate = true } });
    defer site_dir.close(io);
    const site = SiteDir.borrow(io, site_dir);
    const config = "url: https://example.com\ngit_dates: true\nedit_url: https://github.com/me/r/edit/main/{path}\n";
    const page = "---\nlayout: x\n---\nA\n";
    const pinned = "---\nupdated: 2025-05-05\n---\nB\n";
    try site.writeFile("_config.yml", config);
    try site.writeFile("_layouts/x.html", "{{ page.updated }}|{{ page.edit_url }}");
    try site.writeFile("a.md", page);
    try site.writeFile("b.md", pinned);

    // One commit on 2024-01-01 holding the site as it is on disk.
    const blob_a = try git.writeLoose(a, objects, "blob", page);
    const blob_b = try git.writeLoose(a, objects, "blob", pinned);
    const site_tree = try git.writeLoose(a, objects, "tree", try git.treeData(a, &.{ .{ "100644", "a.md", blob_a }, .{ "100644", "b.md", blob_b } }));
    const root = try git.writeLoose(a, objects, "tree", try git.treeData(a, &.{.{ "40000", "site", site_tree }}));
    const commit = try git.writeLoose(a, objects, "commit", try std.fmt.allocPrint(a, "tree {x}\ncommitter A <a@x> 1704110400 +0000\n\nc\n", .{&root}));
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = try std.fmt.allocPrint(a, "{x}\n", .{&commit}) });

    var diag: Diagnostic = .{};
    const built = build(a, site, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expectEqualStrings("2024-01-01|https://github.com/me/r/edit/main/site/a.md", built.find("a/index.html").?.data.bytes);
    const map = built.find("sitemap.xml").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, map, "<loc>https://example.com/a/</loc><lastmod>2024-01-01</lastmod>") != null);
    // Frontmatter `updated` wins over the history.
    try testing.expect(std.mem.indexOf(u8, map, "<loc>https://example.com/b/</loc><lastmod>2025-05-05</lastmod>") != null);

    try expectBuildError(&.{.{ "_config.yml", "edit_url: https://x/edit\n" }}, "_config.yml", 0, "'edit_url' must be a URL containing {path}");
}

test "seo outputs head tags and pages that use it get a social card" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Site\nurl: https://example.com\ntwitter: handle\n" },
        .{ "_layouts/base.html", "<head>{{ seo }}</head>{{ content }}" },
        .{ "_layouts/bare.html", "{{ content }}" },
        .{ "about.md", "---\ntitle: About us\nlayout: base\n---\nWe make *sites*.\n" },
        .{ "photo.md", "---\ntitle: Photo\nlayout: base\nimage: img/p.jpg\n---\nP\n" },
        .{ "plain.md", "---\nlayout: bare\n---\nNo head tags here.\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const about = site.find("about/index.html").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, about, "<meta name=\"description\" content=\"We make sites.\">") != null);
    try testing.expect(std.mem.indexOf(u8, about, "<link rel=\"canonical\" href=\"https://example.com/about/\">") != null);
    try testing.expect(std.mem.indexOf(u8, about, "<meta property=\"og:image\" content=\"https://example.com/social/about.png\">") != null);
    try testing.expect(std.mem.indexOf(u8, about, "<meta name=\"twitter:site\" content=\"@handle\">") != null);
    // The card exists and is a PNG.
    try testing.expect(std.mem.startsWith(u8, site.find("social/about.png").?.data.bytes, "\x89PNG"));
    // A page's own image replaces the card; a page without seo gets none.
    try testing.expect(std.mem.indexOf(u8, site.find("photo/index.html").?.data.bytes, "content=\"https://example.com/img/p.jpg\"") != null);
    try testing.expect(site.find("social/photo.png") == null);
    try testing.expect(site.find("social/plain.png") == null);

    try expectBuildError(&.{.{ "_config.yml", "social_card_style: neon\n" }}, "_config.yml", 1, "'social_card_style' must be plain, visor or lcars");
}

test "cardPath" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("social/index.png", try cardPath(a, "index.html"));
    try testing.expectEqualStrings("social/docs/install.png", try cardPath(a, "docs/install/index.html"));
    try testing.expectEqualStrings("social/rendering.png", try cardPath(a, "rendering.html"));
}

test "icons: writes a favicon, app icons and a manifest" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Docs\ntheme: lcars\nicons: true\n" },
        .{ "index.html", "---\n---\n{{ site.icon_tags }}" },
        .{ "icon-512.png", "mine" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const ico = site.find("favicon.ico").?.data.bytes;
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, ico[4..6], .little));
    try testing.expect(std.mem.startsWith(u8, site.find("apple-touch-icon.png").?.data.bytes, "\x89PNG"));
    // The site's own file wins.
    try testing.expect(site.find("icon-512.png").?.data == .copy);
    try testing.expect(std.mem.indexOf(u8, site.find("site.webmanifest").?.data.bytes, "\"theme_color\": \"#000000\"") != null);
    try testing.expect(std.mem.startsWith(u8, site.find("index.html").?.data.bytes, "<link rel=\"icon\" href=\"/favicon.ico\""));

    try expectBuildError(&.{.{ "_config.yml", "title: T\nicons:\n  colour: \"#fff\"\n" }}, "_config.yml", 2, "icons: 'colour' is not an icons setting");
}

test "gzip: true writes .gz copies of large text files" {
    const big = "x " ** 600;
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "gzip: true\n" },
        .{ "big.md", big ++ "\n" },
        .{ "small.md", "small\n" },
        .{ "css/site.css", "body{}" ++ " " ** 2000 },
        .{ "img.png", big },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expect(site.gzip);
    try writeOutputDir(site, src, &diag);
    const a = t.arena.allocator();
    const gz = try src.readFile(a, "_site/big/index.html.gz");
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b }, gz[0..2]);
    _ = try src.readFile(a, "_site/css/site.css.gz");
    try testing.expectError(error.FileNotFound, src.readFile(a, "_site/small/index.html.gz"));
    try testing.expectError(error.FileNotFound, src.readFile(a, "_site/img.png.gz"));

    try expectBuildError(&.{.{ "_config.yml", "title: T\ngzip: yes\n" }}, "_config.yml", 2, "'gzip' must be true or false");
}

test "search: true writes an index of page sections and the client" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "search: true\n" },
        .{ "_layouts/base.html", "<header>Site</header><main>{{ content }}</main>{{ site.search_box }}" },
        .{ "guide.md", "---\ntitle: Guide\nlayout: base\n---\nIntro text.\n\n## Install zig\n\nDownload it.\n" },
        .{ "about.html", "---\ntitle: About\nlayout: base\n---\n<p>We build things.</p>" },
        .{ "hidden.md", "---\nsearch: false\n---\nSecret.\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    const index = site.find("search-index.json").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, index, "[\"Guide \u{203a} Install zig\",\"/guide/#install-zig\",\"Download it.\",") != null);
    try testing.expect(std.mem.indexOf(u8, index, "[\"About\",\"/about.html\",\"We build things.\",") != null);
    try testing.expect(std.mem.indexOf(u8, index, "ecret") == null);
    // The header is not part of a template page's text.
    try testing.expect(std.mem.indexOf(u8, index, "\"site\"") == null);
    try testing.expect(site.find("search.js") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("guide/index.html").?.data.bytes, "data-index=\"/search-index.json\"") != null);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, t.arena.allocator(), index, .{});
}

test "templates extend layouts and fill their blocks" {
    var t: TestSite = try .init(&.{
        .{ "_layouts/base.html", "<title>{% block title %}{{ site.title }}{% endblock %}</title><main>{% block main %}{{ content }}{% endblock %}</main>" },
        .{ "_layouts/wide.html", "{% extends \"base\" %}{% block main %}<div class=\"wide\">{{ super }}</div>{% endblock %}" },
        .{ "_config.yml", "title: Site\n" },
        .{ "a.md", "---\nlayout: wide\n---\nA\n" },
        .{ "b.html", "---\n---\n{% extends \"base.html\" %}{% block title %}B | {{ super }}{% endblock %}{% block main %}<p>B</p>{% endblock %}" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try testing.expectEqualStrings("<title>Site</title><main><div class=\"wide\"><p>A</p>\n</div></main>", site.find("a/index.html").?.data.bytes);
    try testing.expectEqualStrings("<title>B | Site</title><main><p>B</p></main>", site.find("b.html").?.data.bytes);
    // The parent layout is a dependency of pages that extend it.
    for (site.deps) |d| {
        if (!std.mem.eql(u8, d.output, "b.html")) continue;
        try testing.expect(usesAny(d.sources, &.{"_layouts/base.html"}));
    }

    try expectBuildError(&.{.{ "x.html", "---\n---\n{% extends \"missing\" %}" }}, "x.html", 3, "the layout 'missing' to extend was not found");
}
