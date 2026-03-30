const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("../lib/yaml.zig");
const Symlink = @import("symlink.zig");

const Environment = @This();

tin_dir: []const u8,
home_dir: []const u8,
config: ?yaml.Value,

pub const EnvironmentError = error{
    HomeNotSet,
};

const SymlinkEntry = struct {
    source: []const u8,
    target: []const u8,
};

pub fn managedSymlinks(self: *const Environment, allocator: std.mem.Allocator) ![]const Symlink {
    const config = self.config orelse return &.{};
    const symlinks_section = config.getMapping("symlinks") orelse return &.{};

    var symlinks: std.ArrayList(Symlink) = .{};

    const groups = switch (symlinks_section) {
        .mapping => |m| m,
        else => return &.{},
    };

    for (groups) |group| {
        const entries = group.value.getSequence() orelse continue;
        for (entries) |entry_val| {
            const entry = yaml.decode(SymlinkEntry, allocator, entry_val) catch continue;

            const target = if (std.mem.startsWith(u8, entry.target, "~/"))
                try std.fs.path.join(allocator, &.{ self.home_dir, entry.target[2..] })
            else
                entry.target;

            const source = try std.fs.path.join(allocator, &.{ self.tin_dir, entry.source });

            try symlinks.append(allocator, .{
                .source = source,
                .target = target,
                .name = std.fs.path.basename(entry.source),
            });
        }
    }

    return symlinks.items;
}

pub const Identity = struct {
    name: []const u8,
    email: []const u8,
};

pub fn identity(self: *const Environment, allocator: std.mem.Allocator) ?Identity {
    const config = self.config orelse return null;
    const id_val = config.getMapping("identity") orelse return null;
    return yaml.decode(Identity, allocator, id_val) catch return null;
}

pub const TemplateVar = struct { []const u8, []const u8 };

pub fn templateVars(self: *const Environment, allocator: std.mem.Allocator) ![]const TemplateVar {
    var vars: std.ArrayList(TemplateVar) = .{};
    if (self.identity(allocator)) |id| {
        try vars.append(allocator, .{ "identity.name", id.name });
        try vars.append(allocator, .{ "identity.email", id.email });
    }
    return vars.items;
}

pub const InstallStep = union(enum) {
    link,
    fonts,
    recipes: []const []const u8,
};

pub fn recipeGroup(self: *const Environment, allocator: std.mem.Allocator, group: []const u8) ![]const []const u8 {
    const config = self.config orelse return &.{};
    const recipes_section = config.getMapping("recipes") orelse return &.{};
    const group_val = recipes_section.getMapping(group) orelse return &.{};
    const items = group_val.getSequence() orelse return &.{};

    var names: std.ArrayList([]const u8) = .{};
    for (items) |item| {
        if (item.getString()) |name| {
            try names.append(allocator, name);
        }
    }
    return names.items;
}

pub fn installSteps(self: *const Environment, allocator: std.mem.Allocator) ![]const InstallStep {
    const config = self.config orelse return &.{};
    const install_section = config.getMapping("install") orelse return &.{};
    const steps = install_section.getSequence() orelse return &.{};

    var collected: std.ArrayList(InstallStep) = .{};

    for (steps) |step| {
        if (step.getString()) |s| {
            if (std.mem.eql(u8, s, "link")) {
                try collected.append(allocator, .link);
            } else if (std.mem.eql(u8, s, "fonts")) {
                try collected.append(allocator, .fonts);
            }
            continue;
        }

        if (step.getMapping("recipes")) |group_val| {
            const group_name = group_val.getString() orelse continue;
            const recipe_names = try self.recipeGroup(allocator, group_name);
            try collected.append(allocator, .{ .recipes = recipe_names });
        }
    }

    return collected.items;
}

pub fn recipesDir(self: *const Environment, allocator: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(allocator, &.{ self.tin_dir, "recipes" });
}

pub fn fontSourceDir(self: *const Environment, allocator: std.mem.Allocator) ![]const u8 {
    const default_path = try std.fs.path.join(allocator, &.{ self.tin_dir, "assets", "fonts" });
    const config = self.config orelse return default_path;
    const fonts_val = config.getMapping("fonts") orelse return default_path;
    const fonts_path = fonts_val.getString() orelse return default_path;
    return std.fs.path.join(allocator, &.{ self.tin_dir, fonts_path });
}

pub fn init(allocator: std.mem.Allocator) !Environment {
    const home = fs.homeDir() catch return EnvironmentError.HomeNotSet;
    const tin_dir = try std.fs.path.join(allocator, &.{ home, ".tin" });

    const config_path = try std.fs.path.join(allocator, &.{ tin_dir, "tinrc.yml" });
    const config = blk: {
        const file = std.fs.openFileAbsolute(config_path, .{}) catch break :blk null;
        defer file.close();
        const content = file.readToEndAlloc(allocator, 256 * 1024) catch break :blk null;
        break :blk yaml.parse(allocator, content) catch null;
    };

    return .{
        .tin_dir = tin_dir,
        .home_dir = home,
        .config = config,
    };
}

test "init resolves environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (Environment.init(arena.allocator())) |env| {
        try std.testing.expect(env.home_dir.len > 0);
        try std.testing.expect(env.tin_dir.len > 0);
    } else |_| {}
}

test "managed symlinks from tinrc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (Environment.init(arena.allocator())) |env| {
        if (env.config == null) return; // tinrc.yml not at $HOME/.tin
        const symlinks = try env.managedSymlinks(arena.allocator());
        try std.testing.expect(symlinks.len >= 5);
        try std.testing.expectEqualStrings(".zshrc", symlinks[0].name);
    } else |_| {}
}

test "identity from tinrc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (Environment.init(arena.allocator())) |env| {
        if (env.config == null) return;
        if (env.identity(arena.allocator())) |id| {
            try std.testing.expect(id.name.len > 0);
            try std.testing.expect(id.email.len > 0);
        }
    } else |_| {}
}

test "install steps from tinrc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (Environment.init(arena.allocator())) |env| {
        if (env.config == null) return;
        const steps = try env.installSteps(arena.allocator());
        try std.testing.expect(steps.len >= 3);
        try std.testing.expectEqual(InstallStep.link, steps[0]);
        try std.testing.expectEqual(InstallStep.fonts, steps[1]);
        switch (steps[2]) {
            .recipes => |names| try std.testing.expect(names.len >= 3),
            else => return error.TestUnexpectedResult,
        }
    } else |_| {}
}

test "recipe group from tinrc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (Environment.init(arena.allocator())) |env| {
        if (env.config == null) return;
        const shell = try env.recipeGroup(arena.allocator(), "shell");
        try std.testing.expect(shell.len >= 3);
        try std.testing.expectEqualStrings("zsh", shell[0]);
    } else |_| {}
}
