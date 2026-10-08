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
};

pub const Site = struct {
    /// Every output file, sorted by path.
    outputs: []const Output,
    /// Rendered outputs and the sources each one read.
    deps: []const Deps,
    pages: usize,
    posts: usize,
    static_files: usize,

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

const Page = struct {
    source: []const u8,
    is_post: bool,
    is_markdown: bool,
    fields: frontmatter.Map,
    body: []const u8,
    body_line: usize,
    url: []const u8,
    out_path: []const u8,
    /// Rendered Markdown, or null for HTML templates.
    html: ?[]const u8,
    object: template.Object = .{},
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

    fn addDep(b: *Builder, path: []const u8) Allocator.Error!void {
        for (b.deps.items) |d| if (std.mem.eql(u8, d, path)) return;
        try b.deps.append(b.arena, path);
    }

    fn templateFail(b: *Builder, d: template.Diagnostic) Error {
        const offset = b.line_offsets.get(d.template) orelse 0;
        b.diag.* = .{ .path = d.template, .line = d.line + offset, .message = d.message };
        return error.BuildFailed;
    }
};

/// Builds the site in `src`. On `error.BuildFailed`, `diag` says why.
pub fn build(arena: Allocator, src: SiteDir, diag: *Diagnostic) Error!Site {
    var b: Builder = .{ .arena = arena, .src = src, .diag = diag };

    var bad: ?[]const u8 = null;
    const listing = src.listFiles(arena, &bad) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidPath => return b.fail(bad.?, 0, "file name is not portable across platforms; rename it", .{}),
        else => return b.fail("", 0, "cannot list the source directory: {s}", .{@errorName(err)}),
    };

    var pages: std.ArrayList(Page) = .empty;
    var outputs: std.ArrayList(Output) = .empty;
    var config_fields: frontmatter.Map = .{};
    var static_files: usize = 0;

    for (listing.files) |path| {
        if (std.mem.eql(u8, path, config_path)) {
            var fd: frontmatter.Diagnostic = .{};
            config_fields = frontmatter.parseFile(arena, try b.read(path), &fd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidFrontmatter => return b.fail(path, fd.line, "{s}", .{fd.message}),
            };
            continue;
        }
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
            try outputs.append(arena, .{ .path = path, .source = path, .data = .copy });
            static_files += 1;
        }
    }

    // Pages and posts are visible to every template through `site`.
    var post_values: std.ArrayList(Value) = .empty;
    var page_values: std.ArrayList(Value) = .empty;
    std.mem.sortUnstable(Page, pages.items, {}, pageOrder);
    var post_count: usize = 0;
    for (pages.items) |*p| {
        p.object = try pageObject(arena, p);
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
        try site_entries.append(arena, .{ .key = e.key, .value = try convert(arena, e.value) });
    }
    try site_entries.append(arena, .{ .key = "posts", .value = .{ .list = post_values.items } });
    try site_entries.append(arena, .{ .key = "pages", .value = .{ .list = page_values.items } });
    b.site = .{ .entries = site_entries.items };

    var deps: std.ArrayList(Deps) = .empty;
    for (pages.items) |*p| {
        b.deps = .empty;
        try b.addDep(p.source);
        const html = try renderPage(&b, p);
        try outputs.append(arena, .{ .path = p.out_path, .source = p.source, .data = .{ .bytes = html } });
        try deps.append(arena, .{ .output = p.out_path, .sources = b.deps.items });
    }

    std.mem.sortUnstable(Output, outputs.items, {}, outputOrder);
    for (outputs.items[0..outputs.items.len -| 1], outputs.items[@min(1, outputs.items.len)..]) |a, c| {
        if (std.mem.eql(u8, a.path, c.path)) {
            return b.fail(c.source, 0, "writes to '{s}', which '{s}' also writes to", .{ c.path, a.source });
        }
    }

    return .{
        .outputs = outputs.items,
        .deps = deps.items,
        .pages = pages.items.len - post_count,
        .posts = post_count,
        .static_files = static_files,
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

    if (doc.fields.get("permalink")) |pl| {
        const line = fieldLine(data, "permalink");
        if (pl != .string or pl.string.len == 0 or pl.string[0] != '/') {
            return b.fail(path, line, "'permalink' must be a string starting with '/'", .{});
        }
        page.url = pl.string;
    } else if (is_post) {
        const base = sitepath.basename(path);
        const date = if (base.len > 11) template.parseDate(base[0..10]) else null;
        if (date == null or base[10] != '-' or sitepath.stem(base).len <= 11) {
            return b.fail(path, 0, "post file names must look like YYYY-MM-DD-slug.md", .{});
        }
        page.url = try std.fmt.allocPrint(arena, "/{s}/{s}/{s}/{s}/", .{ base[0..4], base[5..7], base[8..10], sitepath.stem(base)[11..] });
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
        const ad = sitepath.basename(a.source)[0..10];
        const cd = sitepath.basename(c.source)[0..10];
        switch (std.mem.order(u8, ad, cd)) {
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
            try entries.append(arena, .{ .key = "date", .value = .{ .string = base[0..10] } });
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
    if (b.templates.get(path)) |t| return t;

    const data = b.src.readFile(arena, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TemplateNotFound,
    };
    const tpl = try arena.create(template.Template);
    tpl.* = try template.parse(arena, path, data, diag);
    try b.templates.put(arena, path, tpl);
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
