const std = @import("std");

pub const FsError = error{
    HomeNotSet,
};

pub fn homeDir() FsError![]const u8 {
    return std.posix.getenv("HOME") orelse return FsError.HomeNotSet;
}

pub fn ensureDirectoryExists(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return e;
            if (parent.len > 0 and !std.mem.eql(u8, parent, path)) {
                try ensureDirectoryExists(parent);
                try ensureDirectoryExists(path);
            }
        },
        else => return e,
    };
}

pub fn ensureParentDirExists(path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return;
    ensureDirectoryExists(dir) catch |e| {
        switch (e) {
            error.FileNotFound => {
                try ensureParentDirExists(dir);
                try ensureDirectoryExists(dir);
            },
            else => return e,
        }
    };
}

pub fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 256 * 1024);
}

pub fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn deleteTree(path: []const u8) !void {
    try std.fs.deleteTreeAbsolute(path);
}

/// Names of immediate children of `path` (files and dirs). Empty on error.
pub fn listDir(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();

    var out = std.ArrayListUnmanaged([]const u8){};
    defer out.deinit(allocator);

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        try out.append(allocator, try allocator.dupe(u8, entry.name));
    }
    return out.toOwnedSlice(allocator);
}

test "homeDir returns a value or error" {
    if (homeDir()) |home| {
        try std.testing.expect(home.len > 0);
    } else |_| {}
}

test "pathExists for root directory" {
    try std.testing.expect(pathExists("/"));
}

test "pathExists for nonexistent path" {
    try std.testing.expect(!pathExists("/nonexistent_path_that_should_not_exist"));
}

test "ensureDirectoryExists creates and tolerates existing" {
    const path = "/tmp/tin_test_ensure_dir";
    std.fs.deleteTreeAbsolute(path) catch {};
    try ensureDirectoryExists(path);
    try std.testing.expect(pathExists(path));
    try ensureDirectoryExists(path);
    std.fs.deleteTreeAbsolute(path) catch {};
}

test "ensureParentDirExists creates parent chain" {
    const path = "/tmp/tin_test_parent/child/file.txt";
    std.fs.deleteTreeAbsolute("/tmp/tin_test_parent") catch {};
    try ensureParentDirExists(path);
    try std.testing.expect(pathExists("/tmp/tin_test_parent/child"));
    std.fs.deleteTreeAbsolute("/tmp/tin_test_parent") catch {};
}
