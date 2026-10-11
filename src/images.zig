//! Image tags in rendered pages: intrinsic sizes, lazy loading, and
//! resized copies for `srcset`.
//!
//! After a page renders, every `<img>` whose `src` names a PNG, JPEG, GIF
//! or WebP file of the site gets `width` and `height` from the file's
//! header, so the browser reserves its space before it loads. Every image
//! but the page's first also gets `loading="lazy"` and `decoding="async"`.
//! With `widths` configured, PNG and JPEG images wider than a configured
//! width also get a `srcset` listing copies scaled to each smaller width,
//! written next to the original as `NAME.480w.jpg`, plus a `sizes`.
//! Attributes a template or Markdown already set are left alone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const r = @import("render");
const SiteDir = @import("SiteDir.zig");

pub const Config = struct {
    /// Add `width` and `height`.
    dimensions: bool = true,
    /// Add `loading="lazy"` and `decoding="async"` after the first image.
    lazy: bool = true,
    /// Widths of the resized copies, smallest first. Empty: no `srcset`.
    widths: []const u32 = &.{},
    /// The `sizes` attribute; null means "(min-width: Wpx) Wpx, 100vw" for
    /// an image W pixels wide, after "auto, " for lazy images.
    sizes: ?[]const u8 = null,
    /// JPEG quality of resized copies, 1 to 100.
    quality: u8 = 82,
};

pub const Format = enum { png, jpeg, gif, webp };

pub const Info = struct {
    width: u32,
    height: u32,
    format: Format,
    /// False for images that exist only in memory, such as rendered
    /// graphics, which get sizes but no resized copies.
    resizable: bool = true,
};

/// The displayed size and format of an image file, from its header. JPEGs
/// turned on their side by EXIF orientation report their upright size.
pub fn info(bytes: []const u8) ?Info {
    if (r.png.size(bytes)) |s| return .{ .width = s[0], .height = s[1], .format = .png };
    if (r.jpeg.size(bytes)) |s| {
        const turned = r.jpeg.orientation(bytes) >= 5;
        return .{ .width = if (turned) s[1] else s[0], .height = if (turned) s[0] else s[1], .format = .jpeg };
    }
    if (bytes.len >= 10 and (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a"))) {
        const w = std.mem.readInt(u16, bytes[6..8], .little);
        const h = std.mem.readInt(u16, bytes[8..10], .little);
        if (w > 0 and h > 0) return .{ .width = w, .height = h, .format = .gif };
    }
    if (bytes.len >= 30 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        const chunk = bytes[12..16];
        var w: u32 = 0;
        var h: u32 = 0;
        if (std.mem.eql(u8, chunk, "VP8 ") and std.mem.eql(u8, bytes[23..26], "\x9d\x01\x2a")) {
            w = std.mem.readInt(u16, bytes[26..28], .little) & 0x3fff;
            h = std.mem.readInt(u16, bytes[28..30], .little) & 0x3fff;
        } else if (std.mem.eql(u8, chunk, "VP8L") and bytes[20] == 0x2f) {
            const bits = std.mem.readInt(u32, bytes[21..25], .little);
            w = (bits & 0x3fff) + 1;
            h = ((bits >> 14) & 0x3fff) + 1;
        } else if (std.mem.eql(u8, chunk, "VP8X")) {
            w = std.mem.readInt(u24, bytes[24..27], .little) + 1;
            h = std.mem.readInt(u24, bytes[27..30], .little) + 1;
        }
        if (w > 0 and h > 0) return .{ .width = w, .height = h, .format = .webp };
    }
    return null;
}

/// A resized copy of a site image.
pub const Variant = struct {
    /// Output path, such as `images/photo.480w.jpg`.
    path: []const u8,
    /// Site path of the original.
    source: []const u8,
    width: u32,
    height: u32,
    format: Format,
};

/// Looks up site images for `rewrite`.
pub const Resolver = struct {
    ctx: *anyopaque,
    /// The image at site path `path`, or null when the site publishes no
    /// image there.
    infoFn: *const fn (ctx: *anyopaque, path: []const u8) Allocator.Error!?Info,
};

/// `html` with its `<img>` tags completed as described at the top of this
/// file. `page_url` is the page's URL including `baseurl`. Resized copies
/// the page refers to are appended to `variants`.
pub fn rewrite(
    arena: Allocator,
    html: []const u8,
    page_url: []const u8,
    baseurl: []const u8,
    cfg: Config,
    res: Resolver,
    variants: *std.ArrayList(Variant),
) Allocator.Error![]const u8 {
    if (indexOfIgnoreCase(html, 0, "<img") == null) return html;
    var out: std.ArrayList(u8) = try .initCapacity(arena, html.len + 256);
    var first = true;
    var i: usize = 0;
    var copied: usize = 0;
    while (i < html.len) {
        if (html[i] != '<') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, html[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, html, i + 4, "-->")) |e| e + 3 else html.len;
            continue;
        }
        const name_start = i + 1;
        var j = name_start;
        while (j < html.len and std.ascii.isAlphanumeric(html[j])) j += 1;
        const tag = html[name_start..j];
        if (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style")) {
            const close = if (tag.len == 6) "</script" else "</style";
            i = indexOfIgnoreCase(html, j, close) orelse html.len;
            i += @min(html.len - i, 1);
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(tag, "img")) {
            i = j;
            continue;
        }

        var attrs: std.ArrayList(Attr) = .empty;
        const end = try parseAttrs(arena, html, j, &attrs);
        // Insert before `/>` or `>`.
        var insert = end;
        if (insert > j and html[insert - 1] == '/') insert -= 1;
        while (insert > j and std.ascii.isWhitespace(html[insert - 1])) insert -= 1;
        const extra = try imgAttrs(arena, attrs.items, page_url, baseurl, cfg, res, variants, first);
        first = false;
        if (extra.len > 0) {
            try out.appendSlice(arena, html[copied..insert]);
            try out.appendSlice(arena, extra);
            copied = insert;
        }
        i = @min(html.len, end + 1);
    }
    try out.appendSlice(arena, html[copied..]);
    return out.items;
}

const Attr = struct { name: []const u8, value: ?[]const u8 };

/// Reads attributes from `start` up to the tag's `>`. Returns the index of
/// that `>` (or the end of `html`).
fn parseAttrs(arena: Allocator, html: []const u8, start: usize, attrs: *std.ArrayList(Attr)) Allocator.Error!usize {
    var i = start;
    while (i < html.len and html[i] != '>') {
        if (std.ascii.isWhitespace(html[i]) or html[i] == '/') {
            i += 1;
            continue;
        }
        const an_start = i;
        while (i < html.len and !std.ascii.isWhitespace(html[i]) and html[i] != '=' and html[i] != '>' and html[i] != '/') i += 1;
        const name = html[an_start..i];
        if (name.len == 0) {
            i += 1;
            continue;
        }
        while (i < html.len and html[i] == ' ') i += 1;
        if (i >= html.len or html[i] != '=') {
            try attrs.append(arena, .{ .name = name, .value = null });
            continue;
        }
        i += 1;
        while (i < html.len and html[i] == ' ') i += 1;
        if (i >= html.len) break;
        var value: []const u8 = undefined;
        if (html[i] == '"' or html[i] == '\'') {
            const q = html[i];
            const e = std.mem.indexOfScalarPos(u8, html, i + 1, q) orelse html.len;
            value = html[i + 1 .. e];
            i = @min(html.len, e + 1);
        } else {
            const s = i;
            while (i < html.len and !std.ascii.isWhitespace(html[i]) and html[i] != '>') i += 1;
            value = html[s..i];
        }
        try attrs.append(arena, .{ .name = name, .value = value });
    }
    return i;
}

fn getAttr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value orelse "";
    return null;
}

/// The attributes to add to one `<img>`, each with a leading space.
fn imgAttrs(
    arena: Allocator,
    attrs: []const Attr,
    page_url: []const u8,
    baseurl: []const u8,
    cfg: Config,
    res: Resolver,
    variants: *std.ArrayList(Variant),
    first: bool,
) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lazy = if (getAttr(attrs, "loading")) |l| std.ascii.eqlIgnoreCase(l, "lazy") else false;
    if (cfg.lazy and !first) {
        if (getAttr(attrs, "loading") == null) {
            try out.appendSlice(arena, " loading=\"lazy\"");
            lazy = true;
        }
        if (getAttr(attrs, "decoding") == null) try out.appendSlice(arena, " decoding=\"async\"");
    }
    const src = getAttr(attrs, "src") orelse return out.items;
    const path = try sitePath(arena, try unescapeAmp(arena, src), page_url, baseurl) orelse return out.items;
    const img = try res.infoFn(res.ctx, path) orelse return out.items;

    if (cfg.dimensions and getAttr(attrs, "width") == null and getAttr(attrs, "height") == null) {
        try out.print(arena, " width=\"{d}\" height=\"{d}\"", .{ img.width, img.height });
    }
    if (cfg.widths.len == 0 or getAttr(attrs, "srcset") != null) return out.items;
    if (!img.resizable or (img.format != .png and img.format != .jpeg)) return out.items;

    var set: std.ArrayList(u8) = .empty;
    for (cfg.widths) |w| {
        if (w >= img.width) continue;
        const h: u32 = @intCast(@max(1, (@as(u64, img.height) * w + img.width / 2) / img.width));
        const vpath = try variantPath(arena, path, w);
        try variants.append(arena, .{ .path = vpath, .source = path, .width = w, .height = h, .format = img.format });
        try appendUrl(arena, &set, baseurl, vpath);
        try set.print(arena, " {d}w, ", .{w});
    }
    if (set.items.len == 0) return out.items;
    try appendUrl(arena, &set, baseurl, path);
    try set.print(arena, " {d}w", .{img.width});
    try out.print(arena, " srcset=\"{s}\"", .{set.items});
    if (getAttr(attrs, "sizes") == null) {
        if (cfg.sizes) |s| {
            try out.appendSlice(arena, " sizes=\"");
            try appendEscaped(arena, &out, s);
            try out.append(arena, '"');
        } else {
            // Lazy images may use their laid-out width (`auto`); other
            // browsers take the next entry: the image's own width, at most
            // the viewport's.
            try out.print(arena, " sizes=\"{s}(min-width: {d}px) {d}px, 100vw\"", .{ if (lazy) "auto, " else "", img.width, img.width });
        }
    }
    return out.items;
}

/// `photo.jpg` and 480 give `photo.480w.jpg`.
fn variantPath(arena: Allocator, path: []const u8, width: u32) Allocator.Error![]const u8 {
    const slash = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path[slash..], '.').? + slash;
    return std.fmt.allocPrint(arena, "{s}.{d}w{s}", .{ path[0..dot], width, path[dot..] });
}

/// Appends the URL of site path `path`, encoded for a `srcset` inside a
/// double-quoted attribute.
fn appendUrl(arena: Allocator, out: *std.ArrayList(u8), baseurl: []const u8, path: []const u8) Allocator.Error!void {
    try out.appendSlice(arena, baseurl);
    try out.append(arena, '/');
    for (path) |c| switch (c) {
        ' ' => try out.appendSlice(arena, "%20"),
        ',' => try out.appendSlice(arena, "%2C"),
        '"' => try out.appendSlice(arena, "%22"),
        '&' => try out.appendSlice(arena, "&amp;"),
        else => try out.append(arena, c),
    };
}

fn appendEscaped(arena: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(arena, "&amp;"),
        '"' => try out.appendSlice(arena, "&quot;"),
        '<' => try out.appendSlice(arena, "&lt;"),
        else => try out.append(arena, c),
    };
}

fn unescapeAmp(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "&amp;") == null) return s;
    return std.mem.replaceOwned(u8, arena, s, "&amp;", "&");
}

/// The site path an image URL names, relative to the page at `page_url`,
/// or null for external, data and out-of-site URLs.
fn sitePath(arena: Allocator, raw: []const u8, page_url: []const u8, baseurl: []const u8) Allocator.Error!?[]const u8 {
    var url = std.mem.trim(u8, raw, " \t\r\n");
    if (url.len == 0 or std.mem.startsWith(u8, url, "//")) return null;
    for (url, 0..) |c, k| {
        if (c == ':' and k > 0) return null;
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) break;
    }
    if (std.mem.indexOfAny(u8, url, "?#")) |k| url = url[0..k];
    if (url.len == 0) return null;
    const decoded = try percentDecode(arena, url);
    var joined: []const u8 = undefined;
    if (decoded[0] == '/') {
        if (baseurl.len > 0) {
            if (!std.mem.startsWith(u8, decoded, baseurl) or decoded.len == baseurl.len or decoded[baseurl.len] != '/') return null;
        }
        joined = decoded[baseurl.len..];
    } else {
        const page = if (std.mem.startsWith(u8, page_url, baseurl)) page_url[baseurl.len..] else page_url;
        const dir = page[0 .. (std.mem.lastIndexOfScalar(u8, page, '/') orelse 0) + 1];
        joined = try std.mem.concat(arena, u8, &.{ dir, decoded });
    }
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, joined, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, seg);
    }
    if (parts.items.len == 0) return null;
    return try std.mem.join(arena, "/", parts.items);
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

fn indexOfIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Resizing

/// Resized copies and image headers kept across dev-server builds, keyed by
/// the original's path, size and modification time. Owns its memory.
pub const Cache = struct {
    gpa: Allocator,
    files: std.AutoHashMapUnmanaged(u64, []u8) = .empty,
    infos: std.AutoHashMapUnmanaged(u64, ?Info) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.files.valueIterator();
        while (it.next()) |v| c.gpa.free(v.*);
        c.files.deinit(c.gpa);
        c.infos.deinit(c.gpa);
        c.* = undefined;
    }
};

/// A key for `path` as it is now on disk, or null when it cannot be read.
pub fn fileKey(src: SiteDir, path: []const u8) ?u64 {
    const st = src.stat(path) catch return null;
    var h: std.hash.Wyhash = .init(0);
    h.update(path);
    h.update(std.mem.asBytes(&st.size));
    // Widened so no padding bytes are hashed.
    const mtime: i128 = st.mtime.nanoseconds;
    h.update(std.mem.asBytes(&mtime));
    return h.final();
}

fn variantKey(file: u64, v: Variant, quality: u8) u64 {
    var h: std.hash.Wyhash = .init(file);
    h.update(std.mem.asBytes(&v.width));
    h.update(std.mem.asBytes(&v.height));
    h.update(&.{quality});
    return h.final();
}

pub const ResizeError = Allocator.Error || error{ImageFailed};

/// Why the last `resizeAll` failed: the original's path and the reason.
pub const Failure = struct { path: []const u8 = "", reason: []const u8 = "" };

/// Produces the bytes of every variant, in order. Originals decode once
/// each, concurrently on `io`; with a cache, unchanged ones are not decoded
/// at all. Results live in `arena` or, with a cache, as long as the cache.
pub fn resizeAll(arena: Allocator, io: std.Io, src: SiteDir, variants: []const Variant, quality: u8, cache: ?*Cache, failure: *Failure) ResizeError![]const []const u8 {
    const out = try arena.alloc([]const u8, variants.len);
    @memset(out, "");
    // Group the variants that still need work by original.
    var jobs: std.StringArrayHashMapUnmanaged(Job) = .empty;
    for (variants, out) |v, *o| {
        const key = if (cache != null) fileKey(src, v.source) else null;
        if (cache) |c| if (key) |k| if (c.files.get(variantKey(k, v, quality))) |hit| {
            o.* = hit;
            continue;
        };
        const gop = try jobs.getOrPut(arena, v.source);
        if (!gop.found_existing) gop.value_ptr.* = .{ .source = v.source, .key = key };
        try gop.value_ptr.wanted.append(arena, .{ .variant = v, .out = o });
    }
    if (jobs.count() == 0) return out;

    const Run = struct {
        fn run(job: *Job, s: SiteDir, q: u8) void {
            job.result = job.resize(s, q);
        }
    };
    var group: std.Io.Group = .init;
    for (jobs.values()) |*job| group.async(io, Run.run, .{ job, src, quality });
    group.await(io) catch {
        group.cancel(io);
        return error.OutOfMemory;
    };

    const ta = thread_allocator;
    var failed: ?*Job = null;
    for (jobs.values()) |*job| {
        defer {
            for (job.wanted.items) |w| if (w.bytes.len > 0) ta.free(w.bytes);
        }
        job.result catch |e| {
            if (failed == null) failed = job;
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        for (job.wanted.items) |w| {
            if (cache) |c| {
                if (job.key) |k| {
                    const owned = try c.gpa.dupe(u8, w.bytes);
                    c.files.put(c.gpa, variantKey(k, w.variant, quality), owned) catch |e| {
                        c.gpa.free(owned);
                        return e;
                    };
                    w.out.* = owned;
                    continue;
                }
            }
            w.out.* = try arena.dupe(u8, w.bytes);
        }
    }
    if (failed) |job| {
        failure.* = .{ .path = job.source, .reason = if (job.result) |_| "" else |e| @errorName(e) };
        return error.ImageFailed;
    }
    return out;
}

/// Decoding and encoding happen on worker threads, which cannot share the
/// build's arena.
const thread_allocator = std.heap.smp_allocator;

const Job = struct {
    source: []const u8,
    key: ?u64,
    wanted: std.ArrayList(Wanted) = .empty,
    result: JobError!void = {},

    const Wanted = struct { variant: Variant, out: *[]const u8, bytes: []u8 = &.{} };
    const JobError = Allocator.Error || r.png.DecodeError || r.jpeg.DecodeError || error{ Unreadable, UnsupportedImage };

    fn resize(job: *Job, src: SiteDir, quality: u8) JobError!void {
        const ta = thread_allocator;
        const bytes = src.readFile(ta, job.source) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Unreadable,
        };
        defer ta.free(bytes);
        const format = (info(bytes) orelse return error.UnsupportedImage).format;
        var img = switch (format) {
            .png => try r.png.decode(ta, bytes),
            .jpeg => blk: {
                var img = try r.jpeg.decode(ta, bytes);
                errdefer img.deinit(ta);
                try r.jpeg.orient(ta, &img, r.jpeg.orientation(bytes));
                break :blk img;
            },
            else => return error.UnsupportedImage,
        };
        defer img.deinit(ta);
        for (job.wanted.items) |*w| {
            const v = w.variant;
            if (v.width > img.width or v.height > img.height) return error.UnsupportedImage;
            var small = try r.resize.downscale(ta, img, v.width, v.height);
            defer small.deinit(ta);
            w.bytes = switch (format) {
                .png => try r.png.encodeAlloc(ta, small.width, small.height, small.rgba, .{}),
                else => try r.jpeg.encodeAlloc(ta, small.width, small.height, small.rgba, quality),
            };
        }
    }
};

const testing = std.testing;

test "info reads sizes from headers" {
    var buf: [64]u8 = @splat(0);
    @memcpy(buf[0..10], "GIF89a\x20\x00\x10\x00");
    try testing.expectEqual(Info{ .width = 32, .height = 16, .format = .gif }, info(buf[0..10]).?);
    @memcpy(buf[0..30], "RIFF\x00\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\x3f\x00\x00\x1f\x00\x00");
    try testing.expectEqual(Info{ .width = 64, .height = 32, .format = .webp }, info(buf[0..30]).?);
    try testing.expectEqual(@as(?Info, null), info("<svg/>"));
}

test "sitePath resolves relative and absolute URLs" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("docs/img/a b.png", (try sitePath(a, "img/a%20b.png?v=1", "/blog/docs/intro/../", "/blog")).?);
    try testing.expectEqualStrings("img/x.png", (try sitePath(a, "/blog/img/x.png", "/blog/", "/blog")).?);
    try testing.expectEqual(@as(?[]const u8, null), try sitePath(a, "/other/x.png", "/blog/", "/blog"));
    try testing.expectEqual(@as(?[]const u8, null), try sitePath(a, "https://x.dev/a.png", "/", ""));
    try testing.expectEqual(@as(?[]const u8, null), try sitePath(a, "data:image/png;base64,xx", "/", ""));
    try testing.expectEqual(@as(?[]const u8, null), try sitePath(a, "../../a.png", "/a/", ""));
    try testing.expectEqualStrings("a.html.png", (try sitePath(a, "a.html.png", "/a.html", "")).?);
}

const TestImages = struct {
    fn lookup(_: *anyopaque, path: []const u8) Allocator.Error!?Info {
        if (std.mem.eql(u8, path, "img/big.jpg")) return .{ .width = 1200, .height = 800, .format = .jpeg };
        if (std.mem.eql(u8, path, "img/icon.gif")) return .{ .width = 16, .height = 16, .format = .gif };
        return null;
    }
};

test "rewrite adds sizes, lazy loading and srcset" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var dummy: u8 = 0;
    const res: Resolver = .{ .ctx = &dummy, .infoFn = TestImages.lookup };
    var variants: std.ArrayList(Variant) = .empty;
    const html =
        \\<p><img src="/img/icon.gif" alt="i"></p><script>"<img src=x>"</script>
        \\<!-- <img src="/img/big.jpg"> --><IMG src="../../img/big.jpg" alt="Big" />
        \\<img src="/img/big.jpg" width="10" loading="eager" srcset="a.jpg 1x"><img src="https://x/y.png">
    ;
    const out = try rewrite(a, html, "/posts/a/", "", .{ .widths = &.{ 480, 960, 2000 } }, res, &variants);
    try testing.expectEqualStrings(
        \\<p><img src="/img/icon.gif" alt="i" width="16" height="16"></p><script>"<img src=x>"</script>
        \\<!-- <img src="/img/big.jpg"> --><IMG src="../../img/big.jpg" alt="Big" loading="lazy" decoding="async" width="1200" height="800" srcset="/img/big.480w.jpg 480w, /img/big.960w.jpg 960w, /img/big.jpg 1200w" sizes="auto, (min-width: 1200px) 1200px, 100vw" />
        \\<img src="/img/big.jpg" width="10" loading="eager" srcset="a.jpg 1x" decoding="async"><img src="https://x/y.png" loading="lazy" decoding="async">
    , out);
    try testing.expectEqual(@as(usize, 2), variants.items.len);
    try testing.expectEqualStrings("img/big.480w.jpg", variants.items[0].path);
    try testing.expectEqual(@as(u32, 320), variants.items[0].height);

    // Nothing to do leaves the page as it was.
    const plain = "<p>No images</p>";
    try testing.expectEqual(plain.ptr, (try rewrite(a, plain, "/", "", .{}, res, &variants)).ptr);
}

test "resizeAll scales PNG originals once per width" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = SiteDir.borrow(testing.io, tmp.dir);
    var rgba: [8 * 4 * 4]u8 = undefined;
    for (0..32) |i| rgba[i * 4 ..][0..4].* = .{ @intCast(i * 8), 0, 0, 255 };
    try src.writeFile("p.png", try r.png.encodeAlloc(a, 8, 4, &rgba, .{}));

    const vs = [_]Variant{
        .{ .path = "p.4w.png", .source = "p.png", .width = 4, .height = 2, .format = .png },
        .{ .path = "p.2w.png", .source = "p.png", .width = 2, .height = 1, .format = .png },
    };
    var cache: Cache = .init(testing.allocator);
    defer cache.deinit();
    var failure: Failure = .{};
    const files = try resizeAll(a, testing.io, src, &vs, 80, &cache, &failure);
    try testing.expectEqual(@as(?[2]u32, .{ 4, 2 }), r.png.size(files[0]));
    try testing.expectEqual(@as(?[2]u32, .{ 2, 1 }), r.png.size(files[1]));
    // The second time comes from the cache.
    const again = try resizeAll(a, testing.io, src, &vs, 80, &cache, &failure);
    try testing.expectEqual(files[0].ptr, again[0].ptr);

    try src.writeFile("bad.png", "\x89PNG\r\n\x1a\nnope");
    const bad = [_]Variant{.{ .path = "bad.1w.png", .source = "bad.png", .width = 1, .height = 1, .format = .png }};
    try testing.expectError(error.ImageFailed, resizeAll(a, testing.io, src, &bad, 80, null, &failure));
    try testing.expectEqualStrings("bad.png", failure.path);
}
