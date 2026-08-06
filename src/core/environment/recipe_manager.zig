const std = @import("std");
const yaml = @import("yaml");
const Config = @import("config.zig");
const Paths = @import("paths.zig");
const Symlink = @import("../symlink.zig");

pub const InstallStep = union(enum) {
    link,
    fonts,
    recipes: []const []const u8,
};

pub fn getInstallSteps(allocator: std.mem.Allocator, config: Config) ![]const InstallStep {
    const install_section = config.getMapping("install") orelse return &.{};
    const steps = install_section.getSequence() orelse return &.{};

    var collected: std.ArrayListUnmanaged(InstallStep) = .{};

    for (steps) |step_val| {
        if (step_val.getString()) |s| {
            if (std.mem.eql(u8, s, "link")) {
                try collected.append(allocator, .link);
            } else if (std.mem.eql(u8, s, "fonts")) {
                try collected.append(allocator, .fonts);
            }
            continue;
        }

        if (step_val.getMapping("recipes")) |group_val| {
            if (group_val.getString()) |group_name| {
                const recipe_names = try getRecipeGroup(allocator, config, group_name);
                try collected.append(allocator, .{ .recipes = recipe_names });
            }
        }
    }

    return try collected.toOwnedSlice(allocator);
}

pub fn getRecipeGroup(allocator: std.mem.Allocator, config: Config, group: []const u8) ![]const []const u8 {
    const recipes_section = config.getMapping("recipes") orelse return &.{};
    const group_val = recipes_section.getMapping(group) orelse return &.{};
    const items = group_val.getSequence() orelse return &.{};

    var names: std.ArrayListUnmanaged([]const u8) = .{};
    for (items) |item| {
        if (item.getString()) |name| {
            try names.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return try names.toOwnedSlice(allocator);
}

const SymlinkEntry = struct {
    source: []const u8,
    target: []const u8,
};

pub fn getManagedSymlinks(allocator: std.mem.Allocator, config: Config, paths: Paths) ![]const Symlink {
    const symlinks_section = config.getMapping("symlinks") orelse return &.{};

    var symlinks: std.ArrayListUnmanaged(Symlink) = .{};
    defer symlinks.deinit(allocator);

    const node = symlinks_section.tree.nodes.items[symlinks_section.idx];
    if (node.tag != .mapping) return &.{};

    var key_idx = node.first_child;
    while (key_idx != 0) {
        const val_idx = symlinks_section.tree.nodes.items[key_idx].next_sibling;
        if (val_idx == 0) break;
        
        const group_val = yaml.Value{ .tree = symlinks_section.tree, .idx = val_idx, .arena = symlinks_section.arena };
        const entries = group_val.getSequence() orelse {
            key_idx = symlinks_section.tree.nodes.items[val_idx].next_sibling;
            continue;
        };

        for (entries) |entry_val| {
            const entry = yaml.decodeValue(SymlinkEntry, allocator, entry_val) catch continue;
            const target = try paths.absolutePath(allocator, entry.target);
            const source = try paths.absolutePath(allocator, entry.source);

            try symlinks.append(allocator, .{
                .source = source,
                .target = target,
                .name = try allocator.dupe(u8, std.fs.path.basename(entry.source)),
            });
        }
        
        key_idx = symlinks_section.tree.nodes.items[val_idx].next_sibling;
    }

    return try symlinks.toOwnedSlice(allocator);
}

pub fn getFontSourceDir(allocator: std.mem.Allocator, config: Config, paths: Paths) ![]const u8 {
    const default_path = try std.fs.path.join(allocator, &.{ paths.tin_dir, "assets", "fonts" });
    const fonts_val = config.getMapping("fonts") orelse return default_path;
    const fonts_path = fonts_val.getString() orelse return default_path;
    return paths.absolutePath(allocator, fonts_path);
}
