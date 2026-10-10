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
const core = @import("core.zig");
const diagnostics = @import("diagnostics.zig");
const primitives = @import("primitives.zig");
const Validator = core.Validator;
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
pub fn isBetter(a: Validator, b: Validator) bool {
    if (a.diagnostics.items.len < b.diagnostics.items.len) return true;
    if (a.diagnostics.items.len > b.diagnostics.items.len) return false;

    if (a.diagnostics.items.len > 0) {
        const ap = diagnostics.codePriority(a.diagnostics.items[0].code);
        const bp = diagnostics.codePriority(b.diagnostics.items[0].code);
        if (ap > bp) return true;
    }

    return false;
}

pub fn declareInScope(v: *Validator, value: yaml.Value, span: Span) !void {
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

pub fn validateSequence(v: *Validator, seq: *SeqSchema, value: yaml.Value, span: Span) !void {
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
        try core.validateImpl(v, seq.items, item);
    }
}

pub fn validateMapping(v: *Validator, map: *MapSchema, value: yaml.Value, span: Span) !void {
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

        var key_v = Validator.init(v.allocator, v.resolver, v.sublangs, v.catalog);
        key_v.scopes = v.scopes;
        key_v.path = v.path;
        defer {
            key_v.scopes = .{};
            key_v.path = .{};
            key_v.deinit();
        }
        try core.validateImpl(&key_v, map.keys, yaml.Value{ .tree = value.tree, .idx = child, .arena = value.arena });
        for (key_v.diagnostics.items) |d| try v.diagnostics.append(v.allocator, try diagnostics.cloneDiagnostic(v.allocator, d));
        for (key_v.pending_refs.items) |pr| try v.pending_refs.append(v.allocator, pr);
        key_v.pending_refs = .{};

        try core.validateImpl(v, map.values, val);

        child = value.tree.nodes.items[val_idx].next_sibling;
    }
}

pub fn validateObject(v: *Validator, schema: *const Schema, value: yaml.Value, span: Span) !void {
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
                try core.validateImpl(v, field.schema, val);
                found = true;
                break;
            }
        }

        if (!found) {
            switch (obj.additional) {
                .forbid => try v.emit(diag.spanFromValue(yaml.Value{ .tree = value.tree, .idx = child, .arena = value.arena }), "unexpected_field", "field not allowed"),
                .allow => {},
                .schema => |additional_schema| try core.validateImpl(v, additional_schema, val),
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

    try primitives.validateRefinements(v, schema.refinements, value);
}

pub fn validateAnyOf(v: *Validator, schemas: []*Schema, value: yaml.Value, span: Span) !void {
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
        try core.validateImpl(&sub_v, sub, value);
        if (!sub_v.hasErrors()) {
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
            try v.diagnostics.append(v.allocator, try diagnostics.cloneDiagnostic(v.allocator, d));
        }
    } else {
        try v.emit(span, "any_of_none", "no branches matched");
    }
}

pub fn validateDiscriminated(v: *Validator, du: *DiscriminatedUnion, value: yaml.Value, span: Span) !void {
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
            try core.validateImpl(v, variant, value);
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
                try core.validateImpl(v, variant, value);
            } else {
                try v.emit(span, "discriminated_no_match", "no discriminator field present");
            }
        },
    }
}

pub fn validateSwitchOn(v: *Validator, sw: *SwitchSchema, value: yaml.Value, span: Span) !void {
    const tag_val = value.getMapping(sw.on) orelse {
        try v.emit(span, "switch_no_match", "switch field missing");
        return;
    };
    const tag_str = tag_val.getString() orelse {
        try v.emit(span, "switch_no_match", "switch field must be a string");
        return;
    };

    if (sw.common) |common| {
        try core.validateImpl(v, common, value);
    }

    for (sw.cases) |case| {
        if (std.mem.eql(u8, tag_str, case.value)) {
            try core.validateImpl(v, case.schema, value);
            return;
        }
    }
    try v.emit(span, "switch_no_match", "no switch case matched");
}

pub fn validateSublang(v: *Validator, s: SublangSchema, value: yaml.Value, span: Span) !void {
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
}
