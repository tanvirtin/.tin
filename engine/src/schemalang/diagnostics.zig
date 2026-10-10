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
pub fn cloneDiagnostic(allocator: std.mem.Allocator, d: Diagnostic) !Diagnostic {
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

pub fn codePriority(code: []const u8) u8 {
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

