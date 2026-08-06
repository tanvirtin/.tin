const std = @import("std");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");
const compile = @import("../spec/compile.zig");
const validate_mod = @import("../spec/validate.zig");
const Environment = @import("../core/environment.zig");

const Engine = @import("../spec/engine.zig").Engine;

pub const meta = .{
    .name = "validate",
    .description = "Validate a YAML file against a schema",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 2) {
        output.err("usage: tin validate <schema_path> <file_path>", .{});
        return;
    }

    const schema_path = args[0];
    const file_path = args[1];

    var engine = Engine.init(allocator) catch {
        output.err("could not initialize schema engine", .{});
        return;
    };
    defer engine.deinit();

    const schema_content = std.fs.cwd().readFileAlloc(allocator, schema_path, 1024 * 1024) catch {
        output.err("could not read schema file: {s}", .{schema_path});
        return;
    };

    var schema_doc = yaml.parse(allocator, schema_content) catch {
        output.err("could not parse schema YAML", .{});
        return;
    };
    defer schema_doc.deinit();

    const schema = engine.loadSchema(schema_content) catch {
        output.err("could not compile schema: {s}", .{schema_path});
        return;
    };

    var resolver = validate_mod.Resolver.build(allocator, &schema_doc) catch {
        output.err("could not build schema resolver", .{});
        return;
    };
    defer resolver.deinit();

    const doc_content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch {
        output.err("could not read document file: {s}", .{file_path});
        return;
    };

    var doc = yaml.parse(allocator, doc_content) catch {
        output.err("could not parse document YAML", .{});
        return;
    };
    defer doc.deinit();

    const diagnostics = validate_mod.validate(allocator, &schema, doc.value, &resolver, &engine.sublangs, null) catch {
        output.err("internal validation error", .{});
        return;
    };

    if (diagnostics.len == 0) {
        output.success("Validation successful: {s} matches {s}", .{ file_path, schema_path });
    } else {
        output.err("Validation failed for {s}:", .{file_path});
        for (diagnostics) |d| {
            output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
        }
    }
}
