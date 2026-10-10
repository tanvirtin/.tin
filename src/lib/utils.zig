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
    for (id) |c| {
        try buf.append(allocator, if (c == '/') '-' else c);
    }
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

pub fn cleanDir(path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        try dir.deleteTree(entry.name);
    }
}

test "cleanDir empties a directory and tolerates a missing one" {
    const root = "/tmp/tin_test_clean_dir";
    const nested = "/tmp/tin_test_clean_dir/nested";
    std.fs.deleteTreeAbsolute(root) catch {};
    try std.fs.makeDirAbsolute(root);
    try std.fs.makeDirAbsolute(nested);
    defer std.fs.deleteTreeAbsolute(root) catch {};

    var buf: [128]u8 = undefined;
    try std.fs.cwd().writeFile(.{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/a.txt", .{root}),
        .data = "x",
    });
    try std.fs.cwd().writeFile(.{
        .sub_path = try std.fmt.bufPrint(&buf, "{s}/b.txt", .{nested}),
        .data = "y",
    });

    try cleanDir(root);

    var dir = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    try std.testing.expect((try iter.next()) == null);

    try cleanDir("/tmp/tin_test_clean_dir_missing");
}
