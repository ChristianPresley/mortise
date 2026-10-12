//! The built-in template filters: Mortise's own, Liquid's standard
//! filters, and the filters Jekyll adds. docs/templates.md lists Mortise's
//! and docs/liquid.md the rest.
//!
//! Where Mortise and Liquid define a filter differently (`truncate`,
//! `date`, `default`, `sort`, `where`, `slugify`, `size`, `strip_html` and
//! a few more), the renderer's `liquid` flag picks the definition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const template = @import("template.zig");
const markdown = @import("markdown.zig");
const datetime = @import("datetime.zig");
const Value = template.Value;
const Entry = template.Entry;
const Filter = template.Filter;
const Renderer = template.Renderer;
const RenderError = template.RenderError;
const escapeHtml = markdown.escapeHtml;

pub const Kind = enum {
    // Mortise
    raw,
    upper,
    lower,
    default,
    date,
    slugify,
    truncate,
    markdownify,
    json,
    where,
    sort,
    group_by,
    limit,
    reverse,
    reading_time,
    word_count,
    dump,
    size,
    join,
    first,
    last,
    strip_html,
    asset,
    sri,
    // Liquid
    abs,
    append,
    at_least,
    at_most,
    base64_decode,
    base64_encode,
    base64_url_safe_decode,
    base64_url_safe_encode,
    capitalize,
    ceil,
    compact,
    concat,
    divided_by,
    downcase,
    escape,
    escape_once,
    find,
    find_index,
    floor,
    h,
    has,
    lstrip,
    map,
    minus,
    modulo,
    newline_to_br,
    plus,
    prepend,
    reject,
    remove,
    remove_first,
    remove_last,
    replace,
    replace_first,
    replace_last,
    round,
    rstrip,
    slice,
    sort_natural,
    split,
    strip,
    strip_newlines,
    sum,
    times,
    truncatewords,
    uniq,
    upcase,
    url_decode,
    url_encode,
    // Jekyll
    absolute_url,
    array_to_sentence_string,
    cgi_escape,
    date_to_long_string,
    date_to_rfc822,
    date_to_string,
    date_to_xml_schema,
    find_exp,
    group_by_exp,
    inspect,
    jsonify,
    normalize_whitespace,
    number_of_words,
    pop,
    push,
    relative_url,
    sample,
    shift,
    smartify,
    to_integer,
    unshift,
    uri_escape,
    where_exp,
    xml_escape,
};

/// The minimum and maximum number of arguments.
pub fn arity(k: Kind) [2]usize {
    return switch (k) {
        .default, .limit, .append, .at_least, .at_most, .concat, .divided_by, .map, .minus, .modulo, .plus, .prepend, .remove, .remove_first, .remove_last, .split, .times, .push, .unshift => .{ 1, 1 },
        .truncate, .where, .group_by, .has, .reject, .replace, .replace_first, .slice => .{ 1, 2 },
        .find, .find_index, .replace_last, .find_exp, .group_by_exp, .where_exp => .{ 2, 2 },
        .sort, .slugify, .truncatewords, .date_to_string, .date_to_long_string => .{ 0, 2 },
        .join, .date, .compact, .round, .sort_natural, .sum, .uniq, .array_to_sentence_string, .number_of_words, .pop, .shift, .sample => .{ 0, 1 },
        else => .{ 0, 0 },
    };
}

/// Whether filter `k` takes the option `name: value`.
pub fn hasOption(k: Kind, name: []const u8) bool {
    return k == .default and std.mem.eql(u8, name, "allow_false");
}

pub fn apply(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!Value {
    const liquid = r.liquid;
    const a = r.arena;
    switch (f.kind) {
        .raw => return switch (v) {
            .string => |s| .{ .html = s },
            else => v,
        },
        .upper, .lower, .upcase, .downcase => {
            const s = if (liquid or f.kind == .upcase or f.kind == .downcase) blk: {
                if (v == .nil) return v;
                break :blk try toText(r, v);
            } else v.text() orelse switch (v) {
                .nil => return v,
                else => return r.fail(line, "filter '{s}' expects a string, got {s}", .{ @tagName(f.kind), v.typeName() }),
            };
            const out = try a.alloc(u8, s.len);
            if (f.kind == .upper or f.kind == .upcase) _ = std.ascii.upperString(out, s) else _ = std.ascii.lowerString(out, s);
            return keep(v, out);
        },
        .default => {
            const fallback = try arg(r, f, 0);
            if (!liquid) return if (v.truthy()) v else fallback;
            var allow_false = false;
            for (f.options) |o| allow_false = (try template.evalExpr(r, o.value)).liquidTruthy();
            const use_fallback = switch (v) {
                .nil => true,
                .boolean => |b| !b and !allow_false,
                .string, .html => |s| s.len == 0,
                .list => |l| l.len == 0,
                .object => |o| o.entries.len == 0,
                else => false,
            };
            return if (use_fallback) fallback else v;
        },
        .date => {
            if (liquid) {
                const fmt = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else "";
                if (fmt.len == 0) return v;
                const dt = toDateTime(r, v) orelse return v;
                return .{ .string = try formatDate(r, dt, fmt, .ruby, line) };
            }
            if (v == .nil) return v;
            const dt = toDateTime(r, v) orelse {
                if (v.text()) |s| return r.fail(line, "filter 'date' expects a date such as 2024-01-05, got '{s}'", .{s});
                return r.fail(line, "filter 'date' expects a date such as 2024-01-05, got {s}", .{v.typeName()});
            };
            if (f.args.len == 0) {
                return .{ .string = try std.fmt.allocPrint(a, "{s} {d}, {d}", .{ datetime.month_names[dt.month - 1], dt.day, dt.year }) };
            }
            return .{ .string = try formatDate(r, dt, try mortiseString(r, f, 0, line), .mortise, line) };
        },
        .slugify => {
            if (liquid) {
                if (v == .nil) return v;
                const mode = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else "default";
                const cased = f.args.len > 1 and (try arg(r, f, 1)).liquidTruthy();
                return .{ .string = try jekyllSlug(a, try toText(r, v), mode, cased) };
            }
            const s = try mortiseText(r, f, v, line) orelse return v;
            return .{ .string = try slug(a, s) };
        },
        .truncate => {
            if (liquid) {
                if (v == .nil) return v;
                const n = try toInteger(r, try arg(r, f, 0), line);
                const ellipsis = if (f.args.len > 1) try toText(r, try arg(r, f, 1)) else "...";
                return keep(v, try liquidTruncate(a, try toText(r, v), n, ellipsis));
            }
            const s = try plainText(a, try mortiseText(r, f, v, line) orelse return v, v == .html);
            const n = try mortiseInt(r, f, 0, line);
            const suffix = if (f.args.len > 1) try mortiseString(r, f, 1, line) else "…";
            return .{ .string = try truncate(a, s, n, suffix) };
        },
        .markdownify => {
            const s = (if (liquid) (if (v == .nil) null else try toText(r, v)) else try mortiseText(r, f, v, line)) orelse return v;
            // Liquid sites expect kramdown, which passes HTML through.
            return .{ .html = (try markdown.toDocumentWith(a, s, .{ .raw_html = liquid })).html };
        },
        .json => {
            var aw: Writer.Allocating = .init(a);
            try writeJson(&aw.writer, v, null, 0, false);
            return .{ .html = try scriptSafe(a, aw.written()) };
        },
        .jsonify => {
            var aw: Writer.Allocating = .init(a);
            try writeJson(&aw.writer, v, null, 0, true);
            return .{ .string = aw.written() };
        },
        .dump => {
            var json: Writer.Allocating = .init(a);
            try writeJson(&json.writer, v, 2, 0, false);
            var aw: Writer.Allocating = .init(a);
            try aw.writer.writeAll("<pre class=\"mortise-dump\"><code>");
            try escapeHtml(&aw.writer, json.written());
            try aw.writer.writeAll("</code></pre>");
            return .{ .html = aw.written() };
        },
        .where => {
            if (liquid) return whereLiquid(r, f, v, false);
            const items = try mortiseList(r, f, v, line) orelse return v;
            const key = try mortiseString(r, f, 0, line);
            const want: ?Value = if (f.args.len > 1) try arg(r, f, 1) else null;
            var out: std.ArrayList(Value) = .empty;
            for (items) |item| {
                const got = fieldPath(r, item, key) orelse continue;
                const ok = if (want) |w| switch (got) {
                    .list => |l| for (l) |x| {
                        if (x.eql(w)) break true;
                    } else false,
                    else => got.eql(w),
                } else got.truthy();
                if (ok) try out.append(a, item);
            }
            return .{ .list = out.items };
        },
        .reject => return whereLiquid(r, f, v, true),
        .sort => {
            if (liquid) return sortJekyll(r, f, v, line);
            const items = try mortiseList(r, f, v, line) orelse return v;
            const key: ?[]const u8 = if (f.args.len > 0) try mortiseString(r, f, 0, line) else null;
            const sorted = try a.dupe(Value, items);
            std.mem.sort(Value, sorted, SortContext{ .r = r, .key = key }, sortLess);
            return .{ .list = sorted };
        },
        .sort_natural => {
            const items = try iterate(r, v);
            const key: ?[]const u8 = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else null;
            const sorted = try a.dupe(Value, items);
            std.mem.sort(Value, sorted, SortContext{ .r = r, .key = key }, naturalLess);
            return .{ .list = sorted };
        },
        .group_by => {
            const items = (if (liquid) try iterate(r, v) else try mortiseList(r, f, v, line)) orelse return v;
            const key = if (liquid) try toText(r, try arg(r, f, 0)) else try mortiseString(r, f, 0, line);
            const date_fmt: ?[]const u8 = if (f.args.len > 1) try mortiseString(r, f, 1, line) else null;
            const names = try a.alloc(Value, items.len);
            for (items, names) |item, *name| {
                name.* = fieldPath(r, item, key) orelse Value.nil;
                if (date_fmt) |df| {
                    const dt = toDateTime(r, name.*) orelse
                        return r.fail(line, "filter 'group_by' with a date format needs '{s}' to be a date such as 2024-01-05", .{key});
                    name.* = .{ .string = try formatDate(r, dt, df, if (liquid) .ruby else .mortise, line) };
                } else if (liquid) {
                    // Jekyll groups by the property's text.
                    name.* = .{ .string = try toText(r, name.*) };
                }
            }
            return groups(r, items, names);
        },
        .group_by_exp => {
            const items = try iterate(r, v);
            const name = try toText(r, try arg(r, f, 0));
            const expr = try template.parseSourceOutput(r, try toText(r, try arg(r, f, 1)));
            const names = try a.alloc(Value, items.len);
            for (items, names) |item, *n| {
                const mark = try template.bind(r, name, item);
                n.* = try template.evalSourceOutput(r, expr);
                template.unbind(r, mark);
            }
            return groups(r, items, names);
        },
        .where_exp, .find_exp => {
            const items = switch (v) {
                .list => |l| l,
                .object => |o| try objectValues(a, o),
                else => return if (f.kind == .find_exp) .nil else v,
            };
            const name = try toText(r, try arg(r, f, 0));
            const cond = try template.parseSourceCondition(r, try toText(r, try arg(r, f, 1)));
            var out: std.ArrayList(Value) = .empty;
            for (items) |item| {
                const mark = try template.bind(r, name, item);
                const ok = try template.evalCondition(r, cond);
                template.unbind(r, mark);
                if (!ok) continue;
                if (f.kind == .find_exp) return item;
                try out.append(a, item);
            }
            return if (f.kind == .find_exp) .nil else .{ .list = out.items };
        },
        .find, .find_index, .has => {
            const items = try iterate(r, v);
            const key = try toText(r, try arg(r, f, 0));
            const want: ?Value = if (f.args.len > 1) try arg(r, f, 1) else null;
            for (items, 0..) |item, i| {
                const got = fieldPath(r, item, key) orelse Value.nil;
                const ok = if (want) |w| got.eql(w) else got.liquidTruthy();
                if (!ok) continue;
                return switch (f.kind) {
                    .find => item,
                    .find_index => .{ .int = @intCast(i) },
                    else => .{ .boolean = true },
                };
            }
            return if (f.kind == .has) .{ .boolean = false } else .nil;
        },
        .limit => {
            const items = try mortiseList(r, f, v, line) orelse return v;
            const n = try mortiseInt(r, f, 0, line);
            return .{ .list = items[0..@min(items.len, n)] };
        },
        .reverse => {
            const items = (if (liquid) try iterate(r, v) else try mortiseList(r, f, v, line)) orelse return v;
            const out = try a.dupe(Value, items);
            std.mem.reverse(Value, out);
            return .{ .list = out };
        },
        .first, .last => {
            if (liquid) switch (v) {
                .string, .html => |s| {
                    if (s.len == 0) return .{ .string = "" };
                    if (f.kind == .first) return .{ .string = s[0..charOffset(s, 1)] };
                    return .{ .string = s[charOffset(s, charCount(s) - 1)..] };
                },
                .list => {},
                else => return .nil,
            };
            const items = try mortiseList(r, f, v, line) orelse return v;
            if (items.len == 0) return .nil;
            return if (f.kind == .first) items[0] else items[items.len - 1];
        },
        .size => return .{ .int = @intCast(switch (v) {
            .nil => 0,
            .string, .html => |s| if (liquid) charCount(s) else s.len,
            .list => |l| l.len,
            .object => |o| o.entries.len,
            else => if (liquid) 0 else return r.fail(line, "filter 'size' expects a list, object or string, got {s}", .{v.typeName()}),
        }) },
        .join => {
            const sep = if (f.args.len > 0) (if (liquid) try toText(r, try arg(r, f, 0)) else try mortiseString(r, f, 0, line)) else " ";
            const items = (if (liquid) try iterate(r, v) else try mortiseList(r, f, v, line)) orelse return v;
            var aw: Writer.Allocating = .init(a);
            for (items, 0..) |item, i| {
                if (i > 0) try aw.writer.writeAll(sep);
                if (!liquid and (item == .list or item == .object)) return r.fail(line, "filter 'join' cannot join {s}", .{item.typeName()});
                try writeText(r, &aw.writer, item);
            }
            return .{ .string = aw.written() };
        },
        .reading_time, .word_count => {
            const s = try plainText(a, try mortiseText(r, f, v, line) orelse return .{ .int = 0 }, v == .html);
            const words = countWords(s);
            if (f.kind == .word_count) return .{ .int = @intCast(words) };
            return .{ .int = @intCast(@max(1, (words + 199) / 200)) };
        },
        .strip_html => {
            if (liquid) return .{ .string = try stripHtmlLiquid(a, try toText(r, v)) };
            const s = try mortiseText(r, f, v, line) orelse return v;
            return .{ .string = try plainText(a, s, true) };
        },
        .asset, .sri => {
            const path = v.text() orelse return r.fail(line, "filter '{s}' expects a file path such as \"css/site.css\", got {s}", .{ @tagName(f.kind), v.typeName() });
            const assets = r.assets orelse return r.fail(line, "filter '{s}' is not available here", .{@tagName(f.kind)});
            var why: []const u8 = "";
            const answer = try assets.lookupFn(assets.ctx, path, if (f.kind == .asset) .url else .sri, &why);
            return .{ .string = answer orelse return r.fail(line, "filter '{s}': '{s}' {s}", .{ @tagName(f.kind), path, why }) };
        },

        // Numbers
        .plus, .minus, .times, .divided_by, .modulo => return arith(r, f.kind, v, try arg(r, f, 0), line),
        .abs => return switch (toNumber(v)) {
            .int => |n| .{ .int = if (n == std.math.minInt(i64)) return r.fail(line, "number too large", .{}) else if (n < 0) -n else n },
            .float => |x| .{ .float = @abs(x) },
        },
        .ceil, .floor, .round => {
            const digits: i64 = if (f.kind == .round and f.args.len > 0) try toInteger(r, try arg(r, f, 0), line) else 0;
            const x = switch (toNumber(v)) {
                .int => |n| return .{ .int = n },
                .float => |y| y,
            };
            if (!std.math.isFinite(x)) return .{ .float = x };
            if (f.kind == .round and digits > 0) {
                const scale = std.math.pow(f64, 10, @floatFromInt(@min(digits, 15)));
                return .{ .float = @round(x * scale) / scale };
            }
            const y = switch (f.kind) {
                .ceil => @ceil(x),
                .floor => @floor(x),
                else => @round(x),
            };
            if (@abs(y) > 9.0e18) return .{ .float = y };
            return .{ .int = @intFromFloat(y) };
        },
        .at_least, .at_most => {
            const x = toNumber(v);
            const y = toNumber(try arg(r, f, 0));
            const xf = numFloat(x);
            const yf = numFloat(y);
            const pick_y = if (f.kind == .at_least) yf > xf else yf < xf;
            return numValue(if (pick_y) y else x);
        },
        .sum => {
            const items = try iterate(r, v);
            const key: ?[]const u8 = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else null;
            var int_sum: i64 = 0;
            var float_sum: f64 = 0;
            var is_float = false;
            for (items) |item| {
                const x = if (key) |k| fieldPath(r, item, k) orelse Value.nil else item;
                switch (toNumber(x)) {
                    .int => |n| int_sum = std.math.add(i64, int_sum, n) catch return r.fail(line, "number too large", .{}),
                    .float => |y| {
                        float_sum += y;
                        is_float = true;
                    },
                }
            }
            if (is_float) return .{ .float = float_sum + @as(f64, @floatFromInt(int_sum)) };
            return .{ .int = int_sum };
        },
        .to_integer => return .{ .int = switch (v) {
            .boolean => |b| @intFromBool(b),
            .int => |n| n,
            .float => |x| if (std.math.isFinite(x) and @abs(x) < 9.0e18) @intFromFloat(@trunc(x)) else 0,
            .string, .html => |s| leadingInt(s),
            else => 0,
        } },

        // Text
        .append, .prepend => {
            const s = try toText(r, v);
            const other = try toText(r, try arg(r, f, 0));
            const parts: []const []const u8 = if (f.kind == .append) &.{ s, other } else &.{ other, s };
            return keep(v, try std.mem.concat(a, u8, parts));
        },
        .capitalize => {
            const s = try toText(r, v);
            const out = try a.alloc(u8, s.len);
            for (s, out, 0..) |c, *o, i| o.* = if (i == 0) std.ascii.toUpper(c) else std.ascii.toLower(c);
            return keep(v, out);
        },
        .escape, .h, .xml_escape => {
            if (v == .nil and f.kind != .xml_escape) return v;
            var aw: Writer.Allocating = .init(a);
            for (try toText(r, v)) |c| try writeEscaped(&aw.writer, c, f.kind != .xml_escape);
            return escaped(r, aw.written());
        },
        .escape_once => {
            const s = try toText(r, v);
            var aw: Writer.Allocating = .init(a);
            for (s, 0..) |c, i| {
                if (c == '&' and entityAt(s[i..])) {
                    try aw.writer.writeByte('&');
                } else try writeEscaped(&aw.writer, c, true);
            }
            return escaped(r, aw.written());
        },
        .newline_to_br => {
            const s = try toText(r, v);
            var aw: Writer.Allocating = .init(a);
            var i: usize = 0;
            while (i < s.len) : (i += 1) {
                if (s[i] == '\n' or (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n')) {
                    if (s[i] == '\r') i += 1;
                    try aw.writer.writeAll("<br />\n");
                } else if (!liquid and v != .html) {
                    // Mortise escapes the text, since the result is HTML.
                    try writeEscaped(&aw.writer, s[i], false);
                } else try aw.writer.writeByte(s[i]);
            }
            return .{ .html = aw.written() };
        },
        .lstrip, .rstrip, .strip => {
            const s = try toText(r, v);
            const ws = " \t\n\x0b\x0c\r\x00";
            return keep(v, switch (f.kind) {
                .lstrip => std.mem.trimStart(u8, s, ws),
                .rstrip => std.mem.trimEnd(u8, s, ws),
                else => std.mem.trim(u8, s, ws),
            });
        },
        .strip_newlines => {
            const s = try toText(r, v);
            var out: std.ArrayList(u8) = .empty;
            for (s) |c| if (c != '\n' and c != '\r') try out.append(a, c);
            return keep(v, out.items);
        },
        .remove, .remove_first, .remove_last, .replace, .replace_first, .replace_last => {
            const s = try toText(r, v);
            const needle = try toText(r, try arg(r, f, 0));
            const with = switch (f.kind) {
                .replace, .replace_first, .replace_last => if (f.args.len > 1) try toText(r, try arg(r, f, 1)) else "",
                else => "",
            };
            const out = switch (f.kind) {
                .remove, .replace => if (needle.len == 0) s else try std.mem.replaceOwned(u8, a, s, needle, with),
                .remove_first, .replace_first => blk: {
                    const at = std.mem.indexOf(u8, s, needle) orelse break :blk s;
                    break :blk try std.mem.concat(a, u8, &.{ s[0..at], with, s[at + needle.len ..] });
                },
                else => blk: {
                    const at = std.mem.lastIndexOf(u8, s, needle) orelse break :blk s;
                    break :blk try std.mem.concat(a, u8, &.{ s[0..at], with, s[at + needle.len ..] });
                },
            };
            return keep(v, out);
        },
        .split => {
            const s = try toText(r, v);
            return .{ .list = try split(a, s, try toText(r, try arg(r, f, 0))) };
        },
        .slice => {
            const start = try toInteger(r, try arg(r, f, 0), line);
            const len = if (f.args.len > 1) try toInteger(r, try arg(r, f, 1), line) else 1;
            if (v == .list) {
                const l = v.list;
                const at = sliceRange(l.len, start, len) orelse return .{ .list = &.{} };
                return .{ .list = l[at[0]..at[1]] };
            }
            const s = try toText(r, v);
            const at = sliceRange(charCount(s), start, len) orelse return .{ .string = "" };
            return keep(v, s[charOffset(s, at[0])..charOffset(s, at[1])]);
        },
        .truncatewords => {
            if (v == .nil) return v;
            const s = try toText(r, v);
            var n = if (f.args.len > 0) try toInteger(r, try arg(r, f, 0), line) else 15;
            if (n <= 0) n = 1;
            const ellipsis = if (f.args.len > 1) try toText(r, try arg(r, f, 1)) else "...";
            var words: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, s, " \t\n\x0b\x0c\r");
            while (it.next()) |word| {
                if (words.items.len == n) {
                    const joined = try std.mem.join(a, " ", words.items);
                    return keep(v, try std.mem.concat(a, u8, &.{ joined, ellipsis }));
                }
                try words.append(a, word);
            }
            return v;
        },
        .url_encode, .cgi_escape => {
            if (v == .nil and f.kind == .url_encode) return v;
            return .{ .string = try cgiEscape(a, try toText(r, v)) };
        },
        .url_decode => {
            if (v == .nil) return v;
            return .{ .string = try cgiUnescape(a, try toText(r, v)) };
        },
        .uri_escape => return .{ .string = try uriEscape(a, try toText(r, v)) },
        .base64_encode, .base64_url_safe_encode => {
            const s = try toText(r, v);
            const enc = if (f.kind == .base64_encode) std.base64.standard.Encoder else std.base64.url_safe.Encoder;
            const out = try a.alloc(u8, enc.calcSize(s.len));
            return .{ .string = enc.encode(out, s) };
        },
        .base64_decode, .base64_url_safe_decode => {
            const s = try toText(r, v);
            const dec = if (f.kind == .base64_decode) std.base64.standard.Decoder else std.base64.url_safe.Decoder;
            const bad = "invalid base64 provided to " ++ "base64_decode";
            const size = dec.calcSizeForSlice(s) catch return r.fail(line, bad, .{});
            const out = try a.alloc(u8, size);
            dec.decode(out, s) catch return r.fail(line, bad, .{});
            return .{ .string = out };
        },
        .normalize_whitespace => {
            const s = try toText(r, v);
            var words: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeAny(u8, s, " \t\n\x0b\x0c\r");
            while (it.next()) |word| try words.append(a, word);
            return .{ .string = try std.mem.join(a, " ", words.items) };
        },
        .number_of_words => {
            const s = try toText(r, v);
            const mode = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else "";
            return .{ .int = @intCast(numberOfWords(s, mode)) };
        },
        .smartify => {
            const s = try smartify(a, try toText(r, v));
            return if (liquid) .{ .string = s } else .{ .html = s };
        },
        .inspect => {
            var aw: Writer.Allocating = .init(a);
            try inspectValue(&aw.writer, v);
            var out: Writer.Allocating = .init(a);
            for (aw.written()) |c| try writeEscaped(&out.writer, c, false);
            return escaped(r, out.written());
        },

        // Lists
        .compact, .uniq => {
            const items = try iterate(r, v);
            const key: ?[]const u8 = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else null;
            var out: std.ArrayList(Value) = .empty;
            outer: for (items) |item| {
                const x = if (key) |k| fieldPath(r, item, k) orelse Value.nil else item;
                if (f.kind == .compact) {
                    if (x != .nil) try out.append(a, item);
                    continue;
                }
                for (out.items) |seen| {
                    const y = if (key) |k| fieldPath(r, seen, k) orelse Value.nil else seen;
                    if (x.eql(y)) continue :outer;
                }
                try out.append(a, item);
            }
            return .{ .list = out.items };
        },
        .concat => {
            const other = try arg(r, f, 0);
            if (other != .list) return r.fail(line, "filter 'concat' needs a list argument, got {s}", .{other.typeName()});
            return .{ .list = try std.mem.concat(a, Value, &.{ try iterate(r, v), other.list }) };
        },
        .map => {
            const items = try iterate(r, v);
            const key = try toText(r, try arg(r, f, 0));
            const out = try a.alloc(Value, items.len);
            for (items, out) |item, *o| o.* = fieldPath(r, item, key) orelse .nil;
            return .{ .list = out };
        },
        .push, .unshift, .pop, .shift => {
            if (v != .list) return v;
            const l = v.list;
            switch (f.kind) {
                .push => return .{ .list = try std.mem.concat(a, Value, &.{ l, &.{try arg(r, f, 0)} }) },
                .unshift => return .{ .list = try std.mem.concat(a, Value, &.{ &.{try arg(r, f, 0)}, l }) },
                else => {
                    const n: usize = @intCast(std.math.clamp(if (f.args.len > 0) try toInteger(r, try arg(r, f, 0), line) else 1, 0, @as(i64, @intCast(l.len))));
                    return .{ .list = if (f.kind == .pop) l[0 .. l.len - n] else l[n..] };
                },
            }
        },
        .sample => {
            const items = switch (v) {
                .list => |l| l,
                else => return v,
            };
            const n: i64 = if (f.args.len > 0) try toInteger(r, try arg(r, f, 0), line) else 1;
            const random = r.prng.random();
            if (f.args.len == 0) {
                if (items.len == 0) return .nil;
                return items[random.uintLessThan(usize, items.len)];
            }
            const shuffled = try a.dupe(Value, items);
            random.shuffle(Value, shuffled);
            return .{ .list = shuffled[0..@min(shuffled.len, @as(usize, @intCast(@max(0, n))))] };
        },
        .array_to_sentence_string => {
            const items = try iterate(r, v);
            const connector = if (f.args.len > 0) try toText(r, try arg(r, f, 0)) else "and";
            var aw: Writer.Allocating = .init(a);
            for (items, 0..) |item, i| {
                if (i > 0) {
                    if (items.len == 2) {
                        try aw.writer.print(" {s} ", .{connector});
                    } else if (i + 1 == items.len) {
                        try aw.writer.print(", {s} ", .{connector});
                    } else try aw.writer.writeAll(", ");
                }
                try writeText(r, &aw.writer, item);
            }
            return .{ .string = aw.written() };
        },

        // URLs and dates (Jekyll)
        .relative_url, .absolute_url => {
            if (v == .nil) return v;
            const input = try toText(r, v);
            if (hasScheme(input)) return .{ .string = input };
            const base = std.mem.trimEnd(u8, siteText(r, "baseurl"), "/");
            const path = if (input.len > 0 and input[0] == '/') input else try std.mem.concat(a, u8, &.{ "/", input });
            // Mortise URLs already hold the baseurl; do not add it twice.
            const has_base = base.len > 0 and (std.mem.eql(u8, path, base) or
                (std.mem.startsWith(u8, path, base) and path[base.len] == '/'));
            const lead: []const u8 = if (base.len > 0 and base[0] != '/') "/" else "";
            var rel = try uriEscape(a, if (has_base) path else try std.mem.concat(a, u8, &.{ lead, base, path }));
            if (f.kind == .absolute_url) {
                const site_url = std.mem.trimEnd(u8, siteText(r, "url"), "/");
                rel = try std.mem.concat(a, u8, &.{ site_url, rel });
            }
            return .{ .string = rel };
        },
        .date_to_xml_schema, .date_to_rfc822, .date_to_string, .date_to_long_string => {
            if (v == .nil or (v.text() != null and v.text().?.len == 0)) return v;
            const dt = toDateTime(r, v) orelse return r.fail(line, "invalid date '{s}' for '{s}'", .{ try toText(r, v), @tagName(f.kind) });
            const fmt: []const u8 = switch (f.kind) {
                .date_to_xml_schema => "%Y-%m-%dT%H:%M:%S%:z",
                .date_to_rfc822 => "%a, %d %b %Y %H:%M:%S %z",
                else => blk: {
                    const month = if (f.kind == .date_to_string) "%b" else "%B";
                    const ordinal = f.args.len > 0 and std.mem.eql(u8, try toText(r, try arg(r, f, 0)), "ordinal");
                    if (!ordinal) break :blk try std.mem.concat(a, u8, &.{ "%d ", month, " %Y" });
                    const day = try std.fmt.allocPrint(a, "{d}{s}", .{ dt.day, ordinalSuffix(dt.day) });
                    const us = f.args.len > 1 and std.mem.eql(u8, try toText(r, try arg(r, f, 1)), "US");
                    if (us) break :blk try std.mem.concat(a, u8, &.{ month, " ", day, ", %Y" });
                    break :blk try std.mem.concat(a, u8, &.{ day, " ", month, " %Y" });
                },
            };
            return .{ .string = try formatDate(r, dt, fmt, .ruby, line) };
        },
    }
}

/// Keeps a string filter's result HTML when its input was.
fn keep(input: Value, s: []const u8) Value {
    return if (input == .html) .{ .html = s } else .{ .string = s };
}

/// Text a filter escaped itself, so Mortise must not escape it again.
fn escaped(r: *Renderer, s: []const u8) Value {
    return if (r.liquid) .{ .string = s } else .{ .html = s };
}

fn arg(r: *Renderer, f: Filter, i: usize) RenderError!Value {
    return template.evalExpr(r, f.args[i]);
}

// ---------------------------------------------------------------------------
// Conversions, as Liquid makes them

/// `v` as text, as Ruby's `to_s` writes it.
pub fn toText(r: *Renderer, v: Value) RenderError![]const u8 {
    return switch (v) {
        .string, .html => |s| s,
        .nil => "",
        .boolean => |b| if (b) "true" else "false",
        else => blk: {
            var aw: Writer.Allocating = .init(r.arena);
            try writeText(r, &aw.writer, v);
            break :blk aw.written();
        },
    };
}

/// Writes `v` as Liquid outputs it: lists joined, objects as Ruby shows
/// them, floats with a decimal point.
pub fn writeText(r: *Renderer, w: *Writer, v: Value) RenderError!void {
    switch (v) {
        .nil => {},
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |x| try writeFloat(w, x),
        .string, .html => |s| try w.writeAll(s),
        .list => |l| for (l) |item| try writeText(r, w, item),
        .object => try inspectValue(w, v),
    }
}

/// A float as Ruby writes it: `2.0`, `0.1`, `1.0e+20`.
pub fn writeFloat(w: *Writer, x: f64) Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("NaN");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "Infinity" else "-Infinity");
    var buf: [64]u8 = undefined;
    const ax = @abs(x);
    if (ax != 0 and (ax >= 1e16 or ax < 1e-4)) {
        const s = std.fmt.bufPrint(&buf, "{e}", .{x}) catch unreachable;
        const e_at = std.mem.indexOfScalar(u8, s, 'e').?;
        const mantissa = s[0..e_at];
        const exp = std.fmt.parseInt(i32, s[e_at + 1 ..], 10) catch 0;
        try w.writeAll(mantissa);
        if (std.mem.indexOfScalar(u8, mantissa, '.') == null) try w.writeAll(".0");
        try w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
        return;
    }
    const s = std.fmt.bufPrint(&buf, "{d}", .{x}) catch unreachable;
    try w.writeAll(s);
    if (std.mem.indexOfScalar(u8, s, '.') == null) try w.writeAll(".0");
}

/// Ruby's `inspect`: `"text"`, `[1, 2]`, `{"key"=>"value"}`, `nil`.
fn inspectValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .nil => try w.writeAll("nil"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |x| try writeFloat(w, x),
        .string, .html => |s| {
            try w.writeByte('"');
            for (s, 0..) |c, i| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                '\r' => try w.writeAll("\\r"),
                0x1b => try w.writeAll("\\e"),
                '#' => try w.writeAll(if (i + 1 < s.len and (s[i + 1] == '{' or s[i + 1] == '$' or s[i + 1] == '@')) "\\#" else "#"),
                0...0x08, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => try w.print("\\x{X:0>2}", .{c}),
                else => try w.writeByte(c),
            };
            try w.writeByte('"');
        },
        .list => |l| {
            try w.writeByte('[');
            for (l, 0..) |item, i| {
                if (i > 0) try w.writeAll(", ");
                try inspectValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            for (o.entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(", ");
                try inspectValue(w, .{ .string = e.key });
                try w.writeAll("=>");
                try inspectValue(w, e.value);
            }
            try w.writeByte('}');
        },
    }
}

pub const Num = union(enum) { int: i64, float: f64 };

/// Liquid's number conversion: `"3"` is 3, `"3.5"` is 3.5, and anything
/// that is not a number is 0.
pub fn toNumber(v: Value) Num {
    return switch (v) {
        .int => |n| .{ .int = n },
        .float => |x| .{ .float = x },
        .string, .html => |raw| blk: {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            if (isDecimal(s)) break :blk .{ .float = std.fmt.parseFloat(f64, s) catch 0 };
            break :blk .{ .int = leadingInt(s) };
        },
        else => .{ .int = 0 },
    };
}

pub fn toFloat(v: Value) f64 {
    return numFloat(toNumber(v));
}

fn numFloat(n: Num) f64 {
    return switch (n) {
        .int => |i| @floatFromInt(i),
        .float => |x| x,
    };
}

fn numValue(n: Num) Value {
    return switch (n) {
        .int => |i| .{ .int = i },
        .float => |x| .{ .float = x },
    };
}

/// `-?\d+\.\d+`
fn isDecimal(s: []const u8) bool {
    var i: usize = @intFromBool(s.len > 0 and s[0] == '-');
    const int_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i == int_start or i >= s.len or s[i] != '.') return false;
    i += 1;
    const frac_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    return i > frac_start and i == s.len;
}

/// The whole number at the start of `s`, as Ruby's `to_i` reads it.
fn leadingInt(raw: []const u8) i64 {
    const s = std.mem.trimStart(u8, raw, " \t\r\n");
    var end: usize = @intFromBool(s.len > 0 and (s[0] == '-' or s[0] == '+'));
    const digits = end;
    while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
    if (end == digits) return 0;
    return std.fmt.parseInt(i64, s[0..end], 10) catch 0;
}

/// Liquid's integer conversion, which rejects text that is not a number.
pub fn toInteger(r: *Renderer, v: Value, line: usize) RenderError!i64 {
    return switch (v) {
        .int => |n| n,
        .float => |x| if (std.math.isFinite(x) and @abs(x) < 9.0e18) @intFromFloat(@trunc(x)) else r.fail(line, "invalid integer", .{}),
        .string, .html => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch r.fail(line, "invalid integer '{s}'", .{s}),
        else => r.fail(line, "expected a whole number, got {s}", .{v.typeName()}),
    };
}

fn arith(r: *Renderer, kind: Kind, a: Value, b: Value, line: usize) RenderError!Value {
    const x = toNumber(a);
    const y = toNumber(b);
    if (x == .int and y == .int) {
        const p = x.int;
        const q = y.int;
        if ((kind == .divided_by or kind == .modulo) and q == 0) return r.fail(line, "divided by 0", .{});
        const result: ?i64 = switch (kind) {
            .plus => std.math.add(i64, p, q) catch null,
            .minus => std.math.sub(i64, p, q) catch null,
            .times => std.math.mul(i64, p, q) catch null,
            .divided_by => std.math.divFloor(i64, p, q) catch null,
            else => blk: {
                const m = @rem(p, q);
                break :blk if (m != 0 and ((m < 0) != (q < 0))) m + q else m;
            },
        };
        return .{ .int = result orelse return r.fail(line, "number too large", .{}) };
    }
    const p = numFloat(x);
    const q = numFloat(y);
    return .{ .float = switch (kind) {
        .plus => p + q,
        .minus => p - q,
        .times => p * q,
        .divided_by => p / q,
        else => p - q * @floor(p / q),
    } };
}

/// The items Liquid's list filters work on: a list, flattened; nothing for
/// `nil`; anything else as a list of one.
fn iterate(r: *Renderer, v: Value) RenderError![]const Value {
    return switch (v) {
        .nil => &.{},
        .list => |l| blk: {
            for (l) |item| {
                if (item == .list) break;
            } else break :blk l;
            var out: std.ArrayList(Value) = .empty;
            try flatten(r.arena, &out, l);
            break :blk out.items;
        },
        else => try r.arena.dupe(Value, &.{v}),
    };
}

fn flatten(a: Allocator, out: *std.ArrayList(Value), l: []const Value) Allocator.Error!void {
    for (l) |item| switch (item) {
        .list => |inner| try flatten(a, out, inner),
        else => try out.append(a, item),
    };
}

fn objectValues(a: Allocator, o: template.Object) Allocator.Error![]const Value {
    const out = try a.alloc(Value, o.entries.len);
    for (out, o.entries) |*x, e| x.* = e.value;
    return out;
}

/// The value at a dotted `key` path inside `v`, such as `author.name`.
fn fieldPath(r: *Renderer, v: Value, key: []const u8) ?Value {
    var cur = v;
    var it = std.mem.splitScalar(u8, key, '.');
    while (it.next()) |seg| cur = template.member(r, cur, seg) orelse return null;
    return cur;
}

fn siteText(r: *Renderer, key: []const u8) []const u8 {
    const site = r.root.get("site") orelse return "";
    const v = template.member(r, site, key) orelse return "";
    return v.text() orelse "";
}

pub fn charCount(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(c & 0xc0 != 0x80);
    return n;
}

/// The byte offset of character `index` in `s`.
fn charOffset(s: []const u8, index: usize) usize {
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c & 0xc0 == 0x80) continue;
        if (n == index) return i;
        n += 1;
    }
    return s.len;
}

/// Ruby's `slice(start, length)` on something `len` long, as a range, or
/// null where Ruby gives nil.
fn sliceRange(len: usize, start: i64, length: i64) ?[2]usize {
    const n: i64 = @intCast(len);
    const from = if (start < 0) n + start else start;
    if (from < 0 or from > n or length < 0) return null;
    const to = @min(n, from +| length);
    return .{ @intCast(from), @intCast(to) };
}

// ---------------------------------------------------------------------------
// Dates

fn toDateTime(r: *Renderer, v: Value) ?datetime.DateTime {
    return switch (v) {
        .int => |n| datetime.DateTime.fromUnix(n, 0),
        .float => |x| if (std.math.isFinite(x) and @abs(x) < 1e15) datetime.DateTime.fromUnix(@intFromFloat(@trunc(x)), 0) else null,
        .string, .html => |raw| blk: {
            const s = std.mem.trim(u8, raw, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(s, "now") or std.ascii.eqlIgnoreCase(s, "today")) {
                break :blk datetime.DateTime.fromUnix(r.now, 0);
            }
            if (s.len > 0 and s.len < 12 and for (s, 0..) |c, i| {
                if (!(std.ascii.isDigit(c) or (i == 0 and c == '-'))) break false;
            } else true) {
                break :blk datetime.DateTime.fromUnix(std.fmt.parseInt(i64, s, 10) catch break :blk null, 0);
            }
            break :blk datetime.parse(s);
        },
        else => null,
    };
}

fn formatDate(r: *Renderer, dt: datetime.DateTime, fmt: []const u8, style: datetime.Style, line: usize) RenderError![]const u8 {
    var aw: Writer.Allocating = .init(r.arena);
    var unknown: u8 = 0;
    datetime.format(&aw.writer, dt, fmt, style, &unknown) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.UnknownDirective => return r.fail(line, "date format does not know '%{c}'; see the directives in docs/templates.md", .{unknown}),
    };
    return aw.written();
}

fn ordinalSuffix(day: u8) []const u8 {
    if (day % 100 >= 11 and day % 100 <= 13) return "th";
    return switch (day % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
}

// ---------------------------------------------------------------------------
// Lists

/// Jekyll's `group_by` result: `{ name, items, size }` in first-seen order.
fn groups(r: *Renderer, items: []const Value, names: []const Value) RenderError!Value {
    var keys: std.ArrayList(Value) = .empty;
    var members: std.ArrayList(std.ArrayList(Value)) = .empty;
    for (items, names) |item, name| {
        const idx = for (keys.items, 0..) |k, i| {
            if (k.eql(name)) break i;
        } else blk: {
            try keys.append(r.arena, name);
            try members.append(r.arena, .empty);
            break :blk keys.items.len - 1;
        };
        try members.items[idx].append(r.arena, item);
    }
    const out = try r.arena.alloc(Value, keys.items.len);
    for (out, keys.items, members.items) |*o, k, m| {
        o.* = .{ .object = .{ .entries = try r.arena.dupe(Entry, &.{
            .{ .key = "name", .value = k },
            .{ .key = "items", .value = .{ .list = m.items } },
            .{ .key = "size", .value = .{ .int = @intCast(m.items.len) } },
        }) } };
    }
    return .{ .list = out };
}

/// Liquid's `where` and `reject` with one argument (items whose property
/// is true), and Jekyll's `where` with two (items whose property, or an
/// item of it, has the value's text).
fn whereLiquid(r: *Renderer, f: Filter, v: Value, reject: bool) RenderError!Value {
    const items = switch (v) {
        .object => |o| try objectValues(r.arena, o),
        else => try iterate(r, v),
    };
    const key = try toText(r, try arg(r, f, 0));
    const want: ?Value = if (f.args.len > 1) try arg(r, f, 1) else null;
    var out: std.ArrayList(Value) = .empty;
    for (items) |item| {
        const got = fieldPath(r, item, key) orelse Value.nil;
        const ok = if (want) |w| blk: {
            if (reject) break :blk got.eql(w);
            if (w == .nil) break :blk got == .nil;
            const target = try toText(r, w);
            if (got.text()) |t| break :blk std.mem.eql(u8, t, target);
            const props: []const Value = if (got == .list) got.list else &.{got};
            for (props) |p| {
                if (p != .nil and std.mem.eql(u8, try toText(r, p), target)) break :blk true;
            }
            break :blk false;
        } else got.liquidTruthy();
        if (ok != reject) try out.append(r.arena, item);
    }
    return .{ .list = out.items };
}

/// Jekyll's `sort`: by value, or by a property with missing values first
/// (or last with "last").
fn sortJekyll(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!Value {
    const items = switch (v) {
        .list => |l| l,
        .nil => return r.fail(line, "cannot sort nothing", .{}),
        else => return r.fail(line, "filter 'sort' expects a list, got {s}", .{v.typeName()}),
    };
    const sorted = try r.arena.dupe(Value, items);
    if (f.args.len == 0) {
        // Ruby fails to compare numbers with strings, or anything with nil.
        for (sorted[0..sorted.len -| 1], sorted[@min(1, sorted.len)..]) |x, y| {
            const xn = x == .int or x == .float;
            const yn = y == .int or y == .float;
            if (!((xn and yn) or (x.text() != null and y.text() != null))) {
                return r.fail(line, "cannot sort {s} with {s}", .{ x.typeName(), y.typeName() });
            }
        }
        std.mem.sort(Value, sorted, SortContext{ .r = r, .key = null }, sortLess);
        return .{ .list = sorted };
    }
    const key = try toText(r, try arg(r, f, 0));
    const nils = if (f.args.len > 1) try toText(r, try arg(r, f, 1)) else "first";
    if (!std.mem.eql(u8, nils, "first") and !std.mem.eql(u8, nils, "last")) {
        return r.fail(line, "the nils order for 'sort' must be \"first\" or \"last\", not \"{s}\"", .{nils});
    }
    std.mem.sort(Value, sorted, SortContext{ .r = r, .key = key, .nils_last = nils[0] == 'l' }, propertyLess);
    return .{ .list = sorted };
}

const SortContext = struct { r: *Renderer, key: ?[]const u8, nils_last: bool = true };

fn sortKey(ctx: SortContext, v: Value) Value {
    const k = ctx.key orelse return v;
    return fieldPath(ctx.r, v, k) orelse .nil;
}

/// Orders values for Mortise's `sort`: numbers numerically, strings by
/// bytes, booleans false first, missing values last.
fn sortLess(ctx: SortContext, a: Value, b: Value) bool {
    const x = sortKey(ctx, a);
    const y = sortKey(ctx, b);
    const rx = rank(x);
    const ry = rank(y);
    if (rx != ry) return rx < ry;
    return switch (x) {
        .boolean => |p| !p and y.boolean,
        .int, .float => toFloat(x) < toFloat(y),
        .string, .html => |s| std.mem.order(u8, s, y.text().?) == .lt,
        else => false,
    };
}

fn propertyLess(ctx: SortContext, a: Value, b: Value) bool {
    const x = sortKey(ctx, a);
    const y = sortKey(ctx, b);
    if (x == .nil or y == .nil) {
        if (x == .nil and y == .nil) return false;
        return (x == .nil) != ctx.nils_last;
    }
    const xn = x == .int or x == .float;
    const yn = y == .int or y == .float;
    if (xn and yn) return toFloat(x) < toFloat(y);
    if (x.text() != null and y.text() != null) return std.mem.order(u8, x.text().?, y.text().?) == .lt;
    // Mixed types compare by their text.
    const xs = toText(ctx.r, x) catch return false;
    const ys = toText(ctx.r, y) catch return false;
    return std.mem.order(u8, xs, ys) == .lt;
}

/// Liquid's `sort_natural`: case-insensitive, missing values last.
fn naturalLess(ctx: SortContext, a: Value, b: Value) bool {
    const x = sortKey(ctx, a);
    const y = sortKey(ctx, b);
    if (x == .nil or y == .nil) return y == .nil and x != .nil;
    const xs = toText(ctx.r, x) catch return false;
    const ys = toText(ctx.r, y) catch return false;
    return std.ascii.orderIgnoreCase(xs, ys) == .lt;
}

fn rank(v: Value) u8 {
    return switch (v) {
        .boolean => 0,
        .int, .float => 1,
        .string, .html => 2,
        .list, .object => 3,
        .nil => 4,
    };
}

// ---------------------------------------------------------------------------
// Text

/// HTML-escapes one byte: `&`, `<`, `>`, `"`, and with `quote` also `'`.
fn writeEscaped(w: *Writer, c: u8, quote: bool) Writer.Error!void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll(if (quote) "&#39;" else "'"),
        else => try w.writeByte(c),
    }
}

/// Whether `s` starts with a character reference such as `&amp;` or
/// `&#39;`.
fn entityAt(s: []const u8) bool {
    var i: usize = 1;
    if (i < s.len and s[i] == '#') {
        i += 1;
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        return i > start and i < s.len and s[i] == ';';
    }
    const start = i;
    while (i < s.len and std.ascii.isAlphabetic(s[i])) i += 1;
    return i > start and i < s.len and s[i] == ';';
}

/// Liquid's `truncate`: at most `n` characters, counting the ellipsis.
fn liquidTruncate(a: Allocator, s: []const u8, n: i64, ellipsis: []const u8) Allocator.Error![]const u8 {
    if (@as(i64, @intCast(charCount(s))) <= n) return s;
    const keep_chars: usize = @intCast(@max(0, n - @as(i64, @intCast(charCount(ellipsis)))));
    return std.mem.concat(a, u8, &.{ s[0..charOffset(s, keep_chars)], ellipsis });
}

/// Ruby's `split`: on white space for `" "`, into characters for `""`,
/// and without the empty strings at the end.
fn split(a: Allocator, s: []const u8, sep: []const u8) Allocator.Error![]const Value {
    var out: std.ArrayList(Value) = .empty;
    if (std.mem.eql(u8, sep, " ")) {
        var it = std.mem.tokenizeAny(u8, s, " \t\n\x0b\x0c\r");
        while (it.next()) |part| try out.append(a, .{ .string = part });
        return out.items;
    }
    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            try out.append(a, .{ .string = s[i..@min(s.len, i + n)] });
            i += n;
        }
        return out.items;
    }
    var it = std.mem.splitSequence(u8, s, sep);
    while (it.next()) |part| try out.append(a, .{ .string = part });
    while (out.items.len > 0 and out.items[out.items.len - 1].string.len == 0) out.items.len -= 1;
    return out.items;
}

/// Liquid's `strip_html`: drops scripts, styles, comments and tags.
fn stripHtmlLiquid(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '<') {
            try out.append(a, s[i]);
            i += 1;
            continue;
        }
        const rest = s[i..];
        const block_end: ?[]const u8 = if (std.mem.startsWith(u8, rest, "<!--"))
            "-->"
        else if (std.ascii.startsWithIgnoreCase(rest, "<script"))
            "</script>"
        else if (std.ascii.startsWithIgnoreCase(rest, "<style"))
            "</style>"
        else
            null;
        if (block_end) |close| {
            if (indexOfIgnoreCase(s, i + 1, close)) |e| {
                i = e + close.len;
                continue;
            }
        }
        const gt = std.mem.indexOfScalarPos(u8, s, i, '>') orelse {
            try out.appendSlice(a, rest);
            break;
        };
        i = gt + 1;
    }
    return out.items;
}

fn indexOfIgnoreCase(s: []const u8, from: usize, needle: []const u8) ?usize {
    var i = from;
    while (i + needle.len <= s.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(s[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Ruby's `CGI.escape`: `+` for space, `%XX` for all but letters, digits
/// and `_.-~`.
fn cgiEscape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-', '~' => try out.append(a, c),
        ' ' => try out.append(a, '+'),
        else => try out.print(a, "%{X:0>2}", .{c}),
    };
    return out.items;
}

fn cgiUnescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '+') {
            try out.append(a, ' ');
        } else if (c == '%' and i + 2 < s.len and std.ascii.isHex(s[i + 1]) and std.ascii.isHex(s[i + 2])) {
            try out.append(a, std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch unreachable);
            i += 2;
        } else try out.append(a, c);
    }
    return out.items;
}

/// Percent-encodes what may not appear in a URL, keeping its reserved
/// characters and existing escapes, as Jekyll's `uri_escape` does.
fn uriEscape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '!', '*', '\'', '(', ')', ';', ':', '@', '&', '=', '+', '$', ',', '/', '?', '#', '[', ']', '%' => try out.append(a, c),
        else => try out.print(a, "%{X:0>2}", .{c}),
    };
    return out.items;
}

fn hasScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '.' or c == '-')) return false;
    }
    return true;
}

/// Jekyll's `number_of_words`; with "cjk" (or "auto" when there are any)
/// each Chinese, Japanese or Korean character counts as a word.
fn numberOfWords(s: []const u8, mode: []const u8) usize {
    var cjk: usize = 0;
    var words: usize = 0;
    var plain: usize = 0;
    var in_word = false;
    var in_plain = false;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const space = cp < 128 and std.ascii.isWhitespace(@intCast(cp));
        if (!space and !in_plain) plain += 1;
        in_plain = !space;
        if (isCjk(cp)) {
            cjk += 1;
            in_word = false;
        } else if (space) {
            in_word = false;
        } else {
            if (!in_word) words += 1;
            in_word = true;
        }
    }
    if (std.mem.eql(u8, mode, "cjk") or (std.mem.eql(u8, mode, "auto") and cjk > 0)) return cjk + words;
    return plain;
}

fn isCjk(cp: u21) bool {
    return (cp >= 0x4e00 and cp <= 0x9fff) or (cp >= 0x3400 and cp <= 0x4dbf) or (cp >= 0x3040 and cp <= 0x30ff) or
        (cp >= 0xac00 and cp <= 0xd7af) or (cp >= 0x1100 and cp <= 0x11ff) or (cp >= 0x3130 and cp <= 0x318f) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0x20000 and cp <= 0x2ffff);
}

/// Typographic quotes, dashes and ellipses, as Jekyll's `smartify` makes
/// them; `&`, `<` and `>` are escaped.
fn smartify(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        const prev: u8 = if (i > 0) s[i - 1] else ' ';
        const opening = std.ascii.isWhitespace(prev) or prev == '(' or prev == '[' or prev == '{' or prev == '-';
        if (std.mem.startsWith(u8, s[i..], "---")) {
            try out.appendSlice(a, "—");
            i += 3;
        } else if (std.mem.startsWith(u8, s[i..], "--")) {
            try out.appendSlice(a, "–");
            i += 2;
        } else if (std.mem.startsWith(u8, s[i..], "...")) {
            try out.appendSlice(a, "…");
            i += 3;
        } else {
            switch (c) {
                '"' => try out.appendSlice(a, if (opening) "“" else "”"),
                '\'' => try out.appendSlice(a, if (opening) "‘" else "’"),
                '&' => try out.appendSlice(a, "&amp;"),
                '<' => try out.appendSlice(a, "&lt;"),
                '>' => try out.appendSlice(a, "&gt;"),
                else => try out.append(a, c),
            }
            i += 1;
        }
    }
    return out.items;
}

/// Jekyll's `slugify`. Modes: "default" replaces all but letters and
/// digits with `-`; "raw" only white space; "pretty" keeps `._~!$&'()+,;=@`;
/// "ascii" also replaces non-ASCII; "latin" first turns accented letters
/// into plain ones; "none" leaves the text. Lowercase unless `cased`.
fn jekyllSlug(a: Allocator, input: []const u8, mode: []const u8, cased: bool) Allocator.Error![]const u8 {
    const modes = [_][]const u8{ "raw", "default", "pretty", "ascii", "latin" };
    const known = for (modes) |m| {
        if (std.mem.eql(u8, mode, m)) break true;
    } else false;
    var s = input;
    if (known) {
        if (std.mem.eql(u8, mode, "latin")) s = try transliterate(a, s);
        var out: std.ArrayList(u8) = .empty;
        var dash = false;
        for (s) |c| {
            const keep_char = switch (mode[0]) {
                'r' => !std.ascii.isWhitespace(c),
                'p' => std.ascii.isAlphanumeric(c) or c >= 0x80 or std.mem.indexOfScalar(u8, "._~!$&'()+,;=@_", c) != null,
                'a' => std.ascii.isAlphanumeric(c),
                else => std.ascii.isAlphanumeric(c) or c >= 0x80,
            };
            if (keep_char) {
                if (dash) try out.append(a, '-');
                dash = false;
                try out.append(a, c);
            } else dash = true;
        }
        s = std.mem.trim(u8, out.items, "-");
    }
    if (cased) return s;
    const lower = try a.alloc(u8, s.len);
    return std.ascii.lowerString(lower, s);
}

/// Replaces accented Latin letters with plain ones: `é` with `e`, `ß`
/// with `ss`.
fn transliterate(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "ÀÁÂÃÄÅĀĂĄ", "A" },
        .{ "àáâãäåāăą", "a" },
        .{ "ÇĆĈĊČ", "C" },
        .{ "çćĉċč", "c" },
        .{ "ÐĎĐ", "D" },
        .{ "ðďđ", "d" },
        .{ "ÈÉÊËĒĔĖĘĚ", "E" },
        .{ "èéêëēĕėęě", "e" },
        .{ "ĜĞĠĢ", "G" },
        .{ "ĝğġģ", "g" },
        .{ "ÌÍÎÏĨĪĬĮİ", "I" },
        .{ "ìíîïĩīĭįı", "i" },
        .{ "ŁĹĻĽ", "L" },
        .{ "łĺļľ", "l" },
        .{ "ÑŃŅŇ", "N" },
        .{ "ñńņň", "n" },
        .{ "ÒÓÔÕÖØŌŎŐ", "O" },
        .{ "òóôõöøōŏő", "o" },
        .{ "ŔŖŘ", "R" },
        .{ "ŕŗř", "r" },
        .{ "ŚŜŞŠ", "S" },
        .{ "śŝşš", "s" },
        .{ "ŢŤ", "T" },
        .{ "ţť", "t" },
        .{ "ÙÚÛÜŨŪŬŮŰŲ", "U" },
        .{ "ùúûüũūŭůűų", "u" },
        .{ "ÝŸ", "Y" },
        .{ "ýÿ", "y" },
        .{ "ŹŻŽ", "Z" },
        .{ "źżž", "z" },
        .{ "Æ", "AE" },
        .{ "æ", "ae" },
        .{ "Œ", "OE" },
        .{ "œ", "oe" },
        .{ "ß", "ss" },
        .{ "Þ", "TH" },
        .{ "þ", "th" },
    };
    var out: std.ArrayList(u8) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    next: while (it.nextCodepointSlice()) |ch| {
        if (ch.len > 1) {
            for (table) |entry| {
                if (std.mem.indexOf(u8, entry[0], ch) != null) {
                    try out.appendSlice(a, entry[1]);
                    continue :next;
                }
            }
        }
        try out.appendSlice(a, ch);
    }
    return out.items;
}

// Mortise's own definitions

/// The text of `v`, null when it is missing, or an error for other types.
fn mortiseText(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!?[]const u8 {
    return v.text() orelse switch (v) {
        .nil => null,
        else => r.fail(line, "filter '{s}' expects a string, got {s}", .{ @tagName(f.kind), v.typeName() }),
    };
}

fn mortiseList(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!?[]const Value {
    return switch (v) {
        .nil => null,
        .list => |l| l,
        else => r.fail(line, "filter '{s}' expects a list, got {s}", .{ @tagName(f.kind), v.typeName() }),
    };
}

fn mortiseInt(r: *Renderer, f: Filter, i: usize, line: usize) RenderError!usize {
    const a = try arg(r, f, i);
    if (a != .int or a.int < 0) return r.fail(line, "filter '{s}' expects a whole number, got {s}", .{ @tagName(f.kind), a.typeName() });
    return @intCast(a.int);
}

fn mortiseString(r: *Renderer, f: Filter, i: usize, line: usize) RenderError![]const u8 {
    const a = try arg(r, f, i);
    return a.text() orelse r.fail(line, "filter '{s}' expects a string argument, got {s}", .{ @tagName(f.kind), a.typeName() });
}

/// `s` without HTML tags and with common character references decoded,
/// when `is_html`; otherwise `s` unchanged.
fn plainText(a: Allocator, s: []const u8, is_html: bool) Allocator.Error![]const u8 {
    if (!is_html) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < s.len) {
        const c = s[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, s, i, '>') orelse s.len;
            // Block tags separate words; inline tags such as <code> do not.
            if (isBlockTag(s[i + 1 .. end]) and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                try out.append(a, ' ');
            }
            i = end + 1;
            continue;
        }
        if (c == '&') {
            for ([_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#39;", "'" } }) |e| {
                if (std.mem.startsWith(u8, s[i..], e[0])) {
                    try out.appendSlice(a, e[1]);
                    i += e[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(a, if (c == '\n' or c == '\t' or c == '\r') ' ' else c);
        i += 1;
    }
    // Collapse the runs of spaces that tags and newlines leave.
    var w: usize = 0;
    for (out.items) |c| {
        if (c == ' ' and (w == 0 or out.items[w - 1] == ' ')) continue;
        out.items[w] = c;
        w += 1;
    }
    return std.mem.trimEnd(u8, out.items[0..w], " ");
}

/// Whether the tag body (`/p`, `li class="x"`, `br/`) names an element
/// that starts a new line of text.
fn isBlockTag(body: []const u8) bool {
    const name_start: usize = if (body.len > 0 and body[0] == '/') 1 else 0;
    var end = name_start;
    while (end < body.len and std.ascii.isAlphanumeric(body[end])) end += 1;
    const name = body[name_start..end];
    const blocks = [_][]const u8{
        "p",  "div", "br", "li", "ul", "ol", "h1",    "h2",         "h3",      "h4",     "h5",  "h6",      "tr",     "td",
        "th", "pre", "hr", "dt", "dd", "dl", "table", "blockquote", "section", "header", "nav", "article", "figure",
    };
    for (blocks) |b| if (std.ascii.eqlIgnoreCase(name, b)) return true;
    return false;
}

fn countWords(s: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (s) |c| {
        const space = std.ascii.isWhitespace(c);
        if (!space and !in_word) n += 1;
        in_word = !space;
    }
    return n;
}

/// Lowercase ASCII letters and digits joined by single `-`; other ASCII
/// is a separator and non-ASCII bytes are kept.
fn slug(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var dash = false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', 0x80...0xff => {
            if (dash and out.items.len > 0) try out.append(a, '-');
            dash = false;
            try out.append(a, std.ascii.toLower(c));
        },
        '\'' => {},
        else => dash = true,
    };
    return out.items;
}

/// At most `n` characters (code points) of `s`, cut back to a word boundary
/// when one is near, with `suffix` appended when anything was removed.
fn truncate(a: Allocator, s: []const u8, n: usize, suffix: []const u8) Allocator.Error![]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len and count < n) : (count += 1) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    }
    if (i >= s.len) return s;
    var cut = @min(i, s.len);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |sp| {
        // Prefer a word boundary unless it throws away most of the text.
        if (sp * 2 >= cut) cut = sp;
    }
    const kept = std.mem.trimEnd(u8, s[0..cut], " ,;:.");
    return std.mem.concat(a, u8, &.{ kept, suffix });
}

/// Writes `v` as JSON, indented by `indent` spaces per level when set.
/// With `ruby`, floats print as Ruby's JSON does (`2.0`).
fn writeJson(w: *Writer, v: Value, indent: ?usize, level: usize, ruby: bool) Writer.Error!void {
    switch (v) {
        .nil => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |x| if (!std.math.isFinite(x)) try w.writeAll("null") else if (ruby) try writeFloat(w, x) else try w.print("{d}", .{x}),
        .string, .html => |s| try writeJsonString(w, s),
        .list => |l| {
            if (l.len == 0) return w.writeAll("[]");
            try w.writeByte('[');
            for (l, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, indent, level + 1);
                try writeJson(w, item, indent, level + 1, ruby);
            }
            try newline(w, indent, level);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.entries.len == 0) return w.writeAll("{}");
            try w.writeByte('{');
            for (o.entries, 0..) |e, i| {
                if (i > 0) try w.writeByte(',');
                try newline(w, indent, level + 1);
                try writeJsonString(w, e.key);
                try w.writeAll(if (indent != null) ": " else ":");
                try writeJson(w, e.value, indent, level + 1, ruby);
            }
            try newline(w, indent, level);
            try w.writeByte('}');
        },
    }
}

fn newline(w: *Writer, indent: ?usize, level: usize) Writer.Error!void {
    const n = indent orelse return;
    try w.writeByte('\n');
    try w.splatByteAll(' ', n * level);
}

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Makes JSON safe to place inside `<script>`: `<`, `>` and `&` become
/// `\u` escapes, so the text can never close the element, and so do the
/// line separators U+2028 and U+2029.
fn scriptSafe(a: Allocator, json: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        const c = json[i];
        switch (c) {
            '<' => try out.appendSlice(a, "\\u003c"),
            '>' => try out.appendSlice(a, "\\u003e"),
            '&' => try out.appendSlice(a, "\\u0026"),
            0xe2 => if (i + 2 < json.len and json[i + 1] == 0x80 and (json[i + 2] == 0xa8 or json[i + 2] == 0xa9)) {
                try out.appendSlice(a, if (json[i + 2] == 0xa8) "\\u2028" else "\\u2029");
                i += 2;
            } else try out.append(a, c),
            else => try out.append(a, c),
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------

const testing = std.testing;
const expectRender = expectMortise;
const expectLiquid = template.expectLiquid;

fn expectMortise(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: template.Diagnostic = .{};
    const tpl = try template.parse(arena.allocator(), "test.html", src, &diag);
    const root = [_]Entry{
        .{ .key = "page", .value = .{ .object = .{ .entries = &.{
            .{ .key = "title", .value = .{ .string = "<Hello>" } },
            .{ .key = "date", .value = .{ .string = "2024-01-05" } },
            .{ .key = "tags", .value = .{ .list = &.{ .{ .string = "zig" }, .{ .string = "web" } } } },
        } } } },
        .{ .key = "content", .value = .{ .html = "<p>Body</p>" } },
        .{ .key = "posts", .value = .{ .list = &.{
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "First" } }, .{ .key = "url", .value = .{ .string = "/a/" } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "Second & more" } }, .{ .key = "url", .value = .{ .string = "/b/" } } } } },
        } } },
        .{ .key = "pages", .value = .{ .list = &.{
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "x" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "zig" }} } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "y" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "go" }} } } } } },
        } } },
    };
    const out = template.renderAlloc(arena.allocator(), &tpl, .{ .entries = &root }, null, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectMortiseError(src: []const u8, part: []const u8) !void {
    try template.expectModeError(.mortise, src, "main.html", 1, part);
}

test "mortise filters" {
    try expectRender("&lt;HELLO&gt;", "{{ page.title | upper }}");
    try expectRender("&lt;hello&gt;", "{{ page.title | lower }}");
    try expectRender("Untitled", "{{ missing | default(\"Untitled\") }}");
    try expectRender("&lt;Hello&gt;", "{{ page.title | default(\"x\") }}");
    try expectRender("January 5, 2024", "{{ page.date | date }}");
    try expectRender("<HELLO>", "{{ page.title | upper | raw }}");
}

test "mortise text filters" {
    try expectRender("hello-world-zig-0-16", "{{ \"Hello, World! Zig 0.16\" | slugify }}");
    try expectRender("its-ok", "{{ \"  It's ok! \" | slugify }}");
    try expectRender("2024/01/05 5 Jan January 100% Friday", "{{ page.date | date(\"%Y/%m/%d %e %b %B 100%% %A\") }}");
    try expectRender("The quick…", "{{ \"The quick brown fox\" | truncate(12) }}");
    try expectRender("The quick brown fox", "{{ \"The quick brown fox\" | truncate(50) }}");
    try expectRender("The...", "{{ \"The quick brown fox\" | truncate(6, \"...\") }}");
    try expectRender("Body", "{{ content | strip_html }}");
    try expectRender("Set url, then a b", "{{ \"<p>Set <code>url</code>, then</p><p>a<br>b</p>\" | raw | strip_html }}");
    try expectRender("<p><em>hi</em> &amp; bye</p>\n", "{{ \"*hi* & bye\" | markdownify }}");
    try expectRender("1", "{{ content | reading_time }}");
    try expectRender("2 1", "{{ \"<p>one</p><p>two</p>\" | raw | word_count }} {{ content | word_count }}");
    try expectRender("7", "{{ page.title | size }}");
}

test "mortise list filters" {
    try expectRender("web zig", "{{ page.tags | sort | join }}");
    try expectRender("zig, web", "{{ page.tags | join(\", \") }}");
    try expectRender("web", "{{ page.tags | reverse | first }}");
    try expectRender("web 2", "{{ page.tags | last }} {{ page.tags | size }}");
    try expectRender("Second &amp; more,First,", "{% for p in posts | sort(\"url\") | reverse %}{{ p.title }},{% endfor %}");
    try expectRender("First", "{% for p in posts | where(\"url\", \"/a/\") %}{{ p.title }}{% endfor %}");
    try expectRender("First", "{% for p in posts | limit(1) %}{{ p.title }}{% endfor %}");
    try expectRender("2", "{{ posts | where(\"title\") | size }}");
    try expectRender("/a/:First;/b/:Second &amp; more;", "{% for g in posts | group_by(\"url\") %}{{ g.name }}:{% for p in g.items %}{{ p.title }}{% endfor %};{% endfor %}");
    try expectRender("a", "{% for p in grouped | sort %}{% endfor %}a");
    try expectRender("x", "{% for p in pages | where(\"tags\", \"zig\") %}{{ p.name }}{% endfor %}");
}

test "json and dump" {
    try expectRender("[\"zig\",\"web\"]", "{{ page.tags | json }}");
    try expectRender("\"\\u003cHello\\u003e\"", "{{ page.title | json }}");
    try expectRender("{\"title\":\"First\",\"url\":\"/a/\"}", "{{ posts | first | json }}");
    try expectRender("<pre class=\"mortise-dump\"><code>[\n  &quot;zig&quot;,\n  &quot;web&quot;\n]</code></pre>", "{{ page.tags | dump }}");
}

test "mortise filter argument errors" {
    try expectMortiseError("{{ page.tags | truncate(3) }}", "expects a string");
    try expectMortiseError("{{ page.title | limit(2) }}", "expects a list");
    try expectMortiseError("{{ page.tags | limit(\"2\") }}", "whole number");
    try expectMortiseError("{{ page.date | date(\"%Q\") }}", "does not know '%Q'");
}

test "Liquid filters work in Mortise templates" {
    try expectRender("Hello &lt;b&gt;!", "{{ \"Hello <b>\" | append: \"!\" }}");
    try expectRender("a &amp;amp; b", "{{ \"a &amp; b\" | escape }}");
    try expectRender("a &amp; b &lt;", "{{ \"a &amp; b <\" | escape_once }}");
    try expectRender("x&lt;y<br />\nz", "{{ \"x<y\nz\" | newline_to_br }}");
    try expectRender("6", "{{ 2 | plus: 4 }}");
}

test "liquid string filters" {
    try expectLiquid("Hello world!", "{{ \"Hello\" | append: \" world\" | append: \"!\" }}");
    try expectLiquid("Title", "{{ \"title\" | capitalize }}");
    try expectLiquid("My great title", "{{ \"my GREAT title\" | capitalize }}");
    try expectLiquid("HELLO hello", "{{ \"Hello\" | upcase }} {{ \"Hello\" | downcase }}");
    try expectLiquid("Have &#39;you&#39; &lt;b&gt;", "{{ \"Have 'you' <b>\" | escape }}");
    try expectLiquid("1 &lt; 2 &amp; 3 &amp;", "{{ \"1 < 2 &amp; 3 &\" | escape_once }}");
    try expectLiquid("[a b ]|[ a b]|[a b]", "[{{ \"  a b \" | lstrip }}]|[{{ \" a b  \" | rstrip }}]|[{{ \" a b \" | strip }}]");
    try expectLiquid("ab", "{{ \"a\nb\r\n\" | strip_newlines }}");
    try expectLiquid("a<br />\nb", "{{ \"a\nb\" | newline_to_br }}");
    try expectLiquid("I sted to see the t through the ", "{{ \"I strained to see the train through the rain\" | remove: \"rain\" }}");
    try expectLiquid("Take your protein pills|Take my protein pills and put my helmet", "{{ \"Take my protein pills\" | replace: \"my\", \"your\" }}|{{ \"Take my protein pills and put my helmet\" | replace_first: \"x\", \"y\" }}");
    try expectLiquid("a-b-c-|abc", "{{ \"a b c \" | replace: \" \", \"-\" }}|{{ \"a.b.c\" | remove: \".\" }}");
    try expectLiquid("Take your pills and my|Take my pills and your", "{{ \"Take my pills and my\" | replace_first: \"my\", \"your\" }}|{{ \"Take my pills and my\" | replace_last: \"my\", \"your\" }}");
    try expectLiquid("a b|c", "{{ \"a b c\" | remove_last: \" c\" }}|{{ \"a b c\" | remove_first: \"a b \" }}");
    try expectLiquid("Ground control to...|Ground control, and so on|ABCDEFGHIJ", "{{ \"Ground control to Major Tom.\" | truncate: 20 }}|{{ \"Ground control to Major Tom.\" | truncate: 25, \", and so on\" }}|{{ \"ABCDEFGHIJ\" | truncate: 10 }}");
    try expectLiquid("Ground control to...|Ground control to--|Ground", "{{ \"Ground control to Major Tom.\" | truncatewords: 3 }}|{{ \"Ground control to Major Tom.\" | truncatewords: 3, \"--\" }}|{{ \"Ground control\" | truncatewords: 0, \"\" }}");
    try expectLiquid("Liquid|qui|d|iq", "{{ \"Liquid\" | slice: 0, 6 }}|{{ \"Liquid\" | slice: 2, 3 }}|{{ \"Liquid\" | slice: -1 }}|{{ \"Liquid\" | slice: -5, 2 }}");
    try expectLiquid("é|ü", "{{ \"héllo\" | slice: 1 }}|{{ \"über\" | first }}");
    try expectLiquid("John, Paul, George|a,b|5", "{{ \"John, Paul, George\" | split: \", \" | join: \", \" }}|{{ \"a,b,,\" | split: \",\" | join: \",\" }}|{{ \"héllo\" | split: \"\" | size }}");
    try expectLiquid("Have you read Ulysses?", "{{ \"Have <em>you</em> read <script>x</script><!-- c --><strong>Ulysses</strong>?\" | strip_html }}");
    try expectLiquid("%27Stop%21%27+said+Fred|'Stop!' said Fred", "{{ \"'Stop!' said Fred\" | url_encode }}|{{ \"%27Stop%21%27+said+Fred\" | url_decode }}");
    try expectLiquid("b25lIHR3byB0aHJlZQ==|one two three|PDw_Pz4-", "{{ \"one two three\" | base64_encode }}|{{ \"b25lIHR3byB0aHJlZQ==\" | base64_decode }}|{{ \"<<??>>\" | base64_url_safe_encode }}");
    try expectLiquid("5|1|3", "{{ \"Hello\" | size }}|{{ 5 | append: \"\" | size }}|{{ \"héé\" | size }}");
}

test "liquid number filters" {
    try expectLiquid("4|-4|1.5|16|10.0", "{{ 2 | plus: 2 }}|{{ 2 | minus: 6 }}|{{ 0.5 | times: 3 }}|{{ \"8\" | times: 2 }}|{{ \"4.5\" | plus: 5.5 }}");
    try expectLiquid("3|-4|3.3333333333333335|1|-1|1.5", "{{ 10 | divided_by: 3 }}|{{ -7 | divided_by: 2 }}|{{ 10 | divided_by: 3.0 }}|{{ 3 | modulo: 2 }}|{{ 3 | modulo: -2 }}|{{ 5.5 | modulo: 2 }}");
    try expectLiquid("17|5|2|3|4.56|5", "{{ -17 | abs }}|{{ 4.1 | ceil }}|{{ 2.9 | floor }}|{{ 2.7 | round }}|{{ 4.5612 | round: 2 }}|{{ \"4.6\" | round }}");
    try expectLiquid("5|4|4.5", "{{ 4 | at_least: 5 }}|{{ 4 | at_most: 5 }}|{{ 4.5 | at_least: 3 }}");
    try expectLiquid("6|7.5|3|0", "{{ \"1,2,3\" | split: \",\" | sum }}|{{ 7.5 | plus: 0 }}|{{ \"3 apples\" | to_integer }}|{{ posts | map: \"n\" | sum }}");
}

test "liquid list filters" {
    try expectLiquid("web,zig|zig,web|zig", "{{ page.tags | sort | join: \",\" }}|{{ page.tags | uniq | join: \",\" }}|{{ page.tags | first }}");
    try expectLiquid("First, Second & more", "{{ posts | map: \"title\" | join: \", \" }}");
    try expectLiquid("/b/", "{{ posts | where: \"title\", \"Second & more\" | map: \"url\" | join }}");
    try expectLiquid("x", "{{ pages | where: \"tags\", \"zig\" | map: \"name\" | join }}");
    try expectLiquid("y", "{{ pages | reject: \"name\", \"x\" | map: \"name\" | join }}");
    try expectLiquid("First|1|true|false", "{{ posts | find: \"url\", \"/a/\" | map: \"title\" }}|{{ posts | find_index: \"url\", \"/b/\" }}|{{ posts | has: \"url\", \"/b/\" }}|{{ posts | has: \"url\", \"/c/\" }}");
    try expectLiquid("a b c|c b a|5|0", "{{ \"c a b\" | split: \" \" | sort_natural | join: \" \" }}|{{ \"a b c\" | split: \" \" | reverse | join: \" \" }}|{{ \"a b c\" | split: \" \" | concat: page.tags | size }}|{{ pages | map: \"missing\" | compact | size }}");
    try expectLiquid("a, b, and c|a or b|", "{{ \"a b c\" | split: \" \" | array_to_sentence_string }}|{{ \"a b\" | split: \" \" | array_to_sentence_string: \"or\" }}|{{ empty | array_to_sentence_string }}");
    try expectLiquid("zig web x|x zig web|zig|web", "{{ page.tags | push: \"x\" | join: \" \" }}|{{ page.tags | unshift: \"x\" | join: \" \" }}|{{ page.tags | pop | join }}|{{ page.tags | shift | join }}");
    try expectLiquid("a B C", "{{ \"C a B\" | split: \" \" | sort_natural | join: \" \" }}");
    try expectLiquid("First", "{{ posts | where_exp: \"p\", \"p.url == '/a/'\" | map: \"title\" | join }}");
    try expectLiquid("Second & more", "{{ posts | find_exp: \"p\", \"p.title contains 'more'\" | map: \"title\" }}");
    try expectLiquid("/:2", "{% for g in posts | group_by_exp: \"p\", \"p.url | slice: 0\" %}{{ g.name }}:{{ g.size }}{% endfor %}");
    try expectLiquid("/a/:1,/b/:1,", "{% assign gs = posts | group_by: \"url\" %}{% for g in gs %}{{ g.name }}:{{ g.size }},{% endfor %}");
    try expectLiquid("2", "{{ (1..3) | sample: 2 | size }}");
}

test "liquid sort follows Jekyll" {
    try expectLiquid("1 2 10", "{{ (1..2) | push: 10 | reverse | sort | join: \" \" }}");
    try expectLiquid("Second & more,First", "{{ posts | sort: \"url\" | reverse | map: \"title\" | join: \",\" }}");
    try expectLiquid("First,Second & more", "{{ posts | sort: \"missing\" | map: \"title\" | join: \",\" }}");
}

test "liquid default, date and url filters" {
    try expectLiquid("x|x|0|false|x", "{{ nil | default: \"x\" }}|{{ \"\" | default: \"x\" }}|{{ page.zero | default: \"x\" }}|{{ false | default: \"x\", allow_false: true }}|{{ false | default: \"x\" }}");
    try expectLiquid("Fri, Jan 5, 24|2024-01-05|2024", "{{ page.date | date: \"%a, %b %-d, %y\" }}|{{ page.date | date: \"\" }}|{{ \"now\" | date: \"%Y\" }}");
    try expectLiquid("10:30|1970-01-01|not a date", "{{ \"today\" | date: \"%H:%M\" }}|{{ 0 | date: \"%F\" }}|{{ \"not a date\" | date: \"%Y\" }}");
    try expectLiquid("2024-01-05T00:00:00+00:00|Fri, 05 Jan 2024 00:00:00 +0000", "{{ page.date | date_to_xml_schema }}|{{ page.date | date_to_rfc822 }}");
    try expectLiquid("05 Jan 2024|5th January 2024|Jan 5th, 2024", "{{ page.date | date_to_string }}|{{ page.date | date_to_long_string: \"ordinal\" }}|{{ page.date | date_to_string: \"ordinal\", \"US\" }}");
    try expectLiquid("/blog/about/|/blog/about/|https://example.com/blog/a%20b|https://x.org/", "{{ \"about/\" | relative_url }}|{{ \"/blog/about/\" | relative_url }}|{{ \"a b\" | absolute_url }}|{{ \"https://x.org/\" | relative_url }}");
}

test "jekyll text filters" {
    try expectLiquid("hello-world|hello-world.html|Hello-World|the-_config.yml-file|creme-brulee|hello world", "{{ \"Hello, World!\" | slugify }}|{{ \"Hello world.html\" | slugify: \"pretty\" }}|{{ \"Hello World\" | slugify: \"raw\", true }}|{{ \"The _config.yml file\" | slugify: \"pretty\" }}|{{ \"Crème Brûlée\" | slugify: \"latin\" }}|{{ \"Hello World\" | slugify: \"none\" }}");
    try expectLiquid("a &lt; b &amp; &quot;c&quot;|foo%2Cbar%3Bbaz%3F|my%20things/hello%3Cthere%3E", "{{ 'a < b & \"c\"' | xml_escape }}|{{ \"foo,bar;baz?\" | cgi_escape }}|{{ \"my things/hello<there>\" | uri_escape }}");
    try expectLiquid("4|3|5", "{{ \"one two three four\" | number_of_words }}|{{ \"你好 world\" | number_of_words: \"cjk\" }}{{ \"\" }}|{{ \"a  b\tc\nd e\" | number_of_words }}");
    try expectLiquid("a b c", "{{ \"  a \n b   c \" | normalize_whitespace }}");
    try expectLiquid("“Jekyll” — the static generator…", "{{ '\"Jekyll\" --- the static generator...' | smartify }}");
    try expectLiquid("[\"zig\",\"web\"]|{\"n\":2.0}|&quot;a&quot;", "{{ page.tags | jsonify }}|{% assign n = 2.0 %}{\"n\":{{ n }}}|{{ \"a\" | inspect }}");
    try expectLiquid("<p><em>hi</em></p>\n", "{{ \"*hi*\" | markdownify }}");
    try expectLiquid("<p><b>hi</b></p>\n", "{{ \"<b>hi</b>\" | markdownify }}");
}

test "liquid filter errors" {
    try template.expectModeError(.liquid, "{{ \"a\" | concat: 1 }}", "main.html", 1, "needs a list");
    try template.expectModeError(.liquid, "{{ \"%%\" | base64_decode }}", "main.html", 1, "invalid base64");
    try template.expectModeError(.liquid, "{{ \"x\" | truncate: \"y\" }}", "main.html", 1, "invalid integer");
    try template.expectModeError(.liquid, "{{ \"b a\" | split: \" \" | push: 1 | sort }}", "main.html", 1, "cannot sort");
    try template.expectModeError(.liquid, "{{ page.tags | sort: \"x\", \"middle\" }}", "main.html", 1, "\"first\" or \"last\"");
    try template.expectModeError(.liquid, "{{ \"x\" | date_to_string }}", "main.html", 1, "invalid date");
}
