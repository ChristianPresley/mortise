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
};

pub const all = [_]Theme{
    .{ .name = "visor", .css = @embedFile("themes/visor.css") },
    .{ .name = "lcars", .css = @embedFile("themes/lcars.css") },
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
