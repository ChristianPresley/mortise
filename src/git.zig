//! Last-changed dates from a Git repository, read straight from `.git`.
//!
//! Mortise runs no external programs, so this reads the object database
//! itself: loose objects and pack files (version 2 indexes, offset and
//! reference deltas), refs and `packed-refs`, and linked worktrees whose
//! `.git` is a file. Objects are inflated with the standard library's zlib
//! decoder.
//!
//! `lastChanged` walks the first-parent history from `HEAD`, newest first,
//! and gives each wanted file the committer date (in the committer's own
//! time zone) of the newest commit whose tree changed it. Only the trees on
//! changed paths are read, so the walk stays cheap. A shallow clone stops
//! at its oldest commit, which then dates every file not changed since.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Error = error{
    /// The repository uses something this reader does not support, such
    /// as SHA-256 object names or a version 1 pack index.
    Unsupported,
    /// An object, ref or pack is malformed or missing.
    Corrupt,
} || Allocator.Error || Io.Dir.ReadFileAllocError;

pub const Oid = [20]u8;

const Kind = enum(u3) { commit = 1, tree = 2, blob = 3, tag = 4 };

const Object = struct { kind: Kind, data: []const u8 };

const Pack = struct {
    idx: []const u8,
    pack: []const u8,
    count: u32,
};

pub const Repo = struct {
    arena: Allocator,
    io: Io,
    /// The repository's (or worktree's) git directory: `HEAD`, worktree refs.
    git_dir: Io.Dir,
    /// The shared git directory: objects, refs, `packed-refs`.
    common_dir: Io.Dir,
    packs: []const Pack,
    window: []u8,
    /// Inflated pack objects by pack number and offset, so delta chains
    /// are resolved once.
    packed_cache: std.AutoHashMapUnmanaged(u64, Object) = .empty,

    pub fn close(r: *Repo) void {
        if (r.common_dir.handle != r.git_dir.handle) r.common_dir.close(r.io);
        r.git_dir.close(r.io);
    }
};

pub const Found = struct {
    repo: Repo,
    /// The site directory's path inside the repository, with `/`
    /// separators and no trailing slash; "" when the site is the
    /// repository root.
    prefix: []const u8,
};

/// Finds the repository holding `abs_dir` (an absolute path), searching
/// it and its parents for `.git`. Returns null when there is none.
pub fn discover(arena: Allocator, io: Io, abs_dir: []const u8) Error!?Found {
    var dir_path: []const u8 = abs_dir;
    while (true) {
        if (try openGitDir(arena, io, dir_path)) |git_dir| {
            const rest = std.mem.trim(u8, abs_dir[dir_path.len..], "/\\");
            const prefix = try arena.dupe(u8, rest);
            std.mem.replaceScalar(u8, prefix, '\\', '/');
            return .{ .repo = try openRepo(arena, io, git_dir), .prefix = prefix };
        }
        dir_path = std.fs.path.dirname(dir_path) orelse return null;
    }
}

/// Opens `<dir>/.git`: a directory, or a file reading `gitdir: PATH`.
fn openGitDir(arena: Allocator, io: Io, dir: []const u8) Error!?Io.Dir {
    const dot_git = try std.fs.path.join(arena, &.{ dir, ".git" });
    if (Io.Dir.cwd().openDir(io, dot_git, .{})) |d| return d else |_| {}
    const text = Io.Dir.cwd().readFileAlloc(io, dot_git, arena, .limited(4096)) catch return null;
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, line, "gitdir:")) return null;
    const target = std.mem.trim(u8, line["gitdir:".len..], " \t");
    const full = if (std.fs.path.isAbsolute(target)) target else try std.fs.path.join(arena, &.{ dir, target });
    return Io.Dir.cwd().openDir(io, full, .{}) catch null;
}

fn openRepo(arena: Allocator, io: Io, git_dir: Io.Dir) Error!Repo {
    var common_dir = git_dir;
    if (git_dir.readFileAlloc(io, "commondir", arena, .limited(4096))) |text| {
        const rel = std.mem.trim(u8, text, " \t\r\n");
        common_dir = git_dir.openDir(io, rel, .{}) catch return error.Corrupt;
    } else |_| {}
    var repo: Repo = .{
        .arena = arena,
        .io = io,
        .git_dir = git_dir,
        .common_dir = common_dir,
        .packs = &.{},
        .window = try arena.alloc(u8, flate.max_window_len),
    };
    repo.packs = try loadPacks(&repo);
    return repo;
}

fn loadPacks(r: *Repo) Error![]const Pack {
    var packs: std.ArrayList(Pack) = .empty;
    var dir = r.common_dir.openDir(r.io, "objects/pack", .{ .iterate = true }) catch return packs.items;
    defer dir.close(r.io);
    var it = dir.iterate();
    while (it.next(r.io) catch return error.Corrupt) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".idx")) continue;
        const stem = entry.name[0 .. entry.name.len - ".idx".len];
        const pack_name = try std.fmt.allocPrint(r.arena, "{s}.pack", .{stem});
        const idx = try dir.readFileAlloc(r.io, entry.name, r.arena, .limited(1 << 30));
        const pack = dir.readFileAlloc(r.io, pack_name, r.arena, .limited(1 << 31)) catch continue;
        if (idx.len < 8 + 256 * 4 or !std.mem.eql(u8, idx[0..4], "\xfftOc")) return error.Unsupported;
        if (std.mem.readInt(u32, idx[4..8], .big) != 2) return error.Unsupported;
        const count = std.mem.readInt(u32, idx[8 + 255 * 4 ..][0..4], .big);
        if (idx.len < 8 + 256 * 4 + @as(usize, count) * (20 + 4 + 4)) return error.Corrupt;
        try packs.append(r.arena, .{ .idx = idx, .pack = pack, .count = count });
    }
    return packs.items;
}

/// Resolves `HEAD` to a commit, or null in a repository without commits.
pub fn head(r: *Repo) Error!?Oid {
    return resolveRef(r, "HEAD", 0);
}

fn resolveRef(r: *Repo, name: []const u8, depth: usize) Error!?Oid {
    if (depth > 8) return error.Corrupt;
    const text = r.git_dir.readFileAlloc(r.io, name, r.arena, .limited(4096)) catch
        r.common_dir.readFileAlloc(r.io, name, r.arena, .limited(4096)) catch
        return packedRef(r, name);
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, line, "ref:")) return resolveRef(r, std.mem.trim(u8, line[4..], " \t"), depth + 1);
    return parseHex(line) orelse error.Corrupt;
}

fn packedRef(r: *Repo, name: []const u8) Error!?Oid {
    const text = r.common_dir.readFileAlloc(r.io, "packed-refs", r.arena, .limited(64 << 20)) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len < 42 or line[0] == '#' or line[0] == '^') continue;
        if (std.mem.eql(u8, line[41..], name)) return parseHex(line[0..40]);
    }
    return null;
}

pub fn parseHex(s: []const u8) ?Oid {
    if (s.len != 40) return null;
    var oid: Oid = undefined;
    _ = std.fmt.hexToBytes(&oid, s) catch return null;
    return oid;
}

/// Reads an object, or returns null when the repository does not have
/// it (beyond a shallow clone's boundary, for example).
fn readObject(r: *Repo, oid: Oid) Error!?Object {
    // Loose objects: objects/ab/cdef..., zlib-compressed "TYPE SIZE\0DATA".
    const hex = std.fmt.bytesToHex(oid, .lower);
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
    if (r.common_dir.readFileAlloc(r.io, path, r.arena, .limited(1 << 30))) |compressed| {
        const raw = try inflate(r, compressed);
        const nul = std.mem.indexOfScalar(u8, raw, 0) orelse return error.Corrupt;
        const space = std.mem.indexOfScalar(u8, raw[0..nul], ' ') orelse return error.Corrupt;
        const kind = std.meta.stringToEnum(Kind, raw[0..space]) orelse return error.Corrupt;
        return .{ .kind = kind, .data = raw[nul + 1 ..] };
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Corrupt,
    }
    for (r.packs, 0..) |p, i| {
        if (findInIndex(p, oid)) |offset| return try readPacked(r, i, offset);
    }
    return null;
}

fn findInIndex(p: Pack, oid: Oid) ?u64 {
    const fanout = p.idx[8..][0 .. 256 * 4];
    const hi = std.mem.readInt(u32, fanout[@as(usize, oid[0]) * 4 ..][0..4], .big);
    const lo = if (oid[0] == 0) 0 else std.mem.readInt(u32, fanout[(@as(usize, oid[0]) - 1) * 4 ..][0..4], .big);
    const names = p.idx[8 + 256 * 4 ..];
    var a: usize = lo;
    var b: usize = hi;
    while (a < b) {
        const mid = (a + b) / 2;
        switch (std.mem.order(u8, names[mid * 20 ..][0..20], &oid)) {
            .eq => {
                const offsets = names[@as(usize, p.count) * (20 + 4) ..];
                const off32 = std.mem.readInt(u32, offsets[mid * 4 ..][0..4], .big);
                if (off32 & 0x8000_0000 == 0) return off32;
                const large = offsets[@as(usize, p.count) * 4 ..];
                const k = off32 & 0x7fff_ffff;
                if (large.len < (k + 1) * 8) return null;
                return std.mem.readInt(u64, large[k * 8 ..][0..8], .big);
            },
            .lt => a = mid + 1,
            .gt => b = mid,
        }
    }
    return null;
}

fn readPacked(r: *Repo, pack_index: usize, offset: u64) Error!Object {
    const key = (@as(u64, pack_index) << 48) | offset;
    if (r.packed_cache.get(key)) |o| return o;
    const data = r.packs[pack_index].pack;
    if (offset >= data.len) return error.Corrupt;
    var pos: usize = @intCast(offset);
    var c = data[pos];
    pos += 1;
    const type_bits: u3 = @intCast((c >> 4) & 7);
    // The size is not needed: inflating stops at the end of the stream.
    while (c & 0x80 != 0) : (pos += 1) {
        if (pos >= data.len) return error.Corrupt;
        c = data[pos];
    }
    const obj: Object = switch (type_bits) {
        1, 2, 3, 4 => .{ .kind = @enumFromInt(type_bits), .data = try inflate(r, data[pos..]) },
        6 => blk: { // OFS_DELTA: base at a negative offset in this pack
            if (pos >= data.len) return error.Corrupt;
            c = data[pos];
            pos += 1;
            var back: u64 = c & 0x7f;
            while (c & 0x80 != 0) {
                if (pos >= data.len) return error.Corrupt;
                c = data[pos];
                pos += 1;
                back = ((back + 1) << 7) | (c & 0x7f);
            }
            if (back > offset) return error.Corrupt;
            const base = try readPacked(r, pack_index, offset - back);
            break :blk .{ .kind = base.kind, .data = try applyDelta(r.arena, base.data, try inflate(r, data[pos..])) };
        },
        7 => blk: { // REF_DELTA: base named by its object id
            if (pos + 20 > data.len) return error.Corrupt;
            const base = (try readObject(r, data[pos..][0..20].*)) orelse return error.Corrupt;
            break :blk .{ .kind = base.kind, .data = try applyDelta(r.arena, base.data, try inflate(r, data[pos + 20 ..])) };
        },
        else => return error.Corrupt,
    };
    try r.packed_cache.put(r.arena, key, obj);
    return obj;
}

fn inflate(r: *Repo, compressed: []const u8) Error![]const u8 {
    var in: Io.Reader = .fixed(compressed);
    var d: flate.Decompress = .init(&in, .zlib, r.window);
    return d.reader.allocRemaining(r.arena, .unlimited) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}

/// Applies a git delta (see gitformat-pack) to `base`.
fn applyDelta(arena: Allocator, base: []const u8, delta: []const u8) Error![]const u8 {
    var pos: usize = 0;
    const src_size = try varint(delta, &pos);
    const dst_size = try varint(delta, &pos);
    if (src_size != base.len) return error.Corrupt;
    var out: std.ArrayList(u8) = try .initCapacity(arena, @intCast(dst_size));
    while (pos < delta.len) {
        const op = delta[pos];
        pos += 1;
        if (op & 0x80 != 0) {
            var off: u64 = 0;
            var size: u64 = 0;
            inline for (0..4) |bit| {
                if (op & (1 << bit) != 0) {
                    if (pos >= delta.len) return error.Corrupt;
                    off |= @as(u64, delta[pos]) << (8 * bit);
                    pos += 1;
                }
            }
            inline for (0..3) |bit| {
                if (op & (0x10 << bit) != 0) {
                    if (pos >= delta.len) return error.Corrupt;
                    size |= @as(u64, delta[pos]) << (8 * bit);
                    pos += 1;
                }
            }
            if (size == 0) size = 0x10000;
            if (off + size > base.len) return error.Corrupt;
            try out.appendSlice(arena, base[@intCast(off)..][0..@intCast(size)]);
        } else if (op != 0) {
            if (pos + op > delta.len) return error.Corrupt;
            try out.appendSlice(arena, delta[pos..][0..op]);
            pos += op;
        } else return error.Corrupt;
    }
    if (out.items.len != dst_size) return error.Corrupt;
    return out.items;
}

fn varint(data: []const u8, pos: *usize) Error!u64 {
    var v: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len or shift > 56) return error.Corrupt;
        const c = data[pos.*];
        pos.* += 1;
        v |= @as(u64, c & 0x7f) << shift;
        if (c & 0x80 == 0) return v;
        shift += 7;
    }
}

const Commit = struct {
    tree: Oid,
    parent: ?Oid,
    /// `YYYY-MM-DD` of the committer date in the committer's time zone.
    date: [10]u8,
};

fn readCommit(r: *Repo, oid: Oid) Error!?Commit {
    const obj = (try readObject(r, oid)) orelse return null;
    if (obj.kind != .commit) return error.Corrupt;
    var commit: Commit = .{ .tree = undefined, .parent = null, .date = undefined };
    var have_tree = false;
    var have_date = false;
    var lines = std.mem.splitScalar(u8, obj.data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) break; // the message follows
        if (std.mem.startsWith(u8, line, "tree ")) {
            commit.tree = parseHex(line[5..]) orelse return error.Unsupported;
            have_tree = true;
        } else if (std.mem.startsWith(u8, line, "parent ") and commit.parent == null) {
            commit.parent = parseHex(line[7..]) orelse return error.Unsupported;
        } else if (std.mem.startsWith(u8, line, "committer ")) {
            commit.date = signatureDate(line) orelse return error.Corrupt;
            have_date = true;
        }
    }
    if (!have_tree or !have_date) return error.Corrupt;
    return commit;
}

/// The date of a `NAME <EMAIL> SECONDS +HHMM` signature, in its zone.
fn signatureDate(line: []const u8) ?[10]u8 {
    const gt = std.mem.lastIndexOfScalar(u8, line, '>') orelse return null;
    var it = std.mem.tokenizeScalar(u8, line[gt + 1 ..], ' ');
    const secs = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const tz = it.next() orelse "+0000";
    if (tz.len != 5) return null;
    const hours = std.fmt.parseInt(i64, tz[1..3], 10) catch return null;
    const mins = std.fmt.parseInt(i64, tz[3..5], 10) catch return null;
    const offset = (hours * 60 + mins) * 60 * @as(i64, if (tz[0] == '-') -1 else 1);
    const local: u64 = @intCast(@max(0, secs + offset));
    const day = (std.time.epoch.EpochSeconds{ .secs = local }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch return null;
    return out;
}

const TreeEntry = struct { name: []const u8, oid: Oid, is_tree: bool, is_file: bool };

fn readTree(r: *Repo, oid: Oid) Error![]const TreeEntry {
    const obj = (try readObject(r, oid)) orelse return error.Corrupt;
    if (obj.kind != .tree) return error.Corrupt;
    var entries: std.ArrayList(TreeEntry) = .empty;
    var pos: usize = 0;
    const d = obj.data;
    while (pos < d.len) {
        const space = std.mem.indexOfScalarPos(u8, d, pos, ' ') orelse return error.Corrupt;
        const nul = std.mem.indexOfScalarPos(u8, d, space, 0) orelse return error.Corrupt;
        if (nul + 21 > d.len) return error.Corrupt;
        const mode = d[pos..space];
        try entries.append(r.arena, .{
            .name = d[space + 1 .. nul],
            .oid = d[nul + 1 ..][0..20].*,
            .is_tree = std.mem.eql(u8, mode, "40000"),
            // Regular files and symlinks; not submodules (160000).
            .is_file = mode[0] == '1' and !std.mem.eql(u8, mode, "160000"),
        });
        pos = nul + 21;
    }
    return entries.items;
}

/// The tree at `prefix` (`a/b`) inside `root`, or null.
fn subtree(r: *Repo, root: Oid, prefix: []const u8) Error!?Oid {
    var cur = root;
    var it = std.mem.tokenizeScalar(u8, prefix, '/');
    outer: while (it.next()) |name| {
        for (try readTree(r, cur)) |e| {
            if (e.is_tree and std.mem.eql(u8, e.name, name)) {
                cur = e.oid;
                continue :outer;
            }
        }
        return null;
    }
    return cur;
}

pub const Options = struct {
    /// Stop once every one of these paths (relative to the prefix) has a
    /// date. Empty means date every file.
    wanted: []const []const u8 = &.{},
    /// Commits to walk at most.
    max_commits: usize = 100_000,
};

/// Maps paths under `prefix` (relative to it) to the `YYYY-MM-DD` date of
/// the newest first-parent commit that changed them.
pub fn lastChanged(r: *Repo, prefix: []const u8, options: Options) Error!std.StringHashMapUnmanaged([10]u8) {
    var dates: std.StringHashMapUnmanaged([10]u8) = .empty;
    var oid = (try head(r)) orelse return dates;
    var commit = (try readCommit(r, oid)) orelse return error.Corrupt;
    var tree = try subtree(r, commit.tree, prefix);
    var walked: usize = 0;
    while (walked < options.max_commits) : (walked += 1) {
        const parent: ?Commit = if (commit.parent) |p| try readCommit(r, p) else null;
        const parent_tree: ?Oid = if (parent) |p| try subtree(r, p.tree, prefix) else null;
        if (tree) |t| {
            const same = if (parent_tree) |pt| std.mem.eql(u8, &pt, &t) else false;
            if (!same) try diff(r, t, parent_tree, "", commit.date, &dates);
        }
        if (options.wanted.len > 0 and allDated(dates, options.wanted)) break;
        const p = parent orelse break;
        oid = commit.parent.?;
        commit = p;
        tree = parent_tree;
    }
    return dates;
}

fn allDated(dates: std.StringHashMapUnmanaged([10]u8), wanted: []const []const u8) bool {
    for (wanted) |w| if (!dates.contains(w)) return false;
    return true;
}

/// Dates every file in tree `new` that differs from tree `old` (null for
/// none), unless it already has a newer date.
fn diff(r: *Repo, new: Oid, old: ?Oid, dir: []const u8, date: [10]u8, dates: *std.StringHashMapUnmanaged([10]u8)) Error!void {
    const new_entries = try readTree(r, new);
    const old_entries: []const TreeEntry = if (old) |o| try readTree(r, o) else &.{};
    for (new_entries) |e| {
        if (!e.is_tree and !e.is_file) continue;
        var before: ?TreeEntry = null;
        for (old_entries) |o| {
            if (std.mem.eql(u8, o.name, e.name)) {
                before = o;
                break;
            }
        }
        if (before) |b| {
            if (b.is_tree == e.is_tree and std.mem.eql(u8, &b.oid, &e.oid)) continue;
        }
        const path = if (dir.len == 0) e.name else try std.fmt.allocPrint(r.arena, "{s}/{s}", .{ dir, e.name });
        if (e.is_tree) {
            const old_sub = if (before) |b| (if (b.is_tree) b.oid else null) else null;
            try diff(r, e.oid, old_sub, path, date, dates);
        } else {
            const gop = try dates.getOrPut(r.arena, path);
            if (!gop.found_existing) gop.value_ptr.* = date;
        }
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Test helper: writes a loose object the way git does and returns its id.
pub fn writeLoose(arena: Allocator, objects: Io.Dir, kind: []const u8, data: []const u8) !Oid {
    const header = try std.fmt.allocPrint(arena, "{s} {d}\x00", .{ kind, data.len });
    const raw = try std.mem.concat(arena, u8, &.{ header, data });
    var oid: Oid = undefined;
    std.crypto.hash.Sha1.hash(raw, &oid, .{});
    var aw: Io.Writer.Allocating = try .initCapacity(arena, 64);
    const window = try arena.alloc(u8, flate.max_window_len);
    var c: flate.Compress = try .init(&aw.writer, window, .zlib, .level_6);
    try c.writer.writeAll(raw);
    try c.finish();
    const hex = std.fmt.bytesToHex(oid, .lower);
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ hex[0..2], hex[2..] });
    try objects.createDirPath(testing.io, hex[0..2]);
    try objects.writeFile(testing.io, .{ .sub_path = path, .data = aw.written() });
    return oid;
}

/// Test helper: the data of a tree object.
pub fn treeData(arena: Allocator, entries: []const struct { []const u8, []const u8, Oid }) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try out.print(arena, "{s} {s}\x00", .{ e[0], e[1] });
        try out.appendSlice(arena, &e[2]);
    }
    return out.items;
}

test "lastChanged dates files by the newest commit that changed them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDirPath(io, "repo/.git/objects");
    try tmp.dir.createDirPath(io, "repo/.git/refs/heads");
    try tmp.dir.createDirPath(io, "repo/site/docs");
    var objects = try tmp.dir.openDir(io, "repo/.git/objects", .{});
    defer objects.close(io);

    // Commit 1 (2024-01-01): site/a.md, site/docs/b.md, other.txt.
    const a1 = try writeLoose(a, objects, "blob", "a1");
    const b1 = try writeLoose(a, objects, "blob", "b1");
    const docs1 = try writeLoose(a, objects, "tree", try treeData(a, &.{.{ "100644", "b.md", b1 }}));
    const site1 = try writeLoose(a, objects, "tree", try treeData(a, &.{ .{ "100644", "a.md", a1 }, .{ "40000", "docs", docs1 } }));
    const other = try writeLoose(a, objects, "blob", "o");
    const root1 = try writeLoose(a, objects, "tree", try treeData(a, &.{ .{ "100644", "other.txt", other }, .{ "40000", "site", site1 } }));
    const c1 = try writeLoose(a, objects, "commit", try std.fmt.allocPrint(a, "tree {x}\nauthor A <a@x> 1704110400 +0000\ncommitter A <a@x> 1704110400 +0000\n\none\n", .{&root1}));

    // Commit 2 (2024-02-01, but 2024-01-31 in UTC-10): only docs/b.md.
    const b2 = try writeLoose(a, objects, "blob", "b2");
    const docs2 = try writeLoose(a, objects, "tree", try treeData(a, &.{.{ "100644", "b.md", b2 }}));
    const site2 = try writeLoose(a, objects, "tree", try treeData(a, &.{ .{ "100644", "a.md", a1 }, .{ "40000", "docs", docs2 } }));
    const root2 = try writeLoose(a, objects, "tree", try treeData(a, &.{ .{ "100644", "other.txt", other }, .{ "40000", "site", site2 } }));
    const c2 = try writeLoose(a, objects, "commit", try std.fmt.allocPrint(a, "tree {x}\nparent {x}\nauthor A <a@x> 1706770800 -1000\ncommitter A <a@x> 1706770800 -1000\n\ntwo\n", .{ &root2, &c1 }));

    // Commit 3 (2024-03-01): only other.txt, outside the site.
    const other3 = try writeLoose(a, objects, "blob", "o3");
    const root3 = try writeLoose(a, objects, "tree", try treeData(a, &.{ .{ "100644", "other.txt", other3 }, .{ "40000", "site", site2 } }));
    const c3 = try writeLoose(a, objects, "commit", try std.fmt.allocPrint(a, "tree {x}\nparent {x}\nauthor A <a@x> 1709294400 +0000\ncommitter A <a@x> 1709294400 +0000\n\nthree\n", .{ &root3, &c2 }));

    // HEAD -> refs/heads/main in packed-refs.
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/packed-refs", .data = try std.fmt.allocPrint(a, "# pack-refs with: peeled\n{x} refs/heads/main\n", .{&c3}) });

    const repo_path = try tmp.dir.realPathFileAlloc(io, "repo/site/docs", a);
    var found = (try discover(a, io, repo_path)).?;
    defer found.repo.close();
    try testing.expectEqualStrings("site/docs", found.prefix);

    var dates = try lastChanged(&found.repo, "site", .{});
    try testing.expectEqual(@as(usize, 2), dates.count());
    try testing.expectEqualStrings("2024-01-01", &dates.get("a.md").?);
    try testing.expectEqualStrings("2024-01-31", &dates.get("docs/b.md").?);

    dates = try lastChanged(&found.repo, "", .{ .wanted = &.{"other.txt"} });
    try testing.expectEqualStrings("2024-03-01", &dates.get("other.txt").?);
    // The walk stopped as soon as the wanted file had a date.
    try testing.expect(dates.get("site/a.md") == null);
}

test "applyDelta copies and inserts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    // base "hello world" (11) -> "hello there world" (17):
    // copy 6 from 0, insert "there ", copy 5 from 6.
    const delta = [_]u8{ 11, 17, 0x90, 6, 6 } ++ "there ".* ++ [_]u8{ 0x91, 6, 5 };
    try testing.expectEqualStrings("hello there world", try applyDelta(arena_state.allocator(), "hello world", &delta));
    try testing.expectError(error.Corrupt, applyDelta(arena_state.allocator(), "short", &delta));
}

test "signatureDate uses the committer's zone" {
    try testing.expectEqualStrings("2024-01-31", &signatureDate("committer A <a@x> 1706770800 -1000").?);
    try testing.expectEqualStrings("2024-02-01", &signatureDate("committer A <a@x> 1706770800 +0000").?);
    try testing.expect(signatureDate("committer broken") == null);
}

test "reads this repository's own history when there is one" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd().realPathFileAlloc(testing.io, ".", a) catch return error.SkipZigTest;
    var found = (try discover(a, testing.io, cwd)) orelse return error.SkipZigTest;
    defer found.repo.close();
    // Packed objects and deltas: build.zig has a date, in the past.
    const dates = try lastChanged(&found.repo, "", .{ .wanted = &.{"build.zig"} });
    const d = dates.get("build.zig") orelse return error.SkipZigTest;
    try testing.expect(d[0] == '2' and d[4] == '-');
}
