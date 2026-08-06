const std = @import("std");
const fs = @import("../../lib/fs.zig");
const toml = @import("../../lib/toml.zig");
const Paths = @import("../environment/paths.zig");

pub const Probe = struct {
    name: []const u8,
    path: []const u8,
    is_git_repo: bool,
    has_mise: bool,
    tools: []const []const u8,
    env: []const []const u8,
};

pub const ProbeError = error{
    PathNotExists,
    NotADirectory,
    ReadFailed,
};

/// The mise.toml file locations, in precedence order (highest first).
const mise_config_files = [_][]const u8{
    "mise.local.toml",
    "mise.toml",
    "mise/config.toml",
    ".mise/config.toml",
    ".config/mise.toml",
    ".config/mise/config.toml",
};

/// Resolve the first existing mise config file within `path`, or null.
pub fn findMiseConfig(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    for (mise_config_files) |rel| {
        const candidate = std.fs.path.join(allocator, &.{ path, rel }) catch continue;
        if (fs.pathExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

/// Resolve the workspace name from a path: last path segment.
pub fn nameFromPath(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, path, "/");
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse 0;
    const base = if (slash == 0) trimmed else trimmed[slash + 1 ..];
    return allocator.dupe(u8, base) catch "";
}

/// Probe a project root: existence, git, mise config + its tools/env.
pub fn probe(allocator: std.mem.Allocator, paths: Paths, path: []const u8) !Probe {
    _ = paths;
    if (!fs.pathExists(path)) return error.PathNotExists;

    var tools = std.ArrayListUnmanaged([]const u8){};
    var env = std.ArrayListUnmanaged([]const u8){};
    var has_mise = false;

    if (findMiseConfig(allocator, path)) |cfg_path| {
        defer allocator.free(cfg_path);
        has_mise = true;
        const content = fs.readFileAlloc(allocator, cfg_path) catch return error.ReadFailed;
        const doc = toml.parse(allocator, content) catch return error.ReadFailed;

        if (doc.find("tools")) |sec| {
            for (sec.entries) |entry| {
                if (entry.value == .string) {
                    const pair = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ entry.key, entry.value.string });
                    try tools.append(allocator, pair);
                }
            }
        }
        if (doc.find("env")) |sec| {
            for (sec.entries) |entry| {
                if (entry.value == .string) {
                    const pair = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key, entry.value.string });
                    try env.append(allocator, pair);
                }
            }
        }
    }

    const git_dir = std.fs.path.join(allocator, &.{ path, ".git" }) catch "";
    defer allocator.free(git_dir);
    const is_git = fs.pathExists(git_dir);

    return .{
        .name = nameFromPath(allocator, path),
        .path = try allocator.dupe(u8, path),
        .is_git_repo = is_git,
        .has_mise = has_mise,
        .tools = try tools.toOwnedSlice(allocator),
        .env = try env.toOwnedSlice(allocator),
    };
}

/// Emit a seeded, commented workspace YAML from a probe result.
pub fn emitYaml(allocator: std.mem.Allocator, p: *const Probe) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print("name: {s}\n", .{p.name});
    try w.print("path: {s}\n", .{p.path});
    try w.writeAll("\n");

    if (p.tools.len > 0) {
        try w.writeAll("# seeded from mise.toml [tools]\ntools:\n");
        for (p.tools) |tool| {
            const at = std.mem.lastIndexOfScalar(u8, tool, '@') orelse continue;
            try w.print("  {s}: \"{s}\"\n", .{ tool[0..at], tool[at + 1 ..] });
        }
        try w.writeAll("\n");
    }

    if (p.env.len > 0) {
        try w.writeAll("# seeded from mise.toml [env]\nenv:\n");
        for (p.env) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            try w.print("  {s}: \"{s}\"\n", .{ item[0..eq], item[eq + 1 ..] });
        }
        try w.writeAll("\n");
    }

    if (p.has_mise) {
        try w.writeAll("# mise tasks live in your mise.toml; map long-running ones here:\n");
    }

    try w.writeAll(
        \\# Add components below — one runtime each (process | container | compose | task)
        \\# plus modifiers (dir, env, tool, depends_on, healthcheck, scale, ...).
        \\# See `tin help workspace schema` for the full model.
        \\components: {}
        \\
    );

    return buf.toOwnedSlice(allocator);
}
