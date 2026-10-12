//! Font subsetting: makes a font file hold only the glyphs a site uses.
//!
//! Works on fonts with TrueType (`glyf`) or CFF outlines (see `cff.zig`),
//! in `.ttf`, `.otf` or `.woff` files. Glyph ids are kept, so every table
//! that refers to glyphs by id (`hmtx`, `GSUB`, `GPOS`, `kern`, ...) stays
//! valid; glyphs that are not needed simply have no outline. Needed glyphs
//! are those the kept characters map to, the parts of composite glyphs,
//! and whatever the `GSUB` substitutions (single, multiple, alternate and
//! ligature) can turn them into, so ligatures and alternates keep working.
//! The character map only lists the kept characters, and glyph names
//! (`post`) are dropped.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const cff = @import("cff.zig");
const woff2 = @import("woff2.zig");

pub const Error = Allocator.Error || error{ InvalidFont, UnsupportedFont };

pub const Diagnostic = struct { message: []const u8 = "" };

fn fail(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.InvalidFont;
}

fn unsupported(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.UnsupportedFont;
}

fn u16At(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .big);
}

fn u32At(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .big);
}

const Table = struct { tag: [4]u8, data: []const u8 };

/// A font's tables, from an sfnt (`.ttf`, `.otf`) or `.woff` file.
const Font = struct {
    flavor: u32,
    tables: []Table,

    fn get(f: Font, tag: *const [4]u8) ?[]const u8 {
        for (f.tables) |t| if (std.mem.eql(u8, &t.tag, tag)) return t.data;
        return null;
    }
};

fn checkRange(arena: Allocator, diag: *Diagnostic, bytes: []const u8, off: usize, len: usize) Error!void {
    if (off > bytes.len or len > bytes.len - off) return fail(arena, diag, "a table runs past the end of the file", .{});
}

fn readSfnt(arena: Allocator, bytes: []const u8, diag: *Diagnostic) Error!Font {
    if (bytes.len < 12) return fail(arena, diag, "the file is too short to be a font", .{});
    const n = u16At(bytes, 4);
    try checkRange(arena, diag, bytes, 12, @as(usize, n) * 16);
    const tables = try arena.alloc(Table, n);
    for (tables, 0..) |*t, i| {
        const rec = bytes[12 + i * 16 ..][0..16];
        const off = u32At(rec, 8);
        const len = u32At(rec, 12);
        try checkRange(arena, diag, bytes, off, len);
        t.* = .{ .tag = rec[0..4].*, .data = bytes[off..][0..len] };
    }
    return .{ .flavor = u32At(bytes, 0), .tables = tables };
}

fn readWoff(arena: Allocator, bytes: []const u8, diag: *Diagnostic) Error!Font {
    if (bytes.len < 44) return fail(arena, diag, "the file is too short to be a WOFF font", .{});
    const n = u16At(bytes, 12);
    try checkRange(arena, diag, bytes, 44, @as(usize, n) * 20);
    const tables = try arena.alloc(Table, n);
    for (tables, 0..) |*t, i| {
        const rec = bytes[44 + i * 20 ..][0..20];
        const off = u32At(rec, 4);
        const comp = u32At(rec, 8);
        const orig = u32At(rec, 12);
        try checkRange(arena, diag, bytes, off, comp);
        const raw = bytes[off..][0..comp];
        t.tag = rec[0..4].*;
        if (comp == orig) {
            t.data = raw;
        } else {
            var in: std.Io.Reader = .fixed(raw);
            var z: flate.Decompress = .init(&in, .zlib, &.{});
            const data = z.reader.allocRemaining(arena, .limited(orig + 1)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(arena, diag, "a WOFF table does not decompress", .{}),
            };
            if (data.len != orig) return fail(arena, diag, "a WOFF table has the wrong size", .{});
            t.data = data;
        }
    }
    return .{ .flavor = u32At(bytes, 4), .tables = tables };
}

pub const Format = enum { sfnt, woff };

/// The kind of font file, from its first bytes, or null.
pub fn format(bytes: []const u8) ?Format {
    if (bytes.len < 4) return null;
    const sig = bytes[0..4];
    if (std.mem.eql(u8, sig, "wOFF")) return .woff;
    if (std.mem.eql(u8, sig, "\x00\x01\x00\x00") or std.mem.eql(u8, sig, "true") or std.mem.eql(u8, sig, "OTTO")) return .sfnt;
    return null;
}

/// The TrueType, OpenType or WOFF font `bytes` as a WOFF2 file.
pub fn toWoff2(arena: Allocator, bytes: []const u8, diag: *Diagnostic) Error![]u8 {
    const font = switch (format(bytes) orelse return fail(arena, diag, "not a TrueType, OpenType or WOFF font", .{})) {
        .sfnt => try readSfnt(arena, bytes, diag),
        .woff => try readWoff(arena, bytes, diag),
    };
    const sfnt = try writeSfnt(arena, font.flavor, try arena.dupe(Table, font.tables));
    return woff2.fromSfnt(arena, sfnt) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFont => fail(arena, diag, "the font's table directory is invalid", .{}),
    };
}

/// `bytes` reduced to the glyphs for `chars`, in the same file format.
pub fn subset(arena: Allocator, bytes: []const u8, chars: []const u21, diag: *Diagnostic) Error![]u8 {
    const fmt = format(bytes) orelse {
        if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "wOF2")) return unsupported(arena, diag, "WOFF2 fonts cannot be subset; use the .ttf or .woff file", .{});
        return fail(arena, diag, "not a TrueType, OpenType or WOFF font", .{});
    };
    const font = switch (fmt) {
        .sfnt => try readSfnt(arena, bytes, diag),
        .woff => try readWoff(arena, bytes, diag),
    };
    if (font.get("CFF2") != null) return unsupported(arena, diag, "fonts with CFF2 outlines (variable OpenType fonts) cannot be subset", .{});
    // CFF outlines (most .otf files) instead of glyf and loca.
    const cff_data = font.get("CFF ");
    const head = font.get("head") orelse return fail(arena, diag, "the font has no 'head' table", .{});
    const maxp = font.get("maxp") orelse return fail(arena, diag, "the font has no 'maxp' table", .{});
    const loca = font.get("loca") orelse if (cff_data != null) "" else return fail(arena, diag, "the font has no 'loca' table", .{});
    const glyf = font.get("glyf") orelse if (cff_data != null) "" else return fail(arena, diag, "the font has no 'glyf' table", .{});
    const cmap = font.get("cmap") orelse return fail(arena, diag, "the font has no 'cmap' table", .{});
    if (head.len < 54 or maxp.len < 6) return fail(arena, diag, "the font's 'head' or 'maxp' table is too short", .{});
    const num_glyphs: usize = u16At(maxp, 4);
    const long_loca = std.mem.readInt(i16, head[50..52], .big) == 1;
    if (cff_data == null and loca.len < (num_glyphs + 1) * @as(usize, if (long_loca) 4 else 2)) return fail(arena, diag, "the font's 'loca' table is too short", .{});

    const glyphOffset = struct {
        fn at(l: []const u8, long: bool, i: usize) usize {
            return if (long) u32At(l, i * 4) else @as(usize, u16At(l, i * 2)) * 2;
        }
    }.at;

    // Which characters map to which glyphs.
    var map: std.AutoArrayHashMapUnmanaged(u21, u16) = .empty;
    try readCmap(arena, cmap, chars, &map, diag);

    // The glyphs to keep: .notdef, the mapped ones, their components, and
    // what GSUB can substitute for them.
    const keep = try arena.alloc(bool, num_glyphs);
    @memset(keep, false);
    keep[0] = true;
    for (map.values()) |g| if (g < num_glyphs) {
        keep[g] = true;
    };
    var changed = true;
    while (changed) {
        changed = false;
        // Composite glyphs need their components.
        if (cff_data == null) for (0..num_glyphs) |g| {
            if (!keep[g]) continue;
            const start = glyphOffset(loca, long_loca, g);
            const end = glyphOffset(loca, long_loca, g + 1);
            if (end <= start or end > glyf.len) continue;
            const data = glyf[start..end];
            if (data.len < 10 or std.mem.readInt(i16, data[0..2], .big) >= 0) continue;
            var p: usize = 10;
            while (p + 4 <= data.len) {
                const flags = u16At(data, p);
                const comp = u16At(data, p + 2);
                if (comp < num_glyphs and !keep[comp]) {
                    keep[comp] = true;
                    changed = true;
                }
                p += 4 + @as(usize, if (flags & 0x1 != 0) 4 else 2);
                if (flags & 0x8 != 0) p += 2 else if (flags & 0x40 != 0) p += 4 else if (flags & 0x80 != 0) p += 8;
                if (flags & 0x20 == 0) break;
            }
        };
        if (font.get("GSUB")) |gsub| {
            if (try gsubClosure(gsub, keep)) changed = true;
        }
    }

    // CFF outlines: dropped glyphs and unused subroutines are emptied.
    var new_cff: ?[]u8 = null;
    if (cff_data) |data| {
        var cd: cff.Diagnostic = .{};
        new_cff = cff.subset(arena, data, keep, &cd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidCff => return fail(arena, diag, "the font's 'CFF ' table is invalid: {s}", .{cd.message}),
        };
    }

    // Rebuild glyf and loca with empty slots for dropped glyphs.
    var new_glyf: std.ArrayList(u8) = .empty;
    const offsets = try arena.alloc(u32, num_glyphs + 1);
    if (cff_data == null) for (0..num_glyphs) |g| {
        offsets[g] = @intCast(new_glyf.items.len);
        if (!keep[g]) continue;
        const start = glyphOffset(loca, long_loca, g);
        const end = glyphOffset(loca, long_loca, g + 1);
        if (end <= start or end > glyf.len) continue;
        try new_glyf.appendSlice(arena, glyf[start..end]);
        // Short loca stores offsets divided by two.
        if (new_glyf.items.len % 2 != 0) try new_glyf.append(arena, 0);
    };
    offsets[num_glyphs] = @intCast(new_glyf.items.len);
    var new_loca: std.ArrayList(u8) = .empty;
    if (cff_data == null) for (offsets) |o| {
        if (long_loca) {
            try new_loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, o)));
        } else {
            try new_loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u16, @intCast(o / 2))));
        }
    };

    const new_cmap = try writeCmap(arena, &map);
    // post format 3: metrics only, no glyph names.
    var new_post: ?[]u8 = null;
    if (font.get("post")) |post| if (post.len >= 32) {
        const p = try arena.dupe(u8, post[0..32]);
        std.mem.writeInt(u32, p[0..4], 0x00030000, .big);
        new_post = p;
    };

    var out_tables: std.ArrayList(Table) = .empty;
    for (font.tables) |t| {
        const tag = &t.tag;
        // A digital signature no longer matches the changed font.
        if (std.mem.eql(u8, tag, "DSIG")) continue;
        const data: []const u8 = if (std.mem.eql(u8, tag, "glyf")) new_glyf.items else if (std.mem.eql(u8, tag, "loca")) new_loca.items else if (std.mem.eql(u8, tag, "CFF ")) new_cff.? else if (std.mem.eql(u8, tag, "cmap")) new_cmap else if (std.mem.eql(u8, tag, "post") and new_post != null) new_post.? else if (std.mem.eql(u8, tag, "head")) try arena.dupe(u8, t.data) else t.data;
        try out_tables.append(arena, .{ .tag = t.tag, .data = data });
    }
    std.mem.sort(Table, out_tables.items, {}, struct {
        fn lt(_: void, a: Table, b: Table) bool {
            return std.mem.lessThan(u8, &a.tag, &b.tag);
        }
    }.lt);
    const sfnt = try writeSfnt(arena, font.flavor, out_tables.items);
    return switch (fmt) {
        .sfnt => sfnt,
        .woff => try writeWoff(arena, sfnt, font.flavor),
    };
}

/// Adds the glyphs of `chars` from the best Unicode subtable of `cmap`.
fn readCmap(arena: Allocator, cmap: []const u8, chars: []const u21, map: *std.AutoArrayHashMapUnmanaged(u21, u16), diag: *Diagnostic) Error!void {
    if (cmap.len < 4) return fail(arena, diag, "the font's 'cmap' table is too short", .{});
    const n = u16At(cmap, 2);
    var best: ?usize = null;
    var best_score: u8 = 0;
    for (0..n) |i| {
        const rec = 4 + i * 8;
        if (rec + 8 > cmap.len) break;
        const platform = u16At(cmap, rec);
        const encoding = u16At(cmap, rec + 2);
        const off = u32At(cmap, rec + 4);
        if (off + 2 > cmap.len) continue;
        const fmt = u16At(cmap, off);
        // Prefer full Unicode (format 12), then BMP (format 4).
        const score: u8 = if (fmt == 12 and (platform == 3 and encoding == 10 or platform == 0)) 3 else if (fmt == 4 and (platform == 3 and encoding == 1 or platform == 0)) 2 else 0;
        if (score > best_score) {
            best_score = score;
            best = off;
        }
    }
    const off = best orelse return unsupported(arena, diag, "the font has no Unicode character map", .{});
    const sub = cmap[off..];
    for (chars) |c| {
        const g = lookupGlyph(sub, c) orelse continue;
        if (g != 0) try map.put(arena, c, g);
    }
}

fn lookupGlyph(sub: []const u8, c: u21) ?u16 {
    switch (u16At(sub, 0)) {
        4 => {
            if (c > 0xFFFF or sub.len < 14) return null;
            const seg2 = u16At(sub, 6);
            const ends = 14;
            const starts = ends + seg2 + 2;
            const deltas = starts + seg2;
            const ranges = deltas + seg2;
            if (ranges + seg2 > sub.len) return null;
            var s: usize = 0;
            while (s < seg2) : (s += 2) {
                const end = u16At(sub, ends + s);
                if (c > end) continue;
                const start = u16At(sub, starts + s);
                if (c < start) return null;
                const delta = u16At(sub, deltas + s);
                const range = u16At(sub, ranges + s);
                if (range == 0) return @truncate(@as(u32, c) +% delta);
                const at = ranges + s + range + 2 * (@as(usize, c) - start);
                if (at + 2 > sub.len) return null;
                const g = u16At(sub, at);
                return if (g == 0) 0 else @truncate(@as(u32, g) +% delta);
            }
            return null;
        },
        12 => {
            if (sub.len < 16) return null;
            const groups = u32At(sub, 12);
            var lo: usize = 0;
            var hi: usize = groups;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const rec = 16 + mid * 12;
                if (rec + 12 > sub.len) return null;
                const start = u32At(sub, rec);
                const end = u32At(sub, rec + 4);
                if (c < start) {
                    hi = mid;
                } else if (c > end) {
                    lo = mid + 1;
                } else return @truncate(u32At(sub, rec + 8) + (c - start));
            }
            return null;
        },
        else => return null,
    }
}

/// A cmap with a format 4 subtable for the Basic Multilingual Plane and,
/// when needed, a format 12 one for everything.
fn writeCmap(arena: Allocator, map: *std.AutoArrayHashMapUnmanaged(u21, u16)) Allocator.Error![]u8 {
    const Pair = struct { c: u21, g: u16 };
    var pairs: std.ArrayList(Pair) = .empty;
    var it = map.iterator();
    while (it.next()) |e| try pairs.append(arena, .{ .c = e.key_ptr.*, .g = e.value_ptr.* });
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.c < b.c;
        }
    }.lt);
    var astral = false;
    for (pairs.items) |p| astral = astral or p.c > 0xFFFF;

    // Format 4: one segment per run of characters whose glyph ids rise in
    // step, plus the closing 0xFFFF segment.
    const Seg = struct { start: u16, end: u16, delta: u16 };
    var segs: std.ArrayList(Seg) = .empty;
    for (pairs.items) |p| {
        if (p.c > 0xFFFF) break;
        const c: u16 = @intCast(p.c);
        const delta: u16 = p.g -% c;
        if (segs.items.len > 0) {
            const last = &segs.items[segs.items.len - 1];
            if (last.end + 1 == c and last.delta == delta) {
                last.end = c;
                continue;
            }
        }
        try segs.append(arena, .{ .start = c, .end = c, .delta = delta });
    }
    try segs.append(arena, .{ .start = 0xFFFF, .end = 0xFFFF, .delta = 1 });
    var f4: std.ArrayList(u8) = .empty;
    const seg_count: u16 = @intCast(segs.items.len);
    var search: u16 = 1;
    var selector: u16 = 0;
    while (search * 2 <= seg_count) : (selector += 1) search *= 2;
    const put16 = struct {
        fn f(a: Allocator, l: *std.ArrayList(u8), v: u16) Allocator.Error!void {
            try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u16, v)));
        }
    }.f;
    const put32 = struct {
        fn f(a: Allocator, l: *std.ArrayList(u8), v: u32) Allocator.Error!void {
            try l.appendSlice(a, &std.mem.toBytes(std.mem.nativeToBig(u32, v)));
        }
    }.f;
    try put16(arena, &f4, 4);
    try put16(arena, &f4, @intCast(16 + 8 * @as(usize, seg_count)));
    try put16(arena, &f4, 0);
    try put16(arena, &f4, seg_count * 2);
    try put16(arena, &f4, search * 2);
    try put16(arena, &f4, selector);
    try put16(arena, &f4, seg_count * 2 - search * 2);
    for (segs.items) |s| try put16(arena, &f4, s.end);
    try put16(arena, &f4, 0);
    for (segs.items) |s| try put16(arena, &f4, s.start);
    for (segs.items) |s| try put16(arena, &f4, s.delta);
    for (segs.items) |_| try put16(arena, &f4, 0);

    var f12: std.ArrayList(u8) = .empty;
    if (astral) {
        var groups: std.ArrayList([3]u32) = .empty;
        for (pairs.items) |p| {
            if (groups.items.len > 0) {
                const last = &groups.items[groups.items.len - 1];
                if (last[1] + 1 == p.c and last[2] + (p.c - last[0]) == p.g) {
                    last[1] = p.c;
                    continue;
                }
            }
            try groups.append(arena, .{ p.c, p.c, p.g });
        }
        try put16(arena, &f12, 12);
        try put16(arena, &f12, 0);
        try put32(arena, &f12, @intCast(16 + 12 * groups.items.len));
        try put32(arena, &f12, 0);
        try put32(arena, &f12, @intCast(groups.items.len));
        for (groups.items) |g| for (g) |v| try put32(arena, &f12, v);
    }

    var out: std.ArrayList(u8) = .empty;
    const subtables: u16 = if (astral) 2 else 1;
    try put16(arena, &out, 0);
    try put16(arena, &out, subtables);
    const header_len: u32 = 4 + 8 * @as(u32, subtables);
    try put16(arena, &out, 3);
    try put16(arena, &out, 1);
    try put32(arena, &out, header_len);
    if (astral) {
        try put16(arena, &out, 3);
        try put16(arena, &out, 10);
        try put32(arena, &out, header_len + @as(u32, @intCast(f4.items.len)));
    }
    try out.appendSlice(arena, f4.items);
    try out.appendSlice(arena, f12.items);
    return out.items;
}

/// Coverage table: the coverage index of `g`, or null.
fn coverageIndex(t: []const u8, off: usize, g: u16) ?usize {
    if (off + 4 > t.len) return null;
    const cov = t[off..];
    const count = u16At(cov, 2);
    switch (u16At(cov, 0)) {
        1 => for (0..count) |i| {
            if (4 + i * 2 + 2 > cov.len) return null;
            if (u16At(cov, 4 + i * 2) == g) return i;
        },
        2 => for (0..count) |i| {
            const r = 4 + i * 6;
            if (r + 6 > cov.len) return null;
            const start = u16At(cov, r);
            const end = u16At(cov, r + 2);
            if (g >= start and g <= end) return u16At(cov, r + 4) + (g - start);
        },
        else => {},
    }
    return null;
}

/// Adds to `keep` every glyph GSUB's single, multiple, alternate and
/// ligature substitutions can produce from kept glyphs. Returns whether
/// anything was added.
fn gsubClosure(gsub: []const u8, keep: []bool) Allocator.Error!bool {
    if (gsub.len < 10) return false;
    const lookups: usize = u16At(gsub, 8);
    if (lookups + 2 > gsub.len) return false;
    const count = u16At(gsub, lookups);
    var added = false;
    const add = struct {
        fn f(k: []bool, g: u16, flag: *bool) void {
            if (g < k.len and !k[g]) {
                k[g] = true;
                flag.* = true;
            }
        }
    }.f;
    for (0..count) |li| {
        if (lookups + 2 + li * 2 + 2 > gsub.len) break;
        const lookup: usize = lookups + u16At(gsub, lookups + 2 + li * 2);
        if (lookup + 6 > gsub.len) continue;
        var kind = u16At(gsub, lookup);
        const subs = u16At(gsub, lookup + 4);
        for (0..subs) |si| {
            if (lookup + 6 + si * 2 + 2 > gsub.len) break;
            var st: usize = lookup + u16At(gsub, lookup + 6 + si * 2);
            // Extension subtables point further on, with their real type.
            if (kind == 7) {
                if (st + 8 > gsub.len) continue;
                kind = u16At(gsub, st + 2);
                st += u32At(gsub, st + 4);
            }
            if (st + 6 > gsub.len) continue;
            const t = gsub;
            const cov = st + u16At(t, st + 2);
            for (0..keep.len) |gi| {
                if (!keep[gi]) continue;
                const g: u16 = @intCast(gi);
                const idx = coverageIndex(t, cov, g) orelse continue;
                switch (kind) {
                    1 => switch (u16At(t, st)) {
                        1 => add(keep, g +% u16At(t, st + 4), &added),
                        2 => if (st + 6 + idx * 2 + 2 <= t.len) add(keep, u16At(t, st + 6 + idx * 2), &added),
                        else => {},
                    },
                    2, 3 => {
                        // Multiple and alternate: a list of glyphs per input.
                        if (st + 6 + idx * 2 + 2 > t.len) continue;
                        const seq = st + u16At(t, st + 6 + idx * 2);
                        if (seq + 2 > t.len) continue;
                        const n = u16At(t, seq);
                        for (0..n) |k| if (seq + 2 + k * 2 + 2 <= t.len) add(keep, u16At(t, seq + 2 + k * 2), &added);
                    },
                    4 => {
                        if (st + 6 + idx * 2 + 2 > t.len) continue;
                        const set = st + u16At(t, st + 6 + idx * 2);
                        if (set + 2 > t.len) continue;
                        const n = u16At(t, set);
                        for (0..n) |k| {
                            if (set + 2 + k * 2 + 2 > t.len) break;
                            const lig = set + u16At(t, set + 2 + k * 2);
                            if (lig + 4 > t.len) continue;
                            const lig_glyph = u16At(t, lig);
                            const comps = u16At(t, lig + 2);
                            // A ligature is reachable when all its parts are.
                            const all = for (1..comps) |c| {
                                if (lig + 4 + (c - 1) * 2 + 2 > t.len) break false;
                                const part = u16At(t, lig + 4 + (c - 1) * 2);
                                if (part >= keep.len or !keep[part]) break false;
                            } else true;
                            if (all) add(keep, lig_glyph, &added);
                        }
                    },
                    else => {},
                }
            }
            kind = u16At(gsub, lookup);
        }
    }
    return added;
}

fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 4) {
        var word: [4]u8 = @splat(0);
        const n = @min(4, data.len - i);
        @memcpy(word[0..n], data[i..][0..n]);
        sum +%= std.mem.readInt(u32, &word, .big);
    }
    return sum;
}

fn writeSfnt(arena: Allocator, flavor: u32, tables: []Table) Allocator.Error![]u8 {
    const n: u16 = @intCast(tables.len);
    var search: u16 = 1;
    var selector: u16 = 0;
    while (search * 2 <= n) : (selector += 1) search *= 2;
    var size: usize = 12 + 16 * @as(usize, n);
    for (tables) |t| size += (t.data.len + 3) / 4 * 4;
    const out = try arena.alloc(u8, size);
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], flavor, .big);
    std.mem.writeInt(u16, out[4..6], n, .big);
    std.mem.writeInt(u16, out[6..8], search * 16, .big);
    std.mem.writeInt(u16, out[8..10], selector, .big);
    std.mem.writeInt(u16, out[10..12], n * 16 - search * 16, .big);
    var off: usize = 12 + 16 * @as(usize, n);
    var head_off: ?usize = null;
    for (tables, 0..) |t, i| {
        @memcpy(out[off..][0..t.data.len], t.data);
        if (std.mem.eql(u8, &t.tag, "head")) {
            head_off = off;
            // The adjustment is computed over the font with it set to 0.
            std.mem.writeInt(u32, out[off + 8 ..][0..4], 0, .big);
        }
        const rec = out[12 + i * 16 ..][0..16];
        @memcpy(rec[0..4], &t.tag);
        std.mem.writeInt(u32, rec[4..8], checksum(out[off..][0..t.data.len]), .big);
        std.mem.writeInt(u32, rec[8..12], @intCast(off), .big);
        std.mem.writeInt(u32, rec[12..16], @intCast(t.data.len), .big);
        off += (t.data.len + 3) / 4 * 4;
    }
    if (head_off) |h| std.mem.writeInt(u32, out[h + 8 ..][0..4], 0xB1B0AFBA -% checksum(out), .big);
    return out;
}

/// Wraps an sfnt font in WOFF 1.0, compressing each table with zlib when
/// that makes it smaller.
fn writeWoff(arena: Allocator, sfnt: []const u8, flavor: u32) Allocator.Error![]u8 {
    var diag: Diagnostic = .{};
    const font = readSfnt(arena, sfnt, &diag) catch return error.OutOfMemory;
    const n = font.tables.len;
    var body: std.ArrayList(u8) = .empty;
    const Entry = struct { tag: [4]u8, off: u32, comp: u32, orig: u32, sum: u32 };
    const entries = try arena.alloc(Entry, n);
    const header_len: u32 = @intCast(44 + 20 * n);
    for (font.tables, entries, 0..) |t, *e, i| {
        const rec = sfnt[12 + i * 16 ..][0..16];
        var compressed: std.Io.Writer.Allocating = try .initCapacity(arena, @max(64, t.data.len / 2));
        {
            // The compressor is too big for the stack.
            const window = try arena.alloc(u8, flate.max_window_len);
            const z = try arena.create(flate.Compress);
            z.* = flate.Compress.init(&compressed.writer, window, .zlib, .best) catch return error.OutOfMemory;
            z.writer.writeAll(t.data) catch return error.OutOfMemory;
            z.finish() catch return error.OutOfMemory;
        }
        const data = if (compressed.written().len < t.data.len) compressed.written() else t.data;
        e.* = .{ .tag = t.tag, .off = header_len + @as(u32, @intCast(body.items.len)), .comp = @intCast(data.len), .orig = @intCast(t.data.len), .sum = u32At(rec, 4) };
        try body.appendSlice(arena, data);
        while (body.items.len % 4 != 0) try body.append(arena, 0);
    }
    const total = header_len + body.items.len;
    const out = try arena.alloc(u8, total);
    @memset(out[0..header_len], 0);
    @memcpy(out[0..4], "wOFF");
    std.mem.writeInt(u32, out[4..8], flavor, .big);
    std.mem.writeInt(u32, out[8..12], @intCast(total), .big);
    std.mem.writeInt(u16, out[12..14], @intCast(n), .big);
    std.mem.writeInt(u32, out[16..20], @intCast(sfnt.len), .big);
    std.mem.writeInt(u16, out[20..22], 1, .big);
    for (entries, 0..) |e, i| {
        const rec = out[44 + i * 20 ..][0..20];
        @memcpy(rec[0..4], &e.tag);
        std.mem.writeInt(u32, rec[4..8], e.off, .big);
        std.mem.writeInt(u32, rec[8..12], e.comp, .big);
        std.mem.writeInt(u32, rec[12..16], e.orig, .big);
        std.mem.writeInt(u32, rec[16..20], e.sum, .big);
    }
    @memcpy(out[header_len..], body.items);
    return out;
}

/// The characters in the text of an HTML page, skipping markup, scripts
/// and styles, with character references decoded. Added to `set`.
pub fn collectText(arena: Allocator, html: []const u8, set: *std.AutoArrayHashMapUnmanaged(u21, void)) Allocator.Error!void {
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse return;
            const tag = html[i + 1 .. close];
            i = close + 1;
            for ([_][]const u8{ "script", "style" }) |raw| {
                if (tag.len >= raw.len and std.ascii.eqlIgnoreCase(tag[0..raw.len], raw)) {
                    const end_tag = if (raw.len == 6) "</script" else "</style";
                    i = std.ascii.indexOfIgnoreCasePos(html, i, end_tag) orelse html.len;
                }
            }
            continue;
        }
        if (c == '&') {
            const semi = std.mem.indexOfScalarPos(u8, html, i, ';');
            if (semi) |s| if (s - i <= 10) {
                const name = html[i + 1 .. s];
                const cp: ?u21 = if (name.len > 1 and name[0] == '#')
                    (if (name[1] == 'x' or name[1] == 'X') std.fmt.parseInt(u21, name[2..], 16) catch null else std.fmt.parseInt(u21, name[1..], 10) catch null)
                else for ([_]struct { []const u8, u21 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' }, .{ "nbsp", 0xA0 } }) |e| {
                    if (std.mem.eql(u8, name, e[0])) break e[1];
                } else null;
                if (cp) |v| {
                    try set.put(arena, v, {});
                    i = s + 1;
                    continue;
                }
            };
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch {
            i += 1;
            continue;
        };
        if (i + len > html.len) return;
        const cp = std.unicode.utf8Decode(html[i..][0..len]) catch {
            i += 1;
            continue;
        };
        if (cp >= 0x20) try set.put(arena, cp, {});
        i += len;
    }
}

const testing = std.testing;

/// A tiny TrueType font for tests: .notdef, 'A', 'B', a composite 'C'
/// made of 'A', and a ligature 'AB' reached through GSUB.
pub fn testFont(arena: Allocator) ![]u8 {
    const glyph_a = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 10, 0, 10, 0, 0, 0, 0, 1, 0 } ++ [_]u8{0xAA} ** 40;
    const glyph_b = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 10, 0, 10, 0, 0, 0, 0, 1, 0 } ++ [_]u8{0xBB} ** 40;
    // Composite: one component, glyph 1, byte offsets.
    const glyph_c = [_]u8{ 0xFF, 0xFF, 0, 0, 0, 0, 0, 10, 0, 10, 0x00, 0x02, 0x00, 0x01, 0, 0 };
    const glyph_lig = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 10, 0, 10, 0, 0, 0, 0, 1, 0 } ++ [_]u8{0xCC} ** 40;
    const glyphs = [_][]const u8{ "", &glyph_a, &glyph_b, &glyph_c, &glyph_lig };
    var glyf: std.ArrayList(u8) = .empty;
    var loca: std.ArrayList(u8) = .empty;
    for (glyphs) |g| {
        try loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(glyf.items.len))));
        try glyf.appendSlice(arena, g);
    }
    try loca.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(glyf.items.len))));
    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u32, head[0..4], 0x00010000, .big);
    std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
    std.mem.writeInt(i16, head[50..52], 1, .big); // long loca
    const maxp: [6]u8 = .{ 0, 0, 0x50, 0, 0, 5 };
    // cmap: A, B, C mapped through a format 4 subtable.
    var map: std.AutoArrayHashMapUnmanaged(u21, u16) = .empty;
    try map.put(arena, 'A', 1);
    try map.put(arena, 'B', 2);
    try map.put(arena, 'C', 3);
    const cmap = try writeCmap(arena, &map);
    // GSUB with one ligature lookup: A B -> glyph 4.
    const gsub = [_]u8{
        0, 1, 0, 0, // version
        0, 0, 0, 0, // script and feature lists (unused here)
        0, 10, // lookup list
        0, 1, 0, 4, // one lookup at +4
        0, 4, 0, 0, 0, 1, 0, 8, // type 4, flags, one subtable at +8
        0, 1, 0, 8, 0, 1, 0, 14, // format 1, coverage at +8, one ligature set at +14
        0, 1, 0, 1, 0, 1, // coverage: format 1, one glyph, glyph 1 (A)
        0, 1, 0, 4, // ligature set: one ligature at +4
        0, 4, 0, 2, 0, 2, // ligature glyph 4, two components, the second is glyph 2 (B)
    };
    var tables = [_]Table{
        .{ .tag = "GSUB".*, .data = &gsub },
        .{ .tag = "cmap".*, .data = cmap },
        .{ .tag = "glyf".*, .data = glyf.items },
        .{ .tag = "head".*, .data = &head },
        .{ .tag = "loca".*, .data = loca.items },
        .{ .tag = "maxp".*, .data = &maxp },
    };
    return writeSfnt(arena, 0x00010000, &tables);
}

fn glyphBytes(arena: Allocator, font_bytes: []const u8, g: usize) !usize {
    var diag: Diagnostic = .{};
    const f = if (format(font_bytes).? == .woff) try readWoff(arena, font_bytes, &diag) else try readSfnt(arena, font_bytes, &diag);
    const loca = f.get("loca").?;
    return u32At(loca, (g + 1) * 4) - u32At(loca, g * 4);
}

test "subsetting keeps used glyphs, their parts and reachable ligatures" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const font = try testFont(a);
    var diag: Diagnostic = .{};

    // Only "C": its component A stays, B and the ligature go.
    const c_only = try subset(a, font, &.{'C'}, &diag);
    try testing.expect(c_only.len < font.len);
    try testing.expect(try glyphBytes(a, c_only, 1) > 0);
    try testing.expectEqual(@as(usize, 0), try glyphBytes(a, c_only, 2));
    try testing.expect(try glyphBytes(a, c_only, 3) > 0);
    try testing.expectEqual(@as(usize, 0), try glyphBytes(a, c_only, 4));

    // "AB": both, and the ligature they can form.
    const ab = try subset(a, font, &.{ 'A', 'B' }, &diag);
    try testing.expect(try glyphBytes(a, ab, 4) > 0);
    try testing.expectEqual(@as(usize, 0), try glyphBytes(a, ab, 3));

    // The new character map knows only the kept characters, and the file's
    // checksum adjustment is right.
    const f = try readSfnt(a, ab, &diag);
    const sub = f.get("cmap").?[u32At(f.get("cmap").?, 8)..];
    try testing.expectEqual(@as(?u16, 1), lookupGlyph(sub, 'A'));
    try testing.expectEqual(@as(?u16, null), lookupGlyph(sub, 'C'));
    try testing.expectEqual(@as(u32, 0xB1B0AFBA), checksum(ab));

    // WOFF in, WOFF out.
    const woff = try writeWoff(a, font, 0x00010000);
    const woff_sub = try subset(a, woff, &.{'A'}, &diag);
    try testing.expectEqual(Format.woff, format(woff_sub).?);
    try testing.expectEqual(@as(usize, 0), try glyphBytes(a, woff_sub, 2));
}

/// An OpenType font with CFF outlines for tests, around `cff.testCff`:
/// 'A', 'B' and a seac glyph mapped from 'C'.
pub fn testCffFont(arena: Allocator) ![]u8 {
    var head: [54]u8 = @splat(0);
    std.mem.writeInt(u32, head[0..4], 0x00010000, .big);
    std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
    // maxp version 0.5, as CFF fonts have it: only the glyph count.
    const maxp: [6]u8 = .{ 0, 0, 0x50, 0, 0, 4 };
    var map: std.AutoArrayHashMapUnmanaged(u21, u16) = .empty;
    try map.put(arena, 'A', 1);
    try map.put(arena, 'B', 2);
    try map.put(arena, 'C', 3);
    var tables = [_]Table{
        .{ .tag = "CFF ".*, .data = try cff.testCff(arena, false) },
        .{ .tag = "cmap".*, .data = try writeCmap(arena, &map) },
        .{ .tag = "head".*, .data = &head },
        .{ .tag = "maxp".*, .data = &maxp },
    };
    return writeSfnt(arena, 0x4F54544F, &tables);
}

test "CFF outlines are subset too" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const font = try testCffFont(a);
    var diag: Diagnostic = .{};
    const out = try subset(a, font, &.{'A'}, &diag);
    try testing.expect(out.len < font.len);
    const f = try readSfnt(a, out, &diag);
    // 'B' (glyph 2) now draws nothing; the table is otherwise intact.
    const before = try readSfnt(a, font, &diag);
    try testing.expect(f.get("CFF ").?.len < before.get("CFF ").?.len);
    var keep = [_]bool{ true, true, false, false };
    var cd: cff.Diagnostic = .{};
    try testing.expectEqualSlices(u8, f.get("CFF ").?, try cff.subset(a, before.get("CFF ").?, &keep, &cd));
    // WOFF too.
    const woff = try subset(a, try writeWoff(a, font, 0x4F54544F), &.{'A'}, &diag);
    try testing.expectEqual(Format.woff, format(woff).?);
}

test "unsupported fonts are reported" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    try testing.expectError(error.UnsupportedFont, subset(a, "wOF2xxxx", &.{}, &diag));
    try testing.expectError(error.InvalidFont, subset(a, "nope", &.{}, &diag));
    var tables = [_]Table{.{ .tag = "CFF2".*, .data = "" }};
    try testing.expectError(error.UnsupportedFont, subset(a, try writeSfnt(a, 0x4F54544F, &tables), &.{}, &diag));
}

test "collectText reads page text and references, not markup" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var set: std.AutoArrayHashMapUnmanaged(u21, void) = .empty;
    try collectText(a, "<p class=\"zz\">Hé &amp; &#x2192;</p><script>QQ</script><style>.W{}</style>", &set);
    try testing.expect(set.contains('H') and set.contains(0xE9) and set.contains('&') and set.contains(0x2192));
    try testing.expect(!set.contains('z') and !set.contains('Q') and !set.contains('W'));
}
