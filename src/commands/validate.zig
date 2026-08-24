const std = @import("std");
const yaml = @import("yaml");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const validate_mod = @import("../spec/validate.zig");
const Environment = @import("../core/environment.zig");

const Engine = @import("../spec/engine.zig").Engine;
const schema_cmd = @import("schema.zig");

pub const meta = .{
    .name = "validate",
    .description = "Validate a YAML file against a schema (path or built-in name)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 2) {
        output.err("usage: tin validate <schema_path|builtin_name> <file_path>", .{});
        std.process.exit(2);
    }

    const schema_ref = args[0];
    const file_path = args[1];

    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        std.process.exit(2);
    };
    const schemas_dir = std.fs.path.join(allocator, &.{ env.paths.tin_dir, "src", "schemas" }) catch {
        output.err("could not resolve schemas directory", .{});
        std.process.exit(2);
    };
    defer allocator.free(schemas_dir);

    const resolved_schema_ref = schema_cmd.resolveSchemaRef(allocator, schemas_dir, schema_ref) orelse {
        output.err("unknown schema: {s} (run 'tin schema list' for built-ins)", .{schema_ref});
        std.process.exit(2);
    };

    const schema_path_abs = std.fs.cwd().realpathAlloc(allocator, resolved_schema_ref) catch {
        output.err("could not resolve schema file: {s}", .{resolved_schema_ref});
        std.process.exit(2);
    };
    defer allocator.free(schema_path_abs);
    const file_path_abs = std.fs.cwd().realpathAlloc(allocator, file_path) catch {
        output.err("could not resolve document file: {s}", .{file_path});
        std.process.exit(2);
    };
    defer allocator.free(file_path_abs);

    var engine = Engine.initWithSchemasDir(allocator, schemas_dir) catch {
        output.err("could not initialize schema engine", .{});
        std.process.exit(2);
    };
    defer engine.deinit();

    const schema_content = fs.readFileAlloc(allocator, schema_path_abs) catch {
        output.err("could not read schema file: {s}", .{resolved_schema_ref});
        std.process.exit(2);
    };

    var schema_doc = yaml.parse(allocator, schema_content) catch {
        output.err("could not parse schema YAML", .{});
        std.process.exit(2);
    };
    defer schema_doc.deinit();

    const schema = engine.loadSchema(schema_content) catch {
        output.err("could not compile schema: {s}", .{resolved_schema_ref});
        std.process.exit(2);
    };

    var resolver = validate_mod.Resolver.build(allocator, &schema_doc) catch {
        output.err("could not build schema resolver", .{});
        std.process.exit(2);
    };
    defer resolver.deinit();

    const doc_content = fs.readFileAlloc(allocator, file_path_abs) catch {
        output.err("could not read document file: {s}", .{file_path});
        std.process.exit(2);
    };

    var doc = yaml.parse(allocator, doc_content) catch {
        output.err("could not parse document YAML", .{});
        std.process.exit(2);
    };
    defer doc.deinit();

    const diagnostics = validate_mod.validate(allocator, &schema, doc.value, &resolver, &engine.sublangs, null) catch {
        output.err("internal validation error", .{});
        std.process.exit(2);
    };

    if (diagnostics.len == 0) {
        output.success("Validation successful: {s} matches {s}", .{ file_path, resolved_schema_ref });
        return;
    }

    output.err("Validation failed for {s}:", .{file_path});
    for (diagnostics) |d| {
        output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
    }
    std.process.exit(1);
}
