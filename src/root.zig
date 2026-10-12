//! Mortise: a static site generator.
//!
//! I/O policy: the process creates exactly one `std.Io` (the one handed to
//! `main` in `std.process.Init`) and passes it down explicitly. No module
//! creates its own `Io` or reaches for a global one.
//!
//! Allocation policy: long-lived state uses the process `gpa`; everything a
//! build produces uses that build's arena (`BuildArena`).

pub const path = @import("path.zig");
pub const SiteDir = @import("SiteDir.zig");
pub const BuildArena = @import("BuildArena.zig");
pub const markdown = @import("markdown.zig");
pub const highlight = @import("highlight.zig");
pub const snippet = @import("snippet.zig");
pub const chart = @import("chart.zig");
pub const tex = @import("tex.zig");
pub const diagram = @import("diagram.zig");
pub const frontmatter = @import("frontmatter.zig");
pub const defaults = @import("defaults.zig");
pub const template = @import("template.zig");
pub const pipeline = @import("pipeline.zig");
pub const feeds = @import("feeds.zig");
pub const gzip = @import("gzip.zig");
pub const search = @import("search.zig");
pub const minify = @import("minify.zig");
pub const llms = @import("llms.zig");
pub const i18n = @import("i18n.zig");
pub const data = @import("data.zig");
pub const schema = @import("schema.zig");
pub const openapi = @import("openapi.zig");
pub const yaml = @import("yaml.zig");
pub const themes = @import("themes.zig");
pub const tokens = @import("tokens.zig");
pub const icons = @import("icons.zig");
pub const assets = @import("assets.zig");
pub const check = @import("check.zig");
pub const redirects = @import("redirects.zig");
pub const git = @import("git.zig");
pub const seo = @import("seo.zig");
pub const a11y = @import("a11y.zig");
pub const images = @import("images.zig");
pub const links = @import("links.zig");
pub const fonts = @import("fonts.zig");
pub const scaffold = @import("scaffold.zig");
pub const watch = @import("watch.zig");
pub const server = @import("server.zig");

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
