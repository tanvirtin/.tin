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

pub fn remove(allocator: std.mem.Allocator, paths: Paths, name: []const u8) !void {
    const path = try paths.workspaceFile(allocator, name);
    defer allocator.free(path);
    try std.fs.deleteFileAbsolute(path);
}

/// Extract the project root `path` field from a workspace file.
pub fn projectPath(allocator: std.mem.Allocator, paths: Paths, name: []const u8) ![]const u8 {
    const ws = try load(allocator, paths, name);
    return ws.path;
}

/// Collect all project paths from a workspace (path + projects.* values).
pub fn projectPaths(allocator: std.mem.Allocator, paths: Paths, name: []const u8) ![]const []const u8 {
    const ws = try load(allocator, paths, name);
    var doc = yaml.parse(allocator, ws.content) catch return error.ReadFailed;
    defer doc.deinit();

    var list = std.ArrayListUnmanaged([]const u8){};

    // Always include the primary path if present
    try list.append(allocator, ws.path);

    // Collect additional projects
    if (doc.getMapping("projects")) |projs_v| {
        const node = projs_v.tree.nodes.items[projs_v.idx];
        if (node.tag == .mapping) {
            var child = node.first_child;
            while (child != 0) {
                const val_idx = projs_v.tree.nodes.items[child].next_sibling;
                if (val_idx != 0) {
                    const val_node = projs_v.tree.nodes.items[val_idx];
                    const val_start = val_node.computed_value_start orelse val_node.start;
                    const val_end = val_node.computed_value_end orelse val_node.end;
                    const proj_path = projs_v.tree.source[val_start..val_end];
                    try list.append(allocator, try allocator.dupe(u8, proj_path));
                }
                child = projs_v.tree.nodes.items[val_idx].next_sibling;
            }
        }
    }

    return list.toOwnedSlice(allocator);
}
