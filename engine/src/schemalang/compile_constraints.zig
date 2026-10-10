const std = @import("std");
const yaml = @import("yaml");
const schema_mod = @import("ir.zig");
const Schema = schema_mod.Schema;
const Kind = schema_mod.Kind;
const Primitive = schema_mod.Primitive;
const ConstValue = schema_mod.ConstValue;
const Field = schema_mod.Field;
const Additional = schema_mod.Additional;
const ObjectSchema = schema_mod.ObjectSchema;
const SeqSchema = schema_mod.SeqSchema;
const MapSchema = schema_mod.MapSchema;
const SchemaRef = schema_mod.SchemaRef;
const DiscriminatedUnion = schema_mod.DiscriminatedUnion;
const SwitchSchema = schema_mod.SwitchSchema;
const SwitchCase = schema_mod.SwitchCase;
const PathRef = schema_mod.PathRef;
const SublangSchema = schema_mod.SublangSchema;
const Refinement = schema_mod.Refinement;
const StringConstraints = schema_mod.StringConstraints;
const FieldDependency = schema_mod.FieldDependency;
const Span = @import("diagnostic.zig").Span;
const diag = @import("diagnostic.zig");
const core = @import("compile_core.zig");
const CompileError = core.CompileError;

pub fn compileConstant(allocator: std.mem.Allocator, value: yaml.Value) CompileError!ConstValue {
    const val = value.get("value") orelse return error.InvalidSchema;
    return core.compileConstValue(allocator, val);
}

pub fn compileEnum(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]ConstValue {
    const values_val = value.get("values") orelse return error.InvalidSchema;
    const items = values_val.getSequence() orelse return error.InvalidSchema;

    var result = try allocator.alloc(ConstValue, items.len);
    for (items, 0..) |item, i| {
        result[i] = try core.compileConstValue(allocator, item);
    }
    return result;
}
pub fn compileRefinements(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]const Refinement {
    const ref_val = value.get("refinements") orelse return &[_]Refinement{};

    const seq = ref_val.getSequence() orelse return error.InvalidSchema;

    var result = try allocator.alloc(Refinement, seq.len);
    for (seq, 0..) |item, i| {
        if (item.get("forbid_pair")) |fpv| {
            const pair_seq = fpv.getSequence() orelse return error.InvalidSchema;
            if (pair_seq.len != 2) return error.InvalidSchema;
            const a = pair_seq[0].getString() orelse return error.InvalidSchema;
            const b = pair_seq[1].getString() orelse return error.InvalidSchema;
            result[i] = Refinement{
                .forbid_pair = .{ try allocator.dupe(u8, a), try allocator.dupe(u8, b) },
            };
        } else if (item.get("require_one_of")) |rov| {
            const list_seq = rov.getSequence() orelse return error.InvalidSchema;
            var list = try allocator.alloc([]const u8, list_seq.len);
            for (list_seq, 0..) |sv, j| {
                const s = sv.getString() orelse return error.InvalidSchema;
                list[j] = try allocator.dupe(u8, s);
            }
            result[i] = Refinement{ .require_one_of = list };
        } else if (item.get("require_at_least")) |ral| {
            const s = ral.getString() orelse return error.InvalidSchema;
            const n = std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
            result[i] = Refinement{ .require_at_least = n };
        } else {
            return error.InvalidSchema;
        }
    }
    return result;
}

pub fn compileStringConstraints(allocator: std.mem.Allocator, value: yaml.Value) CompileError!?StringConstraints {
    const pattern = if (value.get("pattern")) |pv| blk: {
        break :blk try allocator.dupe(u8, pv.getString() orelse return error.InvalidSchema);
    } else null;

    const min_length = if (value.get("min_length")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    const max_length = if (value.get("max_length")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    if (pattern == null and min_length == null and max_length == null) return null;
    return StringConstraints{ .pattern = pattern, .min_length = min_length, .max_length = max_length };
}

pub fn compileSublang(allocator: std.mem.Allocator, value: yaml.Value) CompileError!SublangSchema {
    const grammar_val = value.get("grammar") orelse return error.InvalidSchema;
    const grammar = grammar_val.getString() orelse return error.InvalidSchema;
    const grammar_dup = try allocator.dupe(u8, grammar);

    const proxy = if (value.get("proxy")) |pv| try allocator.dupe(u8, pv.getString() orelse return error.InvalidSchema) else null;

    return SublangSchema{ .grammar = grammar_dup, .proxy = proxy };
}
