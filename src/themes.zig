//! Built-in themes. `theme: NAME` in `_config.yml` writes the theme's
//! stylesheet to `/theme.css`; a layout links it after its own stylesheet:
//!
//!   {% if site.theme %}<link rel="stylesheet" href="{{ site.baseurl }}/theme.css">{% endif %}
//!
//! Themes are CSS, design tokens, rendered images and templates. They style
//! HTML elements, Mortise's `mt-` components, and the layout hooks listed
//! in docs/themes.md. A theme can build on another (`base`): it inherits
//! the base's stylesheet, tokens, images and templates and replaces or adds
//! to them. A site's own layouts and includes replace a theme's one file at
//! a time, and a site can define its own themes in `_themes/NAME/`.

const std = @import("std");

pub const css_path = "theme.css";

pub const Theme = struct {
    name: []const u8,
    css: []const u8 = "",
    /// The theme's design tokens (see tokens.zig), in frontmatter format.
    /// The build writes them as `--m-NAME` properties above `css`, after
    /// any leading `@import` rules.
    tokens: []const u8 = "",
    /// Images the build renders for the theme. The stylesheet refers to
    /// them relative to itself, as `url("theme/NAME.png")`.
    assets: []const Asset = &.{},
    /// The theme this one builds on, or null.
    base: ?[]const u8 = null,
    /// Layouts and includes, by site path (`_layouts/post.html`).
    files: []const File = &.{},
    /// Only for building on; not offered as `theme:`.
    hidden: bool = false,
};

/// A rendered image a theme ships, written to `/theme/NAME.png` (and
/// `/theme/NAME.css` for kinds that come with CSS). `spec` uses the same
/// format as a site's `_render/*.yml` files; see docs/rendering.md.
pub const Asset = struct {
    name: []const u8,
    spec: []const u8,
};

pub const File = struct {
    path: []const u8,
    data: []const u8,
};

/// Output directory of theme assets.
pub const assets_dir = "theme";

/// Layouts and includes every built-in theme starts from: a page layout
/// with a header, navigation from `site.nav` and a footer, plus `page`,
/// `post` and `home` layouts.
const core_files = [_]File{
    .{ .path = "_layouts/default.html", .data = @embedFile("themes/core/_layouts/default.html") },
    .{ .path = "_layouts/page.html", .data = @embedFile("themes/core/_layouts/page.html") },
    .{ .path = "_layouts/post.html", .data = @embedFile("themes/core/_layouts/post.html") },
    .{ .path = "_layouts/home.html", .data = @embedFile("themes/core/_layouts/home.html") },
    .{ .path = "_includes/head.html", .data = @embedFile("themes/core/_includes/head.html") },
    .{ .path = "_includes/header.html", .data = @embedFile("themes/core/_includes/header.html") },
    .{ .path = "_includes/footer.html", .data = @embedFile("themes/core/_includes/footer.html") },
};

pub const all = [_]Theme{
    .{ .name = "core", .css = @embedFile("themes/core/core.css"), .files = &core_files, .hidden = true },
    .{ .name = "visor", .base = "core", .css = @embedFile("themes/visor.css"), .tokens = @embedFile("themes/visor/tokens.yml"), .assets = &.{
        .{ .name = "panel", .spec = @embedFile("themes/visor/panel.yml") },
    } },
    .{ .name = "lcars", .base = "core", .css = @embedFile("themes/lcars.css"), .tokens = @embedFile("themes/lcars/tokens.yml"), .assets = &.{
        .{ .name = "planet", .spec = @embedFile("themes/lcars/planet.yml") },
        .{ .name = "hologram", .spec = @embedFile("themes/lcars/hologram.yml") },
    } },
    plain("phosphor"),
    plain("cyberdeck"),
    plain("freighter"),
    plain("grid"),
    plain("codex"),
    plain("cockpit"),
    plain("scanvisor"),
};

/// A theme on `core` made of `themes/NAME.css` and `themes/NAME/tokens.yml`.
fn plain(comptime name: []const u8) Theme {
    return .{ .name = name, .base = "core", .css = @embedFile("themes/" ++ name ++ ".css"), .tokens = @embedFile("themes/" ++ name ++ "/tokens.yml") };
}

/// The built-in theme `name`, including hidden ones (for `base`).
pub fn find(name: []const u8) ?Theme {
    for (all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// "visor, lcars, ...", for error messages: the themes a site can pick.
pub const names = blk: {
    var s: []const u8 = "";
    for (all) |t| {
        if (t.hidden) continue;
        s = s ++ (if (s.len == 0) "" else ", ") ++ t.name;
    }
    break :blk s;
};

pub fn file(t: Theme, path: []const u8) ?[]const u8 {
    for (t.files) |f| if (std.mem.eql(u8, f.path, path)) return f.data;
    return null;
}

test "find" {
    try std.testing.expect(find("visor") != null);
    try std.testing.expect(find("lcars") != null);
    try std.testing.expect(find("nope") == null);
    try std.testing.expectEqualStrings("visor, lcars, phosphor, cyberdeck, freighter, grid, codex, cockpit, scanvisor", names);
    try std.testing.expect(file(find("core").?, "_layouts/post.html") != null);
}
