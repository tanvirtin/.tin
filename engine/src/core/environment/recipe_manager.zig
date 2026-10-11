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
    copy: bool = false,
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
                .copy = entry.copy,
            });
        }

        key_idx = symlinks_section.tree.nodes.items[val_idx].next_sibling;
    }

    return try symlinks.toOwnedSlice(allocator);
}

pub fn getFontSourceDir(allocator: std.mem.Allocator, config: Config, paths: Paths) ![]const u8 {
    const default_path = try std.fs.path.join(allocator, &.{ paths.tin_dir, "environment", "config", "fonts" });
    const fonts_val = config.getMapping("fonts") orelse return default_path;
    const fonts_path = fonts_val.getString() orelse return default_path;
    return paths.absolutePath(allocator, fonts_path);
}

pub const ExportTarget = struct {
    name: []const u8,
    dir: []const u8,
};

pub fn getExportTargets(allocator: std.mem.Allocator, config: Config, paths: Paths) ![]const ExportTarget {
    const exports_section = config.getMapping("exports") orelse return &.{};

    const node = exports_section.tree.nodes.items[exports_section.idx];
    if (node.tag != .mapping) return &.{};

    var collected: std.ArrayListUnmanaged(ExportTarget) = .{};
    defer collected.deinit(allocator);

    var key_idx = node.first_child;
    while (key_idx != 0) {
        const val_idx = exports_section.tree.nodes.items[key_idx].next_sibling;
        if (val_idx == 0) break;

        const key_val = exports_section.tree.nodes.items[key_idx];
        const name = key_val.computed_value orelse exports_section.tree.source[key_val.start..key_val.end];

        const dir_val = yaml.Value{ .tree = exports_section.tree, .idx = val_idx, .arena = exports_section.arena };
        if (dir_val.getMapping("dir")) |dir_raw| {
            if (dir_raw.getString()) |dir_str| {
                try collected.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .dir = try paths.absolutePath(allocator, dir_str),
                });
            }
        }

        key_idx = exports_section.tree.nodes.items[val_idx].next_sibling;
    }

    return try collected.toOwnedSlice(allocator);
}

pub const Runtime = struct {
    name: []const u8,
    mcp_path: []const u8,
    dialect: []const u8,
};

fn runtimeString(val: yaml.Value, key: []const u8) ?[]const u8 {
    const v = val.getMapping(key) orelse return null;
    return v.getString();
}

fn resolveRuntimePath(
    allocator: std.mem.Allocator,
    paths: Paths,
    path: []const u8,
    cwd: ?[]const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(allocator, &.{ paths.home_dir, path[2..] });
    }
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    // Project-scoped runtimes (e.g. VS Code's .vscode/mcp.json) resolve against cwd.
    return std.fs.path.join(allocator, &.{ cwd orelse ".", path });
}

pub fn getRuntimes(allocator: std.mem.Allocator, config: Config, paths: Paths) ![]const Runtime {
    const section = config.getMapping("runtimes") orelse return &.{};
    const node = section.tree.nodes.items[section.idx];
    if (node.tag != .mapping) return &.{};

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch null;

    var list: std.ArrayListUnmanaged(Runtime) = .{};
    var child = node.first_child;
    while (child != 0) {
        const key_node = section.tree.nodes.items[child];
        const name = key_node.computed_value orelse section.tree.source[key_node.start..key_node.end];
        const val_idx = key_node.next_sibling;
        if (val_idx == 0) break;

        const val = yaml.Value{ .tree = section.tree, .idx = val_idx, .arena = section.arena };
        const mcp_s = runtimeString(val, "mcp");
        const dialect_s = runtimeString(val, "dialect");
        if (mcp_s != null and dialect_s != null) {
            try list.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .mcp_path = try resolveRuntimePath(allocator, paths, mcp_s.?, cwd),
                .dialect = try allocator.dupe(u8, dialect_s.?),
            });
        }

        child = section.tree.nodes.items[val_idx].next_sibling;
    }
    return list.toOwnedSlice(allocator);
}

test "getRuntimes parses targets and resolves cwd-relative paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a,
        \\runtimes:
        \\  cursor:
        \\    mcp: ~/.cursor/mcp.json
        \\    dialect: cursor
        \\  vscode:
        \\    mcp: .vscode/mcp.json
        \\    dialect: vscode
    );
    const config = Config{ .doc = doc };
    const paths = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const runtimes = try getRuntimes(a, config, paths);
    try std.testing.expectEqual(@as(usize, 2), runtimes.len);
    try std.testing.expectEqualStrings("cursor", runtimes[0].name);
    try std.testing.expectEqualStrings("/home/u/.cursor/mcp.json", runtimes[0].mcp_path);
    try std.testing.expectEqualStrings("cursor", runtimes[0].dialect);
    try std.testing.expect(std.mem.endsWith(u8, runtimes[1].mcp_path, ".vscode/mcp.json"));
}

test "getInstallSteps parses link, fonts, and recipes group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a,
        \\install:
        \\  - link
        \\  - fonts
        \\  - recipes: shell
        \\recipes:
        \\  shell:
        \\    - zsh
        \\    - tmux
    );
    const config = Config{ .doc = doc };
    const steps = try getInstallSteps(a, config);
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expect(steps[0] == .link);
    try std.testing.expect(steps[1] == .fonts);
    try std.testing.expect(steps[2] == .recipes);
    try std.testing.expectEqual(@as(usize, 2), steps[2].recipes.len);
    try std.testing.expectEqualStrings("zsh", steps[2].recipes[0]);
    try std.testing.expectEqualStrings("tmux", steps[2].recipes[1]);
}

test "getInstallSteps returns empty when no install section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a, "identity:\n  name: x");
    const config = Config{ .doc = doc };
    const steps = try getInstallSteps(a, config);
    try std.testing.expectEqual(@as(usize, 0), steps.len);
}

test "getRecipeGroup extracts names from a group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a,
        \\recipes:
        \\  shell:
        \\    - zsh
        \\    - tmux
    );
    const config = Config{ .doc = doc };
    const names = try getRecipeGroup(a, config, "shell");
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("zsh", names[0]);
    try std.testing.expectEqualStrings("tmux", names[1]);
}

test "getRecipeGroup returns empty for unknown group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a, "recipes:\n  shell:\n    - zsh");
    const config = Config{ .doc = doc };
    const names = try getRecipeGroup(a, config, "nope");
    try std.testing.expectEqual(@as(usize, 0), names.len);
}

test "getFontSourceDir defaults to environment/config/fonts under tin_dir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a, "identity:\n  name: x");
    const config = Config{ .doc = doc };
    const paths = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const dir = try getFontSourceDir(a, config, paths);
    try std.testing.expectEqualStrings("/tin/environment/config/fonts", dir);
}

test "getExportTargets extracts configured export targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a,
        \\exports:
        \\  opencode:
        \\    dir: ~/.config/opencode/agent
        \\  claude:
        \\    dir: ~/Documents/claude/skills
    );
    const config = Config{ .doc = doc };
    const paths = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const targets = try getExportTargets(a, config, paths);
    try std.testing.expectEqual(@as(usize, 2), targets.len);
    try std.testing.expectEqualStrings("opencode", targets[0].name);
    try std.testing.expectEqualStrings("/home/u/.config/opencode/agent", targets[0].dir);
    try std.testing.expectEqualStrings("claude", targets[1].name);
    try std.testing.expectEqualStrings("/home/u/Documents/claude/skills", targets[1].dir);
}

test "getExportTargets returns empty when no exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try yaml.parse(a, "identity:\n  name: x");
    const config = Config{ .doc = doc };
    const paths = Paths{ .tin_dir = "/tin", .home_dir = "/home/u" };
    const targets = try getExportTargets(a, config, paths);
    try std.testing.expectEqual(@as(usize, 0), targets.len);
}
