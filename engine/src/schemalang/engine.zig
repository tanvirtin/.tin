const std = @import("std");
const yaml = @import("yaml");
const bootstrap = @import("bootstrap.zig");
const compile = @import("compile_core.zig");
const validate_mod = @import("core.zig");
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
    arena: *std.heap.ArenaAllocator,
    meta_schema: Schema,
    sublangs: SublangRegistry,

    pub fn init(allocator: std.mem.Allocator) !Engine {
        return initWithSchemasDir(allocator, "src/schemas");
    }

    pub fn initWithSchemasDir(allocator: std.mem.Allocator, schemas_dir: []const u8) !Engine {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const sa = arena.allocator();

        var sublangs = SublangRegistry.init(allocator);
        errdefer sublangs.deinit();
        try sublangs.register(@import("sublang/glob.zig").glob_plugin);
        try sublangs.register(@import("sublang/expression/mod.zig").expression_plugin);
        const bootstrap_schema = try bootstrap.get(sa);

        const meta_path = try std.fs.path.join(allocator, &.{ schemas_dir, "meta-schema.yaml" });
        defer allocator.free(meta_path);
        const meta_content = std.fs.cwd().readFileAlloc(allocator, meta_path, 1024 * 1024) catch |err| {
            output.warn("could not load meta-schema.yaml: {s}", .{@errorName(err)});
            return .{
                .allocator = allocator,
                .arena = arena,
                .meta_schema = bootstrap_schema,
                .sublangs = sublangs,
            };
        };
        defer allocator.free(meta_content);

        var meta_doc = try yaml.parse(allocator, meta_content);
        defer meta_doc.deinit();

        const diagnostics = try validate_mod.validate(sa, &bootstrap_schema, meta_doc.value, null, &sublangs, null);
        if (diagnostics.len > 0) {
            output.warn("meta-schema.yaml has validation errors against bootstrap:", .{});
            diag.printDiagnostics(diagnostics);
        }

        const meta_schema = try compile.compile(sa, &meta_doc);

        return .{
            .allocator = allocator,
            .arena = arena,
            .meta_schema = meta_schema,
            .sublangs = sublangs,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.sublangs.deinit();
        self.arena.deinit();
        self.allocator.destroy(self.arena);
    }

    pub fn schemaAllocator(self: *const Engine) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn loadSchema(self: *const Engine, source: []const u8) !Schema {
        const sa = self.arena.allocator();
        var doc = try yaml.parse(self.allocator, source);
        defer doc.deinit();

        const diagnostics = try validate_mod.validate(sa, &self.meta_schema, doc.value, null, &self.sublangs, null);
        if (diagnostics.len > 0) {
            output.err("schema has validation errors against meta-schema:", .{});
            diag.printDiagnostics(diagnostics);
            return error.InvalidSchema;
        }

        return try compile.compile(sa, &doc);
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
        var resolver = try Resolver.build(self.schemaAllocator(), &schema_doc);
        defer resolver.deinit();

        const schema = try self.loadSchema(schema_content);
        const doc_content = try std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
        defer allocator.free(doc_content);

        var doc = try yaml.parse(allocator, doc_content);
        defer doc.deinit();

        return try validate_mod.validate(allocator, &schema, doc.value, &resolver, &self.sublangs, null);
    }
};

test "schema allocations are freed when the engine is deinited" {
    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const content = try std.fs.cwd().readFileAlloc(allocator, "src/schemas/skill.yaml", 1024 * 1024);
    defer allocator.free(content);

    const schema = try engine.loadSchema(content);
    try std.testing.expect(schema.kind == .object);
}

test {
    _ = @import("core.zig");
}
