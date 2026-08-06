const std = @import("std");
const router = @import("../router.zig");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const Method = @import("../core/method.zig");

pub const meta = .{
    .name = "help",
    .description = "Show runtime command reference and discovery index",
};

const Topic = struct {
    name: []const u8,
    description: []const u8,
    children: []const []const u8,
    usage: []const u8,
};

const workspace_children = [_][]const u8{ "add", "list", "show", "validate", "up", "down", "status", "sessions" };
const methods_children = [_][]const u8{ "list", "show", "validate" };
const artifact_children = [_][]const u8{ "list", "validate", "export" };
const env_children = [_][]const u8{ "status", "sync", "set" };
const topics = [_]Topic{
    .{ .name = "workspace", .description = "Register, validate, compose, boot, and inspect workspaces", .children = &workspace_children, .usage = "tin workspace <add|list|show|validate|up|down|status|sessions> [...]" },
    .{ .name = "methods", .description = "Browse the merged run-method catalog", .children = &methods_children, .usage = "tin methods <list|show|validate> [name]" },
    .{ .name = "artifact", .description = "Validate and export skills and rules", .children = &artifact_children, .usage = "tin artifact <list|validate|export> [...]" },
    .{ .name = "env", .description = "Manage provider credentials and defaults", .children = &env_children, .usage = "tin env [status|sync|set KEY=VALUE]" },
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--index")) {
        printIndex();
        return;
    }
    if (args.len == 0) {
        printOverview();
        return;
    }
    printTopic(allocator, args);
}

pub fn printOverview() void {
    output.plain("tin — developer environment manager\n", .{});
    output.plain("Usage: tin <command> [args...]\n", .{});
    output.plain("Discover: tin help --index | tin help <topic> [detail]\n", .{});
    output.plain("\nCommands:", .{});
    inline for (router.command_entries) |entry| output.plain("  {s:<14} {s}", .{ entry.name, entry.description });
    output.plain("", .{});
}

fn printIndex() void {
    const writer = std.fs.File.stdout().deprecatedWriter();
    writer.writeAll("{\"version\":1,\"commands\":{") catch return;
    var first = true;
    inline for (router.command_entries) |entry| {
        if (!first) writer.writeAll(",") catch return;
        first = false;
        writer.print("\"{s}\":{{\"description\":\"{s}\"}}", .{ entry.name, entry.description }) catch return;
    }
    writer.writeAll("},\"topics\":[") catch return;
    for (topics, 0..) |topic, i| {
        if (i > 0) writer.writeAll(",") catch return;
        writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"children\":[", .{ topic.name, topic.description }) catch return;
        for (topic.children, 0..) |child, j| {
            if (j > 0) writer.writeAll(",") catch return;
            writer.print("\"{s}\"", .{child}) catch return;
        }
        writer.print("],\"usage\":\"{s}\"}}", .{topic.usage}) catch return;
    }
    writer.writeAll("],\"resources\":[\"workspace-schema\",\"method-catalog\",\"skill-catalog\",\"live-workspace-state\"]}\n") catch return;
}

fn printTopic(allocator: std.mem.Allocator, args: []const []const u8) void {
    const name = args[0];
    if (std.mem.eql(u8, name, "schema") or (std.mem.eql(u8, name, "workspace") and args.len > 1 and std.mem.eql(u8, args[1], "schema"))) {
        printSchema(allocator, "workspace.yaml");
        return;
    }
    if (std.mem.eql(u8, name, "method") or std.mem.eql(u8, name, "methods")) {
        if (args.len > 1 and !std.mem.eql(u8, args[1], "list") and !std.mem.eql(u8, args[1], "show")) {
            printMethod(allocator, args[1]);
            return;
        }
    }
    for (topics) |topic| {
        if (std.mem.eql(u8, topic.name, name)) {
            output.plain("{s}\n", .{topic.description});
            output.plain("Usage: {s}", .{topic.usage});
            output.plain("\nSubcommands:", .{});
            for (topic.children) |child| output.plain("  {s}", .{child});
            if (args.len > 1) printDetail(topic.name, args[1]);
            return;
        }
    }
    output.err("unknown help topic: {s}", .{name});
    output.plain("Run 'tin help --index' to list discoverable topics.", .{});
}

fn printDetail(topic: []const u8, detail: []const u8) void {
    if (std.mem.eql(u8, topic, "workspace")) {
        if (std.mem.eql(u8, detail, "validate")) output.plain("Validate before boot: tin workspace validate <name>", .{})
        else if (std.mem.eql(u8, detail, "up")) output.plain("Boot validated components in dependency order: tin workspace up <name>", .{});
    } else if (std.mem.eql(u8, topic, "artifact") and std.mem.eql(u8, detail, "export")) {
        output.plain("Export Agent Skills: tin artifact export <pi|opencode|all>", .{});
    }
}

fn printSchema(allocator: std.mem.Allocator, filename: []const u8) void {
    const paths = Paths.init(allocator) catch { output.err("could not resolve environment paths", .{}); return; };
    const path = std.fmt.allocPrint(allocator, "{s}/src/schemas/{s}", .{ paths.tin_dir, filename }) catch return;
    defer allocator.free(path);
    const content = fs.readFileAlloc(allocator, path) catch { output.err("schema not found: {s}", .{filename}); return; };
    output.plain("{s}", .{content});
}

fn printMethod(allocator: std.mem.Allocator, name: []const u8) void {
    const paths = Paths.init(allocator) catch { output.err("could not resolve environment paths", .{}); return; };
    var catalog = Method.Catalog.init(allocator, &paths) catch { output.err("failed to load method catalog", .{}); return; };
    defer catalog.deinit();
    const method = catalog.find(name) orelse { output.err("method not found: {s}", .{name}); return; };
    output.plain("{s}\n", .{method.description});
    output.plain("name: {s}\nruntime: {s}\n\n{s}", .{ method.id, method.runtime, method.content });
}
