//! File watching behind one interface.
//!
//! The standard library has no file-watching API, so each native backend
//! talks to its operating system directly:
//!
//!   Linux    inotify(7): one watch per directory, added as directories
//!            appear.
//!   macOS    kqueue(2) with EVFILT_VNODE: one descriptor per file and
//!            directory, opened with O_EVTONLY. A directory write triggers
//!            a rescan of that directory to find added and removed entries.
//!   Windows  ReadDirectoryChangesW with bWatchSubtree on the root, using
//!            overlapped I/O so waits can time out.
//!
//! If the native backend cannot start (or the OS has none), the watcher
//! falls back to polling file modification times and says so through
//! `fallback_reason`, so the caller can log it.
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

/// The native backend for this OS, or `void` where there is none.
pub const Native = switch (builtin.os.tag) {
    .linux => Inotify,
    .macos => Kqueue,
    .windows => ReadDirectoryChanges,
    else => void,
};

pub const has_native = Native != void;

pub const Watcher = struct {
    io: Io,
    impl: union(enum) {
        native: if (has_native) Native else noreturn,
        polling: Poller,
    },
    /// Why the native backend is not in use, or null if it is.
    fallback_reason: ?anyerror = null,

    pub const InitError = Poller.InitError;

    /// Debounce settings: after the first change, keep collecting until no
    /// new change arrives for `quiet_ms`, but never longer than `max_ms`.
    /// One editor save (truncate + write + close, or write temp + rename)
    /// lands well inside the quiet window, so it causes one rebuild.
    pub const Debounce = struct {
        quiet_ms: u32 = 10,
        max_ms: u32 = 100,
    };

    /// Starts watching `root` (absolute or relative to the working
    /// directory) and everything below it, natively if possible.
    pub fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Watcher {
        if (has_native) {
            if (Native.init(gpa, io, root)) |n| {
                return .{ .io = io, .impl = .{ .native = n } };
            } else |err| {
                var w = try initPolling(gpa, io, root);
                w.fallback_reason = err;
                return w;
            }
        }
        var w = try initPolling(gpa, io, root);
        w.fallback_reason = error.NoNativeWatcher;
        return w;
    }

    /// Starts a polling watcher regardless of native support.
    pub fn initPolling(gpa: Allocator, io: Io, root: []const u8) InitError!Watcher {
        return .{ .io = io, .impl = .{ .polling = try Poller.init(gpa, io, root) } };
    }

    pub fn deinit(w: *Watcher) void {
        switch (w.impl) {
            .native => |*n| n.deinit(),
            .polling => |*p| p.deinit(),
        }
    }

    pub fn backendName(w: *const Watcher) []const u8 {
        return switch (w.impl) {
            .native => Native.name,
            .polling => Poller.name,
        };
    }

    fn waitInto(w: *Watcher, changes: *Changes, timeout_ms: u32) !void {
        switch (w.impl) {
            .native => |*n| try n.wait(changes, timeout_ms),
            .polling => |*p| try p.wait(changes, timeout_ms),
        }
    }

    /// Waits up to `timeout_ms` for changes. Returns the changed site paths,
    /// deduplicated, allocated with `arena`. An empty result means the
    /// timeout passed with no relevant change.
    pub fn wait(w: *Watcher, arena: Allocator, timeout_ms: u32) ![]const []const u8 {
        var changes: Changes = .{ .arena = arena };
        try w.waitInto(&changes, timeout_ms);
        return changes.list.items;
    }

    /// Like `wait`, but once a change arrives keeps collecting until the
    /// burst of events from one save is over (see `Debounce`).
    pub fn waitDebounced(w: *Watcher, arena: Allocator, timeout_ms: u32, debounce: Debounce) ![]const []const u8 {
        var changes: Changes = .{ .arena = arena };
        try w.waitInto(&changes, timeout_ms);
        if (changes.list.items.len == 0) return changes.list.items;
        const start = Io.Clock.Timestamp.now(w.io, .awake);
        while (true) {
            const elapsed_ms = start.durationTo(Io.Clock.Timestamp.now(w.io, .awake)).raw.toMilliseconds();
            if (elapsed_ms >= debounce.max_ms) break;
            const before = changes.events;
            try w.waitInto(&changes, @min(debounce.quiet_ms, debounce.max_ms - @as(u32, @intCast(elapsed_ms))));
            // Quiet: no relevant event, new path or repeat, in the window.
            if (changes.events == before) break;
        }
        return changes.list.items;
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

/// `root` joined with site path `rel` into a null-terminated buffer.
fn joinZ(buf: []u8, root: []const u8, rel: []const u8) error{NameTooLong}![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}{s}{s}", .{ root, if (rel.len > 0) "/" else "", rel }) catch
        error.NameTooLong;
}

// ---------------------------------------------------------------------------
// Polling fallback

const Poller = struct {
    pub const name = "polling";
    pub const InitError = Allocator.Error || Io.Dir.OpenError || error{ScanFailed};
    /// How often the tree is rescanned.
    const interval_ms = 100;

    gpa: Allocator,
    io: Io,
    root: []const u8,
    /// Site path to a stamp of what was last seen there.
    seen: std.StringHashMapUnmanaged(Stamp) = .empty,

    const Stamp = struct { mtime: i96, size: u64, is_dir: bool };

    fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Poller {
        var p: Poller = .{ .gpa = gpa, .io = io, .root = try gpa.dupe(u8, root) };
        errdefer p.deinit();
        p.seen = try p.scan();
        return p;
    }

    fn deinit(p: *Poller) void {
        freeStamps(p.gpa, &p.seen);
        p.gpa.free(p.root);
    }

    fn freeStamps(gpa: Allocator, m: *std.StringHashMapUnmanaged(Stamp)) void {
        var it = m.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.deinit(gpa);
    }

    fn scan(p: *Poller) InitError!std.StringHashMapUnmanaged(Stamp) {
        var result: std.StringHashMapUnmanaged(Stamp) = .empty;
        errdefer freeStamps(p.gpa, &result);
        var dir = try Io.Dir.cwd().openDir(p.io, p.root, .{ .iterate = true });
        defer dir.close(p.io);
        var walker = try dir.walkSelectively(p.gpa);
        defer walker.deinit();
        while (walker.next(p.io) catch return error.ScanFailed) |entry| {
            const sp = sitepath.normalize(p.gpa, entry.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            if (isIgnored(sp)) {
                p.gpa.free(sp);
                continue;
            }
            const is_dir = entry.kind == .directory;
            if (is_dir) walker.enter(p.io, entry) catch return error.ScanFailed;
            const st = entry.dir.statFile(p.io, entry.basename, .{}) catch {
                p.gpa.free(sp);
                continue;
            };
            const gop = try result.getOrPut(p.gpa, sp);
            if (gop.found_existing) p.gpa.free(sp);
            gop.value_ptr.* = .{ .mtime = st.mtime.nanoseconds, .size = st.size, .is_dir = is_dir };
        }
        return result;
    }

    fn wait(p: *Poller, changes: *Changes, timeout_ms: u32) !void {
        try p.io.sleep(.fromMilliseconds(@min(timeout_ms, interval_ms)), .awake);
        var now = try p.scan();
        errdefer freeStamps(p.gpa, &now);
        var it = now.iterator();
        while (it.next()) |e| {
            const before = p.seen.get(e.key_ptr.*);
            const same = if (before) |b| b.mtime == e.value_ptr.mtime and b.size == e.value_ptr.size else false;
            // Directory mtimes change when entries do; the entries
            // themselves are reported, so only report new directories.
            if (!same and !(e.value_ptr.is_dir and before != null)) try changes.add(e.key_ptr.*);
        }
        var old = p.seen.keyIterator();
        while (old.next()) |k| {
            if (!now.contains(k.*)) try changes.add(k.*);
        }
        freeStamps(p.gpa, &p.seen);
        p.seen = now;
    }
};

// ---------------------------------------------------------------------------
// Linux: inotify(7)

const Inotify = struct {
    const linux = std.os.linux;
    pub const name = "inotify";

    pub const InitError = error{ SystemResources, AccessDenied, WatchFailed, Unexpected, NameTooLong } ||
        Allocator.Error || Io.Dir.OpenError;

    gpa: Allocator,
    io: Io,
    fd: i32,
    root: []const u8,
    /// Watch descriptor to the directory it watches, relative to the root
    /// ("" for the root itself).
    dirs: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,
    path_buf: [Io.Dir.max_path_bytes]u8 = undefined,

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

        var dir = Io.Dir.cwd().openDir(w.io, try joinZ(&w.path_buf, w.root, rel), .{ .iterate = true }) catch |err| switch (err) {
            // Removed again before we could look inside.
            error.FileNotFound, error.NotDir => return,
            else => |e| return e,
        };
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

    fn addWatch(w: *Inotify, rel: []const u8) InitError!void {
        const rc = linux.inotify_add_watch(w.fd, try joinZ(&w.path_buf, w.root, rel), mask);
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
// macOS: kqueue(2) with EVFILT_VNODE

const Kqueue = struct {
    const c = std.c;
    pub const name = "kqueue";

    pub const InitError = error{ SystemResources, WatchFailed, NameTooLong } ||
        Allocator.Error || Io.Dir.OpenError;

    const Entry = struct { rel: []const u8, is_dir: bool };

    gpa: Allocator,
    io: Io,
    kq: c_int,
    root: []const u8,
    /// Open descriptor to what it watches.
    by_fd: std.AutoHashMapUnmanaged(c_int, Entry) = .empty,
    /// Site path ("" for the root) to its descriptor.
    by_path: std.StringHashMapUnmanaged(c_int) = .empty,
    path_buf: [Io.Dir.max_path_bytes]u8 = undefined,

    const vnode_flags: u32 = c.NOTE.DELETE | c.NOTE.WRITE | c.NOTE.EXTEND | c.NOTE.ATTRIB |
        c.NOTE.RENAME | c.NOTE.REVOKE;

    fn init(gpa: Allocator, io: Io, root: []const u8) InitError!Kqueue {
        raiseFileLimit();
        const kq = c.kqueue();
        if (kq < 0) return error.SystemResources;
        var w: Kqueue = .{ .gpa = gpa, .io = io, .kq = kq, .root = try gpa.dupe(u8, root) };
        errdefer w.deinit();
        try w.watchTree("", null);
        return w;
    }

    /// One descriptor per watched file means the default limit of 256 on
    /// macOS is quickly exhausted; raise the soft limit toward the hard one.
    fn raiseFileLimit() void {
        var lim: c.rlimit = undefined;
        if (c.getrlimit(.NOFILE, &lim) != 0) return;
        const want: c.rlim_t = @min(lim.max, 10240);
        if (lim.cur >= want) return;
        lim.cur = want;
        _ = c.setrlimit(.NOFILE, &lim);
    }

    fn deinit(w: *Kqueue) void {
        var it = w.by_fd.iterator();
        while (it.next()) |e| {
            _ = c.close(e.key_ptr.*);
            w.gpa.free(e.value_ptr.rel);
        }
        w.by_fd.deinit(w.gpa);
        w.by_path.deinit(w.gpa);
        _ = c.close(w.kq);
        w.gpa.free(w.root);
    }

    /// Watches `rel` and, for a directory, everything below it. Newly
    /// watched paths are reported to `changes` when it is not null.
    fn watchTree(w: *Kqueue, rel: []const u8, changes: ?*Changes) InitError!void {
        if (rel.len > 0 and isIgnored(rel)) return;
        const full = try joinZ(&w.path_buf, w.root, rel);
        var dir = Io.Dir.cwd().openDir(w.io, full, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                if (try w.watch(rel, false)) {
                    if (changes) |ch| try ch.add(rel);
                }
                return;
            },
            error.FileNotFound => return,
            else => |e| return e,
        };
        defer dir.close(w.io);
        if (try w.watch(rel, true)) {
            if (changes) |ch| if (rel.len > 0) try ch.add(rel);
        }
        var it = dir.iterate();
        while (it.next(w.io) catch return error.WatchFailed) |entry| {
            if (entry.kind != .directory and entry.kind != .file) continue;
            const child = if (rel.len == 0)
                try w.gpa.dupe(u8, entry.name)
            else
                try std.fmt.allocPrint(w.gpa, "{s}/{s}", .{ rel, entry.name });
            defer w.gpa.free(child);
            if (w.by_path.contains(child)) {
                if (entry.kind == .directory) try w.watchTree(child, changes);
                continue;
            }
            try w.watchTree(child, changes);
        }
    }

    /// Opens and registers `rel`. Returns false if it was already watched
    /// or has vanished.
    fn watch(w: *Kqueue, rel: []const u8, is_dir: bool) InitError!bool {
        if (w.by_path.contains(rel)) return false;
        const full = try joinZ(&w.path_buf, w.root, rel);
        const fd = c.open(full, .{ .EVTONLY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd < 0) return switch (std.posix.errno(fd)) {
            .NOENT, .LOOP => false,
            .MFILE, .NFILE => error.SystemResources,
            else => error.WatchFailed,
        };
        var ev: c.Kevent = .{
            .ident = @intCast(fd),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR,
            .fflags = vnode_flags,
            .data = 0,
            .udata = 0,
        };
        if (c.kevent(w.kq, @ptrCast(&ev), 1, @ptrCast(&ev), 0, null) < 0) {
            _ = c.close(fd);
            return error.WatchFailed;
        }
        const owned = try w.gpa.dupe(u8, rel);
        errdefer w.gpa.free(owned);
        try w.by_fd.put(w.gpa, fd, .{ .rel = owned, .is_dir = is_dir });
        try w.by_path.put(w.gpa, owned, fd);
        return true;
    }

    fn unwatch(w: *Kqueue, fd: c_int) void {
        const kv = w.by_fd.fetchRemove(fd) orelse return;
        _ = w.by_path.remove(kv.value.rel);
        _ = c.close(fd);
        w.gpa.free(kv.value.rel);
    }

    /// Stops watching `rel` and everything below it.
    fn unwatchTree(w: *Kqueue, rel: []const u8) Allocator.Error!void {
        var doomed: std.ArrayList(c_int) = .empty;
        defer doomed.deinit(w.gpa);
        var it = w.by_path.iterator();
        while (it.next()) |e| {
            const p = e.key_ptr.*;
            if (std.mem.eql(u8, p, rel) or (std.mem.startsWith(u8, p, rel) and p.len > rel.len and p[rel.len] == '/')) {
                try doomed.append(w.gpa, e.value_ptr.*);
            }
        }
        for (doomed.items) |fd| w.unwatch(fd);
    }

    fn exists(w: *Kqueue, rel: []const u8) bool {
        const full = joinZ(&w.path_buf, w.root, rel) catch return false;
        Io.Dir.cwd().access(w.io, full, .{}) catch return false;
        return true;
    }

    fn wait(w: *Kqueue, changes: *Changes, timeout_ms: u32) !void {
        var events: [64]c.Kevent = undefined;
        const ts: c.timespec = .{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast(@as(u64, timeout_ms % 1000) * std.time.ns_per_ms),
        };
        const n = c.kevent(w.kq, &events, 0, &events, events.len, &ts);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) return;
            return error.WatchFailed;
        }
        for (events[0..@intCast(n)]) |ev| {
            const fd: c_int = @intCast(ev.ident);
            const entry = w.by_fd.get(fd) orelse continue;
            const rel = try changes.arena.dupe(u8, entry.rel);
            const gone = ev.fflags & (c.NOTE.DELETE | c.NOTE.RENAME | c.NOTE.REVOKE) != 0;
            if (entry.is_dir) {
                if (gone) {
                    try w.unwatchTree(rel);
                    if (rel.len > 0) try changes.add(rel);
                    continue;
                }
                // Entries were added, removed, or renamed: rescan.
                try w.rescan(rel, changes);
            } else {
                try changes.add(rel);
                if (gone) {
                    w.unwatch(fd);
                    // An atomic save replaces the file: watch the new one.
                    if (w.exists(rel)) _ = try w.watch(rel, false);
                }
            }
        }
    }

    /// Finds entries added to or removed from directory `rel`.
    fn rescan(w: *Kqueue, rel: []const u8, changes: *Changes) !void {
        // Removed: watched children of `rel` that no longer exist.
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(w.gpa);
        var it = w.by_path.keyIterator();
        while (it.next()) |k| {
            const p = k.*;
            const parent = sitepath.dirname(p) orelse "";
            if (p.len > 0 and std.mem.eql(u8, parent, rel)) try doomed.append(w.gpa, p);
        }
        for (doomed.items) |p| {
            if (w.exists(p)) continue;
            try changes.add(p);
            try w.unwatchTree(try changes.arena.dupe(u8, p));
        }
        // Added: anything not yet watched.
        w.watchTree(rel, changes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return changes.add(overflow_marker),
        };
    }
};

// ---------------------------------------------------------------------------
// Windows: ReadDirectoryChangesW

const ReadDirectoryChanges = struct {
    const windows = std.os.windows;
    const BOOL = windows.BOOL;
    const DWORD = windows.DWORD;
    const HANDLE = windows.HANDLE;
    pub const name = "ReadDirectoryChangesW";

    pub const InitError = error{ FileNotFound, AccessDenied, SystemResources, WatchFailed, InvalidWtf8 } ||
        Allocator.Error;

    const OVERLAPPED = extern struct {
        Internal: usize = 0,
        InternalHigh: usize = 0,
        Offset: DWORD = 0,
        OffsetHigh: DWORD = 0,
        hEvent: ?HANDLE = null,
    };

    const FILE_NOTIFY_INFORMATION = extern struct {
        NextEntryOffset: DWORD,
        Action: DWORD,
        /// In bytes.
        FileNameLength: DWORD,
        // Followed by FileNameLength bytes of UTF-16LE, not null-terminated.
    };

    const INFINITE: DWORD = 0xFFFFFFFF;
    const FILE_LIST_DIRECTORY: DWORD = 0x0001;
    const FILE_SHARE_READ: DWORD = 0x1;
    const FILE_SHARE_WRITE: DWORD = 0x2;
    const FILE_SHARE_DELETE: DWORD = 0x4;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
    const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
    const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x001;
    const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x002;
    const FILE_NOTIFY_CHANGE_ATTRIBUTES: DWORD = 0x004;
    const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x008;
    const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x010;
    const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x040;

    const filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
        FILE_NOTIFY_CHANGE_ATTRIBUTES | FILE_NOTIFY_CHANGE_SIZE |
        FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION;

    extern "kernel32" fn CreateFileW(
        lpFileName: windows.LPCWSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn CreateEventW(
        lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
        bManualReset: BOOL,
        bInitialState: BOOL,
        lpName: ?windows.LPCWSTR,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn ReadDirectoryChangesW(
        hDirectory: HANDLE,
        lpBuffer: *anyopaque,
        nBufferLength: DWORD,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
        lpBytesReturned: ?*DWORD,
        lpOverlapped: *OVERLAPPED,
        lpCompletionRoutine: ?*const anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetOverlappedResultEx(
        hFile: HANDLE,
        lpOverlapped: *OVERLAPPED,
        lpNumberOfBytesTransferred: *DWORD,
        dwMilliseconds: DWORD,
        bAlertable: BOOL,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;

    /// The overlapped read writes into this while it is pending, so it lives
    /// on the heap where moving the watcher cannot invalidate it.
    const State = struct {
        dir: HANDLE,
        event: HANDLE,
        overlapped: OVERLAPPED = .{},
        buffer: [64 * 1024]u8 align(@alignOf(DWORD)) = undefined,
        pending: bool = false,
    };

    gpa: Allocator,
    state: *State,

    fn init(gpa: Allocator, io: Io, root: []const u8) InitError!ReadDirectoryChanges {
        _ = io;
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, root);
        defer gpa.free(path_w);
        const dir = CreateFileW(
            path_w.ptr,
            FILE_LIST_DIRECTORY,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            null,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
            null,
        );
        if (dir == windows.INVALID_HANDLE_VALUE) return switch (windows.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            else => error.WatchFailed,
        };
        errdefer windows.CloseHandle(dir);
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.SystemResources;
        errdefer windows.CloseHandle(event);

        const state = try gpa.create(State);
        state.* = .{ .dir = dir, .event = event };
        var w: ReadDirectoryChanges = .{ .gpa = gpa, .state = state };
        errdefer gpa.destroy(state);
        try w.issue();
        return w;
    }

    fn deinit(w: *ReadDirectoryChanges) void {
        const s = w.state;
        if (s.pending) {
            // Cancel the read and wait for it so the kernel stops writing
            // into the buffer before it is freed.
            _ = CancelIoEx(s.dir, &s.overlapped);
            var bytes: DWORD = 0;
            _ = GetOverlappedResultEx(s.dir, &s.overlapped, &bytes, INFINITE, .FALSE);
        }
        windows.CloseHandle(s.event);
        windows.CloseHandle(s.dir);
        w.gpa.destroy(s);
    }

    fn issue(w: *ReadDirectoryChanges) error{WatchFailed}!void {
        const s = w.state;
        s.overlapped = .{ .hEvent = s.event };
        if (ReadDirectoryChangesW(s.dir, &s.buffer, s.buffer.len, .TRUE, filter, null, &s.overlapped, null) == .FALSE) {
            return error.WatchFailed;
        }
        s.pending = true;
    }

    fn wait(w: *ReadDirectoryChanges, changes: *Changes, timeout_ms: u32) !void {
        const s = w.state;
        var bytes: DWORD = 0;
        if (GetOverlappedResultEx(s.dir, &s.overlapped, &bytes, timeout_ms, .FALSE) == .FALSE) {
            return switch (windows.GetLastError()) {
                .WAIT_TIMEOUT, .IO_INCOMPLETE => {},
                else => error.WatchFailed,
            };
        }
        s.pending = false;
        if (bytes == 0) {
            // The buffer overflowed and the events were lost.
            try changes.add(overflow_marker);
        } else {
            var off: usize = 0;
            while (true) {
                const info: *align(@alignOf(DWORD)) const FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(&s.buffer[off]));
                const name_bytes = s.buffer[off + @sizeOf(FILE_NOTIFY_INFORMATION) ..][0..info.FileNameLength];
                const name_w = std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(name_bytes)));
                const rel = try std.unicode.wtf16LeToWtf8Alloc(changes.arena, name_w);
                try changes.add(rel);
                if (info.NextEntryOffset == 0) break;
                off += info.NextEntryOffset;
            }
        }
        try w.issue();
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
    std.debug.print("{s}: no change reported for {s}\n", .{ w.backendName(), want });
    return error.TestExpectedChange;
}

/// Drains pending events so the next assertion sees only new ones.
fn drain(w: *Watcher) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    while ((try w.wait(arena.allocator(), 150)).len > 0) {}
}

const WatcherKind = enum { native, polling };

fn startWatcher(kind: WatcherKind, root: []const u8) !Watcher {
    return switch (kind) {
        .native => blk: {
            const w = try Watcher.init(testing.allocator, testing.io, root);
            if (w.fallback_reason) |reason| {
                std.debug.print("native watcher unavailable: {s}\n", .{@errorName(reason)});
                return error.TestNativeWatcherUnavailable;
            }
            break :blk w;
        },
        .polling => try Watcher.initPolling(testing.allocator, testing.io, root),
    };
}

fn testScenario(kind: WatcherKind) !void {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "posts");
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/a.md", .data = "one" });

    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    var w = try startWatcher(kind, root);
    defer w.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "posts/a.md", .data = "two, longer" });
    try expectChange(&w, "posts/a.md");

    // Editors often save by writing a temporary file and renaming it over
    // the original.
    try drain(&w);
    try tmp.dir.writeFile(io, .{ .sub_path = "posts/a.md.new", .data = "three" });
    try tmp.dir.rename("posts/a.md.new", tmp.dir, "posts/a.md", io);
    try expectChange(&w, "posts/a.md");

    // A directory created after the watcher started is watched too.
    try drain(&w);
    try tmp.dir.createDirPath(io, "new");
    try expectChange(&w, "new");
    try drain(&w);
    try tmp.dir.writeFile(io, .{ .sub_path = "new/b.md", .data = "x" });
    try expectChange(&w, "new/b.md");

    // Deletions are reported.
    try drain(&w);
    try tmp.dir.deleteFile(io, "new/b.md");
    try expectChange(&w, "new/b.md");

    // The output directory and hidden files are ignored.
    try drain(&w);
    try tmp.dir.createDirPath(io, "_site");
    try tmp.dir.writeFile(io, .{ .sub_path = "_site/index.html", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "x" });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try w.wait(arena.allocator(), 300)).len);
}

test "native watcher reports writes, atomic saves, new directories, and deletes" {
    if (!has_native) return error.SkipZigTest;
    try testScenario(.native);
}

test "polling watcher reports the same changes" {
    try testScenario(.polling);
}

test "debounce folds the events of one save into one change set" {
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

    var saw_target = false;
    var attempts: usize = 0;
    while (!saw_target and attempts < 20) : (attempts += 1) {
        const batch = try w.waitDebounced(arena.allocator(), 250, .{});
        for (batch) |c| saw_target = saw_target or std.mem.eql(u8, c, "a.md");
    }
    try testing.expect(saw_target);
    // Nothing is left over to trigger a second rebuild.
    try testing.expectEqual(@as(usize, 0), (try w.wait(arena.allocator(), 300)).len);
}
