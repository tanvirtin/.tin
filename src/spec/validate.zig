const std = @import("std");
const yaml = @import("yaml");
const Schema = @import("ir.zig").Schema;
const Kind = @import("ir.zig").Kind;
const Primitive = @import("ir.zig").Primitive;
const ConstValue = @import("ir.zig").ConstValue;
const ObjectSchema = @import("ir.zig").ObjectSchema;
const SeqSchema = @import("ir.zig").SeqSchema;
const MapSchema = @import("ir.zig").MapSchema;
const FieldDef = @import("ir.zig").Field;
const Refinement = @import("ir.zig").Refinement;
const StringConstraints = @import("ir.zig").StringConstraints;
const FieldDependency = @import("ir.zig").FieldDependency;
const diag = @import("diagnostic.zig");
const Span = diag.Span;
pub const Diagnostic = diag.Diagnostic;

const resolve_mod = @import("resolve.zig");
const Scope = resolve_mod.Scope;
const ReferenceKind = resolve_mod.ReferenceKind;
pub const PendingReference = resolve_mod.PendingReference;

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

    pub fn popPath(self: *Validator) void {
        _ = self.path.pop();
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

fn spanFromValue(value: yaml.Value) Span {
    if (value.idx >= value.tree.nodes.items.len)
        return Span{ .file_id = 0, .start = 0, .end = 0 };
    const node = value.tree.nodes.items[value.idx];
    return Span{ .file_id = 0, .start = node.start, .end = node.end };
}

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

fn validatePrimitive(v: *Validator, prim: Primitive, value: yaml.Value) !bool {
    const s = value.getString();
    const span = spanFromValue(value);
    switch (prim) {
        .string => {
            if (s == null) {
                try v.emit(span, "type_mismatch", "expected string");
                return false;
            }
        },
        .integer => {
            const str = s orelse {
                try v.emit(span, "type_mismatch", "expected integer");
                return false;
            };
            _ = std.fmt.parseInt(i64, str, 10) catch {
                try v.emit(span, "type_mismatch", "expected integer");
                return false;
            };
        },
        .number => {
            const str = s orelse {
                try v.emit(span, "type_mismatch", "expected number");
                return false;
            };
            _ = std.fmt.parseFloat(f64, str) catch {
                try v.emit(span, "type_mismatch", "expected number");
                return false;
            };
        },
        .boolean => {
            const str = s orelse {
                try v.emit(span, "type_mismatch", "expected boolean");
                return false;
            };
            if (!std.mem.eql(u8, str, "true") and
                !std.mem.eql(u8, str, "false") and
                !std.mem.eql(u8, str, "yes") and
                !std.mem.eql(u8, str, "no") and
                !std.mem.eql(u8, str, "on") and
                !std.mem.eql(u8, str, "off"))
            {
                try v.emit(span, "type_mismatch", "expected boolean");
                return false;
            }
        },
        .null_t => {
            const node = value.tree.nodes.items[value.idx];
            if (node.tag == .null) return true;
            if (node.tag != .scalar) {
                try v.emit(span, "type_mismatch", "expected null");
                return false;
            }
            const str = s orelse {
                try v.emit(span, "type_mismatch", "expected null");
                return false;
            };
            if (!std.mem.eql(u8, str, "null") and !std.mem.eql(u8, str, "~") and str.len != 0) {
                try v.emit(span, "type_mismatch", "expected null");
                return false;
            }
        },
        .any => {},
    }
    return true;
}

fn validateConstant(v: *Validator, constant: ConstValue, value: yaml.Value) !bool {
    const s = value.getString() orelse {
        try v.emit(spanFromValue(value), "constant_mismatch", "expected constant value");
        return false;
    };
    const span = spanFromValue(value);
    switch (constant) {
        .string => |expected| {
            if (!std.mem.eql(u8, s, expected)) {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            }
        },
        .integer => |expected| {
            const parsed = std.fmt.parseInt(i64, s, 10) catch {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            };
            if (parsed != expected) {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            }
        },
        .number => |expected| {
            const parsed = std.fmt.parseFloat(f64, s) catch {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            };
            if (parsed != expected) {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            }
        },
        .boolean => |expected| {
            const is_true = std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on");
            const is_false = std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off");
            if (expected) {
                if (!is_true) {
                    try v.emit(span, "constant_mismatch", "expected constant value");
                    return false;
                }
            } else {
                if (!is_false) {
                    try v.emit(span, "constant_mismatch", "expected constant value");
                    return false;
                }
            }
        },
        .null_t => {
            if (!std.mem.eql(u8, s, "null") and !std.mem.eql(u8, s, "~") and s.len != 0) {
                try v.emit(span, "constant_mismatch", "expected constant value");
                return false;
            }
        },
    }
    return true;
}

fn validateEnum(v: *Validator, values: []const ConstValue, value: yaml.Value) !bool {
    const s = value.getString() orelse {
        try v.emit(spanFromValue(value), "enum_mismatch", "expected enum value");
        return false;
    };
    for (values) |cv| {
        const matched = switch (cv) {
            .string => |expected| std.mem.eql(u8, s, expected),
            .integer => |expected| (std.fmt.parseInt(i64, s, 10) catch continue) == expected,
            .number => |expected| (std.fmt.parseFloat(f64, s) catch continue) == expected,
            .boolean => |expected| blk: {
                const is_true = std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on");
                const is_false = std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off");
                break :blk if (expected) is_true else is_false;
            },
            .null_t => std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~") or s.len == 0,
        };
        if (matched) return true;
    }
    try v.emit(spanFromValue(value), "enum_mismatch", "value not in enum");
    return false;
}

fn matchesPattern(pattern: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var wildcard: ?usize = null;
    var match: usize = 0;

    while (si < s.len) {
        if (pi < pattern.len and (pattern[pi] == s[si] or pattern[pi] == '?')) {
            pi += 1;
            si += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            wildcard = pi;
            match = si;
            pi += 1;
        } else if (wildcard) |wp| {
            pi = wp + 1;
            match += 1;
            si = match;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

fn validateStringConstraints(v: *Validator, sc: ?StringConstraints, value: yaml.Value) !bool {
    const constraints = sc orelse return true;
    const s = value.getString() orelse return true;
    const span = spanFromValue(value);

    if (constraints.min_length) |min| if (s.len < min) {
        try v.emit(span, "min_length", "string too short");
        return false;
    };
    if (constraints.max_length) |max| if (s.len > max) {
        try v.emit(span, "max_length", "string too long");
        return false;
    };
    if (constraints.pattern) |pat| {
        if (!matchesPattern(pat, s)) {
            try v.emit(span, "pattern_mismatch", "string does not match pattern");
            return false;
        }
    }
    return true;
}

fn validateRefinements(v: *Validator, refinements: []const Refinement, value: yaml.Value) !void {
    if (refinements.len == 0) return;

    const node = value.tree.nodes.items[value.idx];
    if (node.tag != .mapping) return;
    const span = spanFromValue(value);

    for (refinements) |ref| {
        switch (ref) {
            .require_one_of => |fields| {
                var found: bool = false;
                var child = node.first_child;
                while (child != 0) {
                    const key_node = value.tree.nodes.items[child];
                    const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
                    for (fields) |field| {
                        if (std.mem.eql(u8, key_str, field)) {
                            found = true;
                            break;
                        }
                    }
                    if (found) break;
                    const val_idx = key_node.next_sibling;
                    if (val_idx == 0) break;
                    child = value.tree.nodes.items[val_idx].next_sibling;
                }
                if (!found) try v.emit(span, "missing_required_one_of", "none of the required fields present");
            },
            .forbid_pair => |pair| {
                var found_a = false;
                var found_b = false;
                var child = node.first_child;
                while (child != 0) {
                    const key_node = value.tree.nodes.items[child];
                    const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
                    if (std.mem.eql(u8, key_str, pair[0])) found_a = true;
                    if (std.mem.eql(u8, key_str, pair[1])) found_b = true;
                    const val_idx = key_node.next_sibling;
                    if (val_idx == 0) break;
                    child = value.tree.nodes.items[val_idx].next_sibling;
                }
                if (found_a and found_b) try v.emit(span, "forbidden_pair", "forbidden pair of fields present");
            },
            .require_at_least => |min| {
                var count: usize = 0;
                var child = node.first_child;
                while (child != 0) {
                    count += 1;
                    const key_node = value.tree.nodes.items[child];
                    const val_idx = key_node.next_sibling;
                    if (val_idx == 0) break;
                    child = value.tree.nodes.items[val_idx].next_sibling;
                }
                if (count < min) try v.emit(span, "require_at_least", "not enough fields present");
            },
        }
    }
}

fn cloneDiagnostic(allocator: std.mem.Allocator, d: Diagnostic) !Diagnostic {
    const related = try allocator.alloc(diag.Related, d.related.len);
    for (d.related, 0..) |r, i| {
        related[i] = .{ .span = r.span, .message = try allocator.dupe(u8, r.message) };
    }
    const suggestions = try allocator.alloc(diag.Suggestion, d.suggestions.len);
    for (d.suggestions, 0..) |s, i| {
        suggestions[i] = .{ .span = s.span, .replacement = try allocator.dupe(u8, s.replacement) };
    }
    return .{
        .severity = d.severity,
        .span = d.span,
        .code = try allocator.dupe(u8, d.code),
        .message = try allocator.dupe(u8, d.message),
        .related = related,
        .suggestions = suggestions,
    };
}

fn codePriority(code: []const u8) u8 {
    if (std.mem.eql(u8, code, "unexpected_field")) return 3;
    if (std.mem.eql(u8, code, "missing_field")) return 3;
    if (std.mem.eql(u8, code, "missing_required_one_of")) return 3;
    if (std.mem.eql(u8, code, "forbidden_pair")) return 3;
    if (std.mem.eql(u8, code, "require_at_least")) return 3;
    if (std.mem.eql(u8, code, "min_properties")) return 3;
    if (std.mem.eql(u8, code, "max_properties")) return 3;
    if (std.mem.eql(u8, code, "missing_dependency")) return 3;

    if (std.mem.eql(u8, code, "enum_mismatch")) return 2;
    if (std.mem.eql(u8, code, "constant_mismatch")) return 2;
    if (std.mem.eql(u8, code, "pattern_mismatch")) return 2;
    if (std.mem.eql(u8, code, "min_length")) return 2;
    if (std.mem.eql(u8, code, "max_length")) return 2;
    if (std.mem.eql(u8, code, "min_items")) return 2;
    if (std.mem.eql(u8, code, "max_items")) return 2;
    if (std.mem.eql(u8, code, "discriminated_no_match")) return 2;
    if (std.mem.eql(u8, code, "switch_no_match")) return 2;

    return 1;
}

fn isBetter(a: Validator, b: Validator) bool {
    if (a.diagnostics.items.len < b.diagnostics.items.len) return true;
    if (a.diagnostics.items.len > b.diagnostics.items.len) return false;
    
    if (a.diagnostics.items.len > 0) {
        const ap = codePriority(a.diagnostics.items[0].code);
        const bp = codePriority(b.diagnostics.items[0].code);
        if (ap > bp) return true;
    }
    
    return false;
}

pub fn validateImpl(v: *Validator, schema: *const Schema, value: yaml.Value) !void {
    const span = spanFromValue(value);

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

    // Register declaration if decl_as is present
    if (schema.decl_as) |_| {
        if (v.currentScope()) |s| {
            if (value.getString()) |name| {
                const path_copy = try v.allocator.alloc(resolve_mod.PathSegment, v.path.items.len);
                for (v.path.items, 0..) |segment, i| {
                    path_copy[i] = switch (segment) {
                        .key => |k| .{ .key = try v.allocator.dupe(u8, k) },
                        .wildcard => .wildcard,
                        .recursive => .recursive,
                    };
                }
                try s.declare(try v.allocator.dupe(u8, name), .{
                    .span = span,
                    .node = value,
                    .path = path_copy,
                });
            }
        }
    }

    // Accumulate pending reference if ref_to is present
    if (schema.ref_to) |rt| {
        if (v.currentScope()) |s| {
            if (value.getString()) |name| {
                try v.pending_refs.append(v.allocator, .{
                    .span = span,
                    .kind = rt.kind, // No dupe needed here as it's from Schema
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
            if (try validatePrimitive(v, schema.kind.primitive, value)) {
                if (schema.kind.primitive == .string) _ = try validateStringConstraints(v, schema.string_constraints, value);
            }
        },
        .constant => _ = try validateConstant(v, schema.kind.constant, value),
        .enum_of => _ = try validateEnum(v, schema.kind.enum_of, value),
        .sequence => {
            const seq = schema.kind.sequence;
            const items = value.getSequence() orelse {
                try v.emit(span, "type_mismatch", "expected sequence");
                return;
            };
            if (seq.min_items) |min| if (items.len < min) try v.emit(span, "min_items", "too few items");
            if (seq.max_items) |max| if (items.len > max) try v.emit(span, "max_items", "too many items");
            for (items, 0..) |item, i| {
                var buf: [32]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                try v.pushPath(.{ .key = try v.allocator.dupe(u8, idx_str) });
                defer {
                    const segment = v.path.pop().?;
                    v.allocator.free(segment.key);
                }
                try validateImpl(v, seq.items, item);
            }
        },
        .mapping => {
            const map = schema.kind.mapping;
            const node = value.tree.nodes.items[value.idx];
            if (node.tag != .mapping) {
                try v.emit(span, "type_mismatch", "expected mapping");
                return;
            }
            var child = node.first_child;
            while (child != 0) {
                const key_node = value.tree.nodes.items[child];
                const val_idx = key_node.next_sibling;
                if (val_idx == 0) break;

                const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
                try v.pushPath(.{ .key = try v.allocator.dupe(u8, key_str) });
                defer {
                    const segment = v.path.pop().?;
                    v.allocator.free(segment.key);
                }

                const val = yaml.Value{ .tree = value.tree, .idx = val_idx, .arena = value.arena };
                
                // Key validation
                var key_v = Validator.init(v.allocator, v.resolver, v.sublangs, v.catalog);
                // Inherit scopes for key validation if they should be declarations
                key_v.scopes = v.scopes; 
                defer {
                    key_v.scopes = .{}; // Don't let key_v.deinit free v.scopes
                    key_v.deinit();
                }
                try validateImpl(&key_v, map.keys, yaml.Value{ .tree = value.tree, .idx = child, .arena = value.arena });
                for (key_v.diagnostics.items) |d| try v.diagnostics.append(v.allocator, try cloneDiagnostic(v.allocator, d));
                // Transfer pending refs from key validation
                for (key_v.pending_refs.items) |pr| try v.pending_refs.append(v.allocator, pr);
                key_v.pending_refs = .{}; 

                // Value validation
                try validateImpl(v, map.values, val);

                child = value.tree.nodes.items[val_idx].next_sibling;
            }
        },
        .object => {
            const obj = schema.kind.object;
            const node = value.tree.nodes.items[value.idx];
            if (node.tag != .mapping) {
                try v.emit(span, "type_mismatch", "expected object mapping");
                return;
            }

            for (obj.fields) |field| {
                if (field.required) {
                    const field_value = value.getMapping(field.name);
                    if (field_value == null) {
                        try v.emit(span, "missing_field", "required field missing");
                    }
                }
            }

            var child = node.first_child;
            var prop_count: usize = 0;
            var present_fields = std.StringHashMap(void).init(v.allocator);
            defer present_fields.deinit();
            while (child != 0) {
                prop_count += 1;

                const key_node = value.tree.nodes.items[child];
                const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];

                present_fields.put(key_str, {}) catch return error.OutOfMemory;

                const val_idx = key_node.next_sibling;
                if (val_idx == 0) break;

                try v.pushPath(.{ .key = try v.allocator.dupe(u8, key_str) });
                defer {
                    const segment = v.path.pop().?;
                    v.allocator.free(segment.key);
                }

                const val = yaml.Value{ .tree = value.tree, .idx = val_idx, .arena = value.arena };

                var found: bool = false;
                for (obj.fields) |field| {
                    if (std.mem.eql(u8, key_str, field.name)) {
                        try validateImpl(v, field.schema, val);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    switch (obj.additional) {
                        .forbid => try v.emit(spanFromValue(yaml.Value{ .tree = value.tree, .idx = child, .arena = value.arena }), "unexpected_field", "field not allowed"),
                        .allow => {},
                        .schema => |additional_schema| try validateImpl(v, additional_schema, val),
                    }
                }

                child = value.tree.nodes.items[val_idx].next_sibling;
            }

            if (obj.min_properties) |min| if (prop_count < min) try v.emit(span, "min_properties", "too few properties");
            if (obj.max_properties) |max| if (prop_count > max) try v.emit(span, "max_properties", "too many properties");

            if (obj.dependencies.len > 0) {
                for (obj.dependencies) |dep| {
                    if (present_fields.contains(dep.field)) {
                        for (dep.requires) |req| {
                            if (!present_fields.contains(req)) try v.emit(span, "missing_dependency", "missing dependency");
                        }
                    }
                }
            }

            try validateRefinements(v, schema.refinements, value);
        },
        .any_of => {
            const schemas = schema.kind.any_of;
            var best_v: ?Validator = null;
            defer if (best_v) |*bv| {
                bv.scopes = .{};
                bv.deinit();
            };

            for (schemas) |sub| {
                var sub_v = Validator.init(v.allocator, v.resolver, v.sublangs, v.catalog);
                sub_v.scopes = v.scopes;
                errdefer {
                    sub_v.scopes = .{};
                    sub_v.deinit();
                }
                try validateImpl(&sub_v, sub, value);
                if (!sub_v.hasErrors()) {
                    // Transfer pending refs from successful branch
                    for (sub_v.pending_refs.items) |pr| try v.pending_refs.append(v.allocator, pr);
                    sub_v.pending_refs = .{};
                    sub_v.scopes = .{};
                    sub_v.deinit();
                    return;
                }

                if (best_v == null or isBetter(sub_v, best_v.?)) {
                    if (best_v) |*bv| {
                        bv.scopes = .{};
                        bv.deinit();
                    }
                    best_v = sub_v;
                } else {
                    sub_v.scopes = .{};
                    sub_v.deinit();
                }
            }

            if (best_v) |bv| {
                for (bv.diagnostics.items) |d| {
                    try v.diagnostics.append(v.allocator, try cloneDiagnostic(v.allocator, d));
                }
            } else {
                try v.emit(span, "any_of_none", "no branches matched");
            }
        },
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
        .discriminated => {
            const du = schema.kind.discriminated;
            switch (du.*) {
                .by_tag => |bt| {
                    const tag_val = value.getMapping(bt.field) orelse {
                        try v.emit(span, "discriminated_no_match", "discriminator field missing");
                        return;
                    };
                    const tag_str = tag_val.getString() orelse {
                        try v.emit(span, "discriminated_no_match", "discriminator field must be a string");
                        return;
                    };
                    const variant = bt.variants.get(tag_str) orelse {
                        try v.emit(span, "discriminated_no_match", "unknown discriminator value");
                        return;
                    };
                    try validateImpl(v, variant, value);
                },
                .by_presence => |bp| {
                    var it = bp.fields.iterator();
                    var found_variant: ?*Schema = null;
                    while (it.next()) |entry| {
                        if (value.getMapping(entry.key_ptr.*)) |_| {
                            if (found_variant != null) {
                                try v.emit(span, "discriminated_no_match", "multiple discriminator fields present");
                                return;
                            }
                            found_variant = entry.value_ptr.*;
                        }
                    }
                    if (found_variant) |variant| {
                        try validateImpl(v, variant, value);
                    } else {
                        try v.emit(span, "discriminated_no_match", "no discriminator field present");
                    }
                },
            }
        },
        .switch_on => {
            const sw = schema.kind.switch_on;
            const tag_val = value.getMapping(sw.on) orelse {
                try v.emit(span, "switch_no_match", "switch field missing");
                return;
            };
            const tag_str = tag_val.getString() orelse {
                try v.emit(span, "switch_no_match", "switch field must be a string");
                return;
            };
            
            if (sw.common) |common| {
                try validateImpl(v, common, value);
            }

            for (sw.cases) |case| {
                if (std.mem.eql(u8, tag_str, case.value)) {
                    try validateImpl(v, case.schema, value);
                    return;
                }
            }
            try v.emit(span, "switch_no_match", "no switch case matched");
        },
        .path_ref => |pr| {
            if (value.getString()) |name| {
                const scope = v.currentScope() orelse {
                    try v.emit(span, "no_scope", "no scope available for path reference");
                    return;
                };
                try v.pending_refs.append(v.allocator, .{
                    .span = span,
                    .kind = pr.kind,
                    .name = try v.allocator.dupe(u8, name),
                    .scope = scope,
                    .path = try resolve_mod.PathExpression.parse(v.allocator, pr.path),
                    .catalog_kind = pr.catalog,
                });
            } else {
                try v.emit(span, "type_mismatch", "expected string for path reference");
            }
        },
        .sublang => |s| {
            if (value.getString()) |str| {
                const sm = value.getSourceMap();
                if (s.proxy) |p| {
                    const proxy_mod = @import("sublang/proxy.zig");
                    try proxy_mod.validate(v.allocator, str, span, v.context, &v.diagnostics, sm, .{ .command = p });
                } else if (v.sublangs) |registry| {
                    if (registry.get(s.grammar)) |plugin| {
                        try plugin.validate(v.allocator, str, span, v.context, &v.diagnostics, sm);
                    } else {
                        try v.emit(span, "unknown_grammar", try std.fmt.allocPrint(v.allocator, "unknown grammar: {s}", .{s.grammar}));
                    }
                } else {
                    try v.emit(span, "no_sublang_registry", "no sublanguage registry provided");
                }
            } else {
                try v.emit(span, "type_mismatch", "expected string for sublanguage embedding");
            }
        },
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

    // Pass 2: Resolution
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

    return v.diagnostics.toOwnedSlice(allocator);
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
