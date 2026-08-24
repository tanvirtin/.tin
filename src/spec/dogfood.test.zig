const std = @import("std");
const yaml = @import("yaml");
const Engine = @import("engine.zig").Engine;

/// Dogfood the schema DSL on tin's own YAML. Every schema must validate
/// against the meta-schema, and every shipped data file must validate against
/// its schema. This is the enforcement point for full DSL adoption.
const schemas_dir = "src/schemas";

const SchemaCases = struct {
    schema: []const u8,
    files: []const []const u8,
};

const cases = [_]SchemaCases{
    .{ .schema = "method.yaml", .files = &.{
        "methods/cargo-run.yml",
        "methods/node-dev.yml",
        "methods/postgres.yml",
        "methods/redis.yml",
        "methods/vite-dev.yml",
    } },
    .{ .schema = "recipe.yaml", .files = &.{
        "recipes/curl.yml",
        "recipes/deno.yml",
        "recipes/gh.yml",
        "recipes/git.yml",
        "recipes/neovim.yml",
        "recipes/nvm.yml",
        "recipes/opencode.yml",
        "recipes/pi.yml",
        "recipes/rbenv.yml",
        "recipes/ripgrep.yml",
        "recipes/rust.yml",
        "recipes/starship.yml",
        "recipes/tmux.yml",
        "recipes/zsh-autosuggestions.yml",
        "recipes/zsh.yml",
    } },
    .{ .schema = "tinrc.yaml", .files = &.{"tinrc.example.yml"} },
    .{ .schema = "workspace.yaml", .files = &.{} },
    .{ .schema = "github_workflow.yaml", .files = &.{
        ".github/workflows/nightly.yml",
        ".github/workflows/release.yml",
    } },
};

test "every schema validates against the meta-schema" {
    arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const schemas = [_][]const u8{
        "meta-schema.yaml",
        "method.yaml",
        "recipe.yaml",
        "tinrc.yaml",
        "rule.yaml",
        "skill.yaml",
        "workspace.yaml",
        "github_workflow.yaml",
    };

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    for (schemas) |name| {
        const path = try std.fs.path.join(allocator, &.{ schemas_dir, name });
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);

        const diagnostics = try @import("../spec/validate.zig").validate(
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
    arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    var checked: usize = 0;
    for (cases) |c| {
        for (c.files) |file| {
            const diagnostics = try engine.validateFile(allocator, schemas_dir, c.schema, file);
            if (diagnostics.len > 0) {
                std.debug.print("file {s} failed schema {s}:\n", .{ file, c.schema });
                for (diagnostics) |d| {
                    std.debug.print("  [{s}] {s} at byte {d}\n", .{ d.code, d.message, d.span.start });
                }
                return error.DataFailedSchemaValidation;
            }
            checked += 1;
        }
    }
}

test "bad method is rejected by the method schema" {
    arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const tmp = "/tmp/tin_bad_method.yml";
    std.fs.cwd().deleteFile(tmp) catch {};
    {
        const f = try std.fs.cwd().createFile(tmp, .{});
        defer f.close();
        try f.writeAll("name: broken\nruntime: process\ncomand: typo\n");
    }
    defer std.fs.cwd().deleteFile(tmp) catch {};

    const diagnostics = try engine.validateFile(allocator, schemas_dir, "method.yaml", tmp);
    if (diagnostics.len == 0) return error.BadMethodNotRejected;
}

var arena_state: std.heap.ArenaAllocator = undefined;
const allocator = arena_state.allocator();
