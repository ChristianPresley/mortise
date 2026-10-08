//! Arena-per-build allocation policy.
//!
//! Everything a single build allocates (file contents, parsed documents,
//! rendered pages, path strings) comes from one arena and is freed in one
//! step when the next build begins. Nothing allocated during a build may be
//! kept past it; data that must survive between builds (the dev server's
//! dependency graph, the last good output) is owned by the long-lived `gpa`.
//!
//! Between builds the arena keeps up to `retain_limit` bytes of capacity so
//! the dev server's rebuild loop does not return memory to the OS and ask for
//! it again on every save.

const std = @import("std");
const Allocator = std.mem.Allocator;
const BuildArena = @This();

/// Capacity kept across `begin` calls. A build that grew the arena past this
/// gives the excess back.
pub const default_retain_limit: usize = 64 * 1024 * 1024;

arena: std.heap.ArenaAllocator,
retain_limit: usize,
/// Counts builds started. Zero means `begin` has never been called.
generation: u64 = 0,

pub fn init(gpa: Allocator) BuildArena {
    return .{ .arena = .init(gpa), .retain_limit = default_retain_limit };
}

pub fn deinit(self: *BuildArena) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Frees everything allocated by the previous build and returns the allocator
/// for the next one.
pub fn begin(self: *BuildArena) Allocator {
    if (self.generation != 0) {
        _ = self.arena.reset(.{ .retain_with_limit = self.retain_limit });
    }
    self.generation += 1;
    return self.arena.allocator();
}

/// The allocator for the build in progress. Only valid after `begin`.
pub fn allocator(self: *BuildArena) Allocator {
    std.debug.assert(self.generation != 0);
    return self.arena.allocator();
}

const testing = std.testing;

test "begin frees the previous build's allocations" {
    var ba: BuildArena = .init(testing.allocator);
    defer ba.deinit();

    const a1 = ba.begin();
    _ = try a1.alloc(u8, 1024);
    try testing.expectEqual(@as(u64, 1), ba.generation);

    const a2 = ba.begin();
    try testing.expectEqual(@as(u64, 2), ba.generation);
    // Leak checking in `testing.allocator` verifies deinit releases everything.
    const buf = try a2.alloc(u8, 4096);
    @memset(buf, 0xaa);
}

test "capacity above the retain limit is released" {
    var ba: BuildArena = .init(testing.allocator);
    defer ba.deinit();
    ba.retain_limit = 4096;

    _ = try ba.begin().alloc(u8, 1024 * 1024);
    try testing.expect(ba.arena.queryCapacity() >= 1024 * 1024);
    _ = ba.begin();
    try testing.expect(ba.arena.queryCapacity() <= 4096);
}
