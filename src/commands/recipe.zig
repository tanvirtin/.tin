const std = @import("std");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Recipe = @import("../core/recipe.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "recipe",
    .description = "Run a named recipe (scans recipes/ directory)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const recipes_dir = env.recipesDir(allocator) catch {
        output.err("could not resolve recipes directory", .{});
        return;
    };

    if (args.len == 0) {
        listRecipes(allocator, recipes_dir);
        return;
    }

    const name = args[0];
    const path = std.fmt.allocPrint(allocator, "{s}/{s}.yml", .{ recipes_dir, name }) catch {
        output.err("allocation failed", .{});
        return;
    };

    const content = fs.readFileAlloc(allocator, path) catch {
        output.err("recipe not found: {s}", .{name});
        output.plain("Run 'tin recipe' to see available recipes.", .{});
        return;
    };

    const recipe = Recipe.parse(allocator, content) catch {
        output.err("failed to parse recipe: {s}", .{name});
        return;
    };

    output.info("running recipe: {s}", .{recipe.name});
    if (recipe.execute(allocator)) {
        output.success("recipe complete: {s}", .{recipe.name});
    } else {
        output.err("recipe failed: {s}", .{recipe.name});
    }
}

fn listRecipes(allocator: std.mem.Allocator, recipes_dir: []const u8) void {
    var dir = std.fs.openDirAbsolute(recipes_dir, .{ .iterate = true }) catch {
        output.info("no recipes directory found", .{});
        return;
    };
    defer dir.close();

    output.info("available recipes:", .{});

    var found: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yml")) continue;

        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ recipes_dir, entry.name }) catch continue;
        const content = fs.readFileAlloc(allocator, path) catch continue;
        const recipe = Recipe.parse(allocator, content) catch continue;

        const desc = recipe.description orelse "";
        output.plain("  {s:<12} {s}", .{ recipe.name, desc });
        found += 1;
    }

    if (found == 0) {
        output.plain("  (none)", .{});
    }
}
