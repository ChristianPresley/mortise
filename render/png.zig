//! PNG encoding and decoding, for 8-bit images only. Compression is the
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
    /// Valid PNG, but not 8-bit, non-interlaced gray, RGB, gray+alpha or RGBA.
    Unsupported,
};

/// Decodes an 8-bit, non-interlaced PNG into RGBA. Enough to read back what
/// `encode` writes and most simple assets; palettes, 16-bit channels and
/// interlacing are rejected as `Unsupported`.
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!Image {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var channels: usize = 0;
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
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return error.Corrupt;
            if (data[8] != 8 or data[10] != 0 or data[11] != 0 or data[12] != 0) return error.Unsupported;
            channels = switch (data[9]) {
                0 => 1,
                2 => 3,
                4 => 2,
                6 => 4,
                else => return error.Unsupported,
            };
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    if (channels == 0) return error.Corrupt;

    const stride = @as(usize, width) * channels;
    var in: std.Io.Reader = .fixed(idat.items);
    var z: flate.Decompress = .init(&in, .zlib, &.{});
    const raw = z.reader.allocRemaining(gpa, .limited((stride + 1) * height + 1)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    };
    defer gpa.free(raw);
    if (raw.len != (stride + 1) * height) return error.Corrupt;

    // Undo the filters in place, row by row.
    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        const f = std.enums.fromInt(Filter, raw[y * (stride + 1)]) orelse return error.Corrupt;
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const row = pixels[y * stride ..][0..stride];
        for (0..stride) |i| {
            const a: u8 = if (i >= channels) row[i - channels] else 0;
            const b: u8 = if (y > 0) pixels[(y - 1) * stride + i] else 0;
            const c: u8 = if (y > 0 and i >= channels) pixels[(y - 1) * stride + i - channels] else 0;
            row[i] = src[i] +% predict(f, a, b, c);
        }
    }
    if (channels == 4) return .{ .width = width, .height = height, .rgba = pixels };

    defer gpa.free(pixels);
    const rgba = try gpa.alloc(u8, @as(usize, width) * height * 4);
    for (0..@as(usize, width) * height) |i| {
        const p = pixels[i * channels ..][0..channels];
        rgba[i * 4 ..][0..4].* = switch (channels) {
            1 => .{ p[0], p[0], p[0], 255 },
            2 => .{ p[0], p[0], p[0], p[1] },
            3 => .{ p[0], p[1], p[2], 255 },
            else => unreachable,
        };
    }
    return .{ .width = width, .height = height, .rgba = rgba };
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
