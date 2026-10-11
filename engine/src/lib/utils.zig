const std = @import("std");

pub fn escapeJson(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return s;

    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub fn slugify(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    var pending_dash = false;
    for (id) |c| {
        const lower = std.ascii.toLower(c);
        const is_alnum = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9');
        if (is_alnum) {
            if (pending_dash and buf.items.len > 0) try buf.append(allocator, '-');
            pending_dash = false;
            try buf.append(allocator, lower);
        } else {
            pending_dash = true;
        }
    }
    return buf.toOwnedSlice(allocator);
}

pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0) return false;
    if (std.mem.eql(u8, slug, ".") or std.mem.eql(u8, slug, "..")) return false;
    if (slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    for (slug) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

pub fn escapeYamlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        else => {
            if (c < 0x20) {
                var tmp: [8]u8 = undefined;
                const escaped = try std.fmt.bufPrint(&tmp, "\\x{x:0>2}", .{c});
                try buf.appendSlice(allocator, escaped);
            } else {
                try buf.append(allocator, c);
            }
        },
    };
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}

test "escapeJson returns input unchanged when no escapes needed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = "plain text";
    try std.testing.expectEqualStrings(s, try escapeJson(a, s));
}

test "escapeJson escapes control characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\te", try escapeJson(a, "a\"b\\c\nd\te"));
}

test "slugify replaces slashes with dashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("develop-plan", try slugify(arena.allocator(), "develop/plan"));
}

test "slugify lowercases and collapses unsafe runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("sys-only", try slugify(a, "Sys_Only"));
    try std.testing.expectEqualStrings("a-b", try slugify(a, "a..b"));
    try std.testing.expectEqualStrings("a-b", try slugify(a, "a/b"));
    try std.testing.expectEqualStrings("", try slugify(a, ".."));
    try std.testing.expectEqualStrings("trailing", try slugify(a, "trailing/"));
}

test "isValidSlug rejects traversal and separators" {
    try std.testing.expect(isValidSlug("search-ripgrep"));
    try std.testing.expect(!isValidSlug(""));
    try std.testing.expect(!isValidSlug("."));
    try std.testing.expect(!isValidSlug(".."));
    try std.testing.expect(!isValidSlug("a/b"));
    try std.testing.expect(!isValidSlug("-lead"));
    try std.testing.expect(!isValidSlug("trail-"));
    try std.testing.expect(!isValidSlug("UPPER"));
    try std.testing.expect(!isValidSlug("a b"));
}

test "escapeYamlString quotes and escapes scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"plain\"", try escapeYamlString(a, "plain"));
    try std.testing.expectEqualStrings("\"a: b \\\"c\\\"\"", try escapeYamlString(a, "a: b \"c\""));
    try std.testing.expectEqualStrings("\"line1\\nline2\"", try escapeYamlString(a, "line1\nline2"));
    try std.testing.expectEqualStrings("\"path\\\\to\"", try escapeYamlString(a, "path\\to"));
}
