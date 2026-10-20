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
const fm_defaults = @import("defaults.zig");
const collections = @import("collections.zig");
const permalink = @import("permalink.zig");
const yaml = @import("yaml.zig");
const template = @import("template.zig");
const feeds = @import("feeds.zig");
const gzip = @import("gzip.zig");
const search = @import("search.zig");
const minify = @import("minify.zig");
const llms = @import("llms.zig");
const i18n = @import("i18n.zig");
const Language = i18n.Language;
const fonts = @import("fonts.zig");
const data_files = @import("data.zig");
const schema = @import("schema.zig");
const openapi = @import("openapi.zig");
const themes = @import("themes.zig");
const tokens = @import("tokens.zig");
const icons = @import("icons.zig");
const assets = @import("assets.zig");
const redirects = @import("redirects.zig");
const git = @import("git.zig");
const seo = @import("seo.zig");
const images = @import("images.zig");
const links = @import("links.zig");
const datetime = @import("datetime.zig");
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
    /// `minify: true`: writing the site minifies HTML and CSS (minify.zig).
    minify: bool = false,
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
    defaults: []const fm_defaults.Default,
    collections: []const collections.Collection,
    baseurl: []const u8,
    site_url: ?[]const u8,
    options: Options,
    data: Value,
    history: History,
    schemas: std.StringArrayHashMapUnmanaged(schema.Schema),
    /// Every page and post, in `pageOrder`.
    pages: []const Page,
    /// Files copied unchanged.
    statics: []const Output,
};

pub const Page = struct {
    source: []const u8,
    is_post: bool,
    /// The collection holding the page (Liquid mode), such as `recipes`
    /// for `_recipes/a.md`.
    collection: ?[]const u8 = null,
    /// A document of a collection without `output: true`: listed in
    /// `site.LABEL` but not written. Such pages come last in a build's
    /// list.
    hidden: bool = false,
    /// A post's categories (Liquid mode), from `categories` and `category`.
    categories: ?[]const []const u8 = null,
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
    /// The Markdown's HTML with its wikilinks unresolved, when it has any;
    /// `html` holds them resolved against the current set of pages.
    wikilink_html: ?[]const u8 = null,
    /// URLs of the site's pages this page's Markdown links to, for
    /// backlinks.
    link_targets: []const []const u8 = &.{},
    /// Index of the page's language in `Builder.languages` (0, the default
    /// language, on one-language sites).
    lang: u8 = 0,
    /// What the page's translations share: its path without the language.
    translation_key: []const u8 = "",
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
    /// Whether the page loads `markdown.copy_script` for its copy buttons.
    uses_copy_script: bool = false,
    /// The page's search sections, kept from the render that produced
    /// `output` (see search.zig).
    search_sections: []const search.Section = &.{},
    /// Static files the page's templates named with the `asset` filter.
    assets_used: []const []const u8 = &.{},
    /// Resized images its `<img>` tags refer to.
    image_variants: []const images.Variant = &.{},
    /// With `liquid: true`, what running Liquid in the Markdown body read;
    /// added to `sources`, `reads_collections` and `assets_used`.
    body_sources: []const []const u8 = &.{},
    body_reads_collections: bool = false,
    body_assets: []const []const u8 = &.{},
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
    /// Whether the current page loads the copy-button script.
    uses_copy_script: bool = false,
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
    /// `defaults:` from the config (Liquid mode).
    defaults: []const fm_defaults.Default = &.{},
    /// `collections:` from the config (Liquid mode).
    collections: []const collections.Collection = &.{},
    /// The `permalink:` template for posts (Liquid mode), from the config.
    permalink: ?[]const u8 = null,
    history: History = .{},
    /// The config as a template value, for shortcodes, which render while
    /// pages load, before `site` is complete.
    site_config: Value = .{ .object = .{} },
    /// `site.data`, from the files in `_data/`.
    data: Value = .{ .object = .{} },
    /// Frontmatter schemas from `_schemas/`, by name.
    schemas: std.StringArrayHashMapUnmanaged(schema.Schema) = .empty,
    /// The site's languages from `languages:`, default first; empty for a
    /// one-language site.
    languages: []const Language = &.{},
    /// The `paginator` variable while rendering one page of a paginated
    /// page, or null.
    paginator: ?template.Object = null,
    /// Whether templates fail on undefined variables.
    strict: bool = false,
    /// The site's design tokens, or null without a theme or theme_tokens.
    token_set: ?tokens.Set = null,
    /// The theme named by `theme:` and its bases, most derived first.
    theme_chain: []const ThemeLayer = &.{},
    warnings: std.ArrayList(Diagnostic) = .empty,
    /// Files copied unchanged, for the `asset` filter.
    statics: []const Output = &.{},
    /// Hashes of static files named by the `asset` and `sri` filters.
    asset_info: std.StringHashMapUnmanaged(AssetInfo) = .empty,
    /// Static files the current page named with `asset`.
    page_assets: std.ArrayList([]const u8) = .empty,
    /// Write `asset` files under names with their content hash.
    fingerprint: bool = false,
    /// `site.menus`, which generated pages also see as `page.menus`.
    menus: Value = .{ .object = .{} },
    /// `images:` from the config.
    images: images.Config = .{},
    /// Static outputs by path, for completing `<img>` tags.
    static_outputs: std.StringHashMapUnmanaged(Output) = .empty,
    /// Image headers read during this build, by output path.
    image_infos: std.StringHashMapUnmanaged(?images.Info) = .empty,
    /// Resized images the page being rendered refers to.
    page_variants: std.ArrayList(images.Variant) = .empty,
    /// Set by `links.resolve` when a wikilink is ambiguous.
    link_error: links.Failure = .{},
    /// `liquid: true` in the config: templates and Markdown bodies are
    /// Liquid, as in Jekyll.
    liquid: bool = false,
    /// The build's time, for `site.time` and `"now" | date`, in seconds
    /// since the Unix epoch.
    now: i64 = 0,
    /// Every page and post, for `{% link %}` and `{% post_url %}`.
    pages: []const Page = &.{},
    /// While Liquid runs in a Markdown body: HTML kept out of Markdown.
    stash: ?*std.ArrayList([]const u8) = null,

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

    /// How templates are parsed: as Liquid in Liquid mode, knowing the
    /// collections.
    fn parseOptions(b: *const Builder) Allocator.Error!template.ParseOptions {
        const labels = try b.arena.alloc([]const u8, b.collections.len);
        for (b.collections, labels) |c, *l| l.* = c.label;
        return .{ .liquid = b.liquid, .collections = labels };
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
    /// Name files linked with the `asset` filter by their content hash
    /// (`css/site.3f9a1c2b.css`), unless `fingerprint: false` in the
    /// config. `build` sets this; `serve` keeps plain names so stylesheet
    /// hot-swapping works.
    fingerprint: bool = false,
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
    /// Config settings that replace or add to those in `_config.yml`, for
    /// tools that build one site several ways (such as the theme gallery).
    config: []const frontmatter.Entry = &.{},
    /// Shrink the fonts listed under `fonts: subset:` to the characters
    /// the site uses. `mortise build` turns this on; the dev server serves
    /// whole fonts, so new text never misses a glyph while editing.
    subset_fonts: bool = false,
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
    if (options.config.len > 0) config_fields = try overrideConfig(arena, config_fields, options.config);
    b.baseurl = try baseUrl(&b, config_fields);
    b.site_url = try siteUrl(&b, config_fields);
    b.markdown_options = try markdownOptions(&b, config_fields);
    b.liquid = try configFlag(&b, config_fields, "liquid", false);
    b.permalink = try sitePermalink(&b, config_fields);
    b.future = try showFuture(&b, config_fields);
    b.history = try loadHistory(&b, config_fields, listing.files);
    b.site_config = try convert(arena, .{ .map = config_fields });
    b.languages = try loadLanguages(&b, config_fields);
    b.data = try loadData(&b, listing.files);
    b.schemas = try loadSchemas(&b, listing.files);

    // Pages load in parallel once every file is sorted; everything else
    // is quick and happens here in order.
    var jobs: std.ArrayList(LoadJob) = .empty;
    var render_jobs: std.ArrayList(assets.Job) = .empty;
    var render_paths: std.ArrayList([]const u8) = .empty;
    for (listing.files) |path| {
        if (std.mem.eql(u8, path, config_path)) continue;
        if (std.mem.startsWith(u8, path, "_posts/")) {
            if (!std.mem.eql(u8, sitepath.extension(path), ".md")) continue;
            try jobs.append(arena, .{ .path = path, .is_post = true });
            continue;
        }
        if (openapi.isSpec(path)) {
            try pages.append(arena, try loadApiPage(&b, path));
            continue;
        }
        if (assets.isSpec(path)) {
            try render_jobs.append(arena, .{ .name = assets.outputStem(path), .source = try b.read(path) });
            try render_paths.append(arena, path);
            continue;
        }
        if (collections.find(b.collections, path)) |c| {
            // Documents have front matter; other files are copied, as in
            // Jekyll, when the collection is published.
            const ext = sitepath.extension(path);
            if (std.mem.eql(u8, ext, ".md") or (std.mem.eql(u8, ext, ".html") and try startsWithFrontmatter(&b, path))) {
                try jobs.append(arena, .{ .path = path, .is_post = false });
            } else if (c.output and !sitepath.hasHiddenComponent(path[1..])) {
                try statics.append(arena, .{ .path = path[1..], .source = path, .data = .copy });
            }
            continue;
        }
        if (sitepath.hasHiddenComponent(path)) continue;

        const ext = sitepath.extension(path);
        if (std.mem.eql(u8, ext, ".md") or (std.mem.eql(u8, ext, ".html") and try startsWithFrontmatter(&b, path))) {
            try jobs.append(arena, .{ .path = path, .is_post = false });
        } else {
            try statics.append(arena, .{ .path = path, .source = path, .data = .copy });
        }
    }
    // Render specs are independent, so they draw concurrently.
    try renderSpecs(&b, &statics, render_jobs.items, render_paths.items);
    loadPages(&b, jobs.items);
    // The first failure in listing order is the one reported, whichever
    // worker met it first.
    for (jobs.items) |*job| {
        const page = job.result catch |err| {
            b.diag.* = job.diag;
            return err;
        };
        if (page) |p| try pages.append(arena, p);
        b.skipped.drafts += job.skipped.drafts;
        b.skipped.future += job.skipped.future;
        b.skipped.expired += job.skipped.expired;
    }
    std.mem.sortUnstable(Page, pages.items, {}, pageOrder);
    return finish(&b, config_fields, try hiddenLast(arena, pages.items), statics.items, null);
}

/// Moves documents of unpublished collections to the end, keeping the
/// order otherwise, so that the pages written are a prefix of the list.
fn hiddenLast(arena: Allocator, pages: []Page) Allocator.Error![]Page {
    var hidden: std.ArrayList(Page) = .empty;
    var n: usize = 0;
    for (pages) |p| {
        if (p.hidden) {
            try hidden.append(arena, p);
        } else {
            pages[n] = p;
            n += 1;
        }
    }
    @memcpy(pages[n..], hidden.items);
    return pages;
}

/// How many pages of `pages` (from `hiddenLast`) are written.
fn shownCount(pages: []const Page) usize {
    var n = pages.len;
    while (n > 0 and pages[n - 1].hidden) n -= 1;
    return n;
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
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag, .baseurl = st.baseurl, .site_url = st.site_url, .data = st.data, .options = st.options, .skipped = st.skipped, .history = st.history, .schemas = st.schemas };
    b.defaults = st.defaults;
    b.collections = st.collections;
    b.markdown_options = try markdownOptions(&b, st.config_fields);
    b.liquid = try configFlag(&b, st.config_fields, "liquid", false);
    b.permalink = try sitePermalink(&b, st.config_fields);
    b.future = try showFuture(&b, st.config_fields);
    b.site_config = try convert(arena, .{ .map = st.config_fields });
    b.languages = try loadLanguages(&b, st.config_fields);

    var dirty_templates: std.ArrayList([]const u8) = .empty;
    var dirty_pages: std.ArrayList(usize) = .empty;
    for (changed) |path| {
        // The config and data files feed `site`, which any page may read.
        // Render specs are cheap to rebuild from scratch thanks to the
        // render cache, which keeps every unchanged asset.
        if (std.mem.eql(u8, path, config_path) or std.mem.eql(u8, path, "*") or
            std.mem.startsWith(u8, path, data_files.dir_prefix) or
            std.mem.startsWith(u8, path, assets.dir_prefix) or
            std.mem.startsWith(u8, path, schema.dir_prefix) or
            // A site theme can change any page.
            std.mem.startsWith(u8, path, "_themes/") or
            // Shortcodes render into page content when pages load.
            std.mem.startsWith(u8, path, "_includes/shortcodes/")) return buildWith(arena, src, st.options, diag);
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
            // Pages that link it with the asset filter show its hash.
            // Pages showing an image depend on its size.
            try dirty_templates.append(arena, path);
            continue;
        }
        // Unpublished files such as `_drafts/` never affect the output, as
        // long as they are not new pages in disguise.
        // A new API spec adds a page.
        if (openapi.isSpec(path)) return buildWith(arena, src, st.options, diag);
        // A new or removed document, or a file a collection copies.
        if (collections.find(b.collections, path) != null) return buildWith(arena, src, st.options, diag);
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
            (dirty_pages.items.len > 0 and (p.reads_collections or p.wikilink_html != null)) or
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

/// Reads `_config.yml`, its `defaults:` into `b.defaults` and its
/// `collections:` into `b.collections`.
fn loadConfig(b: *Builder) Error!frontmatter.Map {
    // `defaults:` and the mapping form of `collections:` nest deeper than
    // the frontmatter subset, so they are read on their own.
    const split = try yaml.takeBlock(b.arena, try b.read(config_path), "defaults");
    const coll_split = try yaml.takeBlock(b.arena, split.rest, "collections");
    var fd: frontmatter.Diagnostic = .{};
    const fields = frontmatter.parseFile(b.arena, coll_split.rest, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(config_path, fd.line, "{s}", .{fd.message}),
    };
    const liquid = try configFlag(b, fields, "liquid", false);
    if (split.block) |block| {
        if (!liquid) {
            return b.fail(config_path, split.line, "'defaults' needs 'liquid: true'; Mortise sites give fields defaults with 'default:' rules in _schemas/", .{});
        }
        var dd: fm_defaults.Diagnostic = .{};
        b.defaults = fm_defaults.parse(b.arena, block, split.line, &dd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidDefaults => return b.fail(config_path, dd.line, "{s}", .{dd.message}),
        };
    }
    var cd: collections.Diagnostic = .{};
    const coll_line = if (coll_split.block != null) coll_split.line else fieldLine(try b.read(config_path), "collections");
    if (coll_split.block != null or fields.get("collections") != null) {
        if (!liquid) {
            return b.fail(config_path, coll_line, "'collections' needs 'liquid: true'; Mortise sites publish any folder not starting with '_' as pages", .{});
        }
    }
    if (coll_split.block) |block| {
        b.collections = collections.parse(b.arena, block, coll_split.line, &cd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCollections => return b.fail(config_path, cd.line, "{s}", .{cd.message}),
        };
    } else if (fields.get("collections")) |v| {
        const msg = "'collections' must list names such as [recipes, staff]";
        if (v != .list) return b.fail(config_path, coll_line, msg, .{});
        const names = try b.arena.alloc([]const u8, v.list.len);
        for (v.list, names) |item, *n| {
            if (item != .string) return b.fail(config_path, coll_line, msg, .{});
            n.* = item.string;
        }
        b.collections = collections.fromNames(b.arena, names, coll_line, &cd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCollections => return b.fail(config_path, cd.line, "{s}", .{cd.message}),
        };
    }
    for (b.collections) |c| if (c.permalink) |pl| {
        if (permalink.style(pl) == null and !std.mem.startsWith(u8, pl, "/")) {
            return b.fail(config_path, coll_line, "collection '{s}': 'permalink' must start with '/', such as /:collection/:name/", .{c.label});
        }
    };
    return fields;
}

/// The config's `permalink:` (Liquid mode): a style such as `pretty`, or
/// a template such as `/:categories/:title/`.
fn sitePermalink(b: *Builder, config_fields: frontmatter.Map) Error!?[]const u8 {
    if (!b.liquid) return null;
    const v = config_fields.get("permalink") orelse return null;
    const msg = "'permalink' must be date, pretty, ordinal, weekdate, none, or a template starting with '/', such as /:categories/:title/";
    if (v != .string) return b.fail(config_path, fieldLine(try b.read(config_path), "permalink"), msg, .{});
    if (permalink.style(v.string)) |t| return t;
    if (!std.mem.startsWith(u8, v.string, "/")) return b.fail(config_path, fieldLine(try b.read(config_path), "permalink"), msg, .{});
    return v.string;
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

/// Loads `_schemas/NAME.yml` files, keyed by NAME.
fn loadSchemas(b: *Builder, files: []const []const u8) Error!std.StringArrayHashMapUnmanaged(schema.Schema) {
    var out: std.StringArrayHashMapUnmanaged(schema.Schema) = .empty;
    for (files) |path| {
        if (!std.mem.startsWith(u8, path, schema.dir_prefix) or !std.mem.endsWith(u8, path, ".yml")) continue;
        const name = path[schema.dir_prefix.len .. path.len - ".yml".len];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        const data = try b.read(path);
        var fd: frontmatter.Diagnostic = .{};
        const map = frontmatter.parseFile(b.arena, data, &fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
        };
        var d: schema.Diagnostic = .{};
        const s = schema.parse(b.arena, path, map, &d) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidSchema => return b.fail(path, fieldLine(data, d.key), "'{s}' {s}", .{ d.key, d.message }),
        };
        try out.put(b.arena, name, s);
    }
    return out;
}

/// Checks a page's frontmatter against its schema, filling in defaults:
/// `posts` for posts, the schema named like the page's top directory
/// when there is one, else `pages`.
fn applySchema(b: *Builder, path: []const u8, data: []const u8, is_post: bool, fields: *frontmatter.Map) Error!void {
    if (b.schemas.count() == 0) return;
    const name = if (is_post) "posts" else blk: {
        if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
            if (b.schemas.contains(path[0..slash])) break :blk path[0..slash];
        }
        break :blk "pages";
    };
    const s = b.schemas.get(name) orelse return;
    var out: frontmatter.Map = .{};
    if (try schema.check(b.arena, s, fields.*, &out)) |p| {
        // A missing field is reported at the frontmatter's start.
        return b.fail(path, if (p.missing) 1 else fieldLine(data, p.key), "{s}", .{p.message});
    }
    fields.* = out;
}

/// `languages:` from the config, with `default_language:` (or the first one)
/// moved to the front.
fn loadLanguages(b: *Builder, config_fields: frontmatter.Map) Error![]const Language {
    const v = config_fields.get("languages") orelse {
        if (config_fields.get("default_language") != null) {
            return b.fail(config_path, fieldLine(try b.read(config_path), "default_language"), "'default_language' needs 'languages'", .{});
        }
        return &.{};
    };
    const line = fieldLine(try b.read(config_path), "languages");
    if (v != .map or v.map.entries.len == 0) return b.fail(config_path, line, "'languages' must map codes to names, such as en: English", .{});
    const out = try b.arena.alloc(Language, v.map.entries.len);
    for (v.map.entries, out) |e, *l| {
        if (!i18n.validCode(e.key)) return b.fail(config_path, line, "'{s}' is not a language code; use lowercase letters, digits and '-', such as en or pt-br", .{e.key});
        if (e.value != .string) return b.fail(config_path, line, "language '{s}' needs a name, such as {s}: English", .{ e.key, e.key });
        l.* = .{ .code = e.key, .name = e.value.string };
    }
    if (config_fields.get("default_language")) |d| {
        const dline = fieldLine(try b.read(config_path), "default_language");
        if (d != .string) return b.fail(config_path, dline, "'default_language' must be one of the codes in 'languages'", .{});
        const i = for (out, 0..) |l, i| {
            if (std.mem.eql(u8, l.code, d.string)) break i;
        } else return b.fail(config_path, dline, "'default_language' must be one of the codes in 'languages'", .{});
        // The default goes first; the others keep their order.
        std.mem.rotate(Language, out[0 .. i + 1], i);
    }
    if (out.len > 255) return b.fail(config_path, line, "too many languages", .{});
    return out;
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
    return configFlag(b, config_fields, key, true);
}

/// A true/false setting from the config, `default` when absent.
fn configFlag(b: *Builder, config_fields: frontmatter.Map, key: []const u8, default: bool) Error!bool {
    const v = config_fields.get(key) orelse return default;
    if (v != .boolean) return b.fail(config_path, fieldLine(try b.read(config_path), key), "'{s}' must be true or false", .{key});
    return v.boolean;
}

/// Whether config switch `key` (such as `llms: true`) is on. Defaults off.
fn optIn(b: *Builder, config_fields: frontmatter.Map, key: []const u8) Error!bool {
    const v = config_fields.get(key) orelse return false;
    if (v != .boolean) return b.fail(config_path, fieldLine(try b.read(config_path), key), "'{s}' must be true or false", .{key});
    return v.boolean;
}

/// `llms.txt`, `llms-full.txt` and a Markdown twin of every Markdown page.
/// Pages with `llms: false` in their frontmatter are left out.
fn addLlms(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map, pages: []const Page) Error!void {
    const arena = b.arena;
    var list: std.ArrayList(llms.Page) = .empty;
    for (pages) |*p| {
        if (std.mem.eql(u8, p.out_path, "404.html")) continue;
        if (p.fields.get("llms")) |v| if (v == .boolean and !v.boolean) continue;
        // OpenAPI pages have no Markdown source; their HTML is linked instead.
        const has_markdown = p.is_markdown and p.api == null;
        const page: llms.Page = .{
            .title = stringField(p.fields, "title") orelse "",
            .url = p.url,
            .description = stringField(p.fields, "description") orelse stringField(p.fields, "summary") orelse "",
            .date = p.date,
            .is_post = p.is_post,
            .markdown = if (has_markdown) p.body else null,
        };
        try list.append(arena, page);
        if (has_markdown) {
            const path = try llms.twinPath(arena, p.out_path);
            if (!hasOutput(outputs.items, path)) try outputs.append(arena, .{ .path = path, .source = p.source, .data = .{ .bytes = try llms.twin(arena, page) } });
        }
    }
    const site_url = b.site_url orelse "";
    if (!hasOutput(outputs.items, llms.index_path)) {
        const title = stringField(config_fields, "title") orelse "";
        const description = stringField(config_fields, "description") orelse "";
        try outputs.append(arena, .{ .path = llms.index_path, .source = config_path, .data = .{ .bytes = try llms.index(arena, title, description, site_url, list.items) } });
    }
    if (!hasOutput(outputs.items, llms.full_path)) {
        try outputs.append(arena, .{ .path = llms.full_path, .source = config_path, .data = .{ .bytes = try llms.full(arena, site_url, list.items) } });
    }
}

/// `site.languages`: each language's `{code, name, url}`, the URL being its
/// home page.
fn languageList(arena: Allocator, langs: []const Language, baseurl: []const u8) Allocator.Error!Value {
    const out = try arena.alloc(Value, langs.len);
    for (langs, out, 0..) |l, *o, i| {
        const e = try arena.alloc(Entry, 3);
        e[0] = .{ .key = "code", .value = .{ .string = l.code } };
        e[1] = .{ .key = "name", .value = .{ .string = l.name } };
        e[2] = .{ .key = "url", .value = .{ .string = if (i == 0) try std.fmt.allocPrint(arena, "{s}/", .{baseurl}) else try std.fmt.allocPrint(arena, "{s}/{s}/", .{ baseurl, l.code }) } };
        o.* = .{ .object = .{ .entries = e } };
    }
    return .{ .list = out };
}

/// Adds `page.lang` (the language's code) and `page.translations` to every
/// page: the same page in the other languages, each `{code, name, url}`,
/// in the order of `languages:`.
fn addTranslations(arena: Allocator, pages: []Page, langs: []const Language) Allocator.Error!void {
    var by_key: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (pages, 0..) |p, i| {
        const gop = try by_key.getOrPut(arena, p.translation_key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, i);
    }
    for (pages, 0..) |*p, i| {
        var list: std.ArrayList(Value) = .empty;
        for (langs, 0..) |l, li| {
            if (li == p.lang) continue;
            for (by_key.get(p.translation_key).?.items) |j| {
                if (j == i or pages[j].lang != li) continue;
                const e = try arena.alloc(Entry, 3);
                e[0] = .{ .key = "code", .value = .{ .string = l.code } };
                e[1] = .{ .key = "name", .value = .{ .string = l.name } };
                e[2] = .{ .key = "url", .value = .{ .string = pages[j].url } };
                try list.append(arena, .{ .object = .{ .entries = e } });
                break;
            }
        }
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.object.entries);
        try entries.append(arena, .{ .key = "lang", .value = .{ .string = langs[p.lang].code } });
        try entries.append(arena, .{ .key = "translations", .value = .{ .list = list.items } });
        p.object = .{ .entries = entries.items };
    }
}

/// Replaces each font under `fonts: subset:` with a copy holding only the
/// characters of the site's pages, printable ASCII, and `fonts: keep:`.
fn subsetFonts(b: *Builder, all_outputs: *std.ArrayList(Output), config_fields: frontmatter.Map) Error!void {
    const v = config_fields.get("fonts") orelse return;
    const arena = b.arena;
    const outputs = all_outputs.items;
    const line = fieldLine(try b.read(config_path), "fonts");
    if (v != .map) return b.fail(config_path, line, "'fonts' must hold settings such as 'subset: [fonts/inter.ttf]'", .{});
    var paths: []const frontmatter.Value = &.{};
    var keep: []const u8 = "";
    var woff2 = false;
    for (v.map.entries) |e| {
        if (std.mem.eql(u8, e.key, "subset")) {
            paths = if (e.value == .list) e.value.list else if (e.value == .string) &.{e.value} else return b.fail(config_path, line, "'fonts.subset' must list font files", .{});
        } else if (std.mem.eql(u8, e.key, "keep")) {
            keep = if (e.value == .string) e.value.string else return b.fail(config_path, line, "'fonts.keep' must be text", .{});
        } else if (std.mem.eql(u8, e.key, "woff2")) {
            woff2 = if (e.value == .boolean) e.value.boolean else return b.fail(config_path, line, "'fonts.woff2' must be true or false", .{});
        } else return b.fail(config_path, line, "unknown font setting '{s}'; use subset, keep or woff2", .{e.key});
    }
    // Check the list on every build, so a typo shows up in `serve` too.
    for (paths) |p| {
        if (p != .string) return b.fail(config_path, line, "'fonts.subset' must list font files", .{});
        const path = std.mem.trimStart(u8, p.string, "/");
        const found = for (outputs) |o| {
            if (std.mem.eql(u8, o.path, path) and o.data == .copy) break true;
        } else false;
        if (!found) return b.fail(config_path, line, "font '{s}' in 'fonts.subset' is not a file of the site", .{p.string});
    }
    if (!b.options.subset_fonts or paths.len == 0) return;

    var chars: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
    for (32..127) |c| try chars.put(arena, @intCast(c), {});
    try fonts.collectText(arena, keep, &chars);
    for (outputs) |o| {
        if (!std.mem.endsWith(u8, o.path, ".html") and !std.mem.endsWith(u8, o.path, ".htm")) continue;
        const html = switch (o.data) {
            .bytes => |bytes| bytes,
            .copy => try b.read(o.source),
        };
        try fonts.collectText(arena, html, &chars);
    }
    for (paths) |p| {
        const path = std.mem.trimStart(u8, p.string, "/");
        for (outputs) |*o| {
            if (!std.mem.eql(u8, o.path, path) or o.data != .copy) continue;
            var fd: fonts.Diagnostic = .{};
            const small = fonts.subset(arena, try b.read(o.source), chars.keys(), &fd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return b.fail(o.source, 0, "cannot subset this font: {s}", .{fd.message}),
            };
            o.data = .{ .bytes = small };
        }
    }
    if (!woff2) return;
    // A WOFF2 copy of each subset font, beside it.
    for (paths) |p| {
        const path = std.mem.trimStart(u8, p.string, "/");
        const ext = sitepath.extension(path);
        // A WOFF2 font is written as WOFF2 already.
        if (std.mem.eql(u8, ext, ".woff2")) continue;
        const woff2_path = try std.mem.concat(arena, u8, &.{ path[0 .. path.len - ext.len], ".woff2" });
        if (hasOutput(all_outputs.items, woff2_path)) return b.fail(config_path, line, "'fonts.woff2' would write {s}, which the site already has", .{woff2_path});
        const o = for (all_outputs.items) |o| {
            if (std.mem.eql(u8, o.path, path)) break o;
        } else unreachable;
        var fd: fonts.Diagnostic = .{};
        const converted = fonts.toWoff2(arena, o.data.bytes, &fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return b.fail(o.source, 0, "cannot write this font as WOFF2: {s}", .{fd.message}),
        };
        try all_outputs.append(arena, .{ .path = woff2_path, .source = o.source, .data = .{ .bytes = converted } });
    }
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

/// Writes the copy-button script when a page loads it, unless the site has
/// its own file at that path.
fn addCopyScript(b: *Builder, outputs: *std.ArrayList(Output), pages: []const Page) Error!void {
    // Generated pages, such as tag pages, render after the pages and leave
    // their answer in the builder.
    const used = b.uses_copy_script or for (pages) |p| {
        if (p.uses_copy_script) break true;
    } else false;
    if (!used or hasOutput(outputs.items, markdown.copy_script_path)) return;
    try outputs.append(b.arena, .{ .path = markdown.copy_script_path, .source = config_path, .data = .{ .bytes = markdown.copy_script } });
}

/// Writes `/theme.css`: the design tokens, then the stylesheet of the
/// theme named by `theme:` in the config, unless the site has its own
/// file at that path.
fn addThemeCss(b: *Builder, outputs: *std.ArrayList(Output)) Error!void {
    const set = b.token_set orelse return;
    const line = fieldLine(try b.read(config_path), "theme");
    // A theme's images replace its base's images of the same name.
    for (b.theme_chain) |layer| try addThemeAssets(b, outputs, layer, line);
    if (hasOutput(outputs.items, themes.css_path)) return;
    // Base stylesheets come first so the derived theme's rules win; every
    // layer's @import rules move to the top, where CSS requires them.
    var imports: std.ArrayList(u8) = .empty;
    var rules: std.ArrayList(u8) = .empty;
    var i = b.theme_chain.len;
    while (i > 0) {
        i -= 1;
        const css = b.theme_chain[i].css;
        const split = importsEnd(css);
        try imports.appendSlice(b.arena, css[0..split]);
        try rules.appendSlice(b.arena, css[split..]);
    }
    const token_css = try tokens.css(b.arena, set);
    const all_css = try std.mem.concat(b.arena, u8, &.{ imports.items, if (imports.items.len > 0) "\n" else "", token_css, "\n", rules.items });
    try outputs.append(b.arena, .{ .path = themes.css_path, .source = config_path, .data = .{ .bytes = all_css } });
}

/// One theme of the chain a site uses: the theme it names, then that
/// theme's base, and so on.
const ThemeLayer = struct {
    name: []const u8,
    css: []const u8 = "",
    tokens: []const u8 = "",
    assets: []const themes.Asset = &.{},
    /// A built-in theme's layouts and includes.
    files: []const themes.File = &.{},
    /// A site theme's directory, `_themes/NAME/`, holding its files.
    dir: ?[]const u8 = null,
};

/// The most themes a chain may hold.
const max_theme_depth = 8;

/// The themes named by `theme:` and their bases, most derived first: a
/// site theme in `_themes/NAME/` when there is one, else a built-in.
fn themeChain(b: *Builder, config_fields: frontmatter.Map) Error![]const ThemeLayer {
    const v = config_fields.get("theme") orelse return &.{};
    const line = fieldLine(try b.read(config_path), "theme");
    if (v != .string) return b.fail(config_path, line, "'theme' must be the name of a theme: {s}", .{themes.names});
    var chain: std.ArrayList(ThemeLayer) = .empty;
    var name: ?[]const u8 = v.string;
    while (name) |n| {
        if (chain.items.len >= max_theme_depth) return b.fail(config_path, line, "themes build on each other more than {d} deep (does '{s}' build on itself?)", .{ max_theme_depth, n });
        const dir = try std.fmt.allocPrint(b.arena, "_themes/{s}/", .{n});
        const manifest = try std.mem.concat(b.arena, u8, &.{ dir, "theme.yml" });
        if (sitepath.isNormalized(manifest) and b.exists(manifest)) {
            var fd: frontmatter.Diagnostic = .{};
            const fields = frontmatter.parseFile(b.arena, try b.read(manifest), &fd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFrontmatter => return b.fail(manifest, fd.line, "{s}", .{fd.message}),
            };
            var layer: ThemeLayer = .{ .name = n, .dir = dir };
            const css_file = try std.mem.concat(b.arena, u8, &.{ dir, "theme.css" });
            if (b.exists(css_file)) layer.css = try b.read(css_file);
            const tokens_file = try std.mem.concat(b.arena, u8, &.{ dir, "tokens.yml" });
            if (b.exists(tokens_file)) layer.tokens = try b.read(tokens_file);
            try chain.append(b.arena, layer);
            name = null;
            if (fields.get("base")) |base| {
                if (base != .string) return b.fail(manifest, fieldLine(try b.read(manifest), "base"), "'base' must be the name of a theme", .{});
                name = base.string;
            }
            continue;
        }
        const t = themes.find(n) orelse {
            if (chain.items.len == 0) return b.fail(config_path, line, "unknown theme '{s}'; the themes are: {s}, or a site theme in _themes/NAME/theme.yml", .{ n, themes.names });
            const last = chain.items[chain.items.len - 1];
            return b.fail(try std.mem.concat(b.arena, u8, &.{ last.dir orelse "", "theme.yml" }), 0, "theme '{s}' builds on '{s}', which is not a theme", .{ last.name, n });
        };
        if (t.hidden and chain.items.len == 0) return b.fail(config_path, line, "unknown theme '{s}'; the themes are: {s}", .{ n, themes.names });
        try chain.append(b.arena, .{ .name = t.name, .css = t.css, .tokens = t.tokens, .assets = t.assets, .files = t.files });
        name = t.base;
    }
    return chain.items;
}

const ThemeFile = struct { data: []const u8, source: []const u8 };

/// A layout or include (`_layouts/post.html`) from the site's theme chain:
/// its contents and the path to report and track it by.
fn themeFile(b: *Builder, path: []const u8) Error!?ThemeFile {
    for (b.theme_chain) |layer| {
        if (layer.dir) |dir| {
            const p = try std.mem.concat(b.arena, u8, &.{ dir, path });
            if (b.exists(p)) return .{ .data = try b.read(p), .source = p };
        } else for (layer.files) |f| {
            if (std.mem.eql(u8, f.path, path)) return .{ .data = f.data, .source = try std.fmt.allocPrint(b.arena, "(theme {s}) {s}", .{ layer.name, path }) };
        }
    }
    return null;
}

/// The end of the leading `@import` rules (and comments around them).
fn importsEnd(css: []const u8) usize {
    var pos: usize = 0;
    var i: usize = 0;
    while (i < css.len) {
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
    return pos;
}

/// The design tokens of the theme chain, base first, with `theme_tokens:`
/// from the config applied, or null for a site with neither. Warns about
/// low contrast.
fn tokenSet(b: *Builder, config_fields: frontmatter.Map) Error!?tokens.Set {
    const overrides = config_fields.get("theme_tokens");
    if (b.theme_chain.len == 0 and overrides == null) return null;
    var d: tokens.Diagnostic = .{};
    var set: tokens.Set = .{ .scheme = .both, .tokens = &.{} };
    var first = true;
    var i = b.theme_chain.len;
    while (i > 0) {
        i -= 1;
        const t = b.theme_chain[i];
        if (t.tokens.len == 0) continue;
        const where = if (t.dir) |dir| try std.mem.concat(b.arena, u8, &.{ dir, "tokens.yml" }) else config_path;
        var fd: frontmatter.Diagnostic = .{};
        const fields = frontmatter.parseFile(b.arena, t.tokens, &fd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidFrontmatter => return b.fail(where, fd.line, "theme '{s}' has broken tokens: {s}", .{ t.name, fd.message }),
        };
        const result = if (first) tokens.parse(b.arena, fields, &d) else tokens.override(b.arena, set, fields, &d);
        set = result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTokens => return b.fail(where, 0, "theme '{s}' has a broken token '{s}': {s}", .{ t.name, d.key, d.message }),
        };
        first = false;
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

/// Renders a theme's images into `/theme/`, except those the site
/// replaces with its own file.
fn addThemeAssets(b: *Builder, outputs: *std.ArrayList(Output), theme: ThemeLayer, line: usize) Error!void {
    var jobs: std.ArrayList(assets.Job) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    for (theme.assets) |a| {
        const name = try std.fmt.allocPrint(b.arena, "{s}/{s}", .{ themes.assets_dir, a.name });
        const png = try std.fmt.allocPrint(b.arena, "{s}.png", .{name});
        if (hasOutput(outputs.items, png)) continue;
        try jobs.append(b.arena, .{ .name = name, .source = a.spec });
        try names.append(b.arena, a.name);
    }
    assets.renderMany(b.options.render_cache, b.arena, b.src.io, jobs.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => for (jobs.items, names.items) |j, name| {
            if (j.diag.message.len > 0) return b.fail(config_path, line, "theme '{s}', asset '{s}', line {d}: {s}", .{ theme.name, name, j.diag.line, j.diag.message });
        } else return b.fail(config_path, line, "theme '{s}': cannot render an asset", .{theme.name}),
    };
    for (jobs.items) |j| try appendRendered(b, outputs, config_path, j.name, j.result);
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
    // Every size draws concurrently: the .ico's images first, then the PNGs.
    const want_ico = !hasOutput(outputs.items, icons.ico_path);
    var jobs: std.ArrayList(assets.Job) = .empty;
    if (want_ico) for (icons.ico_sizes) |size| {
        try jobs.append(arena, .{ .name = try std.fmt.allocPrint(arena, "favicon-{d}", .{size}), .source = try icons.spec(arena, c, size) });
    };
    const first_png = jobs.items.len;
    for (icons.pngs) |p| {
        if (hasOutput(outputs.items, p.path)) continue;
        try jobs.append(arena, .{ .name = p.path, .source = try icons.spec(arena, c, p.size) });
    }
    assets.renderMany(b.options.render_cache, arena, b.src.io, jobs.items) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => {
            const msg = for (jobs.items) |j| {
                if (j.diag.message.len > 0) break j.diag.message;
            } else "invalid spec";
            return b.fail(config_path, fieldLine(try b.read(config_path), "icons"), "cannot draw the site icon: {s}", .{msg});
        },
    };
    if (want_ico) {
        var ico_images: [icons.ico_sizes.len]@import("render").icon.IcoImage = undefined;
        for (icons.ico_sizes, &ico_images, jobs.items[0..first_png]) |size, *im, j| im.* = .{ .size = size, .png = j.result.png };
        const ico = try @import("render").icon.ico(arena, &ico_images);
        try outputs.append(arena, .{ .path = icons.ico_path, .source = config_path, .data = .{ .bytes = ico } });
    }
    for (jobs.items[first_png..]) |j| {
        try outputs.append(arena, .{ .path = j.name, .source = config_path, .data = .{ .bytes = j.result.png } });
    }
    if (!hasOutput(outputs.items, icons.manifest_path)) {
        try outputs.append(arena, .{ .path = icons.manifest_path, .source = config_path, .data = .{ .bytes = try icons.manifest(arena, c, b.baseurl) } });
    }
}

/// Renders each job, read from the file at the same index of `sources`,
/// into `NAME.png`, plus `NAME.css` for kinds that need it. The first bad
/// spec in listing order is the one reported.
fn renderSpecs(b: *Builder, outputs: *std.ArrayList(Output), jobs: []assets.Job, sources: []const []const u8) Error!void {
    assets.renderMany(b.options.render_cache, b.arena, b.src.io, jobs) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSpec => for (jobs, sources) |j, source| {
            if (j.diag.message.len > 0) return b.fail(source, j.diag.line, "{s}", .{j.diag.message});
        } else return b.fail("", 0, "cannot render a spec", .{}),
    };
    for (jobs, sources) |j, source| try appendRendered(b, outputs, source, j.name, j.result);
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
fn addGenerated(b: *Builder, outputs: *std.ArrayList(Output), config_fields: frontmatter.Map, pages: []const Page, url: []const u8, langs: []const Language) Error!void {
    const arena = b.arena;
    const title = stringField(config_fields, "title") orelse "";
    const site: feeds.Site = .{
        .url = url,
        .baseurl = b.baseurl,
        .title = title,
        .author = stringField(config_fields, "author") orelse title,
    };
    // Each language's posts, newest first.
    const posts = try arena.alloc(std.ArrayList(feeds.Entry), langs.len);
    @memset(posts, .empty);
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
            try posts[p.lang].append(arena, feed_entry);
        }
        const opted_out = if (p.fields.get("sitemap")) |v| v == .boolean and !v.boolean else false;
        if (!opted_out and !std.mem.eql(u8, p.out_path, "404.html")) {
            var listed_entry = entry;
            // The sitemap's lastmod is the last change, when known.
            if (p.updated.len > 0) listed_entry.date = p.updated;
            try listed.append(arena, listed_entry);
        }
    }
    // A feed per language, of its own posts: `feed.xml`, `fr/feed.xml`, and
    // with `json_feed: true` the same as JSON: `feed.json`, `fr/feed.json`.
    const want_json = try optIn(b, config_fields, "json_feed");
    const description = stringField(config_fields, "description") orelse "";
    const want_atom = try enabled(b, config_fields, "feed");
    for (langs, posts, 0..) |lang, lang_posts, li| {
        if (lang_posts.items.len == 0) continue;
        var lang_site = site;
        if (li > 0) lang_site.baseurl = try std.mem.concat(arena, u8, &.{ b.baseurl, "/", lang.code });
        const dir = if (li == 0) "" else try std.mem.concat(arena, u8, &.{ lang.code, "/" });
        const atom_path = try std.mem.concat(arena, u8, &.{ dir, feeds.feed_path });
        if (want_atom and !hasOutput(outputs.items, atom_path)) {
            try outputs.append(arena, .{ .path = atom_path, .source = config_path, .data = .{ .bytes = try feeds.atom(arena, lang_site, lang_posts.items) } });
        }
        const json_path = try std.mem.concat(arena, u8, &.{ dir, feeds.json_feed_path });
        if (want_json and !hasOutput(outputs.items, json_path)) {
            try outputs.append(arena, .{ .path = json_path, .source = config_path, .data = .{ .bytes = try feeds.jsonFeed(arena, lang_site, description, lang_posts.items) } });
        }
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
fn finish(b: *Builder, config_fields: frontmatter.Map, all_pages: []Page, statics: []const Output, all_render: ?[]const bool) Error!Site {
    const arena = b.arena;
    // Documents of unpublished collections come last (`hiddenLast`): they
    // are listed in `site` but not written.
    const shown = shownCount(all_pages);
    const pages = all_pages[0..shown];
    const hidden = all_pages[shown..];
    const render = if (all_render) |r| r[0..shown] else null;
    const hidden_render = if (all_render) |r| r[shown..] else null;
    b.statics = statics;
    b.fingerprint = b.options.fingerprint and try enabled(b, config_fields, "fingerprint");
    b.liquid = try configFlag(b, config_fields, "liquid", false);
    b.strict = b.options.strict orelse blk: {
        // Liquid templates are written for Liquid's lax rendering, so even
        // `serve` is not strict for them unless asked.
        const v = config_fields.get("strict") orelse break :blk b.options.strict_by_default and !b.liquid;
        if (v != .boolean) return b.fail(config_path, 0, "'strict' must be true or false", .{});
        break :blk v.boolean;
    };
    b.now = @divFloor(std.Io.Clock.real.now(b.src.io).toMilliseconds(), 1000);
    b.pages = pages;

    var view = try buildSites(b, config_fields, pages, hidden);
    // Liquid in Markdown bodies runs first, as in Jekyll, with the site as
    // the bodies stood before; the sites are then built again from the
    // results.
    if (b.liquid) {
        const changed = try renderLiquidBodies(b, pages, render, view.sites);
        if (try renderLiquidBodies(b, hidden, hidden_render, view.sites) or changed) view = try buildSites(b, config_fields, pages, hidden);
    }
    const langs = view.langs;
    const sites = view.sites;
    const lang_posts = view.lang_posts;
    const lang_tags = view.lang_tags;
    const post_count = view.post_count;
    const tag_pages = view.tag_pages;
    const icon_config = view.icon_config;
    const has_search = view.has_search;
    const term_pages = view.term_pages;
    const taxonomy_pages = view.taxonomy_pages;
    const taxonomy_index = view.taxonomy_index;

    var rendered: usize = 0;
    var outputs: std.ArrayList(Output) = .empty;
    try outputs.appendSlice(arena, statics);
    const deps = try arena.alloc(Deps, pages.len);
    b.seo_config = try seoConfig(b, config_fields);
    for (pages, deps, 0..) |*p, *d, i| {
        if (render == null or render.?[i]) {
            b.site = sites[p.lang];
            b.deps = .empty;
            try b.deps.appendSlice(arena, p.body_sources);
            b.reads_collections = p.body_reads_collections;
            b.reads_seo = false;
            b.uses_copy_script = false;
            b.page_assets = .empty;
            try b.page_assets.appendSlice(arena, p.body_assets);
            b.page_variants = .empty;
            try b.addDep(p.source);
            for (p.included_files) |f| try b.addDep(f);
            try renderPaginated(b, p, lang_posts[p.lang]);
            p.sources = b.deps.items;
            p.reads_collections = b.reads_collections;
            p.uses_seo = b.reads_seo;
            p.uses_copy_script = b.uses_copy_script;
            p.search_sections = if (has_search) try searchSections(arena, p) else &.{};
            p.assets_used = b.page_assets.items;
            p.image_variants = b.page_variants.items;
            rendered += 1;
        }
        try outputs.append(arena, .{ .path = p.out_path, .source = p.source, .data = .{ .bytes = p.output } });
        try outputs.appendSlice(arena, p.extra_outputs);
        d.* = .{ .output = p.out_path, .sources = p.sources, .reads_collections = p.reads_collections };
    }

    // Tag pages may name assets too.
    b.page_assets = .empty;
    // Generated pages collect their images here.
    b.page_variants = .empty;
    if (tag_pages) for (langs, lang_tags, sites, 0..) |lang, tags, site, li| {
        b.site = site;
        const dir = if (li == 0) "" else try std.mem.concat(arena, u8, &.{ lang.code, "/" });
        try addTagPages(b, &outputs, tags.list, dir);
    };
    b.site = sites[0];
    try addCards(b, &outputs, pages);
    try addTaxonomyPages(b, &outputs, taxonomy_index, term_pages, taxonomy_pages);
    try addFingerprinted(b, &outputs, pages, b.page_assets.items);
    try addComponentsCss(b, &outputs, config_fields, pages);
    try addCopyScript(b, &outputs, pages);
    try addThemeCss(b, &outputs);
    try addAliases(b, &outputs, config_fields, pages);
    if (icon_config) |c| try addIcons(b, &outputs, c);
    if (has_search) try addSearch(b, &outputs, pages);
    if (try configFlag(b, config_fields, "schema_json", false)) {
        for (b.schemas.keys(), b.schemas.values()) |name, s| {
            const out_path = try std.fmt.allocPrint(arena, "schemas/{s}.json", .{name});
            if (hasOutput(outputs.items, out_path)) continue;
            try outputs.append(arena, .{ .path = out_path, .source = s.path, .data = .{ .bytes = try schema.jsonSchema(arena, s, name) } });
        }
    }
    if (b.site_url) |url| try addGenerated(b, &outputs, config_fields, pages, url, langs);
    try addImageVariants(b, &outputs, pages);
    if (try optIn(b, config_fields, "llms")) try addLlms(b, &outputs, config_fields, pages);
    try subsetFonts(b, &outputs, config_fields);

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
        .state = .{ .skipped = b.skipped, .config_fields = config_fields, .defaults = b.defaults, .collections = b.collections, .baseurl = b.baseurl, .site_url = b.site_url, .options = b.options, .data = b.data, .history = b.history, .schemas = b.schemas, .pages = all_pages, .statics = statics },
        .warnings = b.warnings.items,
        .gzip = if (config_fields.get("gzip")) |v| (if (v == .boolean) v.boolean else return b.fail(config_path, fieldLine(try b.read(config_path), "gzip"), "'gzip' must be true or false", .{})) else false,
        .minify = try configFlag(b, config_fields, "minify", false),
    };
}

/// `images:` in the config: `false`, or a map of settings.
fn imageConfig(b: *Builder, config_fields: frontmatter.Map) Error!images.Config {
    const v = config_fields.get("images") orelse return .{};
    const line = fieldLine(try b.read(config_path), "images");
    switch (v) {
        .boolean => |on| return if (on) .{} else .{ .dimensions = false, .lazy = false },
        .map => {},
        else => return b.fail(config_path, line, "'images' must be false or settings such as 'widths: [480, 960]'", .{}),
    }
    var cfg: images.Config = .{};
    for (v.map.entries) |e| {
        const key = e.key;
        if (std.mem.eql(u8, key, "dimensions") or std.mem.eql(u8, key, "lazy")) {
            if (e.value != .boolean) return b.fail(config_path, line, "'images.{s}' must be true or false", .{key});
            if (key[0] == 'd') cfg.dimensions = e.value.boolean else cfg.lazy = e.value.boolean;
        } else if (std.mem.eql(u8, key, "widths")) {
            const items: []const frontmatter.Value = if (e.value == .list) e.value.list else &.{e.value};
            var widths: std.ArrayList(u32) = .empty;
            for (items) |w| {
                if (w != .int or w.int < 16 or w.int > 8192) return b.fail(config_path, line, "'images.widths' must list widths in pixels from 16 to 8192", .{});
                const n: u32 = @intCast(w.int);
                if (std.mem.indexOfScalar(u32, widths.items, n) == null) try widths.append(b.arena, n);
            }
            std.mem.sortUnstable(u32, widths.items, {}, std.sort.asc(u32));
            cfg.widths = widths.items;
        } else if (std.mem.eql(u8, key, "quality")) {
            if (e.value != .int or e.value.int < 1 or e.value.int > 100) return b.fail(config_path, line, "'images.quality' must be a JPEG quality from 1 to 100", .{});
            cfg.quality = @intCast(e.value.int);
        } else if (std.mem.eql(u8, key, "sizes")) {
            if (e.value != .string) return b.fail(config_path, line, "'images.sizes' must be a string such as '(min-width: 60rem) 50vw, 100vw'", .{});
            cfg.sizes = e.value.string;
        } else {
            return b.fail(config_path, line, "unknown image setting '{s}'; use dimensions, lazy, widths, sizes or quality", .{key});
        }
    }
    return cfg;
}

/// Writes the resized images every page refers to, once each. A file of
/// the site's own at a copy's path is kept instead.
fn addImageVariants(b: *Builder, outputs: *std.ArrayList(Output), pages: []const Page) Error!void {
    const arena = b.arena;
    var unique: std.StringArrayHashMapUnmanaged(images.Variant) = .empty;
    for (pages) |p| for (p.image_variants) |v| try unique.put(arena, v.path, v);
    for (b.page_variants.items) |v| try unique.put(arena, v.path, v);
    var list: std.ArrayList(images.Variant) = .empty;
    for (unique.values()) |v| if (!b.static_outputs.contains(v.path)) try list.append(arena, v);
    if (list.items.len == 0) return;
    const cache = if (b.options.render_cache) |c| &c.images else null;
    var failure: images.Failure = .{};
    const files = images.resizeAll(arena, b.src.io, b.src, list.items, b.images.quality, cache, &failure) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ImageFailed => return b.fail(failure.path, 0, "cannot resize this image for srcset ({s}); convert it to an 8-bit PNG or a baseline or progressive JPEG", .{failure.reason}),
    };
    for (list.items, files) |v, bytes| try outputs.append(arena, .{ .path = v.path, .source = v.source, .data = .{ .bytes = bytes } });
}

/// `fields` with each of `overrides` replacing the setting of its name, or
/// added after them.
fn overrideConfig(arena: Allocator, fields: frontmatter.Map, overrides: []const frontmatter.Entry) Allocator.Error!frontmatter.Map {
    var out: std.ArrayList(frontmatter.Entry) = .empty;
    for (fields.entries) |e| {
        const v = for (overrides) |o| {
            if (std.mem.eql(u8, o.key, e.key)) break o.value;
        } else e.value;
        try out.append(arena, .{ .key = e.key, .value = v });
    }
    for (overrides) |o| if (fields.get(o.key) == null) try out.append(arena, o);
    return .{ .entries = out.items };
}

/// Everything `buildSites` works out for the render that follows.
const Sites = struct {
    langs: []const Language,
    /// Each language's `site`, default language first.
    sites: []const template.Object,
    lang_posts: []const []const Value,
    lang_tags: []const Value,
    post_count: usize,
    tag_pages: bool,
    icon_config: ?icons.Config,
    has_search: bool,
    term_pages: bool,
    taxonomy_pages: bool,
    taxonomy_index: Value,
};

/// Builds each page's object and each language's `site`, which every
/// template sees.
fn buildSites(b: *Builder, config_fields: frontmatter.Map, pages: []Page, hidden: []Page) Error!Sites {
    const arena = b.arena;
    // Pages and posts are visible to every template through `site`. On a
    // site with several languages, each language has its own `site`, which
    // lists only that language's pages and posts.
    const multi = b.languages.len > 0;
    const langs: []const Language = if (multi) b.languages else &.{.{ .code = "", .name = "" }};
    // Wikilinks name other pages, so they are resolved on every build.
    var backlinks = try links.resolve(arena, pages, b.baseurl, &b.link_error);
    if (b.link_error.message.len > 0) return b.fail(b.link_error.path, 0, "{s}", .{b.link_error.message});
    for (pages) |*p| {
        if (p.base.entries.len == 0) p.base = try pageObject(arena, p);
    }
    // Unpublished documents take part in nothing but their collection.
    for (hidden) |*p| {
        if (p.base.entries.len == 0) p.base = try pageObject(arena, p);
        p.object = p.base;
    }
    // Each language's pages, in `pageOrder`, and where they are in `pages`.
    const by_lang = try arena.alloc([]Page, langs.len);
    const where = try arena.alloc([]usize, langs.len);
    if (!multi) {
        try addNavigation(arena, pages);
        by_lang[0] = pages;
        where[0] = &.{};
    } else {
        for (by_lang, where, 0..) |*subset, *idx, li| {
            var list: std.ArrayList(Page) = .empty;
            var at: std.ArrayList(usize) = .empty;
            for (pages, 0..) |p, i| if (p.lang == li) {
                try list.append(arena, p);
                try at.append(arena, i);
            };
            // Previous and next stay within the language.
            try addNavigation(arena, list.items);
            for (list.items, at.items) |p, i| pages[i].object = p.object;
            subset.* = list.items;
            idx.* = at.items;
        }
        try addTranslations(arena, pages, langs);
    }
    const versions = try loadVersions(b, config_fields);
    if (versions.len > 0) try addVersions(arena, pages, versions, b.baseurl);
    const taxonomies = try taxonomyNames(b, config_fields);
    if (config_fields.get("related")) |v| {
        if (v != .int or v.int < 1 or v.int > 50) return b.fail(config_path, fieldLine(try b.read(config_path), "related"), "'related' must be how many related pages to list, 1 to 50", .{});
        try addRelated(arena, pages, taxonomies, @intCast(v.int));
    }
    b.menus = try menuIndex(b, pages);
    const menu_root = try std.fmt.allocPrint(arena, "{s}/", .{b.baseurl});
    for (pages) |*p| {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.object.entries);
        try entries.append(arena, .{ .key = "menus", .value = try pageMenus(arena, b.menus, p.url, menu_root) });
        p.object = .{ .entries = entries.items };
    }
    try links.addBacklinks(arena, pages, &backlinks);
    // The per-language copies take the finished objects.
    if (multi) for (by_lang, where) |subset, idx| {
        for (subset, idx) |*p, i| p.object = pages[i].object;
    };

    b.theme_chain = try themeChain(b, config_fields);
    b.token_set = try tokenSet(b, config_fields);
    // The config's settings, shared by every language's `site`.
    var config_entries: std.ArrayList(Entry) = .empty;
    // A light/dark switch, for token sets with both schemes.
    const toggle = if (b.token_set) |s| (if (s.scheme == .both) tokens.scheme_toggle_html else "") else "";
    try config_entries.append(arena, .{ .key = "scheme_toggle", .value = .{ .html = toggle } });
    for (config_fields.entries) |e| {
        if (std.mem.eql(u8, e.key, "posts") or std.mem.eql(u8, e.key, "pages") or
            std.mem.eql(u8, e.key, "data") or std.mem.eql(u8, e.key, "tags") or std.mem.eql(u8, e.key, "nav") or std.mem.eql(u8, e.key, "menus") or
            std.mem.eql(u8, e.key, "apis") or (b.liquid and (std.mem.eql(u8, e.key, "categories") or std.mem.eql(u8, e.key, "static_files"))) or (multi and (std.mem.eql(u8, e.key, "lang") or std.mem.eql(u8, e.key, "i18n"))))
        {
            return b.fail(config_path, 0, "'{s}' is set by Mortise; use another key", .{e.key});
        }
        if (std.mem.eql(u8, e.key, "baseurl")) {
            try config_entries.append(arena, .{ .key = e.key, .value = .{ .string = b.baseurl } });
            continue;
        }
        // `site.taxonomies`, `site.versions` and `site.languages` are built
        // from these settings.
        if (std.mem.eql(u8, e.key, "taxonomies") or std.mem.eql(u8, e.key, "versions")) continue;
        if (multi and std.mem.eql(u8, e.key, "languages")) continue;
        // `site.collections` and `site.LABEL` list the documents.
        if (std.mem.eql(u8, e.key, "collections")) continue;
        for (b.collections) |c| if (std.mem.eql(u8, c.label, e.key)) {
            return b.fail(config_path, fieldLine(try b.read(config_path), e.key), "'{s}' names a collection, so it cannot also be a setting", .{e.key});
        };
        try config_entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    // Always defined, so templates can use it in strict mode.
    if (config_fields.get("baseurl") == null) try config_entries.append(arena, .{ .key = "baseurl", .value = .{ .string = "" } });
    if (b.liquid and config_fields.get("time") == null) {
        const t = datetime.DateTime.fromUnix(b.now, 0);
        const time = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{ @as(u32, @intCast(t.year)), t.month, t.day, t.hour, t.minute, t.second });
        try config_entries.append(arena, .{ .key = "time", .value = .{ .string = time } });
    }
    const languages_value = if (multi) try languageList(arena, langs, b.baseurl) else Value.nil;

    const tag_pages = b.exists(tag_layout);
    const icon_config = try iconConfig(b, config_fields);
    const icon_tags = if (icon_config) |c| try icons.tags(arena, c, b.baseurl) else "";
    const has_search = if (config_fields.get("search")) |v| (if (v == .boolean) v.boolean else return b.fail(config_path, fieldLine(try b.read(config_path), "search"), "'search' must be true or false", .{})) else false;
    const search_box: Value = .{ .html = if (has_search) try search.box(arena, b.baseurl) else "" };
    const term_pages = taxonomies.len > 0 and b.exists(term_layout);
    const taxonomy_pages = taxonomies.len > 0 and b.exists(taxonomy_layout);
    const taxonomy_index = try taxonomyIndex(arena, pages, taxonomies, if (term_pages) b.baseurl else null);
    // Jekyll's `site.static_files`, the same in every language.
    var static_files: Value = .nil;
    const sites = try arena.alloc(template.Object, langs.len);
    const lang_posts = try arena.alloc([]const Value, langs.len);
    const lang_tags = try arena.alloc(Value, langs.len);
    var post_count: usize = 0;
    for (langs, by_lang, sites, lang_posts, lang_tags, 0..) |lang, subset, *site, *posts_out, *tags_out, li| {
        var post_values: std.ArrayList(Value) = .empty;
        var page_values: std.ArrayList(Value) = .empty;
        // Each collection's documents, published or not.
        const docs = try arena.alloc(std.ArrayList(*const Page), b.collections.len);
        @memset(docs, .empty);
        for (subset) |*p| {
            if (p.is_post) {
                try post_values.append(arena, .{ .object = p.object });
                post_count += 1;
            } else if (p.collection) |label| {
                try docs[collectionIndex(b.collections, label)].append(arena, p);
            } else {
                try page_values.append(arena, .{ .object = p.object });
            }
        }
        for (hidden) |*p| if (!multi or p.lang == li) {
            try docs[collectionIndex(b.collections, p.collection.?)].append(arena, p);
        };
        // The language's root: the baseurl, then `/CODE` except for the
        // default language.
        const root = if (li == 0) b.baseurl else try std.mem.concat(arena, u8, &.{ b.baseurl, "/", lang.code });
        var site_entries: std.ArrayList(Entry) = .empty;
        try site_entries.appendSlice(arena, config_entries.items);
        try site_entries.append(arena, .{ .key = "posts", .value = .{ .list = post_values.items } });
        try site_entries.append(arena, .{ .key = "pages", .value = .{ .list = page_values.items } });
        if (b.liquid) {
            // `site.collections` lists posts first, as Jekyll does.
            var coll_values: std.ArrayList(Value) = .empty;
            try coll_values.append(arena, try collectionValue(arena, .{ .label = "posts", .output = true }, post_values.items));
            for (b.collections, docs) |c, *list| {
                std.mem.sort(*const Page, list.items, c.sort_by, docLess);
                const values = try arena.alloc(Value, list.items.len);
                for (list.items, values) |p, *v| v.* = .{ .object = p.object };
                try site_entries.append(arena, .{ .key = c.label, .value = .{ .list = values } });
                try coll_values.append(arena, try collectionValue(arena, c, values));
            }
            try site_entries.append(arena, .{ .key = "collections", .value = .{ .list = coll_values.items } });
            try site_entries.append(arena, .{ .key = "categories", .value = try postIndex(arena, subset, .categories) });
            if (li == 0) static_files = try staticFileList(b);
            try site_entries.append(arena, .{ .key = "static_files", .value = static_files });
        }
        try site_entries.append(arena, .{ .key = "data", .value = b.data });
        try site_entries.append(arena, .{ .key = "nav", .value = try navTree(arena, subset, root) });
        try site_entries.append(arena, .{ .key = "apis", .value = try apiIndex(arena, subset) });
        if (versions.len > 0) try site_entries.append(arena, .{ .key = "versions", .value = try versionList(arena, versions, b.baseurl) });
        try site_entries.append(arena, .{ .key = "menus", .value = b.menus });
        tags_out.* = try tagIndex(arena, subset, if (tag_pages) root else null);
        // Liquid sites get Jekyll's shape: each tag mapped to its posts.
        try site_entries.append(arena, .{ .key = "tags", .value = if (b.liquid) try postIndex(arena, subset, .tags) else tags_out.* });
        try site_entries.append(arena, .{ .key = "icon_tags", .value = .{ .html = icon_tags } });
        try site_entries.append(arena, .{ .key = "search_box", .value = search_box });
        try site_entries.append(arena, .{ .key = "taxonomies", .value = taxonomy_index });
        if (multi) {
            try site_entries.append(arena, .{ .key = "lang", .value = .{ .string = lang.code } });
            try site_entries.append(arena, .{ .key = "languages", .value = languages_value });
            // `_data/i18n/CODE.yml`, the language's strings for templates.
            const strings: Value = if (b.data.object.get("i18n")) |all| (if (all == .object) all.object.get(lang.code) orelse Value{ .object = .{} } else Value{ .object = .{} }) else .{ .object = .{} };
            try site_entries.append(arena, .{ .key = "i18n", .value = strings });
        }
        site.* = .{ .entries = site_entries.items };
        posts_out.* = post_values.items;
    }
    b.site = sites[0];
    b.images = try imageConfig(b, config_fields);
    for (b.statics) |s| try b.static_outputs.put(arena, s.path, s);
    return .{
        .langs = langs,
        .sites = sites,
        .lang_posts = lang_posts,
        .lang_tags = lang_tags,
        .post_count = post_count,
        .tag_pages = tag_pages,
        .icon_config = icon_config,
        .has_search = has_search,
        .term_pages = term_pages,
        .taxonomy_pages = taxonomy_pages,
        .taxonomy_index = taxonomy_index,
    };
}

/// Jekyll's `site.static_files`: each file copied unchanged, with
/// `path` (from the site's root, with a leading `/`), `url`, `name`,
/// `basename`, `extname`, `modified_time` and `collection`, over the
/// values of the front matter defaults whose path matches it.
fn staticFileList(b: *Builder) Error!Value {
    const arena = b.arena;
    var list: std.ArrayList(Value) = .empty;
    for (b.statics) |s| {
        if (s.data != .copy) continue;
        var entries: std.ArrayList(Entry) = .empty;
        // Defaults with a type never match a static file, as in Jekyll.
        const values = try fm_defaults.apply(arena, b.defaults, s.source, "", .{});
        for (values.entries) |e| try entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
        const name = sitepath.basename(s.source);
        const ext = sitepath.extension(name);
        const computed = [_]Entry{
            .{ .key = "path", .value = .{ .string = try std.fmt.allocPrint(arena, "/{s}", .{s.source}) } },
            .{ .key = "url", .value = .{ .string = try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.baseurl, s.path }) } },
            .{ .key = "name", .value = .{ .string = name } },
            .{ .key = "basename", .value = .{ .string = name[0 .. name.len - ext.len] } },
            .{ .key = "extname", .value = .{ .string = ext } },
            .{ .key = "collection", .value = if (collections.find(b.collections, s.source)) |c| .{ .string = c.label } else .nil },
        };
        try entries.appendSlice(arena, &computed);
        if (b.src.stat(s.source)) |st| {
            const t = datetime.DateTime.fromUnix(st.mtime.toSeconds(), 0);
            const time = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} +0000", .{ @as(u32, @intCast(t.year)), t.month, t.day, t.hour, t.minute, t.second });
            try entries.append(arena, .{ .key = "modified_time", .value = .{ .string = time } });
        } else |_| {}
        try list.append(arena, .{ .object = .{ .entries = try dedupeLast(arena, entries.items) } });
    }
    return .{ .list = list.items };
}

/// Keeps the last entry of each key, so later entries override earlier
/// ones, in the order the kept entries came.
fn dedupeLast(arena: Allocator, entries: []const Entry) Allocator.Error![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (entries, 0..) |e, i| {
        const later = for (entries[i + 1 ..]) |x| {
            if (std.mem.eql(u8, x.key, e.key)) break true;
        } else false;
        if (!later) try out.append(arena, e);
    }
    return out.items;
}

/// Jekyll's `site.categories` or `site.tags` (Liquid mode): each name, in
/// the order the oldest posts first use it, mapped to its posts, newest
/// first. `pages` is in `pageOrder`, newest post first.
fn postIndex(arena: Allocator, pages: []const Page, comptime by: enum { categories, tags }) Allocator.Error!Value {
    var names: std.ArrayList([]const u8) = .empty;
    var lists: std.ArrayList(std.ArrayList(Value)) = .empty;
    var i = pages.len;
    while (i > 0) {
        i -= 1;
        const p = &pages[i];
        if (!p.is_post) continue;
        const own = switch (by) {
            .categories => p.categories orelse &.{},
            .tags => try pageTags(arena, p),
        };
        for (own, 0..) |c, ci| {
            // A name the post repeats lists it once.
            if (for (own[0..ci]) |prev| {
                if (std.mem.eql(u8, prev, c)) break true;
            } else false) continue;
            const at = for (names.items, 0..) |n, k| {
                if (std.mem.eql(u8, n, c)) break k;
            } else blk: {
                try names.append(arena, c);
                try lists.append(arena, .empty);
                break :blk names.items.len - 1;
            };
            try lists.items[at].append(arena, .{ .object = p.object });
        }
    }
    const entries = try arena.alloc(Entry, names.items.len);
    for (entries, names.items, lists.items) |*e, n, l| {
        std.mem.reverse(Value, l.items);
        e.* = .{ .key = n, .value = .{ .list = l.items } };
    }
    return .{ .object = .{ .entries = entries } };
}

fn collectionIndex(all: []const collections.Collection, label: []const u8) usize {
    for (all, 0..) |c, i| if (std.mem.eql(u8, c.label, label)) return i;
    unreachable;
}

/// A collection as `site.collections` lists it, with Jekyll's keys.
fn collectionValue(arena: Allocator, c: collections.Collection, docs: []const Value) Allocator.Error!Value {
    const entries = try arena.dupe(Entry, &.{
        .{ .key = "label", .value = .{ .string = c.label } },
        .{ .key = "docs", .value = .{ .list = docs } },
        .{ .key = "output", .value = .{ .boolean = c.output } },
        .{ .key = "relative_directory", .value = .{ .string = try std.fmt.allocPrint(arena, "_{s}", .{c.label}) } },
    });
    return .{ .object = .{ .entries = entries } };
}

/// Orders a collection's documents: by `sort_by`'s field when set (those
/// without it last), otherwise by `date` when both have one; then by path.
fn docLess(sort_by: ?[]const u8, a: *const Page, c: *const Page) bool {
    const field = sort_by orelse "date";
    const x = a.fields.get(field);
    const y = c.fields.get(field);
    if (x != null and y != null) {
        const order: std.math.Order = switch (x.?) {
            .int => |i| if (y.? == .int) std.math.order(i, y.?.int) else .eq,
            .float => |f| if (y.? == .float) std.math.order(f, y.?.float) else .eq,
            .string => |s| if (y.? == .string) std.mem.order(u8, s, y.?.string) else .eq,
            else => .eq,
        };
        if (order != .eq) return order == .lt;
    } else if (sort_by != null and (x == null) != (y == null)) {
        return x != null;
    }
    return std.mem.lessThan(u8, a.source, c.source);
}

/// Runs Liquid in the Markdown bodies that hold any, before they become
/// HTML. Returns whether any body changed.
fn renderLiquidBodies(b: *Builder, pages: []Page, render: ?[]const bool, sites: []const template.Object) Error!bool {
    const arena = b.arena;
    var changed = false;
    for (pages, 0..) |*p, i| {
        if (!p.is_markdown or p.api != null) continue;
        if (render) |r| if (!r[i]) continue;
        if (std.mem.indexOf(u8, p.body, "{{") == null and std.mem.indexOf(u8, p.body, "{%") == null) continue;
        b.site = sites[p.lang];
        b.deps = .empty;
        b.reads_collections = false;
        b.page_assets = .empty;
        try b.line_offsets.put(arena, p.source, p.body_line - 1);
        var td: template.Diagnostic = .{};
        const tpl = try arena.create(template.Template);
        tpl.* = template.parseWith(arena, p.source, p.body, try b.parseOptions(), &td) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TemplateSyntax => return b.templateFail(td),
        };
        var stash: std.ArrayList([]const u8) = .empty;
        b.stash = &stash;
        defer b.stash = null;
        const source = try renderTemplate(b, tpl, p, null);
        // The same Markdown options as when the page loaded, so `<<<`
        // includes and shortcodes still work.
        var inc: FileIncluder = .{ .b = b, .page = p.source };
        var md_options = b.markdown_options;
        md_options.includer = .{ .ctx = &inc, .readFn = FileIncluder.read };
        var sc: ShortcodeRenderer = .{ .b = b, .page = try convert(arena, .{ .map = p.fields }) };
        md_options.shortcoder = .{ .ctx = &sc, .renderFn = ShortcodeRenderer.render };
        const doc = try markdown.toDocumentWith(arena, source, md_options);
        if (doc.include_error) |e| return b.fail(p.source, 0, "{s}", .{e.message});
        if (doc.chart_error) |ce| return b.fail(p.source, 0, "chart, line {d} of its block: {s}", .{ ce.line, ce.message });
        if (doc.diagram_error) |de| return b.fail(p.source, 0, "diagram, line {d} of its block: {s}", .{ de.line, de.message });
        if (doc.math_error) |me| return b.fail(p.source, 0, "math '{s}': {s}", .{ std.mem.trim(u8, me.source, " \n"), me.message });
        p.html = try template.restoreStashed(arena, doc.html, stash.items);
        p.toc = try tocHtml(arena, doc.headings);
        p.uses_components = doc.uses_components;
        p.included_files = inc.files.items;
        p.wikilink_html = if (std.mem.indexOf(u8, p.html.?, markdown.wikilink_prefix) != null) p.html else null;
        p.base = try pageObject(arena, p);
        p.body_sources = b.deps.items;
        p.body_reads_collections = b.reads_collections;
        p.body_assets = b.page_assets.items;
        changed = true;
    }
    return changed;
}

fn startsWithFrontmatter(b: *Builder, path: []const u8) Error!bool {
    const data = try b.read(path);
    const d = if (std.mem.startsWith(u8, data, "\xEF\xBB\xBF")) data[3..] else data;
    return std.mem.startsWith(u8, d, "---\n") or std.mem.startsWith(u8, d, "---\r\n");
}

const LoadJob = struct {
    path: []const u8,
    is_post: bool,
    result: Error!?Page = null,
    diag: Diagnostic = .{},
    /// Why the page was left out, if it was.
    skipped: Skipped = .{},
};

/// Runs `loadPage` for every job, spread over several threads for big
/// sites. Each job gets its own copy of the builder, so a failure only
/// writes to that job's diagnostic; loading touches nothing else shared but
/// the arena, which is thread-safe.
fn loadPages(b: *Builder, jobs: []LoadJob) void {
    const Worker = struct {
        fn run(builder: *const Builder, all: []LoadJob, first: usize, step: usize) void {
            var i = first;
            while (i < all.len) : (i += step) {
                var own = builder.*;
                own.diag = &all[i].diag;
                own.skipped = .{};
                // Shortcodes load templates while pages load; each job
                // keeps its own cache and dependency list, so workers never
                // write to shared ones.
                own.templates = .empty;
                own.deps = .empty;
                all[i].result = loadPage(&own, all[i].path, all[i].is_post);
                all[i].skipped = own.skipped;
            }
        }
    };
    // Threads only pay off when there is enough to share out.
    const workers = if (jobs.len < 64) 1 else @min(std.Thread.getCpuCount() catch 1, 16);
    if (workers <= 1) return Worker.run(b, jobs, 0, 1);
    const io = b.src.io;
    var group: std.Io.Group = .init;
    for (0..workers) |k| {
        group.concurrent(io, Worker.run, .{ b, jobs, k, workers }) catch Worker.run(b, jobs, k, workers);
    }
    group.await(io) catch {
        group.cancel(io);
        for (jobs) |*j| j.result = error.BuildFailed;
    };
}

/// Reads and parses a page or post. Returns null for drafts.
fn loadPage(b: *Builder, path: []const u8, is_post: bool) Error!?Page {
    if (openapi.isSpec(path)) return try loadApiPage(b, path);
    const arena = b.arena;
    const data = try b.read(path);
    var fd: frontmatter.Diagnostic = .{};
    var doc = frontmatter.parse(arena, data, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
    };
    const coll = collections.find(b.collections, path);
    if (b.defaults.len > 0) {
        const kind = if (is_post) "posts" else if (coll) |c| c.label else "pages";
        doc.fields = try fm_defaults.apply(arena, b.defaults, path, kind, doc.fields);
    }
    try applySchema(b, path, data, is_post, &doc.fields);
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

    if (doc.fields.get("sort")) |s| {
        if (s != .string or std.meta.stringToEnum(SortMode, s.string) == null) {
            return b.fail(path, fieldLine(data, "sort"), "'sort' must be weight, title, date or url", .{});
        }
    }
    if (doc.fields.get("menu")) |m| {
        const ok = switch (m) {
            .string => |s| s.len > 0,
            .list => |l| for (l) |item| {
                if (item != .string or item.string.len == 0) break false;
            } else true,
            else => false,
        };
        if (!ok) return b.fail(path, fieldLine(data, "menu"), "'menu' must be a menu name or a list of them, such as [main, footer]", .{});
    }

    const is_markdown = std.mem.eql(u8, sitepath.extension(path), ".md");
    // A translation's URL is worked out from its path without the language.
    const lang = try i18n.detect(arena, b.languages, path);
    // A collection's documents publish under its name: `_recipes/a.md` at
    // `/recipes/a/`.
    const upath = if (coll != null) lang.path[1..] else lang.path;
    var page: Page = .{
        .source = path,
        .lang = lang.index,
        .translation_key = lang.key,
        .is_post = is_post,
        .collection = if (coll) |c| c.label else null,
        .hidden = if (coll) |c| !c.output else false,
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
        var sc: ShortcodeRenderer = .{ .b = b, .page = try convert(arena, .{ .map = doc.fields }) };
        md_options.shortcoder = .{ .ctx = &sc, .renderFn = ShortcodeRenderer.render };
        const rendered = try markdown.toDocumentWith(arena, doc.body, md_options);
        if (rendered.include_error) |e| {
            const at = std.mem.indexOf(u8, doc.body, e.directive[4..]) orelse 0;
            return b.fail(path, doc.body_line + std.mem.count(u8, doc.body[0..at], "\n"), "{s}", .{e.message});
        }
        if (rendered.math_error) |me| return b.fail(path, 0, "math '{s}': {s}", .{ std.mem.trim(u8, me.source, " \n"), me.message });
        page.html = rendered.html;
        page.toc = try tocHtml(arena, rendered.headings);
        page.uses_components = rendered.uses_components;
        page.included_files = inc.files.items;
        if (std.mem.indexOf(u8, rendered.html, markdown.wikilink_prefix) != null) page.wikilink_html = rendered.html;
        if (rendered.chart_error) |ce| {
            return b.fail(path, 0, "chart, line {d} of its block: {s}", .{ ce.line, ce.message });
        }
        if (rendered.diagram_error) |de| {
            return b.fail(path, 0, "diagram, line {d} of its block: {s}", .{ de.line, de.message });
        }
    }

    if (is_post) {
        const base = sitepath.basename(upath);
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

    // Jekyll's categories: `categories` (a list, or words) and `category`.
    if (b.liquid and is_post) page.categories = try postCategories(arena, doc.fields);

    if (doc.fields.get("permalink")) |pl| {
        const line = fieldLine(data, "permalink");
        if (pl != .string or pl.string.len == 0 or (pl.string[0] != '/' and !(b.liquid and permalink.style(pl.string) != null))) {
            return b.fail(path, line, "'permalink' must be a string starting with '/'", .{});
        }
        // Liquid permalinks may hold placeholders such as `:title`.
        page.url = if (b.liquid) try permalinkUrl(b, &page, upath, coll, permalink.style(pl.string) orelse pl.string) else pl.string;
    } else if (b.liquid and (is_post or b.permalink != null or (coll != null and coll.?.permalink != null))) {
        const tpl = if (is_post)
            b.permalink orelse "/:categories/:year/:month/:day/:title/"
        else if (coll != null and coll.?.permalink != null)
            permalink.style(coll.?.permalink.?) orelse coll.?.permalink.?
        else if (coll != null)
            // Jekyll's default, ending as the site's style does.
            (if (std.mem.endsWith(u8, b.permalink.?, "/")) "/:collection/:path/" else "/:collection/:path:output_ext")
        else if (std.mem.eql(u8, sitepath.stem(sitepath.basename(upath)), "index"))
            "/:path/"
        else if (std.mem.endsWith(u8, b.permalink.?, "/"))
            "/:path/:basename/"
        else
            "/:path/:basename:output_ext";
        page.url = try permalinkUrl(b, &page, upath, coll, tpl);
    } else if (is_post) {
        const d = page.date;
        page.url = try std.fmt.allocPrint(arena, "/{s}/{s}/{s}/{s}/", .{ d[0..4], d[5..7], d[8..10], sitepath.stem(upath)[11..] });
    } else if (is_markdown) {
        const stem_path = upath[0 .. upath.len - ".md".len];
        if (std.mem.eql(u8, sitepath.basename(stem_path), "index")) {
            const dir = sitepath.dirname(stem_path);
            page.url = if (dir) |d| try std.fmt.allocPrint(arena, "/{s}/", .{d}) else "/";
        } else {
            page.url = try std.fmt.allocPrint(arena, "/{s}/", .{stem_path});
        }
    } else {
        page.url = if (std.mem.eql(u8, sitepath.basename(upath), "index.html"))
            (if (sitepath.dirname(upath)) |d| try std.fmt.allocPrint(arena, "/{s}/", .{d}) else "/")
        else
            try std.fmt.allocPrint(arena, "/{s}", .{upath});
    }
    // `about.fr.md` publishes under `/fr/`; `fr/about.md` already does.
    if (lang.prefix and doc.fields.get("permalink") == null) {
        page.url = try std.mem.concat(arena, u8, &.{ "/", b.languages[lang.index].code, page.url });
    }

    const out_raw = if (std.mem.endsWith(u8, page.url, "/"))
        try std.fmt.allocPrint(arena, "{s}index.html", .{page.url})
    else if (b.liquid and std.mem.indexOfScalar(u8, sitepath.basename(page.url), '.') == null)
        // As in Jekyll, `/about` is written to `about.html`.
        try std.fmt.allocPrint(arena, "{s}.html", .{page.url})
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
    if (page.html) |h| if (is_markdown) {
        page.link_targets = try links.targets(arena, h, page.url);
    };
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

/// Renders a page's `{{< name >}}` shortcodes with the templates in
/// `_includes/shortcodes/`. The template sees `args` (the call's
/// arguments, as text), `content` (the rendered body, when the call has
/// one), `page` (the page's frontmatter) and `site` (the config).
const ShortcodeRenderer = struct {
    b: *Builder,
    page: Value,

    fn render(ctx: *anyopaque, call: markdown.Shortcode, why: *[]const u8) Allocator.Error!?[]const u8 {
        const self: *ShortcodeRenderer = @ptrCast(@alignCast(ctx));
        const b = self.b;
        const arena = b.arena;
        const name = try std.fmt.allocPrint(arena, "shortcodes/{s}.html", .{call.name});
        var td: template.Diagnostic = .{};
        const tpl = loadInclude(b, name, &td) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.TemplateNotFound => {
                why.* = try std.fmt.allocPrint(arena, "there is no _includes/{s}", .{name});
                return null;
            },
            error.TemplateSyntax => {
                why.* = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ td.template, td.line, td.message });
                return null;
            },
        };
        const args = try arena.alloc(Entry, call.args.len);
        for (args, call.args) |*e, a| e.* = .{ .key = a.name, .value = .{ .string = a.value } };
        var entries: std.ArrayList(Entry) = .empty;
        try entries.append(arena, .{ .key = "args", .value = .{ .object = .{ .entries = args } } });
        if (call.body) |body| try entries.append(arena, .{ .key = "content", .value = .{ .html = body } });
        try entries.append(arena, .{ .key = "page", .value = self.page });
        try entries.append(arena, .{ .key = "site", .value = b.site_config });
        return template.renderAlloc(arena, tpl, .{ .entries = entries.items }, .{ .ctx = b, .loadFn = loadInclude }, &td) catch |err| switch (err) {
            error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
            else => {
                why.* = try std.fmt.allocPrint(arena, "{s}:{d}: {s}", .{ td.template, td.line, td.message });
                return null;
            },
        };
    }
};

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
    const format: openapi.Format = if (openapi.isYaml(path)) .yaml else .json;
    const r = openapi.render(arena, try b.read(path), format, &od) catch |err| switch (err) {
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

/// A post's categories, from `categories` (a list, or words separated by
/// spaces) and `category`, without repeats.
fn postCategories(arena: Allocator, fields: frontmatter.Map) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn f(a: Allocator, list: *std.ArrayList([]const u8), v: frontmatter.Value) Allocator.Error!void {
            const s = switch (v) {
                .string => |s| s,
                .int => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                else => return,
            };
            for (list.items) |x| if (std.mem.eql(u8, x, s)) return;
            if (s.len > 0) try list.append(a, s);
        }
    }.f;
    if (fields.get("categories")) |v| switch (v) {
        .list => |l| for (l) |item| try add(arena, &out, item),
        .string => |s| {
            var words = std.mem.tokenizeAny(u8, s, " \t");
            while (words.next()) |w| try add(arena, &out, .{ .string = w });
        },
        else => try add(arena, &out, v),
    };
    if (fields.get("category")) |v| try add(arena, &out, v);
    return out.items;
}

/// Expands a Jekyll permalink template for `p`, whose path without its
/// language (and, in a collection, its leading `_`) is `upath`.
fn permalinkUrl(b: *Builder, p: *const Page, upath: []const u8, coll: ?*const collections.Collection, tpl: []const u8) Error![]const u8 {
    const arena = b.arena;
    var vars: std.ArrayList(permalink.Var) = .empty;
    try vars.append(arena, .{ .name = "output_ext", .value = ".html" });
    const base = sitepath.basename(upath);
    const stem = sitepath.stem(base);
    // A date from front matter, with its time, or else a post's file name.
    var date: ?datetime.DateTime = null;
    if (p.fields.get("date")) |d| if (d == .string) {
        date = datetime.parse(d.string);
    };
    if (date == null and p.is_post) date = datetime.parse(p.date);
    const dates = if (date) |d| try permalink.dateVars(arena, d) else &.{};
    const slug_field = if (p.fields.get("slug")) |s| (if (s == .string) s.string else null) else null;
    if (p.is_post) {
        const title = slug_field orelse stem[11..];
        try vars.append(arena, .{ .name = "title", .value = title });
        try vars.append(arena, .{ .name = "slug", .value = try markdown.slugify(arena, title) });
        // Lowercase, joined with `/`, as Jekyll writes them.
        var cats: std.ArrayList(u8) = .empty;
        for (p.categories orelse &.{}, 0..) |c, i| {
            if (i > 0) try cats.append(arena, '/');
            for (c) |ch| try cats.append(arena, std.ascii.toLower(ch));
        }
        try vars.append(arena, .{ .name = "categories", .value = cats.items });
    } else if (coll) |c| {
        const rel = upath[c.label.len + 1 ..];
        const title = slug_field orelse stem;
        try vars.append(arena, .{ .name = "collection", .value = c.label });
        try vars.append(arena, .{ .name = "path", .value = rel[0 .. rel.len - sitepath.extension(rel).len] });
        try vars.append(arena, .{ .name = "name", .value = try markdown.slugify(arena, stem) });
        try vars.append(arena, .{ .name = "title", .value = title });
        try vars.append(arena, .{ .name = "slug", .value = try markdown.slugify(arena, title) });
        try vars.append(arena, .{ .name = "categories", .value = "" });
    } else {
        try vars.append(arena, .{ .name = "path", .value = sitepath.dirname(upath) orelse "" });
        try vars.append(arena, .{ .name = "basename", .value = stem });
    }
    return permalink.expand(arena, tpl, &.{ vars.items, dates });
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
        if (isComputedKey(e.key) or (p.categories != null and std.mem.eql(u8, e.key, "categories"))) continue;
        try entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    try entries.append(arena, .{ .key = "url", .value = .{ .string = p.url } });
    try entries.append(arena, .{ .key = "path", .value = .{ .string = p.source } });
    // The collection the document belongs to, as in Jekyll.
    if (p.collection) |c| if (p.fields.get("collection") == null) {
        try entries.append(arena, .{ .key = "collection", .value = .{ .string = c } });
    };
    // A post's categories as a list, as in Jekyll (Liquid mode).
    if (p.categories) |cats| {
        const list = try arena.alloc(Value, cats.len);
        for (cats, list) |c, *v| v.* = .{ .string = c };
        try entries.append(arena, .{ .key = "categories", .value = .{ .list = list } });
    }
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
pub fn navTitle(p: *const Page) []const u8 {
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

/// Non-post pages by URL, built once per build so navigation does not
/// search every page for every link.
const PageIndex = std.StringHashMapUnmanaged(*const Page);

fn pageIndex(arena: Allocator, pages: []const Page) Allocator.Error!PageIndex {
    var index: PageIndex = .empty;
    for (pages) |*p| {
        if (p.is_post) continue;
        const gop = try index.getOrPut(arena, p.url);
        // The first page at a URL wins, as a search in order would find it.
        if (!gop.found_existing) gop.value_ptr.* = p;
    }
    return index;
}

/// Sets each page's `object` to its fields plus navigation:
///
///   page.breadcrumbs  ancestor pages by URL, root first, as {title, url}
///   page.previous     for posts, the next older post; for pages, the
///   page.next         previous and next page in the same URL directory,
///                     ordered by `weight` then title
fn addNavigation(arena: Allocator, pages: []Page) Allocator.Error!void {
    const index = try pageIndex(arena, pages);
    // Each URL directory's visible pages, in navigation order.
    var by_dir: std.StringHashMapUnmanaged(std.ArrayList(*const Page)) = .empty;
    for (pages) |*q| {
        if (q.is_post or isHiddenFromNav(q) or std.mem.eql(u8, q.url, "/")) continue;
        const dir = parentUrl(q.url);
        if (dir.len == 0) continue;
        const gop = try by_dir.getOrPut(arena, dir);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, q);
    }
    var lists = by_dir.iterator();
    while (lists.next()) |e| std.mem.sortUnstable(*const Page, e.value_ptr.items, sectionSort(&index, e.key_ptr.*), navLess);

    for (pages, 0..) |*p, i| {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.base.entries);

        // Breadcrumbs: every existing page whose URL is a prefix directory.
        var crumbs: std.ArrayList(Value) = .empty;
        var dir = parentUrl(p.url);
        var stack: std.ArrayList(Value) = .empty;
        while (dir.len > 0) : (dir = parentUrl(dir)) {
            if (index.get(dir)) |anc| try stack.append(arena, try navLink(arena, anc));
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
        } else if (!std.mem.eql(u8, p.url, "/")) {
            const siblings: []const *const Page = if (by_dir.get(parentUrl(p.url))) |l| l.items else &.{};
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

fn isHiddenFromNav(p: *const Page) bool {
    const v = p.fields.get("nav") orelse return false;
    return v == .boolean and !v.boolean;
}

/// How a section's pages are ordered, set by `sort:` on its index page.
const SortMode = enum { weight, title, date, url };

/// The order of the pages in the URL directory `dir`.
fn sectionSort(index: *const PageIndex, dir: []const u8) SortMode {
    const page = index.get(dir) orelse return .weight;
    const s = stringField(page.fields, "sort") orelse return .weight;
    return std.meta.stringToEnum(SortMode, s) orelse .weight;
}

/// Orders pages by `mode`, then by title. Weights and dates are optional;
/// pages without one come last, and dates sort newest first.
fn navLess(mode: SortMode, a: *const Page, b: *const Page) bool {
    switch (mode) {
        .weight => {
            const wa = navWeight(a);
            const wb = navWeight(b);
            if (wa != wb) return wa < wb;
        },
        .title => {},
        .date => {
            const da = stringField(a.fields, "date") orelse "";
            const db = stringField(b.fields, "date") orelse "";
            if (!std.mem.eql(u8, da, db)) return std.mem.lessThan(u8, db, da);
        },
        .url => if (!std.mem.eql(u8, a.url, b.url)) return std.mem.lessThan(u8, a.url, b.url),
    }
    return std.mem.lessThan(u8, navTitle(a), navTitle(b));
}

/// `versions:` from the config: the directories that hold each version of
/// the documentation, newest first.
fn loadVersions(b: *Builder, config_fields: frontmatter.Map) Error![]const []const u8 {
    const v = config_fields.get("versions") orelse return &.{};
    const line = fieldLine(try b.read(config_path), "versions");
    const msg = "'versions' must list version directories, newest first, such as [v2, v1]";
    if (v != .list or v.list.len == 0) return b.fail(config_path, line, msg, .{});
    const out = try b.arena.alloc([]const u8, v.list.len);
    for (v.list, out, 0..) |item, *o, i| {
        // `2.0` would read as the number 2; the name must be text.
        if (item == .int or item == .float) return b.fail(config_path, line, "write version numbers in quotes, such as ['2.0', '1.0']", .{});
        const name = if (item == .string) item.string else return b.fail(config_path, line, msg, .{});
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\ ") != null or name[0] == '_' or name[0] == '.') {
            return b.fail(config_path, line, "version '{s}' must be a plain directory name", .{name});
        }
        for (out[0..i]) |prev| if (std.mem.eql(u8, prev, name)) return b.fail(config_path, line, "version '{s}' is listed twice", .{name});
        o.* = name;
    }
    return out;
}

/// The version of the page at `url` (which includes `baseurl`): the index
/// of the version whose directory it is under, or null.
fn pageVersion(url: []const u8, versions: []const []const u8, baseurl: []const u8) ?usize {
    const rest = if (std.mem.startsWith(u8, url, baseurl)) url[baseurl.len..] else url;
    for (versions, 0..) |v, i| {
        if (rest.len > v.len + 1 and rest[0] == '/' and std.mem.startsWith(u8, rest[1..], v) and rest[v.len + 1] == '/') return i;
    }
    return null;
}

/// `site.versions`: each version's `{name, url, latest}`, newest first, the
/// URL being its directory.
fn versionList(arena: Allocator, versions: []const []const u8, baseurl: []const u8) Allocator.Error!Value {
    const out = try arena.alloc(Value, versions.len);
    for (versions, out, 0..) |v, *o, i| {
        const e = try arena.alloc(Entry, 3);
        e[0] = .{ .key = "name", .value = .{ .string = v } };
        e[1] = .{ .key = "url", .value = .{ .string = try std.fmt.allocPrint(arena, "{s}/{s}/", .{ baseurl, v }) } };
        e[2] = .{ .key = "latest", .value = .{ .boolean = i == 0 } };
        o.* = .{ .object = .{ .entries = e } };
    }
    return .{ .list = out };
}

/// Adds to every page in a version directory:
///
///   page.version      its version's name
///   page.versions     the page in every version, newest first, each
///                     {name, url, current, latest}; a version without the
///                     page links to its home page instead
///   page.latest_url   the page in the newest version, or that version's home
///   page.outdated     whether the page is in an older version
///   page.version_nav  `site.nav` for just its version, as a tree
fn addVersions(arena: Allocator, pages: []Page, versions: []const []const u8, baseurl: []const u8) Allocator.Error!void {
    const navs = try arena.alloc(Value, versions.len);
    const roots = try arena.alloc([]const u8, versions.len);
    for (versions, navs, roots) |v, *n, *r| {
        r.* = try std.fmt.allocPrint(arena, "{s}/{s}/", .{ baseurl, v });
        // The version's tree is `site.nav` rooted at its directory.
        n.* = try navTree(arena, pages, r.*[0 .. r.len - 1]);
    }
    const index = try pageIndex(arena, pages);
    for (pages) |*p| {
        const vi = pageVersion(p.url, versions, baseurl) orelse continue;
        // The part of the URL after the version directory.
        const rest = p.url[roots[vi].len..];
        const list = try arena.alloc(Value, versions.len);
        var latest_url: []const u8 = roots[0];
        for (versions, roots, list, 0..) |v, root, *item, wi| {
            const same = try std.mem.concat(arena, u8, &.{ root, rest });
            const url = if (index.get(same) != null) same else root;
            if (wi == 0) latest_url = url;
            const e = try arena.alloc(Entry, 4);
            e[0] = .{ .key = "name", .value = .{ .string = v } };
            e[1] = .{ .key = "url", .value = .{ .string = url } };
            e[2] = .{ .key = "current", .value = .{ .boolean = wi == vi } };
            e[3] = .{ .key = "latest", .value = .{ .boolean = wi == 0 } };
            item.* = .{ .object = .{ .entries = e } };
        }
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.object.entries);
        try entries.append(arena, .{ .key = "version", .value = .{ .string = versions[vi] } });
        try entries.append(arena, .{ .key = "versions", .value = .{ .list = list } });
        try entries.append(arena, .{ .key = "latest_url", .value = .{ .string = latest_url } });
        try entries.append(arena, .{ .key = "outdated", .value = .{ .boolean = vi != 0 } });
        try entries.append(arena, .{ .key = "version_nav", .value = navs[vi] });
        p.object = .{ .entries = entries.items };
    }
}

/// `site.nav`: the non-post pages as a tree by URL, each node
/// {title, url, children}, ordered by `weight` then title. The home page
/// is not in the tree; pages with `nav: false` are left out.
fn navTree(arena: Allocator, pages: []const Page, baseurl: []const u8) Allocator.Error!Value {
    const root = try std.fmt.allocPrint(arena, "{s}/", .{baseurl});
    const index = try pageIndex(arena, pages);
    // Each visible page hangs under its nearest ancestor page, or the root.
    var children: std.StringHashMapUnmanaged(std.ArrayList(*const Page)) = .empty;
    for (pages) |*q| {
        if (q.is_post or isHiddenFromNav(q) or std.mem.eql(u8, q.url, root)) continue;
        if (!std.mem.startsWith(u8, q.url, root)) continue;
        var anc = parentUrl(q.url);
        while (anc.len > root.len and index.get(anc) == null) anc = parentUrl(anc);
        if (anc.len < root.len) continue;
        const gop = try children.getOrPut(arena, anc);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, q);
    }
    return navChildren(arena, &index, &children, root);
}

fn navChildren(arena: Allocator, index: *const PageIndex, children: *const std.StringHashMapUnmanaged(std.ArrayList(*const Page)), dir: []const u8) Allocator.Error!Value {
    const kids = (children.get(dir) orelse return .{ .list = &.{} }).items;
    std.mem.sortUnstable(*const Page, kids, sectionSort(index, dir), navLess);
    const out = try arena.alloc(Value, kids.len);
    for (kids, out) |q, *o| {
        const entries = try arena.alloc(Entry, 3);
        entries[0] = .{ .key = "title", .value = .{ .string = navTitle(q) } };
        entries[1] = .{ .key = "url", .value = .{ .string = q.url } };
        entries[2] = .{ .key = "children", .value = if (std.mem.endsWith(u8, q.url, "/")) try navChildren(arena, index, children, q.url) else .{ .list = &.{} } };
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
fn addTagPages(b: *Builder, outputs: *std.ArrayList(Output), tags: []const Value, dir: []const u8) Error!void {
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
            .out_path = try std.fmt.allocPrint(arena, "{s}tags/{s}/index.html", .{ dir, slug }),
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

/// Layouts that turn on generated pages for `taxonomies:`: one per term at
/// `/NAME/SLUG/`, and one per taxonomy at `/NAME/`.
pub const term_layout = "_layouts/term.html";
pub const taxonomy_layout = "_layouts/taxonomy.html";

/// The taxonomy names from `taxonomies: [categories, series]`.
fn taxonomyNames(b: *Builder, config_fields: frontmatter.Map) Error![]const []const u8 {
    const v = config_fields.get("taxonomies") orelse return &.{};
    const line = fieldLine(try b.read(config_path), "taxonomies");
    const items: []const frontmatter.Value = switch (v) {
        .list => |l| l,
        .string => &.{v},
        else => return b.fail(config_path, line, "'taxonomies' must be a list of names such as [categories, series]", .{}),
    };
    var names: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item != .string or item.string.len == 0) return b.fail(config_path, line, "'taxonomies' must be a list of names such as [categories, series]", .{});
        const n = item.string;
        for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
            return b.fail(config_path, line, "taxonomy '{s}' may hold only letters, digits, '-' and '_'", .{n});
        };
        if (std.mem.eql(u8, n, "tags")) return b.fail(config_path, line, "'tags' is built in; leave it out of 'taxonomies'", .{});
        try names.append(b.arena, n);
    }
    return names.items;
}

/// The terms a page lists in frontmatter `field`: a list of strings or
/// one string.
fn pageTerms(arena: Allocator, p: *const Page, field: []const u8) Allocator.Error![]const []const u8 {
    const v = p.fields.get(field) orelse return &.{};
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

/// `site.taxonomies`: for each taxonomy, its terms sorted by name, each
/// with `name`, `slug`, `count`, its `pages` (posts newest first, then
/// pages) and, when term pages are generated, its `url`.
fn taxonomyIndex(arena: Allocator, pages: []const Page, names: []const []const u8, base: ?[]const u8) Allocator.Error!Value {
    var by_name: std.ArrayList(Entry) = .empty;
    for (names) |tax| {
        var term_names: std.ArrayList([]const u8) = .empty;
        var slugs: std.ArrayList([]const u8) = .empty;
        var lists: std.ArrayList(std.ArrayList(Value)) = .empty;
        for (pages) |*p| {
            for (try pageTerms(arena, p, tax)) |term| {
                const slug = try markdown.slugify(arena, term);
                const i = for (slugs.items, 0..) |s, i| {
                    if (std.mem.eql(u8, s, slug)) break i;
                } else blk: {
                    try term_names.append(arena, term);
                    try slugs.append(arena, slug);
                    try lists.append(arena, .empty);
                    break :blk term_names.items.len - 1;
                };
                try lists.items[i].append(arena, .{ .object = p.object });
            }
        }
        const order = try arena.alloc(usize, term_names.items.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sortUnstable(usize, order, term_names.items, struct {
            fn lt(n: [][]const u8, a: usize, c: usize) bool {
                return std.ascii.lessThanIgnoreCase(n[a], n[c]);
            }
        }.lt);
        const terms = try arena.alloc(Value, order.len);
        for (order, terms) |i, *t| {
            var entries: std.ArrayList(Entry) = .empty;
            try entries.append(arena, .{ .key = "name", .value = .{ .string = term_names.items[i] } });
            try entries.append(arena, .{ .key = "slug", .value = .{ .string = slugs.items[i] } });
            try entries.append(arena, .{ .key = "count", .value = .{ .int = @intCast(lists.items[i].items.len) } });
            try entries.append(arena, .{ .key = "pages", .value = .{ .list = lists.items[i].items } });
            if (base) |b| try entries.append(arena, .{ .key = "url", .value = .{ .string = try std.fmt.allocPrint(arena, "{s}/{s}/{s}/", .{ b, tax, slugs.items[i] }) } });
            t.* = .{ .object = .{ .entries = entries.items } };
        }
        try by_name.append(arena, .{ .key = tax, .value = .{ .list = terms } });
    }
    return .{ .object = .{ .entries = by_name.items } };
}

/// Renders the term pages (`term` layout: `page.title` and `page.term`
/// are the term's name, `page.taxonomy` its taxonomy, `page.pages` its
/// pages) and the taxonomy pages (`taxonomy` layout: `page.terms`).
fn addTaxonomyPages(b: *Builder, outputs: *std.ArrayList(Output), index: Value, terms_on: bool, index_on: bool) Error!void {
    const arena = b.arena;
    for (index.object.entries) |tax| {
        if (terms_on) for (tax.value.list) |term| {
            const t = term.object;
            const slug = t.get("slug").?.string;
            try renderGenerated(b, outputs, "term", term_layout, t.get("url").?.string, try std.fmt.allocPrint(arena, "{s}/{s}/index.html", .{ tax.key, slug }), &.{
                .{ .key = "title", .value = t.get("name").? },
                .{ .key = "term", .value = t.get("name").? },
                .{ .key = "taxonomy", .value = .{ .string = tax.key } },
                .{ .key = "pages", .value = t.get("pages").? },
            });
        };
        if (index_on) {
            try renderGenerated(b, outputs, "taxonomy", taxonomy_layout, try std.fmt.allocPrint(arena, "{s}/{s}/", .{ b.baseurl, tax.key }), try std.fmt.allocPrint(arena, "{s}/index.html", .{tax.key}), &.{
                .{ .key = "title", .value = .{ .string = tax.key } },
                .{ .key = "taxonomy", .value = .{ .string = tax.key } },
                .{ .key = "terms", .value = tax.value },
            });
        }
    }
}

/// Renders a page that has no source file, with `layout` and the page
/// fields given.
fn renderGenerated(b: *Builder, outputs: *std.ArrayList(Output), layout: []const u8, source: []const u8, url: []const u8, out_path: []const u8, fields: []const Entry) Error!void {
    const arena = b.arena;
    const layout_field = try arena.dupe(frontmatter.Entry, &.{.{ .key = "layout", .value = .{ .string = layout } }});
    var page: Page = .{
        .source = source,
        .is_post = false,
        .is_markdown = false,
        .fields = .{ .entries = layout_field },
        .body = "",
        .body_line = 1,
        .url = url,
        .out_path = out_path,
        .html = "",
    };
    var entries: std.ArrayList(Entry) = .empty;
    try entries.appendSlice(arena, fields);
    try entries.append(arena, .{ .key = "url", .value = .{ .string = url } });
    try entries.append(arena, .{ .key = "menus", .value = try pageMenus(arena, b.menus, url, try std.fmt.allocPrint(arena, "{s}/", .{b.baseurl})) });
    page.object = .{ .entries = entries.items };
    b.deps = .empty;
    const html = try renderPage(b, &page);
    try outputs.append(arena, .{ .path = out_path, .source = source, .data = .{ .bytes = html } });
}

/// `site.menus`: each named menu as a list of {title, url, weight,
/// external}, ordered by weight, then title. Pages join a menu with
/// frontmatter `menu: NAME` (titled by `menu_title`, else their navigation
/// title); `site.data.menus.NAME` adds links of its own, each
/// {title, url, weight}.
fn menuIndex(b: *Builder, pages: []const Page) Error!Value {
    const arena = b.arena;
    var names: std.ArrayList([]const u8) = .empty;
    var lists: std.ArrayList(std.ArrayList(MenuItem)) = .empty;
    const Add = struct {
        fn list(a: Allocator, n: *std.ArrayList([]const u8), l: *std.ArrayList(std.ArrayList(MenuItem)), name: []const u8) Allocator.Error!*std.ArrayList(MenuItem) {
            for (n.items, 0..) |m, i| if (std.mem.eql(u8, m, name)) return &l.items[i];
            try n.append(a, name);
            try l.append(a, .empty);
            return &l.items[l.items.len - 1];
        }
    };

    if (b.data.object.get("menus")) |data| {
        if (data != .object) return b.fail("_data/menus", 0, "'site.data.menus' must map menu names to lists of links", .{});
        for (data.object.entries) |menu| {
            if (menu.value != .list) return b.fail("_data/menus", 0, "menu '{s}' must be a list of links", .{menu.key});
            const list = try Add.list(arena, &names, &lists, menu.key);
            for (menu.value.list) |item| {
                const o = if (item == .object) item.object else return b.fail("_data/menus", 0, "each link in menu '{s}' must have a title and a url", .{menu.key});
                const title = o.get("title") orelse Value.nil;
                const url = o.get("url") orelse Value.nil;
                if (title != .string or url != .string) return b.fail("_data/menus", 0, "each link in menu '{s}' must have a title and a url", .{menu.key});
                const weight: ?i64 = if (o.get("weight")) |w| switch (w) {
                    .int => |n| n,
                    else => return b.fail("_data/menus", 0, "link '{s}' in menu '{s}' has a 'weight' that is not a whole number", .{ title.string, menu.key }),
                } else null;
                // Root-relative links are inside the site, under `baseurl`.
                const internal = url.string.len > 0 and url.string[0] == '/' and !std.mem.startsWith(u8, url.string, "//");
                const href = if (internal and b.baseurl.len > 0) try std.mem.concat(arena, u8, &.{ b.baseurl, url.string }) else url.string;
                try list.append(arena, .{ .title = title.string, .url = href, .weight = weight, .external = !internal });
            }
        }
    }
    for (pages) |*p| {
        const v = p.fields.get("menu") orelse continue;
        const menus: []const frontmatter.Value = if (v == .list) v.list else &.{v};
        for (menus) |m| {
            const list = try Add.list(arena, &names, &lists, m.string);
            const weight = navWeight(p);
            try list.append(arena, .{
                .title = stringField(p.fields, "menu_title") orelse navTitle(p),
                .url = p.url,
                .weight = if (weight == std.math.maxInt(i64)) null else weight,
                .external = false,
            });
        }
    }

    const out = try arena.alloc(Entry, names.items.len);
    for (names.items, lists.items, out) |name, *list, *o| {
        std.mem.sort(MenuItem, list.items, {}, MenuItem.lessThan);
        const items = try arena.alloc(Value, list.items.len);
        for (list.items, items) |item, *v| v.* = try item.value(arena, &.{});
        o.* = .{ .key = name, .value = .{ .list = items } };
    }
    return .{ .object = .{ .entries = out } };
}

const MenuItem = struct {
    title: []const u8,
    url: []const u8,
    weight: ?i64,
    external: bool,

    fn lessThan(_: void, a: MenuItem, b: MenuItem) bool {
        const wa = a.weight orelse std.math.maxInt(i64);
        const wb = b.weight orelse std.math.maxInt(i64);
        if (wa != wb) return wa < wb;
        return std.mem.lessThan(u8, a.title, b.title);
    }

    fn value(item: MenuItem, arena: Allocator, extra: []const Entry) Allocator.Error!Value {
        var entries: std.ArrayList(Entry) = .empty;
        try entries.append(arena, .{ .key = "title", .value = .{ .string = item.title } });
        try entries.append(arena, .{ .key = "url", .value = .{ .string = item.url } });
        try entries.append(arena, .{ .key = "weight", .value = if (item.weight) |w| .{ .int = w } else .nil });
        try entries.append(arena, .{ .key = "external", .value = .{ .boolean = item.external } });
        try entries.appendSlice(arena, extra);
        return .{ .object = .{ .entries = entries.items } };
    }
};

/// `page.menus`: every menu in `menus` as seen from the page at `url`.
/// Each link gains `active` (it is this page) and `in_section` (this page
/// is below it, as `/docs/setup/` is below `/docs/`).
fn pageMenus(arena: Allocator, menus: Value, url: []const u8, root: []const u8) Allocator.Error!Value {
    const out = try arena.alloc(Entry, menus.object.entries.len);
    for (menus.object.entries, out) |menu, *o| {
        const items = try arena.alloc(Value, menu.value.list.len);
        for (menu.value.list, items) |item, *v| {
            const href = item.object.get("url").?.string;
            const active = std.mem.eql(u8, href, url);
            const in_section = !active and !std.mem.eql(u8, href, root) and
                std.mem.endsWith(u8, href, "/") and std.mem.startsWith(u8, url, href);
            var entries: std.ArrayList(Entry) = .empty;
            try entries.appendSlice(arena, item.object.entries);
            try entries.append(arena, .{ .key = "active", .value = .{ .boolean = active } });
            try entries.append(arena, .{ .key = "in_section", .value = .{ .boolean = in_section } });
            v.* = .{ .object = .{ .entries = entries.items } };
        }
        o.* = .{ .key = menu.key, .value = .{ .list = items } };
    }
    return .{ .object = .{ .entries = out } };
}

/// Adds `page.related` to every page: up to `count` other pages that share
/// the most tags and taxonomy terms with it, newest posts first on ties.
fn addRelated(arena: Allocator, pages: []Page, names: []const []const u8, count: usize) Allocator.Error!void {
    // Every page's terms as "field\x00slug", and the pages of each term.
    const keys = try arena.alloc([]const []const u8, pages.len);
    var by_term: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (pages, keys, 0..) |*p, *k, i| {
        var list: std.ArrayList([]const u8) = .empty;
        const fields = try std.mem.concat(arena, []const u8, &.{ &.{"tags"}, names });
        for (fields) |field| {
            for (try pageTerms(arena, p, field)) |term| {
                const key = try std.mem.concat(arena, u8, &.{ field, "\x00", try markdown.slugify(arena, term) });
                try list.append(arena, key);
                const gop = try by_term.getOrPut(arena, key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                if (gop.value_ptr.items.len == 0 or gop.value_ptr.items[gop.value_ptr.items.len - 1] != i) try gop.value_ptr.append(arena, i);
            }
        }
        k.* = list.items;
    }
    // Related pages appear as they were before getting their own lists.
    const plain = try arena.alloc(template.Object, pages.len);
    for (pages, plain) |p, *o| o.* = p.object;
    const scores = try arena.alloc(u32, pages.len);
    for (pages, keys, 0..) |*p, own, i| {
        @memset(scores, 0);
        for (own) |key| for (by_term.get(key).?.items) |j| {
            if (j != i) scores[j] += 1;
        };
        var picked: std.ArrayList(usize) = .empty;
        for (scores, 0..) |s, j| if (s > 0) try picked.append(arena, j);
        // Pages are in `pageOrder` (newest posts first), so a stable sort
        // by score keeps that order among ties.
        std.mem.sort(usize, picked.items, scores, struct {
            fn lt(sc: []const u32, a: usize, c: usize) bool {
                return sc[a] > sc[c];
            }
        }.lt);
        const n = @min(count, picked.items.len);
        const related = try arena.alloc(Value, n);
        for (related, picked.items[0..n]) |*r, j| r.* = .{ .object = plain[j] };
        var entries: std.ArrayList(Entry) = .empty;
        try entries.appendSlice(arena, p.object.entries);
        try entries.append(arena, .{ .key = "related", .value = .{ .list = related } });
        p.object = .{ .entries = entries.items };
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
        tpl.* = template.parseWith(arena, p.source, p.body, try b.parseOptions(), &td) catch |err| switch (err) {
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
        const tag = try std.fmt.allocPrint(arena, "<script src=\"{s}/{s}\" defer></script>\n", .{ b.baseurl, markdown.copy_script_path });
        content = try insertBeforeBodyEnd(b.arena, content, tag);
        b.uses_copy_script = true;
    }
    if (!std.mem.endsWith(u8, p.out_path, ".html") and !std.mem.endsWith(u8, p.out_path, ".htm")) return content;
    return images.rewrite(arena, content, p.url, b.baseurl, b.images, .{ .ctx = b, .infoFn = imageInfo }, &b.page_variants);
}

/// Whether path names an image `<img>` tags get sizes for.
fn isImagePath(path: []const u8) bool {
    const ext = sitepath.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" }) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// The header of image file path, through the dev server's cache when
/// there is one. Unreadable files have none.
fn readImageInfo(b: *Builder, path: []const u8) Allocator.Error!?images.Info {
    const cache = if (b.options.render_cache) |c| &c.images else null;
    const key = if (cache != null) images.fileKey(b.src, path) else null;
    if (cache) |c| if (key) |k| if (c.infos.get(k)) |hit| return hit;
    const bytes = b.src.readFile(b.arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const result = images.info(bytes);
    if (cache) |c| if (key) |k| try c.infos.put(c.gpa, k, result);
    return result;
}

fn imageInfo(ctx: *anyopaque, path: []const u8) Allocator.Error!?images.Info {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    if (!isImagePath(path)) return null;
    const out = b.static_outputs.get(path) orelse return null;
    try b.addDep(out.source);
    if (b.image_infos.get(path)) |i| return i;
    const result: ?images.Info = switch (out.data) {
        .bytes => |bytes| if (images.info(bytes)) |i| .{ .width = i.width, .height = i.height, .format = i.format, .resizable = false } else null,
        .copy => try readImageInfo(b, out.source),
    };
    try b.image_infos.put(b.arena, path, result);
    return result;
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
        .math = try optIn(b, config_fields, "math"),
        // Liquid sites are written for kramdown, which passes HTML through.
        .raw_html = try configFlag(b, config_fields, "liquid", false),
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
    const loader: template.Loader = .{ .ctx = b, .loadFn = loadInclude, .extendsFn = loadExtends, .relativeFn = loadRelative };
    return template.renderAllocWith(b.arena, tpl, root, loader, .{
        .strict = b.strict,
        .liquid = b.liquid,
        .now = b.now,
        .assets = .{ .ctx = b, .lookupFn = lookupAsset },
        .links = .{ .ctx = b, .lookupFn = lookupLink },
        .stash = b.stash,
    }, &td) catch |err| switch (err) {
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

    // The site's own layout, else the theme's.
    var source: []const u8 = path;
    const data = b.src.readFile(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => blk: {
            const f = (try themeFile(b, path)) orelse return b.fail(used_by, 0, "layout '{s}' not found (looked for {s})", .{ name, path });
            source = f.source;
            break :blk f.data;
        },
        else => return b.fail(path, 0, "cannot read file: {s}", .{@errorName(err)}),
    };
    var fd: frontmatter.Diagnostic = .{};
    const doc = frontmatter.parse(arena, data, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return b.fail(source, fd.line, "{s}", .{fd.message}),
    };
    try b.line_offsets.put(arena, source, doc.body_line - 1);
    var td: template.Diagnostic = .{};
    const tpl = try arena.create(template.Template);
    tpl.* = template.parseWith(arena, source, doc.body, try b.parseOptions(), &td) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TemplateSyntax => return b.templateFail(td),
    };
    var parent: ?[]const u8 = null;
    if (doc.fields.get("layout")) |l| {
        if (l != .string) return b.fail(source, fieldLine(data, "layout"), "'layout' must be a string", .{});
        parent = l.string;
    }
    const layout: Layout = .{ .tpl = tpl, .parent = parent };
    try b.layouts.put(arena, path, layout);
    return layout;
}

const AssetInfo = struct {
    /// Where the file is written: its own path, or with `fingerprint` its
    /// path with the content hash before the extension.
    out_path: []const u8,
    /// `sha384-...` for `integrity=`.
    sri: []const u8,
};

/// Answers the `asset` and `sri` filters for a static file of the site,
/// given as `css/site.css` or `/css/site.css`, and records it as a
/// dependency of the page being rendered.
fn lookupAsset(ctx: *anyopaque, raw: []const u8, kind: template.Assets.Kind, why: *[]const u8) Allocator.Error!?[]const u8 {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    const arena = b.arena;
    const trimmed = std.mem.trimStart(u8, raw, "/");
    const path = sitepath.normalize(arena, if (trimmed.len == 0) "." else trimmed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            why.* = "is not a path inside the site";
            return null;
        },
    };
    if (!findStatic(b.statics, path)) {
        why.* = "is not a static file of the site (rendered pages and generated files have no fixed contents to hash)";
        return null;
    }
    const info = (try assetInfo(b, path)) orelse {
        why.* = "cannot be read";
        return null;
    };
    try b.addDep(path);
    for (b.page_assets.items) |a| {
        if (std.mem.eql(u8, a, path)) break;
    } else try b.page_assets.append(arena, path);
    return switch (kind) {
        .url => try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.baseurl, info.out_path }),
        // In serve, stylesheets are swapped live with new contents that an
        // old hash would reject; an empty integrity attribute checks nothing.
        .sri => if (b.options.fingerprint) info.sri else "",
    };
}

fn assetInfo(b: *Builder, path: []const u8) Allocator.Error!?AssetInfo {
    if (b.asset_info.get(path)) |i| return i;
    const data = b.src.readFile(b.arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &sha256, .{});
    var sha384: [48]u8 = undefined;
    std.crypto.hash.sha2.Sha384.hash(data, &sha384, .{});
    var b64: [64]u8 = undefined;
    const sri = try std.mem.concat(b.arena, u8, &.{ "sha384-", std.base64.standard.Encoder.encode(&b64, &sha384) });
    var out_path = path;
    if (b.fingerprint) {
        const hex = std.fmt.bytesToHex(sha256[0..4].*, .lower);
        const ext = sitepath.extension(path);
        out_path = try std.mem.concat(b.arena, u8, &.{ path[0 .. path.len - ext.len], ".", &hex, ext });
    }
    const info: AssetInfo = .{ .out_path = out_path, .sri = sri };
    try b.asset_info.put(b.arena, path, info);
    return info;
}

/// Writes each fingerprinted file a page names with `asset`, next to its
/// plain copy, which stays for links that do not use the filter.
fn addFingerprinted(b: *Builder, outputs: *std.ArrayList(Output), pages: []const Page, more: []const []const u8) Error!void {
    if (!b.fingerprint) return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (pages) |p| for (p.assets_used) |a| try seen.put(b.arena, a, {});
    for (more) |a| try seen.put(b.arena, a, {});
    var it = seen.keyIterator();
    while (it.next()) |path| {
        const info = (try assetInfo(b, path.*)) orelse continue;
        if (hasOutput(outputs.items, info.out_path)) continue;
        try outputs.append(b.arena, .{ .path = info.out_path, .source = path.*, .data = .copy });
    }
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

/// Loads `_includes/NAME`; a NAME without an extension, as Liquid's
/// `{% render 'card' %}` writes it, may also be `NAME.liquid` or
/// `NAME.html`.
fn loadInclude(ctx: *anyopaque, name: []const u8, diag: *template.Diagnostic) template.Loader.LoadError!*const template.Template {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    const arena = b.arena;
    const raw = try std.fmt.allocPrint(arena, "_includes/{s}", .{name});
    var path = sitepath.normalize(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    // An include name with `..` must not reach outside `_includes/`.
    if (!std.mem.startsWith(u8, path, "_includes/")) return error.TemplateNotFound;
    if (sitepath.extension(path).len == 0 and !b.exists(path)) {
        for ([_][]const u8{ ".liquid", ".html" }) |ext| {
            const with_ext = try std.mem.concat(arena, u8, &.{ path, ext });
            if (b.exists(with_ext)) {
                path = with_ext;
                break;
            }
        }
    }
    return loadTemplateFile(b, path, diag);
}

/// Loads `{% include_relative NAME %}`: NAME relative to the file that
/// holds the tag.
fn loadRelative(ctx: *anyopaque, from: []const u8, name: []const u8, diag: *template.Diagnostic) template.Loader.LoadError!*const template.Template {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    const arena = b.arena;
    // As in Jekyll, the name may not climb out of the file's directory.
    if (std.mem.indexOf(u8, name, "..") != null) return error.TemplateNotFound;
    const raw = if (sitepath.dirname(from)) |dir| try std.mem.concat(arena, u8, &.{ dir, "/", name }) else name;
    const path = sitepath.normalize(arena, raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    return loadTemplateFile(b, path, diag);
}

fn loadTemplateFile(b: *Builder, path: []const u8, diag: *template.Diagnostic) template.Loader.LoadError!*const template.Template {
    const arena = b.arena;
    try b.addDep(path);
    if (b.templates.get(path)) |t| {
        b.useTemplate(t);
        return t;
    }

    // The site's own include, else the theme's.
    var source: []const u8 = path;
    const data = b.src.readFile(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            const f = (themeFile(b, path) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BuildFailed => return error.TemplateNotFound,
            }) orelse return error.TemplateNotFound;
            source = f.source;
            break :blk f.data;
        },
    };
    const tpl = try arena.create(template.Template);
    tpl.* = try template.parseWith(arena, source, data, try b.parseOptions(), diag);
    try b.templates.put(arena, path, tpl);
    b.useTemplate(tpl);
    return tpl;
}

/// Answers `{% link PATH %}` with the URL of the page, post or static file
/// at PATH, and `{% post_url NAME %}` with the URL of the post whose file
/// is NAME (`2024-01-05-hello`), with or without its directory.
fn lookupLink(ctx: *anyopaque, kind: template.Links.Kind, target: []const u8, why: *[]const u8) Allocator.Error!?[]const u8 {
    const b: *Builder = @ptrCast(@alignCast(ctx));
    // The URL changes when the other page's does.
    b.reads_collections = true;
    const t = std.mem.trimStart(u8, target, "/");
    switch (kind) {
        .link => {
            for (b.pages) |p| {
                if (std.mem.eql(u8, p.source, t)) return p.url;
            }
            if (findStatic(b.statics, t)) return try std.fmt.allocPrint(b.arena, "{s}/{s}", .{ b.baseurl, t });
            why.* = "no page, post or file has that path";
        },
        .post_url => {
            for (b.pages) |p| {
                if (!p.is_post) continue;
                const stem_path = p.source[0 .. p.source.len - sitepath.extension(p.source).len];
                const in_posts = stem_path["_posts/".len..];
                if (std.mem.eql(u8, in_posts, t) or std.mem.eql(u8, sitepath.basename(stem_path), t)) return p.url;
            }
            why.* = "no post in _posts/ has that name";
        },
    }
    return null;
}

/// Writes every output into `out`, copying static files from `src`, and
/// `.gz` copies of text files when the site asks for them. Files are
/// written by several workers at once, which matters on file systems where
/// each new file is slow, such as Windows with a virus scanner. On failure,
/// `diag` names the first output, in output order, that could not be
/// written, so the error does not depend on timing.
pub fn writeSite(site: Site, src: SiteDir, out: SiteDir, diag: *Diagnostic) error{BuildFailed}!void {
    return writeSiteWith(site, src, out, false, diag);
}

/// `writeSite`, leaving files that already hold the right bytes untouched
/// when `keep_unchanged` is set: reading and comparing a file costs far
/// less than writing it, above all on Windows.
fn writeSiteWith(site: Site, src: SiteDir, out: SiteDir, keep_unchanged: bool, diag: *Diagnostic) error{BuildFailed}!void {
    const outputs = site.outputs;
    if (outputs.len == 0) return;
    const workers = @min(std.Thread.getCpuCount() catch 1, 16, outputs.len);
    const Worker = struct {
        /// Index of the first output this worker failed to write, if any.
        failed: ?usize = null,
        err: anyerror = error.Unexpected,

        fn run(w: *@This(), st: *const Site, first: usize, step: usize, s: SiteDir, o: SiteDir, keep: bool) void {
            const all = st.outputs;
            var i = first;
            while (i < all.len) : (i += step) {
                const item = all[i];
                writeOne(st, item, s, o, keep) catch |e| {
                    w.failed = i;
                    w.err = e;
                    return;
                };
            }
        }
    };
    var state: [16]Worker = @splat(.{});
    if (workers <= 1) {
        Worker.run(&state[0], &site, 0, 1, src, out, keep_unchanged);
    } else {
        // Outputs are spread round-robin, so every worker gets a mix of
        // directories and sizes.
        var group: std.Io.Group = .init;
        for (state[0..workers], 0..) |*w, k| {
            // Without a free thread, the worker runs here and now.
            group.concurrent(src.io, Worker.run, .{ w, &site, k, workers, src, out, keep_unchanged }) catch Worker.run(w, &site, k, workers, src, out, keep_unchanged);
        }
        group.await(src.io) catch {
            group.cancel(src.io);
            diag.* = .{ .path = "", .message = "canceled" };
            return error.BuildFailed;
        };
    }
    var first: ?usize = null;
    var err: anyerror = error.Unexpected;
    for (state[0..workers]) |w| if (w.failed) |i| if (first == null or i < first.?) {
        first = i;
        err = w.err;
    };
    if (first) |i| {
        diag.* = .{ .path = outputs[i].path, .message = @errorName(err) };
        return error.BuildFailed;
    }
}

/// Writes one output, minified when the site asks, and its `.gz` copy.
/// Each worker makes the directories its files need: with a directory per
/// page, making them one by one up front would take longer than writing
/// the files.
fn writeOne(site: *const Site, o: Output, src: SiteDir, out: SiteDir, keep: bool) !void {
    const minify_it = site.minify and minifiable(o.path);
    if (minify_it) {
        try writeMinified(o, src, out, keep);
    } else switch (o.data) {
        .bytes => |bytes| try putFile(out, o.path, bytes, keep),
        .copy => if (keep) {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena_state.deinit();
            try putFile(out, o.path, try src.readFile(arena_state.allocator(), o.source), true);
        } else try src.copyFileTo(o.source, out, o.path),
    }
    if (site.gzip) try writeGzip(o, src, out, minify_it, keep);
}

/// Writes `data` to `path`, unless `keep` is set and the file already
/// holds exactly `data`.
fn putFile(out: SiteDir, path: []const u8, data: []const u8, keep: bool) !void {
    if (keep and holds(out, path, data)) return;
    try out.writeFile(path, data);
}

/// Whether the file at `path` exists and holds exactly `data`.
fn holds(out: SiteDir, path: []const u8, data: []const u8) bool {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const old = out.dir.readFileAlloc(out.io, path, arena_state.allocator(), .limited(data.len + 1)) catch return false;
    return std.mem.eql(u8, old, data);
}

fn minifiable(path: []const u8) bool {
    const ext = sitepath.extension(path);
    return std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm") or std.mem.eql(u8, ext, ".css");
}

fn minified(arena: Allocator, path: []const u8, data: []const u8) ![]const u8 {
    if (std.mem.eql(u8, sitepath.extension(path), ".css")) return minify.css(arena, data);
    return minify.html(arena, data);
}

fn writeMinified(o: Output, src: SiteDir, out: SiteDir, keep: bool) !void {
    // One scratch arena per file keeps memory flat across a large site.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data = switch (o.data) {
        .bytes => |bytes| bytes,
        .copy => try src.readFile(arena, o.source),
    };
    try putFile(out, o.path, try minified(arena, o.path, data), keep);
}

/// Writes `PATH.gz` for a text output over the size threshold, compressing
/// the minified text when `minify` says the output was minified.
fn writeGzip(o: Output, src: SiteDir, out: SiteDir, minify_first: bool, keep: bool) !void {
    // Outputs are written one after another, so a scratch arena per file
    // keeps memory flat.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gz_path = try std.mem.concat(arena, u8, &.{ o.path, ".gz" });
    if (!gzip.wanted(o.path, gzip.min_size)) return;
    var data = switch (o.data) {
        .bytes => |bytes| bytes,
        .copy => try src.readFile(arena, o.source),
    };
    if (minify_first) data = try minified(arena, o.path, data);
    if (!gzip.wanted(o.path, data.len)) {
        // Written in place, an earlier build's copy may be there.
        if (keep) out.dir.deleteFile(out.io, gz_path) catch {};
        return;
    }
    try putFile(out, gz_path, try gzip.compress(arena, data), keep);
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
    // Swap the new site in before deleting the old one, so `_site` is only
    // missing between two renames, then delete the old one in parallel.
    src.deleteTree(old_output_dir) catch |err| return ioFail(diag, old_output_dir, err);
    const had_old = if (src.dir.rename(output_dir, src.dir, old_output_dir, src.io)) true else |err| switch (err) {
        error.FileNotFound => false,
        else => return ioFail(diag, output_dir, err),
    };
    src.dir.rename(staging_dir, src.dir, output_dir, src.io) catch |err| return ioFail(diag, output_dir, err);
    if (had_old) deleteTreeParallel(src, old_output_dir) catch |err| return ioFail(diag, old_output_dir, err);
}

/// `build --in-place`: writes the site straight into `_site`, leaving
/// files that already hold the right bytes alone and deleting those the
/// build no longer makes. Much faster than `writeOutputDir` when little
/// changed, above all on Windows, where every file written or deleted is
/// costly; but an I/O error partway through leaves `_site` partly updated
/// until the next build.
pub fn writeOutputInPlace(site: Site, src: SiteDir, diag: *Diagnostic) error{BuildFailed}!void {
    var out = src.openSub(output_dir) catch |err| return ioFail(diag, output_dir, err);
    defer out.close();
    // Stale files go first, so that a path can turn from a file into a
    // directory or back.
    removeStale(site, out) catch |err| return ioFail(diag, output_dir, err);
    try writeSiteWith(site, src, out, true, diag);
}

/// Deletes the files in `out` that `site` does not write, then the
/// directories left empty. A `.gz` copy stays when its file does; if
/// it is no longer wanted, writing removes it.
fn removeStale(site: Site, out: SiteDir) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    for (site.outputs) |o| {
        try keep.put(arena, o.path, {});
        if (site.gzip) try keep.put(arena, try std.mem.concat(arena, u8, &.{ o.path, ".gz" }), {});
    }
    var dirs: std.ArrayList([]const u8) = .empty;
    var walker = try out.dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(out.io)) |entry| {
        const path = try arena.dupe(u8, entry.path);
        // The walker joins with the platform's separator.
        if (@import("builtin").os.tag == .windows) std.mem.replaceScalar(u8, path, '\\', '/');
        switch (entry.kind) {
            .directory => try dirs.append(arena, path),
            else => if (!keep.contains(path)) try out.dir.deleteFile(out.io, path),
        }
    }
    // Deepest first; a directory that still holds files stays.
    std.mem.sortUnstable([]const u8, dirs.items, {}, struct {
        fn deeper(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.deeper);
    for (dirs.items) |d| out.dir.deleteDir(out.io, d) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
}

/// Where `writeOutputDir` moves the previous `_site` while it is deleted.
pub const old_output_dir = ".mortise-old";

/// Deletes the directory `sp` with its top-level entries spread over
/// several workers, which is several times faster than one at a time for
/// a big site.
fn deleteTreeParallel(src: SiteDir, sp: []const u8) !void {
    const io = src.io;
    var dir = src.dir.openDir(io, sp, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var names_buf: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer names_buf.deinit();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| try names.append(names_buf.allocator(), try names_buf.allocator().dupe(u8, entry.name));

    const Worker = struct {
        fn run(d: std.Io.Dir, i: std.Io, all: []const []const u8, first: usize, step: usize) void {
            var k = first;
            while (k < all.len) : (k += step) d.deleteTree(i, all[k]) catch {};
        }
    };
    const workers = @min(std.Thread.getCpuCount() catch 1, 16, @max(names.items.len, 1));
    var group: std.Io.Group = .init;
    for (0..workers) |k| {
        group.concurrent(io, Worker.run, .{ dir, io, names.items, k, workers }) catch Worker.run(dir, io, names.items, k, workers);
    }
    group.await(io) catch group.cancel(io);
    // Whatever a worker could not delete makes this fail with its reason.
    try src.deleteTree(sp);
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
    }, "_config.yml", 2, "unknown theme 'borg'; the themes are: visor, lcars, phosphor");
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
    const theme: ThemeLayer = .{ .name = "test", .assets = &.{
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

    const bad: ThemeLayer = .{ .name = "test", .assets = &.{.{ .name = "x", .spec = "kind: radar\nsize: 1\n" }} };
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
    // The previous site is moved aside and deleted, deep folders included.
    try src.writeFile("_site/a/b/c/old.html", "old");
    try writeOutputDir(site, src, &diag);
    try testing.expectEqualStrings("<p>new</p>\n", try src.readFile(a, "_site/index.html"));
    try testing.expectError(error.FileNotFound, src.readFile(a, "_site/a/b/c/old.html"));
    try testing.expectError(error.FileNotFound, src.dir.statFile(testing.io, old_output_dir, .{}));
}

test "writeOutputInPlace writes only what changed and removes what went" {
    var t: TestSite = try .init(&.{
        .{ "index.md", "home\n" },
        .{ "about.md", "about\n" },
        .{ "a.html", "file" },
        .{ "_site/stale.html", "old" },
        .{ "_site/old/dir/x.html", "old" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    try writeOutputInPlace(try t.build(&diag), src, &diag);
    try testing.expectEqualStrings("<p>home</p>\n", try src.readFile(a, "_site/index.html"));
    try testing.expectEqualStrings("file", try src.readFile(a, "_site/a.html"));
    // Files the site does not make are gone, and so are the folders they
    // leave empty.
    try testing.expectError(error.FileNotFound, src.readFile(a, "_site/stale.html"));
    try testing.expectError(error.FileNotFound, src.dir.statFile(testing.io, "_site/old", .{}));

    // A second build leaves unchanged files untouched and rewrites the rest;
    // a file can become a folder.
    const before = try src.dir.statFile(testing.io, "_site/index.html", .{});
    try src.writeFile("about.md", "changed\n");
    try src.deleteTree("a.html");
    try src.writeFile("a.html/index.html", "now a folder");
    try writeOutputInPlace(try t.build(&diag), src, &diag);
    const after = try src.dir.statFile(testing.io, "_site/index.html", .{});
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    try testing.expectEqualStrings("<p>changed</p>\n", try src.readFile(a, "_site/about/index.html"));
    try testing.expectEqualStrings("now a folder", try src.readFile(a, "_site/a.html/index.html"));
    // No staging folder is made.
    try testing.expectError(error.FileNotFound, src.dir.statFile(testing.io, staging_dir, .{}));
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
    // The copy script loads before </body>, once, and only where needed,
    // from one file rather than inline.
    try testing.expect(std.mem.endsWith(u8, a, "<script src=\"/mortise-copy.js\" defer></script>\n</body></html>"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, a, "<script"));
    try testing.expect(std.mem.indexOf(u8, try t.output("b/index.html"), "<script") == null);
    try testing.expectEqualStrings(markdown.copy_script, try t.output("mortise-copy.js"));

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

test "a theme's layouts serve sites without their own, one file at a time" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Site\ntheme: visor\n" },
        .{ "index.md", "---\nlayout: home\n---\nWelcome.\n" },
        .{ "_posts/2024-01-05-hi.md", "---\ntitle: Hi\nlayout: post\n---\nPost.\n" },
        .{ "_includes/footer.html", "<footer>mine</footer>" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    const home = site.find("index.html").?.data.bytes;
    try testing.expect(std.mem.startsWith(u8, home, "<!doctype html>"));
    try testing.expect(std.mem.indexOf(u8, home, "<link rel=\"stylesheet\" href=\"/theme.css\">") != null);
    try testing.expect(std.mem.indexOf(u8, home, "<a href=\"/2024/01/05/hi/\">Hi</a>") != null);
    // The site's footer replaces the theme's; the header is still the theme's.
    try testing.expect(std.mem.indexOf(u8, home, "<footer>mine</footer>") != null);
    try testing.expect(std.mem.indexOf(u8, home, "<a class=\"brand\" href=\"/\">Site</a>") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("2024/01/05/hi/index.html").?.data.bytes, "<p class=\"meta\">January 5, 2024") != null);
}

test "site themes build on built-in themes" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Site\ntheme: night\n" },
        .{ "_themes/night/theme.yml", "base: visor\n" },
        .{ "_themes/night/theme.css", "@import url(\"fonts.css\");\n.night { color: var(--m-accent); }\n" },
        .{ "_themes/night/tokens.yml", "accent: \"#ff9c00\"\n" },
        .{ "_themes/night/_includes/footer.html", "<footer>night</footer>" },
        .{ "about.md", "---\nlayout: page\ntitle: About\n---\nA\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    const css = site.find(themes.css_path).?.data.bytes;
    // Imports first, then tokens (the base's, with the override), then the
    // base's rules, then the site theme's.
    try testing.expect(std.mem.startsWith(u8, css, "@import url(\"fonts.css\");"));
    try testing.expect(std.mem.indexOf(u8, css, "  --m-accent: #ff9c00;\n") != null);
    try testing.expect(std.mem.indexOf(u8, css, "  --m-bg: #04070b;\n") != null);
    const visor_at = std.mem.indexOf(u8, css, "Mortise theme \"visor\"").?;
    try testing.expect(std.mem.indexOf(u8, css, ".night {").? > visor_at);
    try testing.expect(site.find("theme/panel.png") != null);
    const about = site.find("about/index.html").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, about, "<h1>About</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, about, "<footer>night</footer>") != null);

    try expectBuildError(&.{
        .{ "_config.yml", "theme: a\n" },
        .{ "_themes/a/theme.yml", "base: nope\n" },
    }, "_themes/a/theme.yml", 0, "theme 'a' builds on 'nope', which is not a theme");
    try expectBuildError(&.{
        .{ "_config.yml", "theme: a\n" },
        .{ "_themes/a/theme.yml", "base: a\n" },
    }, "_config.yml", 1, "more than 8 deep");
    try expectBuildError(&.{.{ "_config.yml", "title: T\ntheme: core\n" }}, "_config.yml", 2, "unknown theme 'core'");
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected '{s}' in:\n{s}\n", .{ needle, haystack });
        return error.TestUnexpectedResult;
    }
}

test "liquid: true builds a Jekyll-style site" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Jek & Co\nliquid: true\nbaseurl: /blog\nurl: https://example.com\n" },
        .{ "_layouts/default.html", "<title>{{ page.title | default: site.title }}</title>\n{%- include nav.html active=page.url %}\n{{ content }}" },
        .{ "_layouts/post.html", "---\nlayout: default\n---\n<article><time>{{ page.date | date_to_string }}</time>{{ content }}</article>" },
        .{ "_includes/nav.html", "<nav>{% for p in site.pages %}<a href=\"{{ p.url | relative_url }}\"{% if p.url == include.active %} class=\"on\"{% endif %}>{{ p.title }}</a>{% endfor %}</nav>" },
        .{ "_includes/card.liquid", "<b>{{ post.title }}</b>" },
        .{ "index.html", "---\ntitle: Home\nlayout: default\n---\n{% for post in site.posts %}{% render 'card', post: post %}{% endfor %}|{{ site.posts.first.content | strip_html | strip }}|{{ site.time | date: '%Y' | size }}" },
        .{ "about.md", "---\ntitle: About\nlayout: default\n---\nSee [the first post]({% post_url 2024-01-05-hello %}) and [home]({% link index.html %}).\n\n{% raw %}{{ kept }}{% endraw %} {% include_relative snippet.txt %}\n" },
        .{ "snippet.txt", "Snippet." },
        .{ "_posts/2024-01-05-hello.md", "---\ntitle: Hello\nlayout: post\n---\n{% assign n = 3 %}Count: {{ n | times: 2 }}.\n" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = t.build(&diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };

    const index = site.find("index.html").?.data.bytes;
    try expectContains(index, "<title>Home</title><nav>");
    // Mortise URLs hold the baseurl already; relative_url does not add it twice.
    try expectContains(index, "<a href=\"/blog/\" class=\"on\">Home</a>");
    try expectContains(index, "<a href=\"/blog/about/\">About</a>");
    // Other pages see a post's content after its Liquid ran.
    try expectContains(index, "<b>Hello</b>|Count: 6.|4");
    const post = site.find("2024/01/05/hello/index.html").?.data.bytes;
    try expectContains(post, "<title>Hello</title>");
    try expectContains(post, "<article><time>05 Jan 2024</time><p>Count: 6.</p>\n</article>");
    const about = site.find("about/index.html").?.data.bytes;
    try expectContains(about, "<p>See <a href=\"/blog/2024/01/05/hello/\">the first post</a> and <a href=\"/blog/\">home</a>.</p>\n<p>{{ kept }} Snippet.</p>");

    // A file named by include_relative is a dependency of its page.
    try src.writeFile("snippet.txt", "Changed.");
    site = try rebuild(a, src, &site, &.{"snippet.txt"}, &diag);
    try testing.expectEqual(@as(usize, 1), site.rendered);
    try expectContains(site.find("about/index.html").?.data.bytes, "{{ kept }} Changed.");
    // A post's body: the post, and the pages that list posts.
    try src.writeFile("_posts/2024-01-05-hello.md", "---\ntitle: Hello\nlayout: post\n---\nCount: {{ 4 | plus: 1 }}.\n");
    site = try rebuild(a, src, &site, &.{"_posts/2024-01-05-hello.md"}, &diag);
    try expectContains(site.find("index.html").?.data.bytes, "|Count: 5.|");
    try expectSameOutputs(try t.build(&diag), site);
}

test "Liquid errors in Markdown bodies name the file line" {
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\n" },
        .{ "_posts/2024-01-05-a.md", "---\ntitle: A\n---\nfine\n\n{{ x | nope }}\n" },
    }, "_posts/2024-01-05-a.md", 6, "unknown filter 'nope'");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\n" },
        .{ "a.md", "---\ntitle: A\n---\n{% post_url 2020-01-01-missing %}\n" },
    }, "a.md", 4, "no post in _posts/ has that name");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: yes please\n" },
    }, "_config.yml", 1, "'liquid' must be true or false");
}

test "without liquid: true, Markdown bodies are not templates" {
    var t: TestSite = try .init(&.{
        .{ "a.md", "---\ntitle: A\n---\nWrite `{{ page.title }}`.\n" },
    });
    defer t.deinit();
    try expectContains(try t.output("a/index.html"), "<code>{{ page.title }}</code>");
}

test "front matter defaults fill in fields by path and type" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\ndefaults:\n  - scope:\n      path: \"\"\n    values:\n      layout: default\n      author: Ada\n  - scope:\n      type: posts\n    values:\n      layout: post\n  - scope:\n      path: notes\n    values:\n      layout: note\n      tags: [notes]\ntitle: Site\n" },
        .{ "_layouts/default.html", "D:{{ page.author }}:{{ content }}" },
        .{ "_layouts/post.html", "P:{{ page.author }}:{{ content }}" },
        .{ "_layouts/note.html", "N:{{ page.tags | join: ',' }}:{{ site.title }}:{{ content }}" },
        .{ "about.md", "---\ntitle: About\n---\nA" },
        .{ "notes/one.md", "---\ntitle: One\n---\nB" },
        .{ "_posts/2024-01-05-hi.md", "---\ntitle: Hi\nauthor: Bo\n---\nC" },
    });
    defer t.deinit();
    try expectContains(try t.output("about/index.html"), "D:Ada:<p>A</p>");
    try expectContains(try t.output("notes/one/index.html"), "N:notes:Site:<p>B</p>");
    // A file's own front matter wins.
    try expectContains(try t.output("2024/01/05/hi/index.html"), "P:Bo:<p>C</p>");
}

test "front matter defaults need liquid: true and the right shape" {
    try expectBuildError(&.{
        .{ "_config.yml", "title: T\ndefaults:\n  - values:\n      layout: x\n" },
    }, "_config.yml", 2, "'defaults' needs 'liquid: true'");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\ndefaults:\n  - scope:\n      type: posts\n" },
    }, "_config.yml", 2, "each default needs 'values'");
    try expectBuildError(&.{
        // Lines after the block keep their numbers.
        .{ "_config.yml", "liquid: true\ndefaults:\n  - values: {}\ntitle: [a\n" },
    }, "_config.yml", 4, "");
}

test "collections list documents, and publish them with output: true" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\ncollections:\n  recipes:\n    output: true\n    sort_by: order\n  staff:\ndefaults:\n  - scope:\n      type: recipes\n    values:\n      layout: recipe\n" },
        .{ "_layouts/recipe.html", "<h1>{{ page.title }}</h1>{{ page.collection }}|{{ content }}" },
        .{ "_recipes/pancakes.md", "---\ntitle: Pancakes\norder: 2\n---\nFlour and *eggs*." },
        .{ "_recipes/bread.md", "---\ntitle: Bread\norder: 1\n---\nFlour and water." },
        .{ "_recipes/photo.jpg", "jpeg" },
        .{ "_staff/ada.md", "---\nname: Ada\n---\nWrites the {{ 'recipes' | upcase }}." },
        .{ "_staff/bo.md", "---\nname: Bo\n---\nBakes." },
        .{ "index.html", "---\n---\n{% for r in site.recipes %}<a href=\"{{ r.url }}\">{{ r.title }}</a>{% endfor %}|{% for s in site.staff %}{{ s.name }}: {{ s.content | strip_html | strip }} {% endfor %}|{% for c in site.collections %}{{ c.label }}={{ c.docs.size }}/{{ c.output }} {% endfor %}|{{ site.pages.size }}" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = t.build(&diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };
    const index = site.find("index.html").?.data.bytes;
    // sort_by orders the recipes; staff go by path. Documents are not pages.
    try expectContains(index, "<a href=\"/recipes/bread/\">Bread</a><a href=\"/recipes/pancakes/\">Pancakes</a>|Ada: Writes the RECIPES. Bo: Bakes. |posts=0/true recipes=2/true staff=2/false |1");
    try expectContains(site.find("recipes/pancakes/index.html").?.data.bytes, "<h1>Pancakes</h1>recipes|<p>Flour and <em>eggs</em>.</p>");
    try testing.expect(site.find("recipes/photo.jpg") != null);
    // Unpublished documents are not written.
    try testing.expect(site.find("staff/ada/index.html") == null);
    try testing.expect(site.find("_staff/ada.md") == null);

    // Editing an unpublished document updates the pages that list it.
    try src.writeFile("_staff/bo.md", "---\nname: Bo\n---\nBakes rye.");
    site = try rebuild(a, src, &site, &.{"_staff/bo.md"}, &diag);
    try expectContains(site.find("index.html").?.data.bytes, "Bo: Bakes rye.");
    // So does editing a published one.
    try src.writeFile("_recipes/bread.md", "---\ntitle: Sourdough\norder: 1\n---\nStarter.");
    site = try rebuild(a, src, &site, &.{"_recipes/bread.md"}, &diag);
    try expectContains(site.find("index.html").?.data.bytes, ">Sourdough</a>");
    // A new document.
    try src.writeFile("_staff/cy.md", "---\nname: Cy\n---\nSweeps.");
    site = try rebuild(a, src, &site, &.{"_staff/cy.md"}, &diag);
    try expectContains(site.find("index.html").?.data.bytes, "Cy: Sweeps.");
    try expectSameOutputs(try t.build(&diag), site);
}

test "collections need liquid: true and valid names" {
    try expectBuildError(&.{
        .{ "_config.yml", "title: T\ncollections: [recipes]\n" },
    }, "_config.yml", 2, "'collections' needs 'liquid: true'");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\ncollections:\n  pages:\n" },
    }, "_config.yml", 2, "taken by site's own variables");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\nrecipes: 3\ncollections: [recipes]\n" },
    }, "_config.yml", 2, "'recipes' names a collection");
}

/// Builds `files` and checks that each `[2]` pair's source is written at
/// its output path.
fn expectOutputs(files: []const struct { []const u8, []const u8 }, outs: []const [2][]const u8) !void {
    var t: TestSite = try .init(files);
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };
    for (outs) |o| {
        const found = for (site.outputs) |out| {
            if (std.mem.eql(u8, out.path, o[1])) break std.mem.eql(u8, out.source, o[0]);
        } else false;
        if (!found) {
            std.debug.print("expected {s} at {s}; outputs:\n", .{ o[0], o[1] });
            for (site.outputs) |out| std.debug.print("  {s} <- {s}\n", .{ out.path, out.source });
            return error.TestUnexpectedResult;
        }
    }
}

test "permalink styles and templates (Liquid mode)" {
    const posts = .{
        .{ "_posts/2024-01-05-hello.md", "---\ncategories: [Tech, zig]\n---\nx" },
        .{ "_posts/2024-03-09-plain.md", "---\ndate: 2024-03-09 14:30:00\n---\ny" },
        .{ "about.md", "---\n---\nz" },
        .{ "docs/index.md", "---\n---\nw" },
        .{ "tags.html", "---\n---\nt" },
    };
    // Without `permalink:`, posts keep Mortise's URLs, with categories.
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\n" }} ++ posts), &.{
        .{ "_posts/2024-01-05-hello.md", "tech/zig/2024/01/05/hello/index.html" },
        .{ "_posts/2024-03-09-plain.md", "2024/03/09/plain/index.html" },
        .{ "about.md", "about/index.html" },
        .{ "tags.html", "tags.html" },
    });
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: date\n" }} ++ posts), &.{
        .{ "_posts/2024-01-05-hello.md", "tech/zig/2024/01/05/hello.html" },
        .{ "about.md", "about.html" },
        .{ "docs/index.md", "docs/index.html" },
        .{ "tags.html", "tags.html" },
    });
    // `pretty` gives every page a folder.
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: pretty\n" }} ++ posts), &.{
        .{ "_posts/2024-01-05-hello.md", "tech/zig/2024/01/05/hello/index.html" },
        .{ "about.md", "about/index.html" },
        .{ "tags.html", "tags/index.html" },
    });
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: none\n" }} ++ posts), &.{
        .{ "_posts/2024-01-05-hello.md", "tech/zig/hello.html" },
        .{ "_posts/2024-03-09-plain.md", "plain.html" },
    });
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: /blog/:year/:hour:minute-:title\n" }} ++ posts), &.{
        .{ "_posts/2024-03-09-plain.md", "blog/2024/1430-plain.html" },
        .{ "about.md", "about.html" },
    });
}

test "front matter and collection permalinks (Liquid mode)" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\ncollections:\n  recipes:\n    output: true\n    permalink: /cook/:path/\n  staff:\n    output: true\n    permalink: /people/:name:output_ext\n" },
        .{ "_recipes/cakes/Lemon Drizzle.md", "---\n---\na" },
        .{ "_staff/Ada.md", "---\n---\nb" },
        .{ "_posts/2024-01-05-hello.md", "---\ncategory: news\npermalink: /:categories/:title/\n---\n{{ page.categories | join: ',' }}" },
        .{ "a.md", "---\npermalink: /x/:basename/\n---\nc" },
        .{ "b.md", "---\npermalink: /plain/\n---\nd" },
    });
    defer t.deinit();
    try expectContains(try t.output("news/hello/index.html"), "news");
    _ = try t.output("cook/cakes/Lemon Drizzle/index.html");
    _ = try t.output("people/ada.html");
    _ = try t.output("x/a/index.html");
    _ = try t.output("plain/index.html");
}

test "site.static_files lists copied files with front matter defaults" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\nbaseurl: /b\ncollections:\n  shots:\n    output: true\ndefaults:\n  - scope:\n      path: assets/img\n    values:\n      image: true\n  - scope:\n      path: assets\n      type: pages\n    values:\n      typed: true\n" },
        .{ "assets/img/a.png", "png" },
        .{ "assets/img/b.jpg", "jpg" },
        .{ "assets/site.css", "css" },
        .{ "_shots/c.gif", "gif" },
        .{ "about.md", "---\n---\nnot static" },
        .{ "index.html", "---\n---\n{% assign images = site.static_files | where: 'image', true %}{% for f in images %}{{ f.path }}={{ f.url }} {% endfor %}|{% for f in site.static_files %}{{ f.name }}:{{ f.basename }}:{{ f.extname }}:{{ f.collection }}:{{ f.typed }}:{{ f.modified_time | size }} {% endfor %}" },
    });
    defer t.deinit();
    const out = try t.output("index.html");
    try expectContains(out, "/assets/img/a.png=/b/assets/img/a.png /assets/img/b.jpg=/b/assets/img/b.jpg |");
    // Typed defaults never match; the collection's copied files say which.
    try expectContains(out, "c.gif:c:.gif:shots::25 ");
    try expectContains(out, "a.png:a:.png:::25 ");
    try expectContains(out, "site.css:site:.css:::25 ");
    try testing.expect(std.mem.indexOf(u8, out, "about") == null);
}

test "site.tags maps each tag to its posts in Liquid mode, as in Jekyll" {
    const files = .{
        .{ "_posts/2024-01-01-a.md", "---\ntitle: A\ntags: [zig, web]\n---\na" },
        .{ "_posts/2024-02-01-b.md", "---\ntitle: B\ntags: [web, web]\n---\nb" },
        .{ "_posts/2024-03-01-c.md", "---\ntitle: C\ntags: zig\n---\nc" },
    };
    var liquid: TestSite = try .init(&(.{
        .{ "_config.yml", "liquid: true\n" },
        .{ "index.html", "---\n---\n{% for t in site.tags %}{{ t[0] }}:{% for p in t[1] %}{{ p.title }}{% endfor %} {% endfor %}|{{ site.tags.web.size }}" },
    } ++ files));
    defer liquid.deinit();
    // First used by the oldest posts first; each list newest first; a tag a
    // post repeats lists it once.
    try expectContains(try liquid.output("index.html"), "zig:CA web:BA |2");
    // Mortise sites keep the list of tags with names and posts.
    var plain: TestSite = try .init(&(.{
        .{ "index.html", "---\n---\n{% for t in site.tags %}{{ t.name }}={{ t.posts.size }} {% endfor %}" },
    } ++ files));
    defer plain.deinit();
    try expectContains(try plain.output("index.html"), "web=");
}

test "site.categories maps each category to its posts, as in Jekyll" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\n" },
        .{ "_posts/2024-01-01-a.md", "---\ntitle: A\ncategories: news\n---\na" },
        .{ "_posts/2024-02-01-b.md", "---\ntitle: B\ncategories: [Zig, news]\n---\nb" },
        .{ "_posts/2024-03-01-c.md", "---\ntitle: C\ncategory: Zig\n---\nc" },
        .{ "_posts/2024-04-01-d.md", "---\ntitle: D\n---\nd" },
        .{ "index.html", "---\n---\n{% for c in site.categories %}{{ c[0] }}:{% for p in c[1] %}{{ p.title }}{% endfor %} {% endfor %}|{{ site.categories.Zig.size }}|{{ site.categories['news'].first.title }}|{{ site.posts[1].categories | join: '+' }}" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    var site = t.build(&diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };
    // First used by the oldest posts first; each list newest first.
    try expectContains(site.find("index.html").?.data.bytes, "news:BA Zig:CB |2|B|Zig");
    // A post's new category reaches the index on a rebuild.
    try src.writeFile("_posts/2024-04-01-d.md", "---\ntitle: D\ncategory: misc\n---\nd");
    site = try rebuild(a, src, &site, &.{"_posts/2024-04-01-d.md"}, &diag);
    try expectContains(site.find("index.html").?.data.bytes, "Zig:CB misc:D |");
    try expectSameOutputs(try t.build(&diag), site);

    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\ncategories: [a]\n" },
    }, "_config.yml", 0, "'categories' is set by Mortise");
}

test "collection documents follow the site's permalink style" {
    const files = .{
        .{ "_staff/ada.md", "---\n---\nb" },
        .{ "_staff/team/bo.html", "---\n---\nc" },
    };
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: pretty\ncollections:\n  staff:\n    output: true\n" }} ++ files), &.{
        .{ "_staff/ada.md", "staff/ada/index.html" },
        .{ "_staff/team/bo.html", "staff/team/bo/index.html" },
    });
    try expectOutputs(&(.{.{ "_config.yml", "liquid: true\npermalink: date\ncollections:\n  staff:\n    output: true\n" }} ++ files), &.{
        .{ "_staff/ada.md", "staff/ada.html" },
        .{ "_staff/team/bo.html", "staff/team/bo.html" },
    });
}

test "permalink settings are checked" {
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\npermalink: fancy\n" },
    }, "_config.yml", 2, "'permalink' must be date, pretty");
    try expectBuildError(&.{
        .{ "_config.yml", "liquid: true\ncollections:\n  a:\n    permalink: x/:name\n" },
    }, "_config.yml", 2, "must start with '/'");
}

test "raw HTML in Markdown passes through only with liquid: true" {
    const body = "---\ntitle: A\n---\n<div class=\"box\">\n*kept*\n</div>\n\nSome <kbd>Ctrl</kbd> text.\n";
    var liquid: TestSite = try .init(&.{
        .{ "_config.yml", "liquid: true\n" },
        .{ "a.md", body },
    });
    defer liquid.deinit();
    try expectContains(try liquid.output("a/index.html"), "<div class=\"box\">\n*kept*\n</div>\n<p>Some <kbd>Ctrl</kbd> text.</p>");
    var plain: TestSite = try .init(&.{
        .{ "a.md", body },
    });
    defer plain.deinit();
    try expectContains(try plain.output("a/index.html"), "<p>&lt;div class=&quot;box&quot;&gt;\n<em>kept</em>\n&lt;/div&gt;</p>\n<p>Some &lt;kbd&gt;Ctrl&lt;/kbd&gt; text.</p>");
}

test "the asset filter fingerprints static files and gives SRI hashes" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "baseurl: /blog\n" },
        .{ "css/site.css", "body { color: red; }\n" },
        .{ "index.html", "---\n---\n<link href=\"{{ \"css/site.css\" | asset }}\" integrity=\"{{ \"/css/site.css\" | sri }}\">" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const a = t.arena.allocator();

    // build: hashed name, next to the plain copy.
    const site = try buildWith(a, src, .{ .fingerprint = true }, &diag);
    const html = site.find("index.html").?.data.bytes;
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("body { color: red; }\n", &sha, .{});
    const hashed = try std.fmt.allocPrint(a, "css/site.{s}.css", .{&std.fmt.bytesToHex(sha[0..4].*, .lower)});
    try testing.expect(std.mem.indexOf(u8, html, try std.fmt.allocPrint(a, "href=\"/blog/{s}\"", .{hashed})) != null);
    try testing.expect(std.mem.indexOf(u8, html, "integrity=\"sha384-") != null);
    try testing.expect(site.find(hashed).?.data == .copy);
    try testing.expect(site.find("css/site.css") != null);

    // serve: plain names, still with the baseurl.
    const dev = try buildWith(a, src, .{}, &diag);
    try testing.expect(std.mem.indexOf(u8, dev.find("index.html").?.data.bytes, "href=\"/blog/css/site.css\"") != null);
    try testing.expect(std.mem.indexOf(u8, dev.find("index.html").?.data.bytes, "integrity=\"\"") != null);

    // Editing the file re-renders the page with the new hash.
    try src.writeFile("css/site.css", "body { color: blue; }\n");
    const again = try rebuild(a, src, &site, &.{"css/site.css"}, &diag);
    try testing.expectEqual(@as(usize, 1), again.rendered);
    try testing.expect(again.find(hashed) == null);

    try expectBuildError(&.{.{ "a.html", "---\n---\n{{ \"nope.css\" | asset }}" }}, "a.html", 3, "'nope.css' is not a static file");
}

test "minify: true shrinks HTML and CSS when writing" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "minify: true\n" },
        .{ "a.html", "---\n---\n<p>a   b</p>\n\n<!-- note -->\n<pre>  x  </pre>" },
        .{ "s.css", "a {\n  color : red ;\n}\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const site = try t.build(&diag);
    try writeOutputDir(site, src, &diag);
    const a = t.arena.allocator();
    try testing.expectEqualStrings("<p>a b</p>\n<pre>  x  </pre>", try src.readFile(a, "_site/a.html"));
    try testing.expectEqualStrings("a{color:red}", try src.readFile(a, "_site/s.css"));
}

test "frontmatter schemas check pages and fill in defaults" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "schema_json: true\n" },
        .{ "_schemas/posts.yml", "title:\n  type: string\n  required: true\nstatus:\n  enum: [draft, live]\n  default: live\n" },
        .{ "_schemas/docs.yml", "weight:\n  type: int\n  required: true\n" },
        .{ "_posts/2024-01-05-a.md", "---\ntitle: A\nlayout: x\n---\nA\n" },
        .{ "_layouts/x.html", "{{ page.status }}" },
        .{ "docs/b.md", "---\nweight: 2\n---\nB\n" },
        .{ "about.md", "No schema for plain pages here.\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    // The default reaches templates.
    try testing.expectEqualStrings("live", site.find("2024/01/05/a/index.html").?.data.bytes);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, t.arena.allocator(), site.find("schemas/posts.json").?.data.bytes, .{});

    try expectBuildError(&.{
        .{ "_schemas/posts.yml", "title:\n  required: true\n" },
        .{ "_posts/2024-01-05-a.md", "---\nlayout: x\n---\n" },
    }, "_posts/2024-01-05-a.md", 1, "'title' is required by _schemas/posts.yml");
    try expectBuildError(&.{
        .{ "_schemas/docs.yml", "weight:\n  type: int\n" },
        .{ "docs/a.md", "---\ntitle: A\nweight: heavy\n---\n" },
    }, "docs/a.md", 3, "'weight' must be a whole number (_schemas/docs.yml)");
    try expectBuildError(&.{.{ "_schemas/pages.yml", "title:\n  type: words\n" }}, "_schemas/pages.yml", 1, "'title' has a 'type' that is not");
}

test "shortcodes render templates from _includes/shortcodes" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: Site\n" },
        .{ "_includes/shortcodes/note.html", "<aside class=\"{{ args.kind | default(\"info\") }}\">{{ site.title }}/{{ page.title }}: {{ content }}</aside>" },
        .{ "_includes/shortcodes/br.html", "<br>" },
        .{ "a.md", "---\ntitle: A\n---\n{{< note kind=\"warn\" >}}\nHi *there*\n{{< br />}}\n{{< /note >}}\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expectEqualStrings("<aside class=\"warn\">Site/A: <p>Hi <em>there</em></p>\n<br>\n</aside>\n", site.find("a/index.html").?.data.bytes);

    try expectBuildError(&.{.{ "a.md", "---\nx: 1\n---\n\n{{< nope >}}\n" }}, "a.md", 5, "shortcode 'nope': there is no _includes/shortcodes/nope.html");
    try expectBuildError(&.{
        .{ "_includes/shortcodes/bad.html", "\n{{ args }}" },
        .{ "a.md", "{{< bad >}}\n" },
    }, "a.md", 1, "shortcode 'bad': _includes/shortcodes/bad.html:2: cannot output an object");
}

test "taxonomies, their pages, and related pages" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "taxonomies: [categories, series]\nrelated: 2\n" },
        .{ "_layouts/term.html", "{{ page.taxonomy }}/{{ page.term }}:{% for p in page.pages %}[{{ p.title }}]{% endfor %}" },
        .{ "_layouts/taxonomy.html", "{{ page.taxonomy }}:{% for t in page.terms %}[{{ t.name }} {{ t.count }} {{ t.url }}]{% endfor %}" },
        .{ "_layouts/post.html", "{% for r in page.related %}<{{ r.title }}>{% endfor %}" },
        .{ "_posts/2024-01-01-a.md", "---\ntitle: A\nlayout: post\ncategories: [Zig, Web]\ntags: [x]\n---\nA\n" },
        .{ "_posts/2024-02-01-b.md", "---\ntitle: B\nlayout: post\ncategories: Zig\nseries: Intro\n---\nB\n" },
        .{ "_posts/2024-03-01-c.md", "---\ntitle: C\nlayout: post\ncategories: [zig, web]\ntags: [x]\n---\nC\n" },
        .{ "guide.md", "---\ntitle: Guide\nseries: Intro\n---\nG\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    // "Zig" and "zig" are one term, named as first seen (the newest post).
    try testing.expectEqualStrings("categories/zig:[C][B][A]", site.find("categories/zig/index.html").?.data.bytes);
    try testing.expectEqualStrings("series/Intro:[B][Guide]", site.find("series/intro/index.html").?.data.bytes);
    try testing.expectEqualStrings("categories:[web 2 /categories/web/][zig 3 /categories/zig/]", site.find("categories/index.html").?.data.bytes);
    // A shares zig, web and x with C, zig with B.
    try testing.expectEqualStrings("<C><B>", site.find("2024/01/01/a/index.html").?.data.bytes);

    try expectBuildError(&.{.{ "_config.yml", "taxonomies: [tags]\n" }}, "_config.yml", 1, "'tags' is built in");
    try expectBuildError(&.{.{ "_config.yml", "title: T\nrelated: lots\n" }}, "_config.yml", 2, "'related' must be how many");
}

test "named menus and section sort orders" {
    var t: TestSite = try .init(&.{
        .{ "_data/menus/main.json", "[{\"title\": \"Source\", \"url\": \"https://example.com/src\", \"weight\": 9}, {\"title\": \"Home\", \"url\": \"/\", \"weight\": 0}]" },
        .{ "_layouts/l.html", "{% for m in page.menus.main %}[{{ m.title }}{% if m.active %}*{% endif %}{% if m.in_section %}+{% endif %}{% if m.external %}^{% endif %}]{% endfor %}|{% for n in site.nav %}{{ n.title }}:{% for c in n.children %}{{ c.title }},{% endfor %};{% endfor %}" },
        .{ "index.md", "---\nlayout: l\nsort: title\n---\n" },
        .{ "docs/index.md", "---\ntitle: Docs\nlayout: l\nmenu: main\nmenu_title: Guide\nweight: 2\nsort: date\n---\n" },
        .{ "docs/old.md", "---\ntitle: Old\nlayout: l\ndate: 2023-01-01\n---\n" },
        .{ "docs/new.md", "---\ntitle: New\nlayout: l\ndate: 2024-01-01\n---\n" },
        .{ "docs/none.md", "---\ntitle: Aardvark\nlayout: l\n---\n" },
        .{ "about.md", "---\ntitle: About\nlayout: l\nmenu: [main, footer]\nweight: 5\n---\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    // Root pages by title despite weights; /docs/ children newest first,
    // undated last.
    const nav = "|About:;Docs:New,Old,Aardvark,;";
    try testing.expectEqualStrings("[Home][Guide+][About][Source^]" ++ nav, site.find("docs/new/index.html").?.data.bytes);
    try testing.expectEqualStrings("[Home][Guide][About*][Source^]" ++ nav, site.find("about/index.html").?.data.bytes);
    try testing.expectEqualStrings("[Home*][Guide][About][Source^]" ++ nav, site.find("index.html").?.data.bytes);

    try expectBuildError(&.{.{ "a.md", "---\ntitle: A\nsort: size\n---\n" }}, "a.md", 3, "'sort' must be weight");
    try expectBuildError(&.{.{ "a.md", "---\nmenu: 3\n---\n" }}, "a.md", 2, "'menu' must be a menu name");
    try expectBuildError(&.{.{ "_data/menus.json", "{\"main\": [{\"title\": \"X\"}]}" }}, "_data/menus", 0, "must have a title and a url");
}

test "img tags get sizes, lazy loading and resized copies" {
    const gpa = testing.allocator;
    var rgba: [40 * 20 * 4]u8 = undefined;
    @memset(&rgba, 200);
    const wide = try @import("render").png.encodeAlloc(gpa, 40, 20, &rgba, .{});
    defer gpa.free(wide);
    const square = try @import("render").png.encodeAlloc(gpa, 10, 10, rgba[0 .. 10 * 10 * 4], .{});
    defer gpa.free(square);

    var t: TestSite = try .init(&.{
        .{ "_config.yml", "images:\n  widths: [16, 32, 64]\n" },
        .{ "img/wide.png", wide },
        .{ "a/index.md", "![first](../img/wide.png)\n\n![second](/img/wide.png)\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const first = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expectEqualStrings(
        \\<p><img src="../img/wide.png" alt="first" width="40" height="20" srcset="/img/wide.16w.png 16w, /img/wide.32w.png 32w, /img/wide.png 40w" sizes="(min-width: 40px) 40px, 100vw" /></p>
        \\<p><img src="/img/wide.png" alt="second" loading="lazy" decoding="async" width="40" height="20" srcset="/img/wide.16w.png 16w, /img/wide.32w.png 32w, /img/wide.png 40w" sizes="auto, (min-width: 40px) 40px, 100vw" /></p>
        \\
    , first.find("a/index.html").?.data.bytes);
    try testing.expectEqual(@as(?[2]u32, .{ 32, 16 }), @import("render").png.size(first.find("img/wide.32w.png").?.data.bytes));
    try testing.expect(first.find("img/wide.64w.png") == null);

    // Replacing the image re-renders the page with its new size.
    try src.writeFile("img/wide.png", square);
    const second = try rebuild(t.arena.allocator(), src, &first, &.{"img/wide.png"}, &diag);
    try testing.expect(std.mem.indexOf(u8, second.find("a/index.html").?.data.bytes, "width=\"10\" height=\"10\"") != null);
    try testing.expect(second.find("img/wide.16w.png") == null);

    try expectBuildError(&.{.{ "_config.yml", "images:\n  widths: [4]\n" }}, "_config.yml", 1, "'images.widths' must list widths");
    try expectBuildError(&.{.{ "_config.yml", "title: x\nimages:\n  quality: 0\n" }}, "_config.yml", 2, "'images.quality'");
    try expectBuildError(&.{.{ "_config.yml", "images:\n  lazzy: false\n" }}, "_config.yml", 1, "unknown image setting 'lazzy'");
}

test "wikilinks resolve by title, path and file name, with backlinks" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "heading_anchors: false\n" },
        .{ "_layouts/l.html", "{{ content }}|{% for b in page.backlinks %}<{{ b.title }}>{% endfor %}" },
        .{ "docs/install.md", "---\ntitle: Installing Mortise\nlayout: l\n---\n# Linux\n" },
        .{ "about.md", "---\ntitle: About\nlayout: l\n---\n[[installing mortise#Linux]] [[docs/install|setup]] [[install]] [[Nowhere]]\n" },
        .{ "_posts/2024-01-02-news.md", "---\ntitle: News\nlayout: l\n---\nRead [the docs](../../../../docs/install/) and [[#Top]].\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var diag: Diagnostic = .{};
    const first = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expectEqualStrings(
        "<p><a class=\"wikilink\" href=\"/docs/install/#linux\">installing mortise \u{203a} Linux</a> <a class=\"wikilink\" href=\"/docs/install/\">setup</a> " ++
            "<a class=\"wikilink\" href=\"/docs/install/\">install</a> <a class=\"wikilink wikilink-missing\" title=\"No page named Nowhere\">Nowhere</a></p>\n|",
        first.find("about/index.html").?.data.bytes,
    );
    try testing.expectEqualStrings("<h1 id=\"linux\">Linux</h1>\n|<About><News>", first.find("docs/install/index.html").?.data.bytes);
    try testing.expect(std.mem.indexOf(u8, first.find("2024/01/02/news/index.html").?.data.bytes, "href=\"#top\"") != null);

    // A new title still resolves: the page is found by its path.
    try src.writeFile("docs/install.md", "---\ntitle: Setup\nlayout: l\n---\n# Linux\n");
    const second = try rebuild(t.arena.allocator(), src, &first, &.{"docs/install.md"}, &diag);
    try testing.expect(std.mem.indexOf(u8, second.find("about/index.html").?.data.bytes, "title=\"No page named installing mortise\"") != null);
    try testing.expectEqualStrings("<h1 id=\"linux\">Linux</h1>\n|<About><News>", second.find("docs/install/index.html").?.data.bytes);

    try expectBuildError(&.{
        .{ "a/notes.md", "---\ntitle: A\n---\n" },
        .{ "b/notes.md", "---\ntitle: B\n---\n" },
        .{ "c.md", "[[notes]]\n" },
    }, "c.md", 0, "wikilink [[notes]] could mean any of a/notes.md, b/notes.md");
}

test "chart blocks become SVG, and bad specs fail the build" {
    var t: TestSite = try .init(&.{
        .{ "a.md", "```chart\nvalues: [1, 2]\n```\n" },
    });
    defer t.deinit();
    const html = try t.output("a/index.html");
    try testing.expect(std.mem.startsWith(u8, html, "<figure class=\"mt-chart mt-chart-bar\">"));
    // Charts use mortise.css.
    var diag: Diagnostic = .{};
    try testing.expect((try t.build(&diag)).find("mortise.css") != null);
    try expectBuildError(&.{.{ "a.md", "Intro\n\n```chart\nvalues: [1]\nstacked: yes\n```\n" }}, "a.md", 0, "chart, line 2 of its block: unknown chart setting 'stacked'");
}

test "llms.txt, Markdown twins and the JSON feed" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: T\nurl: https://x.dev\nllms: true\njson_feed: true\n" },
        .{ "_posts/2024-01-02-hi.md", "---\ntitle: Hi\n---\nHello *there*.\n" },
        .{ "docs.md", "---\ntitle: Docs\ndescription: How to\n---\nRead me.\n" },
        .{ "secret.md", "---\ntitle: Secret\nllms: false\n---\nNo.\n" },
        .{ "index.html", "---\ntitle: Home\n---\nhome" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try testing.expectEqualStrings("# Hi\n\nHello *there*.\n", site.find("2024/01/02/hi/index.html.md").?.data.bytes);
    try testing.expectEqualStrings("# Docs\n\nRead me.\n", site.find("docs/index.html.md").?.data.bytes);
    try testing.expect(site.find("secret/index.html.md") == null);
    const index = site.find("llms.txt").?.data.bytes;
    try testing.expect(std.mem.indexOf(u8, index, "- [Docs](https://x.dev/docs/index.html.md): How to\n") != null);
    try testing.expect(std.mem.indexOf(u8, index, "- [Home](https://x.dev/)\n") != null);
    try testing.expect(std.mem.indexOf(u8, index, "Secret") == null);
    try testing.expect(std.mem.indexOf(u8, site.find("llms-full.txt").?.data.bytes, "URL: https://x.dev/docs/\n\n# Docs") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("feed.json").?.data.bytes, "\"title\": \"Hi\"") != null);

    try expectBuildError(&.{.{ "_config.yml", "title: T\nllms: yes\n" }}, "_config.yml", 2, "'llms' must be true or false");
}

test "languages: translations, per-language collections, feeds and strings" {
    const layout = "{{ site.lang }}|{{ page.lang }}|{% for t in page.translations %}{{ t.code }}={{ t.url }};{% endfor %}|" ++
        "{% for p in site.posts %}{{ p.title }},{% endfor %}|{{ site.i18n.hello }}|{% for n in site.nav %}{{ n.title }},{% endfor %}|" ++
        "{% for l in site.languages %}{{ l.name }}@{{ l.url }};{% endfor %}";
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: T\nurl: https://x.dev\nlanguages:\n  fr: Français\n  en: English\ndefault_language: en\n" },
        .{ "_data/i18n/en.yml", "hello: Hello\n" },
        .{ "_data/i18n/fr.yml", "hello: Bonjour\n" },
        .{ "_layouts/l.html", layout },
        .{ "about.md", "---\ntitle: About\nlayout: l\n---\n" },
        .{ "about.fr.md", "---\ntitle: À propos\nlayout: l\n---\n" },
        .{ "fr/contact.md", "---\ntitle: Contact\nlayout: l\n---\n" },
        .{ "_posts/2024-01-01-hi.md", "---\ntitle: Hi\nlayout: l\n---\n" },
        .{ "_posts/2024-01-01-hi.fr.md", "---\ntitle: Salut\nlayout: l\n---\n" },
        .{ "_posts/2024-02-01-only.md", "---\ntitle: Only\nlayout: l\n---\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    const langs = "English@/;Français@/fr/;";
    try testing.expectEqualStrings("en|en|fr=/fr/about/;|Only,Hi,|Hello|About,|" ++ langs, site.find("about/index.html").?.data.bytes);
    try testing.expectEqualStrings("fr|fr|en=/about/;|Salut,|Bonjour|Contact,À propos,|" ++ langs, site.find("fr/about/index.html").?.data.bytes);
    try testing.expectEqualStrings("fr|fr||Salut,|Bonjour|Contact,À propos,|" ++ langs, site.find("fr/contact/index.html").?.data.bytes);
    try testing.expect(site.find("fr/2024/01/01/hi/index.html") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("fr/feed.xml").?.data.bytes, "<title>Salut</title>") != null);
    try testing.expect(std.mem.indexOf(u8, site.find("feed.xml").?.data.bytes, "Salut") == null);

    try expectBuildError(&.{.{ "_config.yml", "languages:\n  en: English\ndefault_language: de\n" }}, "_config.yml", 3, "'default_language' must be one of");
    try expectBuildError(&.{.{ "_config.yml", "languages:\n  EN: English\n" }}, "_config.yml", 1, "'EN' is not a language code");
}

test "versioned docs: switcher links, latest links and per-version navigation" {
    const layout = "{{ page.version }}|{% for v in page.versions %}{{ v.name }}{% if v.current %}*{% endif %}={{ v.url }};{% endfor %}|" ++
        "{{ page.latest_url }}|{% if page.outdated %}old{% endif %}|{% for n in page.version_nav %}{{ n.title }},{% endfor %}|" ++
        "{% for v in site.versions %}{{ v.name }}{% if v.latest %}!{% endif %};{% endfor %}";
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "versions: ['2.0', '1.0']\n" },
        .{ "_layouts/l.html", layout },
        .{ "2.0/index.md", "---\ntitle: Docs 2\nlayout: l\n---\n" },
        .{ "2.0/install.md", "---\ntitle: Install\nlayout: l\n---\n" },
        .{ "2.0/plugins.md", "---\ntitle: Plugins\nlayout: l\n---\n" },
        .{ "1.0/index.md", "---\ntitle: Docs 1\nlayout: l\n---\n" },
        .{ "1.0/install.md", "---\ntitle: Install\nlayout: l\n---\n" },
        .{ "about.md", "---\ntitle: About\nlayout: l\n---\n" },
    });
    defer t.deinit();
    var diag: Diagnostic = .{};
    const site = t.build(&diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    const all = "2.0!;1.0;";
    try testing.expectEqualStrings("1.0|2.0=/2.0/install/;1.0*=/1.0/install/;|/2.0/install/|old|Install,|" ++ all, site.find("1.0/install/index.html").?.data.bytes);
    // 1.0 has no plugins page, so its link goes to the 1.0 home page.
    try testing.expectEqualStrings("2.0|2.0*=/2.0/plugins/;1.0=/1.0/;|/2.0/plugins/||Install,Plugins,|" ++ all, site.find("2.0/plugins/index.html").?.data.bytes);
    // Pages outside the versions have none of it.
    try testing.expectEqualStrings("|||||" ++ all, site.find("about/index.html").?.data.bytes);

    try expectBuildError(&.{.{ "_config.yml", "versions: [v1, v1]\n" }}, "_config.yml", 1, "'v1' is listed twice");
    try expectBuildError(&.{.{ "_config.yml", "versions: [a/b]\n" }}, "_config.yml", 1, "plain directory name");
    try expectBuildError(&.{.{ "_config.yml", "versions: [2.0]\n" }}, "_config.yml", 1, "write version numbers in quotes");
}

test "math: true typesets dollar math, and bad math fails the build" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "math: true\n" },
        .{ "a.md", "Euler: $e^{i\\pi} + 1 = 0$\n" },
    });
    defer t.deinit();
    try testing.expect(std.mem.indexOf(u8, try t.output("a/index.html"), "<msup><mi>e</mi><mrow><mi>i</mi><mi>\u{3c0}</mi></mrow></msup>") != null);
    try expectBuildError(&.{
        .{ "_config.yml", "math: true\n" },
        .{ "a.md", "Oops: $\\frac{1}$\n" },
    }, "a.md", 0, "math '\\frac{1}': missing argument");
    try expectBuildError(&.{.{ "_config.yml", "math: yes\n" }}, "_config.yml", 1, "'math' must be true or false");
}

test "mermaid blocks become SVG, and bad ones fail the build" {
    var t: TestSite = try .init(&.{
        .{ "a.md", "```mermaid\ngraph LR\nA --> B\n```\n" },
    });
    defer t.deinit();
    try testing.expect(std.mem.startsWith(u8, try t.output("a/index.html"), "<figure class=\"mt-diagram mt-diagram-flowchart\">"));
    try expectBuildError(&.{.{ "a.md", "```mermaid\ngraph TD\nA[open --> B\n```\n" }}, "a.md", 0, "diagram, line 2 of its block: node 'A' is missing ']'");
}

test "builds are deterministic, also when pages load in parallel" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "title: T\nurl: https://x.dev\n" },
        .{ "_layouts/l.html", "{{ page.title }}|{% for p in site.posts %}{{ p.url }}{% endfor %}|{% for n in site.nav %}{{ n.title }}{% endfor %}{{ content }}" },
        .{ "_layouts/tag.html", "{{ page.tag }}:{% for p in page.posts %}{{ p.title }},{% endfor %}" },
    });
    defer t.deinit();
    // Enough pages that loading is shared out across threads.
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    const a = t.arena.allocator();
    for (0..150) |i| {
        try src.writeFile(try std.fmt.allocPrint(a, "_posts/2024-01-{d:0>2}-p{d}.md", .{ i % 28 + 1, i }), try std.fmt.allocPrint(a, "---\ntitle: P{d}\nlayout: l\ntags: [t{d}]\n---\n# H{d}\n\nText *{d}*.\n", .{ i, i % 5, i, i }));
        try src.writeFile(try std.fmt.allocPrint(a, "docs/d{d}.md", .{i}), try std.fmt.allocPrint(a, "---\ntitle: D{d}\nlayout: l\nweight: {d}\n---\nPage {d}.\n", .{ i, i % 7, i }));
    }
    var diag: Diagnostic = .{};
    const first = try t.build(&diag);
    const second = try t.build(&diag);
    try testing.expectEqual(first.outputs.len, second.outputs.len);
    for (first.outputs, second.outputs) |x, y| {
        try testing.expectEqualStrings(x.path, y.path);
        if (x.data == .bytes) try testing.expectEqualStrings(x.data.bytes, y.data.bytes);
    }

    // With several broken pages, the one reported is the first in path
    // order, however the threads were scheduled.
    try src.writeFile("docs/d3.md", "---\ndraft: never\n---\n");
    try src.writeFile("docs/d90.md", "---\ndraft: maybe\n---\n");
    for (0..3) |_| {
        try testing.expectError(error.BuildFailed, t.build(&diag));
        try testing.expectEqualStrings("docs/d3.md", diag.path);
    }
}

test "fonts listed under fonts.subset shrink to the site's characters in production builds" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "fonts:\n  subset: [fonts/t.ttf]\n" },
        .{ "index.md", "Only A here.\n" },
    });
    defer t.deinit();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    const font = try fonts.testFont(t.arena.allocator());
    try src.writeFile("fonts/t.ttf", font);
    var diag: Diagnostic = .{};
    // The dev server serves the whole font.
    const dev = try buildWith(t.arena.allocator(), src, .{}, &diag);
    try testing.expect(dev.find("fonts/t.ttf").?.data == .copy);
    const prod = try buildWith(t.arena.allocator(), src, .{ .subset_fonts = true }, &diag);
    // The test font's characters are all ASCII, which is always kept, so
    // this only shows the font was rewritten; fonts.zig tests the glyphs.
    const small = prod.find("fonts/t.ttf").?.data.bytes;
    try testing.expectEqual(fonts.Format.sfnt, fonts.format(small).?);

    try expectBuildError(&.{.{ "_config.yml", "fonts:\n  subset: [fonts/missing.ttf]\n" }}, "_config.yml", 1, "font 'fonts/missing.ttf' in 'fonts.subset' is not a file of the site");
    try expectBuildError(&.{.{ "_config.yml", "fonts:\n  sub: [x]\n" }}, "_config.yml", 1, "unknown font setting 'sub'");
}

test "fonts.woff2 writes a WOFF2 copy of each subset font in production builds" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "fonts:\n  subset: [fonts/t.ttf, fonts/c.otf]\n  woff2: true\n" },
        .{ "index.md", "A\n" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    try src.writeFile("fonts/t.ttf", try fonts.testFont(a));
    try src.writeFile("fonts/c.otf", try fonts.testCffFont(a));
    var diag: Diagnostic = .{};
    // `serve` serves the fonts as they are, and no WOFF2.
    const dev = try buildWith(a, src, .{}, &diag);
    try testing.expect(dev.find("fonts/t.woff2") == null);
    const prod = try buildWith(a, src, .{ .subset_fonts = true }, &diag);
    for ([_][]const u8{ "fonts/t.woff2", "fonts/c.woff2" }) |path| {
        const w = prod.find(path).?.data.bytes;
        try testing.expectEqualStrings("wOF2", w[0..4]);
    }
    try testing.expectEqualStrings("OTTO", prod.find("fonts/c.woff2").?.data.bytes[4..8]);

    try src.writeFile("fonts/t.woff2", "mine");
    try testing.expectError(error.BuildFailed, buildWith(a, src, .{ .subset_fonts = true }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "would write fonts/t.woff2") != null);
}

test "a WOFF2 font listed under fonts.subset is subset and stays WOFF2" {
    var t: TestSite = try .init(&.{
        .{ "_config.yml", "fonts:\n  subset: [fonts/c.woff2]\n  woff2: true\n" },
        .{ "index.md", "A\n" },
    });
    defer t.deinit();
    const a = t.arena.allocator();
    const src = SiteDir.borrow(testing.io, t.tmp.dir);
    var fd: fonts.Diagnostic = .{};
    try src.writeFile("fonts/c.woff2", try fonts.toWoff2(a, try fonts.testCffFont(a), &fd));
    var diag: Diagnostic = .{};
    const prod = buildWith(a, src, .{ .subset_fonts = true }, &diag) catch |err| {
        std.debug.print("build failed: {f}\n", .{diag});
        return err;
    };
    const out = prod.find("fonts/c.woff2").?.data.bytes;
    try testing.expectEqual(fonts.Format.woff2, fonts.format(out).?);
    try src.writeFile("fonts/c.woff2", "wOF2 but broken");
    try testing.expectError(error.BuildFailed, buildWith(a, src, .{ .subset_fonts = true }, &diag));
    try testing.expectEqualStrings("fonts/c.woff2", diag.path);
}
