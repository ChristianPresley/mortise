//! WOFF2 (W3C WOFF File Format 2.0): font tables compressed together
//! with Brotli.
//!
//! `fromSfnt` applies the glyf transform to TrueType outlines (section
//! 5.1: glyphs split into streams of contour and point counts, flags,
//! packed coordinate deltas, composite records, boxes and instructions,
//! with loca rebuilt by the reader) and stores every other table as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const brotli = @import("brotli.zig");

pub const Error = Allocator.Error || error{InvalidFont};

fn u16At(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

fn writeBase128(out: *std.ArrayList(u8), arena: Allocator, v: u32) Allocator.Error!void {
    var bytes: [5]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        bytes[n] = @intCast(x & 0x7F);
        n += 1;
        x >>= 7;
        if (x == 0) break;
    }
    var i = n;
    while (i > 0) {
        i -= 1;
        try out.append(arena, bytes[i] | if (i > 0) @as(u8, 0x80) else 0);
    }
}

fn write255(out: *std.ArrayList(u8), arena: Allocator, v: u16) Allocator.Error!void {
    if (v < 253) {
        try out.append(arena, @intCast(v));
    } else if (v < 506) {
        try out.appendSlice(arena, &.{ 255, @intCast(v - 253) });
    } else if (v < 762) {
        try out.appendSlice(arena, &.{ 254, @intCast(v - 506) });
    } else {
        try out.appendSlice(arena, &.{ 253, @intCast(v >> 8), @truncate(v) });
    }
}

fn writeI16(out: *std.ArrayList(u8), arena: Allocator, v: i16) Allocator.Error!void {
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, v)));
}

/// The streams of a transformed glyf table (WOFF2 section 5.1).
const GlyfStreams = struct {
    n_contour: std.ArrayList(u8) = .empty,
    n_points: std.ArrayList(u8) = .empty,
    flags: std.ArrayList(u8) = .empty,
    glyph: std.ArrayList(u8) = .empty,
    composite: std.ArrayList(u8) = .empty,
    bbox_bitmap: []u8 = &.{},
    bbox: std.ArrayList(u8) = .empty,
    instructions: std.ArrayList(u8) = .empty,
    overlap: []u8 = &.{},
    has_overlap: bool = false,

    /// One point, as a flag and the bytes of its x and y deltas.
    fn triplet(s: *GlyfStreams, arena: Allocator, on_curve: bool, x: i32, y: i32) Allocator.Error!void {
        const ax: u32 = @abs(x);
        const ay: u32 = @abs(y);
        const on: u8 = if (on_curve) 0 else 128;
        const xs: u8 = if (x < 0) 0 else 1;
        const ys: u8 = if (y < 0) 0 else 1;
        const xy = xs + 2 * ys;
        if (x == 0 and ay < 1280) {
            try s.flags.append(arena, on + @as(u8, @intCast((ay & 0xF00) >> 7)) + ys);
            try s.glyph.append(arena, @truncate(ay));
        } else if (y == 0 and ax < 1280) {
            try s.flags.append(arena, on + 10 + @as(u8, @intCast((ax & 0xF00) >> 7)) + xs);
            try s.glyph.append(arena, @truncate(ax));
        } else if (ax < 65 and ay < 65) {
            try s.flags.append(arena, on + 20 + @as(u8, @intCast((ax - 1) & 0x30)) + @as(u8, @intCast(((ay - 1) & 0x30) >> 2)) + xy);
            try s.glyph.append(arena, @intCast((((ax - 1) & 0xF) << 4) | ((ay - 1) & 0xF)));
        } else if (ax < 769 and ay < 769) {
            try s.flags.append(arena, on + 84 + 12 * @as(u8, @intCast(((ax - 1) & 0x300) >> 8)) + @as(u8, @intCast(((ay - 1) & 0x300) >> 6)) + xy);
            try s.glyph.appendSlice(arena, &.{ @truncate(ax - 1), @truncate(ay - 1) });
        } else if (ax < 4096 and ay < 4096) {
            try s.flags.append(arena, on + 120 + xy);
            try s.glyph.appendSlice(arena, &.{ @intCast(ax >> 4), @intCast(((ax & 0xF) << 4) | (ay >> 8)), @truncate(ay) });
        } else {
            try s.flags.append(arena, on + 124 + xy);
            try s.glyph.appendSlice(arena, &.{ @truncate(ax >> 8), @truncate(ax), @truncate(ay >> 8), @truncate(ay) });
        }
    }
};

/// The glyf table in WOFF2's transformed form, or null when a glyph
/// cannot be read, in which case the table is stored as it is.
fn transformGlyf(arena: Allocator, glyf: []const u8, loca: []const u8, num_glyphs: u16, long_loca: bool) Allocator.Error!?[]u8 {
    if (loca.len < (@as(usize, num_glyphs) + 1) * @as(usize, if (long_loca) 4 else 2)) return null;
    var s: GlyfStreams = .{};
    const bitmap_len = 4 * ((@as(usize, num_glyphs) + 31) / 32);
    s.bbox_bitmap = try arena.alloc(u8, bitmap_len);
    @memset(s.bbox_bitmap, 0);
    s.overlap = try arena.alloc(u8, (@as(usize, num_glyphs) + 7) / 8);
    @memset(s.overlap, 0);
    for (0..num_glyphs) |g| {
        const start: usize = if (long_loca) u32At(loca, g * 4) else @as(usize, u16At(loca, g * 2)) * 2;
        const end: usize = if (long_loca) u32At(loca, (g + 1) * 4) else @as(usize, u16At(loca, (g + 1) * 2)) * 2;
        if (end < start or end > glyf.len) return null;
        const data = glyf[start..end];
        if (data.len == 0) {
            try writeI16(&s.n_contour, arena, 0);
            continue;
        }
        if (data.len < 10) return null;
        const contours = std.mem.readInt(i16, data[0..2], .big);
        const bbox = data[2..10];
        if (contours < 0) {
            // Composite: its component records go as they are, and the
            // bounding box is always explicit.
            try writeI16(&s.n_contour, arena, -1);
            s.bbox_bitmap[g >> 3] |= @as(u8, 0x80) >> @intCast(g & 7);
            try s.bbox.appendSlice(arena, bbox);
            var p: usize = 10;
            var has_instructions = false;
            while (true) {
                if (p + 4 > data.len) return null;
                const flags = u16At(data, p);
                var size: usize = 4 + @as(usize, if (flags & 0x1 != 0) 4 else 2);
                if (flags & 0x8 != 0) size += 2 else if (flags & 0x40 != 0) size += 4 else if (flags & 0x80 != 0) size += 8;
                if (p + size > data.len) return null;
                if (flags & 0x100 != 0) has_instructions = true;
                p += size;
                if (flags & 0x20 == 0) break;
            }
            try s.composite.appendSlice(arena, data[10..p]);
            if (has_instructions) {
                if (p + 2 > data.len) return null;
                const len = u16At(data, p);
                if (p + 2 + len > data.len) return null;
                try write255(&s.glyph, arena, len);
                try s.instructions.appendSlice(arena, data[p + 2 ..][0..len]);
            }
            continue;
        }
        if (contours == 0) {
            try writeI16(&s.n_contour, arena, 0);
            continue;
        }
        // Simple glyph: end points, instructions, flags, x, y.
        const nc: usize = @intCast(contours);
        if (10 + 2 * nc + 2 > data.len) return null;
        try writeI16(&s.n_contour, arena, contours);
        var prev_end: i32 = -1;
        for (0..nc) |k| {
            const e: i32 = u16At(data, 10 + 2 * k);
            if (e <= prev_end) return null;
            try write255(&s.n_points, arena, @intCast(e - prev_end));
            prev_end = e;
        }
        const points: usize = @intCast(prev_end + 1);
        var p = 10 + 2 * nc;
        const ilen = u16At(data, p);
        p += 2;
        if (p + ilen > data.len) return null;
        const instructions = data[p..][0..ilen];
        p += ilen;
        const flags = try arena.alloc(u8, points);
        var k: usize = 0;
        while (k < points) {
            if (p >= data.len) return null;
            const f = data[p];
            p += 1;
            flags[k] = f;
            k += 1;
            if (f & 0x8 != 0) {
                if (p >= data.len) return null;
                const repeat = data[p];
                p += 1;
                if (k + repeat > points) return null;
                @memset(flags[k..][0..repeat], f);
                k += repeat;
            }
        }
        const xs = try arena.alloc(i32, points);
        const ys = try arena.alloc(i32, points);
        for ([_]struct { out: []i32, short: u8, same: u8 }{ .{ .out = xs, .short = 0x2, .same = 0x10 }, .{ .out = ys, .short = 0x4, .same = 0x20 } }) |axis| {
            for (flags, axis.out) |f, *d| {
                if (f & axis.short != 0) {
                    if (p >= data.len) return null;
                    const v: i32 = data[p];
                    p += 1;
                    d.* = if (f & axis.same != 0) v else -v;
                } else if (f & axis.same != 0) {
                    d.* = 0;
                } else {
                    if (p + 2 > data.len) return null;
                    d.* = std.mem.readInt(i16, data[p..][0..2], .big);
                    p += 2;
                }
            }
        }
        if (flags[0] & 0x40 != 0) {
            s.has_overlap = true;
            s.overlap[g >> 3] |= @as(u8, 0x80) >> @intCast(g & 7);
        }
        // The box the points give, unless the glyph says otherwise.
        var x: i32 = 0;
        var y: i32 = 0;
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        for (flags, xs, ys) |f, dx, dy| {
            try s.triplet(arena, f & 0x1 != 0, dx, dy);
            x += dx;
            y += dy;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
        const given = [4]i32{ std.mem.readInt(i16, bbox[0..2], .big), std.mem.readInt(i16, bbox[2..4], .big), std.mem.readInt(i16, bbox[4..6], .big), std.mem.readInt(i16, bbox[6..8], .big) };
        if (!std.mem.eql(i32, &given, &.{ min_x, min_y, max_x, max_y })) {
            s.bbox_bitmap[g >> 3] |= @as(u8, 0x80) >> @intCast(g & 7);
            try s.bbox.appendSlice(arena, bbox);
        }
        try write255(&s.glyph, arena, ilen);
        try s.instructions.appendSlice(arena, instructions);
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, &.{ 0, 0 });
    try out.appendSlice(arena, &.{ 0, @intFromBool(s.has_overlap) });
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, num_glyphs)));
    try out.appendSlice(arena, &.{ 0, @intFromBool(long_loca) });
    const streams = [_][]const u8{ s.n_contour.items, s.n_points.items, s.flags.items, s.glyph.items, s.composite.items };
    for (streams) |st| try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(st.len))));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(s.bbox_bitmap.len + s.bbox.items.len))));
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(s.instructions.items.len))));
    for (streams) |st| try out.appendSlice(arena, st);
    try out.appendSlice(arena, s.bbox_bitmap);
    try out.appendSlice(arena, s.bbox.items);
    try out.appendSlice(arena, s.instructions.items);
    if (s.has_overlap) try out.appendSlice(arena, s.overlap);
    return out.items;
}

/// The bytes of table `tag` in `sfnt`, or null.
fn findTable(sfnt: []const u8, tag: []const u8) ?[]const u8 {
    const n = u16At(sfnt, 4);
    for (0..n) |i| {
        const rec = sfnt[12 + i * 16 ..][0..16];
        if (!std.mem.eql(u8, rec[0..4], tag)) continue;
        const off = u32At(rec, 8);
        const len = u32At(rec, 12);
        if (@as(usize, off) + len > sfnt.len) return null;
        return sfnt[off..][0..len];
    }
    return null;
}

/// A WOFF2 file holding the tables of the TrueType or OpenType font
/// `sfnt`.
pub fn fromSfnt(arena: Allocator, sfnt: []const u8) Error![]u8 {
    if (sfnt.len < 12) return error.InvalidFont;
    const flavor = u32At(sfnt, 0);
    const n = u16At(sfnt, 4);
    if (sfnt.len < 12 + @as(usize, n) * 16) return error.InvalidFont;
    // TrueType outlines are transformed when every glyph can be read.
    var glyf_transformed: ?[]u8 = null;
    if (findTable(sfnt, "glyf")) |glyf| if (findTable(sfnt, "loca")) |loca| if (findTable(sfnt, "head")) |head| if (findTable(sfnt, "maxp")) |maxp| {
        if (head.len >= 54 and maxp.len >= 6) {
            glyf_transformed = try transformGlyf(arena, glyf, loca, u16At(maxp, 4), std.mem.readInt(i16, head[50..52], .big) == 1);
        }
    };
    var dir: std.ArrayList(u8) = .empty;
    var stream: std.ArrayList(u8) = .empty;
    var sfnt_size: usize = 12 + 16 * @as(usize, n);
    for (0..n) |i| {
        const rec = sfnt[12 + i * 16 ..][0..16];
        const tag = rec[0..4];
        const off = u32At(rec, 8);
        const len = u32At(rec, 12);
        if (@as(usize, off) + len > sfnt.len) return error.InvalidFont;
        sfnt_size += (@as(usize, len) + 3) / 4 * 4;
        // Tag index 63: the tag follows.
        const is_glyf = std.mem.eql(u8, tag, "glyf");
        const is_loca = std.mem.eql(u8, tag, "loca");
        if ((is_glyf or is_loca) and glyf_transformed != null) {
            // Transform version 0 for glyf and loca: transformed, with a
            // transformLength; loca is rebuilt from glyf and has none.
            try dir.append(arena, 63);
            try dir.appendSlice(arena, tag);
            try writeBase128(&dir, arena, len);
            if (is_glyf) {
                try writeBase128(&dir, arena, @intCast(glyf_transformed.?.len));
                try stream.appendSlice(arena, glyf_transformed.?);
            } else {
                try writeBase128(&dir, arena, 0);
            }
            continue;
        }
        // glyf and loca say "null transform" with version 3; other tables
        // with version 0.
        const null_transform: u8 = if (is_glyf or is_loca) 3 else 0;
        try dir.append(arena, 63 | null_transform << 6);
        try dir.appendSlice(arena, tag);
        try writeBase128(&dir, arena, len);
        try stream.appendSlice(arena, sfnt[off..][0..len]);
    }
    const compressed = try brotli.compress(arena, stream.items);
    const header_len = 48;
    const unpadded = header_len + dir.items.len + compressed.len;
    const total = (unpadded + 3) / 4 * 4;
    const out = try arena.alloc(u8, total);
    @memset(out, 0);
    @memcpy(out[0..4], "wOF2");
    std.mem.writeInt(u32, out[4..8], flavor, .big);
    std.mem.writeInt(u32, out[8..12], @intCast(total), .big);
    std.mem.writeInt(u16, out[12..14], n, .big);
    std.mem.writeInt(u32, out[16..20], @intCast(sfnt_size), .big);
    std.mem.writeInt(u32, out[20..24], @intCast(compressed.len), .big);
    std.mem.writeInt(u16, out[24..26], 1, .big);
    @memcpy(out[header_len..][0..dir.items.len], dir.items);
    @memcpy(out[header_len + dir.items.len ..][0..compressed.len], compressed);
    return out;
}

const testing = std.testing;

test "base 128 numbers are big-endian with continuation bits" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeBase128(&out, a, 0);
    try writeBase128(&out, a, 127);
    try writeBase128(&out, a, 128);
    try writeBase128(&out, a, 63 * 128 * 128 + 1);
    try testing.expectEqualSlices(u8, &.{ 0, 0x7F, 0x81, 0x00, 0xBF, 0x80, 0x01 }, out.items);
}

test "fromSfnt: header, directory and the tables in one Brotli stream" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A two-table font: glyf (null transform, version 3) and head.
    var sfnt: std.ArrayList(u8) = .empty;
    try sfnt.appendSlice(a, &.{ 0, 1, 0, 0, 0, 2, 0, 32, 0, 1, 0, 0 });
    const glyf = "glyph data!";
    const head = "head table data.";
    try sfnt.appendSlice(a, "glyf" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x2C" ++ "\x00\x00\x00\x0B");
    try sfnt.appendSlice(a, "head" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x38" ++ "\x00\x00\x00\x10");
    try sfnt.appendSlice(a, glyf ++ "\x00");
    try sfnt.appendSlice(a, head);
    const out = try fromSfnt(a, sfnt.items);
    try testing.expectEqualStrings("wOF2", out[0..4]);
    try testing.expectEqual(@as(u32, 0x00010000), u32At(out, 4));
    try testing.expectEqual(@as(u32, @intCast(out.len)), u32At(out, 8));
    try testing.expect(out.len % 4 == 0);
    try testing.expectEqual(@as(u16, 2), u16At(out, 12));
    // 12 + 2 * 16 + 12 + 16: each table padded to four bytes.
    try testing.expectEqual(@as(u32, 72), u32At(out, 16));
    // Directory: flags 0xFF (tag follows, null transform), "glyf", 11;
    // flags 0x3F, "head", 16.
    try testing.expectEqualSlices(u8, &.{ 0xFF, 'g', 'l', 'y', 'f', 11, 0x3F, 'h', 'e', 'a', 'd', 16 }, out[48..60]);
    const compressed = out[60..][0..u32At(out, 20)];
    try testing.expectEqualStrings(glyf ++ head, try brotli.decompress(a, compressed));
}

test "the glyf transform splits glyphs into WOFF2's streams" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Glyph 1: one contour of three points, (0,0) and (100,0) on the
    // curve, (50,700) off it, with two bytes of instructions. Its box is
    // the one its points give.
    const simple = [_]u8{
        0, 1, 0, 0, 0, 0, 0, 100, 2, 0xBC, // contours, box 0 0 100 700
        0, 2, // end point
        0, 2, 0xB0, 0x01, // instructions
        0x31, 0x33, 0x02, // flags
        100, 50, // x: +100, -50
        2, 0xBC, // y: +700
    };
    // Glyph 2: a composite of glyph 1 moved by (10, 0).
    const composite = [_]u8{ 0xFF, 0xFF, 0, 0, 0, 0, 0, 100, 2, 0xBC, 0, 2, 0, 1, 10, 0 };
    var glyf: std.ArrayList(u8) = .empty;
    try glyf.appendSlice(a, &simple);
    try glyf.append(a, 0);
    try glyf.appendSlice(a, &composite);
    var loca: std.ArrayList(u8) = .empty;
    for ([_]u32{ 0, 0, 24, 40 }) |o| try loca.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, o)));
    const out = (try transformGlyf(a, glyf.items, loca.items, 3, true)).?;
    const want = [_]u8{
        0, 0, 0, 0, 0, 3, 0, 1, // version, options, glyphs, long loca
        0, 0, 0, 6, 0, 0, 0, 1,  0, 0, 0, 3, 0, 0, 0, 5, // stream sizes
        0, 0, 0, 6, 0, 0, 0, 12, 0, 0, 0, 2,
        0, 0, 0, 1, 0xFF, 0xFF, // contours: empty, 1, composite
        3, // points in the contour
        1, 11, 222, // flags: (0,0); (+100,0); off curve (-50,+700)
        0, 100, 49, 187, 2, // their bytes, then the instruction length
        0, 2, 0, 1, 10, 0, // the component record
        0x20, 0, 0, 0, 0, 0, 0, 0, 0, 100, 2, 0xBC, // the composite's box
        0xB0, 0x01, // instructions
    };
    try testing.expectEqualSlices(u8, &want, out);
    // A glyph that cannot be read leaves the table untransformed.
    try testing.expect(try transformGlyf(a, glyf.items[0..20], loca.items, 3, true) == null);
}
