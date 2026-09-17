const std = @import("std");
const yaml = @import("yaml");
const Engine = @import("engine.zig").Engine;

const schemas_dir = "src/schemas";

const SchemaCases = struct {
    schema: []const u8,
    files: []const []const u8,
};

const cases = [_]SchemaCases{
    .{ .schema = "recipe.yaml", .files = &.{
        "recipes/curl.yml",
        "recipes/deno.yml",
        "recipes/gh.yml",
        "recipes/git.yml",
        "recipes/neovim.yml",
        "recipes/nvm.yml",
        "recipes/opencode.yml",
        "recipes/rbenv.yml",
        "recipes/ripgrep.yml",
        "recipes/rust.yml",
        "recipes/starship.yml",
        "recipes/tmux.yml",
        "recipes/zsh-autosuggestions.yml",
        "recipes/zsh.yml",
    } },
    .{ .schema = "tinrc.yaml", .files = &.{"tinrc.example.yml"} },
    .{ .schema = "build_plan.yaml", .files = &.{"src/spec/fixtures/build_plan_ok.yml"} },
};

test "every schema validates against the meta-schema" {
    arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const schemas = [_][]const u8{
        "meta-schema.yaml",
        "recipe.yaml",
        "tinrc.yaml",
        "rule.yaml",
        "skill.yaml",
        "build_plan.yaml",
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

var arena_state: std.heap.ArenaAllocator = undefined;
const allocator = arena_state.allocator();

test "scoped references and expressions are rejected when broken" {
    arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const diagnostics = try engine.validateFile(allocator, schemas_dir, "build_plan.yaml", "src/spec/fixtures/build_plan_bad.yml");

    var saw_ref: bool = false;
    var saw_property: bool = false;
    for (diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "undefined_reference")) saw_ref = true;
        if (std.mem.eql(u8, d.code, "undefined_property")) saw_property = true;
    }
    try std.testing.expect(saw_ref);
    try std.testing.expect(saw_property);
}
