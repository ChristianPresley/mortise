//! Charts drawn as inline SVG at build time.
//!
//! A fenced code block with the language `chart` holds a spec in the
//! frontmatter format:
//!
//!   ```chart
//!   type: bar
//!   title: Build time
//!   labels: [100 pages, 1k pages, 10k pages]
//!   series:
//!     cold: [0.2, 0.9, 7.5]
//!     warm: [0.1, 0.4, 3.1]
//!   suffix: " s"
//!   ```
//!
//! It renders as a `<figure class="mt-chart">` holding an SVG and a table
//! of the same numbers for screen readers. Colors come from CSS classes
//! (`mt-chart-s1` to `mt-chart-s6`), so stylesheets and themes can recolor
//! charts; the SVG has no colors of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const frontmatter = @import("frontmatter.zig");

pub const Kind = enum { bar, line, area, pie, donut };

pub const Spec = struct {
    kind: Kind = .bar,
    title: []const u8 = "",
    labels: []const []const u8 = &.{},
    series: []const Series = &.{},
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    min: ?f64 = null,
    max: ?f64 = null,
    height: u32 = 320,
};

pub const Series = struct { name: []const u8, values: []const f64 };

/// Why a spec was rejected: its line within the block, and a message.
pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };

pub const Error = Allocator.Error || error{InvalidChart};

fn fail(arena: Allocator, diag: *Diagnostic, line: usize, comptime fmt: []const u8, args: anytype) Error {
    diag.* = .{ .line = line, .message = try std.fmt.allocPrint(arena, fmt, args) };
    return error.InvalidChart;
}

/// The 1-based line of `key:` in `src`, or 0.
fn keyLine(src: []const u8, key: []const u8) usize {
    var it = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        const t = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, t, key) and t.len > key.len and t[key.len] == ':') return n;
    }
    return 0;
}

fn number(v: frontmatter.Value) ?f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn text(arena: Allocator, v: frontmatter.Value) Allocator.Error!?[]const u8 {
    return switch (v) {
        .string => |s| s,
        .int => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(arena, "{d}", .{f}),
        else => null,
    };
}

/// Parses a chart spec.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!Spec {
    var fd: frontmatter.Diagnostic = .{};
    const map = frontmatter.parseFile(arena, src, &fd) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidFrontmatter => return fail(arena, diag, fd.line, "{s}", .{fd.message}),
    };
    var spec: Spec = .{};
    for (map.entries) |e| {
        const line = keyLine(src, e.key);
        const key = e.key;
        if (std.mem.eql(u8, key, "type")) {
            const s = if (e.value == .string) e.value.string else "";
            spec.kind = std.meta.stringToEnum(Kind, s) orelse return fail(arena, diag, line, "'type' must be bar, line, area, pie or donut", .{});
        } else if (std.mem.eql(u8, key, "title") or std.mem.eql(u8, key, "prefix") or std.mem.eql(u8, key, "suffix")) {
            const s = try text(arena, e.value) orelse return fail(arena, diag, line, "'{s}' must be text", .{key});
            switch (key[0]) {
                't' => spec.title = s,
                'p' => spec.prefix = s,
                else => spec.suffix = s,
            }
        } else if (std.mem.eql(u8, key, "labels")) {
            if (e.value != .list) return fail(arena, diag, line, "'labels' must be a list such as [Jan, Feb, Mar]", .{});
            const labels = try arena.alloc([]const u8, e.value.list.len);
            for (e.value.list, labels) |v, *l| l.* = try text(arena, v) orelse return fail(arena, diag, line, "each label must be text or a number", .{});
            spec.labels = labels;
        } else if (std.mem.eql(u8, key, "values") or std.mem.eql(u8, key, "series")) {
            // `values: [...]` is one unnamed series.
            const entries: []const frontmatter.Entry = if (key[0] == 'v')
                &.{.{ .key = "", .value = e.value }}
            else if (e.value == .map) e.value.map.entries else return fail(arena, diag, line, "'series' must map names to lists of numbers", .{});
            var list: std.ArrayList(Series) = .empty;
            try list.appendSlice(arena, spec.series);
            for (entries) |s| {
                if (s.value != .list) return fail(arena, diag, line, "series '{s}' must be a list of numbers", .{s.key});
                const values = try arena.alloc(f64, s.value.list.len);
                for (s.value.list, values) |v, *out| out.* = number(v) orelse return fail(arena, diag, line, "series '{s}' must hold only numbers", .{s.key});
                try list.append(arena, .{ .name = s.key, .values = values });
            }
            spec.series = list.items;
        } else if (std.mem.eql(u8, key, "min") or std.mem.eql(u8, key, "max")) {
            const n = number(e.value) orelse return fail(arena, diag, line, "'{s}' must be a number", .{key});
            if (key[1] == 'i') spec.min = n else spec.max = n;
        } else if (std.mem.eql(u8, key, "height")) {
            if (e.value != .int or e.value.int < 120 or e.value.int > 1200) return fail(arena, diag, line, "'height' must be a number of pixels from 120 to 1200", .{});
            spec.height = @intCast(e.value.int);
        } else {
            return fail(arena, diag, line, "unknown chart setting '{s}'; use type, title, labels, series, values, prefix, suffix, min, max or height", .{key});
        }
    }
    if (spec.series.len == 0) return fail(arena, diag, 0, "a chart needs 'values' or 'series'", .{});
    if (spec.series.len > palette_size) return fail(arena, diag, keyLine(src, "series"), "a chart can show at most {d} series", .{palette_size});
    for (spec.series) |s| {
        if (s.values.len == 0) return fail(arena, diag, keyLine(src, "series"), "series '{s}' is empty", .{s.name});
        if (spec.labels.len > 0 and s.values.len != spec.labels.len) {
            return fail(arena, diag, keyLine(src, "labels"), "there are {d} labels but series '{s}' has {d} values", .{ spec.labels.len, s.name, s.values.len });
        }
        for (s.values) |v| if (!std.math.isFinite(v)) return fail(arena, diag, keyLine(src, "series"), "values must be finite numbers", .{});
    }
    if (spec.kind == .pie or spec.kind == .donut) {
        if (spec.series.len != 1) return fail(arena, diag, keyLine(src, "series"), "a {s} chart shows one series", .{@tagName(spec.kind)});
        for (spec.series[0].values) |v| if (v < 0) return fail(arena, diag, keyLine(src, "values"), "a {s} chart cannot show negative values", .{@tagName(spec.kind)});
    }
    return spec;
}

const palette_size = 6;
const width: f64 = 640;

/// Renders `src` as a figure, or fails with `diag` set.
pub fn render(arena: Allocator, src: []const u8, w: *Writer, diag: *Diagnostic) (Error || Writer.Error)!void {
    const spec = try parse(arena, src, diag);
    try write(arena, spec, w);
}

pub fn write(arena: Allocator, spec: Spec, w: *Writer) (Allocator.Error || Writer.Error)!void {
    const h: f64 = @floatFromInt(spec.height);
    try w.print("<figure class=\"mt-chart mt-chart-{s}\">\n", .{@tagName(spec.kind)});
    try w.print("<svg viewBox=\"0 0 {d} {d}\" role=\"img\"", .{ width, h });
    if (spec.title.len > 0) {
        try w.writeAll(" aria-label=\"");
        try escape(w, spec.title);
        try w.writeAll("\"");
    }
    try w.writeAll(">\n");
    switch (spec.kind) {
        .pie, .donut => try writePie(arena, spec, w, h),
        else => try writeAxes(arena, spec, w, h),
    }
    try w.writeAll("</svg>\n");
    if (spec.title.len > 0) {
        try w.writeAll("<figcaption>");
        try escape(w, spec.title);
        try w.writeAll("</figcaption>\n");
    }
    try writeTable(spec, w);
    try w.writeAll("</figure>\n");
}

fn label(spec: Spec, i: usize) []const u8 {
    return if (i < spec.labels.len) spec.labels[i] else "";
}

/// A value with the spec's prefix and suffix, with at most two decimals
/// and thousands shortened to k, M or G on axes.
fn writeValue(w: *Writer, spec: Spec, v: f64, short: bool) Writer.Error!void {
    try escape(w, spec.prefix);
    var x = v;
    var unit: []const u8 = "";
    if (short) {
        const a = @abs(v);
        if (a >= 1e9) {
            x = v / 1e9;
            unit = "G";
        } else if (a >= 1e6) {
            x = v / 1e6;
            unit = "M";
        } else if (a >= 1e4) {
            x = v / 1e3;
            unit = "k";
        }
    }
    const rounded = @round(x * 100) / 100;
    if (rounded == @trunc(rounded) and @abs(rounded) < 1e15) {
        try w.print("{d}", .{@as(i64, @intFromFloat(rounded))});
    } else {
        try w.print("{d}", .{rounded});
    }
    try w.writeAll(unit);
    try escape(w, spec.suffix);
}

/// A tick step of 1, 2 or 5 times a power of ten, giving about `n` steps.
fn niceStep(range: f64, n: f64) f64 {
    const raw = range / n;
    const mag = std.math.pow(f64, 10, @floor(std.math.log10(raw)));
    const f = raw / mag;
    const nice: f64 = if (f <= 1) 1 else if (f <= 2) 2 else if (f <= 5) 5 else 10;
    return nice * mag;
}

fn writeAxes(arena: Allocator, spec: Spec, w: *Writer, h: f64) (Allocator.Error || Writer.Error)!void {
    _ = arena;
    const count = spec.series[0].values.len;
    var lo: f64 = if (spec.kind == .line) std.math.inf(f64) else 0;
    var hi: f64 = -std.math.inf(f64);
    for (spec.series) |s| for (s.values) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    };
    if (spec.kind != .line) {
        lo = @min(lo, 0);
        hi = @max(hi, 0);
    }
    if (spec.min) |m| lo = m;
    if (spec.max) |m| hi = m;
    if (hi <= lo) hi = lo + 1;
    const step = niceStep(hi - lo, 5);
    lo = @floor(lo / step) * step;
    hi = @ceil(hi / step) * step;

    const legend = spec.series.len > 1 or spec.series[0].name.len > 0;
    const top: f64 = if (legend) 40 else 16;
    const left: f64 = 56;
    const right: f64 = 16;
    const bottom: f64 = 40;
    const plot_w = width - left - right;
    const plot_h = h - top - bottom;
    const Map = struct {
        lo: f64,
        hi: f64,
        top: f64,
        plot_h: f64,
        fn y(m: @This(), v: f64) f64 {
            return m.top + m.plot_h - (v - m.lo) / (m.hi - m.lo) * m.plot_h;
        }
    };
    const m: Map = .{ .lo = lo, .hi = hi, .top = top, .plot_h = plot_h };

    if (legend) try writeLegend(spec, w, left);

    // Grid lines and value labels.
    try w.writeAll("<g class=\"mt-chart-grid\">\n");
    var t = lo;
    var guard: usize = 0;
    while (t <= hi + step / 2 and guard < 50) : ({
        t += step;
        guard += 1;
    }) {
        const y = m.y(t);
        try w.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\"{s}/>\n", .{ left, y, width - right, y, if (@abs(t) < step / 1e6) " class=\"mt-chart-zero\"" else "" });
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"end\" dominant-baseline=\"middle\">", .{ left - 8, y });
        try writeValue(w, spec, if (@abs(t) < step / 1e6) 0 else t, true);
        try w.writeAll("</text>\n");
    }
    try w.writeAll("</g>\n");

    // Category labels, thinned out so they do not collide.
    const slot = plot_w / @as(f64, @floatFromInt(count));
    const every: usize = @max(1, @as(usize, @intFromFloat(@ceil(48 / slot))));
    try w.writeAll("<g class=\"mt-chart-labels\">\n");
    for (0..count) |i| {
        if (i % every != 0) continue;
        const x = if (spec.kind == .bar) left + slot * (@as(f64, @floatFromInt(i)) + 0.5) else left + plotX(i, count, plot_w);
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">", .{ x, h - bottom + 20 });
        try escape(w, label(spec, i));
        try w.writeAll("</text>\n");
    }
    try w.writeAll("</g>\n");

    const zero_y = m.y(std.math.clamp(0, lo, hi));
    switch (spec.kind) {
        .bar => {
            const group = slot * 0.8;
            const bar_w = group / @as(f64, @floatFromInt(spec.series.len));
            for (spec.series, 0..) |s, si| {
                try w.print("<g class=\"mt-chart-s{d}\">\n", .{si + 1});
                for (s.values, 0..) |v, i| {
                    const x = left + slot * @as(f64, @floatFromInt(i)) + slot * 0.1 + bar_w * @as(f64, @floatFromInt(si));
                    const y = m.y(std.math.clamp(v, lo, hi));
                    try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"><title>", .{ x + 1, @min(y, zero_y), @max(1, bar_w - 2), @abs(zero_y - y) });
                    try writeTip(w, spec, s, i, v);
                    try w.writeAll("</title></rect>\n");
                }
                try w.writeAll("</g>\n");
            }
        },
        .line, .area => {
            for (spec.series, 0..) |s, si| {
                try w.print("<g class=\"mt-chart-s{d}\">\n", .{si + 1});
                if (spec.kind == .area) {
                    try w.print("<path class=\"mt-chart-fill\" d=\"M{d:.1} {d:.1}", .{ left + plotX(0, count, plot_w), zero_y });
                    for (s.values, 0..) |v, i| try w.print(" L{d:.1} {d:.1}", .{ left + plotX(i, count, plot_w), m.y(std.math.clamp(v, lo, hi)) });
                    try w.print(" L{d:.1} {d:.1} Z\"/>\n", .{ left + plotX(count - 1, count, plot_w), zero_y });
                }
                try w.writeAll("<polyline points=\"");
                for (s.values, 0..) |v, i| try w.print("{s}{d:.1},{d:.1}", .{ if (i == 0) "" else " ", left + plotX(i, count, plot_w), m.y(std.math.clamp(v, lo, hi)) });
                try w.writeAll("\"/>\n");
                for (s.values, 0..) |v, i| {
                    try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"3.5\"><title>", .{ left + plotX(i, count, plot_w), m.y(std.math.clamp(v, lo, hi)) });
                    try writeTip(w, spec, s, i, v);
                    try w.writeAll("</title></circle>\n");
                }
                try w.writeAll("</g>\n");
            }
        },
        else => unreachable,
    }
}

/// The x position of point `i` of `count` across a line chart.
fn plotX(i: usize, count: usize, plot_w: f64) f64 {
    if (count <= 1) return plot_w / 2;
    return plot_w * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1));
}

fn writeTip(w: *Writer, spec: Spec, s: Series, i: usize, v: f64) Writer.Error!void {
    if (s.name.len > 0) {
        try escape(w, s.name);
        try w.writeAll(", ");
    }
    if (label(spec, i).len > 0) {
        try escape(w, label(spec, i));
        try w.writeAll(": ");
    }
    try writeValue(w, spec, v, false);
}

fn writeLegend(spec: Spec, w: *Writer, left: f64) Writer.Error!void {
    try w.writeAll("<g class=\"mt-chart-legend\">\n");
    var x = left;
    for (spec.series, 0..) |s, si| {
        try w.print("<rect class=\"mt-chart-s{d}\" x=\"{d:.1}\" y=\"10\" width=\"12\" height=\"12\" rx=\"2\"/>", .{ si + 1, x });
        try w.print("<text x=\"{d:.1}\" y=\"16\" dominant-baseline=\"middle\">", .{x + 18});
        try escape(w, s.name);
        try w.writeAll("</text>\n");
        // An estimate of the name's width, since SVG cannot measure text.
        x += 18 + 7.5 * @as(f64, @floatFromInt(std.unicode.utf8CountCodepoints(s.name) catch s.name.len)) + 20;
    }
    try w.writeAll("</g>\n");
}

fn writePie(arena: Allocator, spec: Spec, w: *Writer, h: f64) (Allocator.Error || Writer.Error)!void {
    _ = arena;
    const values = spec.series[0].values;
    var total: f64 = 0;
    for (values) |v| total += v;
    const r = @min(h / 2 - 16, 150);
    const cx = r + 24;
    const cy = h / 2;
    const inner = if (spec.kind == .donut) r * 0.58 else 0;
    var angle: f64 = -std.math.pi / 2.0;
    for (values, 0..) |v, i| {
        if (total <= 0 or v <= 0) continue;
        const share = v / total;
        const sweep = share * 2 * std.math.pi;
        const end = angle + sweep;
        try w.print("<path class=\"mt-chart-s{d}\" d=\"", .{i % palette_size + 1});
        if (share >= 0.9999) {
            // A full circle cannot be one arc.
            try w.print("M{d:.2} {d:.2} A{d:.2} {d:.2} 0 1 1 {d:.2} {d:.2} A{d:.2} {d:.2} 0 1 1 {d:.2} {d:.2} Z", .{ cx, cy - r, r, r, cx, cy + r, r, r, cx, cy - r });
            if (inner > 0) try w.print(" M{d:.2} {d:.2} A{d:.2} {d:.2} 0 1 0 {d:.2} {d:.2} A{d:.2} {d:.2} 0 1 0 {d:.2} {d:.2} Z", .{ cx, cy - inner, inner, inner, cx, cy + inner, inner, inner, cx, cy - inner });
        } else {
            const large: u8 = if (sweep > std.math.pi) 1 else 0;
            const x0 = cx + r * @cos(angle);
            const y0 = cy + r * @sin(angle);
            const x1 = cx + r * @cos(end);
            const y1 = cy + r * @sin(end);
            if (inner > 0) {
                try w.print("M{d:.2} {d:.2} A{d:.2} {d:.2} 0 {d} 1 {d:.2} {d:.2} L{d:.2} {d:.2} A{d:.2} {d:.2} 0 {d} 0 {d:.2} {d:.2} Z", .{
                    x0, y0, r, r, large, x1, y1,
                    cx + inner * @cos(end), cy + inner * @sin(end), inner, inner, large, cx + inner * @cos(angle), cy + inner * @sin(angle),
                });
            } else {
                try w.print("M{d:.2} {d:.2} L{d:.2} {d:.2} A{d:.2} {d:.2} 0 {d} 1 {d:.2} {d:.2} Z", .{ cx, cy, x0, y0, r, r, large, x1, y1 });
            }
        }
        try w.writeAll("\"><title>");
        try writeTip(w, spec, .{ .name = "", .values = values }, i, v);
        try w.print(" ({d:.0}%)", .{share * 100});
        try w.writeAll("</title></path>\n");
        angle = end;
    }
    // The legend, with each slice's share.
    try w.writeAll("<g class=\"mt-chart-legend\">\n");
    const lx = cx + r + 40;
    const line_h: f64 = 24;
    var ly = cy - line_h * @as(f64, @floatFromInt(values.len)) / 2 + line_h / 2;
    for (values, 0..) |v, i| {
        try w.print("<rect class=\"mt-chart-s{d}\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"12\" height=\"12\" rx=\"2\"/>", .{ i % palette_size + 1, lx, ly - 6 });
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" dominant-baseline=\"middle\">", .{ lx + 18, ly });
        try escape(w, label(spec, i));
        try w.writeAll(" <tspan class=\"mt-chart-share\">");
        try w.print("{d:.0}%", .{if (total > 0) v / total * 100 else 0});
        try w.writeAll("</tspan></text>\n");
        ly += line_h;
    }
    try w.writeAll("</g>\n");
}

/// The chart's numbers as a table, hidden from sight but read by screen
/// readers.
fn writeTable(spec: Spec, w: *Writer) Writer.Error!void {
    try w.writeAll("<table class=\"mt-chart-data\">\n<thead><tr><th></th>");
    for (spec.series) |s| {
        try w.writeAll("<th>");
        try escape(w, if (s.name.len > 0) s.name else "Value");
        try w.writeAll("</th>");
    }
    try w.writeAll("</tr></thead>\n<tbody>\n");
    for (0..spec.series[0].values.len) |i| {
        try w.writeAll("<tr><th>");
        try escape(w, label(spec, i));
        try w.writeAll("</th>");
        for (spec.series) |s| {
            try w.writeAll("<td>");
            try writeValue(w, spec, s.values[i], false);
            try w.writeAll("</td>");
        }
        try w.writeAll("</tr>\n");
    }
    try w.writeAll("</tbody>\n</table>\n");
}

fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (s, 0..) |c, i| {
        const rep: []const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => continue,
        };
        try w.writeAll(s[start..i]);
        try w.writeAll(rep);
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

const testing = std.testing;

fn renderString(arena: Allocator, src: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    var diag: Diagnostic = .{};
    render(arena, src, &aw.writer, &diag) catch |err| {
        std.debug.print("chart error at line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    return aw.written();
}

test "bar charts scale to nice ticks and carry a data table" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const svg = try renderString(a, "title: Pages <built>\nlabels: [A, B]\nseries:\n  cold: [3, 7.5]\n  warm: [1, 2]\nsuffix: \" s\"\n");
    try testing.expect(std.mem.startsWith(u8, svg, "<figure class=\"mt-chart mt-chart-bar\">\n<svg viewBox=\"0 0 640 320\" role=\"img\" aria-label=\"Pages &lt;built&gt;\">"));
    // Ticks run 0 to 8 in steps of 2.
    try testing.expect(std.mem.indexOf(u8, svg, ">8 s</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">10 s</text>") == null);
    try testing.expect(std.mem.indexOf(u8, svg, "<title>cold, B: 7.5 s</title>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "<g class=\"mt-chart-s2\">") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "<tr><th>B</th><td>7.5 s</td><td>2 s</td></tr>") != null);
    try testing.expect(std.mem.endsWith(u8, svg, "<figcaption>Pages &lt;built&gt;</figcaption>\n" ++ "<table class=\"mt-chart-data\">\n<thead><tr><th></th><th>cold</th><th>warm</th></tr></thead>\n<tbody>\n<tr><th>A</th><td>3 s</td><td>1 s</td></tr>\n<tr><th>B</th><td>7.5 s</td><td>2 s</td></tr>\n</tbody>\n</table>\n</figure>\n"));
}

test "line, area, pie and donut charts" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const line = try renderString(a, "type: line\nlabels: [1, 2, 3]\nvalues: [-5, 10, 25000]\n");
    try testing.expect(std.mem.indexOf(u8, line, "<polyline points=\"") != null);
    try testing.expect(std.mem.indexOf(u8, line, ">30k</text>") != null);
    try testing.expect(std.mem.indexOf(u8, line, "<title>3: 25000</title>") != null);
    const area = try renderString(a, "type: area\nvalues: [1, 2]\n");
    try testing.expect(std.mem.indexOf(u8, area, "class=\"mt-chart-fill\"") != null);
    const pie = try renderString(a, "type: pie\nlabels: [Yes, No]\nvalues: [3, 1]\n");
    try testing.expect(std.mem.indexOf(u8, pie, "<title>Yes: 3 (75%)</title>") != null);
    try testing.expect(std.mem.indexOf(u8, pie, "<tspan class=\"mt-chart-share\">25%</tspan>") != null);
    const whole = try renderString(a, "type: donut\nvalues: [5]\n");
    try testing.expect(std.mem.indexOf(u8, whole, "A") != null);
}

test "bad specs name the line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "type: radar\nvalues: [1]\n", 1, "'type' must be" },
        .{ "labels: [a, b]\nvalues: [1]\n", 1, "2 labels but series '' has 1 values" },
        .{ "values: [1, x]\n", 1, "only numbers" },
        .{ "title: t\ncolour: red\nvalues: [1]\n", 2, "unknown chart setting 'colour'" },
        .{ "type: pie\nvalues: [1, -2]\n", 2, "negative" },
        .{ "title: nothing\n", 0, "needs 'values' or 'series'" },
    };
    for (cases) |c| {
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidChart, parse(a, c[0], &diag));
        try testing.expectEqual(c[1], diag.line);
        if (std.mem.indexOf(u8, diag.message, c[2]) == null) {
            std.debug.print("expected '{s}' in '{s}'\n", .{ c[2], diag.message });
            return error.TestUnexpectedResult;
        }
    }
}
