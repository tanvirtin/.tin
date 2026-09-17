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
const diag = @import("diagnostic.zig");

pub const Engine = struct {
    allocator: std.mem.Allocator,
    meta_schema: Schema,
    sublangs: SublangRegistry,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return initWithSchemasDir(allocator, "src/schemas");
    }

    pub fn initWithSchemasDir(allocator: std.mem.Allocator, schemas_dir: []const u8) !Engine {
        var sublangs = SublangRegistry.init(allocator);
        try sublangs.register(@import("sublang/glob.zig").glob_plugin);
        try sublangs.register(@import("sublang/expression/mod.zig").expression_plugin);
        const bootstrap_schema = try bootstrap.get(allocator);

        const meta_path = try std.fs.path.join(allocator, &.{ schemas_dir, "meta-schema.yaml" });
        defer allocator.free(meta_path);
        const meta_content = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024 * 1024) catch |err| {
            output.warn("could not load meta-schema.yaml: {s}", .{@errorName(err)});
            return .{
                .allocator = allocator,
                .meta_schema = bootstrap_schema,
                .sublangs = sublangs,
            };
        };

        var meta_doc = try yaml.parse(allocator, meta_content);
        defer meta_doc.deinit();

        const diagnostics = try validate_mod.validate(allocator, &bootstrap_schema, meta_doc.value, null, &sublangs, null);
        if (diagnostics.len > 0) {
            output.warn("meta-schema.yaml has validation errors against bootstrap:", .{});
            diag.printDiagnostics(diagnostics);
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
            diag.printDiagnostics(diagnostics);
            return error.InvalidSchema;
        }

        return try compile.compile(self.allocator, &doc);
    }

    pub fn validateFile(
        self: *const Engine,
        allocator: std.mem.Allocator,
        schemas_dir: []const u8,
        schema_name: []const u8,
        file_path: []const u8,
    ) ![]const Diagnostic {
        const schema_path = try std.fs.path.join(allocator, &.{ schemas_dir, schema_name });
        defer allocator.free(schema_path);
        const schema_content = try std.fs.cwd().readFileAlloc(allocator, schema_path, 1024 * 1024);
        defer allocator.free(schema_content);

        var schema_doc = try yaml.parse(allocator, schema_content);
        defer schema_doc.deinit();
        var resolver = try Resolver.build(allocator, &schema_doc);
        defer resolver.deinit();

        const schema = try self.loadSchema(schema_content);
        const doc_content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
        defer allocator.free(doc_content);

        var doc = try yaml.parse(allocator, doc_content);
        defer doc.deinit();

        return try validate_mod.validate(allocator, &schema, doc.value, &resolver, &self.sublangs, null);
    }
};

test {
    _ = @import("validate.zig");
}
