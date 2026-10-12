//! WOFF2 (W3C WOFF File Format 2.0): font tables compressed together
//! with Brotli.
//!
//! `fromSfnt` applies the glyf transform to TrueType outlines (section
//! 5.1: glyphs split into streams of contour and point counts, flags,
//! packed coordinate deltas, composite records, boxes and instructions,
//! with loca rebuilt by the reader) and stores every other table as it is.
//!
//! `toTables` reads a WOFF2 file back into a font's tables, undoing the
//! glyf, loca and hmtx transforms. Font collections are not read.

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

// ---------------------------------------------------------------------------
// Reading

/// Tags a table directory entry can name by index (section 4.2).
const known_tags = [63]*const [4]u8{
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

pub const Table = struct { tag: [4]u8, data: []const u8 };

/// A font's tables, as `toTables` reads them from a WOFF2 file.
pub const Font = struct { flavor: u32, tables: []Table };

/// Reads big-endian values off the front of a byte slice.
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn bytes(r: *Reader, n: usize) error{InvalidFont}![]const u8 {
        if (r.pos + n > r.data.len) return error.InvalidFont;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    fn u8_(r: *Reader) error{InvalidFont}!u8 {
        return (try r.bytes(1))[0];
    }

    fn u16_(r: *Reader) error{InvalidFont}!u16 {
        return std.mem.readInt(u16, (try r.bytes(2))[0..2], .big);
    }

    fn i16_(r: *Reader) error{InvalidFont}!i16 {
        return std.mem.readInt(i16, (try r.bytes(2))[0..2], .big);
    }

    fn u32_(r: *Reader) error{InvalidFont}!u32 {
        return std.mem.readInt(u32, (try r.bytes(4))[0..4], .big);
    }

    fn base128(r: *Reader) error{InvalidFont}!u32 {
        var v: u32 = 0;
        for (0..5) |k| {
            const b = try r.u8_();
            // No leading zeros, and no overflow.
            if (k == 0 and b == 0x80) return error.InvalidFont;
            if (v & 0xFE000000 != 0) return error.InvalidFont;
            v = v << 7 | (b & 0x7F);
            if (b & 0x80 == 0) return v;
        }
        return error.InvalidFont;
    }

    fn read255(r: *Reader) error{InvalidFont}!u16 {
        const code = try r.u8_();
        return switch (code) {
            253 => try r.u16_(),
            254 => @as(u16, try r.u8_()) + 506,
            255 => @as(u16, try r.u8_()) + 253,
            else => code,
        };
    }
};

/// The tables of the WOFF2 file `bytes`, with the glyf, loca and hmtx
/// transforms undone. `message` says what is wrong when it fails.
pub fn toTables(arena: Allocator, bytes: []const u8, message: *[]const u8) Error!Font {
    return readFont(arena, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFont => {
            if (message.len == 0) message.* = "the WOFF2 file is damaged or uses features Mortise does not read";
            return error.InvalidFont;
        },
        error.Collection => {
            message.* = "WOFF2 font collections are not supported";
            return error.InvalidFont;
        },
        error.Brotli => {
            message.* = "the WOFF2 file's Brotli data does not decode";
            return error.InvalidFont;
        },
    };
}

const Entry = struct { tag: [4]u8, orig_len: u32, transform: u2, transformed: bool, len: u32 };

fn readFont(arena: Allocator, bytes: []const u8) (Allocator.Error || error{ InvalidFont, Collection, Brotli })!Font {
    var r: Reader = .{ .data = bytes };
    if (!std.mem.eql(u8, try r.bytes(4), "wOF2")) return error.InvalidFont;
    const flavor = try r.u32_();
    if (flavor == 0x74746366) return error.Collection; // 'ttcf'
    _ = try r.u32_(); // length
    const num_tables = try r.u16_();
    _ = try r.u16_(); // reserved
    _ = try r.u32_(); // totalSfntSize
    const compressed_len = try r.u32_();
    _ = try r.bytes(4 + 4 * 5); // version, metadata and private data
    const entries = try arena.alloc(Entry, num_tables);
    var total: usize = 0;
    for (entries) |*e| {
        const flags = try r.u8_();
        const tag: [4]u8 = if (flags & 0x3F == 63) (try r.bytes(4))[0..4].* else known_tags[flags & 0x3F].*;
        const version: u2 = @intCast(flags >> 6);
        const is_glyf_loca = std.mem.eql(u8, &tag, "glyf") or std.mem.eql(u8, &tag, "loca");
        // Version 0 transforms glyf and loca; other tables are transformed
        // by any other version.
        const transformed = if (is_glyf_loca) version == 0 else version != 0;
        const orig = try r.base128();
        const len = if (transformed) try r.base128() else orig;
        if (std.mem.eql(u8, &tag, "loca") and transformed and len != 0) return error.InvalidFont;
        e.* = .{ .tag = tag, .orig_len = orig, .transform = version, .transformed = transformed, .len = len };
        total += len;
    }
    const compressed = try r.bytes(compressed_len);
    const stream = brotli.decompress(arena, compressed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Brotli,
    };
    if (stream.len != total) return error.InvalidFont;

    // Each table's data in the stream.
    const datas = try arena.alloc([]const u8, entries.len);
    var at: usize = 0;
    for (entries, datas) |e, *d| {
        d.* = stream[at..][0..e.len];
        at += e.len;
    }
    const find = struct {
        fn f(es: []const Entry, tag: []const u8) ?usize {
            for (es, 0..) |e, k| if (std.mem.eql(u8, &e.tag, tag)) return k;
            return null;
        }
    }.f;
    const tables = try arena.alloc(Table, entries.len);
    for (entries, datas, tables) |e, d, *t| t.* = .{ .tag = e.tag, .data = d };
    const glyf_i = find(entries, "glyf");
    const loca_i = find(entries, "loca");
    if ((glyf_i == null) != (loca_i == null)) return error.InvalidFont;
    var x_mins: ?[]i16 = null;
    if (glyf_i) |gi| {
        const li = loca_i.?;
        if (entries[gi].transformed != entries[li].transformed) return error.InvalidFont;
        if (entries[gi].transformed) {
            const rebuilt = try reconstructGlyf(arena, datas[gi]);
            tables[gi].data = rebuilt.glyf;
            tables[li].data = rebuilt.loca;
            x_mins = rebuilt.x_mins;
        }
    }
    if (find(entries, "hmtx")) |hi| if (entries[hi].transformed) {
        if (entries[hi].transform != 1) return error.InvalidFont;
        const hhea = if (find(entries, "hhea")) |k| tables[k].data else return error.InvalidFont;
        const maxp = if (find(entries, "maxp")) |k| tables[k].data else return error.InvalidFont;
        if (hhea.len < 36 or maxp.len < 6) return error.InvalidFont;
        tables[hi].data = try reconstructHmtx(arena, datas[hi], u16At(hhea, 34), u16At(maxp, 4), x_mins orelse return error.InvalidFont);
    };
    for (entries, tables) |e, t| {
        if (e.transformed and !std.mem.eql(u8, &e.tag, "glyf") and !std.mem.eql(u8, &e.tag, "loca") and !std.mem.eql(u8, &e.tag, "hmtx")) return error.InvalidFont;
        _ = t;
    }
    return .{ .flavor = flavor, .tables = tables };
}

const Rebuilt = struct { glyf: []u8, loca: []u8, x_mins: []i16 };

/// Undoes the glyf transform (section 5.1): rebuilds glyf and loca, and
/// notes each glyph's xMin for the hmtx transform.
fn reconstructGlyf(arena: Allocator, data: []const u8) (Allocator.Error || error{InvalidFont})!Rebuilt {
    var h: Reader = .{ .data = data };
    _ = try h.u16_(); // reserved
    const options = try h.u16_();
    const num_glyphs = try h.u16_();
    const long_loca = try h.u16_() == 1;
    var sizes: [7]u32 = undefined;
    for (&sizes) |*s| s.* = try h.u32_();
    var streams: [7]Reader = undefined;
    for (&streams, sizes) |*s, size| s.* = .{ .data = try h.bytes(size) };
    var n_contour = &streams[0];
    var n_points = &streams[1];
    var flag_s = &streams[2];
    var glyph_s = &streams[3];
    var composite_s = &streams[4];
    var bbox_s = &streams[5];
    var instr_s = &streams[6];
    const bitmap = try bbox_s.bytes(4 * ((@as(usize, num_glyphs) + 31) / 32));
    const overlap: ?[]const u8 = if (options & 1 != 0) try h.bytes((@as(usize, num_glyphs) + 7) / 8) else null;

    var glyf: std.ArrayList(u8) = .empty;
    const offsets = try arena.alloc(u32, @as(usize, num_glyphs) + 1);
    const x_mins = try arena.alloc(i16, num_glyphs);
    for (0..num_glyphs) |g| {
        offsets[g] = @intCast(glyf.items.len);
        x_mins[g] = 0;
        const has_bbox = bitmap[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0;
        const contours = try n_contour.i16_();
        if (contours == 0) {
            if (has_bbox) return error.InvalidFont;
            continue;
        }
        const start = glyf.items.len;
        if (contours < 0) {
            if (contours != -1 or !has_bbox) return error.InvalidFont;
            const bbox = try bbox_s.bytes(8);
            x_mins[g] = std.mem.readInt(i16, bbox[0..2], .big);
            try glyf.appendSlice(arena, &.{ 0xFF, 0xFF });
            try glyf.appendSlice(arena, bbox);
            // Component records, as written.
            const comp_start = composite_s.pos;
            var has_instructions = false;
            while (true) {
                const flags = try composite_s.u16_();
                _ = try composite_s.u16_();
                var size: usize = if (flags & 0x1 != 0) 4 else 2;
                if (flags & 0x8 != 0) size += 2 else if (flags & 0x40 != 0) size += 4 else if (flags & 0x80 != 0) size += 8;
                _ = try composite_s.bytes(size);
                if (flags & 0x100 != 0) has_instructions = true;
                if (flags & 0x20 == 0) break;
            }
            try glyf.appendSlice(arena, composite_s.data[comp_start..composite_s.pos]);
            if (has_instructions) {
                const len = try glyph_s.read255();
                try glyf.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, len)));
                try glyf.appendSlice(arena, try instr_s.bytes(len));
            }
        } else {
            const nc: usize = @intCast(contours);
            const end_pts = try arena.alloc(u16, nc);
            var points: usize = 0;
            for (end_pts) |*e| {
                points += try n_points.read255();
                if (points == 0 or points > 0xFFFF) return error.InvalidFont;
                e.* = @intCast(points - 1);
            }
            const on = try arena.alloc(bool, points);
            const xs = try arena.alloc(i32, points);
            const ys = try arena.alloc(i32, points);
            var x: i32 = 0;
            var y: i32 = 0;
            for (on, xs, ys) |*o, *px, *py| {
                const raw = try flag_s.u8_();
                o.* = raw & 0x80 == 0;
                const d = try tripletDecode(raw & 0x7F, glyph_s);
                x += d[0];
                y += d[1];
                px.* = x;
                py.* = y;
            }
            const ilen = try glyph_s.read255();
            const instructions = try instr_s.bytes(ilen);
            var bbox: [4]i32 = undefined;
            if (has_bbox) {
                const b = try bbox_s.bytes(8);
                for (&bbox, 0..) |*v, k| v.* = std.mem.readInt(i16, b[k * 2 ..][0..2], .big);
            } else {
                bbox = .{ std.mem.min(i32, xs), std.mem.min(i32, ys), std.mem.max(i32, xs), std.mem.max(i32, ys) };
            }
            x_mins[g] = @intCast(bbox[0]);
            try glyf.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, contours)));
            for (bbox) |v| try glyf.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(v))));
            for (end_pts) |e| try glyf.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, e)));
            try glyf.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, ilen)));
            try glyf.appendSlice(arena, instructions);
            const overlaps = if (overlap) |o| o[g >> 3] & (@as(u8, 0x80) >> @intCast(g & 7)) != 0 else false;
            try writeOutline(arena, &glyf, on, xs, ys, overlaps);
        }
        _ = start;
        // Glyphs start at even offsets, at offsets of four with long loca.
        const alignment: usize = if (long_loca) 4 else 2;
        while (glyf.items.len % alignment != 0) try glyf.append(arena, 0);
    }
    offsets[num_glyphs] = @intCast(glyf.items.len);
    var loca: std.ArrayList(u8) = .empty;
    for (offsets) |o| {
        if (long_loca) {
            try loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, o)));
        } else {
            if (o / 2 > 0xFFFF) return error.InvalidFont;
            try loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(o / 2))));
        }
    }
    return .{ .glyf = glyf.items, .loca = loca.items, .x_mins = x_mins };
}

/// The x and y deltas of a point from its flag and the glyph stream.
fn tripletDecode(flag: u8, s: *Reader) error{InvalidFont}![2]i32 {
    const sign = struct {
        fn f(bit: u8, v: i32) i32 {
            return if (bit & 1 != 0) v else -v;
        }
    }.f;
    if (flag < 10) {
        const b = try s.u8_();
        return .{ 0, sign(flag, (@as(i32, flag & 14) << 7) + b) };
    }
    if (flag < 20) {
        const b = try s.u8_();
        return .{ sign(flag, (@as(i32, (flag - 10) & 14) << 7) + b), 0 };
    }
    if (flag < 84) {
        const b0: i32 = flag - 20;
        const b1: i32 = try s.u8_();
        return .{ sign(flag, 1 + (b0 & 0x30) + (b1 >> 4)), sign(flag >> 1, 1 + ((b0 & 0x0C) << 2) + (b1 & 0x0F)) };
    }
    if (flag < 120) {
        const b0: i32 = flag - 84;
        const b = try s.bytes(2);
        return .{ sign(flag, 1 + (@divTrunc(b0, 12) << 8) + b[0]), sign(flag >> 1, 1 + ((@rem(b0, 12) >> 2) << 8) + b[1]) };
    }
    if (flag < 124) {
        const b = try s.bytes(3);
        return .{ sign(flag, (@as(i32, b[0]) << 4) + (b[1] >> 4)), sign(flag >> 1, (@as(i32, b[1] & 0x0F) << 8) + b[2]) };
    }
    const b = try s.bytes(4);
    return .{ sign(flag, (@as(i32, b[0]) << 8) + b[1]), sign(flag >> 1, (@as(i32, b[2]) << 8) + b[3]) };
}

/// A simple glyph's flags and coordinates in TrueType's form, with short
/// and repeated values packed.
fn writeOutline(arena: Allocator, out: *std.ArrayList(u8), on: []const bool, xs: []const i32, ys: []const i32, overlaps: bool) Allocator.Error!void {
    const n = on.len;
    const flags = try arena.alloc(u8, n);
    var xb: std.ArrayList(u8) = .empty;
    var yb: std.ArrayList(u8) = .empty;
    var px: i32 = 0;
    var py: i32 = 0;
    for (0..n) |k| {
        var f: u8 = if (on[k]) 0x01 else 0;
        if (k == 0 and overlaps) f |= 0x40;
        const dx = xs[k] - px;
        const dy = ys[k] - py;
        px = xs[k];
        py = ys[k];
        if (dx == 0) {
            f |= 0x10;
        } else if (dx > -256 and dx < 256) {
            f |= 0x02;
            if (dx > 0) f |= 0x10;
            try xb.append(arena, @intCast(@abs(dx)));
        } else {
            try xb.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(dx))));
        }
        if (dy == 0) {
            f |= 0x20;
        } else if (dy > -256 and dy < 256) {
            f |= 0x04;
            if (dy > 0) f |= 0x20;
            try yb.append(arena, @intCast(@abs(dy)));
        } else {
            try yb.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, @intCast(dy))));
        }
        flags[k] = f;
    }
    // Runs of equal flags use the repeat flag.
    var k: usize = 0;
    while (k < n) {
        var run: usize = 1;
        while (k + run < n and flags[k + run] == flags[k] and run < 256) run += 1;
        if (run > 2) {
            try out.appendSlice(arena, &.{ flags[k] | 0x08, @intCast(run - 1) });
        } else {
            for (0..run) |_| try out.append(arena, flags[k]);
        }
        k += run;
    }
    try out.appendSlice(arena, xb.items);
    try out.appendSlice(arena, yb.items);
}

/// Undoes the hmtx transform (section 5.4): left side bearings left out
/// are each glyph's xMin.
fn reconstructHmtx(arena: Allocator, data: []const u8, num_hmetrics: u16, num_glyphs: u16, x_mins: []const i16) (Allocator.Error || error{InvalidFont})![]u8 {
    if (num_hmetrics == 0 or num_hmetrics > num_glyphs or x_mins.len != num_glyphs) return error.InvalidFont;
    var r: Reader = .{ .data = data };
    const flags = try r.u8_();
    if (flags & 0xFC != 0 or flags & 3 == 0) return error.InvalidFont;
    const advances = try arena.alloc(u16, num_hmetrics);
    for (advances) |*a| a.* = try r.u16_();
    const lsbs = try arena.alloc(i16, num_glyphs);
    for (lsbs[0..num_hmetrics], 0..) |*l, g| l.* = if (flags & 1 == 0) try r.i16_() else x_mins[g];
    for (lsbs[num_hmetrics..], num_hmetrics..) |*l, g| l.* = if (flags & 2 == 0) try r.i16_() else x_mins[g];
    var out: std.ArrayList(u8) = .empty;
    for (0..num_glyphs) |g| {
        if (g < num_hmetrics) try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, advances[g])));
        try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i16, lsbs[g])));
    }
    return out.items;
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

    // Undoing the transform gives glyphs that transform the same way, and
    // the same glyph bytes here, since the original was written compactly.
    const back = try reconstructGlyf(a, out);
    try testing.expectEqualSlices(u8, out, (try transformGlyf(a, back.glyf, back.loca, 3, true)).?);
    try testing.expectEqualSlices(u8, &simple, back.glyf[0..simple.len]);
    try testing.expectEqualSlices(i16, &.{ 0, 0, 0 }, back.x_mins);
    try testing.expectEqualSlices(u8, &composite, back.glyf[24..40]);
}

test "fromSfnt and toTables round trip, with hmtx rebuilt from glyph boxes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A transformed hmtx: flags 3 (both kinds of side bearing left out),
    // two advance widths; the bearings come from the glyphs' xMin (0).
    const hmtx_t = [_]u8{ 3, 0x02, 0x58, 0x01, 0xF4 };
    const rebuilt = try reconstructHmtx(a, &hmtx_t, 2, 3, &.{ 0, 5, -7 });
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x58, 0, 0, 0x01, 0xF4, 0, 5, 0xFF, 0xF9 }, rebuilt);
    try testing.expectError(error.InvalidFont, reconstructHmtx(a, &hmtx_t, 4, 3, &.{ 0, 0, 0 }));

    // A small font through WOFF2 and back: the same tables.
    var sfnt: std.ArrayList(u8) = .empty;
    try sfnt.appendSlice(a, &.{ 0, 1, 0, 0, 0, 2, 0, 32, 0, 1, 0, 0 });
    try sfnt.appendSlice(a, "head" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x2C" ++ "\x00\x00\x00\x10");
    try sfnt.appendSlice(a, "name" ++ "\x00\x00\x00\x00" ++ "\x00\x00\x00\x3C" ++ "\x00\x00\x00\x05");
    try sfnt.appendSlice(a, "head table data.");
    try sfnt.appendSlice(a, "names");
    const w = try fromSfnt(a, sfnt.items);
    var message: []const u8 = "";
    const f = try toTables(a, w, &message);
    try testing.expectEqual(@as(u32, 0x00010000), f.flavor);
    try testing.expectEqual(@as(usize, 2), f.tables.len);
    try testing.expectEqualStrings("head", &f.tables[0].tag);
    try testing.expectEqualStrings("head table data.", f.tables[0].data);
    try testing.expectEqualStrings("names", f.tables[1].data);
    // Damage is reported, not a crash.
    try testing.expectError(error.InvalidFont, toTables(a, w[0 .. w.len - 8], &message));
    try testing.expect(message.len > 0);
}

test "triplets decode to what they encode" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_][2]i32{ .{ 0, 0 }, .{ 0, -1279 }, .{ 1279, 0 }, .{ -64, 64 }, .{ 1, -1 }, .{ 768, -768 }, .{ 4095, 4095 }, .{ -4096, 5 }, .{ 32767, -32768 + 1 }, .{ -300, 0 } };
    for (cases) |c| {
        var s: GlyfStreams = .{};
        try s.triplet(a, true, c[0], c[1]);
        var r: Reader = .{ .data = s.glyph.items };
        const d = try tripletDecode(s.flags.items[0] & 0x7F, &r);
        try testing.expectEqual(c, d);
        try testing.expectEqual(s.glyph.items.len, r.pos);
    }
}
