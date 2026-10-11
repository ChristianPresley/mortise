//! JPEG decoding and encoding.
//!
//! The decoder reads 8-bit Huffman-coded JPEGs, baseline or progressive,
//! gray or three-component (YCbCr, or RGB when an Adobe marker says so),
//! with any chroma subsampling and restart intervals. Arithmetic coding,
//! lossless and 12-bit JPEGs, and CMYK are rejected as `Unsupported`.
//!
//! The encoder writes baseline JPEGs with 4:2:0 chroma subsampling and the
//! standard Huffman tables, at an IJG-style quality from 1 to 100.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const png = @import("png.zig");

pub const Image = png.Image;

pub const DecodeError = Allocator.Error || error{ NotJpeg, Corrupt, Unsupported };

/// `zigzag[k]` is the natural (row-major) index of the k-th coefficient in
/// zigzag order.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

// ---------------------------------------------------------------------------
// Header inspection

/// Width and height from a JPEG's frame header, as stored (before EXIF
/// orientation).
pub fn size(bytes: []const u8) ?[2]u32 {
    var it: Segments = .{ .bytes = bytes };
    if (!std.mem.startsWith(u8, bytes, "\xff\xd8")) return null;
    while (it.next()) |seg| {
        switch (seg.marker) {
            0xc0...0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => {
                if (seg.data.len < 5) return null;
                const h = std.mem.readInt(u16, seg.data[1..3], .big);
                const w = std.mem.readInt(u16, seg.data[3..5], .big);
                if (w == 0 or h == 0) return null;
                return .{ w, h };
            },
            0xda, 0xd9 => return null,
            else => {},
        }
    }
    return null;
}

/// The EXIF orientation (1 to 8) of a JPEG, or 1 when it has none. Values
/// 5 to 8 mean the stored image is turned on its side.
pub fn orientation(bytes: []const u8) u8 {
    var it: Segments = .{ .bytes = bytes };
    while (it.next()) |seg| {
        if (seg.marker == 0xda) break;
        if (seg.marker != 0xe1 or !std.mem.startsWith(u8, seg.data, "Exif\x00\x00")) continue;
        const tiff = seg.data[6..];
        if (tiff.len < 8) return 1;
        const endian: std.builtin.Endian = if (std.mem.eql(u8, tiff[0..2], "II")) .little else if (std.mem.eql(u8, tiff[0..2], "MM")) .big else return 1;
        const ifd = std.mem.readInt(u32, tiff[4..8], endian);
        if (ifd + 2 > tiff.len) return 1;
        const count = std.mem.readInt(u16, tiff[ifd..][0..2], endian);
        for (0..count) |i| {
            const e = ifd + 2 + i * 12;
            if (e + 12 > tiff.len) return 1;
            if (std.mem.readInt(u16, tiff[e..][0..2], endian) != 0x0112) continue;
            const v = std.mem.readInt(u16, tiff[e + 8 ..][0..2], endian);
            return if (v >= 1 and v <= 8) @intCast(v) else 1;
        }
        return 1;
    }
    return 1;
}

/// Turns `img` upright for EXIF orientation `o`, replacing its pixels.
pub fn orient(gpa: Allocator, img: *Image, o: u8) Allocator.Error!void {
    if (o <= 1 or o > 8) return;
    const w: usize = img.width;
    const h: usize = img.height;
    const swap = o >= 5;
    const nw = if (swap) h else w;
    const nh = if (swap) w else h;
    const out = try gpa.alloc(u8, w * h * 4);
    for (0..nh) |y| for (0..nw) |x| {
        // Where the upright pixel (x, y) comes from in the stored image.
        const sx, const sy = switch (o) {
            2 => .{ w - 1 - x, y },
            3 => .{ w - 1 - x, h - 1 - y },
            4 => .{ x, h - 1 - y },
            5 => .{ y, x },
            6 => .{ y, h - 1 - x },
            7 => .{ w - 1 - y, h - 1 - x },
            8 => .{ w - 1 - y, x },
            else => unreachable,
        };
        out[(y * nw + x) * 4 ..][0..4].* = img.rgba[(sy * w + sx) * 4 ..][0..4].*;
    };
    gpa.free(img.rgba);
    img.* = .{ .width = @intCast(nw), .height = @intCast(nh), .rgba = out };
}

/// Iterates over the marker segments before the first scan's data.
const Segments = struct {
    bytes: []const u8,
    pos: usize = 2,

    const Segment = struct { marker: u8, data: []const u8, end: usize };

    fn next(it: *Segments) ?Segment {
        const b = it.bytes;
        while (it.pos < b.len and b[it.pos] != 0xff) it.pos += 1;
        while (it.pos < b.len and b[it.pos] == 0xff) it.pos += 1;
        if (it.pos >= b.len) return null;
        const marker = b[it.pos];
        it.pos += 1;
        // Markers without a length.
        if (marker == 0xd8 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) return .{ .marker = marker, .data = "", .end = it.pos };
        if (marker == 0xd9) return .{ .marker = marker, .data = "", .end = it.pos };
        if (it.pos + 2 > b.len) return null;
        const len = std.mem.readInt(u16, b[it.pos..][0..2], .big);
        if (len < 2 or it.pos + len > b.len) return null;
        const data = b[it.pos + 2 .. it.pos + len];
        it.pos += len;
        return .{ .marker = marker, .data = data, .end = it.pos };
    }
};

// ---------------------------------------------------------------------------
// Decoding

const Huffman = struct {
    /// For each code length 1..16: the largest code of that length plus
    /// one (0 when there is none), the first code, and where its values
    /// start in `values`.
    maxcode: [17]i32 = @splat(0),
    mincode: [17]i32 = @splat(0),
    valptr: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),
    /// Codes of up to `fast_bits` bits: (length << 8) | value, or 0.
    fast: [1 << fast_bits]u16 = @splat(0),

    const fast_bits = 9;

    fn init(counts: *const [16]u8, values: []const u8) error{Corrupt}!Huffman {
        var t: Huffman = .{};
        var total: usize = 0;
        for (counts) |c| total += c;
        if (total > 256 or total > values.len) return error.Corrupt;
        @memcpy(t.values[0..total], values[0..total]);
        var code: i32 = 0;
        var k: i32 = 0;
        for (1..17) |len| {
            const n: i32 = counts[len - 1];
            t.valptr[len] = k;
            t.mincode[len] = code;
            if (n > 0) {
                if (len <= fast_bits) {
                    for (0..@intCast(n)) |j| {
                        const c: usize = @intCast(code + @as(i32, @intCast(j)));
                        const shift: u5 = @intCast(fast_bits - len);
                        const first = c << shift;
                        for (first..first + (@as(usize, 1) << shift)) |idx| {
                            t.fast[idx] = @intCast((len << 8) | t.values[@intCast(k + @as(i32, @intCast(j)))]);
                        }
                    }
                }
                code += n;
                k += n;
            }
            t.maxcode[len] = if (n > 0) code else 0;
            if (code > (@as(i32, 1) << @intCast(len))) return error.Corrupt;
            code <<= 1;
        }
        return t;
    }
};

/// Reads entropy-coded bits, removing stuffed zero bytes. At a marker it
/// supplies zero bits and stays put, so the caller can find the marker.
const Bits = struct {
    data: []const u8,
    pos: usize,
    acc: u32 = 0,
    n: u6 = 0,
    at_marker: bool = false,

    fn fill(br: *Bits) void {
        while (br.n <= 24) {
            var byte: u8 = 0;
            if (!br.at_marker and br.pos < br.data.len) {
                byte = br.data[br.pos];
                if (byte == 0xff) {
                    const next: u8 = if (br.pos + 1 < br.data.len) br.data[br.pos + 1] else 0xd9;
                    if (next == 0) {
                        br.pos += 2;
                    } else {
                        br.at_marker = true;
                        byte = 0;
                    }
                } else br.pos += 1;
            }
            br.acc |= @as(u32, byte) << @intCast(24 - @as(u32, br.n));
            br.n += 8;
        }
    }

    fn bits(br: *Bits, k: u5) u32 {
        if (k == 0) return 0;
        br.fill();
        const v = br.acc >> @intCast(32 - @as(u32, k));
        br.acc <<= k;
        br.n -= k;
        return v;
    }

    fn bit(br: *Bits) bool {
        return br.bits(1) == 1;
    }

    fn decode(br: *Bits, t: *const Huffman) error{Corrupt}!u8 {
        br.fill();
        const f = t.fast[br.acc >> (32 - Huffman.fast_bits)];
        if (f != 0) {
            const len: u5 = @intCast(f >> 8);
            br.acc <<= len;
            br.n -= len;
            return @truncate(f);
        }
        var code: i32 = 0;
        for (1..17) |len| {
            code = (code << 1) | @as(i32, @intCast(br.bits(1)));
            if (code < t.maxcode[len] and code >= t.mincode[len] and t.maxcode[len] != 0) {
                return t.values[@intCast(t.valptr[len] + code - t.mincode[len])];
            }
        }
        return error.Corrupt;
    }

    /// A coefficient of `s` bits, sign-extended as JPEG defines it.
    fn receive(br: *Bits, s: u8) error{Corrupt}!i32 {
        if (s == 0) return 0;
        if (s > 16) return error.Corrupt;
        const v: i32 = @intCast(br.bits(@intCast(s)));
        return if (v < (@as(i32, 1) << @intCast(s - 1))) v - (@as(i32, 1) << @intCast(s)) + 1 else v;
    }

    /// Skips a restart marker and starts afresh after it.
    fn restart(br: *Bits) void {
        br.acc = 0;
        br.n = 0;
        br.at_marker = false;
        while (br.pos + 1 < br.data.len) {
            if (br.data[br.pos] == 0xff and br.data[br.pos + 1] >= 0xd0 and br.data[br.pos + 1] <= 0xd7) {
                br.pos += 2;
                return;
            }
            if (br.data[br.pos] == 0xff and br.data[br.pos + 1] != 0 and br.data[br.pos + 1] != 0xff) return;
            br.pos += 1;
        }
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// Blocks per row and rows of blocks, padded to whole MCUs.
    bw: usize,
    bh: usize,
    /// Blocks that hold image data, as a non-interleaved scan visits them.
    bw_data: usize,
    bh_data: usize,
    coefs: []i16,
    td: u8 = 0,
    ta: u8 = 0,
    dc_pred: i32 = 0,
};

const Decoder = struct {
    gpa: Allocator,
    qt: [4][64]u16 = @splat(@splat(1)),
    dc: [4]?Huffman = @splat(null),
    ac: [4]?Huffman = @splat(null),
    comps: []Component = &.{},
    width: usize = 0,
    height: usize = 0,
    hmax: u8 = 1,
    vmax: u8 = 1,
    mcux: usize = 0,
    mcuy: usize = 0,
    progressive: bool = false,
    restart_interval: usize = 0,
    eobrun: u32 = 0,
    adobe_transform: ?u8 = null,

    fn frame(d: *Decoder, data: []const u8) DecodeError!void {
        if (d.comps.len != 0) return error.Corrupt;
        if (data.len < 6) return error.Corrupt;
        if (data[0] != 8) return error.Unsupported;
        d.height = std.mem.readInt(u16, data[1..3], .big);
        d.width = std.mem.readInt(u16, data[3..5], .big);
        const n = data[5];
        if (d.width == 0 or d.height == 0) return error.Unsupported;
        if (n != 1 and n != 3) return error.Unsupported;
        if (data.len < 6 + @as(usize, n) * 3) return error.Corrupt;
        d.comps = try d.gpa.alloc(Component, n);
        @memset(d.comps, .{ .id = 0, .h = 1, .v = 1, .tq = 0, .bw = 0, .bh = 0, .bw_data = 0, .bh_data = 0, .coefs = &.{} });
        for (d.comps, 0..) |*c, i| {
            const s = data[6 + i * 3 ..][0..3];
            c.id = s[0];
            c.h = s[1] >> 4;
            c.v = s[1] & 15;
            c.tq = s[2];
            if (c.h < 1 or c.h > 4 or c.v < 1 or c.v > 4 or c.tq > 3) return error.Corrupt;
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }
        // A single-component image has one block per MCU whatever it says.
        if (n == 1) {
            d.comps[0].h = 1;
            d.comps[0].v = 1;
            d.hmax = 1;
            d.vmax = 1;
        }
        d.mcux = (d.width + 8 * @as(usize, d.hmax) - 1) / (8 * @as(usize, d.hmax));
        d.mcuy = (d.height + 8 * @as(usize, d.vmax) - 1) / (8 * @as(usize, d.vmax));
        for (d.comps) |*c| {
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.bw_data = ((d.width * c.h + d.hmax - 1) / d.hmax + 7) / 8;
            c.bh_data = ((d.height * c.v + d.vmax - 1) / d.vmax + 7) / 8;
            c.coefs = try d.gpa.alloc(i16, c.bw * c.bh * 64);
            @memset(c.coefs, 0);
        }
    }

    fn quantTables(d: *Decoder, data: []const u8) DecodeError!void {
        var p: usize = 0;
        while (p < data.len) {
            const precision = data[p] >> 4;
            const id = data[p] & 15;
            if (id > 3 or precision > 1) return error.Corrupt;
            p += 1;
            const len: usize = if (precision == 1) 128 else 64;
            if (p + len > data.len) return error.Corrupt;
            for (0..64) |k| {
                d.qt[id][zigzag[k]] = if (precision == 1) std.mem.readInt(u16, data[p + k * 2 ..][0..2], .big) else data[p + k];
            }
            p += len;
        }
    }

    fn huffmanTables(d: *Decoder, data: []const u8) DecodeError!void {
        var p: usize = 0;
        while (p < data.len) {
            if (p + 17 > data.len) return error.Corrupt;
            const class = data[p] >> 4;
            const id = data[p] & 15;
            if (class > 1 or id > 3) return error.Corrupt;
            const counts = data[p + 1 ..][0..16];
            var total: usize = 0;
            for (counts) |c| total += c;
            if (p + 17 + total > data.len) return error.Corrupt;
            const t = try Huffman.init(counts, data[p + 17 ..][0..total]);
            if (class == 0) d.dc[id] = t else d.ac[id] = t;
            p += 17 + total;
        }
    }

    /// Decodes one scan starting at its SOS segment. Returns the position
    /// just after the scan's entropy-coded data.
    fn scan(d: *Decoder, header: []const u8, bytes: []const u8, start: usize) DecodeError!usize {
        if (d.comps.len == 0 or header.len < 1) return error.Corrupt;
        const ns = header[0];
        if (ns < 1 or ns > 4 or header.len < 1 + @as(usize, ns) * 2 + 3) return error.Corrupt;
        var in_scan: [4]*Component = undefined;
        for (0..ns) |i| {
            const id = header[1 + i * 2];
            const tables = header[2 + i * 2];
            const c = for (d.comps) |*c| {
                if (c.id == id) break c;
            } else return error.Corrupt;
            c.td = tables >> 4;
            c.ta = tables & 15;
            if (c.td > 3 or c.ta > 3) return error.Corrupt;
            in_scan[i] = c;
        }
        const tail = header[1 + @as(usize, ns) * 2 ..];
        const ss = tail[0];
        const se = tail[1];
        const ah = tail[2] >> 4;
        const al = tail[2] & 15;
        if (d.progressive) {
            if (ss > se or se > 63 or (ss == 0 and se != 0) or (ss > 0 and ns != 1) or al > 13) return error.Corrupt;
        } else if (ss != 0 or se != 63 or ah != 0 or al != 0) return error.Corrupt;

        const s: Scan = .{ .ss = ss, .se = se, .ah = ah, .al = @intCast(al) };
        var br: Bits = .{ .data = bytes, .pos = start };
        for (d.comps) |*c| c.dc_pred = 0;
        d.eobrun = 0;

        var units: usize = 0;
        if (ns == 1) {
            const c = in_scan[0];
            for (0..c.bh_data) |by| for (0..c.bw_data) |bx| {
                try d.restartIfDue(&br, &units);
                try d.block(&br, c, c.coefs[(by * c.bw + bx) * 64 ..][0..64], s);
            };
        } else {
            for (0..d.mcuy) |my| for (0..d.mcux) |mx| {
                try d.restartIfDue(&br, &units);
                for (in_scan[0..ns]) |c| {
                    for (0..c.v) |v| for (0..c.h) |h| {
                        const by = my * c.v + v;
                        const bx = mx * c.h + h;
                        try d.block(&br, c, c.coefs[(by * c.bw + bx) * 64 ..][0..64], s);
                    };
                }
            };
        }
        // The data ends at the first marker that is not a restart marker.
        var p = br.pos;
        while (p + 1 < bytes.len) : (p += 1) {
            if (bytes[p] == 0xff and bytes[p + 1] != 0 and !(bytes[p + 1] >= 0xd0 and bytes[p + 1] <= 0xd7)) break;
        }
        return p;
    }

    fn restartIfDue(d: *Decoder, br: *Bits, units: *usize) error{}!void {
        if (d.restart_interval > 0 and units.* > 0 and units.* % d.restart_interval == 0) {
            br.restart();
            for (d.comps) |*c| c.dc_pred = 0;
            d.eobrun = 0;
        }
        units.* += 1;
    }

    const Scan = struct { ss: u8, se: u8, ah: u8, al: u4 };

    fn block(d: *Decoder, br: *Bits, c: *Component, coef: *[64]i16, s: Scan) DecodeError!void {
        if (!d.progressive) {
            const dc = &(d.dc[c.td] orelse return error.Corrupt);
            const ac = &(d.ac[c.ta] orelse return error.Corrupt);
            c.dc_pred += try br.receive(try br.decode(dc));
            coef[0] = @truncate(c.dc_pred);
            var k: usize = 1;
            while (k < 64) {
                const rs = try br.decode(ac);
                const r = rs >> 4;
                const size_bits = rs & 15;
                if (size_bits == 0) {
                    if (r != 15) break;
                    k += 16;
                    continue;
                }
                k += r;
                if (k > 63) return error.Corrupt;
                coef[zigzag[k]] = @truncate(try br.receive(size_bits));
                k += 1;
            }
            return;
        }

        if (s.ss == 0) {
            // DC scans.
            if (s.ah == 0) {
                const dc = &(d.dc[c.td] orelse return error.Corrupt);
                c.dc_pred += try br.receive(try br.decode(dc));
                coef[0] = @truncate(c.dc_pred * (@as(i32, 1) << s.al));
            } else if (br.bit()) {
                coef[0] |= @as(i16, 1) << s.al;
            }
            return;
        }

        const ac = &(d.ac[c.ta] orelse return error.Corrupt);
        if (s.ah == 0) {
            // First AC scan for this band.
            if (d.eobrun > 0) {
                d.eobrun -= 1;
                return;
            }
            var k: usize = s.ss;
            while (k <= s.se) {
                const rs = try br.decode(ac);
                const r = rs >> 4;
                const size_bits = rs & 15;
                if (size_bits == 0) {
                    if (r < 15) {
                        d.eobrun = (@as(u32, 1) << @intCast(r)) - 1;
                        if (r > 0) d.eobrun += br.bits(@intCast(r));
                        break;
                    }
                    k += 16;
                    continue;
                }
                k += r;
                if (k > 63) return error.Corrupt;
                coef[zigzag[k]] = @truncate(try br.receive(size_bits) * (@as(i32, 1) << s.al));
                k += 1;
            }
            return;
        }

        // AC refinement: one more bit for coefficients already nonzero, and
        // new coefficients of magnitude 1.
        const p1: i16 = @as(i16, 1) << s.al;
        const m1: i16 = -p1;
        var k: usize = s.ss;
        if (d.eobrun == 0) {
            while (k <= s.se) {
                const rs = try br.decode(ac);
                var r: u8 = rs >> 4;
                const size_bits = rs & 15;
                var val: i16 = 0;
                if (size_bits == 0) {
                    if (r < 15) {
                        d.eobrun = @as(u32, 1) << @intCast(r);
                        if (r > 0) d.eobrun += br.bits(@intCast(r));
                        break;
                    }
                } else {
                    if (size_bits != 1) return error.Corrupt;
                    val = if (br.bit()) p1 else m1;
                }
                while (k <= s.se) {
                    const z = &coef[zigzag[k]];
                    if (z.* != 0) {
                        if (br.bit() and (z.* & p1) == 0) z.* += if (z.* >= 0) p1 else m1;
                    } else {
                        if (r == 0) {
                            if (val != 0) z.* = val;
                            k += 1;
                            break;
                        }
                        r -= 1;
                    }
                    k += 1;
                }
            }
        }
        if (d.eobrun > 0) {
            while (k <= s.se) : (k += 1) {
                const z = &coef[zigzag[k]];
                if (z.* != 0 and br.bit() and (z.* & p1) == 0) z.* += if (z.* >= 0) p1 else m1;
            }
            d.eobrun -= 1;
        }
    }

    /// Turns the coefficients into RGBA pixels.
    fn finish(d: *Decoder) Allocator.Error!Image {
        const planes = try d.gpa.alloc([]u8, d.comps.len);
        defer d.gpa.free(planes);
        var made: usize = 0;
        defer for (planes[0..made]) |pl| d.gpa.free(pl);
        for (d.comps, planes) |c, *pl| {
            const pw = c.bw * 8;
            pl.* = try d.gpa.alloc(u8, pw * c.bh * 8);
            made += 1;
            const q = &d.qt[c.tq];
            for (0..c.bh) |by| for (0..c.bw) |bx| {
                var out: [64]u8 = undefined;
                idct(c.coefs[(by * c.bw + bx) * 64 ..][0..64], q, &out);
                for (0..8) |y| @memcpy(pl.*[(by * 8 + y) * pw + bx * 8 ..][0..8], out[y * 8 ..][0..8]);
            };
        }

        const rgba = try d.gpa.alloc(u8, d.width * d.height * 4);
        // Adobe's marker says whether the components are RGB; without it,
        // components named R, G and B are, and anything else is YCbCr.
        const rgb_stored = d.comps.len == 3 and if (d.adobe_transform) |t| t == 0 else
            (d.comps[0].id == 'R' and d.comps[1].id == 'G' and d.comps[2].id == 'B');
        for (0..d.height) |y| for (0..d.width) |x| {
            var v: [3]f32 = undefined;
            for (d.comps, planes, 0..) |c, pl, i| {
                const sx = x * c.h / d.hmax;
                const sy = y * c.v / d.vmax;
                v[i] = @floatFromInt(pl[sy * c.bw * 8 + sx]);
            }
            const px = rgba[(y * d.width + x) * 4 ..][0..4];
            if (d.comps.len == 1) {
                const g: u8 = @intFromFloat(v[0]);
                px.* = .{ g, g, g, 255 };
            } else if (rgb_stored) {
                px.* = .{ @intFromFloat(v[0]), @intFromFloat(v[1]), @intFromFloat(v[2]), 255 };
            } else {
                const yy = v[0];
                const cb = v[1] - 128;
                const cr = v[2] - 128;
                px.* = .{ clamp8(yy + 1.402 * cr), clamp8(yy - 0.344136 * cb - 0.714136 * cr), clamp8(yy + 1.772 * cb), 255 };
            }
        };
        return .{ .width = @intCast(d.width), .height = @intCast(d.height), .rgba = rgba };
    }

    fn deinit(d: *Decoder) void {
        for (d.comps) |c| d.gpa.free(c.coefs);
        d.gpa.free(d.comps);
    }
};

fn clamp8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v), 0, 255));
}

/// cos_table[x][u] = C(u) / 2 * cos((2x + 1) u pi / 16).
const cos_table: [8][8]f32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [8][8]f32 = undefined;
    for (0..8) |x| for (0..8) |u| {
        const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        t[x][u] = @floatCast(cu / 2.0 * @cos(@as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0));
    };
    break :blk t;
};

fn idct(coef: *const [64]i16, q: *const [64]u16, out: *[64]u8) void {
    var f: [64]f32 = undefined;
    for (&f, coef, q) |*o, c, qq| o.* = @as(f32, @floatFromInt(c)) * @as(f32, @floatFromInt(qq));
    // Rows, then columns.
    var tmp: [64]f32 = undefined;
    for (0..8) |v| for (0..8) |x| {
        var sum: f32 = 0;
        for (0..8) |u| sum += cos_table[x][u] * f[v * 8 + u];
        tmp[v * 8 + x] = sum;
    };
    for (0..8) |x| for (0..8) |y| {
        var sum: f32 = 0;
        for (0..8) |v| sum += cos_table[y][v] * tmp[v * 8 + x];
        out[y * 8 + x] = clamp8(sum + 128);
    };
}

/// Decodes a JPEG into RGBA as stored, without applying EXIF orientation.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Image {
    if (!std.mem.startsWith(u8, bytes, "\xff\xd8")) return error.NotJpeg;
    var d: Decoder = .{ .gpa = gpa };
    defer d.deinit();
    var it: Segments = .{ .bytes = bytes };
    var saw_scan = false;
    while (it.next()) |seg| {
        switch (seg.marker) {
            0xd8, 0x01, 0xd0...0xd7 => {},
            0xd9 => break,
            0xc0, 0xc1 => try d.frame(seg.data),
            0xc2 => {
                d.progressive = true;
                try d.frame(seg.data);
            },
            0xc3, 0xc5...0xc7, 0xc9...0xcb, 0xcd...0xcf => return error.Unsupported,
            0xc4 => try d.huffmanTables(seg.data),
            0xdb => try d.quantTables(seg.data),
            0xdd => {
                if (seg.data.len < 2) return error.Corrupt;
                d.restart_interval = std.mem.readInt(u16, seg.data[0..2], .big);
            },
            0xee => if (seg.data.len >= 12 and std.mem.startsWith(u8, seg.data, "Adobe")) {
                d.adobe_transform = seg.data[11];
            },
            0xda => {
                it.pos = try d.scan(seg.data, bytes, seg.end);
                saw_scan = true;
            },
            else => {},
        }
    }
    if (!saw_scan) return error.Corrupt;
    return d.finish();
}

// ---------------------------------------------------------------------------
// Encoding

const base_luma = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const base_chroma = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

// The example Huffman tables from Annex K of the JPEG standard.
const dc_luma_counts = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_chroma_counts = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_values = [12]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const ac_luma_counts = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_luma_values = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};
const ac_chroma_counts = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chroma_values = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

/// Code and length for each symbol of a Huffman table.
const Codes = struct {
    code: [256]u16 = @splat(0),
    len: [256]u8 = @splat(0),

    fn init(counts: *const [16]u8, values: []const u8) Codes {
        var c: Codes = .{};
        var code: u16 = 0;
        var k: usize = 0;
        for (counts, 1..) |n, len| {
            for (0..n) |_| {
                c.code[values[k]] = code;
                c.len[values[k]] = @intCast(len);
                code += 1;
                k += 1;
            }
            code <<= 1;
        }
        return c;
    }
};

comptime {
    // Every AC symbol the encoder can emit has a code: EOB, ZRL, and each
    // run of 0 to 15 zeros followed by a size of 1 to 10 bits.
    @setEvalBranchQuota(100000);
    for ([_]struct { []const u8, [16]u8 }{ .{ &ac_luma_values, ac_luma_counts }, .{ &ac_chroma_values, ac_chroma_counts } }) |t| {
        var total: usize = 0;
        for (t[1]) |n| total += n;
        if (total != t[0].len or total != 162) @compileError("bad AC table");
        var seen: [256]bool = @splat(false);
        for (t[0]) |v| {
            if (seen[v]) @compileError("duplicate AC symbol");
            seen[v] = true;
        }
        for (0..16) |r| for (1..11) |s| {
            if (!seen[r * 16 + s]) @compileError("missing AC symbol");
        };
        if (!seen[0] or !seen[0xf0]) @compileError("missing EOB or ZRL");
    }
}

const BitWriter = struct {
    out: *Writer,
    acc: u32 = 0,
    n: u5 = 0,

    fn put(bw: *BitWriter, code: u32, len: u5) Writer.Error!void {
        var l = len;
        while (l > 0) {
            l -= 1;
            bw.acc = (bw.acc << 1) | ((code >> l) & 1);
            bw.n += 1;
            if (bw.n == 8) {
                const byte: u8 = @truncate(bw.acc);
                try bw.out.writeByte(byte);
                if (byte == 0xff) try bw.out.writeByte(0);
                bw.acc = 0;
                bw.n = 0;
            }
        }
    }

    fn flush(bw: *BitWriter) Writer.Error!void {
        // Pad the last byte with one bits.
        while (bw.n != 0) try bw.put(1, 1);
    }
};

/// The number of bits needed for `v`'s magnitude, and those bits as JPEG
/// stores them (one's complement for negative values).
fn magnitude(v: i32) struct { u5, u32 } {
    const a: u32 = @abs(v);
    const bits: u5 = @intCast(32 - @clz(a));
    const stored: u32 = if (v < 0) @bitCast(v - 1) else @intCast(v);
    const mask: u32 = if (bits == 0) 0 else (@as(u32, 1) << bits) - 1;
    return .{ bits, stored & mask };
}

fn scaledTable(base: *const [64]u8, quality: u8) [64]u8 {
    const q: u32 = std.math.clamp(quality, 1, 100);
    const scale: u32 = if (q < 50) 5000 / q else 200 - q * 2;
    var t: [64]u8 = undefined;
    for (&t, base) |*o, b| o.* = @intCast(std.math.clamp((@as(u32, b) * scale + 50) / 100, 1, 255));
    return t;
}

fn fdct(px: *const [64]f32, q: *const [64]u8, out: *[64]i32) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| for (0..8) |u| {
        var sum: f32 = 0;
        for (0..8) |x| sum += cos_table[x][u] * px[y * 8 + x];
        tmp[y * 8 + u] = sum;
    };
    for (0..8) |u| for (0..8) |v| {
        var sum: f32 = 0;
        for (0..8) |y| sum += cos_table[y][v] * tmp[y * 8 + u];
        // Baseline AC coefficients must fit in 10 bits.
        out[v * 8 + u] = @intFromFloat(std.math.clamp(@round(sum / @as(f32, @floatFromInt(q[v * 8 + u]))), -1023, 1023));
    };
}

/// Writes `rgba` (alpha ignored) as a baseline JPEG.
pub fn encode(gpa: Allocator, out: *Writer, width: u32, height: u32, rgba: []const u8, quality: u8) (Allocator.Error || Writer.Error)!void {
    std.debug.assert(width > 0 and height > 0 and width <= 65535 and height <= 65535);
    const w: usize = width;
    const h: usize = height;
    const ql = scaledTable(&base_luma, quality);
    const qc = scaledTable(&base_chroma, quality);

    try out.writeAll("\xff\xd8");
    try out.writeAll("\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00");
    for ([_]struct { u8, *const [64]u8 }{ .{ 0, &ql }, .{ 1, &qc } }) |t| {
        try out.writeAll("\xff\xdb\x00\x43");
        try out.writeByte(t[0]);
        for (zigzag) |z| try out.writeByte(t[1][z]);
    }
    // SOF0: 8-bit, three components, Y at 2x2 and Cb, Cr at 1x1.
    try out.writeAll("\xff\xc0\x00\x11\x08");
    try out.writeInt(u16, @intCast(h), .big);
    try out.writeInt(u16, @intCast(w), .big);
    try out.writeAll("\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01");
    for ([_]struct { u8, []const u8, []const u8 }{
        .{ 0x00, &dc_luma_counts, &dc_values },
        .{ 0x10, &ac_luma_counts, &ac_luma_values },
        .{ 0x01, &dc_chroma_counts, &dc_values },
        .{ 0x11, &ac_chroma_counts, &ac_chroma_values },
    }) |t| {
        try out.writeAll("\xff\xc4");
        try out.writeInt(u16, @intCast(2 + 1 + 16 + t[2].len), .big);
        try out.writeByte(t[0]);
        try out.writeAll(t[1]);
        try out.writeAll(t[2]);
    }
    try out.writeAll("\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00");

    // Color planes, with edges repeated out to whole MCUs.
    const mw = (w + 15) / 16 * 16;
    const mh = (h + 15) / 16 * 16;
    const ys = try gpa.alloc(f32, mw * mh);
    defer gpa.free(ys);
    const cbs = try gpa.alloc(f32, mw * mh / 4);
    defer gpa.free(cbs);
    const crs = try gpa.alloc(f32, mw * mh / 4);
    defer gpa.free(crs);
    @memset(cbs, 0);
    @memset(crs, 0);
    for (0..mh) |y| for (0..mw) |x| {
        const p = rgba[(@min(y, h - 1) * w + @min(x, w - 1)) * 4 ..][0..3];
        const r: f32 = @floatFromInt(p[0]);
        const g: f32 = @floatFromInt(p[1]);
        const b: f32 = @floatFromInt(p[2]);
        ys[y * mw + x] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
        const ci = (y / 2) * (mw / 2) + x / 2;
        cbs[ci] += (-0.168736 * r - 0.331264 * g + 0.5 * b) / 4;
        crs[ci] += (0.5 * r - 0.418688 * g - 0.081312 * b) / 4;
    };

    const dc_l = Codes.init(&dc_luma_counts, &dc_values);
    const ac_l = Codes.init(&ac_luma_counts, &ac_luma_values);
    const dc_c = Codes.init(&dc_chroma_counts, &dc_values);
    const ac_c = Codes.init(&ac_chroma_counts, &ac_chroma_values);
    var bw: BitWriter = .{ .out = out };
    var preds: [3]i32 = @splat(0);
    var y0: usize = 0;
    while (y0 < mh) : (y0 += 16) {
        var x0: usize = 0;
        while (x0 < mw) : (x0 += 16) {
            for (0..4) |i| {
                const bx = x0 + (i % 2) * 8;
                const by = y0 + (i / 2) * 8;
                var blk: [64]f32 = undefined;
                for (0..8) |yy| @memcpy(blk[yy * 8 ..][0..8], ys[(by + yy) * mw + bx ..][0..8]);
                try encodeBlock(&bw, &blk, &ql, &preds[0], &dc_l, &ac_l);
            }
            const cw = mw / 2;
            for ([_][]const f32{ cbs, crs }, 1..) |plane, ci| {
                var blk: [64]f32 = undefined;
                for (0..8) |yy| @memcpy(blk[yy * 8 ..][0..8], plane[(y0 / 2 + yy) * cw + x0 / 2 ..][0..8]);
                try encodeBlock(&bw, &blk, &qc, &preds[ci], &dc_c, &ac_c);
            }
        }
    }
    try bw.flush();
    try out.writeAll("\xff\xd9");
}

fn encodeBlock(bw: *BitWriter, blk: *const [64]f32, q: *const [64]u8, pred: *i32, dc: *const Codes, ac: *const Codes) Writer.Error!void {
    var coef: [64]i32 = undefined;
    fdct(blk, q, &coef);
    const diff = coef[0] - pred.*;
    pred.* = coef[0];
    const dbits, const dval = magnitude(diff);
    try bw.put(dc.code[dbits], @intCast(dc.len[dbits]));
    try bw.put(dval, dbits);
    var run: u8 = 0;
    for (1..64) |k| {
        const v = coef[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) {
            try bw.put(ac.code[0xf0], @intCast(ac.len[0xf0]));
            run -= 16;
        }
        const bits, const val = magnitude(v);
        const sym = run * 16 + @as(u8, bits);
        try bw.put(ac.code[sym], @intCast(ac.len[sym]));
        try bw.put(val, bits);
        run = 0;
    }
    if (run > 0) try bw.put(ac.code[0], @intCast(ac.len[0]));
}

/// A JPEG file in memory. The caller owns the result.
pub fn encodeAlloc(gpa: Allocator, width: u32, height: u32, rgba: []const u8, quality: u8) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    encode(gpa, &aw.writer, width, height, rgba, quality) catch |e| switch (e) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

const testing = std.testing;

test "encode then decode stays close to the original" {
    const gpa = testing.allocator;
    const w = 45;
    const h = 30;
    var rgba: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        rgba[i..][0..4].* = .{ @intCast(x * 5), @intCast(y * 8), @intCast(128 + (x + y) % 64), 255 };
    };
    const file = try encodeAlloc(gpa, w, h, &rgba, 90);
    defer gpa.free(file);
    try testing.expectEqual(@as(?[2]u32, .{ w, h }), size(file));
    var img = try decode(gpa, file);
    defer img.deinit(gpa);
    try testing.expectEqual(@as(u32, w), img.width);
    var err_sum: u64 = 0;
    for (img.rgba, rgba) |a, b| err_sum += @abs(@as(i32, a) - b);
    // Smooth gradients survive quality 90 with a small average error.
    try testing.expect(err_sum / (w * h * 3) < 4);
}

test "orientation reads EXIF and orient turns the image" {
    const gpa = testing.allocator;
    // SOI, then an APP1 Exif segment with one IFD entry: orientation 6.
    const exif = "\xff\xd8\xff\xe1\x00\x22Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00\x00\x00\x00\x00";
    try testing.expectEqual(@as(u8, 6), orientation(exif));
    try testing.expectEqual(@as(u8, 1), orientation("\xff\xd8\xff\xd9"));

    // 2x1: red, blue. Orientation 6 (turn clockwise) gives 1x2: red over blue.
    var img: Image = .{ .width = 2, .height = 1, .rgba = try gpa.dupe(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }) };
    defer img.deinit(gpa);
    try orient(gpa, &img, 6);
    try testing.expectEqual(@as(u32, 1), img.width);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 0, 255, 255 }, img.rgba);
}

test "corrupt and unsupported input is rejected" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotJpeg, decode(gpa, "GIF89a"));
    try testing.expectError(error.Corrupt, decode(gpa, "\xff\xd8\xff\xd9"));
    // SOF3 (lossless).
    try testing.expectError(error.Unsupported, decode(gpa, "\xff\xd8\xff\xc3\x00\x0b\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xd9"));
}
