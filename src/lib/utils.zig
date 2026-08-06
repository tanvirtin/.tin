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

pub fn cleanDir(allocator: std.mem.Allocator, path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
            defer allocator.free(sub);
            cleanDir(allocator, sub);
            dir.deleteDir(entry.name) catch {};
        } else {
            dir.deleteFile(entry.name) catch {};
        }
    }
}
