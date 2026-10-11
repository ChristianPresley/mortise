//! Languages. A site with `languages:` in `_config.yml` publishes each page
//! in the language its path names: `about.fr.md` and `fr/about.md` are the
//! French `about`, at `/fr/about/`; pages without a language code are in
//! the default language, at the root. Pages with the same path apart from
//! the language are translations of each other.

const std = @import("std");

pub const Language = struct {
    /// A short code such as `en`, `fr` or `pt-br`, used in paths and URLs.
    code: []const u8,
    /// The language's name in itself, such as `Français`, for menus.
    name: []const u8,
};

/// Whether `code` can name a language: 2 to 12 lowercase letters, digits
/// and hyphens, starting with a letter.
pub fn validCode(code: []const u8) bool {
    if (code.len < 2 or code.len > 12 or !std.ascii.isLower(code[0])) return false;
    for (code) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return false;
    return true;
}

pub const Detected = struct {
    /// Index into the languages; 0 is the default.
    index: u8 = 0,
    /// The path the page's URL is worked out from: the source path without
    /// a `.CODE` suffix.
    path: []const u8,
    /// What the page's translations share: the path without the language,
    /// whether it was a suffix or a leading directory.
    key: []const u8,
    /// Whether the URL needs `/CODE` in front, because the language came
    /// from a suffix rather than a directory.
    prefix: bool = false,
};

/// The language of the page at site path `path`. `languages[0]` is the
/// default; with no languages every page is in it.
pub fn detect(arena: std.mem.Allocator, languages: []const Language, path: []const u8) std.mem.Allocator.Error!Detected {
    var d: Detected = .{ .path = path, .key = path };
    if (languages.len == 0) return d;
    // A leading directory: `fr/about.md`.
    if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
        const first = path[0..slash];
        for (languages[1..], 1..) |l, i| if (std.mem.eql(u8, l.code, first)) {
            d.index = @intCast(i);
            d.key = path[slash + 1 ..];
            return d;
        };
    }
    // A suffix before the extension: `about.fr.md`.
    const base_start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| s + 1 else 0;
    const ext = std.mem.lastIndexOfScalar(u8, path[base_start..], '.') orelse return d;
    const stem = path[base_start .. base_start + ext];
    const dot = std.mem.lastIndexOfScalar(u8, stem, '.') orelse return d;
    const code = stem[dot + 1 ..];
    for (languages, 0..) |l, i| if (std.mem.eql(u8, l.code, code)) {
        // `about.fr.md` becomes `about.md`.
        const cut = base_start + dot;
        const stripped = try std.mem.concat(arena, u8, &.{ path[0..cut], path[base_start + ext ..] });
        d.index = @intCast(i);
        d.path = stripped;
        d.key = stripped;
        d.prefix = i != 0;
        return d;
    };
    return d;
}

const testing = std.testing;

test "detect finds the language in a suffix or a leading directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const langs = [_]Language{ .{ .code = "en", .name = "English" }, .{ .code = "fr", .name = "Français" } };
    const a = try detect(arena, &langs, "docs/about.fr.md");
    try testing.expectEqual(@as(u8, 1), a.index);
    try testing.expectEqualStrings("docs/about.md", a.path);
    try testing.expect(a.prefix);
    const b = try detect(arena, &langs, "fr/docs/about.md");
    try testing.expectEqual(@as(u8, 1), b.index);
    try testing.expectEqualStrings("docs/about.md", b.key);
    try testing.expectEqualStrings("fr/docs/about.md", b.path);
    try testing.expect(!b.prefix);
    const c = try detect(arena, &langs, "about.en.md");
    try testing.expectEqual(@as(u8, 0), c.index);
    try testing.expectEqualStrings("about.md", c.path);
    try testing.expect(!c.prefix);
    const d = try detect(arena, &langs, "notes.v2.md");
    try testing.expectEqual(@as(u8, 0), d.index);
    try testing.expectEqualStrings("notes.v2.md", d.path);
    try testing.expectEqualStrings("_posts/2024-01-01-hi.md", (try detect(arena, &langs, "_posts/2024-01-01-hi.fr.md")).path);
    try testing.expect(validCode("pt-br"));
    try testing.expect(!validCode("FR"));
    try testing.expect(!validCode("x"));
}
