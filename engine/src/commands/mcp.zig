const std = @import("std");
const Artifact = @import("../core/artifact.zig");
const mcp = @import("../core/mcp.zig");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "mcp",
    .description = "Project declared MCP servers into configured runtimes",
};

const Mode = enum { diff, apply };

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const environment = Environment.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    if (args.len == 0) {
        showHelp();
        return 0;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "list")) {
        return list(allocator, &environment);
    }
    if (std.mem.eql(u8, sub, "diff")) {
        return project(allocator, &environment, .diff, args[1..]);
    }
    if (std.mem.eql(u8, sub, "apply")) {
        return project(allocator, &environment, .apply, args[1..]);
    }

    output.err("unknown mcp command: {s}", .{sub});
    showHelp();
    return 1;
}

fn showHelp() void {
    output.info("mcp — Project MCP server artifacts into runtime configs", .{});
    output.plain("", .{});
    output.plain("  tin mcp list              List declared servers and configured runtimes", .{});
    output.plain("  tin mcp diff [runtime]    Show projected config without writing", .{});
    output.plain("  tin mcp apply [runtime]   Merge servers into runtime configs (backs up)", .{});
    output.plain("", .{});
    output.plain("  Servers live in the artifacts/mcp dir, dialects in artifacts/dialects,", .{});
    output.plain("  and targets in the runtimes: section of tinrc.yml.", .{});
}

const Loaded = struct {
    artifact: Artifact,
    servers: []mcp.Server,
    dialects: []mcp.Dialect,
    runtimes: []const Environment.RecipeManager.Runtime,
};

fn load(allocator: std.mem.Allocator, environment: *const Environment) !Loaded {
    const artifacts_dir = try environment.paths.artifactsDir(allocator);
    var artifact = try Artifact.init(allocator, environment.tin_dir, artifacts_dir);
    const servers = try artifact.discoverMcp(allocator);
    const dialects = try artifact.discoverDialects(allocator);
    const runtimes = try Environment.RecipeManager.getRuntimes(allocator, environment.config, environment.paths);
    return .{ .artifact = artifact, .servers = servers, .dialects = dialects, .runtimes = runtimes };
}

fn findDialect(dialects: []const mcp.Dialect, id: []const u8) ?mcp.Dialect {
    for (dialects) |dialect| {
        if (std.mem.eql(u8, dialect.id, id)) return dialect;
    }
    return null;
}

fn list(allocator: std.mem.Allocator, environment: *const Environment) u8 {
    var loaded = load(allocator, environment) catch {
        output.err("could not load MCP artifacts from {s}", .{environment.paths.artifactsDir(allocator) catch "artifacts"});
        return 1;
    };
    defer loaded.artifact.deinit();

    output.info("MCP servers ({d}):", .{loaded.servers.len});
    if (loaded.servers.len == 0) {
        output.plain("  (none — add YAML under {s}/mcp)", .{loaded.artifact.artifacts_dir});
    }
    for (loaded.servers) |server| {
        output.plain("  {s:<20} {s}", .{ server.id, @tagName(server.type) });
    }

    output.plain("", .{});
    output.info("Runtimes ({d}):", .{loaded.runtimes.len});
    if (loaded.runtimes.len == 0) {
        output.plain("  (none — add `runtimes:` to tinrc.yml)", .{});
    }
    for (loaded.runtimes) |runtime| {
        const dialect = findDialect(loaded.dialects, runtime.dialect);
        const exists = if (fs.pathExists(runtime.mcp_path)) "present" else "absent";
        if (dialect) |d| {
            output.plain("  {s:<10} {s:<7} {s}  [{s}]", .{ runtime.name, exists, runtime.mcp_path, @tagName(d.format) });
        } else {
            output.warn("  {s:<10} {s:<7} {s}  [unknown dialect: {s}]", .{ runtime.name, exists, runtime.mcp_path, runtime.dialect });
        }
    }
    return 0;
}

fn project(
    allocator: std.mem.Allocator,
    environment: *const Environment,
    mode: Mode,
    targets: []const []const u8,
) u8 {
    var loaded = load(allocator, environment) catch {
        output.err("could not load MCP artifacts", .{});
        return 1;
    };
    defer loaded.artifact.deinit();

    if (loaded.runtimes.len == 0) {
        output.err("no runtimes configured (add `runtimes:` to tinrc.yml)", .{});
        return 1;
    }

    if (loaded.servers.len == 0) {
        output.warn("no MCP servers declared — nothing to project", .{});
        return 0;
    }

    var failures: usize = 0;
    var considered: usize = 0;

    for (loaded.runtimes) |runtime| {
        if (!selected(runtime.name, targets)) continue;
        considered += 1;

        const dialect = findDialect(loaded.dialects, runtime.dialect) orelse {
            output.err("  {s}: unknown dialect '{s}'", .{ runtime.name, runtime.dialect });
            failures += 1;
            continue;
        };

        const entries = buildEntries(allocator, loaded.servers, dialect) catch {
            output.err("  {s}: could not render servers", .{runtime.name});
            failures += 1;
            continue;
        };

        const existing = readExisting(allocator, runtime.mcp_path);

        if (mode == .diff) {
            const preview = mcp.renderPreview(allocator, dialect, entries) catch "";
            const changed = existing == null or !std.mem.eql(u8, existing.?, mergedFor(allocator, existing, dialect, entries) catch "");
            if (changed) {
                output.warn("  {s}: would update {s}", .{ runtime.name, runtime.mcp_path });
                output.plain("{s}", .{preview});
            } else {
                output.success("  {s}: up to date ({s})", .{ runtime.name, runtime.mcp_path });
            }
            continue;
        }

        const merged = mergedFor(allocator, existing, dialect, entries) catch {
            output.err("  {s}: could not parse existing config at {s} (refusing to overwrite)", .{ runtime.name, runtime.mcp_path });
            failures += 1;
            continue;
        };

        if (existing) |text| {
            if (std.mem.eql(u8, text, merged)) {
                output.success("  {s}: up to date ({s})", .{ runtime.name, runtime.mcp_path });
                continue;
            }
        }

        writeResult(runtime, existing, merged) catch {
            output.err("  {s}: failed to write {s}", .{ runtime.name, runtime.mcp_path });
            failures += 1;
            continue;
        };
        if (existing == null) {
            output.success("  {s}: wrote {s}", .{ runtime.name, runtime.mcp_path });
        } else {
            output.success("  {s}: updated {s} (backup: {s}.tin.bak)", .{ runtime.name, runtime.mcp_path, runtime.mcp_path });
        }
    }

    if (considered == 0) {
        output.err("no matching runtime for: {s}", .{targets[0]});
        return 1;
    }

    if (failures > 0) {
        output.err("{d} runtime(s) failed", .{failures});
        return 1;
    }
    return 0;
}

fn mergedFor(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    dialect: mcp.Dialect,
    entries: []const mcp.Entry,
) ![]const u8 {
    return mcp.merge(allocator, existing, dialect, entries);
}

fn buildEntries(allocator: std.mem.Allocator, servers: []const mcp.Server, dialect: mcp.Dialect) ![]const mcp.Entry {
    var entries: std.ArrayListUnmanaged(mcp.Entry) = .{};
    for (servers) |server| {
        try entries.append(allocator, try mcp.buildEntry(allocator, server, dialect));
    }
    return entries.toOwnedSlice(allocator);
}

fn selected(name: []const u8, targets: []const []const u8) bool {
    if (targets.len == 0) return true;
    for (targets) |target| {
        if (std.mem.eql(u8, target, name)) return true;
    }
    return false;
}

fn readExisting(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (!fs.pathExists(path)) return null;
    return fs.readFileAlloc(allocator, path) catch null;
}

fn writeResult(runtime: Environment.RecipeManager.Runtime, existing: ?[]const u8, merged: []const u8) !void {
    if (existing) |text| {
        const backup_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}.tin.bak", .{runtime.mcp_path});
        defer std.heap.page_allocator.free(backup_path);
        try fs.ensureParentDirExists(backup_path);
        try fs.writeFile(backup_path, text);
    }
    try fs.ensureParentDirExists(runtime.mcp_path);
    try fs.writeFile(runtime.mcp_path, merged);
}
