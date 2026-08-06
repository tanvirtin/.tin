const std = @import("std");
const fs = @import("../../lib/fs.zig");

pub const Paths = @This();

tin_dir: []const u8,
home_dir: []const u8,

pub fn init(allocator: std.mem.Allocator) !Paths {
    const home = try fs.homeDir();
    const tin_dir = if (std.process.getEnvVarOwned(allocator, "TIN_DIR")) |dir|
        dir
    else |_|
        try std.fs.path.join(allocator, &.{ home, ".tin" });

    return .{
        .tin_dir = tin_dir,
        .home_dir = home,
    };
}

pub fn recipesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "recipes" });
}

pub fn workspacesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "TIN_WORKSPACES_DIR")) |dir|
        return dir
    else |_|
        return std.fs.path.join(allocator, &.{ self.home_dir, ".config", "tin", "workspaces" });
}

pub fn workspaceFile(self: *const Paths, allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const dir = try self.workspacesDir(allocator);
    return std.fmt.allocPrint(allocator, "{s}/{s}.yml", .{ dir, name });
}

pub fn seedMethodsDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "methods" });
}

pub fn methodsDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.home_dir, ".config", "tin", "methods" });
}

pub fn envFile(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, ".env" });
}

pub fn piAgentDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.home_dir, ".pi", "agent" });
}

pub fn piAuthFile(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.home_dir, ".pi", "agent", "auth.json" });
}

pub fn piSettingsFile(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.home_dir, ".pi", "agent", "settings.json" });
}

pub fn absolutePath(self: *const Paths, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const resolved = if (std.mem.startsWith(u8, path, "~/"))
        try std.fs.path.join(allocator, &.{ self.home_dir, path[2..] })
    else if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ self.tin_dir, path });

    if (resolved.len > 1 and resolved[resolved.len - 1] == '/') {
        return resolved[0 .. resolved.len - 1];
    }
    return resolved;
}
