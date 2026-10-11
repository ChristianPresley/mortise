//! PNG encoding (8-bit RGBA) and decoding (every standard format). Compression is the
//! standard library's deflate; everything else (chunks, CRCs, row filters)
//! is here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const flate = std.compress.flate;

const signature = "\x89PNG\r\n\x1a\n";

pub const EncodeOptions = struct {
    /// Deflate effort. `.default` is a good trade; `.best` shaves a few
    /// percent off large images for several times the time.
    level: flate.Compress.Options = .default,
};

/// Writes `rgba` (width * height * 4 bytes, 8-bit sRGB, straight alpha,
/// top row first) as a PNG file.
pub fn encode(
    gpa: Allocator,
    out: *Writer,
    width: u32,
    height: u32,
    rgba: []const u8,
    options: EncodeOptions,
) (Allocator.Error || Writer.Error)!void {
    std.debug.assert(width > 0 and height > 0);
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);

    try out.writeAll(signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // not interlaced
    try writeChunk(out, "IHDR", &ihdr);

    const filtered = try filterRows(gpa, width, height, rgba);
    defer gpa.free(filtered);

    // The compressor needs room in its output buffer from the start.
    var compressed: Writer.Allocating = try .initCapacity(gpa, @max(64, filtered.len / 4));
    defer compressed.deinit();
    {
        // The compressor carries a few hundred KiB of tables, too much for
        // the stack.
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        const z = try gpa.create(flate.Compress);
        defer gpa.destroy(z);
        z.* = flate.Compress.init(&compressed.writer, window, .zlib, options.level) catch return error.OutOfMemory;
        z.writer.writeAll(filtered) catch return error.OutOfMemory;
        z.finish() catch return error.OutOfMemory;
    }

    // Split IDAT so no single chunk grows unreasonably large.
    var rest = compressed.written();
    while (rest.len > 0) {
        const n = @min(rest.len, 1 << 20);
        try writeChunk(out, "IDAT", rest[0..n]);
        rest = rest[n..];
    }
    try writeChunk(out, "IEND", "");
}

/// A PNG file in memory. The caller owns the result.
pub fn encodeAlloc(gpa: Allocator, width: u32, height: u32, rgba: []const u8, options: EncodeOptions) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    encode(gpa, &aw.writer, width, height, rgba, options) catch |e| switch (e) {
        error.WriteFailed, error.OutOfMemory => return error.OutOfMemory,
    };
    return aw.toOwnedSlice();
}

fn writeChunk(out: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try out.writeInt(u32, @intCast(data.len), .big);
    try out.writeAll(kind);
    try out.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try out.writeInt(u32, crc.final(), .big);
}

const Filter = enum(u8) { none, sub, up, average, paeth };

/// Prefixes each row with the filter that minimizes the sum of absolute
/// differences, the heuristic the PNG specification recommends.
fn filterRows(gpa: Allocator, width: u32, height: u32, rgba: []const u8) Allocator.Error![]u8 {
    const stride = @as(usize, width) * 4;
    const out = try gpa.alloc(u8, (stride + 1) * height);
    const candidate = try gpa.alloc(u8, stride);
    defer gpa.free(candidate);
    const zero_row = try gpa.alloc(u8, stride);
    defer gpa.free(zero_row);
    @memset(zero_row, 0);

    for (0..height) |y| {
        const row = rgba[y * stride ..][0..stride];
        const prev = if (y == 0) zero_row else rgba[(y - 1) * stride ..][0..stride];
        const dst = out[y * (stride + 1) ..][0 .. stride + 1];
        var best_score: u64 = std.math.maxInt(u64);
        inline for (comptime std.enums.values(Filter)) |f| {
            var score: u64 = 0;
            for (0..stride) |i| {
                const a: u8 = if (i >= 4) row[i - 4] else 0;
                const b = prev[i];
                const c: u8 = if (i >= 4) prev[i - 4] else 0;
                const v = row[i] -% predict(f, a, b, c);
                candidate[i] = v;
                // Treat bytes as signed so small negative residues score low.
                score += @abs(@as(i8, @bitCast(v)));
            }
            if (score < best_score) {
                best_score = score;
                dst[0] = @intFromEnum(f);
                @memcpy(dst[1..], candidate);
            }
        }
    }
    return out;
}

fn predict(f: Filter, a: u8, b: u8, c: u8) u8 {
    return switch (f) {
        .none => 0,
        .sub => a,
        .up => b,
        .average => @intCast((@as(u16, a) + b) / 2),
        .paeth => paeth(a, b, c),
    };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub const Image = struct {
    width: u32,
    height: u32,
    /// 8-bit RGBA, straight alpha, top row first.
    rgba: []u8,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.rgba);
        img.* = undefined;
    }
};

pub const DecodeError = Allocator.Error || error{
    NotPng,
    Corrupt,
    /// A valid PNG using a feature outside the specification's core, such
    /// as an unknown color type.
    Unsupported,
};

/// The image layout from a PNG's IHDR chunk.
const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlaced: bool,

    fn channels(h: Header) u8 {
        return switch (h.color) {
            0 => 1,
            2 => 3,
            3 => 1,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }

    /// Bytes per complete pixel, at least 1: the distance filters look back.
    fn filterStep(h: Header) usize {
        return @max(1, @as(usize, h.channels()) * h.depth / 8);
    }

    fn rowBytes(h: Header, width: usize) usize {
        return (width * h.channels() * h.depth + 7) / 8;
    }
};

/// Decodes any standard PNG into 8-bit RGBA: gray, RGB, palette, gray with
/// alpha and RGBA, at every bit depth (16-bit channels keep their high
/// byte), with `tRNS` transparency and Adam7 interlacing. Gamma and color
/// profile chunks are ignored.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
    var pos: usize = signature.len;
    var header: ?Header = null;
    var palette: []const u8 = "";
    var trns: []const u8 = "";
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    while (true) {
        if (bytes.len - pos < 12) return error.Corrupt;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        if (bytes.len - pos - 12 < len) return error.Corrupt;
        const kind = bytes[pos + 4 ..][0..4];
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        var h: std.hash.Crc32 = .init();
        h.update(kind);
        h.update(data);
        if (h.final() != crc) return error.Corrupt;
        pos += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.Corrupt;
            const hd: Header = .{
                .width = std.mem.readInt(u32, data[0..4], .big),
                .height = std.mem.readInt(u32, data[4..8], .big),
                .depth = data[8],
                .color = data[9],
                .interlaced = data[12] == 1,
            };
            if (hd.width == 0 or hd.height == 0) return error.Corrupt;
            if (data[10] != 0 or data[11] != 0 or data[12] > 1) return error.Unsupported;
            const depth_ok = switch (hd.color) {
                0 => hd.depth == 1 or hd.depth == 2 or hd.depth == 4 or hd.depth == 8 or hd.depth == 16,
                3 => hd.depth == 1 or hd.depth == 2 or hd.depth == 4 or hd.depth == 8,
                2, 4, 6 => hd.depth == 8 or hd.depth == 16,
                else => return error.Unsupported,
            };
            if (!depth_ok) return error.Corrupt;
            // Refuse sizes whose pixels would not fit in memory anyway.
            if (@as(u64, hd.width) * hd.height > 1 << 28) return error.Unsupported;
            header = hd;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len == 0) return error.Corrupt;
            palette = data;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    const hd = header orelse return error.Corrupt;
    if (hd.color == 3 and palette.len == 0) return error.Corrupt;

    // The decompressed size is known from the header.
    var expected: usize = 0;
    for (passes(hd)) |p| {
        if (p.w > 0 and p.h > 0) expected += (hd.rowBytes(p.w) + 1) * p.h;
    }
    var in: std.Io.Reader = .fixed(idat.items);
    var z: flate.Decompress = .init(&in, .zlib, &.{});
    const raw = z.reader.allocRemaining(gpa, .limited(expected + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    defer gpa.free(raw);
    if (raw.len != expected) return error.Corrupt;

    const rgba = try gpa.alloc(u8, @as(usize, hd.width) * hd.height * 4);
    errdefer gpa.free(rgba);
    const step = hd.filterStep();
    var offset: usize = 0;
    var prev_buf: std.ArrayList(u8) = .empty;
    defer prev_buf.deinit(gpa);
    for (passes(hd)) |p| {
        if (p.w == 0 or p.h == 0) continue;
        const stride = hd.rowBytes(p.w);
        try prev_buf.resize(gpa, stride * 2);
        const prev = prev_buf.items[0..stride];
        const row = prev_buf.items[stride..][0..stride];
        @memset(prev, 0);
        for (0..p.h) |py| {
            const f = std.enums.fromInt(Filter, raw[offset]) orelse return error.Corrupt;
            const src = raw[offset + 1 ..][0..stride];
            offset += stride + 1;
            for (0..stride) |i| {
                const a: u8 = if (i >= step) row[i - step] else 0;
                const c: u8 = if (i >= step) prev[i - step] else 0;
                row[i] = src[i] +% predict(f, a, prev[i], c);
            }
            for (0..p.w) |px| {
                const x = p.x0 + px * p.dx;
                const y = p.y0 + py * p.dy;
                rgba[(y * hd.width + x) * 4 ..][0..4].* = try pixel(hd, row, px, palette, trns);
            }
            @memcpy(prev, row);
        }
    }
    return .{ .width = hd.width, .height = hd.height, .rgba = rgba };
}

const Pass = struct { x0: usize, y0: usize, dx: usize, dy: usize, w: usize, h: usize };

/// The seven Adam7 passes, or one pass covering the image followed by
/// empty ones.
fn passes(hd: Header) [7]Pass {
    const W: usize = hd.width;
    const H: usize = hd.height;
    var out: [7]Pass = @splat(.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .w = 0, .h = 0 });
    if (!hd.interlaced) {
        out[0] = .{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .w = W, .h = H };
        return out;
    }
    const adam7 = [7][4]usize{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    for (adam7, &out) |a, *p| {
        p.* = .{
            .x0 = a[0],
            .y0 = a[1],
            .dx = a[2],
            .dy = a[3],
            .w = if (W > a[0]) (W - a[0] + a[2] - 1) / a[2] else 0,
            .h = if (H > a[1]) (H - a[1] + a[3] - 1) / a[3] else 0,
        };
    }
    return out;
}

/// Sample `i` of a row at the header's bit depth, as stored.
fn sample(hd: Header, row: []const u8, i: usize) u16 {
    return switch (hd.depth) {
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        8 => row[i],
        else => blk: {
            const bit = i * hd.depth;
            const shift: u3 = @intCast(8 - hd.depth - bit % 8);
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(hd.depth)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

/// A stored sample scaled to 8 bits.
fn to8(hd: Header, v: u16) u8 {
    return switch (hd.depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(hd.depth)) - 1)),
    };
}

fn pixel(hd: Header, row: []const u8, x: usize, palette: []const u8, trns: []const u8) DecodeError![4]u8 {
    const n = hd.channels();
    switch (hd.color) {
        0 => {
            const g = sample(hd, row, x);
            const clear = trns.len >= 2 and std.mem.readInt(u16, trns[0..2], .big) == g;
            const v = to8(hd, g);
            return .{ v, v, v, if (clear) 0 else 255 };
        },
        2 => {
            const r = sample(hd, row, x * n);
            const g = sample(hd, row, x * n + 1);
            const b = sample(hd, row, x * n + 2);
            const clear = trns.len >= 6 and std.mem.readInt(u16, trns[0..2], .big) == r and
                std.mem.readInt(u16, trns[2..4], .big) == g and std.mem.readInt(u16, trns[4..6], .big) == b;
            return .{ to8(hd, r), to8(hd, g), to8(hd, b), if (clear) 0 else 255 };
        },
        3 => {
            const i = sample(hd, row, x);
            if (@as(usize, i) * 3 + 3 > palette.len) return error.Corrupt;
            const a: u8 = if (i < trns.len) trns[i] else 255;
            return .{ palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], a };
        },
        4 => {
            const v = to8(hd, sample(hd, row, x * 2));
            return .{ v, v, v, to8(hd, sample(hd, row, x * 2 + 1)) };
        },
        6 => return .{
            to8(hd, sample(hd, row, x * 4)),
            to8(hd, sample(hd, row, x * 4 + 1)),
            to8(hd, sample(hd, row, x * 4 + 2)),
            to8(hd, sample(hd, row, x * 4 + 3)),
        },
        else => unreachable,
    }
}

/// The width and height in a PNG's header, without decoding it.
pub fn size(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, signature) or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ w, h };
}

const testing = std.testing;

test "encode then decode round-trips every pixel" {
    const w = 37;
    const h = 23;
    var rgba: [w * h * 4]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(7);
    const rand = prng.random();
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            // A mix of smooth gradients (which filters love) and noise.
            rgba[i] = @intCast(x * 6);
            rgba[i + 1] = @intCast(y * 11);
            rgba[i + 2] = if (x % 5 == 0) rand.int(u8) else 128;
            rgba[i + 3] = @intCast((x + y) * 4);
        }
    }
    const file = try encodeAlloc(testing.allocator, w, h, &rgba, .{});
    defer testing.allocator.free(file);
    try testing.expectStringStartsWith(file, signature);

    var img = try decode(testing.allocator, file);
    defer img.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, w), img.width);
    try testing.expectEqual(@as(u32, h), img.height);
    try testing.expectEqualSlices(u8, &rgba, img.rgba);
}

test "smooth images compress well" {
    const w = 256;
    const h = 256;
    const rgba = try testing.allocator.alloc(u8, w * h * 4);
    defer testing.allocator.free(rgba);
    for (0..h) |y| for (0..w) |x| {
        rgba[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x), @intCast(y), 40, 255 };
    };
    const file = try encodeAlloc(testing.allocator, w, h, rgba, .{});
    defer testing.allocator.free(file);
    try testing.expect(file.len < rgba.len / 20);
}

test "decode rejects bad input" {
    try testing.expectError(error.NotPng, decode(testing.allocator, "GIF89a"));
    const px = [_]u8{ 1, 2, 3, 4 };
    const file = try encodeAlloc(testing.allocator, 1, 1, &px, .{});
    defer testing.allocator.free(file);
    // Flip a byte inside IHDR: the CRC no longer matches.
    const bad = try testing.allocator.dupe(u8, file);
    defer testing.allocator.free(bad);
    bad[signature.len + 8] ^= 1;
    try testing.expectError(error.Corrupt, decode(testing.allocator, bad));
    try testing.expectError(error.Corrupt, decode(testing.allocator, file[0 .. file.len - 12]));
}

test "paeth predictor matches the specification" {
    try testing.expectEqual(@as(u8, 10), paeth(10, 20, 20));
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 10));
    try testing.expectEqual(@as(u8, 20), paeth(10, 20, 9));
    try testing.expectEqual(@as(u8, 20), paeth(10, 30, 20));
    try testing.expectEqual(@as(u8, 10), paeth(10, 12, 30));
}

/// A PNG with the given header fields, extra chunks before IDAT, and raw
/// (filter byte plus row) scanlines, for decoder tests.
fn testPng(gpa: Allocator, w: u32, h: u32, depth: u8, color: u8, interlace: u8, chunks: []const struct { *const [4]u8, []const u8 }, raw: []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ depth, color, 0, 0, interlace };
    try writeChunk(&aw.writer, "IHDR", &ihdr);
    for (chunks) |c| try writeChunk(&aw.writer, c[0], c[1]);
    var z_out: Writer.Allocating = try .initCapacity(gpa, 256);
    defer z_out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const z = try gpa.create(flate.Compress);
    defer gpa.destroy(z);
    z.* = try flate.Compress.init(&z_out.writer, window, .zlib, .default);
    try z.writer.writeAll(raw);
    try z.finish();
    try writeChunk(&aw.writer, "IDAT", z_out.written());
    try writeChunk(&aw.writer, "IEND", "");
    return aw.toOwnedSlice();
}

test "decode palettes, low and high bit depths, and transparency" {
    const gpa = testing.allocator;
    // 2-bit palette, 3x1: indices 0, 1, 2 packed as 00 01 10 00.
    const pal = try testPng(gpa, 3, 1, 2, 3, 0, &.{ .{ "PLTE", "\xff\x00\x00\x00\xff\x00\x00\x00\xff" }, .{ "tRNS", "\x80" } }, "\x00\x18");
    defer gpa.free(pal);
    var a = try decode(gpa, pal);
    defer a.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 255 }, a.rgba);

    // 16-bit gray, 2x1, with the second value marked transparent.
    const gray = try testPng(gpa, 2, 1, 16, 0, 0, &.{.{ "tRNS", "\x12\x34" }}, "\x00\xff\xff\x12\x34");
    defer gpa.free(gray);
    var b = try decode(gpa, gray);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0x12, 0x12, 0x12, 0 }, b.rgba);

    // 1-bit gray scales to 0 and 255.
    const bits = try testPng(gpa, 3, 1, 1, 0, 0, &.{}, "\x00\xa0");
    defer gpa.free(bits);
    var c = try decode(gpa, bits);
    defer c.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255 }, c.rgba);
    try testing.expectEqual(@as(?[2]u32, .{ 3, 1 }), size(bits));
}

test "decode Adam7 interlaced images" {
    const gpa = testing.allocator;
    // A 3x3 8-bit gray image with pixel (x, y) = 10 * (3 * y + x).
    // Pass 1: (0,0). Pass 4: (2,0). Pass 5: (0,2), (2,2). Pass 6: (1,0),
    // (1,2). Pass 7: row 1, all three pixels. Passes 2 and 3 are empty.
    const raw = "\x00\x00" ++ "\x00\x14" ++ "\x00\x3c\x50" ++ "\x00\x0a" ++ "\x00\x46" ++ "\x00\x1e\x28\x32";
    const file = try testPng(gpa, 3, 3, 8, 0, 1, &.{}, raw);
    defer gpa.free(file);
    var img = try decode(gpa, file);
    defer img.deinit(gpa);
    for (0..9) |i| try testing.expectEqual(@as(u8, @intCast(10 * i)), img.rgba[i * 4]);
}
