const std = @import("std");
const fs = @import("../../lib/fs.zig");
const yaml = @import("yaml");
const Paths = @import("../environment/paths.zig");

pub const RegistryError = error{
    NotDirectory,
    ReadFailed,
};

pub const Workspace = struct {
    name: []const u8,
    path: []const u8,
    content: []const u8,

    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub fn ensureDir(allocator: std.mem.Allocator, paths: Paths) !void {
    const dir = try paths.workspacesDir(allocator);
    defer allocator.free(dir);
    try fs.ensureDirectoryExists(dir);
}

/// All workspace names present in the registry directory.
pub fn listNames(allocator: std.mem.Allocator, paths: Paths) ![]const []const u8 {
    const dir = try paths.workspacesDir(allocator);
    defer allocator.free(dir);

    if (!fs.pathExists(dir)) return &[_][]const u8{};

    var dir_handle = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch return error.NotDirectory;
    defer dir_handle.close();

    var names = std.ArrayListUnmanaged([]const u8){};
    var iter = dir_handle.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;
        const name = entry.name[0 .. entry.name.len - 4];
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    return names.toOwnedSlice(allocator);
}

pub fn load(allocator: std.mem.Allocator, paths: Paths, name: []const u8) !Workspace {
    const path = try paths.workspaceFile(allocator, name);
    defer allocator.free(path);

    const content = fs.readFileAlloc(allocator, path) catch return error.ReadFailed;

    var doc = yaml.parse(allocator, content) catch return error.ReadFailed;
    defer doc.deinit();

    const path_field = (doc.getMapping("path") orelse return error.ReadFailed).getString() orelse return error.ReadFailed;

    return .{
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path_field),
        .content = content,
    };
}

/// Write (create or overwrite) a workspace file.
pub fn write(allocator: std.mem.Allocator, paths: Paths, name: []const u8, content: []const u8) !void {
    try ensureDir(allocator, paths);
    const path = try paths.workspaceFile(allocator, name);
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

/// Extract the project root `path` field from a workspace file.
pub fn projectPath(allocator: std.mem.Allocator, paths: Paths, name: []const u8) ![]const u8 {
    const ws = try load(allocator, paths, name);
    return ws.path;
}
