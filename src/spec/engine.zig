const std = @import("std");
const yaml = @import("yaml");
const bootstrap = @import("bootstrap.zig");
const compile = @import("compile.zig");
const validate_mod = @import("validate.zig");
const ir = @import("ir.zig");
const sublang = @import("sublang.zig");

const Schema = ir.Schema;
const Resolver = validate_mod.Resolver;
const SublangRegistry = sublang.SublangRegistry;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const output = @import("../lib/output.zig");

pub const Engine = struct {
    allocator: std.mem.Allocator,
    meta_schema: Schema,
    sublangs: SublangRegistry,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        var sublangs = SublangRegistry.init(allocator);
        try sublangs.register(@import("sublang/glob.zig").glob_plugin);
        try sublangs.register(@import("sublang/expression/mod.zig").expression_plugin);
        const bootstrap_schema = try bootstrap.get(allocator);

        // Load meta-schema.yaml
        const meta_content = std.fs.cwd().readFileAlloc(allocator, "src/schemas/meta-schema.yaml", 1024 * 1024) catch |err| {
            output.warn("could not load meta-schema.yaml: {s}", .{@errorName(err)});
            return .{
                .allocator = allocator,
                .meta_schema = bootstrap_schema,
                .sublangs = sublangs,
            };
        };

        var meta_doc = try yaml.parse(allocator, meta_content);
        defer meta_doc.deinit();

        // Validate meta-schema.yaml against bootstrap
        const diagnostics = try validate_mod.validate(allocator, &bootstrap_schema, meta_doc.value, null, &sublangs, null);
        if (diagnostics.len > 0) {
            output.warn("meta-schema.yaml has validation errors against bootstrap:", .{});
            for (diagnostics) |d| {
                output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
            }
        }

        const meta_schema = try compile.compile(allocator, &meta_doc);

        return .{
            .allocator = allocator,
            .meta_schema = meta_schema,
            .sublangs = sublangs,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.sublangs.deinit();
    }

    pub fn loadSchema(self: *const Engine, source: []const u8) !Schema {
        var doc = try yaml.parse(self.allocator, source);
        defer doc.deinit();

        const diagnostics = try validate_mod.validate(self.allocator, &self.meta_schema, doc.value, null, &self.sublangs, null);
        if (diagnostics.len > 0) {
            output.err("schema has validation errors against meta-schema:", .{});
            for (diagnostics) |d| {
                output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
            }
            return error.InvalidSchema;
        }

        return try compile.compile(self.allocator, &doc);
    }
};

test {
    _ = @import("validate.zig");
}
