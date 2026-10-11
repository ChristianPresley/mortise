//! Site icons: with `icons:` in `_config.yml`, the build draws an emblem
//! with the renderer and writes `favicon.ico` (16, 32 and 48 pixels),
//! `apple-touch-icon.png` (180), `icon-192.png`, `icon-512.png` and a web
//! app manifest, `site.webmanifest`. `site.icon_tags` holds the matching
//! `<head>` tags.
//!
//!   icons: true          # the site title's first letter, the theme's style
//!   icons:
//!     letters: Mo        # one or two characters
//!     style: visor       # plain, visor or lcars
//!     accent: "#ff9c00"  # and background, foreground

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const frontmatter = @import("frontmatter.zig");
const escapeHtml = @import("markdown.zig").escapeHtml;

pub const ico_path = "favicon.ico";
pub const manifest_path = "site.webmanifest";

/// Sizes drawn for `favicon.ico`.
pub const ico_sizes = [_]u32{ 16, 32, 48 };

/// The PNG icons, by output path and size.
pub const pngs = [_]struct { path: []const u8, size: u32 }{
    .{ .path = "apple-touch-icon.png", .size = 180 },
    .{ .path = "icon-192.png", .size = 192 },
    .{ .path = "icon-512.png", .size = 512 },
};

pub const Config = struct {
    letters: []const u8,
    style: []const u8,
    accent: ?[]const u8 = null,
    background: ?[]const u8 = null,
    foreground: ?[]const u8 = null,
    name: []const u8,
    /// The manifest's theme color: the icon's background.
    theme_color: []const u8,
};

pub const Diagnostic = struct { key: []const u8 = "", message: []const u8 = "" };

/// Reads `icons:` from the config, or returns null when it is absent or
/// false. `theme` picks the default style.
pub fn config(arena: Allocator, v: ?frontmatter.Value, site_title: []const u8, theme: ?[]const u8, diag: *Diagnostic) error{ InvalidIcons, OutOfMemory }!?Config {
    const value = v orelse return null;
    const default_style: []const u8 = if (theme) |t| (if (std.mem.eql(u8, t, "visor") or std.mem.eql(u8, t, "lcars")) t else "plain") else "plain";
    var c: Config = .{
        .letters = firstLetter(site_title),
        .style = default_style,
        .name = if (site_title.len > 0) site_title else "Site",
        .theme_color = "",
    };
    switch (value) {
        .boolean => |on| if (!on) return null,
        .map => |m| for (m.entries) |e| {
            const s = if (e.value == .string) e.value.string else {
                diag.* = .{ .key = e.key, .message = "must be text" };
                return error.InvalidIcons;
            };
            if (std.mem.eql(u8, e.key, "letters")) {
                if (s.len == 0) {
                    diag.* = .{ .key = e.key, .message = "must hold one or two characters" };
                    return error.InvalidIcons;
                }
                c.letters = s;
            } else if (std.mem.eql(u8, e.key, "style")) {
                if (!(std.mem.eql(u8, s, "plain") or std.mem.eql(u8, s, "visor") or std.mem.eql(u8, s, "lcars"))) {
                    diag.* = .{ .key = e.key, .message = "must be plain, visor or lcars" };
                    return error.InvalidIcons;
                }
                c.style = s;
            } else if (std.mem.eql(u8, e.key, "accent") or std.mem.eql(u8, e.key, "background") or std.mem.eql(u8, e.key, "foreground")) {
                if (!isHex(s)) {
                    diag.* = .{ .key = e.key, .message = "must be a color such as \"#3fd8ff\"" };
                    return error.InvalidIcons;
                }
                if (e.key[0] == 'a') c.accent = s else if (e.key[0] == 'b') c.background = s else c.foreground = s;
            } else if (std.mem.eql(u8, e.key, "name")) {
                c.name = s;
            } else {
                diag.* = .{ .key = e.key, .message = "is not an icons setting; use letters, style, accent, background, foreground or name" };
                return error.InvalidIcons;
            }
        },
        else => {
            diag.* = .{ .key = "icons", .message = "must be true, false, or a map of settings" };
            return error.InvalidIcons;
        },
    }
    c.theme_color = c.background orelse if (std.mem.eql(u8, c.style, "visor"))
        "#050b16"
    else if (std.mem.eql(u8, c.style, "lcars"))
        "#000000"
    else
        c.accent orelse "#c2410c";
    _ = arena;
    return c;
}

fn firstLetter(title: []const u8) []const u8 {
    const t = std.mem.trimStart(u8, title, " ");
    if (t.len == 0) return "M";
    const n = std.unicode.utf8ByteSequenceLength(t[0]) catch 1;
    return t[0..@min(n, t.len)];
}

fn isHex(s: []const u8) bool {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else return false;
    if (h.len != 3 and h.len != 6) return false;
    for (h) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// The render spec for one size of the icon.
pub fn spec(arena: Allocator, c: Config, size: u32) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "kind: icon\nsize: {d}\nstyle: {s}\nletters: \"", .{ size, c.style });
    for (c.letters) |ch| {
        if (ch == '"' or ch == '\\') try out.append(arena, '\\');
        try out.append(arena, ch);
    }
    try out.appendSlice(arena, "\"\n");
    if (c.accent) |a| try out.print(arena, "accent: \"{s}\"\n", .{a});
    if (c.background) |a| try out.print(arena, "background: \"{s}\"\n", .{a});
    if (c.foreground) |a| try out.print(arena, "foreground: \"{s}\"\n", .{a});
    return out.items;
}

/// `site.webmanifest`: the name, the 192 and 512 pixel icons, and colors.
pub fn manifest(arena: Allocator, c: Config, baseurl: []const u8) Allocator.Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    (blk: {
        w.writeAll("{\n  \"name\": ") catch |e| break :blk e;
        std.json.Stringify.value(c.name, .{}, w) catch |e| break :blk e;
        w.writeAll(",\n  \"short_name\": ") catch |e| break :blk e;
        std.json.Stringify.value(c.name, .{}, w) catch |e| break :blk e;
        w.print(",\n  \"start_url\": \"{s}/\",\n  \"display\": \"standalone\",\n", .{baseurl}) catch |e| break :blk e;
        w.print("  \"theme_color\": \"{s}\",\n  \"background_color\": \"{s}\",\n  \"icons\": [\n", .{ c.theme_color, c.theme_color }) catch |e| break :blk e;
        w.print("    {{ \"src\": \"{s}/icon-192.png\", \"sizes\": \"192x192\", \"type\": \"image/png\" }},\n", .{baseurl}) catch |e| break :blk e;
        w.print("    {{ \"src\": \"{s}/icon-512.png\", \"sizes\": \"512x512\", \"type\": \"image/png\" }}\n  ]\n}}\n", .{baseurl}) catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.written();
}

/// The `<head>` tags for the icons, as `site.icon_tags`.
pub fn tags(arena: Allocator, c: Config, baseurl: []const u8) Allocator.Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    const w = &aw.writer;
    (blk: {
        w.print("<link rel=\"icon\" href=\"{s}/favicon.ico\" sizes=\"48x48\">\n", .{baseurl}) catch |e| break :blk e;
        w.print("<link rel=\"icon\" href=\"{s}/icon-192.png\" type=\"image/png\" sizes=\"192x192\">\n", .{baseurl}) catch |e| break :blk e;
        w.print("<link rel=\"apple-touch-icon\" href=\"{s}/apple-touch-icon.png\">\n", .{baseurl}) catch |e| break :blk e;
        w.print("<link rel=\"manifest\" href=\"{s}/site.webmanifest\">\n", .{baseurl}) catch |e| break :blk e;
        w.writeAll("<meta name=\"theme-color\" content=\"") catch |e| break :blk e;
        escapeHtml(w, c.theme_color) catch |e| break :blk e;
        w.writeAll("\">\n") catch |e| break :blk e;
    }) catch return error.OutOfMemory;
    return aw.written();
}

const testing = std.testing;

fn parse(arena: Allocator, src: []const u8) !frontmatter.Value {
    var fd: frontmatter.Diagnostic = .{};
    const m = try frontmatter.parseFile(arena, src, &fd);
    return m.get("icons").?;
}

test "config defaults and settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const on = (try config(a, .{ .boolean = true }, "mortise docs", "visor", &d)).?;
    try testing.expectEqualStrings("m", on.letters);
    try testing.expectEqualStrings("visor", on.style);
    try testing.expectEqualStrings("#050b16", on.theme_color);
    try testing.expect(try config(a, .{ .boolean = false }, "x", null, &d) == null);
    try testing.expect(try config(a, null, "x", null, &d) == null);
    const m = (try config(a, try parse(a, "icons:\n  letters: Mo\n  accent: \"#123456\"\n"), "x", null, &d)).?;
    try testing.expectEqualStrings("Mo", m.letters);
    try testing.expectEqualStrings("plain", m.style);
    try testing.expectEqualStrings("#123456", m.theme_color);
    try testing.expectEqualStrings("kind: icon\nsize: 32\nstyle: plain\nletters: \"Mo\"\naccent: \"#123456\"\n", try spec(a, m, 32));
    try testing.expectError(error.InvalidIcons, config(a, try parse(a, "icons:\n  style: neon\n"), "x", null, &d));
    try testing.expectEqualStrings("style", d.key);
}

test "manifest and tags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c: Config = .{ .letters = "M", .style = "plain", .name = "My \"Site\"", .theme_color = "#c2410c" };
    const m = try manifest(a, c, "/blog");
    try testing.expect(std.mem.indexOf(u8, m, "\"name\": \"My \\\"Site\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, m, "\"src\": \"/blog/icon-512.png\"") != null);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, a, m, .{});
    const t = try tags(a, c, "");
    try testing.expect(std.mem.startsWith(u8, t, "<link rel=\"icon\" href=\"/favicon.ico\" sizes=\"48x48\">\n"));
    try testing.expect(std.mem.endsWith(u8, t, "<meta name=\"theme-color\" content=\"#c2410c\">\n"));
}
