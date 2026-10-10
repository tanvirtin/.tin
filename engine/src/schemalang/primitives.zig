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
pub fn validatePrimitive(v: *Validator, prim: Primitive, value: yaml.Value) !bool {
    const s = value.getString();
    const span = diag.spanFromValue(value);
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

pub fn validateConstant(v: *Validator, constant: ConstValue, value: yaml.Value) !bool {
    const s = value.getString() orelse {
        try v.emit(diag.spanFromValue(value), "constant_mismatch", "expected constant value");
        return false;
    };
    const span = diag.spanFromValue(value);
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

pub fn validateEnum(v: *Validator, values: []const ConstValue, value: yaml.Value) !bool {
    const s = value.getString() orelse {
        try v.emit(diag.spanFromValue(value), "enum_mismatch", "expected enum value");
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
    try v.emit(diag.spanFromValue(value), "enum_mismatch", "value not in enum");
    return false;
}

pub fn matchesPattern(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var si: usize = 0;
    var wildcard: ?usize = null;
    var match: usize = 0;

    while (si < s.len) {
        if (p < pattern.len and (pattern[p] == s[si] or pattern[p] == '?')) {
            p += 1;
            si += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            wildcard = p;
            match = si;
            p += 1;
        } else if (wildcard) |w| {
            p = w + 1;
            match += 1;
            si = match;
        } else {
            return false;
        }
    }

    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn validateStringConstraints(v: *Validator, sc: ?StringConstraints, value: yaml.Value) !bool {
    const constraints = sc orelse return true;
    const s = value.getString() orelse return true;
    const span = diag.spanFromValue(value);

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

pub fn validateRefinements(v: *Validator, refinements: []const Refinement, value: yaml.Value) !void {
    if (refinements.len == 0) return;

    const node = value.tree.nodes.items[value.idx];
    if (node.tag != .mapping) return;
    const span = diag.spanFromValue(value);

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
