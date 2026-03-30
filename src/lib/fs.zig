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
        // Parent of parent might not exist either — try recursive
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

pub fn isSymlink(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .sym_link;
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
