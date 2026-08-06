const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const Method = @import("../core/method.zig");
const Engine = @import("../spec/engine.zig").Engine;

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
    } else if (std.mem.eql(u8, subcommand, "validate")) {
        validateAll(allocator, &paths);
    } else {
        output.err("unknown methods subcommand: {s}", .{subcommand});
        printUsage();
    }
}

fn printUsage() void {
    output.plain("usage: tin methods <list|show|validate> [name]", .{});
    output.plain("", .{});
    output.plain("  list                  List all methods (seed + user, merged)", .{});
    output.plain("  show <name>           Show one method's full template", .{});
    output.plain("  validate              Validate all methods against schemas/method.yaml", .{});
}

fn validateAll(allocator: std.mem.Allocator, paths: *const Paths) void {
    const schemas_dir = std.fs.path.join(allocator, &.{ paths.tin_dir, "src", "schemas" }) catch {
        output.err("could not resolve schemas directory", .{});
        return;
    };
    defer allocator.free(schemas_dir);

    var engine = Engine.initWithSchemasDir(allocator, schemas_dir) catch {
        output.err("could not initialize schema engine", .{});
        return;
    };
    defer engine.deinit();

    const seed_dir = paths.seedMethodsDir(allocator) catch {
        output.err("could not resolve seed methods dir", .{});
        return;
    };
    defer allocator.free(seed_dir);
    const user_dir = paths.methodsDir(allocator) catch {
        output.err("could not resolve user methods dir", .{});
        return;
    };
    defer allocator.free(user_dir);

    var failed: usize = 0;
    var checked: usize = 0;
    validateDir(allocator, &engine, schemas_dir, seed_dir, &checked, &failed);
    validateDir(allocator, &engine, schemas_dir, user_dir, &checked, &failed);

    if (failed > 0) {
        output.err("{d}/{d} method files failed validation", .{ failed, checked });
        std.process.exit(1);
    }
    output.success("{d} method file(s) validated against schemas/method.yaml", .{checked});
}

fn validateDir(
    allocator: std.mem.Allocator,
    engine: *const Engine,
    schemas_dir: []const u8,
    dir: []const u8,
    checked: *usize,
    failed: *usize,
) void {
    if (!fs.pathExists(dir)) return;
    var dir_handle = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch return;
    defer dir_handle.close();

    var iter = dir_handle.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;

        const file_path = std.fs.path.join(allocator, &.{ dir, entry.name }) catch continue;
        defer allocator.free(file_path);

        checked.* += 1;
        const diagnostics = engine.validateFile(allocator, schemas_dir, "method.yaml", file_path) catch {
            output.err("  {s}: schema error", .{file_path});
            failed.* += 1;
            continue;
        };
        if (diagnostics.len > 0) {
            output.err("  {s} ({d} error(s))", .{ file_path, diagnostics.len });
            for (diagnostics) |d| {
                output.plain("    [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
            }
            failed.* += 1;
        }
    }
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
