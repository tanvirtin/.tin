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

fn configDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.home_dir, ".config", "tin" });
}

pub fn recipesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "environment", "recipes" });
}

pub fn personalRecipesDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const dir = std.process.getEnvVarOwned(allocator, "TIN_RECIPES") catch {
        const config_dir = try self.configDir(allocator);
        defer allocator.free(config_dir);
        return std.fs.path.join(allocator, &.{ config_dir, "recipes" });
    };

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
    return std.fs.path.join(allocator, &.{ self.tin_dir, "engine", "src", "schemas" });
}

pub fn personalTinrcPath(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const config_dir = try self.configDir(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "tinrc.yml" });
}

pub fn repoTinrcPath(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "tinrc.yml" });
}

pub fn tinrcPath(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const personal = try self.personalTinrcPath(allocator);
    if (fs.pathExists(personal)) return personal;
    allocator.free(personal);
    return self.repoTinrcPath(allocator);
}

pub fn artifactsDir(self: *const Paths, allocator: std.mem.Allocator) ![]const u8 {
    const dir = std.process.getEnvVarOwned(allocator, "TIN_ARTIFACTS") catch {
        const config_dir = try self.configDir(allocator);
        defer allocator.free(config_dir);
        return std.fs.path.join(allocator, &.{ config_dir, "artifacts" });
    };

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

test "absolutePath expands leading tilde to home" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/home/u/foo", try p.absolutePath(arena.allocator(), "~/foo"));
}

test "absolutePath keeps already-absolute paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/abs/path", try p.absolutePath(arena.allocator(), "/abs/path"));
}

test "absolutePath resolves relative paths against tin_dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/tin/config/x", try p.absolutePath(arena.allocator(), "config/x"));
}

test "absolutePath strips trailing slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/home/u/foo", try p.absolutePath(arena.allocator(), "~/foo/"));
}

test "personalRecipesDir defaults to ~/.config/tin/recipes when no override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const dir = try p.personalRecipesDir(a);
    try std.testing.expectEqualStrings("/home/u/.config/tin/recipes", dir);
}

test "artifactsDir defaults to ~/.config/tin/artifacts when no override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const dir = try p.artifactsDir(a);
    try std.testing.expectEqualStrings("/home/u/.config/tin/artifacts", dir);
}

test "personalTinrcPath defaults to ~/.config/tin/tinrc.yml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/home/u/.config/tin/tinrc.yml", try p.personalTinrcPath(arena.allocator()));
}

test "repoTinrcPath sits at the tin dir root" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/tin/tinrc.yml", try p.repoTinrcPath(arena.allocator()));
}

test "tinrcPath falls back to the repo default when no personal override exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const p = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    try std.testing.expectEqualStrings("/tin/tinrc.yml", try p.tinrcPath(arena.allocator()));
}

test "tinrcPath prefers the personal override when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.parent_dir.realpathAlloc(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(root);

    const tin_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".tin" });
    defer std.testing.allocator.free(tin_dir);
    const config_dir = try std.fs.path.join(std.testing.allocator, &.{ root, ".config", "tin" });
    defer std.testing.allocator.free(config_dir);
    const repo_file = try std.fs.path.join(std.testing.allocator, &.{ tin_dir, "tinrc.yml" });
    defer std.testing.allocator.free(repo_file);
    const personal_file = try std.fs.path.join(std.testing.allocator, &.{ config_dir, "tinrc.yml" });
    defer std.testing.allocator.free(personal_file);

    const p = Paths{ .tin_dir = tin_dir, .home_dir = root };

    try fs.ensureDirectoryExists(tin_dir);
    try fs.writeFile(repo_file, "identity:\n  name: repo");
    {
        const path = try p.tinrcPath(std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings(repo_file, path);
    }

    try fs.ensureDirectoryExists(config_dir);
    try fs.writeFile(personal_file, "identity:\n  name: personal");
    {
        const path = try p.tinrcPath(std.testing.allocator);
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings(personal_file, path);
    }
}
