const std = @import("std");
const fs = @import("../lib/fs.zig");
const Engine = @import("../spec/engine.zig").Engine;
const Diagnostic = @import("../spec/diagnostic.zig").Diagnostic;

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
    const config = Config.load(allocator, paths) orelse Config{ .doc = null };

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

pub fn fontSourceDir(self: *const Environment, allocator: std.mem.Allocator) ![]const u8 {
    return RecipeManager.getFontSourceDir(allocator, self.config, self.paths);
}

pub fn validateTinrc(allocator: std.mem.Allocator, paths: Paths) ?[]const Diagnostic {
    const tinrc_path = std.fs.path.join(allocator, &.{ paths.tin_dir, "tinrc.yml" }) catch return null;
    defer allocator.free(tinrc_path);
    if (!fs.pathExists(tinrc_path)) return null;

    const schemas_dir = paths.schemasDir(allocator) catch return null;
    defer allocator.free(schemas_dir);

    var engine = Engine.initWithSchemasDir(allocator, schemas_dir) catch return null;
    defer engine.deinit();

    return engine.validateFile(allocator, schemas_dir, "tinrc.yaml", tinrc_path) catch null;
}
