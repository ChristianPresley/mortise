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
pub const frontmatter = @import("frontmatter.zig");
pub const template = @import("template.zig");
pub const pipeline = @import("pipeline.zig");
pub const feeds = @import("feeds.zig");
pub const data = @import("data.zig");
pub const watch = @import("watch.zig");
pub const server = @import("server.zig");

pub const version = "0.1.0";

test {
    @import("std").testing.refAllDecls(@This());
}
