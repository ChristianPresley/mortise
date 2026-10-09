//! Regenerates the expected outputs of the fixture tests from the current
//! implementation: every test/fixtures/markdown/*.html and the whole
//! test/expected/site-basic/ tree.
//!
//! Usage: zig build update-fixtures
//!
//! Review the resulting diff before committing it: the fixtures are the
//! specification, so an unexpected change there is a bug, not a new
//! expectation.

const std = @import("std");
const Io = std.Io;
const mortise = @import("mortise");
const paths = @import("test_paths");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    // Markdown fixtures.
    var md_dir = try Io.Dir.cwd().openDir(io, paths.markdown_fixtures, .{ .iterate = true });
    defer md_dir.close(io);
    var it = md_dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
        const src = try md_dir.readFileAlloc(io, entry.name, arena, .limited(1 << 20));
        const html = try mortise.markdown.toHtml(arena, src);
        const out_name = try std.mem.concat(arena, u8, &.{ entry.name[0 .. entry.name.len - ".md".len], ".html" });
        try md_dir.writeFile(io, .{ .sub_path = out_name, .data = html });
        count += 1;
    }

    // The site-basic end-to-end fixture.
    var src = try mortise.SiteDir.open(io, paths.site_basic);
    defer src.close();
    var diag: mortise.pipeline.Diagnostic = .{};
    const site = mortise.pipeline.build(arena, src, &diag) catch |err| {
        std.debug.print("site-basic failed to build: {f}\n", .{diag});
        return err;
    };
    try Io.Dir.cwd().deleteTree(io, paths.site_basic_expected);
    var out = try mortise.SiteDir.openOrCreate(io, paths.site_basic_expected);
    defer out.close();
    try mortise.pipeline.writeSite(site, src, out, &diag);

    std.debug.print("Updated {d} Markdown fixtures and {d} site-basic outputs.\n", .{ count, site.outputs.len });
}
