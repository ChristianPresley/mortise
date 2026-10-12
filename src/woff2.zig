//! WOFF2 (W3C WOFF File Format 2.0): font tables compressed together
//! with Brotli.
//!
//! `fromSfnt` writes every table as it is (the "null transform"), which
//! the format allows for all tables, glyf and loca included; the glyf
//! transform Google's encoder applies would save a little more.

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

/// A WOFF2 file holding the tables of the TrueType or OpenType font
/// `sfnt`.
pub fn fromSfnt(arena: Allocator, sfnt: []const u8) Error![]u8 {
    if (sfnt.len < 12) return error.InvalidFont;
    const flavor = u32At(sfnt, 0);
    const n = u16At(sfnt, 4);
    if (sfnt.len < 12 + @as(usize, n) * 16) return error.InvalidFont;
    var dir: std.ArrayList(u8) = .empty;
    var stream: std.ArrayList(u8) = .empty;
    var sfnt_size: usize = 12 + 16 * @as(usize, n);
    for (0..n) |i| {
        const rec = sfnt[12 + i * 16 ..][0..16];
        const tag = rec[0..4];
        const off = u32At(rec, 8);
        const len = u32At(rec, 12);
        if (@as(usize, off) + len > sfnt.len) return error.InvalidFont;
        // Tag index 63: the tag follows. glyf and loca say "null
        // transform" with version 3; other tables with version 0.
        const null_transform: u8 = if (std.mem.eql(u8, tag, "glyf") or std.mem.eql(u8, tag, "loca")) 3 else 0;
        try dir.append(arena, 63 | null_transform << 6);
        try dir.appendSlice(arena, tag);
        try writeBase128(&dir, arena, len);
        try stream.appendSlice(arena, sfnt[off..][0..len]);
        sfnt_size += (@as(usize, len) + 3) / 4 * 4;
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
