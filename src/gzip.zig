//! Precompressed outputs: with `gzip: true` in `_config.yml`, `build`
//! writes `NAME.gz` next to every text file over 1 KiB, for servers that
//! send precompressed files (nginx `gzip_static`, Caddy `precompressed`).
//!
//! Files are compressed at the best level with the standard library's
//! deflate. The gzip header carries no time stamp or file name, so the
//! same input always gives the same bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Smaller files gain too little to be worth a second copy.
pub const min_size = 1024;

/// Extensions of text files worth compressing.
const extensions = [_][]const u8{ ".html", ".htm", ".css", ".js", ".mjs", ".json", ".xml", ".svg", ".txt", ".md", ".webmanifest", ".map", ".csv" };

/// Whether `path` with `size` bytes gets a `.gz` copy.
pub fn wanted(path: []const u8, size: usize) bool {
    if (size < min_size) return false;
    for (extensions) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}

/// `data` in the gzip format (RFC 1952).
pub fn compress(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, @max(64, data.len / 3));
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var c = flate.Compress.init(&out.writer, window, .gzip, .best) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

const testing = std.testing;

test "wanted" {
    try testing.expect(wanted("index.html", 4096));
    try testing.expect(wanted("css/site.css", 1024));
    try testing.expect(!wanted("index.html", 1023));
    try testing.expect(!wanted("img/a.png", 1 << 20));
}

test "compress round-trips and is deterministic" {
    const data = "<p>hello hello hello hello</p>\n" ** 64;
    const a = try compress(testing.allocator, data);
    defer testing.allocator.free(a);
    const b = try compress(testing.allocator, data);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
    try testing.expect(a.len < data.len / 4);
    // No time stamp: bytes 4..8 are zero.
    try testing.expectEqualSlices(u8, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0 }, a[0..8]);

    var in: std.Io.Reader = .fixed(a);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .gzip, &window);
    const back = try d.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(data, back);
}
