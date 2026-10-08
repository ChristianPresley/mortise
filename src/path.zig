//! Site paths: the one canonical form Mortise uses for every source and
//! output path inside a site root.
//!
//! A site path is relative to a root directory, uses `/` as its only
//! separator, and has no empty, `.` or `..` components. Both `/` and `\` are
//! accepted as separators on input on every platform, so a site authored on
//! Windows builds the same on Linux and macOS.
//!
//! Components are also checked for portability: a name that Windows cannot
//! create is rejected everywhere, so a site never builds on one OS and fails
//! on another.
//!
//! The standard library accepts `/` in sub-paths on Windows, so site paths
//! are passed to `std.Io.Dir` calls as-is.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// The path is empty or normalizes to the root itself.
    EmptyPath,
    /// The path is absolute (`/x`, `\x`, `C:\x`, `C:x`, `\\server\share`).
    AbsolutePath,
    /// A `..` component would climb above the site root.
    EscapesRoot,
    /// A component contains a byte that is not portable across platforms.
    InvalidCharacter,
    /// A component is a reserved Windows device name such as `CON` or `nul.txt`.
    ReservedName,
    /// A component ends with `.` or a space, which Windows silently strips.
    TrailingDotOrSpace,
};

pub fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Normalizes `raw` into a site path. Caller owns the result.
pub fn normalize(gpa: Allocator, raw: []const u8) (Error || Allocator.Error)![]u8 {
    if (raw.len == 0) return error.EmptyPath;
    if (isSep(raw[0])) return error.AbsolutePath;
    // A drive letter (`C:`) makes a path absolute or drive-relative on Windows.
    if (raw.len >= 2 and raw[1] == ':' and std.ascii.isAlphabetic(raw[0])) return error.AbsolutePath;

    var out: std.ArrayList(u8) = try .initCapacity(gpa, raw.len);
    errdefer out.deinit(gpa);

    var it = std.mem.tokenizeAny(u8, raw, "/\\");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (out.items.len == 0) return error.EscapesRoot;
            const cut = std.mem.lastIndexOfScalar(u8, out.items, '/') orelse 0;
            out.shrinkRetainingCapacity(cut);
            continue;
        }
        try checkComponent(comp);
        if (out.items.len != 0) out.appendAssumeCapacity('/');
        out.appendSliceAssumeCapacity(comp);
    }

    if (out.items.len == 0) return error.EmptyPath;
    return out.toOwnedSlice(gpa);
}

/// Reports whether `p` is already in canonical site-path form.
pub fn isNormalized(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[p.len - 1] == '/') return false;
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) return false;
        if (std.mem.eql(u8, comp, ".") or std.mem.eql(u8, comp, "..")) return false;
        checkComponent(comp) catch return false;
    }
    return true;
}

fn checkComponent(comp: []const u8) Error!void {
    for (comp) |c| switch (c) {
        0...0x1f, '<', '>', ':', '"', '|', '?', '*', '\\' => return error.InvalidCharacter,
        else => {},
    };
    const last = comp[comp.len - 1];
    if (last == '.' or last == ' ') return error.TrailingDotOrSpace;
    if (isReservedName(comp)) return error.ReservedName;
}

const reserved_names = [_][]const u8{
    "CON",  "PRN",  "AUX",  "NUL",
    "COM1", "COM2", "COM3", "COM4",
    "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3",
    "LPT4", "LPT5", "LPT6", "LPT7",
    "LPT8", "LPT9",
    // Windows also reserves the superscript-digit aliases.
    "COM\u{b9}", "COM\u{b2}", "COM\u{b3}",
    "LPT\u{b9}", "LPT\u{b2}", "LPT\u{b3}",
};

fn isReservedName(comp: []const u8) bool {
    // Windows reserves the device name with any extension: `nul.txt` too.
    const base = comp[0 .. std.mem.indexOfScalar(u8, comp, '.') orelse comp.len];
    for (reserved_names) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

/// Joins two site paths (either may contain `..`) and normalizes the result.
pub fn join(gpa: Allocator, a: []const u8, b: []const u8) (Error || Allocator.Error)![]u8 {
    const raw = try std.mem.concat(gpa, u8, &.{ a, "/", b });
    defer gpa.free(raw);
    return normalize(gpa, raw);
}

/// Everything before the last `/`, or null for a top-level entry.
pub fn dirname(p: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return null;
    return p[0..i];
}

pub fn basename(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[i + 1 ..];
}

/// The extension of the last component including its dot, or "" if none.
/// A leading dot (`.gitignore`) is not an extension.
pub fn extension(p: []const u8) []const u8 {
    const base = basename(p);
    const i = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (i == 0) return "";
    return base[i..];
}

/// The last component without its extension.
pub fn stem(p: []const u8) []const u8 {
    const base = basename(p);
    return base[0 .. base.len - extension(p).len];
}

/// Returns `p` with its extension replaced by `ext` (which includes the dot,
/// or is empty to strip). Caller owns the result.
pub fn replaceExtension(gpa: Allocator, p: []const u8, ext: []const u8) Allocator.Error![]u8 {
    const head = p[0 .. p.len - extension(p).len];
    return std.mem.concat(gpa, u8, &.{ head, ext });
}

/// Reports whether any component of `p` starts with `.` or `_`, the prefixes
/// a site uses for files that are not published directly.
pub fn hasHiddenComponent(p: []const u8) bool {
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |comp| {
        if (comp.len != 0 and (comp[0] == '.' or comp[0] == '_')) return true;
    }
    return false;
}

const testing = std.testing;

fn expectNorm(expected: []const u8, raw: []const u8) !void {
    const got = try normalize(testing.allocator, raw);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    try testing.expect(isNormalized(got));
}

test "normalize canonicalizes separators and dot components" {
    try expectNorm("a/b/c.md", "a/b/c.md");
    try expectNorm("a/b/c.md", "a\\b\\c.md");
    try expectNorm("a/b/c.md", "a//b///c.md");
    try expectNorm("a/b/c.md", "./a/./b/c.md");
    try expectNorm("a/c.md", "a/b/../c.md");
    try expectNorm("a/b", "a/b/");
    try expectNorm("c.md", "a\\..\\c.md");
    try expectNorm("posts/2024-01-01-hello.md", "posts\\2024-01-01-hello.md");
}

test "normalize rejects absolute paths" {
    try testing.expectError(error.AbsolutePath, normalize(testing.allocator, "/etc/passwd"));
    try testing.expectError(error.AbsolutePath, normalize(testing.allocator, "\\x"));
    try testing.expectError(error.AbsolutePath, normalize(testing.allocator, "C:\\x"));
    try testing.expectError(error.AbsolutePath, normalize(testing.allocator, "c:x"));
    try testing.expectError(error.AbsolutePath, normalize(testing.allocator, "\\\\server\\share"));
}

test "normalize rejects escaping and empty paths" {
    try testing.expectError(error.EscapesRoot, normalize(testing.allocator, ".."));
    try testing.expectError(error.EscapesRoot, normalize(testing.allocator, "a/../../b"));
    try testing.expectError(error.EmptyPath, normalize(testing.allocator, ""));
    try testing.expectError(error.EmptyPath, normalize(testing.allocator, "."));
    try testing.expectError(error.EmptyPath, normalize(testing.allocator, "a/.."));
}

test "normalize rejects non-portable names" {
    try testing.expectError(error.InvalidCharacter, normalize(testing.allocator, "a/b:c"));
    try testing.expectError(error.InvalidCharacter, normalize(testing.allocator, "what?.md"));
    try testing.expectError(error.InvalidCharacter, normalize(testing.allocator, "a\x00b"));
    try testing.expectError(error.ReservedName, normalize(testing.allocator, "docs/CON"));
    try testing.expectError(error.ReservedName, normalize(testing.allocator, "nul.txt"));
    try testing.expectError(error.ReservedName, normalize(testing.allocator, "com\u{b9}.md"));
    try testing.expectError(error.ReservedName, normalize(testing.allocator, "LPT\u{b3}"));
    try testing.expectError(error.TrailingDotOrSpace, normalize(testing.allocator, "a./b"));
    try testing.expectError(error.TrailingDotOrSpace, normalize(testing.allocator, "a /b"));
    // Prefixes and lookalikes of reserved names are fine.
    try expectNorm("console.md", "console.md");
    try expectNorm("com10/x", "com10/x");
}

test "isNormalized" {
    try testing.expect(isNormalized("a/b.md"));
    try testing.expect(!isNormalized("a\\b.md"));
    try testing.expect(!isNormalized("/a"));
    try testing.expect(!isNormalized("a/"));
    try testing.expect(!isNormalized("a//b"));
    try testing.expect(!isNormalized("a/./b"));
    try testing.expect(!isNormalized("a/../b"));
    try testing.expect(!isNormalized(""));
}

test "join" {
    const j = try join(testing.allocator, "_layouts", "../_includes/nav.html");
    defer testing.allocator.free(j);
    try testing.expectEqualStrings("_includes/nav.html", j);
    try testing.expectError(error.EscapesRoot, join(testing.allocator, "a", "../../b"));
}

test "components" {
    try testing.expectEqualStrings("posts", dirname("posts/hello.md").?);
    try testing.expect(dirname("index.md") == null);
    try testing.expectEqualStrings("hello.md", basename("posts/hello.md"));
    try testing.expectEqualStrings(".md", extension("posts/hello.md"));
    try testing.expectEqualStrings(".gz", extension("a/b.tar.gz"));
    try testing.expectEqualStrings("", extension("a.d/README"));
    try testing.expectEqualStrings("", extension(".gitignore"));
    try testing.expectEqualStrings("hello", stem("posts/hello.md"));
    try testing.expectEqualStrings(".gitignore", stem(".gitignore"));

    const r = try replaceExtension(testing.allocator, "posts/hello.md", ".html");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("posts/hello.html", r);
}

test "hasHiddenComponent" {
    try testing.expect(hasHiddenComponent(".git/config"));
    try testing.expect(hasHiddenComponent("_layouts/base.html"));
    try testing.expect(hasHiddenComponent("a/_drafts/x.md"));
    try testing.expect(!hasHiddenComponent("posts/hello.md"));
}
