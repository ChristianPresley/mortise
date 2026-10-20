//! Rendered assets: images that the build draws with the `render` module
//! instead of reading from disk.
//!
//! A site asks for one with a small spec file under `_render/`:
//!
//!   _render/img/stars.yml   ->  /img/stars.png
//!
//!   kind: starfield
//!   width: 1024
//!   height: 512
//!   seed: 7
//!
//! Kinds that need CSS to be used (panels for `border-image`, animated
//! sprite sheets) also get a stylesheet next to the image, `/img/NAME.css`,
//! with a rule for the class `NAME`. Themes can ship specs too; see
//! `themes.Asset`. docs/rendering.md lists every kind and field.
//!
//! Rendering takes from milliseconds to seconds, so the dev server keeps a
//! `Cache` keyed by each spec's contents: editing a page never re-renders,
//! and editing a spec re-renders only that spec. `mortise build` keeps the
//! same cache on disk, in `.mortise-cache/render/` inside the site.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const r = @import("render");
const images = @import("images.zig");
const frontmatter = @import("frontmatter.zig");
const sitepath = @import("path.zig");
const Color = r.Color;

pub const dir_prefix = "_render/";

/// Whether `path` is a render spec.
pub fn isSpec(path: []const u8) bool {
    return std.mem.startsWith(u8, path, dir_prefix) and std.mem.eql(u8, sitepath.extension(path), ".yml");
}

/// The output name of a spec without its extension: `_render/img/stars.yml`
/// becomes `img/stars`.
pub fn outputStem(spec_path: []const u8) []const u8 {
    return spec_path[dir_prefix.len .. spec_path.len - ".yml".len];
}

pub const Rendered = struct {
    png: []const u8,
    /// A stylesheet for kinds used through CSS, or null.
    css: ?[]const u8,
};

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

pub const Error = error{InvalidSpec} || Allocator.Error;

pub const Kind = enum { starfield, panel, reticle, radar, planet, hologram, card, icon };

/// Upper bounds that keep a typo from rendering for minutes.
const max_side = 4096;
const max_frames = 256;

/// Renders the spec `source` (the contents of a spec file). `name` is the
/// output path without extension, such as `img/stars`; its last component
/// names the CSS class and the image the stylesheet points at. The result
/// is allocated with `gpa`. Animation frames render concurrently on `io`.
pub fn render(gpa: Allocator, arena: Allocator, io: std.Io, name: []const u8, source: []const u8, diag: *Diagnostic) Error!Rendered {
    var fd: frontmatter.Diagnostic = .{};
    const fields = frontmatter.parseFile(arena, source, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => {
            diag.* = .{ .line = fd.line, .message = fd.message };
            return error.InvalidSpec;
        },
    };
    var s: Spec = .{ .arena = arena, .io = io, .source = source, .fields = fields, .diag = diag, .used = try arena.alloc(bool, fields.entries.len) };
    @memset(s.used, false);
    const kind = try s.enumField(Kind, "kind", null);
    const class = sitepath.basename(name);
    const rendered: Rendered = switch (kind) {
        .starfield => try starfield(gpa, &s),
        .panel => try panel(gpa, &s, class),
        .reticle => try reticle(gpa, &s),
        .radar => try radar(gpa, &s, class),
        .planet => try planet(gpa, &s, class),
        .hologram => try hologram(gpa, &s, class),
        .card => try card(gpa, &s),
        .icon => try icon(gpa, &s),
    };
    errdefer {
        gpa.free(rendered.png);
        if (rendered.css) |c| gpa.free(c);
    }
    try s.checkUnused();
    return rendered;
}

fn starfield(gpa: Allocator, s: *Spec) Error!Rendered {
    const nebula = try s.boolean("nebula", true);
    const defaults: r.starfield.Nebula = .{};
    var c = try r.starfield.render(gpa, .{
        .width = try s.side("width", 1024),
        .height = try s.side("height", 512),
        .seed = try s.seed(),
        .density = try s.float("density", 8, 0, 200),
        .brightness = try s.float("brightness", 1, 0, 10),
        .spike_fraction = try s.float("spikes", 0.004, 0, 1),
        .background = try s.color("background", Color.hex(0x03050c)),
        .tileable = try s.boolean("tileable", true),
        .nebula = if (!nebula) null else .{
            .colors = .{
                try s.color("nebula_color", defaults.colors[0]),
                try s.color("nebula_color2", defaults.colors[1]),
            },
            .scale = @intCast(try s.int("nebula_scale", defaults.scale, 1, 64)),
            .intensity = try s.float("nebula_intensity", defaults.intensity, 0, 4),
            .coverage = try s.float("nebula_coverage", defaults.coverage, 0, 1),
        },
    });
    defer c.deinit(gpa);
    return .{ .png = try r.encodePng(gpa, c, .soft), .css = null };
}

fn panel(gpa: Allocator, s: *Spec, class: []const u8) Error!Rendered {
    const d: r.hud.PanelOptions = .{};
    var p = try r.hud.panel(gpa, .{
        .width = try s.side("width", d.width),
        .height = try s.side("height", d.height),
        .color = try s.color("color", d.color),
        .chamfer = try s.float("chamfer", d.chamfer, 0, 512),
        .stroke = try s.float("stroke", d.stroke, 0.5, 64),
        .fill = try s.float("fill", d.fill, 0, 1),
        .glow = try s.float("glow", d.glow, 0, 64),
        .margin = @intCast(try s.int("margin", d.margin, 0, 512)),
        .brackets = try s.boolean("brackets", d.brackets),
    });
    defer p.deinit(gpa);
    if (p.slice * 2 >= @min(p.canvas.width, p.canvas.height)) {
        return s.fail(0, "the panel is too small for its corners; make it at least {d} pixels on each side", .{p.slice * 2 + 2});
    }
    const png = try r.encodePng(gpa, p.canvas, .soft);
    errdefer gpa.free(png);
    const css = try std.fmt.allocPrint(gpa,
        \\.{s} {{
        \\  border: {d}px solid transparent;
        \\  border-image: url("{s}.png") {d} fill stretch;
        \\}}
        \\
    , .{ class, p.slice, class, p.slice });
    return .{ .png = png, .css = css };
}

fn reticle(gpa: Allocator, s: *Spec) Error!Rendered {
    const d: r.hud.ReticleOptions = .{};
    var c = try r.hud.reticle(gpa, .{
        .size = try s.side("size", d.size),
        .color = try s.color("color", d.color),
        .accent = try s.color("accent", d.accent),
        .glow = try s.float("glow", d.glow, 0, 64),
        .spin = try s.angle("spin", 0),
    });
    defer c.deinit(gpa);
    return .{ .png = try r.encodePng(gpa, c, .soft), .css = null };
}

/// Frame layout fields shared by animated kinds.
const Frames = struct {
    count: u32,
    columns: u32,
    seconds: f32,

    fn read(s: *Spec, default_count: u32) Error!Frames {
        const count: u32 = @intCast(try s.int("frames", default_count, 1, max_frames));
        return .{
            .count = count,
            .columns = @intCast(try s.int("columns", @min(count, 8), 1, max_frames)),
            .seconds = try s.float("seconds", 3, 0.05, 600),
        };
    }

    /// Fraction of the loop at frame `i`, 0 to just under 1.
    fn t(f: Frames, i: usize) f32 {
        return @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(f.count));
    }
};

/// Frames render on several threads at once, so they allocate from a
/// thread-safe allocator rather than the caller's, which may be an arena.
const frame_allocator = std.heap.smp_allocator;

/// Packs frames drawn by `frameFn(ctx, i)` into a sheet, with CSS when
/// there is more than one frame. Frames render concurrently; `frameFn`
/// must allocate with `frame_allocator`.
fn sheet(gpa: Allocator, io: std.Io, class: []const u8, size: u32, frames: Frames, ctx: anytype, comptime frameFn: fn (@TypeOf(ctx), usize) Error!r.Canvas) Error!Rendered {
    const fa = frame_allocator;
    if (frames.count == 1) {
        var c = try frameFn(ctx, 0);
        defer c.deinit(fa);
        return .{ .png = try r.encodePng(gpa, c, .soft), .css = null };
    }
    const results = try fa.alloc(Error!r.Canvas, frames.count);
    @memset(results, error.OutOfMemory);
    defer {
        for (results) |res| if (res) |c| fa.free(c.pixels) else |_| {};
        fa.free(results);
    }
    const Task = struct {
        fn run(c: @TypeOf(ctx), i: usize, out: *(Error!r.Canvas)) void {
            out.* = frameFn(c, i);
        }
    };
    var group: std.Io.Group = .init;
    for (results, 0..) |*res, i| group.async(io, Task.run, .{ ctx, i, res });
    group.await(io) catch {
        // Only a canceled build gets here; stop the rest and give up.
        group.cancel(io);
        return error.OutOfMemory;
    };
    var sh = try r.SpriteSheet.init(gpa, size, size, frames.count, frames.columns);
    defer sh.deinit(gpa);
    for (results, 0..) |res, i| sh.set(@intCast(i), try res);
    const png = try r.encodePng(gpa, sh.canvas, .soft);
    errdefer gpa.free(png);
    var css: Writer.Allocating = .init(gpa);
    defer css.deinit();
    const url = try std.fmt.allocPrint(gpa, "{s}.png", .{class});
    defer gpa.free(url);
    sh.writeCss(&css.writer, .{ .class = class, .url = url, .seconds = frames.seconds }) catch return error.OutOfMemory;
    return .{ .png = png, .css = try css.toOwnedSlice() };
}

fn radar(gpa: Allocator, s: *Spec, class: []const u8) Error!Rendered {
    const d: r.hud.RadarOptions = .{};
    const Ctx = struct {
        gpa: Allocator,
        opts: r.hud.RadarOptions,
        frames: Frames,
        start: f32,
        fn frame(c: @This(), i: usize) Error!r.Canvas {
            var o = c.opts;
            o.angle = c.start + c.frames.t(i) * std.math.tau;
            return r.hud.radar(c.gpa, o);
        }
    };
    const size = try s.side("size", d.size);
    const blip_count: u32 = @intCast(try s.int("blips", 4, 0, 64));
    const seed = try s.seed();
    const blips = try s.arena.alloc([2]f32, blip_count);
    for (blips, 0..) |*b, i| {
        const k: i32 = @intCast(i);
        b.* = .{
            0.2 + 0.75 * r.noise.hashUnit(seed, k, 1, 0),
            std.math.tau * r.noise.hashUnit(seed, k, 2, 0),
        };
    }
    const ctx: Ctx = .{
        .gpa = frame_allocator,
        .opts = .{ .size = size, .color = try s.color("color", d.color), .glow = try s.float("glow", d.glow, 0, 64), .blips = blips },
        .start = try s.angle("angle", 0),
        .frames = try Frames.read(s, 1),
    };
    return sheet(gpa, s.io, class, size, ctx.frames, ctx, Ctx.frame);
}

fn planet(gpa: Allocator, s: *Spec, class: []const u8) Error!Rendered {
    const d: r.planet.Options = .{};
    const Ctx = struct {
        gpa: Allocator,
        opts: r.planet.Options,
        frames: Frames,
        fn frame(c: @This(), i: usize) Error!r.Canvas {
            var o = c.opts;
            o.rotation += c.frames.t(i) * std.math.tau;
            return r.planet.render(c.gpa, o);
        }
    };
    const kind = try s.enumField(r.planet.Kind, "type", .terran);
    // `atmosphere: false` turns it off, `true` keeps the default color.
    const atmosphere: ?Color = if (try s.boolean2("atmosphere")) |on|
        (if (on) defaultAtmosphere(kind) else null)
    else
        try s.color("atmosphere", defaultAtmosphere(kind));
    const size = try s.side("size", d.size);
    const ctx: Ctx = .{
        .gpa = frame_allocator,
        .opts = .{
            .size = size,
            .kind = kind,
            .seed = try s.seed(),
            .rotation = try s.angle("rotation", 0),
            .tilt = try s.angle("tilt", 20),
            .atmosphere = atmosphere,
            .samples = @intCast(try s.int("samples", d.samples, 1, 4)),
        },
        .frames = try Frames.read(s, 1),
    };
    return sheet(gpa, s.io, class, size, ctx.frames, ctx, Ctx.frame);
}

fn defaultAtmosphere(kind: r.planet.Kind) Color {
    return switch (kind) {
        .terran => Color.hex(0x5ab4ff),
        .lava => Color.hex(0xff7a30),
        .ice => Color.hex(0xbfe8ff),
        .gas => Color.hex(0xffd9a0),
    };
}

fn card(gpa: Allocator, s: *Spec) Error!Rendered {
    var c = try r.card.render(gpa, .{
        .width = try s.side("width", 1200),
        .height = try s.side("height", 630),
        .title = try s.text("title", null),
        .subtitle = try s.text("subtitle", ""),
        .label = try s.text("label", ""),
        .style = try s.enumField(r.card.Style, "style", .plain),
        .accent = try s.optionalColor("accent"),
        .background = try s.optionalColor("background"),
        .foreground = try s.optionalColor("foreground"),
    });
    defer c.deinit(gpa);
    // Cards are large and plain; fast compression costs little in size.
    return .{ .png = try r.encodePngWith(gpa, c, .clamp, .{ .level = .level_1 }), .css = null };
}

fn icon(gpa: Allocator, s: *Spec) Error!Rendered {
    var c = try r.icon.render(gpa, .{
        .size = @intCast(try s.int("size", 512, 16, 1024)),
        .letters = try s.text("letters", null),
        .style = try s.enumField(r.card.Style, "style", .plain),
        .accent = try s.optionalColor("accent"),
        .background = try s.optionalColor("background"),
        .foreground = try s.optionalColor("foreground"),
    });
    defer c.deinit(gpa);
    return .{ .png = try r.encodePng(gpa, c, .clamp), .css = null };
}

pub const Shape = enum { icosphere, sphere, cube, torus, gem };

fn hologram(gpa: Allocator, s: *Spec, class: []const u8) Error!Rendered {
    const Ctx = struct {
        gpa: Allocator,
        mesh: *const r.Mesh,
        ring: ?*const r.Mesh,
        size: u32,
        color: Color,
        ring_color: Color,
        wire: f32,
        hidden: f32,
        turn: f32,
        frames: Frames,
        fn frame(c: @This(), i: usize) Error!r.Canvas {
            const m3 = r.math3d;
            const t = c.frames.t(i);
            var target = try r.render3d.Target.init(c.gpa, c.size, c.size, 3);
            defer target.deinit(c.gpa);
            const cam: r.render3d.Camera = .{ .eye = .{ 0, 1.2, 4.2 }, .projection = .{ .perspective = 0.75 } };
            const spin = m3.Mat4.rotation(.{ 1, 0, 0 }, 0.4).mul(m3.Mat4.rotation(.{ 0, 1, 0 }, t * c.turn));
            try r.render3d.drawMesh(c.gpa, &target, c.mesh.*, spin, cam, .{}, .{
                .color = .black,
                .emissive = c.color.scale(0.02),
                .rim = .{ .color = c.color.scale(0.6), .power = 2.5 },
                .blend = .add,
                .opacity = 0.5,
                .wire = .{ .color = c.color, .width = c.wire, .hidden = c.hidden },
            });
            if (c.ring) |ring| {
                const tilt = m3.Mat4.rotation(.{ 0, 0, 1 }, 0.3).mul(m3.Mat4.rotation(.{ 0, 1, 0 }, -t * std.math.tau));
                try r.render3d.drawMesh(c.gpa, &target, ring.*, tilt, cam, .{}, .{ .color = .black, .emissive = c.ring_color });
            }
            var out = try target.resolve(c.gpa);
            errdefer out.deinit(c.gpa);
            try r.filter.glow(c.gpa, out, @as(f32, @floatFromInt(c.size)) / 40, 0.6, .transparent);
            r.filter.scanlines(out, 3, 0.35);
            return out;
        }
    };
    const shape = try s.enumField(Shape, "shape", .icosphere);
    var mesh = switch (shape) {
        .icosphere => try r.Mesh.icosphere(gpa, 1, 1),
        .gem => try r.Mesh.icosphere(gpa, 1, 0),
        .sphere => try r.Mesh.uvSphere(gpa, 1, 24, 12),
        .cube => try r.Mesh.cube(gpa, 0.7),
        .torus => try r.Mesh.torus(gpa, 0.85, 0.3, 24, 10),
    };
    defer mesh.deinit(gpa);
    const with_ring = try s.boolean("ring", true);
    var ring: ?r.Mesh = if (with_ring) try r.Mesh.torus(gpa, 1.45, 0.02, 96, 6) else null;
    defer if (ring) |*m| m.deinit(gpa);
    const size = try s.side("size", 160);
    const ctx: Ctx = .{
        .gpa = frame_allocator,
        .mesh = &mesh,
        .ring = if (ring) |*m| m else null,
        .size = size,
        .color = try s.color("color", Color.hex(0x45e0ff)),
        .ring_color = try s.color("ring_color", Color.hex(0xff5a3c)),
        .wire = try s.float("wire", 1.2, 0.25, 16),
        .hidden = try s.float("hidden", 0.2, 0, 1),
        // Shapes repeat after a half turn about y, except the cube and
        // torus, which repeat after a quarter; either way the loop is
        // seamless.
        .turn = switch (shape) {
            .cube, .torus => std.math.pi / 2.0,
            else => std.math.pi,
        },
        .frames = try Frames.read(s, 24),
    };
    return sheet(gpa, s.io, class, size, ctx.frames, ctx, Ctx.frame);
}

/// Typed access to a spec's fields, remembering which were read so that
/// unknown (usually misspelled) fields can be reported.
const Spec = struct {
    arena: Allocator,
    io: std.Io,
    source: []const u8,
    fields: frontmatter.Map,
    diag: *Diagnostic,
    used: []bool,

    fn fail(s: *Spec, line: usize, comptime fmt: []const u8, args: anytype) Error {
        s.diag.* = .{
            .line = line,
            .message = std.fmt.allocPrint(s.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.InvalidSpec;
    }

    fn get(s: *Spec, key: []const u8) ?frontmatter.Value {
        for (s.fields.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                s.used[i] = true;
                return e.value;
            }
        }
        return null;
    }

    fn lineOf(s: *Spec, key: []const u8) usize {
        var it = std.mem.splitScalar(u8, s.source, '\n');
        var n: usize = 0;
        while (it.next()) |l| {
            n += 1;
            if (std.mem.startsWith(u8, l, key) and l.len > key.len and l[key.len] == ':') return n;
        }
        return 0;
    }

    fn int(s: *Spec, key: []const u8, default: i64, min: i64, max: i64) Error!i64 {
        const v = s.get(key) orelse return default;
        if (v != .int or v.int < min or v.int > max) {
            return s.fail(s.lineOf(key), "'{s}' must be a whole number from {d} to {d}", .{ key, min, max });
        }
        return v.int;
    }

    fn side(s: *Spec, key: []const u8, default: u32) Error!u32 {
        return @intCast(try s.int(key, default, 8, max_side));
    }

    fn seed(s: *Spec) Error!u32 {
        return @intCast(try s.int("seed", 1, 0, std.math.maxInt(u32)));
    }

    fn float(s: *Spec, key: []const u8, default: f32, min: f32, max: f32) Error!f32 {
        const v = s.get(key) orelse return default;
        const f: f32 = switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => return s.fail(s.lineOf(key), "'{s}' must be a number from {d} to {d}", .{ key, min, max }),
        };
        if (!(f >= min and f <= max)) return s.fail(s.lineOf(key), "'{s}' must be a number from {d} to {d}", .{ key, min, max });
        return f;
    }

    /// An angle given in degrees, returned in radians.
    fn angle(s: *Spec, key: []const u8, default_deg: f32) Error!f32 {
        return try s.float(key, default_deg, -3600, 3600) * std.math.pi / 180;
    }

    fn boolean(s: *Spec, key: []const u8, default: bool) Error!bool {
        const v = s.get(key) orelse return default;
        if (v != .boolean) return s.fail(s.lineOf(key), "'{s}' must be true or false", .{key});
        return v.boolean;
    }

    /// The field as a boolean if it is one, else null (and not marked read).
    fn boolean2(s: *Spec, key: []const u8) Error!?bool {
        const v = s.fields.get(key) orelse return null;
        if (v != .boolean) return null;
        _ = s.get(key);
        return v.boolean;
    }

    fn color(s: *Spec, key: []const u8, default: Color) Error!Color {
        const v = s.get(key) orelse return default;
        if (v == .string) if (parseColor(v.string)) |c| return c;
        return s.fail(s.lineOf(key), "'{s}' must be a color such as \"#3fd8ff\" (quoted, since # starts a comment)", .{key});
    }

    fn optionalColor(s: *Spec, key: []const u8) Error!?Color {
        if (s.fields.get(key) == null) return null;
        return try s.color(key, undefined);
    }

    /// Text; numbers are written out as text.
    fn text(s: *Spec, key: []const u8, default: ?[]const u8) Error![]const u8 {
        const v = s.get(key) orelse return default orelse s.fail(0, "'{s}' is required", .{key});
        return switch (v) {
            .string => |t| t,
            .int => |i| std.fmt.allocPrint(s.arena, "{d}", .{i}),
            .float => |f| std.fmt.allocPrint(s.arena, "{d}", .{f}),
            else => s.fail(s.lineOf(key), "'{s}' must be text", .{key}),
        };
    }

    fn enumField(s: *Spec, comptime E: type, key: []const u8, default: ?E) Error!E {
        const v = s.get(key) orelse {
            if (default) |d| return d;
            return s.fail(0, "'{s}' is required; it must be one of: {s}", .{ key, comptime names(E) });
        };
        if (v == .string) if (std.meta.stringToEnum(E, v.string)) |e| return e;
        return s.fail(s.lineOf(key), "'{s}' must be one of: {s}", .{ key, comptime names(E) });
    }

    fn checkUnused(s: *Spec) Error!void {
        for (s.fields.entries, s.used) |e, u| {
            if (!u) return s.fail(s.lineOf(e.key), "unknown field '{s}'", .{e.key});
        }
    }
};

fn names(comptime E: type) []const u8 {
    var out: []const u8 = "";
    for (std.meta.fieldNames(E), 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ n;
    return out;
}

/// Parses `#rgb`, `#rrggbb`, or the same without the `#`.
pub fn parseColor(text: []const u8) ?Color {
    const hex = if (std.mem.startsWith(u8, text, "#")) text[1..] else text;
    const v = std.fmt.parseInt(u24, hex, 16) catch return null;
    return switch (hex.len) {
        6 => Color.hex(v),
        3 => Color.hex(((v >> 8) & 0xf) * 0x110000 | ((v >> 4) & 0xf) * 0x1100 | (v & 0xf) * 0x11),
        else => null,
    };
}

/// Rendered assets kept across builds, keyed by spec contents, so a dev
/// server renders each version of a spec once, plus resized site images.
/// Owns its memory.
///
/// With `openDisk`, rendered assets are also kept in files, so that one
/// `mortise build` finds what the last one drew.
pub const Cache = struct {
    gpa: Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Rendered) = .empty,
    images: images.Cache,
    disk: ?Disk = null,

    const Disk = struct {
        /// The site directory, borrowed.
        site: std.Io.Dir,
        /// `disk_dir_path`, opened once it exists: a site that draws
        /// nothing gets no cache folder.
        dir: ?std.Io.Dir,
        io: std.Io,
        /// Mixed into every file's key, so that a different renderer, which
        /// may draw the same spec differently, never reads this one's files.
        salt: u64,
        /// Keys read or written this build; `pruneDisk` keeps only these.
        used: std.AutoHashMapUnmanaged(u64, void) = .empty,
    };

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa, .images = .init(gpa) };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.entries.valueIterator();
        while (it.next()) |v| {
            c.gpa.free(v.png);
            if (v.css) |css| c.gpa.free(css);
        }
        c.entries.deinit(c.gpa);
        c.images.deinit();
        if (c.disk) |*d| {
            d.used.deinit(c.gpa);
            if (d.dir) |dir| dir.close(d.io);
        }
        c.* = undefined;
    }

    /// Keeps rendered assets in `disk_dir_path` under `site` too, which is
    /// created when the first one is stored. `site` must stay open while
    /// the cache is used. `salt` should change whenever the renderer might
    /// draw differently, such as a hash of the running program.
    pub fn openDisk(c: *Cache, io: std.Io, site: std.Io.Dir, salt: u64) !void {
        const dir = site.openDir(io, disk_dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        c.disk = .{ .site = site, .dir = dir, .io = io, .salt = salt };
    }

    /// Deletes the files on disk that this build neither read nor wrote,
    /// so the cache holds only what the site now draws. Call it after a
    /// successful build only: a failed one may not have reached every spec.
    pub fn pruneDisk(c: *Cache) !void {
        const d = &(c.disk orelse return);
        const dir = d.dir orelse return;
        var it = dir.iterate();
        while (try it.next(d.io)) |entry| {
            const key = std.fmt.parseInt(u64, entry.name, 16) catch null;
            if (entry.kind == .file and key != null and d.used.contains(key.?)) continue;
            dir.deleteTree(d.io, entry.name) catch {};
        }
    }

    /// The rendered asset for `source` under `name`, from the cache or
    /// freshly rendered. The result lives as long as the cache.
    pub fn get(c: *Cache, arena: Allocator, io: std.Io, name: []const u8, source: []const u8, diag: *Diagnostic) Error!Rendered {
        const key = cacheKey(name, source);
        if (try c.lookup(key)) |hit| return hit;
        const fresh = try render(c.gpa, arena, io, name, source, diag);
        try c.keep(key, fresh);
        return fresh;
    }

    /// The entry for `key` from memory, else from disk (then remembered).
    fn lookup(c: *Cache, key: u64) Allocator.Error!?Rendered {
        if (c.entries.get(key)) |hit| return hit;
        const d = &(c.disk orelse return null);
        const file_key = d.salt ^ key;
        try d.used.put(c.gpa, file_key, {});
        var name_buf: [16]u8 = undefined;
        const dir = d.dir orelse return null;
        const bytes = dir.readFileAlloc(d.io, fileName(&name_buf, file_key), c.gpa, .limited(max_disk_entry)) catch return null;
        defer c.gpa.free(bytes);
        const parsed = decodeEntry(bytes) orelse return null;
        const png = try c.gpa.dupe(u8, parsed.png);
        errdefer c.gpa.free(png);
        const css = if (parsed.css) |s| try c.gpa.dupe(u8, s) else null;
        errdefer if (css) |s| c.gpa.free(s);
        const hit: Rendered = .{ .png = png, .css = css };
        try c.entries.put(c.gpa, key, hit);
        return hit;
    }

    /// Takes ownership of `fresh` (allocated with the cache's allocator)
    /// and writes it to disk when the cache has one. A failed write only
    /// means the next build renders it again.
    fn keep(c: *Cache, key: u64, fresh: Rendered) Allocator.Error!void {
        c.entries.put(c.gpa, key, fresh) catch |e| {
            c.gpa.free(fresh.png);
            if (fresh.css) |css| c.gpa.free(css);
            return e;
        };
        const d = &(c.disk orelse return);
        const file_key = d.salt ^ key;
        try d.used.put(c.gpa, file_key, {});
        const bytes = try encodeEntry(c.gpa, fresh);
        defer c.gpa.free(bytes);
        if (d.dir == null) d.dir = d.site.createDirPathOpen(d.io, disk_dir_path, .{ .open_options = .{ .iterate = true } }) catch return;
        var name_buf: [16]u8 = undefined;
        d.dir.?.writeFile(d.io, .{ .sub_path = fileName(&name_buf, file_key), .data = bytes }) catch {};
    }
};

/// Where `mortise build` keeps rendered assets, relative to the site. Like
/// every directory starting with `.`, the build never reads it as content.
pub const disk_dir_path = ".mortise-cache/render";

/// Larger files in the cache directory are not ours; read them as a miss.
const max_disk_entry = 256 << 20;

fn fileName(buf: *[16]u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{key}) catch unreachable;
}

/// A cache file: `MRC1`, the PNG's length and the stylesheet's length
/// (all ones for none) as little-endian u32s, then the PNG and stylesheet.
const entry_magic = "MRC1";
const no_css = std.math.maxInt(u32);

fn encodeEntry(gpa: Allocator, e: Rendered) Allocator.Error![]u8 {
    const css_len: u32 = if (e.css) |s| @intCast(s.len) else no_css;
    const css = e.css orelse "";
    const out = try gpa.alloc(u8, 12 + e.png.len + css.len);
    @memcpy(out[0..4], entry_magic);
    std.mem.writeInt(u32, out[4..8], @intCast(e.png.len), .little);
    std.mem.writeInt(u32, out[8..12], css_len, .little);
    @memcpy(out[12..][0..e.png.len], e.png);
    @memcpy(out[12 + e.png.len ..], css);
    return out;
}

/// The entry in `bytes`, borrowing from it, or null when it is not one.
fn decodeEntry(bytes: []const u8) ?Rendered {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], entry_magic)) return null;
    const png_len = std.mem.readInt(u32, bytes[4..8], .little);
    const css_len = std.mem.readInt(u32, bytes[8..12], .little);
    const rest = bytes[12..];
    const want = @as(u64, png_len) + (if (css_len == no_css) 0 else css_len);
    if (rest.len != want) return null;
    return .{ .png = rest[0..png_len], .css = if (css_len == no_css) null else rest[png_len..] };
}

/// Renders with the cache when there is one, else into `arena`.
pub fn renderCached(cache: ?*Cache, arena: Allocator, io: std.Io, name: []const u8, source: []const u8, diag: *Diagnostic) Error!Rendered {
    if (cache) |c| return c.get(arena, io, name, source, diag);
    return render(arena, arena, io, name, source, diag);
}

pub const Job = struct {
    name: []const u8,
    source: []const u8,
    result: Rendered = undefined,
    diag: Diagnostic = .{},
};

/// Renders many specs at once, concurrently on `io`, like `renderCached`
/// for each. On `error.InvalidSpec`, the failed job's `diag` says why.
/// Results live in the cache when there is one, else in `arena`.
pub fn renderMany(cache: ?*Cache, arena: Allocator, io: std.Io, jobs: []Job) Error!void {
    const fa = frame_allocator;
    const Slot = struct { job: *Job, out: Error!Rendered = error.OutOfMemory, key: u64 };
    var todo: std.ArrayList(Slot) = .empty;
    for (jobs) |*j| {
        const key = cacheKey(j.name, j.source);
        if (cache) |c| if (try c.lookup(key)) |hit| {
            j.result = hit;
            continue;
        };
        try todo.append(arena, .{ .job = j, .key = key });
    }
    const Task = struct {
        fn run(t_io: std.Io, slot: *Slot) void {
            var task_arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer task_arena.deinit();
            slot.out = render(std.heap.smp_allocator, task_arena.allocator(), t_io, slot.job.name, slot.job.source, &slot.job.diag);
            // The diagnostic's message lives in the task's arena.
            if (slot.out) |_| {} else |_| slot.job.diag.message = std.heap.smp_allocator.dupe(u8, slot.job.diag.message) catch "out of memory";
        }
    };
    var group: std.Io.Group = .init;
    for (todo.items) |*slot| group.async(io, Task.run, .{ io, slot });
    group.await(io) catch {
        group.cancel(io);
        return error.OutOfMemory;
    };
    // Move each result where it must live, freeing the threads' copies.
    var failed: ?Error = null;
    for (todo.items) |*slot| {
        const fresh = slot.out catch |e| {
            const msg = slot.job.diag.message;
            slot.job.diag.message = try arena.dupe(u8, msg);
            if (msg.len > 0 and !std.mem.eql(u8, msg, "out of memory")) fa.free(msg);
            if (failed == null) failed = e;
            continue;
        };
        defer {
            fa.free(fresh.png);
            if (fresh.css) |css| fa.free(css);
        }
        const keep_gpa = if (cache) |c| c.gpa else arena;
        const kept: Rendered = .{ .png = try keep_gpa.dupe(u8, fresh.png), .css = if (fresh.css) |css| try keep_gpa.dupe(u8, css) else null };
        if (cache) |c| try c.keep(slot.key, kept);
        slot.job.result = kept;
    }
    if (failed) |e| return e;
}

fn cacheKey(name: []const u8, source: []const u8) u64 {
    var h: std.hash.Wyhash = .init(0);
    h.update(name);
    h.update(&.{0});
    h.update(source);
    return h.final();
}

const testing = std.testing;

fn expectSpecError(source: []const u8, line: usize, message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidSpec, render(arena.allocator(), arena.allocator(), testing.io, "x", source, &diag));
    try testing.expectEqual(line, diag.line);
    try testing.expectEqualStrings(message, diag.message);
}

test "spec paths" {
    try testing.expect(isSpec("_render/img/stars.yml"));
    try testing.expect(!isSpec("_render/img/stars.png"));
    try testing.expect(!isSpec("render/stars.yml"));
    try testing.expectEqualStrings("img/stars", outputStem("_render/img/stars.yml"));
}

test "colors" {
    try testing.expectEqual(Color.hex(0x3fd8ff), parseColor("#3fd8ff").?);
    try testing.expectEqual(Color.hex(0x3fd8ff), parseColor("3FD8FF").?);
    try testing.expectEqual(Color.hex(0xff8800), parseColor("#f80").?);
    try testing.expect(parseColor("#12345") == null);
    try testing.expect(parseColor("teal") == null);
}

test "bad specs name the line" {
    try expectSpecError("width: 64\n", 0, "'kind' is required; it must be one of: starfield, panel, reticle, radar, planet, hologram, card, icon");
    try expectSpecError("kind: nebula\n", 1, "'kind' must be one of: starfield, panel, reticle, radar, planet, hologram, card, icon");
    try expectSpecError("kind: starfield\nwidht: 64\n", 2, "unknown field 'widht'");
    try expectSpecError("kind: starfield\nwidth: 99999\n", 2, "'width' must be a whole number from 8 to 4096");
    try expectSpecError("kind: reticle\ncolor: teal\n", 2, "'color' must be a color such as \"#3fd8ff\" (quoted, since # starts a comment)");
    try expectSpecError("kind: panel\nwidth: 64\nheight: 64\n", 0, "the panel is too small for its corners; make it at least 152 pixels on each side");
    try expectSpecError("kind: [a\n", 1, "unterminated list; add ']'");
    try expectSpecError("kind: card\nsubtitle: x\n", 0, "'title' is required");
    try expectSpecError("kind: card\ntitle: x\nstyle: neon\n", 3, "'style' must be one of: plain, visor, lcars");
}

test "kinds render PNGs, with CSS where needed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const cases = [_]struct { src: []const u8, css: bool }{
        .{ .src = "kind: starfield\nwidth: 32\nheight: 16\nnebula_color: \"#ff0000\"\n", .css = false },
        .{ .src = "kind: panel\nwidth: 160\nheight: 160\ncolor: \"#ffb03a\"\n", .css = true },
        .{ .src = "kind: reticle\nsize: 32\n", .css = false },
        .{ .src = "kind: radar\nsize: 32\nframes: 3\nblips: 2\n", .css = true },
        .{ .src = "kind: planet\nsize: 16\ntype: gas\natmosphere: false\nsamples: 1\n", .css = false },
        .{ .src = "kind: planet\nsize: 16\natmosphere: \"#00ff00\"\nsamples: 1\nframes: 2\n", .css = true },
        .{ .src = "kind: hologram\nsize: 24\nshape: cube\nframes: 2\nring: false\n", .css = true },
    };
    for (cases) |case| {
        const out = render(a, a, testing.io, "img/thing", case.src, &diag) catch |e| {
            std.debug.print("{s}: {s}\n", .{ case.src, diag.message });
            return e;
        };
        var img = try r.png.decode(a, out.png);
        _ = &img;
        try testing.expectEqual(case.css, out.css != null);
        if (out.css) |css| try testing.expect(std.mem.indexOf(u8, css, ".thing {") != null);
    }
}

test "the cache renders each spec once" {
    var cache: Cache = .init(testing.allocator);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const a1 = try cache.get(arena.allocator(), testing.io, "a", "kind: reticle\nsize: 16\n", &diag);
    const a2 = try cache.get(arena.allocator(), testing.io, "a", "kind: reticle\nsize: 16\n", &diag);
    try testing.expectEqual(a1.png.ptr, a2.png.ptr);
    const b = try cache.get(arena.allocator(), testing.io, "a", "kind: reticle\nsize: 24\n", &diag);
    try testing.expect(b.png.ptr != a1.png.ptr);
    try testing.expectEqual(@as(u32, 2), cache.entries.count());
}

fn countFiles(dir: std.Io.Dir) !usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

test "the disk cache is reused by the next build, per program, and pruned" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const spec = "kind: radar\nsize: 24\nframes: 2\n";

    var first: Cache = .init(testing.allocator);
    try first.openDisk(testing.io, tmp.dir, 1);
    // Nothing drawn yet, so no folder.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, disk_dir_path, .{}));
    const drawn = try first.get(arena.allocator(), testing.io, "r", spec, &diag);
    try testing.expect(drawn.css != null);
    const dir = first.disk.?.dir.?;
    try testing.expectEqual(@as(usize, 1), try countFiles(dir));

    // The next build reads it back instead of drawing, and pruning keeps it.
    var second: Cache = .init(testing.allocator);
    try second.openDisk(testing.io, tmp.dir, 1);
    var jobs = [_]Job{.{ .name = "r", .source = spec }};
    try renderMany(&second, arena.allocator(), testing.io, &jobs);
    try testing.expectEqualSlices(u8, drawn.png, jobs[0].result.png);
    try testing.expectEqualStrings(drawn.css.?, jobs[0].result.css.?);
    try second.pruneDisk();
    try testing.expectEqual(@as(usize, 1), try countFiles(dir));
    second.deinit();

    // A different program draws afresh; pruning drops the old file and
    // anything else in the directory.
    try dir.writeFile(testing.io, .{ .sub_path = "stray.txt", .data = "x" });
    var third: Cache = .init(testing.allocator);
    try third.openDisk(testing.io, tmp.dir, 2);
    _ = try third.get(arena.allocator(), testing.io, "r", spec, &diag);
    try testing.expectEqual(@as(usize, 3), try countFiles(dir));
    try third.pruneDisk();
    try testing.expectEqual(@as(usize, 1), try countFiles(dir));
    third.deinit();

    // A damaged file is a miss: the spec is drawn again and the file fixed.
    var name_buf: [16]u8 = undefined;
    const name = fileName(&name_buf, 2 ^ cacheKey("r", spec));
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = "MRC1 broken" });
    var fourth: Cache = .init(testing.allocator);
    defer fourth.deinit();
    try fourth.openDisk(testing.io, tmp.dir, 2);
    const again = try fourth.get(arena.allocator(), testing.io, "r", spec, &diag);
    try testing.expectEqualSlices(u8, drawn.png, again.png);
    const fixed = try dir.readFileAlloc(testing.io, name, arena.allocator(), .unlimited);
    try testing.expectEqualSlices(u8, drawn.png, decodeEntry(fixed).?.png);
    first.deinit();
}

test "cache entries round-trip with and without a stylesheet" {
    for ([_]?[]const u8{ null, "", ".a{}" }) |css| {
        const bytes = try encodeEntry(testing.allocator, .{ .png = "PNGDATA", .css = css });
        defer testing.allocator.free(bytes);
        const e = decodeEntry(bytes).?;
        try testing.expectEqualStrings("PNGDATA", e.png);
        if (css) |s| try testing.expectEqualStrings(s, e.css.?) else try testing.expect(e.css == null);
        try testing.expect(decodeEntry(bytes[0 .. bytes.len - 1]) == null);
    }
}
