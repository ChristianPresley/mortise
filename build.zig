const std = @import("std");
const builtin = @import("builtin");

/// The one Zig release Mortise builds with. Keep in sync with
/// `minimum_zig_version` in build.zig.zon and ZIG_VERSION in CI.
const required_zig = "0.16.0";

/// The package manifest, read at compile time. Its `dependencies` field is
/// typed as an empty struct, so adding any dependency to build.zig.zon
/// makes the build fail: Mortise has no third-party dependencies.
const manifest: struct {
    name: @EnumLiteral(),
    version: []const u8,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    dependencies: struct {},
    paths: []const []const u8,
} = @import("build.zig.zon");

comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, required_zig)) {
        @compileError("Mortise requires Zig " ++ required_zig ++ " exactly; found " ++ builtin.zig_version_string);
    }
    if (!std.mem.eql(u8, manifest.minimum_zig_version, required_zig)) {
        @compileError("build.zig.zon must pin minimum_zig_version to " ++ required_zig);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("mortise", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "mortise",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mortise", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // `zig build dev --watch -fincremental` rebuilds mortise in about 0.1 s
    // after each save, for use with `mortise serve --restart-on-rebuild`.
    // On x86_64 it uses Zig's own backend, which compiles far faster than
    // LLVM and is what incremental compilation needs.
    const dev_exe = b.addExecutable(.{
        .name = "mortise",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "mortise", .module = mod },
            },
        }),
    });
    if (target.result.cpu.arch == .x86_64) dev_exe.use_llvm = false;
    const dev_step = b.step("dev", "Build a Debug mortise quickly, for zig build dev --watch -fincremental");
    const dev_install = b.addInstallArtifact(dev_exe, .{});
    // Incremental linking patches the cached binary in place, which on
    // Windows can leave its modified time unchanged, so the install above
    // may skip it as up to date. Copy it every time it is rebuilt.
    const dev_copy = CopyAlways.create(b, dev_exe.getEmittedBin(), b.getInstallPath(.bin, dev_exe.out_filename));
    dev_copy.step.dependOn(&dev_install.step);
    dev_step.dependOn(&dev_copy.step);

    const run_step = b.step("run", "Run mortise");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    // `zig build bench -- [PAGES] [RUNS]` measures save-to-reload latency.
    // It always builds optimized, since debug timings say little.
    const bench_exe = b.addExecutable(.{
        .name = "reload-latency",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/reload_latency.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "mortise", .module = b.createModule(.{
                    .root_source_file = b.path("src/root.zig"),
                    .target = target,
                    .optimize = .ReleaseFast,
                }) },
            },
        }),
    });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    b.step("bench", "Run the save-to-reload latency benchmark").dependOn(&bench_run.step);

    // Fixture tests find their inputs through absolute paths baked in here.
    const test_paths = b.addOptions();
    test_paths.addOption([]const u8, "markdown_fixtures", b.pathFromRoot("test/fixtures/markdown"));
    test_paths.addOption([]const u8, "site_basic", b.pathFromRoot("test/fixtures/site-basic"));
    test_paths.addOption([]const u8, "site_basic_expected", b.pathFromRoot("test/expected/site-basic"));
    test_paths.addOption([]const u8, "showcase", b.pathFromRoot("examples/showcase"));
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mortise", .module = mod },
                .{ .name = "test_paths", .module = test_paths.createModule() },
            },
        }),
    });

    // `zig build update-fixtures` regenerates expected fixture outputs from
    // the current implementation, for review before committing.
    const update_fixtures = b.addExecutable(.{
        .name = "update-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/update_fixtures.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mortise", .module = mod },
                .{ .name = "test_paths", .module = test_paths.createModule() },
            },
        }),
    });
    b.step("update-fixtures", "Regenerate expected fixture outputs").dependOn(&b.addRunArtifact(update_fixtures).step);

    const test_step = b.step("test", "Run all unit and fixture tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);
}

/// Copies a generated file to an absolute path whenever the step runs,
/// without the up-to-date check that installing does.
const CopyAlways = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    dest: []const u8,

    fn create(b: *std.Build, source: std.Build.LazyPath, dest: []const u8) *CopyAlways {
        const self = b.allocator.create(CopyAlways) catch @panic("OOM");
        self.* = .{
            .step = .init(.{ .id = .custom, .name = "copy dev binary", .owner = b, .makeFn = make }),
            .source = source,
            .dest = dest,
        };
        source.addStepDependencies(&self.step);
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CopyAlways = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const src = self.source.getPath3(b, step);
        try src.root_dir.handle.copyFile(src.sub_path, std.Io.Dir.cwd(), self.dest, io, .{});
    }
};
