//! `zig build theme-gallery -- [OUT_DIR]`: builds the showcase once with
//! every built-in theme into OUT_DIR/NAME/ (default zig-out/theme-gallery)
//! and writes OUT_DIR/index.html, which previews them side by side. Each
//! copy is built under the base URL /NAME, so serve OUT_DIR as a site root:
//!
//!   zig build theme-gallery && zig-out/bin/mortise serve zig-out/theme-gallery

const std = @import("std");
const mortise = @import("mortise");
const pipeline = mortise.pipeline;
const SiteDir = mortise.SiteDir;

/// One line per theme for the index, in `themes.all` order.
const blurbs = [_]struct { []const u8, []const u8 }{
    .{ "visor", "A helmet heads-up display: HUD bar, shield meter, mission objectives." },
    .{ "lcars", "A starship console: orange elbows, color bars, rounded console pills." },
    .{ "phosphor", "A monochrome CRT terminal: one glowing monospace face, scanlines, prompts." },
    .{ "cyberdeck", "A hacker's deck: magenta and cyan neon, notched panels, glitches on hover." },
    .{ "freighter", "An old hauler's mainframe: graph paper, inverse labels, hazard stripes." },
    .{ "grid", "A world drawn in light: a floor grid to the horizon, traced rounded panels." },
    .{ "codex", "A starship encyclopedia: holographic blue, hex lattice, cut-corner entries." },
    .{ "cockpit", "A trader's flight deck: orange vector light framed by canopy struts." },
    .{ "scanvisor", "A bounty hunter's scan visor: orange frame, energy tanks, scan-data panels." },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.MissingShowcasePath;
    const showcase = args[1];
    const out_path = if (args.len > 2) args[2] else "zig-out/theme-gallery";

    var src = try SiteDir.open(io, showcase);
    defer src.close();
    var out = try SiteDir.openOrCreate(io, out_path);
    defer out.close();

    var index: std.Io.Writer.Allocating = .init(gpa);
    defer index.deinit();
    const w = &index.writer;
    try w.writeAll(head);

    for (mortise.themes.all) |t| {
        if (t.hidden) continue;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const base = try std.fmt.allocPrint(arena, "/{s}", .{t.name});
        var diag: pipeline.Diagnostic = .{};
        const site = pipeline.buildWith(arena, src, .{ .config = &.{
            .{ .key = "theme", .value = .{ .string = t.name } },
            .{ .key = "baseurl", .value = .{ .string = base } },
        } }, &diag) catch |err| {
            std.debug.print("{s}: {f}\n", .{ t.name, diag });
            return err;
        };
        for (site.warnings) |warning| std.debug.print("{s}: warning: {f}\n", .{ t.name, warning });
        out.deleteTree(t.name) catch {};
        var dir = try out.openSub(t.name);
        defer dir.close();
        try pipeline.writeSite(site, src, dir, &diag);

        const blurb = for (blurbs) |b| {
            if (std.mem.eql(u8, b[0], t.name)) break b[1];
        } else "";
        try w.print(
            \\<figure>
            \\<div class="frame"><iframe src="{0s}/" title="The showcase in the {0s} theme" loading="lazy" tabindex="-1"></iframe></div>
            \\<figcaption><a href="{0s}/"><code>theme: {0s}</code></a><span>{1s}</span>
            \\<span class="pages"><a href="{0s}/components/">components</a> <a href="{0s}/code/">code</a> <a href="{0s}/wiki/">wiki</a> <a href="{0s}/api/pets/">API</a></span></figcaption>
            \\</figure>
            \\
        , .{ t.name, blurb });
        std.debug.print("built {s}\n", .{t.name});
    }
    try w.writeAll(tail);
    try out.writeFile("index.html", index.written());
    std.debug.print("wrote {s}/index.html; serve it with: mortise serve {s}\n", .{ out_path, out_path });
}

const head =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Mortise themes</title>
    \\<style>
    \\  body { margin: 0; padding: 2rem; background: #101114; color: #e8e8ed; font: 16px/1.5 system-ui, sans-serif; }
    \\  h1 { margin: 0 0 .3rem; font-weight: 600; }
    \\  .intro { margin: 0 0 2rem; color: #a0a0aa; }
    \\  main { display: grid; grid-template-columns: repeat(auto-fill, 440px); gap: 2rem; }
    \\  figure { margin: 0; }
    \\  .frame { position: relative; width: 440px; height: 280px; overflow: hidden; border-radius: 8px; border: 1px solid #2a2b31; }
    \\  /* Each preview is a 1100x700 window shrunk to fit its card. */
    \\  iframe { position: absolute; top: 0; left: 0; width: 1100px; height: 700px; border: 0; transform-origin: 0 0; transform: scale(.4); pointer-events: none; }
    \\  figcaption { display: flex; flex-direction: column; gap: .15rem; padding: .7rem .1rem 0; color: #a0a0aa; font-size: .92rem; }
    \\  figcaption > a { color: #fff; font-size: 1.05rem; text-decoration: none; }
    \\  .pages a { color: #8ab4f8; margin-right: .6rem; }
    \\</style>
    \\</head>
    \\<body>
    \\<h1>Mortise themes</h1>
    \\<p class="intro">The showcase site built with each built-in theme. Pick one with <code>theme: NAME</code> in <code>_config.yml</code>.</p>
    \\<main>
    \\
;

const tail =
    \\</main>
    \\</body>
    \\</html>
    \\
;
