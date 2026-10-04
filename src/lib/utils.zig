const std = @import("std");

pub fn escapeJson(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return s;

    var buf = std.ArrayListUnmanaged(u8){};
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch continue,
            '\\' => buf.appendSlice(allocator, "\\\\") catch continue,
            '\n' => buf.appendSlice(allocator, "\\n") catch continue,
            '\r' => buf.appendSlice(allocator, "\\r") catch continue,
            '\t' => buf.appendSlice(allocator, "\\t") catch continue,
            else => buf.append(allocator, c) catch continue,
        }
    }
    return buf.toOwnedSlice(allocator) catch s;
}

pub fn slugify(allocator: std.mem.Allocator, id: []const u8) []const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    for (id) |c| {
        buf.append(allocator, if (c == '/') '-' else c) catch continue;
    }
    return buf.toOwnedSlice(allocator) catch id;
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
