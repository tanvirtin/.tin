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

