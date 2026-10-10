//! Built-in themes. `theme: NAME` in `_config.yml` writes the theme's
//! stylesheet to `/theme.css`; a layout links it after its own stylesheet:
//!
//!   {% if site.theme %}<link rel="stylesheet" href="{{ site.baseurl }}/theme.css">{% endif %}
//!
//! Themes are plain CSS. They style HTML elements, Mortise's `mt-`
//! components, and the layout hooks listed in docs/themes.md.

const std = @import("std");

pub const css_path = "theme.css";

pub const Theme = struct {
    name: []const u8,
    css: []const u8,
    /// Images the build renders for the theme. The stylesheet refers to
    /// them relative to itself, as `url("theme/NAME.png")`.
    assets: []const Asset = &.{},
};

/// A rendered image a theme ships, written to `/theme/NAME.png` (and
/// `/theme/NAME.css` for kinds that come with CSS). `spec` uses the same
/// format as a site's `_render/*.yml` files; see docs/rendering.md.
pub const Asset = struct {
    name: []const u8,
    spec: []const u8,
};

/// Output directory of theme assets.
pub const assets_dir = "theme";

pub const all = [_]Theme{
    .{ .name = "visor", .css = @embedFile("themes/visor.css"), .assets = &.{
        .{ .name = "panel", .spec = @embedFile("themes/visor/panel.yml") },
    } },
    .{ .name = "lcars", .css = @embedFile("themes/lcars.css"), .assets = &.{
        .{ .name = "planet", .spec = @embedFile("themes/lcars/planet.yml") },
        .{ .name = "hologram", .spec = @embedFile("themes/lcars/hologram.yml") },
    } },
};

pub fn find(name: []const u8) ?Theme {
    for (all) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// "visor, lcars", for error messages.
pub const names = blk: {
    var s: []const u8 = "";
    for (all, 0..) |t, i| s = s ++ (if (i == 0) "" else ", ") ++ t.name;
    break :blk s;
};

test "find" {
    try std.testing.expect(find("visor") != null);
    try std.testing.expect(find("lcars") != null);
    try std.testing.expect(find("nope") == null);
    try std.testing.expectEqualStrings("visor, lcars", names);
}
