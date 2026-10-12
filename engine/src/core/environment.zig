const std = @import("std");

pub const Paths = @import("environment/paths.zig");
pub const Config = @import("environment/config.zig");
pub const Identity = @import("environment/identity.zig").Identity;
pub const IdentityProvider = @import("environment/identity.zig");
pub const TemplateVar = IdentityProvider.TemplateVar;
pub const RecipeManager = @import("environment/recipe_manager.zig");

const Environment = @This();

paths: Paths,
config: Config,
tin_dir: []const u8,
home_dir: []const u8,

pub fn init(allocator: std.mem.Allocator) !Environment {
    const paths = try Paths.init(allocator);
    const config = try Config.loadOrEmpty(allocator, paths);

    return .{
        .paths = paths,
        .config = config,
        .tin_dir = paths.tin_dir,
        .home_dir = paths.home_dir,
    };
}

pub fn managedSymlinks(self: *const Environment, allocator: std.mem.Allocator) ![]const @import("symlink.zig") {
    return RecipeManager.getManagedSymlinks(allocator, self.config, self.paths);
}

pub fn identity(self: *const Environment, allocator: std.mem.Allocator) ?Identity {
    return IdentityProvider.getIdentity(allocator, self.config);
}

pub fn recipesDir(self: *const Environment, allocator: std.mem.Allocator) ![]const u8 {
    return self.paths.recipesDir(allocator);
}
