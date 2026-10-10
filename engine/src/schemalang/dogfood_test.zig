const std = @import("std");
const yaml = @import("yaml");
const Engine = @import("engine.zig").Engine;
const validate_mod = @import("core.zig");

const schemas_dir = "src/schemas";
const recipes_dir = "../environment/recipes";

fn collectFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    ext: []const u8,
) ![]const []const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var names = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) continue;
        if (!std.mem.endsWith(u8, entry.name, ext)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }

    const slice = try names.toOwnedSlice(allocator);
    std.sort.pdq([]const u8, slice, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return slice;
}

fn validateOk(allocator: std.mem.Allocator, engine: *Engine, schema: []const u8, file: []const u8) !void {
    const diagnostics = try engine.validateFile(allocator, schemas_dir, schema, file);
    if (diagnostics.len > 0) {
        std.debug.print("file {s} failed schema {s}:\n", .{ file, schema });
        for (diagnostics) |d| {
            std.debug.print("  [{s}] {s} at byte {d}\n", .{ d.code, d.message, d.span.start });
        }
        return error.DataFailedSchemaValidation;
    }
}

test "every schema validates against the meta-schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const schemas = try collectFiles(allocator, schemas_dir, ".yaml");
    try std.testing.expect(schemas.len > 0);

    for (schemas) |name| {
        const path = try std.fs.path.join(allocator, &.{ schemas_dir, name });
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);

        const diagnostics = try validate_mod.validate(
            allocator,
            &engine.meta_schema,
            (try yaml.parse(allocator, content)).value,
            null,
            &engine.sublangs,
            null,
        );
        if (diagnostics.len > 0) {
            std.debug.print("schema {s} failed meta-schema validation:\n", .{name});
            for (diagnostics) |d| {
                std.debug.print("  [{s}] {s} at byte {d}\n", .{ d.code, d.message, d.span.start });
            }
            return error.SchemaFailedMetaValidation;
        }
    }
}

test "shipped data files validate against their schemas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const recipes = try collectFiles(allocator, recipes_dir, ".yml");
    try std.testing.expect(recipes.len > 0);
    for (recipes) |name| {
        const path = try std.fs.path.join(allocator, &.{ recipes_dir, name });
        try validateOk(allocator, &engine, "recipe.yaml", path);
    }

    try validateOk(allocator, &engine, "tinrc.yaml", "../environment/tinrc.example.yml");
    try validateOk(allocator, &engine, "build_plan.yaml", "src/schemalang/fixtures/build_plan_ok.yml");
}

test "scoped references and expressions are rejected when broken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const diagnostics = try engine.validateFile(allocator, schemas_dir, "build_plan.yaml", "src/schemalang/fixtures/build_plan_bad.yml");

    var saw_ref: bool = false;
    var saw_property: bool = false;
    for (diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "undefined_reference")) saw_ref = true;
        if (std.mem.eql(u8, d.code, "undefined_property")) saw_property = true;
    }
    try std.testing.expect(saw_ref);
    try std.testing.expect(saw_property);
}
