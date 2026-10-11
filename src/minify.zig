//! Conservative minification for `minify: true`: changes that cannot
//! alter how a page renders.
//!
//! HTML: comments go (except conditional comments), and runs of
//! whitespace between tags shrink to one space, or a newline when they
//! held one. Whitespace is never removed entirely, since between inline
//! elements it is visible. `<pre>`, `<textarea>`, `<script>` and `<style>`
//! keep their contents as they are.
//!
//! CSS: comments go (except `/*! ... */` licence comments), runs of
//! whitespace become one space, and spaces around `{ } ; : ,` and before
//! `!important` go. Strings and `url(...)` are copied as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn html(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, src.len);
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '<') {
            if (std.mem.startsWith(u8, src[i..], "<!--")) {
                const end = std.mem.indexOfPos(u8, src, i + 4, "-->") orelse src.len;
                const body = src[i + 4 .. end];
                if (std.mem.startsWith(u8, body, "[if") or std.mem.startsWith(u8, body, "<![endif]")) {
                    try out.appendSlice(arena, src[i..@min(src.len, end + 3)]);
                }
                i = @min(src.len, end + 3);
                continue;
            }
            // Raw text and preformatted elements are copied whole.
            const raw = [_][]const u8{ "pre", "textarea", "script", "style" };
            for (raw) |tag| {
                if (startsWithTag(src[i + 1 ..], tag)) {
                    const close = try std.fmt.allocPrint(arena, "</{s}", .{tag});
                    const end = indexOfIgnoreCase(src, i + 1, close) orelse src.len;
                    const gt = if (end < src.len) (std.mem.indexOfScalarPos(u8, src, end, '>') orelse src.len) else src.len;
                    try out.appendSlice(arena, src[i..@min(src.len, gt + 1)]);
                    i = @min(src.len, gt + 1);
                    break;
                }
            } else {
                const end = std.mem.indexOfScalarPos(u8, src, i, '>') orelse src.len;
                try out.appendSlice(arena, src[i..@min(src.len, end + 1)]);
                i = @min(src.len, end + 1);
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            var j = i;
            var newline = false;
            while (j < src.len and std.ascii.isWhitespace(src[j])) : (j += 1) {
                if (src[j] == '\n') newline = true;
            }
            // Whitespace on both sides of a removed comment is one run.
            const last = if (out.items.len > 0) out.items[out.items.len - 1] else 0;
            if (last == ' ' or last == '\n') {
                if (newline) out.items[out.items.len - 1] = '\n';
            } else {
                try out.append(arena, if (newline) '\n' else ' ');
            }
            i = j;
            continue;
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

fn startsWithTag(s: []const u8, tag: []const u8) bool {
    if (s.len < tag.len or !std.ascii.eqlIgnoreCase(s[0..tag.len], tag)) return false;
    return s.len == tag.len or s[tag.len] == '>' or std.ascii.isWhitespace(s[tag.len]);
}

fn indexOfIgnoreCase(h: []const u8, start: usize, needle: []const u8) ?usize {
    var i = start;
    while (i + needle.len <= h.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(h[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn css(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, src.len);
    var i: usize = 0;
    var pending_space = false;
    while (i < src.len) {
        const c = src[i];
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            const end = std.mem.indexOfPos(u8, src, i + 2, "*/") orelse src.len;
            if (i + 2 < src.len and src[i + 2] == '!') try out.appendSlice(arena, src[i..@min(src.len, end + 2)]);
            i = @min(src.len, end + 2);
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            pending_space = out.items.len > 0;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const end = stringEnd(src, i);
            if (pending_space and needsSpace(out.items)) try out.append(arena, ' ');
            pending_space = false;
            try out.appendSlice(arena, src[i..end]);
            i = end;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "url(")) {
            const end = (std.mem.indexOfScalarPos(u8, src, i, ')') orelse src.len - 1) + 1;
            if (pending_space and needsSpace(out.items)) try out.append(arena, ' ');
            pending_space = false;
            try out.appendSlice(arena, src[i..@min(end, src.len)]);
            i = @min(end, src.len);
            continue;
        }
        const tight = "{};:,>";
        const last: u8 = if (out.items.len > 0) out.items[out.items.len - 1] else '{';
        if (pending_space and std.mem.indexOfScalar(u8, tight, c) == null and std.mem.indexOfScalar(u8, tight, last) == null) {
            try out.append(arena, ' ');
        }
        pending_space = false;
        // `;` right before `}` is not needed.
        if (c == '}' and out.items.len > 0 and out.items[out.items.len - 1] == ';') out.items.len -= 1;
        try out.append(arena, c);
        i += 1;
    }
    return out.items;
}

fn stringEnd(s: []const u8, start: usize) usize {
    const q = s[start];
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == q) return i + 1;
    }
    return s.len;
}

/// Whether a space is needed after what is written so far.
fn needsSpace(out: []const u8) bool {
    if (out.len == 0) return false;
    return std.mem.indexOfScalar(u8, "{};:,>", out[out.len - 1]) == null;
}

const testing = std.testing;

test "html keeps visible spaces and raw elements" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "<p>a <b>b</b> c</p>\n<pre>  keep\n    this  </pre>\n<!--[if IE]>x<![endif]-->\n<script>if (a  <  b) {}</script>",
        try html(a, "<p>a   <b>b</b>  c</p>\n\n   <!-- note --><pre>  keep\n    this  </pre>\n  <!--[if IE]>x<![endif]-->\n<script>if (a  <  b) {}</script>"),
    );
}

test "css drops comments and spaces but not strings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "/*! keep */ a>b,c{color:red;content:\"a  b\";background:url( x.png )}@media (min-width:1px){p{margin:0 auto}}",
        try css(a, "/*! keep */\na  >  b ,\n c {\n  color : red ; /* gone */\n  content: \"a  b\";\n background: url( x.png );\n}\n@media (min-width: 1px) {\n  p { margin: 0  auto; }\n}\n"),
    );
}
