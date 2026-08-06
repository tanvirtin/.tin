const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("yaml");
const Paths = @import("environment/paths.zig").Paths;

pub const Layer = enum { seed, user };

pub const Method = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    runtime: []const u8,
    layer: Layer,
    content: []const u8,
};

pub const Error = error{ ParseFailed };

/// A method file that could not be loaded. The catalog stays usable when a
/// single file is broken — the failure is recorded and surfaced, not fatal.
pub const SkippedFile = struct {
    layer: Layer,
    path: []const u8,
    reason: []const u8,
};

/// The method catalog: seed layer (versioned in the tin repo) merged with the
/// user layer (`~/.config/tin/methods`). User methods shadow seed methods with
/// the same id — the documented merge rule.
pub const Catalog = struct {
    allocator: std.mem.Allocator,
    items: []Method,
    /// Files that failed to load (bad YAML, missing name/runtime, ...).
    /// Loaded per layer; user layer entries come after seed entries.
    skipped: []SkippedFile,

    pub fn init(allocator: std.mem.Allocator, paths: *const Paths) !Catalog {
        const seed_dir = try paths.seedMethodsDir(allocator);
        const user_dir = try paths.methodsDir(allocator);

        var seed = std.ArrayListUnmanaged(Method){};
        defer seed.deinit(allocator);
        var seed_skipped = std.ArrayListUnmanaged(SkippedFile){};
        defer seed_skipped.deinit(allocator);
        try collectLayer(allocator, seed_dir, .seed, &seed, &seed_skipped);

        var user = std.ArrayListUnmanaged(Method){};
        defer user.deinit(allocator);
        var user_skipped = std.ArrayListUnmanaged(SkippedFile){};
        defer user_skipped.deinit(allocator);
        try collectLayer(allocator, user_dir, .user, &user, &user_skipped);

        var all_skipped = std.ArrayListUnmanaged(SkippedFile){};
        defer all_skipped.deinit(allocator);
        try all_skipped.appendSlice(allocator, seed_skipped.items);
        try all_skipped.appendSlice(allocator, user_skipped.items);
        const skipped = try all_skipped.toOwnedSlice(allocator);
        errdefer allocator.free(skipped);

        // Keep seed items only when not shadowed by a same-id user method.
        var merged = std.ArrayListUnmanaged(Method){};
        defer merged.deinit(allocator);
        for (seed.items) |s| {
            if (!containsId(user.items, s.id)) try merged.append(allocator, s);
        }
        for (user.items) |u| try merged.append(allocator, u);

        const items = try merged.toOwnedSlice(allocator);
        errdefer allocator.free(items);
        return .{ .allocator = allocator, .items = items, .skipped = skipped };
    }

    pub fn deinit(self: *Catalog) void {
        self.allocator.free(self.items);
        self.allocator.free(self.skipped);
    }

    pub fn find(self: *const Catalog, id: []const u8) ?Method {
        for (self.items) |m| {
            if (std.mem.eql(u8, m.id, id)) return m;
        }
        return null;
    }
};

fn containsId(items: []const Method, id: []const u8) bool {
    for (items) |m| {
        if (std.mem.eql(u8, m.id, id)) return true;
    }
    return false;
}

fn collectLayer(
    allocator: std.mem.Allocator,
    dir: []const u8,
    layer: Layer,
    out: *std.ArrayListUnmanaged(Method),
    skipped_out: *std.ArrayListUnmanaged(SkippedFile),
) !void {
    if (!fs.pathExists(dir)) return;

    var dir_handle = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch return;
    defer dir_handle.close();

    var iter = dir_handle.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;

        const id = entry.name[0 .. entry.name.len - 4];
        const file_path = try std.fs.path.join(allocator, &.{ dir, entry.name });
        defer allocator.free(file_path);

        const content = fs.readFileAlloc(allocator, file_path) catch |err| {
            try skip(allocator, skipped_out, layer, file_path, "unreadable (", @errorName(err));
            continue;
        };
        errdefer allocator.free(content);

        var doc = yaml.parse(allocator, content) catch |err| {
            try skip(allocator, skipped_out, layer, file_path, "invalid yaml (", @errorName(err));
            continue;
        };
        defer doc.deinit();

        const name_val = doc.getMapping("name") orelse {
            try skip(allocator, skipped_out, layer, file_path, "missing required field 'name'", "");
            continue;
        };
        const name = name_val.getString() orelse {
            try skip(allocator, skipped_out, layer, file_path, "field 'name' is not a string", "");
            continue;
        };
        const runtime_val = doc.getMapping("runtime") orelse {
            try skip(allocator, skipped_out, layer, file_path, "missing required field 'runtime'", "");
            continue;
        };
        const runtime = runtime_val.getString() orelse {
            try skip(allocator, skipped_out, layer, file_path, "field 'runtime' is not a string", "");
            continue;
        };
        const description = if (doc.getMapping("description")) |v| v.getString() orelse "" else "";

        try out.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .runtime = try allocator.dupe(u8, runtime),
            .layer = layer,
            .content = try allocator.dupe(u8, content),
        });
    }
}

/// Record a skipped file. `suffix` is an optional close-parenthesis payload,
/// e.g. the error name; if empty, nothing is appended after `reason`.
fn skip(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(SkippedFile),
    layer: Layer,
    path: []const u8,
    reason: []const u8,
    suffix: []const u8,
) !void {
    const full_reason = if (suffix.len > 0)
        try std.fmt.allocPrint(allocator, "{s} {s})", .{ reason, suffix })
    else
        try allocator.dupe(u8, reason);
    errdefer allocator.free(full_reason);
    try out.append(allocator, .{
        .layer = layer,
        .path = try allocator.dupe(u8, path),
        .reason = full_reason,
    });
}

test "catalog merges seed and user layers, user wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = "/tmp/tin_methods_test";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const paths = Paths{
        .tin_dir = try std.fmt.allocPrint(a, "{s}/seed", .{tmp}),
        .home_dir = try std.fmt.allocPrint(a, "{s}/home", .{tmp}),
    };

    const seed_dir = try paths.seedMethodsDir(a);
    const user_dir = try paths.methodsDir(a);
    try fs.ensureDirectoryExists(seed_dir);
    try fs.ensureDirectoryExists(user_dir);

    const seed_content =
        \\name: postgres
        \\description: seed postgres
        \\runtime: container
        \\image: postgres:16
        \\
    ;
    const seed_file = try std.fmt.allocPrint(a, "{s}/postgres.yml", .{seed_dir});
    try writeFile(a, seed_file, seed_content);

    const user_content =
        \\name: postgres
        \\description: user postgres (overrides)
        \\runtime: container
        \\image: postgres:16
        \\
    ;
    const user_file = try std.fmt.allocPrint(a, "{s}/postgres.yml", .{user_dir});
    try writeFile(a, user_file, user_content);

    const cat = try Catalog.init(a, &paths);
    try std.testing.expectEqual(@as(usize, 1), cat.items.len);
    try std.testing.expectEqualStrings("user postgres (overrides)", cat.items[0].description);
    try std.testing.expectEqual(Layer.user, cat.items[0].layer);
}

test "catalog keeps seed method when no user shadow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = "/tmp/tin_methods_test2";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const paths = Paths{
        .tin_dir = try std.fmt.allocPrint(a, "{s}/seed", .{tmp}),
        .home_dir = try std.fmt.allocPrint(a, "{s}/home", .{tmp}),
    };

    const seed_dir = try paths.seedMethodsDir(a);
    try fs.ensureDirectoryExists(seed_dir);

    const seed_content =
        \\name: redis
        \\description: seed redis
        \\runtime: container
        \\image: redis:7
        \\
    ;
    const seed_file = try std.fmt.allocPrint(a, "{s}/redis.yml", .{seed_dir});
    try writeFile(a, seed_file, seed_content);

    const cat = try Catalog.init(a, &paths);
    try std.testing.expectEqual(@as(usize, 1), cat.items.len);
    try std.testing.expectEqualStrings("redis", cat.items[0].name);
    try std.testing.expectEqual(Layer.seed, cat.items[0].layer);
    const found = cat.find("redis");
    try std.testing.expect(found != null);
}

test "catalog survives a bad file in the user layer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = "/tmp/tin_methods_test3";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const paths = Paths{
        .tin_dir = try std.fmt.allocPrint(a, "{s}/seed", .{tmp}),
        .home_dir = try std.fmt.allocPrint(a, "{s}/home", .{tmp}),
    };

    const seed_dir = try paths.seedMethodsDir(a);
    const user_dir = try paths.methodsDir(a);
    try fs.ensureDirectoryExists(seed_dir);
    try fs.ensureDirectoryExists(user_dir);

    // Good seed method.
    const seed_content =
        \\name: redis
        \\description: seed redis
        \\runtime: container
        \\image: redis:7
        \\
    ;
    try writeFile(a, try std.fmt.allocPrint(a, "{s}/redis.yml", .{seed_dir}), seed_content);

    // Good user method.
    const good_user =
        \\name: node-dev
        \\description: user node-dev
        \\runtime: process
        \\command: npm run dev
        \\
    ;
    try writeFile(a, try std.fmt.allocPrint(a, "{s}/node-dev.yml", .{user_dir}), good_user);

    // Broken user method: invalid YAML.
    try writeFile(a, try std.fmt.allocPrint(a, "{s}/broken.yml", .{user_dir}), "name: [unclosed");

    // Broken user method: parseable YAML but missing required 'runtime'.
    try writeFile(a, try std.fmt.allocPrint(a, "{s}/noruntime.yml", .{user_dir}), "name: foo");

    const cat = try Catalog.init(a, &paths);
    try std.testing.expectEqual(@as(usize, 2), cat.items.len);
    try std.testing.expect(cat.find("redis") != null);
    try std.testing.expect(cat.find("node-dev") != null);
    try std.testing.expect(cat.find("broken") == null);
    try std.testing.expect(cat.find("noruntime") == null);

    try std.testing.expectEqual(@as(usize, 2), cat.skipped.len);
    try std.testing.expectEqual(Layer.user, cat.skipped[0].layer);
}

fn writeFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    _ = allocator;
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}
