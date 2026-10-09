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
//! and editing a spec re-renders only that spec.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const r = @import("render");
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

pub const Kind = enum { starfield, panel, reticle, radar, planet, hologram };

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
/// server renders each version of a spec once. Owns its memory.
pub const Cache = struct {
    gpa: Allocator,
    entries: std.AutoHashMapUnmanaged(u64, Rendered) = .empty,

    pub fn init(gpa: Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        var it = c.entries.valueIterator();
        while (it.next()) |v| {
            c.gpa.free(v.png);
            if (v.css) |css| c.gpa.free(css);
        }
        c.entries.deinit(c.gpa);
        c.* = undefined;
    }

    /// The rendered asset for `source` under `name`, from the cache or
    /// freshly rendered. The result lives as long as the cache.
    pub fn get(c: *Cache, arena: Allocator, io: std.Io, name: []const u8, source: []const u8, diag: *Diagnostic) Error!Rendered {
        var h: std.hash.Wyhash = .init(0);
        h.update(name);
        h.update(&.{0});
        h.update(source);
        const key = h.final();
        if (c.entries.get(key)) |hit| return hit;
        const fresh = try render(c.gpa, arena, io, name, source, diag);
        c.entries.put(c.gpa, key, fresh) catch |e| {
            c.gpa.free(fresh.png);
            if (fresh.css) |css| c.gpa.free(css);
            return e;
        };
        return fresh;
    }
};

/// Renders with the cache when there is one, else into `arena`.
pub fn renderCached(cache: ?*Cache, arena: Allocator, io: std.Io, name: []const u8, source: []const u8, diag: *Diagnostic) Error!Rendered {
    if (cache) |c| return c.get(arena, io, name, source, diag);
    return render(arena, arena, io, name, source, diag);
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
    try expectSpecError("width: 64\n", 0, "'kind' is required; it must be one of: starfield, panel, reticle, radar, planet, hologram");
    try expectSpecError("kind: nebula\n", 1, "'kind' must be one of: starfield, panel, reticle, radar, planet, hologram");
    try expectSpecError("kind: starfield\nwidht: 64\n", 2, "unknown field 'widht'");
    try expectSpecError("kind: starfield\nwidth: 99999\n", 2, "'width' must be a whole number from 8 to 4096");
    try expectSpecError("kind: reticle\ncolor: teal\n", 2, "'color' must be a color such as \"#3fd8ff\" (quoted, since # starts a comment)");
    try expectSpecError("kind: panel\nwidth: 64\nheight: 64\n", 0, "the panel is too small for its corners; make it at least 152 pixels on each side");
    try expectSpecError("kind: [a\n", 1, "unterminated list; add ']'");
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
