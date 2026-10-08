const std = @import("std");
const Io = std.Io;
const mortise = @import("mortise");

const usage =
    \\Usage: mortise <command>
    \\
    \\Commands:
    \\  build     Build the site into the output directory
    \\  serve     Build, serve on localhost, and reload the browser on change
    \\  version   Print the version
    \\  help      Print this message
    \\
;

const Command = enum { build, serve, version, help };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const err = &stderr_writer.interface;

    const status = run(args, out, err);
    out.flush() catch {};
    err.flush() catch {};
    return status;
}

fn run(args: []const [:0]const u8, out: *Io.Writer, err: *Io.Writer) u8 {
    if (args.len < 2) {
        err.writeAll(usage) catch {};
        return 2;
    }
    const cmd = parseCommand(args[1]) orelse {
        err.print("mortise: unknown command '{s}'\n\n{s}", .{ args[1], usage }) catch {};
        return 2;
    };
    switch (cmd) {
        .help => out.writeAll(usage) catch return 1,
        .version => out.print("mortise {s}\n", .{mortise.version}) catch return 1,
        .build, .serve => {
            err.print("mortise: '{s}' is not implemented yet\n", .{@tagName(cmd)}) catch {};
            return 1;
        },
    }
    return 0;
}

fn parseCommand(arg: []const u8) ?Command {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .help;
    if (std.mem.eql(u8, arg, "--version")) return .version;
    return std.meta.stringToEnum(Command, arg);
}

test "parseCommand" {
    try std.testing.expectEqual(Command.build, parseCommand("build").?);
    try std.testing.expectEqual(Command.serve, parseCommand("serve").?);
    try std.testing.expectEqual(Command.help, parseCommand("--help").?);
    try std.testing.expect(parseCommand("deploy") == null);
}

test "run reports unknown commands with usage" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out: Io.Writer = .fixed(&out_buf);
    var err: Io.Writer = .fixed(&err_buf);
    const status = run(&.{ "mortise", "deploy" }, &out, &err);
    try std.testing.expectEqual(@as(u8, 2), status);
    try std.testing.expectStringStartsWith(err.buffered(), "mortise: unknown command 'deploy'");
}
