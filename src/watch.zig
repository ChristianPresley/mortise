//! Native file watching behind one interface.
//!
//! The standard library has no file-watching API, so each backend talks to
//! its operating system directly:
//!
//!   Linux    inotify(7): one watch per directory, added as directories appear.
//!
//! `wait` reports changed paths relative to the watched root, already
//! filtered: the output directory (`_site`) and anything hidden (a path
//! component starting with `.`, such as `.git` or an editor's swap file)
//! never trigger a rebuild.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sitepath = @import("path.zig");

/// Returned in a change list when the backend lost track of events (for
/// example on queue overflow). The caller should rebuild everything.
pub const overflow_marker = "*";

pub const Watcher = struct {
    io: Io,
    backend: Backend,

    pub const Backend = switch (builtin.os.tag) {
        .linux => Inotify,
        else => Unsupported,
    };

    pub const InitError = Backend.InitError;

    /// Debounce settings: after the first change, keep collecting until no
    /// new change arrives for `quiet_ms`, but never longer than `max_ms`.
    /// One editor save (truncate + write + close, or write temp + rename)
    /// lands well inside the quiet window, so it causes one rebuild.
    pub const Debounce = struct {
        quiet_ms: u32 = 10,
        max_ms: u32 = 100,
    };

    /// Starts watching `root` (absolute or relative to the working
    /// directory) and everything below it.
    pub fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Watcher {
        return .{ .io = io, .backend = try Backend.init(gpa, io, root) };
    }

    pub fn deinit(w: *Watcher) void {
        w.backend.deinit();
    }

    /// Waits up to `timeout_ms` for changes. Returns the changed site paths,
    /// deduplicated, allocated with `arena`. An empty result means the
    /// timeout passed with no relevant change.
    pub fn wait(w: *Watcher, arena: Allocator, timeout_ms: u32) ![]const []const u8 {
        var changes: Changes = .{ .arena = arena };
        try w.backend.wait(&changes, timeout_ms);
        return changes.list.items;
    }

    /// Like `wait`, but once a change arrives keeps collecting until the
    /// burst of events from one save is over (see `Debounce`).
    pub fn waitDebounced(w: *Watcher, arena: Allocator, timeout_ms: u32, debounce: Debounce) ![]const []const u8 {
        var changes: Changes = .{ .arena = arena };
        try w.backend.wait(&changes, timeout_ms);
        if (changes.list.items.len == 0) return changes.list.items;
        const start = Io.Clock.Timestamp.now(w.io, .awake);
        while (true) {
            const elapsed_ms = start.durationTo(Io.Clock.Timestamp.now(w.io, .awake)).raw.toMilliseconds();
            if (elapsed_ms >= debounce.max_ms) break;
            const before = changes.events;
            try w.backend.wait(&changes, @min(debounce.quiet_ms, debounce.max_ms - @as(u32, @intCast(elapsed_ms))));
            // Quiet: no relevant event, new path or repeat, in the window.
            if (changes.events == before) break;
        }
        return changes.list.items;
    }

    pub fn name() []const u8 {
        return Backend.name;
    }
};

/// Collects changed paths for one `wait` call.
pub const Changes = struct {
    arena: Allocator,
    list: std.ArrayList([]const u8) = .empty,
    /// Relevant events seen, counting repeats for the same path.
    events: usize = 0,

    /// Records a change to `raw`, a path relative to the root using either
    /// separator. Ignored and non-portable paths are dropped.
    pub fn add(c: *Changes, raw: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, raw, overflow_marker)) {
            c.events += 1;
            return c.addUnique(overflow_marker);
        }
        const sp = sitepath.normalize(c.arena, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        if (isIgnored(sp)) return;
        c.events += 1;
        try c.addUnique(sp);
    }

    fn addUnique(c: *Changes, sp: []const u8) Allocator.Error!void {
        for (c.list.items) |p| if (std.mem.eql(u8, p, sp)) return;
        try c.list.append(c.arena, sp);
    }
};

/// Whether a change to site path `sp` should be ignored.
pub fn isIgnored(sp: []const u8) bool {
    if (std.mem.eql(u8, sp, "_site") or std.mem.startsWith(u8, sp, "_site/")) return true;
    var it = std.mem.splitScalar(u8, sp, '/');
    while (it.next()) |comp| {
        if (comp.len > 0 and comp[0] == '.') return true;
    }
    // Editor backup files such as `index.md~`.
    return std.mem.endsWith(u8, sp, "~");
}

pub const Unsupported = struct {
    pub const name = "none";
    pub const InitError = error{WatchingUnsupported};

    fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Unsupported {
        _ = gpa;
        _ = io;
        _ = root;
        return error.WatchingUnsupported;
    }
    fn deinit(_: *Unsupported) void {}
    fn wait(_: *Unsupported, _: *Changes, _: u32) !void {}
};

// ---------------------------------------------------------------------------
// Linux: inotify(7)

const Inotify = struct {
    const linux = std.os.linux;
    pub const name = "inotify";

    pub const InitError = error{ SystemResources, AccessDenied, WatchFailed, Unexpected } ||
        Allocator.Error || Io.Dir.OpenError;

    gpa: Allocator,
    io: Io,
    fd: i32,
    root: []const u8,
    /// Watch descriptor to the directory it watches, relative to the root
    /// ("" for the root itself).
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,

    const mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.CLOSE_WRITE |
        linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.DELETE_SELF |
        linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW;

    fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Inotify {
        const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .MFILE, .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        var w: Inotify = .{ .gpa = gpa, .io = io, .fd = @intCast(rc), .root = try gpa.dupe(u8, root) };
        errdefer w.deinit();
        try w.addTree("");
        return w;
    }

    fn deinit(w: *Inotify) void {
        var it = w.dirs.valueIterator();
        while (it.next()) |d| w.gpa.free(d.*);
        w.dirs.deinit(w.gpa);
        _ = linux.close(w.fd);
        w.gpa.free(w.root);
    }

    /// Watches directory `rel` and every directory below it, skipping
    /// ignored ones.
    fn addTree(w: *Inotify, rel: []const u8) InitError!void {
        if (rel.len > 0 and isIgnored(rel)) return;
        try w.addWatch(rel);

        var dir = try Io.Dir.cwd().openDir(w.io, try w.fullPath(rel), .{ .iterate = true });
        defer dir.close(w.io);
        var it = dir.iterate();
        while (it.next(w.io) catch return error.WatchFailed) |entry| {
            if (entry.kind != .directory) continue;
            const child = if (rel.len == 0)
                try w.gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ rel, entry.name });
            defer w.gpa.free(child);
            try w.addTree(child);
        }
    }

    fn fullPath(w: *Inotify, rel: []const u8) Allocator.Error![:0]u8 {
        // A thread-local scratch buffer would also do; paths are short.
        const S = struct {
            threadlocal var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        };
        const p = std.fmt.bufPrintZ(&S.buf, "{s}{s}{s}", .{ w.root, if (rel.len > 0) "/" else "", rel }) catch
            return error.OutOfMemory;
        return p;
    }

    fn addWatch(w: *Inotify, rel: []const u8) InitError!void {
        const rc = linux.inotify_add_watch(w.fd, try w.fullPath(rel), mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // The directory vanished or was replaced before we got to it.
            .NOENT, .NOTDIR => return,
            .ACCES => return error.AccessDenied,
            .NOSPC, .NOMEM => return error.SystemResources,
            else => return error.WatchFailed,
        }
        const wd: i32 = @intCast(rc);
        const gop = try w.dirs.getOrPut(w.gpa, wd);
        if (gop.found_existing) w.gpa.free(gop.value_ptr.*);
        gop.value_ptr.* = try w.gpa.dupe(u8, rel);
    }

    fn wait(w: *Inotify, changes: *Changes, timeout_ms: u32) !void {
        var fds = [_]linux.pollfd{.{ .fd = w.fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&fds, 1, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => return,
            else => return error.WatchFailed,
        }
        if (rc == 0) return;

        var buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = linux.read(w.fd, &buf, buf.len);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .AGAIN => return,
                .INTR => continue,
                else => return error.WatchFailed,
            }
            if (n == 0) return;
            var off: usize = 0;
            while (off < n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                off += @sizeOf(linux.inotify_event) + ev.len;
                try w.handle(ev, changes);
            }
        }
    }

    fn handle(w: *Inotify, ev: *const linux.inotify_event, changes: *Changes) !void {
        if (ev.mask & linux.IN.Q_OVERFLOW != 0) return changes.add(overflow_marker);
        const dir = w.dirs.get(ev.wd) orelse return;
        if (ev.mask & linux.IN.IGNORED != 0) {
            if (w.dirs.fetchRemove(ev.wd)) |kv| w.gpa.free(kv.value);
            return;
        }
        const leaf = ev.getName() orelse {
            // An event about the watched directory itself.
            if (dir.len > 0) try changes.add(dir);
            return;
        };
        const rel = if (dir.len == 0)
            try changes.arena.dupe(u8, leaf)
        else
            try std.fmt.allocPrint(changes.arena, "{s}/{s}", .{ dir, leaf });
        if (ev.mask & linux.IN.ISDIR != 0 and ev.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
            // Watch the new directory. Files created in it before the watch
            // existed are covered by reporting the directory itself.
            w.addTree(rel) catch {};
        }
        try changes.add(rel);
    }
};

// ---------------------------------------------------------------------------

const testing = std.testing;

test "isIgnored" {
    try testing.expect(isIgnored("_site"));
    try testing.expect(isIgnored("_site/index.html"));
    try testing.expect(isIgnored(".git/index"));
    try testing.expect(isIgnored("posts/.hello.md.swp"));
    try testing.expect(isIgnored("index.md~"));
    try testing.expect(!isIgnored("_posts/2024-01-01-a.md"));
    try testing.expect(!isIgnored("_site.md"));
}

test "Changes normalizes, filters, and deduplicates" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var c: Changes = .{ .arena = arena.allocator() };
    try c.add("a\\b.md");
    try c.add("a/b.md");
    try c.add("_site/x.html");
    try c.add(".git/HEAD");
    try c.add("../escape");
    try c.add(overflow_marker);
    try testing.expectEqual(@as(usize, 2), c.list.items.len);
    try testing.expectEqualStrings("a/b.md", c.list.items[0]);
    try testing.expectEqualStrings(overflow_marker, c.list.items[1]);
}

/// Waits until `wait` reports `want`, or fails after a few seconds.
fn expectChange(w: *Watcher, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const changes = try w.wait(arena.allocator(), 100);
        for (changes) |c| if (std.mem.eql(u8, c, want)) return;
    }
    std.debug.print("no change reported for {s}\n", .{want});
    return error.TestExpectedChange;
}

/// Drains pending events so the next assertion sees only new ones.
fn drain(w: *Watcher) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while ((try w.wait(arena.allocator(), 50)).len > 0) {}
}

test "watcher reports writes, creates, renames, and new directories" {
    if (Watcher.Backend == Unsupported) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "posts");
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/a.md", .data = "one" });

    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var w = try Watcher.init(testing.allocator, io, root);
    defer w.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "posts/a.md", .data = "two" });
    try expectChange(&w, "posts/a.md");

    // Editors often save by writing a temporary file and renaming it over
    // the original.
    try drain(&w);
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/.a.md.tmp", .data = "three" });
    try tmp.dir.rename("posts/.a.md.tmp", tmp.dir, "posts/a.md", io);
    try expectChange(&w, "posts/a.md");

    // A directory created after the watcher started is watched too.
    try drain(&w);
    try tmp.dir.createDirPath(io, "new");
    try expectChange(&w, "new");
    try drain(&w);
    try tmp.dir.writeFile(io, .{ .sub_path = "new/b.md", .data = "x" });
    try expectChange(&w, "new/b.md");

    // The output directory is ignored.
    try drain(&w);
    try tmp.dir.createDirPath(io, "_site");
    try tmp.dir.writeFile(io, .{ .sub_path = "_site/index.html", .data = "x" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try w.wait(arena.allocator(), 200)).len);
}

test "debounce folds the events of one save into one change set" {
    if (Watcher.Backend == Unsupported) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "one" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var w = try Watcher.init(testing.allocator, io, root);
    defer w.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // An atomic save: write a temporary file, then rename it over the
    // original. Then a plain in-place save of the same file.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md.new", .data = "two" });
    try tmp.dir.rename("a.md.new", tmp.dir, "a.md", io);
    try tmp.dir.writeFile(io, .{ .sub_path = "a.md", .data = "three" });

    const first = try w.waitDebounced(arena.allocator(), 2000, .{});
    var saw_target = false;
    for (first) |c| saw_target = saw_target or std.mem.eql(u8, c, "a.md");
    try testing.expect(saw_target);
    // Nothing is left over to trigger a second rebuild.
    try testing.expectEqual(@as(usize, 0), (try w.wait(arena.allocator(), 200)).len);
}
