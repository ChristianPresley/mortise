const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mortise = @import("mortise");
const SiteDir = mortise.SiteDir;
const pipeline = mortise.pipeline;
const restart = @import("restart.zig");

const usage =
    \\Usage: mortise <command> [SITE_DIR] [options]
    \\
    \\Commands:
    \\  new       Create a new site in SITE_DIR (required; must be empty or missing)
    \\  build     Build SITE_DIR (default: the current directory) into SITE_DIR/_site
    \\  serve     Serve SITE_DIR on localhost and reload the browser on every change
    \\  version   Print the version
    \\  help      Print this message
    \\
    \\Options for build and serve:
    \\  --drafts  Include pages and posts marked draft: true
    \\
    \\Options for serve:
    \\  --port N  Port to listen on (default: 4000)
    \\  --restart-on-rebuild
    \\            Restart the server when the mortise binary is rebuilt, for
    \\            working on Mortise itself with: zig build dev --watch -fincremental
    \\
;

const Command = enum { new, build, serve, version, help };

const Ctx = struct {
    io: Io,
    gpa: Allocator,
    out: *Io.Writer,
    err: *Io.Writer,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err = &stderr_writer.interface;

    var status = run(.{ .io = io, .gpa = init.gpa, .out = out, .err = err }, args);
    // Buffered output is only written here, so a failed flush means the
    // command's output never arrived.
    out.flush() catch {
        status = 1;
    };
    err.flush() catch {};
    return status;
}

fn run(ctx: Ctx, args: []const [:0]const u8) u8 {
    if (args.len < 2) {
        ctx.err.writeAll(usage) catch {};
        return 2;
    }
    const cmd = parseCommand(args[1]) orelse {
        ctx.err.print("mortise: unknown command '{s}'\n\n{s}", .{ args[1], usage }) catch {};
        return 2;
    };
    return switch (cmd) {
        .help => if (ctx.out.writeAll(usage)) 0 else |_| 1,
        .version => if (ctx.out.print("mortise {s}\n", .{mortise.version})) 0 else |_| 1,
        .new => cmdNew(ctx, args[2..]),
        .build => cmdBuild(ctx, args[2..]),
        .serve => cmdServe(ctx, args),
    };
}

fn cmdNew(ctx: Ctx, rest: []const [:0]const u8) u8 {
    if (rest.len != 1 or rest[0].len == 0 or rest[0][0] == '-') {
        ctx.err.writeAll("mortise: 'new' needs exactly one directory, as in: mortise new my-site\n") catch {};
        return 2;
    }
    const dir = rest[0];
    var buf: [10]u8 = undefined;
    mortise.scaffold.create(ctx.io, dir, mortise.scaffold.today(ctx.io, &buf)) catch |e| {
        switch (e) {
            error.DirectoryNotEmpty => ctx.err.print("mortise: '{s}' is not empty\n", .{dir}) catch {},
            else => ctx.err.print("mortise: cannot create a site in '{s}': {s}\n", .{ dir, @errorName(e) }) catch {},
        }
        return 1;
    };
    ctx.out.print("Created a new site in {s}. Run: mortise serve {s}\n", .{ dir, dir }) catch return 1;
    return 0;
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    if (std.mem.eql(u8, arg, "--version")) return .version;
    return std.meta.stringToEnum(Command, arg);
}

/// Returns the site directory argument, or null after printing a usage error.
fn siteDirArg(ctx: Ctx, rest: []const [:0]const u8) ?[]const u8 {
    var dir: ?[]const u8 = null;
    for (rest) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            ctx.err.print("mortise: unknown option '{s}'\n\n{s}", .{ arg, usage }) catch {};
            return null;
        }
        if (dir != null) {
            ctx.err.print("mortise: expected one site directory, got '{s}' and '{s}'\n", .{ dir.?, arg }) catch {};
            return null;
        }
        dir = arg;
    }
    return dir orelse ".";
}

fn cmdBuild(ctx: Ctx, rest: []const [:0]const u8) u8 {
    const args = parseArgs(ctx, rest, false) orelse return 2;
    const dir = args.dir;
    const io = ctx.io;
    var src = SiteDir.open(io, dir) catch |e| {
        ctx.err.print("mortise: cannot open site directory '{s}': {s}\n", .{ dir, @errorName(e) }) catch {};
        return 1;
    };
    defer src.close();

    var build_arena: mortise.BuildArena = .init(ctx.gpa);
    defer build_arena.deinit();
    const arena = build_arena.begin();

    const start = Io.Clock.Timestamp.now(io, .awake);
    var diag: pipeline.Diagnostic = .{};
    const site = pipeline.buildWith(arena, src, .{ .drafts = args.drafts }, &diag) catch |e| {
        switch (e) {
            error.BuildFailed => ctx.err.print("error: {f}\n", .{diag}) catch {},
            error.OutOfMemory => ctx.err.writeAll("error: out of memory\n") catch {},
        }
        return 1;
    };

    pipeline.writeOutputDir(site, src, &diag) catch {
        ctx.err.print("error: cannot write {s}/{s}: {f}\n", .{ dir, pipeline.output_dir, diag }) catch {};
        return 1;
    };

    const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw;
    ctx.out.print("Built {d} pages, {d} posts, and {d} static files into {s}/{s} in {d} ms\n", .{
        site.pages, site.posts, site.static_files, dir, pipeline.output_dir, elapsed.toMilliseconds(),
    }) catch return 1;
    return 0;
}

const Args = struct {
    dir: []const u8 = ".",
    port: u16 = 4000,
    drafts: bool = false,
    restart_on_rebuild: bool = false,
    /// Set in a server started by the restart supervisor.
    restarted_from: ?[]const u8 = null,
};

/// Parses `[SITE_DIR] [--drafts]`, plus the serve options when `serve`.
/// Returns null after printing a usage error.
fn parseArgs(ctx: Ctx, rest: []const [:0]const u8, serve: bool) ?Args {
    var result: Args = .{};
    var buf: [4][:0]const u8 = undefined;
    var positional: std.ArrayList([:0]const u8) = .initBuffer(&buf);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (std.mem.eql(u8, arg, "--drafts")) {
            result.drafts = true;
            continue;
        }
        if (serve and std.mem.eql(u8, arg, "--restart-on-rebuild")) {
            result.restart_on_rebuild = true;
            continue;
        }
        if (serve and std.mem.startsWith(u8, arg, restart.child_flag)) {
            result.restarted_from = arg[restart.child_flag.len..];
            continue;
        }
        const is_port = std.mem.eql(u8, arg, "--port") or std.mem.startsWith(u8, arg, "--port=");
        if (is_port and !serve) {
            ctx.err.print("mortise: unknown option '{s}'\n\n{s}", .{ arg, usage }) catch {};
            return null;
        }
        const port_text: ?[]const u8 = if (std.mem.eql(u8, arg, "--port")) blk: {
            i += 1;
            if (i == rest.len) {
                ctx.err.writeAll("mortise: --port needs a number\n") catch {};
                return null;
            }
            break :blk rest[i];
        } else if (std.mem.startsWith(u8, arg, "--port=")) arg["--port=".len..] else null;
        if (port_text) |t| {
            result.port = std.fmt.parseInt(u16, t, 10) catch {
                ctx.err.print("mortise: invalid port '{s}'\n", .{t}) catch {};
                return null;
            };
            continue;
        }
        positional.appendBounded(arg) catch {
            ctx.err.writeAll("mortise: too many arguments\n") catch {};
            return null;
        };
    }
    result.dir = siteDirArg(ctx, positional.items) orelse return null;
    return result;
}

fn cmdServe(ctx: Ctx, argv: []const [:0]const u8) u8 {
    const args = parseArgs(ctx, argv[2..], true) orelse return 2;
    const io = ctx.io;
    if (args.restart_on_rebuild and args.restarted_from == null) {
        var buf: [32][]const u8 = undefined;
        var child_args: std.ArrayList([]const u8) = .initBuffer(&buf);
        for (argv) |a| {
            if (std.mem.eql(u8, a, "--restart-on-rebuild")) continue;
            child_args.appendBounded(a) catch {
                ctx.err.writeAll("mortise: too many arguments\n") catch {};
                return 2;
            };
        }
        ctx.out.flush() catch {};
        return restart.supervise(io, ctx.gpa, ctx.out, ctx.err, child_args.items);
    }
    // Each process starts its build count from the clock, so pages built by
    // an earlier process (before a restart) reload when they reconnect.
    const first_generation: u64 = @intCast(@max(0, Io.Clock.real.now(io).toMilliseconds()));
    const server = mortise.server.Server.init(ctx.gpa, io, args.dir, .{
        .port = args.port,
        .log = ctx.out,
        .build = .{ .drafts = args.drafts },
        .first_generation = first_generation,
    }) catch |e| {
        switch (e) {
            error.AddressInUse => ctx.err.print("mortise: port {d} is in use; try --port\n", .{args.port}) catch {},
            else => ctx.err.print("mortise: cannot serve '{s}': {s}\n", .{ args.dir, @errorName(e) }) catch {},
        }
        return 1;
    };
    defer server.deinit();

    var watcher = mortise.watch.Watcher.init(ctx.gpa, io, args.dir) catch |e| {
        ctx.err.print("mortise: cannot watch '{s}' for changes: {s}\n", .{ args.dir, @errorName(e) }) catch {};
        return 1;
    };
    defer watcher.deinit();
    if (watcher.fallback_reason) |reason| {
        ctx.out.print("warning: native file watching is unavailable ({s}); polling for changes instead\n", .{@errorName(reason)}) catch {};
    }

    server.start() catch |e| {
        ctx.err.print("mortise: cannot start the server: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    server.watch(&watcher) catch |e| {
        ctx.err.print("mortise: cannot start watching: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    ctx.out.print("Serving {s} at ", .{args.dir}) catch {};
    server.writeUrl(ctx.out) catch {};
    ctx.out.print(" (watching with {s}). Press Ctrl+C to stop.\n", .{watcher.backendName()}) catch {};
    ctx.out.flush() catch {};
    if (args.restarted_from) |exe| {
        var poll = io.concurrent(restart.exitWhenChanged, .{ io, exe }) catch |e| {
            ctx.err.print("mortise: cannot watch the mortise binary: {s}\n", .{@errorName(e)}) catch {};
            return 1;
        };
        defer poll.cancel(io) catch {};
        server.wait();
        return 0;
    }
    server.wait();
    return 0;
}

const testing = std.testing;

fn testCtx(out: *Io.Writer, err: *Io.Writer) Ctx {
    return .{ .io = testing.io, .gpa = testing.allocator, .out = out, .err = err };
}

test "parseCommand" {
    try testing.expectEqual(Command.build, parseCommand("build").?);
    try testing.expectEqual(Command.serve, parseCommand("serve").?);
    try testing.expectEqual(Command.help, parseCommand("--help").?);
    try testing.expect(parseCommand("deploy") == null);
}

test "run reports unknown commands and options with usage" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 2), run(testCtx(&out, &err), &.{ "mortise", "deploy" }));
    try testing.expectStringStartsWith(err.buffered(), "mortise: unknown command 'deploy'");

    err = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 2), run(testCtx(&out, &err), &.{ "mortise", "build", "--fast" }));
    try testing.expectStringStartsWith(err.buffered(), "mortise: unknown option '--fast'");
}

test "parseArgs" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    const ctx = testCtx(&out, &err);
    const a = parseArgs(ctx, &.{ "site", "--port", "8080", "--drafts" }, true).?;
    try testing.expectEqualStrings("site", a.dir);
    try testing.expectEqual(@as(u16, 8080), a.port);
    try testing.expect(a.drafts);
    const b = parseArgs(ctx, &.{"--port=0"}, true).?;
    try testing.expectEqualStrings(".", b.dir);
    try testing.expectEqual(@as(u16, 0), b.port);
    try testing.expect(!b.drafts);
    try testing.expect(parseArgs(ctx, &.{"--port"}, true) == null);
    try testing.expect(parseArgs(ctx, &.{ "--port", "99999" }, true) == null);
    try testing.expect(parseArgs(ctx, &.{ "a", "b" }, true) == null);
    // build takes --drafts but not --port.
    try testing.expect(parseArgs(ctx, &.{"--drafts"}, false).?.drafts);
    try testing.expect(parseArgs(ctx, &.{ "--port", "1" }, false) == null);
    // Restarting on rebuild is for serve only.
    const r = parseArgs(ctx, &.{ "site", "--restart-on-rebuild", "--restarted-from=bin/mortise" }, true).?;
    try testing.expect(r.restart_on_rebuild);
    try testing.expectEqualStrings("bin/mortise", r.restarted_from.?);
    try testing.expectEqualStrings("site", r.dir);
    try testing.expect(parseArgs(ctx, &.{"--restart-on-rebuild"}, false) == null);
}

test "new needs exactly one directory" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 2), run(testCtx(&out, &err), &.{ "mortise", "new" }));
    try testing.expectStringStartsWith(err.buffered(), "mortise: 'new' needs exactly one directory");
}

test "build reports a missing site directory" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 1), run(testCtx(&out, &err), &.{ "mortise", "build", "does-not-exist-9f2c" }));
    try testing.expectStringStartsWith(err.buffered(), "mortise: cannot open site directory 'does-not-exist-9f2c'");
}
