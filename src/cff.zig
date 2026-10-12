//! Subsetting of CFF outlines, the `CFF ` table of most `.otf` fonts.
//!
//! Glyph ids are kept, as for TrueType outlines: a glyph that is not
//! needed gets the charstring `endchar`, which draws nothing, so every
//! other table that refers to glyphs by id stays valid. Subroutines (local
//! and global) that no kept glyph calls become `return`; their numbers,
//! and so the bias every call is made with, do not change. The table is
//! then written again with its offsets worked out afresh. Both name-keyed
//! and CID-keyed fonts are handled. A kept glyph built with the old
//! `seac` operator (an accented character made of two others) keeps every
//! glyph, since its parts are found through the standard encoding.
//!
//! References: Adobe Technical Notes #5176 (The Compact Font Format
//! Specification) and #5177 (The Type 2 Charstring Format).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{InvalidCff};

/// Where and why reading the table failed.
pub const Diagnostic = struct { message: []const u8 = "" };

fn fail(diag: *Diagnostic, message: []const u8) error{InvalidCff} {
    diag.message = message;
    return error.InvalidCff;
}

/// An INDEX: a counted list of byte strings.
const Index = struct {
    items: []const []const u8,
    /// Bytes the INDEX takes in the table.
    size: usize,
};

fn readIndex(arena: Allocator, data: []const u8, at: usize, diag: *Diagnostic) Error!Index {
    if (at + 2 > data.len) return fail(diag, "an INDEX runs past the end of the CFF table");
    const count = std.mem.readInt(u16, data[at..][0..2], .big);
    if (count == 0) return .{ .items = &.{}, .size = 2 };
    if (at + 3 > data.len) return fail(diag, "an INDEX runs past the end of the CFF table");
    const off_size = data[at + 2];
    if (off_size < 1 or off_size > 4) return fail(diag, "an INDEX has an invalid offset size");
    const offsets_at = at + 3;
    const data_at = offsets_at + (@as(usize, count) + 1) * off_size - 1;
    if (data_at > data.len) return fail(diag, "an INDEX runs past the end of the CFF table");
    const items = try arena.alloc([]const u8, count);
    var prev = readOffset(data, offsets_at, off_size);
    for (items, 1..) |*item, k| {
        const next = readOffset(data, offsets_at + k * off_size, off_size);
        if (next < prev or data_at + next > data.len) return fail(diag, "an INDEX has offsets out of order or out of range");
        item.* = data[data_at + prev .. data_at + next];
        prev = next;
    }
    return .{ .items = items, .size = data_at + prev - at };
}

fn readOffset(data: []const u8, at: usize, off_size: u8) usize {
    var v: usize = 0;
    for (data[at .. at + off_size]) |b| v = v << 8 | b;
    return v;
}

fn writeIndex(arena: Allocator, out: *std.ArrayList(u8), items: []const []const u8) Allocator.Error!void {
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(items.len))));
    if (items.len == 0) return;
    var total: usize = 1;
    for (items) |it| total += it.len;
    const off_size: u8 = if (total <= 0xFF) 1 else if (total <= 0xFFFF) 2 else if (total <= 0xFFFFFF) 3 else 4;
    try out.append(arena, off_size);
    var off: usize = 1;
    for (0..items.len + 1) |k| {
        var i: u8 = off_size;
        while (i > 0) {
            i -= 1;
            try out.append(arena, @truncate(off >> @as(u6, @intCast(@as(usize, i) * 8))));
        }
        if (k < items.len) off += items[k].len;
    }
    for (items) |it| try out.appendSlice(arena, it);
}

fn indexSize(items: []const []const u8) usize {
    if (items.len == 0) return 2;
    var total: usize = 1;
    for (items) |it| total += it.len;
    const off_size: usize = if (total <= 0xFF) 1 else if (total <= 0xFFFF) 2 else if (total <= 0xFFFFFF) 3 else 4;
    return 3 + (items.len + 1) * off_size + total - 1;
}

/// One DICT entry: an operator (escaped operators as 1200 + the second
/// byte) and its operands as written.
const Entry = struct {
    op: u16,
    operands: []const u8,
    /// The operands as integers, for the ones that are offsets.
    ints: [2]i64 = .{ 0, 0 },
    count: usize = 0,
};

const op_charset = 15;
const op_encoding = 16;
const op_charstrings = 17;
const op_private = 18;
const op_subrs = 19;
const op_charstring_type = 1206;
const op_ros = 1230;
const op_fd_array = 1236;
const op_fd_select = 1237;

fn readDict(arena: Allocator, data: []const u8, diag: *Diagnostic) Error![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    var ints: [2]i64 = .{ 0, 0 };
    var count: usize = 0;
    while (i < data.len) {
        const b = data[i];
        if (b <= 21) {
            var op: u16 = b;
            const operands = data[start..i];
            i += 1;
            if (b == 12) {
                if (i >= data.len) return fail(diag, "a DICT ends in the middle of an operator");
                op = 1200 + @as(u16, data[i]);
                i += 1;
            }
            try entries.append(arena, .{ .op = op, .operands = operands, .ints = ints, .count = count });
            start = i;
            count = 0;
            continue;
        }
        var value: i64 = 0;
        switch (b) {
            28 => {
                if (i + 3 > data.len) return fail(diag, "a DICT operand runs past its end");
                value = std.mem.readInt(i16, data[i + 1 ..][0..2], .big);
                i += 3;
            },
            29 => {
                if (i + 5 > data.len) return fail(diag, "a DICT operand runs past its end");
                value = std.mem.readInt(i32, data[i + 1 ..][0..4], .big);
                i += 5;
            },
            30 => {
                // A real number: nibbles up to an 0xF one.
                i += 1;
                while (i < data.len) : (i += 1) {
                    if (data[i] & 0xF == 0xF or data[i] >> 4 == 0xF) break;
                }
                i += 1;
            },
            32...246 => {
                value = @as(i64, b) - 139;
                i += 1;
            },
            247...250 => {
                if (i + 2 > data.len) return fail(diag, "a DICT operand runs past its end");
                value = (@as(i64, b) - 247) * 256 + data[i + 1] + 108;
                i += 2;
            },
            251...254 => {
                if (i + 2 > data.len) return fail(diag, "a DICT operand runs past its end");
                value = -(@as(i64, b) - 251) * 256 - data[i + 1] - 108;
                i += 2;
            },
            else => return fail(diag, "a DICT holds a reserved byte"),
        }
        if (count < 2) ints[count] = value;
        count += 1;
    }
    return entries.items;
}

fn find(entries: []const Entry, op: u16) ?Entry {
    for (entries) |e| if (e.op == op) return e;
    return null;
}

/// An operator whose operands `writeDict` writes as 5-byte integers.
const Replace = struct { op: u16, values: []const i32 };

/// Writes `entries`, with the operands of the ops in `replace` written
/// as 5-byte integers from `values`, so the size does not depend on them.
fn writeDict(arena: Allocator, entries: []const Entry, replace: []const Replace) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        const r = for (replace) |r| {
            if (r.op == e.op) break r;
        } else null;
        if (r) |rep| {
            for (rep.values) |v| {
                try out.append(arena, 29);
                try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i32, v)));
            }
        } else {
            try out.appendSlice(arena, e.operands);
        }
        if (e.op >= 1200) {
            try out.append(arena, 12);
            try out.append(arena, @intCast(e.op - 1200));
        } else {
            try out.append(arena, @intCast(e.op));
        }
    }
    return out.items;
}

fn bias(count: usize) i64 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

/// The subroutines kept glyphs call, found by walking their charstrings.
const Walker = struct {
    arena: Allocator,
    diag: *Diagnostic,
    global: []const []const u8,
    global_used: []bool,
    /// Each font DICT's local subroutines (one for a name-keyed font).
    locals: []const []const []const u8,
    locals_used: []const []bool,
    /// (kind, fd, index, stems) already walked, since the stem count
    /// decides how many bytes a hint mask takes.
    seen: std.AutoHashMapUnmanaged([4]u32, void) = .empty,
    stack: [48]i64 = undefined,
    sp: usize = 0,
    stems: u32 = 0,
    /// A kept glyph uses `seac`.
    seac: bool = false,

    fn glyph(w: *Walker, cs: []const u8, fd: usize) Error!void {
        w.sp = 0;
        w.stems = 0;
        _ = try w.run(cs, fd, 0);
    }

    /// Returns true when the charstring ended the glyph (`endchar`).
    fn run(w: *Walker, cs: []const u8, fd: usize, depth: u32) Error!bool {
        if (depth > 10) return fail(w.diag, "charstring subroutines nest more than 10 deep");
        var i: usize = 0;
        while (i < cs.len) {
            const b = cs[i];
            switch (b) {
                32...246 => {
                    w.push(@as(i64, b) - 139);
                    i += 1;
                },
                247...250 => {
                    if (i + 2 > cs.len) return fail(w.diag, "a charstring ends in the middle of a number");
                    w.push((@as(i64, b) - 247) * 256 + cs[i + 1] + 108);
                    i += 2;
                },
                251...254 => {
                    if (i + 2 > cs.len) return fail(w.diag, "a charstring ends in the middle of a number");
                    w.push(-(@as(i64, b) - 251) * 256 - cs[i + 1] - 108);
                    i += 2;
                },
                28 => {
                    if (i + 3 > cs.len) return fail(w.diag, "a charstring ends in the middle of a number");
                    w.push(std.mem.readInt(i16, cs[i + 1 ..][0..2], .big));
                    i += 3;
                },
                255 => {
                    if (i + 5 > cs.len) return fail(w.diag, "a charstring ends in the middle of a number");
                    w.push(std.mem.readInt(i32, cs[i + 1 ..][0..4], .big) >> 16);
                    i += 5;
                },
                // hstem, vstem, hstemhm, vstemhm.
                1, 3, 18, 23 => {
                    w.stems += @intCast(w.sp / 2);
                    w.sp = 0;
                    i += 1;
                },
                // hintmask, cntrmask: a vstem may come first, implicitly.
                19, 20 => {
                    w.stems += @intCast(w.sp / 2);
                    w.sp = 0;
                    i += 1 + (w.stems + 7) / 8;
                },
                10, 29 => {
                    if (w.sp == 0) return fail(w.diag, "a subroutine call has no number");
                    w.sp -= 1;
                    const global = b == 29;
                    const subrs = if (global) w.global else w.locals[fd];
                    const n = w.stack[w.sp] + bias(subrs.len);
                    if (n < 0 or n >= subrs.len) return fail(w.diag, "a charstring calls a subroutine that does not exist");
                    const idx: usize = @intCast(n);
                    if (global) w.global_used[idx] = true else w.locals_used[fd][idx] = true;
                    i += 1;
                    const key: [4]u32 = .{ @intFromBool(global), @intCast(fd), @intCast(idx), w.stems };
                    if ((try w.seen.getOrPut(w.arena, key)).found_existing) {
                        // Walked already with the same hints. The stack it
                        // leaves is unknown, which only `seac` would need.
                        w.sp = 0;
                        continue;
                    }
                    if (try w.run(subrs[idx], fd, depth + 1)) return true;
                },
                11 => return false,
                14 => {
                    // endchar with four more numbers (and maybe a width) is
                    // seac: the glyph is two others.
                    if (w.sp >= 4) w.seac = true;
                    return true;
                },
                12 => {
                    w.sp = 0;
                    i += 2;
                },
                else => {
                    w.sp = 0;
                    i += 1;
                },
            }
        }
        return false;
    }

    fn push(w: *Walker, v: i64) void {
        if (w.sp < w.stack.len) {
            w.stack[w.sp] = v;
            w.sp += 1;
        }
    }
};

/// Bytes the charset at `at` takes, for `num_glyphs` glyphs.
fn charsetSize(data: []const u8, at: usize, num_glyphs: usize, diag: *Diagnostic) Error!usize {
    if (at >= data.len) return fail(diag, "the charset is out of range");
    switch (data[at]) {
        0 => return 1 + 2 * (num_glyphs -| 1),
        1, 2 => {
            const range: usize = if (data[at] == 1) 3 else 4;
            var covered: usize = 1;
            var p = at + 1;
            while (covered < num_glyphs) {
                if (p + range > data.len) return fail(diag, "the charset runs past the end of the CFF table");
                const n_left: usize = if (range == 3) data[p + 2] else std.mem.readInt(u16, data[p + 2 ..][0..2], .big);
                covered += n_left + 1;
                p += range;
            }
            return p - at;
        },
        else => return fail(diag, "the charset has an unknown format"),
    }
}

fn encodingSize(data: []const u8, at: usize, diag: *Diagnostic) Error!usize {
    if (at + 2 > data.len) return fail(diag, "the encoding is out of range");
    const fmt = data[at];
    var size: usize = switch (fmt & 0x7F) {
        0 => 2 + @as(usize, data[at + 1]),
        1 => 2 + 2 * @as(usize, data[at + 1]),
        else => return fail(diag, "the encoding has an unknown format"),
    };
    if (fmt & 0x80 != 0) {
        if (at + size >= data.len) return fail(diag, "the encoding is out of range");
        size += 1 + 3 * @as(usize, data[at + size]);
    }
    return size;
}

fn fdSelectSize(data: []const u8, at: usize, num_glyphs: usize, diag: *Diagnostic) Error!usize {
    if (at >= data.len) return fail(diag, "the FDSelect is out of range");
    return switch (data[at]) {
        0 => 1 + num_glyphs,
        3 => blk: {
            if (at + 3 > data.len) return fail(diag, "the FDSelect is out of range");
            break :blk 3 + 3 * @as(usize, std.mem.readInt(u16, data[at + 1 ..][0..2], .big)) + 2;
        },
        else => fail(diag, "the FDSelect has an unknown format"),
    };
}

/// Which font DICT glyph `g` uses.
fn fdOf(data: []const u8, at: usize, g: usize) usize {
    switch (data[at]) {
        0 => return data[at + 1 + g],
        else => {
            const n: usize = std.mem.readInt(u16, data[at + 1 ..][0..2], .big);
            var k: usize = 0;
            while (k < n) : (k += 1) {
                const r = at + 3 + 3 * k;
                const first = std.mem.readInt(u16, data[r..][0..2], .big);
                const next = std.mem.readInt(u16, data[r + 3 ..][0..2], .big);
                if (g >= first and g < next) return data[r + 2];
            }
            return 0;
        },
    }
}

/// A Private DICT and its local subroutines.
const Private = struct {
    entries: []Entry,
    subrs: []const []const u8,
};

fn readPrivate(arena: Allocator, data: []const u8, size: i64, offset: i64, diag: *Diagnostic) Error!Private {
    if (size < 0 or offset < 0 or @as(usize, @intCast(offset)) + @as(usize, @intCast(size)) > data.len) return fail(diag, "a Private DICT is out of range");
    const at: usize = @intCast(offset);
    const entries = try readDict(arena, data[at..][0..@intCast(size)], diag);
    var subrs: []const []const u8 = &.{};
    if (find(entries, op_subrs)) |s| {
        if (s.ints[0] < 0) return fail(diag, "a Private DICT has a negative Subrs offset");
        subrs = (try readIndex(arena, data, at + @as(usize, @intCast(s.ints[0])), diag)).items;
    }
    return .{ .entries = entries, .subrs = subrs };
}

/// The CFF table `data` with only the glyphs in `keep` drawn. `keep` has
/// one entry per glyph; when a kept glyph uses `seac`, every entry is set.
pub fn subset(arena: Allocator, data: []const u8, keep: []bool, diag: *Diagnostic) Error![]u8 {
    if (data.len < 4 or data[0] != 1) return fail(diag, "the CFF table is not CFF version 1");
    const hdr_size = data[2];
    if (hdr_size < 4 or hdr_size > data.len) return fail(diag, "the CFF header is too short");
    const names = try readIndex(arena, data, hdr_size, diag);
    const top_dicts = try readIndex(arena, data, hdr_size + names.size, diag);
    if (top_dicts.items.len != 1) return fail(diag, "the CFF table must hold exactly one font");
    const strings_at = hdr_size + names.size + top_dicts.size;
    const strings = try readIndex(arena, data, strings_at, diag);
    const gsubrs = try readIndex(arena, data, strings_at + strings.size, diag);
    const top = try readDict(arena, top_dicts.items[0], diag);

    if (find(top, op_charstring_type)) |t| if (t.ints[0] != 2) return fail(diag, "only Type 2 charstrings are supported");
    const cs_entry = find(top, op_charstrings) orelse return fail(diag, "the CFF font has no CharStrings");
    if (cs_entry.ints[0] <= 0) return fail(diag, "the CFF font's CharStrings offset is invalid");
    const charstrings = try readIndex(arena, data, @intCast(cs_entry.ints[0]), diag);
    const num_glyphs = charstrings.items.len;
    if (num_glyphs != keep.len) return fail(diag, "the CFF font and 'maxp' disagree on the number of glyphs");

    const cid = find(top, op_ros) != null;
    // Each font DICT's Private DICT; one for a name-keyed font.
    var font_dicts: []const []const u8 = &.{};
    var fd_dict_entries: [][]Entry = &.{};
    var privates: []Private = undefined;
    var fd_select_at: usize = 0;
    if (cid) {
        const fda = find(top, op_fd_array) orelse return fail(diag, "a CID-keyed CFF font has no FDArray");
        const fds = find(top, op_fd_select) orelse return fail(diag, "a CID-keyed CFF font has no FDSelect");
        if (fda.ints[0] <= 0 or fds.ints[0] <= 0) return fail(diag, "the CFF font's FDArray or FDSelect offset is invalid");
        font_dicts = (try readIndex(arena, data, @intCast(fda.ints[0]), diag)).items;
        fd_select_at = @intCast(fds.ints[0]);
        _ = try fdSelectSize(data, fd_select_at, num_glyphs, diag);
        fd_dict_entries = try arena.alloc([]Entry, font_dicts.len);
        privates = try arena.alloc(Private, font_dicts.len);
        for (font_dicts, fd_dict_entries, privates) |fd, *entries, *priv| {
            entries.* = try readDict(arena, fd, diag);
            const p = find(entries.*, op_private) orelse return fail(diag, "a font DICT has no Private DICT");
            priv.* = try readPrivate(arena, data, p.ints[0], p.ints[1], diag);
        }
    } else {
        privates = try arena.alloc(Private, 1);
        privates[0] = if (find(top, op_private)) |p|
            try readPrivate(arena, data, p.ints[0], p.ints[1], diag)
        else
            .{ .entries = &.{}, .subrs = &.{} };
    }

    // Walk the kept glyphs' charstrings for the subroutines they call.
    const locals = try arena.alloc([]const []const u8, privates.len);
    const locals_used = try arena.alloc([]bool, privates.len);
    for (privates, locals, locals_used) |p, *l, *u| {
        l.* = p.subrs;
        u.* = try arena.alloc(bool, p.subrs.len);
        @memset(u.*, false);
    }
    const global_used = try arena.alloc(bool, gsubrs.items.len);
    @memset(global_used, false);
    var w: Walker = .{ .arena = arena, .diag = diag, .global = gsubrs.items, .global_used = global_used, .locals = locals, .locals_used = locals_used };
    for (keep, 0..) |k, g| {
        if (!k) continue;
        const fd = if (cid) fdOf(data, fd_select_at, g) else 0;
        if (fd >= privates.len) return fail(diag, "FDSelect names a font DICT that does not exist");
        try w.glyph(charstrings.items[g], fd);
    }
    if (w.seac) {
        // seac's parts are found through the standard encoding; keep it
        // simple and keep every glyph and subroutine.
        @memset(keep, true);
        @memset(global_used, true);
        for (locals_used) |u| @memset(u, true);
    }

    const endchar: []const u8 = &.{14};
    const ret: []const u8 = &.{11};
    const new_cs = try arena.alloc([]const u8, num_glyphs);
    for (new_cs, charstrings.items, keep) |*n, old, k| n.* = if (k) old else endchar;
    const new_gsubrs = try arena.alloc([]const u8, gsubrs.items.len);
    for (new_gsubrs, gsubrs.items, global_used) |*n, old, used| n.* = if (used) old else ret;
    const new_locals = try arena.alloc([]const []const u8, privates.len);
    for (new_locals, locals, locals_used) |*n, old, used| {
        const list = try arena.alloc([]const u8, old.len);
        for (list, old, used) |*x, o, u| x.* = if (u) o else ret;
        n.* = list;
    }

    // The parts copied unchanged.
    const charset_e = find(top, op_charset);
    const charset_data: ?[]const u8 = if (charset_e) |c| (if (c.ints[0] > 2) blk: {
        const at: usize = @intCast(c.ints[0]);
        break :blk data[at..][0..try charsetSize(data, at, num_glyphs, diag)];
    } else null) else null;
    const encoding_e = find(top, op_encoding);
    const encoding_data: ?[]const u8 = if (encoding_e) |e| (if (e.ints[0] > 1 and !cid) blk: {
        const at: usize = @intCast(e.ints[0]);
        break :blk data[at..][0..try encodingSize(data, at, diag)];
    } else null) else null;
    const fd_select_data: ?[]const u8 = if (cid) data[fd_select_at..][0..try fdSelectSize(data, fd_select_at, num_glyphs, diag)] else null;

    // Private DICTs with their Subrs right after them.
    const private_bytes = try arena.alloc([]u8, privates.len);
    for (privates, new_locals, private_bytes) |p, subrs, *bytes| {
        const has_subrs = find(p.entries, op_subrs) != null;
        // Its size is fixed by the 5-byte operand, so the offset is too.
        const sized = try writeDict(arena, p.entries, &.{.{ .op = op_subrs, .values = &.{0} }});
        bytes.* = try writeDict(arena, p.entries, &.{.{ .op = op_subrs, .values = &.{@intCast(sized.len)} }});
        if (has_subrs) {
            var all: std.ArrayList(u8) = .empty;
            try all.appendSlice(arena, bytes.*);
            try writeIndex(arena, &all, subrs);
            bytes.* = all.items;
        }
    }
    const private_dict_sizes = try arena.alloc(usize, privates.len);
    for (privates, private_dict_sizes) |p, *s| s.* = (try writeDict(arena, p.entries, &.{.{ .op = op_subrs, .values = &.{0} }})).len;

    // Layout, with every offset written as a 5-byte integer so that the
    // Top DICT's size does not depend on the offsets in it.
    const placeholder = [_]i32{ 0, 0 };
    var reps: std.ArrayList(Replace) = .empty;
    if (charset_data != null) try reps.append(arena, .{ .op = op_charset, .values = placeholder[0..1] });
    if (encoding_data != null) try reps.append(arena, .{ .op = op_encoding, .values = placeholder[0..1] });
    try reps.append(arena, .{ .op = op_charstrings, .values = placeholder[0..1] });
    if (cid) {
        try reps.append(arena, .{ .op = op_fd_array, .values = placeholder[0..1] });
        try reps.append(arena, .{ .op = op_fd_select, .values = placeholder[0..1] });
    } else if (find(top, op_private) != null) {
        try reps.append(arena, .{ .op = op_private, .values = &placeholder });
    }
    const top_size = (try writeDict(arena, top, reps.items)).len;

    // The INDEXes are written again, with the smallest offsets that fit.
    var at: usize = hdr_size + indexSize(names.items) + indexSize(&.{try arena.alloc(u8, top_size)}) + indexSize(strings.items) + indexSize(new_gsubrs);
    const charset_at = at;
    if (charset_data) |c| at += c.len;
    const encoding_at = at;
    if (encoding_data) |e| at += e.len;
    const charstrings_at = at;
    at += indexSize(new_cs);
    const fd_select_out = at;
    if (fd_select_data) |f| at += f.len;
    // Font DICTs, each pointing at its Private DICT.
    const fd_array_at = at;
    var private_at = at;
    if (cid) {
        const sized = try arena.alloc([]const u8, font_dicts.len);
        for (fd_dict_entries, sized) |e, *s| s.* = try writeDict(arena, e, &.{.{ .op = op_private, .values = &placeholder }});
        private_at += indexSize(sized);
    }
    const private_ats = try arena.alloc(usize, privates.len);
    for (private_ats, private_bytes) |*pa, bytes| {
        pa.* = private_at;
        private_at += bytes.len;
    }

    for (reps.items) |*r| {
        const vals = try arena.alloc(i32, r.values.len);
        switch (r.op) {
            op_charset => vals[0] = @intCast(charset_at),
            op_encoding => vals[0] = @intCast(encoding_at),
            op_charstrings => vals[0] = @intCast(charstrings_at),
            op_fd_array => vals[0] = @intCast(fd_array_at),
            op_fd_select => vals[0] = @intCast(fd_select_out),
            op_private => {
                vals[0] = @intCast(private_dict_sizes[0]);
                vals[1] = @intCast(private_ats[0]);
            },
            else => unreachable,
        }
        r.values = vals;
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, data[0..hdr_size]);
    try writeIndex(arena, &out, names.items);
    try writeIndex(arena, &out, &.{try writeDict(arena, top, reps.items)});
    try writeIndex(arena, &out, strings.items);
    try writeIndex(arena, &out, new_gsubrs);
    if (charset_data) |c| try out.appendSlice(arena, c);
    if (encoding_data) |e| try out.appendSlice(arena, e);
    std.debug.assert(out.items.len == charstrings_at);
    try writeIndex(arena, &out, new_cs);
    if (fd_select_data) |f| try out.appendSlice(arena, f);
    if (cid) {
        const dicts = try arena.alloc([]const u8, font_dicts.len);
        for (fd_dict_entries, dicts, private_dict_sizes, private_ats) |e, *d, size, pa| {
            d.* = try writeDict(arena, e, &.{.{ .op = op_private, .values = &.{ @intCast(size), @intCast(pa) } }});
        }
        try writeIndex(arena, &out, dicts);
    }
    for (private_bytes) |bytes| try out.appendSlice(arena, bytes);
    return out.items;
}

const testing = std.testing;

fn int5(out: *std.ArrayList(u8), arena: Allocator, v: usize) !void {
    try out.append(arena, 29);
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(i32, @intCast(v))));
}

/// A small CFF table for tests: .notdef; 'A', with two stem hints, a hint
/// mask whose byte looks like `callsubr`, a call of local subroutine 0 and
/// of global subroutine 0; 'B', calling local subroutine 1; and a `seac`
/// glyph. With `cid`, a CID-keyed font whose second font DICT holds 'B'
/// and the seac glyph.
pub fn testCff(arena: Allocator, cid: bool) ![]u8 {
    const gsubrs = [_][]const u8{ &.{ 144, 144, 5, 11 }, &.{ 150, 150, 5, 11 } };
    const subrs0 = [_][]const u8{ &.{ 149, 159, 21, 11 }, &.{ 169, 179, 5, 11 }, &.{ 189, 189, 5, 11 } };
    const subrs1 = [_][]const u8{ &.{ 139, 139, 5, 11 }, &.{ 140, 140, 5, 11 } };
    const glyphs = [_][]const u8{
        &.{14},
        &.{ 139, 149, 159, 149, 1, 19, 10, 32, 10, 32, 29, 14 },
        &.{ 33, 10, 14 },
        &.{ 139, 139, 204, 205, 14 },
    };
    const privates: []const []const []const u8 = if (cid) &.{ &subrs0, &subrs1 } else &.{&subrs0};
    var name_idx: std.ArrayList(u8) = .empty;
    // Written with 4-byte offsets, which `subset` writes smaller.
    try name_idx.appendSlice(arena, &.{ 0, 1, 4, 0, 0, 0, 1, 0, 0, 0, 5 });
    try name_idx.appendSlice(arena, "Test");
    var gsubr_idx: std.ArrayList(u8) = .empty;
    try writeIndex(arena, &gsubr_idx, &gsubrs);
    var cs_idx: std.ArrayList(u8) = .empty;
    try writeIndex(arena, &cs_idx, &glyphs);
    // FDSelect format 3: glyphs 0-1 use font DICT 0, 2-3 font DICT 1.
    const fd_select = [_]u8{ 3, 0, 2, 0, 0, 0, 0, 2, 1, 0, 4 };
    // Private DICTs: Subrs (5-byte offset, so 6 bytes), then the Subrs.
    var private_blobs: std.ArrayList([]const u8) = .empty;
    for (privates) |subrs| {
        var p: std.ArrayList(u8) = .empty;
        try int5(&p, arena, 6);
        try p.append(arena, 19);
        try writeIndex(arena, &p, subrs);
        try private_blobs.append(arena, p.items);
    }
    // Two passes: the DICTs' sizes do not depend on the offsets in them.
    var offsets: [4]usize = .{ 0, 0, 0, 0 };
    var out: std.ArrayList(u8) = .empty;
    for (0..2) |_| {
        var top: std.ArrayList(u8) = .empty;
        if (cid) try top.appendSlice(arena, &.{ 139, 139, 139, 12, 30 });
        try int5(&top, arena, offsets[0]);
        try top.append(arena, 17);
        if (cid) {
            try int5(&top, arena, offsets[1]);
            try top.appendSlice(arena, &.{ 12, 37 });
            try int5(&top, arena, offsets[2]);
            try top.appendSlice(arena, &.{ 12, 36 });
        } else {
            try int5(&top, arena, 6);
            try int5(&top, arena, offsets[3]);
            try top.append(arena, 18);
        }
        out = .empty;
        try out.appendSlice(arena, &.{ 1, 0, 4, 4 });
        try out.appendSlice(arena, name_idx.items);
        try writeIndex(arena, &out, &.{top.items});
        try writeIndex(arena, &out, &.{});
        try out.appendSlice(arena, gsubr_idx.items);
        offsets[0] = out.items.len;
        try out.appendSlice(arena, cs_idx.items);
        if (cid) {
            offsets[1] = out.items.len;
            try out.appendSlice(arena, &fd_select);
            offsets[2] = out.items.len;
            // Font DICTs of 11 bytes: a 5-byte size, a 5-byte offset, op.
            const fd_size: []const u8 = &([_]u8{0} ** 11);
            var priv_at = out.items.len + indexSize(&.{ fd_size, fd_size });
            var fds: [2][]const u8 = undefined;
            for (&fds, private_blobs.items) |*fd, blob| {
                var d: std.ArrayList(u8) = .empty;
                try int5(&d, arena, 6);
                try int5(&d, arena, priv_at);
                try d.append(arena, 18);
                fd.* = d.items;
                priv_at += blob.len;
            }
            try writeIndex(arena, &out, &fds);
        } else {
            offsets[3] = out.items.len;
        }
        for (private_blobs.items) |blob| try out.appendSlice(arena, blob);
    }
    return out.items;
}

/// The charstrings, global subroutines and each Private DICT's local
/// subroutines of a CFF table.
const Parts = struct {
    charstrings: []const []const u8,
    gsubrs: []const []const u8,
    locals: []const []const []const u8,
};

fn readParts(arena: Allocator, data: []const u8) !Parts {
    var diag: Diagnostic = .{};
    const names = try readIndex(arena, data, data[2], &diag);
    const tops = try readIndex(arena, data, data[2] + names.size, &diag);
    const strings = try readIndex(arena, data, data[2] + names.size + tops.size, &diag);
    const gsubrs = try readIndex(arena, data, data[2] + names.size + tops.size + strings.size, &diag);
    const top = try readDict(arena, tops.items[0], &diag);
    const cs = try readIndex(arena, data, @intCast(find(top, op_charstrings).?.ints[0]), &diag);
    var locals: std.ArrayList([]const []const u8) = .empty;
    if (find(top, op_fd_array)) |fda| {
        for ((try readIndex(arena, data, @intCast(fda.ints[0]), &diag)).items) |fd| {
            const p = find(try readDict(arena, fd, &diag), op_private).?;
            try locals.append(arena, (try readPrivate(arena, data, p.ints[0], p.ints[1], &diag)).subrs);
        }
    } else {
        const p = find(top, op_private).?;
        try locals.append(arena, (try readPrivate(arena, data, p.ints[0], p.ints[1], &diag)).subrs);
    }
    return .{ .charstrings = cs.items, .gsubrs = gsubrs.items, .locals = locals.items };
}

test "name-keyed: dropped glyphs draw nothing and unused subroutines return" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const font = try testCff(a, false);
    const before = try readParts(a, font);
    var diag: Diagnostic = .{};

    var keep = [_]bool{ true, true, false, false };
    const out = try subset(a, font, &keep, &diag);
    const parts = try readParts(a, out);
    try testing.expectEqualSlices(u8, before.charstrings[1], parts.charstrings[1]);
    try testing.expectEqualSlices(u8, &.{14}, parts.charstrings[2]);
    try testing.expectEqualSlices(u8, &.{14}, parts.charstrings[3]);
    // 'A' calls local 0 and global 0; the hint mask byte, 10, is not a call.
    try testing.expectEqualSlices(u8, before.locals[0][0], parts.locals[0][0]);
    try testing.expectEqualSlices(u8, &.{11}, parts.locals[0][1]);
    try testing.expectEqualSlices(u8, &.{11}, parts.locals[0][2]);
    try testing.expectEqualSlices(u8, before.gsubrs[0], parts.gsubrs[0]);
    try testing.expectEqualSlices(u8, &.{11}, parts.gsubrs[1]);
    try testing.expect(out.len < font.len);

    // 'B' alone keeps local 1 only.
    keep = .{ true, false, true, false };
    const b_only = try readParts(a, try subset(a, font, &keep, &diag));
    try testing.expectEqualSlices(u8, &.{11}, b_only.locals[0][0]);
    try testing.expectEqualSlices(u8, before.locals[0][1], b_only.locals[0][1]);
    try testing.expectEqualSlices(u8, &.{11}, b_only.gsubrs[0]);

    // A seac glyph keeps everything.
    keep = .{ true, false, false, true };
    const all = try readParts(a, try subset(a, font, &keep, &diag));
    try testing.expect(std.mem.allEqual(bool, &keep, true));
    for (before.charstrings, all.charstrings) |x, y| try testing.expectEqualSlices(u8, x, y);
    for (before.locals[0], all.locals[0]) |x, y| try testing.expectEqualSlices(u8, x, y);
    for (before.gsubrs, all.gsubrs) |x, y| try testing.expectEqualSlices(u8, x, y);
}

test "CID-keyed: each font DICT's subroutines are kept apart" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const font = try testCff(a, true);
    const before = try readParts(a, font);
    var diag: Diagnostic = .{};
    var keep = [_]bool{ true, false, true, false };
    const parts = try readParts(a, try subset(a, font, &keep, &diag));
    // 'B' is in font DICT 1 and calls its subroutine 1.
    try testing.expectEqualSlices(u8, &.{11}, parts.locals[0][0]);
    try testing.expectEqualSlices(u8, &.{11}, parts.locals[1][0]);
    try testing.expectEqualSlices(u8, before.locals[1][1], parts.locals[1][1]);
    try testing.expectEqualSlices(u8, &.{14}, parts.charstrings[1]);
}

test "bad tables are reported" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    var keep = [_]bool{true};
    try testing.expectError(error.InvalidCff, subset(a, "\x02\x00\x04\x04", &keep, &diag));
    const font = try testCff(a, false);
    try testing.expectError(error.InvalidCff, subset(a, font, &keep, &diag));
    try testing.expectEqualStrings("the CFF font and 'maxp' disagree on the number of glyphs", diag.message);
    var four = [_]bool{ true, true, true, true };
    try testing.expectError(error.InvalidCff, subset(a, font[0 .. font.len - 10], &four, &diag));
}
