const std = @import("std");
const yaml = @import("yaml");
const Schema = @import("ir.zig").Schema;
const Primitive = @import("ir.zig").Primitive;
const ConstValue = @import("ir.zig").ConstValue;
const ObjectSchema = @import("ir.zig").ObjectSchema;
const SeqSchema = @import("ir.zig").SeqSchema;
const MapSchema = @import("ir.zig").MapSchema;
const DiscriminatedUnion = @import("ir.zig").DiscriminatedUnion;
const SwitchSchema = @import("ir.zig").SwitchSchema;
const SublangSchema = @import("ir.zig").SublangSchema;
const FieldDef = @import("ir.zig").Field;
const Refinement = @import("ir.zig").Refinement;
const StringConstraints = @import("ir.zig").StringConstraints;
const diag = @import("diagnostic.zig");
const diagnostics = @import("diagnostics.zig");
const primitives = @import("primitives.zig");
const containers = @import("containers.zig");
const Span = diag.Span;

const resolve_mod = @import("resolve.zig");
const Scope = resolve_mod.Scope;
const ReferenceKind = resolve_mod.ReferenceKind;
pub const PendingReference = diagnostics.PendingReference;
pub const Diagnostic = diagnostics.Diagnostic;

const context_mod = @import("context.zig");
const sublang_mod = @import("sublang.zig");
const ContextEnv = context_mod.ContextEnv;
const SublangRegistry = sublang_mod.SublangRegistry;

const Catalog = resolve_mod.Catalog;
pub const Validator = struct {
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic),
    resolver: ?*const Resolver,
    sublangs: ?*const SublangRegistry,
    catalog: ?*const Catalog,
    scopes: std.ArrayListUnmanaged(*Scope),
    pending_refs: std.ArrayListUnmanaged(PendingReference),
    context: ?*const ContextEnv,
    path: std.ArrayListUnmanaged(resolve_mod.PathSegment),

    pub fn init(allocator: std.mem.Allocator, resolver: ?*const Resolver, sublangs: ?*const SublangRegistry, catalog: ?*const Catalog) Validator {
        return .{
            .allocator = allocator,
            .diagnostics = .{},
            .resolver = resolver,
            .sublangs = sublangs,
            .catalog = catalog,
            .scopes = .{},
            .pending_refs = .{},
            .context = null,
            .path = .{},
        };
    }

    pub fn deinit(self: *Validator) void {
        for (self.diagnostics.items) |d| {
            self.allocator.free(d.code);
            self.allocator.free(d.message);
            for (d.related) |r| self.allocator.free(r.message);
            self.allocator.free(d.related);
            for (d.suggestions) |s| self.allocator.free(s.replacement);
            self.allocator.free(d.suggestions);
        }
        self.diagnostics.deinit(self.allocator);

        for (self.scopes.items) |s| {
            var it = s.declarations.iterator();
            while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
            s.deinit();
            self.allocator.destroy(s);
        }
        self.scopes.deinit(self.allocator);

        for (self.pending_refs.items) |pr| {
            self.allocator.free(pr.name);
            pr.path.deinit(self.allocator);
        }
        self.pending_refs.deinit(self.allocator);
        self.path.deinit(self.allocator);
    }

    pub fn pushPath(self: *Validator, segment: resolve_mod.PathSegment) !void {
        try self.path.append(self.allocator, segment);
    }

    pub fn emit(self: *Validator, span: Span, code: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .err,
            .span = span,
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
            .related = &.{},
            .suggestions = &.{},
        });
    }

    pub fn hasErrors(self: *const Validator) bool {
        for (self.diagnostics.items) |d| {
            if (d.severity == .err) return true;
        }
        return false;
    }

    pub fn currentScope(self: *const Validator) ?*Scope {
        if (self.scopes.items.len == 0) return null;
        return self.scopes.items[self.scopes.items.len - 1];
    }

    pub fn pushScope(self: *Validator, kind: ReferenceKind) !void {
        const parent = self.currentScope();
        const scope = try self.allocator.create(Scope);
        scope.* = Scope.init(self.allocator, kind, parent);
        try self.scopes.append(self.allocator, scope);
    }

    pub fn popScope(self: *Validator) void {
        _ = self.scopes.pop();
    }
};

pub const Resolver = struct {
    definitions: std.StringHashMap(*const Schema),

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .definitions = std.StringHashMap(*const Schema).init(allocator) };
    }

    pub fn deinit(self: *Resolver) void {
        self.definitions.deinit();
    }

    pub fn resolve(self: *const Resolver, path: []const u8) ?*const Schema {
        const name = if (std.mem.startsWith(u8, path, "#/definitions/"))
            path["#/definitions/".len..]
        else if (std.mem.startsWith(u8, path, "#/"))
            path["#/".len..]
        else
            path;
        return self.definitions.get(name);
    }

    pub fn build(allocator: std.mem.Allocator, doc: *const yaml.DocNode) !Resolver {
        const compile = @import("compile.zig");
        var resolver = Resolver.init(allocator);

        const defs_val = doc.value.getMapping("definitions") orelse return resolver;
        const defs_node = doc.value.tree.nodes.items[defs_val.idx];

        var child = defs_node.first_child;
        while (child != 0) {
            const key_node = doc.value.tree.nodes.items[child];
            const key_str = key_node.computed_value orelse doc.value.tree.source[key_node.start..key_node.end];
            const val_idx = key_node.next_sibling;
            if (val_idx == 0) break;

            const key_dup = try allocator.dupe(u8, key_str);
            const val = yaml.Value{ .tree = doc.value.tree, .idx = val_idx, .arena = doc.value.arena };

            const schema_val = try compile.compile(allocator, &yaml.DocNode{
                .value = val,
                .arena = doc.value.arena,
                .source = doc.source,
            });

            const schema_ptr = try allocator.create(Schema);
            schema_ptr.* = schema_val;
            try resolver.definitions.put(key_dup, schema_ptr);

            child = doc.value.tree.nodes.items[val_idx].next_sibling;
        }

        return resolver;
    }
};
pub fn validateImpl(v: *Validator, schema: *const Schema, value: yaml.Value) anyerror!void {
    const span = diag.spanFromValue(value);

    if (schema.push_scope) |kind| {
        try v.pushScope(kind);
    }
    defer if (schema.push_scope != null) v.popScope();

    const old_context = v.context;
    if (schema.contexts) |cd| {
        const new_env = try v.allocator.create(ContextEnv);
        new_env.* = ContextEnv{
            .parent = v.context,
            .contributions = .{ .map = cd.map },
        };
        v.context = new_env;
    }
    defer v.context = old_context;

    if (schema.decl_as != null) {
        try containers.declareInScope(v, value, span);
    }

    if (schema.ref_to) |rt| {
        if (v.currentScope()) |s| {
            if (value.getString()) |name| {
                try v.pending_refs.append(v.allocator, .{
                    .span = span,
                    .kind = rt.kind,
                    .name = try v.allocator.dupe(u8, name),
                    .scope = s,
                    .path = try resolve_mod.PathExpression.parse(v.allocator, rt.path),
                    .catalog_kind = rt.catalog,
                });
            }
        }
    }

    switch (schema.kind) {
        .primitive => {
            if (try primitives.validatePrimitive(v, schema.kind.primitive, value)) {
                if (schema.kind.primitive == .string) _ = try primitives.validateStringConstraints(v, schema.string_constraints, value);
            }
        },
        .constant => _ = try primitives.validateConstant(v, schema.kind.constant, value),
        .enum_of => _ = try primitives.validateEnum(v, schema.kind.enum_of, value),
        .sequence => try containers.validateSequence(v, schema.kind.sequence, value, span),
        .mapping => try containers.validateMapping(v, schema.kind.mapping, value, span),
        .object => try containers.validateObject(v, schema, value, span),
        .any_of => try containers.validateAnyOf(v, schema.kind.any_of, value, span),
        .all_of => {
            const schemas = schema.kind.all_of;
            for (schemas) |sub| {
                try validateImpl(v, sub, value);
            }
        },
        .not => {
            const inner = schema.kind.not;
            var sub_v = Validator.init(v.allocator, v.resolver, v.sublangs, v.catalog);
            defer sub_v.deinit();
            try validateImpl(&sub_v, inner, value);
            if (!sub_v.hasErrors()) {
                try v.emit(span, "not_allowed", "value should not match schema");
            }
        },
        .ref => {
            if (v.resolver) |r| {
                const resolved = r.resolve(schema.kind.ref.path) orelse {
                    try v.emit(span, "ref_not_resolved", "could not resolve reference");
                    return;
                };
                try validateImpl(v, resolved, value);
            } else {
                try v.emit(span, "ref_not_resolved", "no resolver provided");
            }
        },
        .discriminated => try containers.validateDiscriminated(v, schema.kind.discriminated, value, span),
        .switch_on => try containers.validateSwitchOn(v, schema.kind.switch_on, value, span),
        .sublang => |s| try containers.validateSublang(v, s, value, span),
    }
}

pub fn validate(
    allocator: std.mem.Allocator,
    schema: *const Schema,
    value: yaml.Value,
    resolver: ?*const Resolver,
    sublangs: ?*const SublangRegistry,
    catalog: ?*const Catalog,
) ![]const Diagnostic {
    var v = Validator.init(allocator, resolver, sublangs, catalog);
    try validateImpl(&v, schema, value);

    for (v.pending_refs.items) |pr| {
        var decl: ?resolve_mod.Declaration = null;
        if (pr.catalog_kind) |ck| {
            if (v.catalog) |cat| {
                decl = cat.resolve(ck, pr.name);
            }
        } else {
            decl = pr.scope.resolve(pr.name, pr.path);
        }

        if (decl == null) {
            try v.emit(pr.span, "undefined_reference", try std.fmt.allocPrint(v.allocator, "undefined reference: {s}", .{pr.name}));
        }
    }

    const diags = v.diagnostics.toOwnedSlice(allocator);
    v.diagnostics = .{};
    v.deinit();
    return diags;
}

fn expectSuccess(allocator: std.mem.Allocator, schema: *const Schema, value: yaml.Value) !void {
    var v = Validator.init(allocator, null, null, null);
    defer v.deinit();
    try validateImpl(&v, schema, value);
    if (v.hasErrors()) {
        return error.ValidationFailed;
    }
}

fn expectErrorCode(allocator: std.mem.Allocator, schema: *const Schema, value: yaml.Value, code: []const u8) !void {
    var v = Validator.init(allocator, null, null, null);
    defer v.deinit();
    try validateImpl(&v, schema, value);
    if (!v.hasErrors()) return error.ValidationSucceeded;
    for (v.diagnostics.items) |d| {
        if (std.mem.eql(u8, d.code, code)) return;
    }
    return error.ErrorCodeNotFound;
}

test "validate string passes for scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate string fails for mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "key: value");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "type_mismatch");
}

test "validate integer matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "42");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate integer rejects non-numeric" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "not-a-number");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "type_mismatch");
}

test "validate boolean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "true");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .boolean }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate any passes everything" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "anything_goes");
    defer doc.deinit();
    const schema = Schema{ .span = undefined, .kind = .{ .primitive = .any }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate object requires fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "name: hello");
    defer doc.deinit();

    const name_schema = try arena.allocator().create(Schema);
    name_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };

    const obj_schema = try arena.allocator().create(ObjectSchema);
    obj_schema.* = ObjectSchema{
        .fields = &.{
            FieldDef{ .name = "name", .schema = name_schema, .required = true, .optional = false },
        },
        .additional = .{ .forbid = {} },
        .min_properties = null,
        .max_properties = null,
    };

    const schema = Schema{ .span = undefined, .kind = .{ .object = obj_schema }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate object rejects missing field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "other: value");
    defer doc.deinit();

    const name_schema = try arena.allocator().create(Schema);
    name_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };

    const obj_schema = try arena.allocator().create(ObjectSchema);
    obj_schema.* = ObjectSchema{
        .fields = &.{
            FieldDef{ .name = "name", .schema = name_schema, .required = true, .optional = false },
        },
        .additional = .{ .forbid = {} },
        .min_properties = null,
        .max_properties = null,
    };

    const schema = Schema{ .span = undefined, .kind = .{ .object = obj_schema }, .refinements = &.{}, .contexts = null };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "missing_field");
}

test "validate object rejects unexpected field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "name: hello\nextra: oops");
    defer doc.deinit();

    const name_schema = try arena.allocator().create(Schema);
    name_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };

    const obj_schema = try arena.allocator().create(ObjectSchema);
    obj_schema.* = ObjectSchema{
        .fields = &.{
            FieldDef{ .name = "name", .schema = name_schema, .required = true, .optional = false },
        },
        .additional = .{ .forbid = {} },
        .min_properties = null,
        .max_properties = null,
    };

    const schema = Schema{ .span = undefined, .kind = .{ .object = obj_schema }, .refinements = &.{}, .contexts = null };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "unexpected_field");
}

test "validate sequence checks items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "[1, 2, 3]");
    defer doc.deinit();

    const item_schema = try arena.allocator().create(Schema);
    item_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    const seq_schema = try arena.allocator().create(SeqSchema);
    seq_schema.* = SeqSchema{ .items = item_schema, .min_items = null, .max_items = null };

    const schema = Schema{ .span = undefined, .kind = .{ .sequence = seq_schema }, .refinements = &.{}, .contexts = null };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate sequence rejects min_items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "[1]");
    defer doc.deinit();

    const item_schema = try arena.allocator().create(Schema);
    item_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    const seq_schema = try arena.allocator().create(SeqSchema);
    seq_schema.* = SeqSchema{ .items = item_schema, .min_items = @as(usize, 2), .max_items = null };

    const schema = Schema{ .span = undefined, .kind = .{ .sequence = seq_schema }, .refinements = &.{}, .contexts = null };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "min_items");
}

test "validate enum matches one of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "foo");
    defer doc.deinit();
    const values = try arena.allocator().alloc(ConstValue, 2);
    values[0] = ConstValue{ .string = "foo" };
    values[1] = ConstValue{ .string = "bar" };
    const schema = Schema{
        .span = undefined,
        .kind = .{ .enum_of = values },
        .refinements = &.{},
        .contexts = null,
    };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate enum rejects non-matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "baz");
    defer doc.deinit();
    const values = try arena.allocator().alloc(ConstValue, 2);
    values[0] = ConstValue{ .string = "foo" };
    values[1] = ConstValue{ .string = "bar" };
    const schema = Schema{
        .span = undefined,
        .kind = .{ .enum_of = values },
        .refinements = &.{},
        .contexts = null,
    };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "enum_mismatch");
}

test "validate constant matches exact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();
    const schema = Schema{
        .span = undefined,
        .kind = .{ .constant = ConstValue{ .string = "hello" } },
        .refinements = &.{},
        .contexts = null,
    };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate any_of succeeds when one matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "42");
    defer doc.deinit();

    const str_schema = try arena.allocator().create(Schema);
    str_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    const int_schema = try arena.allocator().create(Schema);
    int_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    const any_of_schemas = try arena.allocator().alloc(*Schema, 2);
    any_of_schemas[0] = str_schema;
    any_of_schemas[1] = int_schema;
    const schema = Schema{
        .span = undefined,
        .kind = .{ .any_of = any_of_schemas },
        .refinements = &.{},
        .contexts = null,
    };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate any_of fails when none match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();

    const int_schema = try arena.allocator().create(Schema);
    int_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    const any_of_schemas = try arena.allocator().alloc(*Schema, 1);
    any_of_schemas[0] = int_schema;
    const schema = Schema{
        .span = undefined,
        .kind = .{ .any_of = any_of_schemas },
        .refinements = &.{},
        .contexts = null,
    };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "type_mismatch");
}

test "validate all_of passes when all match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();

    const str_schema = try arena.allocator().create(Schema);
    str_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    const any_schema = try arena.allocator().create(Schema);
    any_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .any }, .refinements = &.{}, .contexts = null };

    const all_of_schemas = try arena.allocator().alloc(*Schema, 2);
    all_of_schemas[0] = str_schema;
    all_of_schemas[1] = any_schema;
    const schema = Schema{
        .span = undefined,
        .kind = .{ .all_of = all_of_schemas },
        .refinements = &.{},
        .contexts = null,
    };
    try expectSuccess(arena.allocator(), &schema, doc.value);
}

test "validate all_of fails when one fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();

    const str_schema = try arena.allocator().create(Schema);
    str_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    const int_schema = try arena.allocator().create(Schema);
    int_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    const all_of_schemas = try arena.allocator().alloc(*Schema, 2);
    all_of_schemas[0] = str_schema;
    all_of_schemas[1] = int_schema;
    const schema = Schema{
        .span = undefined,
        .kind = .{ .all_of = all_of_schemas },
        .refinements = &.{},
        .contexts = null,
    };
    try expectErrorCode(arena.allocator(), &schema, doc.value, "type_mismatch");
}

test "resolver resolves ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var resolver = Resolver.init(arena.allocator());
    defer resolver.deinit();

    const target = try arena.allocator().create(Schema);
    target.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };

    try resolver.definitions.put("MyType", target);

    const ref_schema = try arena.allocator().create(Schema);
    ref_schema.* = Schema{
        .span = undefined,
        .kind = .{ .ref = .{ .path = "#/definitions/MyType" } },
        .refinements = &.{},
        .contexts = null,
    };

    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();

    var v = Validator.init(arena.allocator(), &resolver, null, null);
    defer v.deinit();
    try validateImpl(&v, ref_schema, doc.value);
    try std.testing.expect(!v.hasErrors());
}

test "resolver validates resolved ref body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var resolver = Resolver.init(arena.allocator());
    defer resolver.deinit();

    const target = try arena.allocator().create(Schema);
    target.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    try resolver.definitions.put("MyType", target);

    const ref_schema = try arena.allocator().create(Schema);
    ref_schema.* = Schema{
        .span = undefined,
        .kind = .{ .ref = .{ .path = "MyType" } },
        .refinements = &.{},
        .contexts = null,
    };

    var doc = try yaml.parse(arena.allocator(), "42");
    defer doc.deinit();

    var v = Validator.init(arena.allocator(), &resolver, null, null);
    defer v.deinit();
    try validateImpl(&v, ref_schema, doc.value);
    try std.testing.expect(!v.hasErrors());
}

test "resolver rejects non-matching ref value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var resolver = Resolver.init(arena.allocator());
    defer resolver.deinit();

    const target = try arena.allocator().create(Schema);
    target.* = Schema{ .span = undefined, .kind = .{ .primitive = .integer }, .refinements = &.{}, .contexts = null };

    try resolver.definitions.put("MyType", target);

    const ref_schema = try arena.allocator().create(Schema);
    ref_schema.* = Schema{
        .span = undefined,
        .kind = .{ .ref = .{ .path = "#/definitions/MyType" } },
        .refinements = &.{},
        .contexts = null,
    };

    var doc = try yaml.parse(arena.allocator(), "not-a-number");
    defer doc.deinit();

    var v = Validator.init(arena.allocator(), &resolver, null, null);
    defer v.deinit();
    try validateImpl(&v, ref_schema, doc.value);
    try std.testing.expect(v.hasErrors());
}

test "resolver returns ref_not_resolved for unknown path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var resolver = Resolver.init(arena.allocator());
    defer resolver.deinit();

    const ref_schema = try arena.allocator().create(Schema);
    ref_schema.* = Schema{
        .span = undefined,
        .kind = .{ .ref = .{ .path = "#/definitions/Unknown" } },
        .refinements = &.{},
        .contexts = null,
    };

    var doc = try yaml.parse(arena.allocator(), "hello");
    defer doc.deinit();

    var v = Validator.init(arena.allocator(), &resolver, null, null);
    defer v.deinit();
    try validateImpl(&v, ref_schema, doc.value);
    try std.testing.expect(v.hasErrors());
    try std.testing.expectEqualStrings("ref_not_resolved", v.diagnostics.items[0].code);
}
