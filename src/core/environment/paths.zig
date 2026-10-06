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

pub const RecipeLayer = struct {
    dir: []const u8,
    origin: []const u8,
};

pub const RecipeSearch = struct {
    layers: [2]RecipeLayer,
    count: usize,

    pub fn deinit(self: RecipeSearch, allocator: std.mem.Allocator) void {
        for (self.layers[0..self.count]) |layer| allocator.free(layer.dir);
    }

    pub fn resolve(self: RecipeSearch, allocator: std.mem.Allocator, name: []const u8) !?struct { path: []const u8, origin: []const u8 } {
        for (self.layers[0..self.count]) |layer| {
            const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}.yml", .{ layer.dir, name });
            if (fs.pathExists(candidate)) {
                return .{ .path = candidate, .origin = layer.origin };
            }
            allocator.free(candidate);
        }
        return null;
    }
};

pub fn recipesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "recipes" });
}

pub fn personalRecipesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const dir = std.process.getEnvVarOwned(allocator, "TIN_RECIPES") catch
        return std.fs.path.join(allocator, &.{ self.home_dir, ".config", "tin", "recipes" });

    return dir;
}

pub fn recipeSearch(self: *const Paths, allocator: std.mem.Allocator) !RecipeSearch {
    const personal = try self.personalRecipesDir(allocator);
    errdefer allocator.free(personal);

    const repo = try self.recipesDir(allocator);
    errdefer allocator.free(repo);

    return .{
        .layers = .{
            .{ .dir = personal, .origin = "config" },
            .{ .dir = repo, .origin = "repo" },
        },
        .count = 2,
    };
}

pub fn schemasDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "src", "schemas" });
}

pub fn artifactsDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const dir = std.process.getEnvVarOwned(allocator, "TIN_ARTIFACTS") catch
        return std.fs.path.join(allocator, &.{ self.home_dir, ".config", "tin", "artifacts" });

    return dir;
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
