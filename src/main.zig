const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const mortise = @import("mortise");
const SiteDir = mortise.SiteDir;
const pipeline = mortise.pipeline;

const usage =
    \\Usage: mortise <command> [SITE_DIR]
    \\
    \\Commands:
    \\  build     Build SITE_DIR (default: the current directory) into SITE_DIR/_site
    \\  serve     Build, serve on localhost, and reload the browser on change
    \\  version   Print the version
    \\  help      Print this message
    \\
;

const Command = enum { build, serve, version, help };

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
        .build => cmdBuild(ctx, args[2..]),
        .serve => {
            ctx.err.writeAll("mortise: 'serve' is not implemented yet\n") catch {};
            return 1;
        },
    };
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
    const dir = siteDirArg(ctx, rest) orelse return 2;
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
    const site = pipeline.build(arena, src, &diag) catch |e| {
        switch (e) {
            error.BuildFailed => ctx.err.print("error: {f}\n", .{diag}) catch {},
            error.OutOfMemory => ctx.err.writeAll("error: out of memory\n") catch {},
        }
        return 1;
    };

    src.deleteTree(pipeline.output_dir) catch |e| {
        ctx.err.print("error: cannot clear {s}/{s}: {s}\n", .{ dir, pipeline.output_dir, @errorName(e) }) catch {};
        return 1;
    };
    var out = src.openSub(pipeline.output_dir) catch |e| {
        ctx.err.print("error: cannot create {s}/{s}: {s}\n", .{ dir, pipeline.output_dir, @errorName(e) }) catch {};
        return 1;
    };
    defer out.close();
    pipeline.writeSite(site, src, out, &diag) catch {
        ctx.err.print("error: cannot write {s}/{s}/{f}\n", .{ dir, pipeline.output_dir, diag }) catch {};
        return 1;
    };

    const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw;
    ctx.out.print("Built {d} pages, {d} posts, and {d} static files into {s}/{s} in {d} ms\n", .{
        site.pages, site.posts, site.static_files, dir, pipeline.output_dir, elapsed.toMilliseconds(),
    }) catch return 1;
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

test "build reports a missing site directory" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    try testing.expectEqual(@as(u8, 1), run(testCtx(&out, &err), &.{ "mortise", "build", "does-not-exist-9f2c" }));
    try testing.expectStringStartsWith(err.buffered(), "mortise: cannot open site directory 'does-not-exist-9f2c'");
}
