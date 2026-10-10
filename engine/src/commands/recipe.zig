const std = @import("std");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Recipe = @import("../core/recipe.zig");
const Environment = @import("../core/environment.zig");
const Engine = @import("../spec/engine.zig").Engine;
const diag = @import("../spec/diagnostic.zig");

pub const meta = .{
    .name = "recipe",
    .description = "Run a named recipe (scans environment/recipes/ directory)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return 1;
    };

    var search = env.paths.recipeSearch(allocator) catch {
        output.err("could not resolve recipes directories", .{});
        return 1;
    };
    defer search.deinit(allocator);

    if (args.len == 0) {
        listRecipes(allocator, search);
        return 0;
    }

    const name = args[0];
    const found = search.resolve(allocator, name) catch {
        output.err("allocation failed", .{});
        return 1;
    } orelse {
        output.err("recipe not found: {s}", .{name});
        output.plain("Run 'tin recipe' to see available recipes.", .{});
        return 1;
    };
    defer allocator.free(found.path);

    const content = fs.readFileAlloc(allocator, found.path) catch {
        output.err("could not read recipe: {s}", .{name});
        return 1;
    };
    defer allocator.free(content);

    if (validateRecipe(allocator, &env.paths, found.path)) return 1;

    const recipe = Recipe.parse(allocator, content) catch {
        output.err("failed to parse recipe: {s}", .{name});
        return 1;
    };

    output.info("running recipe: {s}", .{recipe.name});
    recipe.execute(allocator) catch {
        output.err("recipe failed: {s}", .{recipe.name});
        return 1;
    };
    output.success("recipe complete: {s}", .{recipe.name});
    return 0;
}

fn validateRecipe(allocator: std.mem.Allocator, paths: anytype, recipe_path: []const u8) bool {
    const schemas_dir = paths.schemasDir(allocator) catch {
        output.err("could not resolve schemas directory", .{});
        return true;
    };
    defer allocator.free(schemas_dir);

    var engine = Engine.initWithSchemasDir(allocator, schemas_dir) catch {
        output.err("could not initialize schema engine", .{});
        return true;
    };
    defer engine.deinit();

    const diagnostics = engine.validateFile(allocator, schemas_dir, "recipe.yaml", recipe_path) catch {
        output.err("internal validation error", .{});
        return true;
    };

    if (diagnostics.len > 0) {
        output.err("recipe failed validation: {s}", .{recipe_path});
        diag.printDiagnostics(diagnostics);
        return true;
    }
    return false;
}

fn listRecipes(allocator: std.mem.Allocator, search: anytype) void {
    output.info("available recipes:", .{});

    var total: usize = 0;
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    for (search.layers[0..search.count]) |layer| {
        var dir = std.fs.openDirAbsolute(layer.dir, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;

            const name = allocator.dupe(u8, std.mem.trimEnd(u8, entry.name, ".yml")) catch continue;
            if (seen.contains(name)) {
                allocator.free(name);
                continue;
            }

            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ layer.dir, entry.name }) catch {
                allocator.free(name);
                continue;
            };
            const content = fs.readFileAlloc(allocator, path) catch {
                allocator.free(path);
                allocator.free(name);
                continue;
            };
            defer allocator.free(content);
            const recipe = Recipe.parse(allocator, content) catch continue;

            seen.put(name, {}) catch continue;
            output.plain("  {s:<12} [{s}] {s}", .{ recipe.name, layer.origin, recipe.description orelse "" });
            total += 1;
        }
    }

    if (total == 0) {
        output.plain("  (none)", .{});
    }
}
