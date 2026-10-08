//! A directory that Mortise reads from or writes to, addressed only by site
//! paths (see `path.zig`). This is the single place where site paths meet
//! the filesystem, and every call goes through the explicit `std.Io` value
//! the process was started with.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sitepath = @import("path.zig");
const SiteDir = @This();

/// Largest single file Mortise will read into memory.
pub const max_file_size: usize = 64 * 1024 * 1024;

io: Io,
dir: Io.Dir,
/// Whether `close` should release `dir`. False for borrowed handles.
owned: bool,

/// Opens `root` (absolute, or relative to the working directory) for reading
/// and iteration.
pub fn open(io: Io, root: []const u8) Io.Dir.OpenError!SiteDir {
    const dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    return .{ .io = io, .dir = dir, .owned = true };
}

/// Opens `root`, creating it and any missing parents first.
pub fn openOrCreate(io: Io, root: []const u8) Io.Dir.CreateDirPathOpenError!SiteDir {
    const dir = try Io.Dir.cwd().createDirPathOpen(io, root, .{ .open_options = .{ .iterate = true } });
    return .{ .io = io, .dir = dir, .owned = true };
}

/// Wraps a handle the caller keeps ownership of.
pub fn borrow(io: Io, dir: Io.Dir) SiteDir {
    return .{ .io = io, .dir = dir, .owned = false };
}

pub fn close(self: *SiteDir) void {
    if (self.owned) self.dir.close(self.io);
    self.* = undefined;
}

/// Reads a whole file. The result is allocated with `arena`, normally the
/// current build's arena.
pub fn readFile(self: SiteDir, arena: Allocator, sp: []const u8) Io.Dir.ReadFileAllocError![]u8 {
    std.debug.assert(sitepath.isNormalized(sp));
    return self.dir.readFileAlloc(self.io, sp, arena, .limited(max_file_size));
}

pub const WriteError = Io.Dir.CreateDirPathError || Io.Dir.WriteFileError;

/// Writes `data` to `sp`, creating parent directories as needed and
/// replacing any existing file.
pub fn writeFile(self: SiteDir, sp: []const u8, data: []const u8) WriteError!void {
    std.debug.assert(sitepath.isNormalized(sp));
    if (sitepath.dirname(sp)) |parent| try self.dir.createDirPath(self.io, parent);
    try self.dir.writeFile(self.io, .{ .sub_path = sp, .data = data });
}

/// Copies `src_sp` in this directory to `dest_sp` in `dest`, creating parent
/// directories as needed.
pub fn copyFileTo(self: SiteDir, src_sp: []const u8, dest: SiteDir, dest_sp: []const u8) Io.Dir.CopyFileError!void {
    std.debug.assert(sitepath.isNormalized(src_sp) and sitepath.isNormalized(dest_sp));
    try self.dir.copyFile(src_sp, dest.dir, dest_sp, self.io, .{ .make_path = true });
}

/// Removes `sp` and everything under it. Missing paths are not an error.
pub fn deleteTree(self: SiteDir, sp: []const u8) Io.Dir.DeleteTreeError!void {
    std.debug.assert(sitepath.isNormalized(sp));
    try self.dir.deleteTree(self.io, sp);
}

pub const ListResult = struct {
    /// Every regular file under the root, as site paths, sorted bytewise so
    /// builds are deterministic regardless of directory iteration order.
    files: []const []const u8,
};

/// Lists every regular file under the directory. Symlinks and special files
/// are skipped. All memory comes from `arena`.
///
/// Returns `error.InvalidPath` when a file name is not a valid site path;
/// `bad_path.*` then holds the offending native path (allocated with
/// `arena`) so the caller can report it.
pub fn listFiles(self: SiteDir, arena: Allocator, bad_path: *?[]const u8) !ListResult {
    var walker = try self.dir.walk(arena);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(self.io)) |entry| {
        if (entry.kind != .file) continue;
        const sp = sitepath.normalize(arena, entry.path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                bad_path.* = try arena.dupe(u8, entry.path);
                return error.InvalidPath;
            },
        };
        try files.append(arena, sp);
    }

    std.mem.sortUnstable([]const u8, files.items, {}, lessThan);
    return .{ .files = files.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

test "write creates parents, read returns contents" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const site = borrow(testing.io, tmp.dir);

    try site.writeFile("a/b/c.txt", "hello");
    try site.writeFile("a/b/c.txt", "replaced");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const got = try site.readFile(arena.allocator(), "a/b/c.txt");
    try testing.expectEqualStrings("replaced", got);
}

test "listFiles returns sorted site paths of regular files only" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const site = borrow(testing.io, tmp.dir);

    try site.writeFile("posts/2024-02-01-b.md", "b");
    try site.writeFile("posts/2024-01-01-a.md", "a");
    try site.writeFile("index.md", "i");
    try site.writeFile("_layouts/base.html", "l");
    try tmp.dir.createDirPath(testing.io, "empty/dir");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: ?[]const u8 = null;
    const res = try site.listFiles(arena.allocator(), &bad);

    const expected = [_][]const u8{
        "_layouts/base.html",
        "index.md",
        "posts/2024-01-01-a.md",
        "posts/2024-02-01-b.md",
    };
    try testing.expectEqual(expected.len, res.files.len);
    for (expected, res.files) |e, f| try testing.expectEqualStrings(e, f);
}

test "listFiles reports a non-portable name" {
    // Windows cannot create this name, so only exercise it elsewhere.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "bad:name.md", .data = "" });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: ?[]const u8 = null;
    try testing.expectError(error.InvalidPath, borrow(testing.io, tmp.dir).listFiles(arena.allocator(), &bad));
    try testing.expectEqualStrings("bad:name.md", bad.?);
}

test "copyFileTo and deleteTree" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const site = borrow(testing.io, tmp.dir);

    try site.writeFile("src/img/logo.svg", "<svg/>");
    try site.copyFileTo("src/img/logo.svg", site, "out/img/logo.svg");

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("<svg/>", try site.readFile(arena.allocator(), "out/img/logo.svg"));

    try site.deleteTree("out");
    try testing.expectError(error.FileNotFound, site.readFile(arena.allocator(), "out/img/logo.svg"));
    try site.deleteTree("does/not/exist");
}
