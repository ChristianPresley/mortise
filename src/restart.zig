//! `mortise serve --restart-on-rebuild`: restarts the dev server whenever
//! the mortise binary is rebuilt, so edits to Mortise itself reach the
//! browser without restarting anything by hand. Pair it with
//! `zig build dev --watch -fincremental`.
//!
//! A supervisor runs the server as a child process started from a copy of
//! the binary, so the build is free to replace the original. On Windows a
//! running executable cannot be replaced, so the supervisor first moves its
//! own image aside too. The child polls the original binary and exits with
//! `restart_code` once a new one has been written; the supervisor then
//! starts the new binary the same way. Open pages reconnect to the new
//! process and reload.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The exit code a child uses to ask for a restart.
pub const restart_code: u8 = 75;
/// Passed to the child: the path of the binary it watches. Internal.
pub const child_flag = "--restarted-from=";
/// Holds the running copies, next to the binary.
const copies_dir = ".mortise-restart";
const exe_ext = if (builtin.os.tag == .windows) ".exe" else "";

/// Runs the server in child processes, restarting it whenever the binary
/// changes, until a child exits for another reason. `args` is the full
/// command line minus `--restart-on-rebuild`. Returns the exit status.
pub fn supervise(io: Io, gpa: Allocator, out: *Io.Writer, err: *Io.Writer, args: []const []const u8) u8 {
    return superviseOrFail(io, gpa, out, args) catch |e| {
        err.print("mortise: cannot restart on rebuild: {s}\n", .{@errorName(e)}) catch {};
        err.flush() catch {};
        return 1;
    };
}

fn superviseOrFail(io: Io, gpa: Allocator, out: *Io.Writer, args: []const []const u8) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const exe_path = try std.process.executablePathAlloc(io, arena);
    const bin_path = std.fs.path.dirname(exe_path) orelse ".";
    const exe_name = std.fs.path.basename(exe_path);
    var bin = try Io.Dir.cwd().openDir(io, bin_path, .{});
    defer bin.close(io);
    var copies = try bin.createDirPathOpen(io, copies_dir, .{ .open_options = .{ .iterate = true } });
    defer copies.close(io);
    deleteStaleCopies(io, arena, copies);

    if (builtin.os.tag == .windows) {
        // Free the original paths: move this process's image and the DLLs
        // it loaded from beside it aside, and put copies back where they
        // were.
        var names: std.ArrayList([]const u8) = .empty;
        try names.append(arena, exe_name);
        try names.appendSlice(arena, try dllNames(io, arena, bin));
        const prefix = try std.fmt.allocPrint(arena, "supervisor-{d}-", .{stamp(io)});
        for (names.items) |name| {
            const aside_name = try std.mem.concat(arena, u8, &.{ prefix, name });
            const from = try std.fs.path.join(arena, &.{ bin_path, name });
            const to = try std.fs.path.join(arena, &.{ bin_path, copies_dir, aside_name });
            try moveRunningFile(arena, from, to);
            try Io.Dir.copyFile(copies, aside_name, bin, name, io, .{});
        }
    }

    const child_path = try std.fs.path.join(arena, &.{ bin_path, copies_dir, "server" ++ exe_ext });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, child_path);
    try argv.appendSlice(arena, args[1..]);
    try argv.append(arena, try std.mem.concat(arena, u8, &.{ child_flag, exe_path }));

    while (true) {
        try Io.Dir.copyFile(bin, exe_name, copies, "server" ++ exe_ext, io, .{});
        // Zig's own Windows backend links compiler_rt as a DLL beside the
        // executable, so the copy needs it too.
        if (builtin.os.tag == .windows) try copyDlls(io, arena, bin, copies);
        var child = try std.process.spawn(io, .{ .argv = argv.items });
        const term = try child.wait(io);
        switch (term) {
            .exited => |code| {
                if (code != restart_code) return code;
                out.writeAll("Mortise was rebuilt; restarting the server\n") catch {};
                out.flush() catch {};
            },
            else => return 1,
        }
    }
}

/// Renames a file that may be a running executable. `Io.Dir.rename` asks
/// for write access, which Windows never grants on a running image, while
/// MoveFileExW only needs to delete the old name.
fn moveRunningFile(arena: Allocator, from: []const u8, to: []const u8) !void {
    const from_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, from);
    const to_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, to);
    if (win.MoveFileExW(from_w.ptr, to_w.ptr, win.MOVEFILE_REPLACE_EXISTING) == 0) return error.CannotMoveExecutable;
}

const win = struct {
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    extern "kernel32" fn MoveFileExW(
        existing: [*:0]const u16,
        new: [*:0]const u16,
        flags: u32,
    ) callconv(.winapi) i32;
};

fn dllNames(io: Io, arena: Allocator, bin: Io.Dir) ![]const []const u8 {
    var dir = try bin.openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".dll")) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    return names.items;
}

fn copyDlls(io: Io, arena: Allocator, bin: Io.Dir, copies: Io.Dir) !void {
    for (try dllNames(io, arena, bin)) |name| {
        Io.Dir.copyFile(bin, name, copies, name, io, .{}) catch |e| switch (e) {
            // A DLL still loaded by the previous copy is unchanged.
            error.AccessDenied => {},
            else => return e,
        };
    }
}

/// Removes copies left by earlier runs. Copies still running are skipped.
fn deleteStaleCopies(io: Io, arena: Allocator, copies: Io.Dir) void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = copies.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        names.append(arena, arena.dupe(u8, entry.name) catch return) catch return;
    }
    for (names.items) |name| copies.deleteFile(io, name) catch {};
}

fn stamp(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

const Version = struct { size: u64, mtime: i96 };

fn version(io: Io, path: []const u8) ?Version {
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime = st.mtime.nanoseconds };
}

/// Run by the child: polls the binary at `path` and exits the process with
/// `restart_code` once it has changed and two polls in a row agree, so a
/// binary still being written is not started.
pub fn exitWhenChanged(io: Io, path: []const u8) Io.Cancelable!void {
    const first = version(io, path);
    var last = first;
    while (true) {
        try io.sleep(.fromMilliseconds(25), .awake);
        const now = version(io, path);
        if (now != null and !std.meta.eql(now, first) and std.meta.eql(now, last)) {
            std.process.exit(restart_code);
        }
        last = now;
    }
}
