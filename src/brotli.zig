//! Brotli (RFC 7932), the compression WOFF2 fonts use.
//!
//! `compress` finds repeats with hash chains, looking one byte ahead
//! before taking a match, and writes them as insert-and-copy commands in
//! meta-blocks of up to 1 MB, each with prefix codes built from its own
//! symbol counts. Distances used just before are written with the short
//! codes that need no extra bits, and a block that does not shrink is
//! stored as it is. It uses one block type and one prefix code per
//! alphabet, and never refers to the static dictionary.
//!
//! `decompress` reads the whole format, including static dictionary words
//! with their transforms and the UTF-8 and signed literal context modes.
//! The dictionary (`brotli_dictionary.bin`) and those tables
//! (`brotli_tables.zig`) were extracted from the text of RFC 7932, and the
//! tests check them against the CRC-32 values the RFC gives. Only the
//! large-window extension, which is not part of RFC 7932, is unsupported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tables = @import("brotli_tables.zig");
/// The static dictionary of RFC 7932 Appendix A.
const dictionary = @embedFile("brotli_dictionary.bin");

pub const Error = Allocator.Error || error{ InvalidBrotli, UnsupportedBrotli };

// ---------------------------------------------------------------------------
// Tables of the format (RFC 7932 sections 4, 5 and 6)

const Code = struct { base: u32, extra: u5 };

const insert_codes = [24]Code{
    .{ .base = 0, .extra = 0 },     .{ .base = 1, .extra = 0 },     .{ .base = 2, .extra = 0 },     .{ .base = 3, .extra = 0 },
    .{ .base = 4, .extra = 0 },     .{ .base = 5, .extra = 0 },     .{ .base = 6, .extra = 1 },     .{ .base = 8, .extra = 1 },
    .{ .base = 10, .extra = 2 },    .{ .base = 14, .extra = 2 },    .{ .base = 18, .extra = 3 },    .{ .base = 26, .extra = 3 },
    .{ .base = 34, .extra = 4 },    .{ .base = 50, .extra = 4 },    .{ .base = 66, .extra = 5 },    .{ .base = 98, .extra = 5 },
    .{ .base = 130, .extra = 6 },   .{ .base = 194, .extra = 7 },   .{ .base = 322, .extra = 8 },   .{ .base = 578, .extra = 9 },
    .{ .base = 1090, .extra = 10 }, .{ .base = 2114, .extra = 12 }, .{ .base = 6210, .extra = 14 }, .{ .base = 22594, .extra = 24 },
};

const copy_codes = [24]Code{
    .{ .base = 2, .extra = 0 },   .{ .base = 3, .extra = 0 },   .{ .base = 4, .extra = 0 },     .{ .base = 5, .extra = 0 },
    .{ .base = 6, .extra = 0 },   .{ .base = 7, .extra = 0 },   .{ .base = 8, .extra = 0 },     .{ .base = 9, .extra = 0 },
    .{ .base = 10, .extra = 1 },  .{ .base = 12, .extra = 1 },  .{ .base = 14, .extra = 2 },    .{ .base = 18, .extra = 2 },
    .{ .base = 22, .extra = 3 },  .{ .base = 30, .extra = 3 },  .{ .base = 38, .extra = 4 },    .{ .base = 54, .extra = 4 },
    .{ .base = 70, .extra = 5 },  .{ .base = 102, .extra = 5 }, .{ .base = 134, .extra = 6 },   .{ .base = 198, .extra = 7 },
    .{ .base = 326, .extra = 8 }, .{ .base = 582, .extra = 9 }, .{ .base = 1094, .extra = 10 }, .{ .base = 2118, .extra = 24 },
};

const block_count_codes = [26]Code{
    .{ .base = 1, .extra = 2 },     .{ .base = 5, .extra = 2 },      .{ .base = 9, .extra = 2 },     .{ .base = 13, .extra = 2 },
    .{ .base = 17, .extra = 3 },    .{ .base = 25, .extra = 3 },     .{ .base = 33, .extra = 3 },    .{ .base = 41, .extra = 3 },
    .{ .base = 49, .extra = 4 },    .{ .base = 65, .extra = 4 },     .{ .base = 81, .extra = 4 },    .{ .base = 97, .extra = 4 },
    .{ .base = 113, .extra = 5 },   .{ .base = 145, .extra = 5 },    .{ .base = 177, .extra = 5 },   .{ .base = 209, .extra = 5 },
    .{ .base = 241, .extra = 6 },   .{ .base = 305, .extra = 6 },    .{ .base = 369, .extra = 7 },   .{ .base = 497, .extra = 8 },
    .{ .base = 753, .extra = 9 },   .{ .base = 1265, .extra = 10 },  .{ .base = 2289, .extra = 11 }, .{ .base = 4337, .extra = 12 },
    .{ .base = 8433, .extra = 13 }, .{ .base = 16625, .extra = 24 },
};

/// The insert and copy code ranges of each 64-symbol cell of the
/// insert-and-copy alphabet; the first two cells imply distance code 0.
const cells = [11]struct { insert: u8, copy: u8 }{
    .{ .insert = 0, .copy = 0 },  .{ .insert = 0, .copy = 8 },   .{ .insert = 0, .copy = 0 },
    .{ .insert = 0, .copy = 8 },  .{ .insert = 8, .copy = 0 },   .{ .insert = 8, .copy = 8 },
    .{ .insert = 0, .copy = 16 }, .{ .insert = 16, .copy = 0 },  .{ .insert = 8, .copy = 16 },
    .{ .insert = 16, .copy = 8 }, .{ .insert = 16, .copy = 16 },
};

/// The order code length code lengths are written in.
const code_length_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// What distance codes 4 to 9 (and 10 to 15) add to the last (and second
/// to last) distance.
const ring_offsets = [6]i64{ -1, 1, -2, 2, -3, 3 };

const max_window_bits = 22;
const literal_alphabet = 256;
const command_alphabet = 704;

fn lengthCode(table: []const Code, v: u32) u5 {
    var i: usize = table.len;
    while (i > 0) {
        i -= 1;
        if (v >= table[i].base) return @intCast(i);
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Encoding

const BitWriter = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,

    fn write(w: *BitWriter, arena: Allocator, bits: u64, count: u6) Allocator.Error!void {
        std.debug.assert(count <= 32);
        w.acc |= bits << w.n;
        w.n += count;
        while (w.n >= 8) {
            try w.out.append(arena, @truncate(w.acc));
            w.acc >>= 8;
            w.n -= 8;
        }
    }

    fn finish(w: *BitWriter, arena: Allocator) Allocator.Error![]u8 {
        if (w.n > 0) try w.out.append(arena, @truncate(w.acc));
        w.acc = 0;
        w.n = 0;
        return w.out.items;
    }
};

/// An insert-and-copy command: `insert` literals from `lit_start`, then
/// `copy` bytes from `distance` back (no copy when `copy` is 0).
const Command = struct { lit_start: usize, insert: u32, copy: u32, distance: u32 };

/// Code lengths for `freqs`, at most `limit` bits, from a Huffman tree
/// whose counts are flattened until it fits.
fn codeLengths(arena: Allocator, freqs: []const u32, limit: u4, lengths: []u4) Allocator.Error!void {
    @memset(lengths, 0);
    var used: usize = 0;
    var only: usize = 0;
    for (freqs, 0..) |f, i| if (f > 0) {
        used += 1;
        only = i;
    };
    if (used == 0) return;
    if (used == 1) {
        lengths[only] = 1;
        return;
    }
    const Node = struct { weight: u64, left: i32, right: i32 };
    var floor: u32 = 1;
    while (true) : (floor *= 2) {
        var nodes: std.ArrayList(Node) = .empty;
        var queue: std.ArrayList(u32) = .empty;
        for (freqs, 0..) |f, i| if (f > 0) {
            try nodes.append(arena, .{ .weight = @max(f, floor), .left = -1, .right = @intCast(i) });
            try queue.append(arena, @intCast(nodes.items.len - 1));
        };
        // Repeatedly join the two lightest nodes.
        while (queue.items.len > 1) {
            std.mem.sort(u32, queue.items, nodes.items, struct {
                fn heavier(ns: []const Node, x: u32, y: u32) bool {
                    return ns[x].weight > ns[y].weight;
                }
            }.heavier);
            const x = queue.pop().?;
            const y = queue.pop().?;
            try nodes.append(arena, .{ .weight = nodes.items[x].weight + nodes.items[y].weight, .left = @intCast(x), .right = @intCast(y) });
            try queue.append(arena, @intCast(nodes.items.len - 1));
        }
        // Depths, walking down from the root.
        var too_deep = false;
        var stack: std.ArrayList(struct { node: u32, depth: u32 }) = .empty;
        try stack.append(arena, .{ .node = queue.items[0], .depth = 0 });
        while (stack.pop()) |s| {
            const node = nodes.items[s.node];
            if (node.left < 0) {
                if (s.depth > limit) too_deep = true else lengths[@intCast(node.right)] = @intCast(s.depth);
                continue;
            }
            try stack.append(arena, .{ .node = @intCast(node.left), .depth = s.depth + 1 });
            try stack.append(arena, .{ .node = @intCast(node.right), .depth = s.depth + 1 });
        }
        if (!too_deep) return;
        @memset(lengths, 0);
    }
}

/// Canonical codes for `lengths`, bit-reversed for writing LSB first.
fn canonicalCodes(lengths: []const u4, codes: []u16) void {
    var count: [16]u16 = @splat(0);
    for (lengths) |l| count[l] += 1;
    count[0] = 0;
    var next: [16]u16 = @splat(0);
    var code: u16 = 0;
    for (1..16) |bits| {
        code = (code + count[bits - 1]) << 1;
        next[bits] = code;
    }
    for (lengths, codes) |l, *c| {
        if (l == 0) {
            c.* = 0;
            continue;
        }
        const v = next[l];
        next[l] += 1;
        c.* = @bitReverse(v) >> @intCast(16 - @as(u5, l));
    }
}

/// A prefix code ready for writing.
const Prefix = struct {
    lengths: []u4,
    codes: []u16,

    fn write(p: Prefix, arena: Allocator, w: *BitWriter, sym: usize) Allocator.Error!void {
        try w.write(arena, p.codes[sym], p.lengths[sym]);
    }
};

/// Builds a prefix code for `freqs` and writes its description (RFC 7932
/// section 3.4 or 3.5).
fn writePrefixCode(arena: Allocator, w: *BitWriter, freqs: []const u32, alphabet_bits: u6) Allocator.Error!Prefix {
    const lengths = try arena.alloc(u4, freqs.len);
    const codes = try arena.alloc(u16, freqs.len);
    try codeLengths(arena, freqs, 15, lengths);
    var used: usize = 0;
    var only: usize = 0;
    for (freqs, 0..) |f, i| if (f > 0) {
        used += 1;
        only = i;
    };
    if (used <= 1) {
        // A simple prefix code with one symbol, which takes no bits.
        try w.write(arena, 1, 2);
        try w.write(arena, 0, 2);
        try w.write(arena, only, alphabet_bits);
        @memset(lengths, 0);
        @memset(codes, 0);
        return .{ .lengths = lengths, .codes = codes };
    }
    canonicalCodes(lengths, codes);
    // The symbols' code lengths, written with the code length code. Only
    // the lengths up to the last used symbol are needed: the reader stops
    // once the code is complete.
    var last: usize = 0;
    for (lengths, 0..) |l, i| if (l > 0) {
        last = i;
    };
    var cl_freqs: [18]u32 = @splat(0);
    for (lengths[0 .. last + 1]) |l| cl_freqs[l] += 1;
    var cl_lengths: [18]u4 = undefined;
    try codeLengths(arena, &cl_freqs, 5, &cl_lengths);
    var cl_codes: [18]u16 = undefined;
    var cl_used: usize = 0;
    for (cl_lengths) |l| {
        if (l > 0) cl_used += 1;
    }
    if (cl_used > 1) canonicalCodes(&cl_lengths, &cl_codes) else {
        // One code length symbol: it takes no bits.
        @memset(&cl_codes, 0);
        for (&cl_lengths) |*l| {
            if (l.* > 0) l.* = 1;
        }
    }
    // HSKIP 0, then the code length code's lengths with the fixed code.
    try w.write(arena, 0, 2);
    var space: i32 = 32;
    for (code_length_order) |sym| {
        const l = cl_lengths[sym];
        const fixed: [6]struct { v: u4, n: u6 } = .{ .{ .v = 0, .n = 2 }, .{ .v = 7, .n = 4 }, .{ .v = 3, .n = 3 }, .{ .v = 2, .n = 2 }, .{ .v = 1, .n = 2 }, .{ .v = 15, .n = 4 } };
        try w.write(arena, fixed[l].v, fixed[l].n);
        if (l > 0) {
            space -= @as(i32, 32) >> l;
            if (space <= 0) break;
        }
    }
    const single = cl_used == 1;
    for (lengths[0 .. last + 1]) |l| {
        if (!single) try w.write(arena, cl_codes[l], cl_lengths[l]);
    }
    return .{ .lengths = lengths, .codes = codes };
}

fn bitsFor(alphabet: usize) u6 {
    var bits: u6 = 0;
    while ((@as(usize, 1) << bits) < alphabet) bits += 1;
    return bits;
}

/// The distance code and extra bits for `distance` (no postfix, no direct
/// codes).
fn distanceCode(distance: u32) struct { code: u32, extra: u32, nbits: u5 } {
    const d = distance + 3;
    const top: u5 = @intCast(31 - @clz(d));
    const n = top - 1;
    const h = (d >> n) & 1;
    return .{ .code = 16 + 2 * (@as(u32, n) - 1) + h, .extra = d - ((2 + h) << n), .nbits = n };
}

/// Finds repeats of at least four bytes with hash chains, looking one byte
/// ahead before taking a match (lazy matching) and preferring the distances
/// used last, which cost no extra bits.
fn findCommands(arena: Allocator, data: []const u8) Allocator.Error![]Command {
    var m: Matcher = try .init(arena, data);
    var commands: std.ArrayList(Command) = .empty;
    var lit_start: usize = 0;
    var i: usize = 0;
    var pending: ?Match = null;
    while (i < data.len) {
        const here = pending orelse m.longest(i);
        pending = null;
        m.insert(i);
        if (here.len < 4) {
            i += 1;
            continue;
        }
        // A longer match one byte on is worth a literal.
        if (i + 1 < data.len and here.len < nice_len) {
            const next = m.longest(i + 1);
            if (next.len > here.len + 1) {
                pending = next;
                i += 1;
                continue;
            }
        }
        try commands.append(arena, .{ .lit_start = lit_start, .insert = @intCast(i - lit_start), .copy = @intCast(here.len), .distance = @intCast(here.dist) });
        m.used(here.dist);
        const end = i + here.len;
        var k = i + 1;
        while (k < end) : (k += 1) m.insert(k);
        i = end;
        lit_start = i;
    }
    if (lit_start < data.len) try commands.append(arena, .{ .lit_start = lit_start, .insert = @intCast(data.len - lit_start), .copy = 0, .distance = 0 });
    return commands.items;
}

const Match = struct { len: usize = 0, dist: usize = 0 };

/// A match of this length is taken without looking further.
const nice_len = 258;

const Matcher = struct {
    const hash_bits = 17;
    const max_chain = 128;
    const max_len: usize = 1 << 16;
    const window: usize = (1 << max_window_bits) - 16;

    data: []const u8,
    head: []i32,
    prev: []i32,
    /// The last distances, newest last, as the decoder keeps them.
    recent: [4]usize = .{ 16, 15, 11, 4 },

    fn init(arena: Allocator, data: []const u8) Allocator.Error!Matcher {
        const head = try arena.alloc(i32, 1 << hash_bits);
        @memset(head, -1);
        return .{ .data = data, .head = head, .prev = try arena.alloc(i32, data.len) };
    }

    fn hash(m: *const Matcher, i: usize) usize {
        const v = std.mem.readInt(u32, m.data[i..][0..4], .little);
        return (v *% 0x1E35A7BD) >> (32 - hash_bits);
    }

    fn insert(m: *Matcher, i: usize) void {
        if (i + 4 > m.data.len) return;
        const hv = m.hash(i);
        m.prev[i] = m.head[hv];
        m.head[hv] = @intCast(i);
    }

    fn matchLen(m: *const Matcher, at: usize, dist: usize) usize {
        const d = m.data;
        const limit = @min(d.len - at, max_len);
        var len: usize = 0;
        while (len < limit and d[at - dist + len] == d[at + len]) len += 1;
        return len;
    }

    /// The best match at `i` against the positions inserted so far.
    fn longest(m: *const Matcher, i: usize) Match {
        var best: Match = .{};
        const d = m.data;
        // The recent distances first: a match at one of them needs no
        // distance bits, so it wins unless another is clearly longer.
        var r: usize = 4;
        while (r > 0) {
            r -= 1;
            const dist = m.recent[r];
            if (dist > i or dist > window) continue;
            const len = m.matchLen(i, dist);
            if (len > best.len) best = .{ .len = len, .dist = dist };
        }
        const cache_len = best.len;
        if (i + 4 > d.len) return best;
        var cand = m.head[m.hash(i)];
        var chain: usize = 0;
        while (cand >= 0 and chain < max_chain) : (chain += 1) {
            const c: usize = @intCast(cand);
            if (i - c > window or best.len >= nice_len) break;
            // A candidate must beat the best: check that byte first. A
            // match that reaches the end cannot be beaten.
            if (i + best.len >= d.len) break;
            if (d[c + best.len] == d[i + best.len]) {
                const len = m.matchLen(i, i - c);
                // Two more bytes pay for a new distance.
                if (len > best.len and (best.len != cache_len or len >= cache_len + 2 or cache_len < 4)) best = .{ .len = len, .dist = i - c };
            }
            cand = m.prev[c];
        }
        return best;
    }

    /// Notes a match's distance, as the decoder will.
    fn used(m: *Matcher, dist: usize) void {
        if (dist == m.recent[3]) return;
        m.recent = .{ m.recent[1], m.recent[2], m.recent[3], dist };
    }
};

/// The distance code (with its extra bits) the decoder's last distances
/// allow for `distance`; codes 0 to 15 need no extra bits.
fn pickDistance(recent: *[4]u32, distance: u32) struct { code: u32, extra: u32, nbits: u5 } {
    const last = recent[3];
    const second = recent[2];
    const short = [16]i64{
        last,                 second,               recent[1],            recent[0],
        @as(i64, last) - 1,   @as(i64, last) + 1,   @as(i64, last) - 2,   @as(i64, last) + 2,
        @as(i64, last) - 3,   @as(i64, last) + 3,   @as(i64, second) - 1, @as(i64, second) + 1,
        @as(i64, second) - 2, @as(i64, second) + 2, @as(i64, second) - 3, @as(i64, second) + 3,
    };
    var code: ?u32 = null;
    for (short, 0..) |v, k| if (v == distance) {
        code = @intCast(k);
        break;
    };
    // Every distance code but 0 moves the distance into the last ones.
    if (code != @as(?u32, 0)) recent.* = .{ recent[1], recent[2], recent[3], distance };
    if (code) |c| return .{ .code = c, .extra = 0, .nbits = 0 };
    const d = distanceCode(distance);
    return .{ .code = d.code, .extra = d.extra, .nbits = d.nbits };
}

/// Compresses `data` as a Brotli stream.
pub fn compress(arena: Allocator, data: []const u8) Allocator.Error![]u8 {
    var w: BitWriter = .{};
    // WBITS 22: a 1, then 3 bits of 22 - 17.
    try w.write(arena, 1, 1);
    try w.write(arena, max_window_bits - 17, 3);
    const all = try findCommands(arena, data);
    // Meta-blocks of at most 1 MB of output, at command boundaries, so
    // each has prefix codes fitted to its own part. Long inserts are
    // split so that one never overflows a block.
    const block_limit: usize = 1 << 20;
    var commands: std.ArrayList(Command) = .empty;
    for (all) |c| {
        var cmd = c;
        while (cmd.insert > block_limit) {
            try commands.append(arena, .{ .lit_start = cmd.lit_start, .insert = @intCast(block_limit), .copy = 0, .distance = 0 });
            cmd.lit_start += block_limit;
            cmd.insert -= @intCast(block_limit);
        }
        try commands.append(arena, cmd);
    }
    var recent: [4]u32 = .{ 16, 15, 11, 4 };
    var start: usize = 0;
    var at: usize = 0;
    while (start < commands.items.len) {
        var end = start;
        var size: usize = 0;
        while (end < commands.items.len) {
            const c = commands.items[end];
            if (end > start and size + c.insert + c.copy > block_limit) break;
            size += c.insert + c.copy;
            end += 1;
        }
        // Written compressed unless that is bigger than the bytes.
        var trial: BitWriter = .{ .acc = w.acc, .n = w.n };
        const saved = recent;
        try writeMetaBlock(arena, &trial, data, commands.items[start..end], size, &recent);
        const bits = trial.out.items.len * 8 + trial.n - w.n;
        if (bits > size * 8 + 48) {
            recent = saved;
            try writeHeader(arena, &w, size, true);
            // Uncompressed data starts at a byte boundary.
            if (w.n > 0) try w.write(arena, 0, 8 - @as(u6, w.n % 8));
            try w.out.appendSlice(arena, data[at..][0..size]);
        } else {
            try w.out.appendSlice(arena, trial.out.items);
            w.acc = trial.acc;
            w.n = trial.n;
        }
        at += size;
        start = end;
    }
    // ISLAST, ISLASTEMPTY.
    try w.write(arena, 3, 2);
    return w.finish(arena);
}

/// ISLAST 0, MNIBBLES, MLEN - 1 and ISUNCOMPRESSED.
fn writeHeader(arena: Allocator, w: *BitWriter, size: usize, uncompressed: bool) Allocator.Error!void {
    try w.write(arena, 0, 1);
    const nibbles: u6 = if (size - 1 < 1 << 16) 4 else if (size - 1 < 1 << 20) 5 else 6;
    try w.write(arena, nibbles - 4, 2);
    try w.write(arena, size - 1, nibbles * 4);
    try w.write(arena, @intFromBool(uncompressed), 1);
}

fn writeMetaBlock(arena: Allocator, w: *BitWriter, data: []const u8, commands: []const Command, size: usize, recent: *[4]u32) Allocator.Error!void {
    try writeHeader(arena, w, size, false);
    // One block type for each category; NPOSTFIX 0, NDIRECT 0; literal
    // context mode LSB6; one prefix code each.
    try w.write(arena, 0, 1);
    try w.write(arena, 0, 1);
    try w.write(arena, 0, 1);
    try w.write(arena, 0, 2);
    try w.write(arena, 0, 4);
    try w.write(arena, 0, 2);
    try w.write(arena, 0, 1);
    try w.write(arena, 0, 1);

    // Each command's symbols, then their counts.
    const Coded = struct { sym: u16, dist: u32 = 0, extra: u32 = 0, nbits: u5 = 0, explicit: bool = false };
    var lit_freqs: [literal_alphabet]u32 = @splat(0);
    var cmd_freqs: [command_alphabet]u32 = @splat(0);
    var dist_freqs: [64]u32 = @splat(0);
    const coded = try arena.alloc(Coded, commands.len);
    for (commands, coded) |c, *k| {
        for (data[c.lit_start..][0..c.insert]) |b| lit_freqs[b] += 1;
        const ic = lengthCode(&insert_codes, c.insert);
        const cc = lengthCode(&copy_codes, @max(c.copy, 2));
        var cell: u16 = undefined;
        k.* = .{ .sym = 0 };
        const d = if (c.copy > 0) pickDistance(recent, c.distance) else null;
        if (d != null and d.?.code == 0 and ic < 8 and cc < 16) {
            // The last distance again: cells 0 and 1 imply it.
            cell = if (cc < 8) 0 else 1;
        } else {
            // Cells from 128 on carry an explicit distance.
            cell = switch (ic >> 3) {
                0 => switch (cc >> 3) {
                    0 => 2,
                    1 => 3,
                    else => 6,
                },
                1 => switch (cc >> 3) {
                    0 => 4,
                    1 => 5,
                    else => 8,
                },
                else => switch (cc >> 3) {
                    0 => 7,
                    1 => 9,
                    else => 10,
                },
            };
            if (d) |dd| {
                k.* = .{ .sym = 0, .dist = dd.code, .extra = dd.extra, .nbits = dd.nbits, .explicit = true };
                dist_freqs[dd.code] += 1;
            }
        }
        k.sym = cell * 64 + (@as(u16, ic & 7) << 3) + (cc & 7);
        cmd_freqs[k.sym] += 1;
    }
    const lit = try writePrefixCode(arena, w, &lit_freqs, 8);
    const cmd = try writePrefixCode(arena, w, &cmd_freqs, 10);
    const dist = try writePrefixCode(arena, w, &dist_freqs, 6);

    for (commands, coded) |c, k| {
        try cmd.write(arena, w, k.sym);
        const ic = lengthCode(&insert_codes, c.insert);
        const cc = lengthCode(&copy_codes, @max(c.copy, 2));
        try w.write(arena, c.insert - insert_codes[ic].base, insert_codes[ic].extra);
        try w.write(arena, @max(c.copy, 2) - copy_codes[cc].base, copy_codes[cc].extra);
        for (data[c.lit_start..][0..c.insert]) |b| try lit.write(arena, w, b);
        if (k.explicit) {
            try dist.write(arena, w, k.dist);
            try w.write(arena, k.extra, k.nbits);
        }
    }
}

// ---------------------------------------------------------------------------
// Decoding

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,
    bit: u3 = 0,

    fn read(r: *BitReader, count: u6) error{InvalidBrotli}!u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < count) : (i += 1) {
            if (r.pos >= r.data.len) return error.InvalidBrotli;
            v |= @as(u32, (r.data[r.pos] >> r.bit) & 1) << @intCast(i);
            if (r.bit == 7) {
                r.bit = 0;
                r.pos += 1;
            } else r.bit += 1;
        }
        return v;
    }

    fn alignToByte(r: *BitReader) error{InvalidBrotli}!void {
        if (r.bit != 0) {
            if (try r.read(@intCast(8 - @as(u6, r.bit))) != 0) return error.InvalidBrotli;
        }
    }
};

/// A canonical prefix code for decoding: symbols in code order and how
/// many codes each length has.
const Decoder = struct {
    counts: [16]u16 = @splat(0),
    symbols: []u16,
    /// The one symbol of a code that takes no bits.
    single: ?u16 = null,

    fn init(arena: Allocator, lengths: []const u4) Error!Decoder {
        var d: Decoder = .{ .symbols = try arena.alloc(u16, lengths.len) };
        var nonzero: usize = 0;
        var last: u16 = 0;
        for (lengths, 0..) |l, i| if (l > 0) {
            d.counts[l] += 1;
            nonzero += 1;
            last = @intCast(i);
        };
        if (nonzero == 1) d.single = last;
        var offs: [16]u16 = @splat(0);
        for (1..15) |l| offs[l + 1] = offs[l] + d.counts[l];
        for (lengths, 0..) |l, i| if (l > 0) {
            d.symbols[offs[l]] = @intCast(i);
            offs[l] += 1;
        };
        return d;
    }

    fn decode(d: *const Decoder, r: *BitReader) error{InvalidBrotli}!u16 {
        if (d.single) |s| return s;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        for (1..16) |l| {
            code |= @intCast(try r.read(1));
            const count: i32 = d.counts[l];
            if (code - count < first) return d.symbols[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidBrotli;
    }
};

fn readPrefixCode(arena: Allocator, r: *BitReader, alphabet: usize) Error!Decoder {
    const lengths = try arena.alloc(u4, alphabet);
    @memset(lengths, 0);
    const hskip = try r.read(2);
    if (hskip == 1) {
        const nsym = try r.read(2) + 1;
        const bits = bitsFor(alphabet);
        var syms: [4]u16 = undefined;
        for (syms[0..nsym]) |*s| {
            const v = try r.read(bits);
            if (v >= alphabet) return error.InvalidBrotli;
            s.* = @intCast(v);
        }
        for (syms[0..nsym], 0..) |s, k| for (syms[0..k]) |t| if (s == t) return error.InvalidBrotli;
        switch (nsym) {
            1 => {
                var d = try Decoder.init(arena, lengths);
                d.single = syms[0];
                return d;
            },
            2 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 1;
            },
            3 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 2;
            },
            else => if (try r.read(1) == 0) {
                for (syms) |s| lengths[s] = 2;
            } else {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 3;
                lengths[syms[3]] = 3;
            },
        }
        return Decoder.init(arena, lengths);
    }
    // Complex: the code length code's lengths, with a fixed code.
    var cl_lengths: [18]u4 = @splat(0);
    var space: i32 = 32;
    var num_codes: usize = 0;
    for (code_length_order[hskip..]) |sym| {
        var l: u4 = undefined;
        const peek2 = try r.read(2);
        l = switch (peek2) {
            0 => 0,
            1 => 4,
            2 => 3,
            else => if (try r.read(1) == 0) 2 else if (try r.read(1) == 0) 1 else 5,
        };
        cl_lengths[sym] = l;
        if (l > 0) {
            space -= @as(i32, 32) >> l;
            num_codes += 1;
            if (space <= 0) break;
        }
    }
    if (!(num_codes == 1 or space == 0)) return error.InvalidBrotli;
    const cl = try Decoder.init(arena, &cl_lengths);
    var symbol: usize = 0;
    var prev_len: u4 = 8;
    var repeat: u32 = 0;
    var repeat_len: u4 = 0;
    var sym_space: i32 = 32768;
    while (symbol < alphabet and sym_space > 0) {
        const c = try cl.decode(r);
        if (c < 16) {
            repeat = 0;
            lengths[symbol] = @intCast(c);
            if (c != 0) {
                prev_len = @intCast(c);
                sym_space -= @as(i32, 32768) >> @intCast(c);
            }
            symbol += 1;
            continue;
        }
        const extra: u5 = if (c == 16) 2 else 3;
        const new_len: u4 = if (c == 16) prev_len else 0;
        if (repeat_len != new_len) {
            repeat = 0;
            repeat_len = new_len;
        }
        const old = repeat;
        if (repeat > 0) {
            repeat -= 2;
            repeat <<= extra;
        }
        repeat += try r.read(extra) + 3;
        const delta = repeat - old;
        if (symbol + delta > alphabet) return error.InvalidBrotli;
        for (0..delta) |_| {
            lengths[symbol] = repeat_len;
            symbol += 1;
        }
        if (repeat_len != 0) sym_space -= @as(i32, @intCast(delta)) << @intCast(15 - @as(u5, repeat_len));
    }
    if (sym_space != 0) return error.InvalidBrotli;
    return Decoder.init(arena, lengths);
}

fn readVarCount(r: *BitReader) error{InvalidBrotli}!u32 {
    if (try r.read(1) == 0) return 1;
    const n = try r.read(3);
    if (n == 0) return 2;
    return (@as(u32, 1) << @intCast(n)) + try r.read(@intCast(n)) + 1;
}

/// Block types and counts of one category (literals, commands or
/// distances).
const Blocks = struct {
    types: u32,
    type_code: ?Decoder = null,
    count_code: ?Decoder = null,
    current: u32 = 0,
    previous: u32 = 1,
    left: u32 = 1 << 24,

    fn read(arena: Allocator, r: *BitReader) Error!Blocks {
        var b: Blocks = .{ .types = try readVarCount(r) };
        if (b.types >= 2) {
            b.type_code = try readPrefixCode(arena, r, b.types + 2);
            b.count_code = try readPrefixCode(arena, r, 26);
            b.left = try readCount(&b.count_code.?, r);
        }
        return b;
    }

    fn readCount(code: *const Decoder, r: *BitReader) error{InvalidBrotli}!u32 {
        const c = block_count_codes[try code.decode(r)];
        return c.base + try r.read(c.extra);
    }

    /// Counts one symbol, switching blocks first when the block is spent.
    fn next(b: *Blocks, r: *BitReader) error{InvalidBrotli}!void {
        if (b.left == 0) {
            const sym = try b.type_code.?.decode(r);
            const t: u32 = switch (sym) {
                0 => b.previous,
                1 => (b.current + 1) % b.types,
                else => sym - 2,
            };
            if (t >= b.types) return error.InvalidBrotli;
            b.previous = b.current;
            b.current = t;
            b.left = try readCount(&b.count_code.?, r);
        }
        b.left -%= 1;
    }
};

fn readContextMap(arena: Allocator, r: *BitReader, trees: u32, size: usize) Error![]u8 {
    const map = try arena.alloc(u8, size);
    @memset(map, 0);
    if (trees < 2) return map;
    const rle_max: u32 = if (try r.read(1) == 1) try r.read(4) + 1 else 0;
    const code = try readPrefixCode(arena, r, trees + rle_max);
    var i: usize = 0;
    while (i < size) {
        const sym = try code.decode(r);
        if (sym == 0) {
            map[i] = 0;
            i += 1;
        } else if (sym <= rle_max) {
            const run = (@as(usize, 1) << @intCast(sym)) + try r.read(@intCast(sym));
            if (i + run > size) return error.InvalidBrotli;
            @memset(map[i..][0..run], 0);
            i += run;
        } else {
            map[i] = @intCast(sym - rle_max);
            i += 1;
        }
    }
    if (try r.read(1) == 1) {
        // Inverse move-to-front.
        var mtf: [256]u8 = undefined;
        for (&mtf, 0..) |*m, k| m.* = @intCast(k);
        for (map) |*v| {
            const idx = v.*;
            const value = mtf[idx];
            v.* = value;
            std.mem.copyBackwards(u8, mtf[1 .. @as(usize, idx) + 1], mtf[0..idx]);
            mtf[0] = value;
        }
    }
    return map;
}

/// Where each word length's words start in the dictionary.
const dictionary_offsets = blk: {
    var offsets: [26]u32 = undefined;
    offsets[0] = 0;
    for (0..25) |l| {
        const words: u32 = if (l < 4) 0 else @as(u32, 1) << tables.ndbits[l];
        offsets[l + 1] = offsets[l] + @as(u32, @intCast(l)) * words;
    }
    break :blk offsets;
};

/// Writes word `word_id` of length `len`, transformed, to `out` (RFC 7932
/// section 8) and returns its length.
fn dictionaryWord(word_id: u64, len: u32, out: *[38]u8) error{InvalidBrotli}!usize {
    if (len < 4 or len > 24) return error.InvalidBrotli;
    const nbits = tables.ndbits[len];
    const index = word_id & ((@as(u64, 1) << nbits) - 1);
    const transform_id = word_id >> nbits;
    if (transform_id >= tables.transforms.len) return error.InvalidBrotli;
    const t = tables.transforms[@intCast(transform_id)];
    const start = dictionary_offsets[len] + index * len;
    var word: [24]u8 = undefined;
    @memcpy(word[0..len], dictionary[@intCast(start)..][0..len]);
    var w: []u8 = word[0..len];
    switch (t.kind) {
        0 => {},
        1 => if (w.len > 0) {
            _ = ferment(w, 0);
        },
        2 => {
            var i: usize = 0;
            while (i < w.len) i += ferment(w, i);
        },
        3...11 => w = w[@min(t.kind - 2, w.len)..],
        else => w = w[0 .. w.len - @min(t.kind - 11, w.len)],
    }
    var n: usize = 0;
    for ([_][]const u8{ t.prefix, w, t.suffix }) |part| {
        @memcpy(out[n..][0..part.len], part);
        n += part.len;
    }
    return n;
}

/// Uppercases the character at `pos` the way the RFC's `Ferment` does,
/// and returns its length.
fn ferment(word: []u8, pos: usize) usize {
    if (word[pos] < 192) {
        if (word[pos] >= 'a' and word[pos] <= 'z') word[pos] ^= 32;
        return 1;
    }
    if (word[pos] < 224) {
        if (pos + 1 < word.len) word[pos + 1] ^= 32;
        return 2;
    }
    if (pos + 2 < word.len) word[pos + 2] ^= 5;
    return 3;
}

/// Decompresses a Brotli stream.
pub fn decompress(arena: Allocator, data: []const u8) Error![]u8 {
    var r: BitReader = .{ .data = data };
    var out: std.ArrayList(u8) = .empty;
    // WBITS.
    var wbits: u5 = 16;
    if (try r.read(1) == 1) {
        const n = try r.read(3);
        if (n != 0) {
            wbits = @intCast(17 + n);
        } else {
            const m = try r.read(3);
            if (m == 1) return error.UnsupportedBrotli; // large windows
            wbits = if (m == 0) 17 else @intCast(8 + m);
        }
    }
    const max_backward: usize = (@as(usize, 1) << wbits) - 16;
    var dist_ring: [4]u32 = .{ 16, 15, 11, 4 };
    var ring_at: usize = 3;

    while (true) {
        const is_last = try r.read(1) == 1;
        if (is_last and try r.read(1) == 1) break;
        const nibbles_code = try r.read(2);
        if (nibbles_code == 3) {
            // Metadata: skipped.
            if (try r.read(1) != 0) return error.InvalidBrotli;
            const skip_bytes = try r.read(2);
            var skip: usize = 0;
            for (0..skip_bytes) |k| skip |= @as(usize, try r.read(8)) << @intCast(8 * k);
            if (skip_bytes > 0) skip += 1;
            try r.alignToByte();
            if (r.pos + skip > data.len) return error.InvalidBrotli;
            r.pos += skip;
            if (is_last) break;
            continue;
        }
        const mlen = try r.read(@intCast((nibbles_code + 4) * 4)) + 1;
        if (!is_last and try r.read(1) == 1) {
            try r.alignToByte();
            if (r.pos + mlen > data.len) return error.InvalidBrotli;
            try out.appendSlice(arena, data[r.pos..][0..mlen]);
            r.pos += mlen;
            continue;
        }
        const end = out.items.len + mlen;
        var lit_blocks = try Blocks.read(arena, &r);
        var cmd_blocks = try Blocks.read(arena, &r);
        var dist_blocks = try Blocks.read(arena, &r);
        const npostfix: u5 = @intCast(try r.read(2));
        const ndirect: u32 = try r.read(4) << npostfix;
        const modes = try arena.alloc(u2, lit_blocks.types);
        for (modes) |*m| m.* = @intCast(try r.read(2));
        const lit_trees = try readVarCount(&r);
        const lit_map = try readContextMap(arena, &r, lit_trees, 64 * lit_blocks.types);
        const dist_trees = try readVarCount(&r);
        const dist_map = try readContextMap(arena, &r, dist_trees, 4 * dist_blocks.types);
        const lit_codes = try arena.alloc(Decoder, lit_trees);
        for (lit_codes) |*c| c.* = try readPrefixCode(arena, &r, literal_alphabet);
        const cmd_codes = try arena.alloc(Decoder, cmd_blocks.types);
        for (cmd_codes) |*c| c.* = try readPrefixCode(arena, &r, command_alphabet);
        const dist_alphabet = 16 + ndirect + (@as(u32, 48) << npostfix);
        const dist_codes = try arena.alloc(Decoder, dist_trees);
        for (dist_codes) |*c| c.* = try readPrefixCode(arena, &r, dist_alphabet);

        while (out.items.len < end) {
            try cmd_blocks.next(&r);
            const sym = try cmd_codes[cmd_blocks.current].decode(&r);
            const cell = cells[sym >> 6];
            const ic = insert_codes[cell.insert + ((sym >> 3) & 7)];
            const cc = copy_codes[cell.copy + (sym & 7)];
            const insert = ic.base + try r.read(ic.extra);
            const copy = cc.base + try r.read(cc.extra);
            for (0..insert) |_| {
                try lit_blocks.next(&r);
                const n = out.items.len;
                const p1: u8 = if (n > 0) out.items[n - 1] else 0;
                const p2: u8 = if (n > 1) out.items[n - 2] else 0;
                const ctx: u8 = switch (modes[lit_blocks.current]) {
                    0 => p1 & 0x3F,
                    1 => p1 >> 2,
                    2 => tables.lut0[p1] | tables.lut1[p2],
                    3 => (tables.lut2[p1] << 3) | tables.lut2[p2],
                };
                const tree = lit_map[64 * lit_blocks.current + ctx];
                if (tree >= lit_codes.len) return error.InvalidBrotli;
                try out.append(arena, @intCast(try lit_codes[tree].decode(&r)));
            }
            if (out.items.len >= end) break;
            var dcode: u32 = 0;
            if (sym >= 128) {
                try dist_blocks.next(&r);
                const dctx: u32 = if (copy > 4) 3 else copy - 2;
                const tree = dist_map[4 * dist_blocks.current + dctx];
                if (tree >= dist_codes.len) return error.InvalidBrotli;
                dcode = try dist_codes[tree].decode(&r);
            }
            const last = dist_ring[ring_at];
            const second = dist_ring[(ring_at + 3) % 4];
            var distance: i64 = switch (dcode) {
                0 => last,
                1 => second,
                2 => dist_ring[(ring_at + 2) % 4],
                3 => dist_ring[(ring_at + 1) % 4],
                4...9 => @as(i64, last) + ring_offsets[dcode - 4],
                10...15 => @as(i64, second) + ring_offsets[dcode - 10],
                else => blk: {
                    if (dcode < 16 + ndirect) break :blk dcode - 15;
                    const x = dcode - ndirect - 16;
                    const nbits: u5 = @intCast(1 + (x >> (npostfix + 1)));
                    const hcode = x >> npostfix;
                    const lcode = x & ((@as(u32, 1) << npostfix) - 1);
                    const offset = ((@as(u64, 2) + (hcode & 1)) << nbits) - 4;
                    const extra = try r.read(nbits);
                    break :blk @intCast(((offset + extra) << npostfix) + lcode + ndirect + 1);
                },
            };
            if (distance <= 0) return error.InvalidBrotli;
            const max_distance = @min(max_backward, out.items.len);
            if (distance > max_distance) {
                // A static dictionary word, which leaves the last distances
                // alone.
                var word: [38]u8 = undefined;
                const len = try dictionaryWord(@intCast(distance - @as(i64, @intCast(max_distance)) - 1), copy, &word);
                if (out.items.len + len > end) return error.InvalidBrotli;
                try out.appendSlice(arena, word[0..len]);
                continue;
            }
            if (dcode != 0) {
                ring_at = (ring_at + 1) % 4;
                dist_ring[ring_at] = @intCast(distance);
            }
            if (out.items.len + copy > end) return error.InvalidBrotli;
            const from = out.items.len - @as(usize, @intCast(distance));
            for (0..copy) |k| try out.append(arena, out.items[from + k]);
            distance = 0;
        }
        if (out.items.len != end) return error.InvalidBrotli;
        if (is_last) break;
    }
    return out.items;
}

const testing = std.testing;

fn roundTrip(data: []const u8) !usize {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const packed_bytes = try compress(a, data);
    try testing.expectEqualSlices(u8, data, try decompress(a, packed_bytes));
    return packed_bytes.len;
}

test "round trips: empty, tiny, repetitive, mixed and random data" {
    _ = try roundTrip("");
    _ = try roundTrip("a");
    _ = try roundTrip("abcabcabcabcabcabcabcabcabcabcabc");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    for (0..400) |i| try text.print(testing.allocator, "line {d}: the quick brown fox jumps over the lazy dog\n", .{i % 37});
    const n = try roundTrip(text.items);
    try testing.expect(n * 8 < text.items.len);
    var prng: std.Random.DefaultPrng = .init(42);
    var noise: [70000]u8 = undefined;
    prng.random().bytes(&noise);
    // Random bytes stay about the same size.
    try testing.expect(try roundTrip(&noise) < noise.len + noise.len / 50);
    var one: [5000]u8 = @splat('x');
    _ = try roundTrip(&one);
    var two: [3000]u8 = undefined;
    for (&two, 0..) |*b, i| b.* = if (i % 2 == 0) 'a' else 'b';
    _ = try roundTrip(&two);
}

test "decodes streams from the RFC's features: uncompressed and metadata blocks, simple codes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // WBITS 16 (one 0 bit); an uncompressed meta-block of 3 bytes "abc";
    // then ISLAST, ISLASTEMPTY.
    var w: BitWriter = .{};
    try w.write(a, 0, 1);
    try w.write(a, 0, 1); // ISLAST 0
    try w.write(a, 0, 2); // 4 nibbles
    try w.write(a, 2, 16); // MLEN - 1
    try w.write(a, 1, 1); // ISUNCOMPRESSED
    var bytes = try w.finish(a);
    var stream: std.ArrayList(u8) = .empty;
    try stream.appendSlice(a, bytes);
    try stream.appendSlice(a, "abc");
    // A metadata block of 2 bytes, then the last empty block.
    w = .{};
    try w.write(a, 0, 1); // ISLAST 0
    try w.write(a, 3, 2); // MNIBBLES = 0: metadata
    try w.write(a, 0, 1); // reserved
    try w.write(a, 1, 2); // one MSKIPBYTES
    try w.write(a, 1, 8); // MSKIPLEN - 1 = 1
    bytes = try w.finish(a);
    try stream.appendSlice(a, bytes);
    try stream.appendSlice(a, "zz");
    try stream.append(a, 3); // ISLAST, ISLASTEMPTY
    try testing.expectEqualStrings("abc", try decompress(a, stream.items));
    // Truncated input is an error, not a crash.
    const good = try compress(a, "hello hello hello hello");
    try testing.expectError(error.InvalidBrotli, decompress(a, good[0 .. good.len - 2]));
}

test "decodes a stream from Google's encoder" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // "Mortise reads Brotli. " 20 times, then a pangram, compressed by the
    // reference encoder at quality 1.
    const stream = [_]u8{
        11,  247, 0,   0,   128, 170, 170, 170, 234, 255, 116, 229, 195, 201, 96,  217, 175, 118, 183, 155,
        29,  46,  106, 166, 98,  166, 106, 155, 152, 137, 170, 218, 6,   27,  112, 224, 26,  6,   140, 9,
        14,  4,   179, 3,   88,  103, 16,  59,  22,  111, 29,  65,  72,  105, 135, 86,  216, 111, 54,  194,
        185, 150, 85,  111, 8,   87,  176, 227, 138, 65,  248, 57,  48,  241, 139, 37,  236, 167, 3,   223,
        36,  240, 134, 176, 169, 255, 131, 230, 25,  113, 146, 102, 121, 81,  86,  117, 19,  13,
    };
    var want: std.ArrayList(u8) = .empty;
    for (0..20) |_| try want.appendSlice(a, "Mortise reads Brotli. ");
    try want.appendSlice(a, "The quick brown fox jumps over the lazy dog 0123456789.");
    try testing.expectEqualStrings(want.items, try decompress(a, &stream));
}

test "decodes Google's best compression: dictionary words and context modes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var want: std.ArrayList(u8) = .empty;
    for (0..20) |_| try want.appendSlice(a, "Mortise reads Brotli. ");
    try want.appendSlice(a, "The quick brown fox jumps over the lazy dog 0123456789.");
    // The same text at the reference encoder's default and best qualities,
    // which use the static dictionary.
    const default_quality = [_]u8{
        27,  238, 1,   0,   196, 200, 109, 169, 126, 72,  59,  68,  43,  157, 70,  40,  51,  71,  188, 77,
        145, 8,   42,  10,  101, 133, 174, 147, 107, 206, 251, 105, 15,  137, 93,  82,  113, 96,  218, 243,
        25,  44,  129, 176, 24,  137, 140, 127, 11,  182, 231, 39,  65,  229, 23,  238, 138, 235, 129, 124,
        203, 253, 93,  82,  5,   250, 127, 16,  89,  163, 40,  171, 186, 105, 187, 126, 24,  9,
    };
    const best_quality = [_]u8{
        27,  238, 1,   232, 141, 148, 171, 237, 104, 213, 68,  101, 110, 163, 84,  47,  36,  121, 254, 106,
        106, 194, 15,  194, 96,  51,  8,   14,  57,  112, 248, 150, 6,   89,  128, 24,  57,  7,   19,  57,
        163, 12,  179, 236, 219, 79,  46,  196, 239, 200, 0,   143, 214, 5,   149, 233, 221, 163, 64,  238,
        29,  20,  106, 117, 210, 79,  38,  75,  1,   233, 39,  118, 162, 211, 130, 54,  214, 249, 16,  83,
        46,  10,
    };
    try testing.expectEqualStrings(want.items, try decompress(a, &default_quality));
    try testing.expectEqualStrings(want.items, try decompress(a, &best_quality));
}

test "the dictionary and tables match the CRC-32 values RFC 7932 gives" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const crc = std.hash.Crc32.hash;
    try testing.expectEqual(@as(usize, 122784), dictionary.len);
    try testing.expectEqual(@as(u32, 0x5136cb04), crc(dictionary));
    try testing.expectEqual(@as(u32, 0x8e91efb7), crc(&tables.lut0));
    try testing.expectEqual(@as(u32, 0xd01a32f4), crc(&tables.lut1));
    try testing.expectEqual(@as(u32, 0x0dd7a0d6), crc(&tables.lut2));
    // Appendix B: each transform as prefix, 0, kind, suffix, 0.
    var bytes: std.ArrayList(u8) = .empty;
    for (tables.transforms) |t| {
        try bytes.appendSlice(a, t.prefix);
        try bytes.appendSlice(a, &.{ 0, t.kind });
        try bytes.appendSlice(a, t.suffix);
        try bytes.append(a, 0);
    }
    try testing.expectEqual(@as(usize, 648), bytes.items.len);
    try testing.expectEqual(@as(u32, 0x3d965f81), crc(bytes.items));
    try testing.expectEqual(@as(u32, 122784), dictionary_offsets[25]);
}

test "dictionary words and their transforms" {
    var word: [38]u8 = undefined;
    // Word 0 of length 4 is "time"; transform 1 adds a space after it.
    var n = try dictionaryWord(0, 4, &word);
    try testing.expectEqualStrings("time", word[0..n]);
    n = try dictionaryWord(1 << 10, 4, &word);
    try testing.expectEqualStrings("time ", word[0..n]);
    // Transform 9 uppercases the first letter, 44 every letter.
    n = try dictionaryWord(9 << 10, 4, &word);
    try testing.expectEqualStrings("Time", word[0..n]);
    n = try dictionaryWord(44 << 10, 4, &word);
    try testing.expectEqualStrings("TIME", word[0..n]);
    try testing.expectError(error.InvalidBrotli, dictionaryWord(121 << 10, 4, &word));
    try testing.expectError(error.InvalidBrotli, dictionaryWord(0, 3, &word));
}

test "a match that runs to the end of the data, with more candidates left" {
    var data: [200]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = "xyzw"[i % 4];
    _ = try roundTrip(&data);
}

test "insert and copy lengths from every cell of the command alphabet" {
    // Inserts and copies of each length class, so every cell is used.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    var data: std.ArrayList(u8) = .empty;
    for ([_]usize{ 1, 9, 30, 200, 3000 }) |insert| {
        for ([_]usize{ 4, 12, 40, 300, 5000 }) |copy| {
            const start = data.items.len;
            for (0..insert) |_| try data.append(a, prng.random().int(u8));
            const from = data.items.len - @min(data.items.len - start, 50);
            for (0..copy) |k| try data.append(a, data.items[from + k % (data.items.len - from)]);
        }
    }
    _ = try roundTrip(data.items);
}

test "code lengths are limited and complete" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Fibonacci counts make the deepest plain Huffman trees.
    var freqs: [40]u32 = undefined;
    var x: u32 = 1;
    var y: u32 = 1;
    for (&freqs) |*f| {
        f.* = x;
        const z = x +% y;
        x = y;
        y = @min(z, 1 << 30);
    }
    var lengths: [40]u4 = undefined;
    try codeLengths(a, &freqs, 15, &lengths);
    var kraft: u64 = 0;
    for (lengths) |l| {
        try testing.expect(l >= 1 and l <= 15);
        kraft += @as(u64, 1) << @intCast(15 - @as(u6, l));
    }
    try testing.expectEqual(@as(u64, 1 << 15), kraft);
}
