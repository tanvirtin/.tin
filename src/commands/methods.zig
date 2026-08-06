const std = @import("std");
const output = @import("../lib/output.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const Method = @import("../core/method.zig");

pub const meta = .{
    .name = "methods",
    .description = "Browse the run-method catalog (seed + user, merged)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        printUsage();
        return;
    }

    const subcommand = args[0];
    const rest = args[1..];

    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return;
    };

    if (std.mem.eql(u8, subcommand, "list")) {
        list(allocator, &paths);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        show(allocator, &paths, rest);
    } else {
        output.err("unknown methods subcommand: {s}", .{subcommand});
        printUsage();
    }
}

fn printUsage() void {
    output.plain("usage: tin methods <list|show> [name]", .{});
    output.plain("", .{});
    output.plain("  list                  List all methods (seed + user, merged)", .{});
    output.plain("  show <name>           Show one method's full template", .{});
}

fn list(allocator: std.mem.Allocator, paths: *const Paths) void {
    const catalog = Method.Catalog.init(allocator, paths) catch {
        output.err("failed to load method catalog", .{});
        return;
    };

    output.info("method catalog ({d}):", .{catalog.items.len});
    for (catalog.items) |m| {
        const layer = switch (m.layer) {
            .seed => "seed",
            .user => "user",
        };
        const runtime_pad = padTo(allocator, m.runtime, 10);
        defer allocator.free(runtime_pad);
        output.plain("  {s:<24} {s} [{s}] {s}", .{ m.id, runtime_pad, layer, m.description });
    }
    if (catalog.items.len == 0) output.plain("  (none — add methods to ~/.config/tin/methods/)", .{});
    printSkipped(&catalog, "method catalog");
}

/// Warn about catalog files that failed to load, so a broken user method is
/// visible instead of silently missing.
fn printSkipped(
    catalog: *const Method.Catalog,
    load_context: []const u8,
) void {
    for (catalog.skipped) |s| {
        const layer = switch (s.layer) {
            .seed => "seed",
            .user => "user",
        };
        output.warn("  skipped {s} file: {s} — {s}", .{ layer, s.path, s.reason });
    }
    if (catalog.skipped.len > 0) {
        output.warn("  {d} file(s) failed to load in {s}; the rest are usable", .{ catalog.skipped.len, load_context });
    }
}

fn padTo(allocator: std.mem.Allocator, s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return allocator.dupe(u8, s) catch s;
    return std.fmt.allocPrint(allocator, "{s: <[1]}", .{ s, width - s.len }) catch allocator.dupe(u8, s) catch s;
}

fn show(allocator: std.mem.Allocator, paths: *const Paths, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin methods show <name>", .{});
        return;
    }
    const name = args[0];

    var catalog = Method.Catalog.init(allocator, paths) catch {
        output.err("failed to load method catalog", .{});
        return;
    };

    const method = catalog.find(name) orelse {
        output.err("method not found: {s}", .{name});
        catalog.deinit();
        return;
    };

    const layer = switch (method.layer) {
        .seed => "seed",
        .user => "user",
    };
    output.info("method: {s} [{s}]", .{ method.id, layer });
    output.plain("", .{});
    output.plain("{s}", .{method.content});
    printSkipped(&catalog, "method catalog");
    catalog.deinit();
}
