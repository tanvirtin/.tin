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

pub fn compileSequence(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*SeqSchema {
    const items_val = value.get("items") orelse return error.InvalidSchema;
    const items = try core.readSchema(allocator, items_val);

    const min_items = if (value.get("min_items")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    const max_items = if (value.get("max_items")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    const seq = try allocator.create(SeqSchema);
    seq.* = SeqSchema{
        .items = items,
        .min_items = min_items,
        .max_items = max_items,
    };
    return seq;
}

pub fn compileMapping(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*MapSchema {
    const values_val = value.get("values") orelse return error.InvalidSchema;
    const values = try core.readSchema(allocator, values_val);

    var keys: *Schema = undefined;
    if (value.get("keys")) |keys_val| {
        keys = try core.readSchema(allocator, keys_val);
    } else {
        keys = try allocator.create(Schema);
        keys.* = Schema{
            .span = undefined,
            .kind = .{ .primitive = .string },
            .refinements = &.{},
            .contexts = null,
        };
    }

    const map = try allocator.create(MapSchema);
    map.* = MapSchema{ .keys = keys, .values = values };
    return map;
}

pub fn compileObject(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*ObjectSchema {
    const fields = if (value.get("fields")) |fv| blk: {
        const seq = fv.getSequence() orelse return error.InvalidSchema;
        var result = try allocator.alloc(Field, seq.len);
        for (seq, 0..) |item, i| {
            const name_val = item.get("name") orelse return error.InvalidSchema;
            const name = name_val.getString() orelse return error.InvalidSchema;
            const name_dup = try allocator.dupe(u8, name);

            const field_schema = if (item.get("type")) |type_val| blk1: {
                if (type_val.getString()) |s| {
                    if (core.isPrimitive(s)) break :blk1 try core.readSchema(allocator, item);
                    break :blk1 try core.readSchema(allocator, item);
                } else {
                    break :blk1 try core.readSchema(allocator, type_val);
                }
            } else blk1: {
                break :blk1 try core.readSchema(allocator, item);
            };

            const required = if (item.get("required")) |rv| blk3: {
                const s = rv.getString() orelse break :blk3 true;
                break :blk3 std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes");
            } else true;

            result[i] = Field{
                .name = name_dup,
                .schema = field_schema,
                .required = required,
                .optional = !required,
            };
        }
        break :blk result;
    } else &[_]Field{};

    const additional = if (value.get("additional")) |av| add: {
        if (av.getString()) |s| {
            if (std.mem.eql(u8, s, "forbid")) break :add Additional{ .forbid = {} };
            if (std.mem.eql(u8, s, "allow")) break :add Additional{ .allow = {} };
        }
        break :add Additional{ .schema = try core.readSchema(allocator, av) };
    } else Additional{ .forbid = {} };

    const min_properties = if (value.get("min_properties")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    const max_properties = if (value.get("max_properties")) |mv| blk: {
        const s = mv.getString() orelse return error.InvalidSchema;
        break :blk std.fmt.parseInt(usize, s, 10) catch return error.InvalidSchema;
    } else null;

    const dependencies = if (value.get("dependencies")) |dv| blk: {
        const seq = dv.getSequence() orelse return error.InvalidSchema;
        var result = try allocator.alloc(FieldDependency, seq.len);
        for (seq, 0..) |item, i| {
            const field_val = item.get("field") orelse return error.InvalidSchema;
            const field = field_val.getString() orelse return error.InvalidSchema;
            const field_dup = try allocator.dupe(u8, field);

            const requires_val = item.get("requires") orelse return error.InvalidSchema;
            const requires_seq = requires_val.getSequence() orelse return error.InvalidSchema;
            var requires = try allocator.alloc([]const u8, requires_seq.len);
            for (requires_seq, 0..) |rv, j| {
                const r = rv.getString() orelse return error.InvalidSchema;
                requires[j] = try allocator.dupe(u8, r);
            }

            result[i] = FieldDependency{ .field = field_dup, .requires = requires };
        }
        break :blk result;
    } else &.{};

    const obj = try allocator.create(ObjectSchema);
    obj.* = ObjectSchema{
        .fields = fields,
        .additional = additional,
        .min_properties = min_properties,
        .max_properties = max_properties,
        .dependencies = dependencies,
    };
    return obj;
}

pub fn compileSchemasList(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    const schemas_val = value.get("schemas") orelse return error.InvalidSchema;
    const seq = schemas_val.getSequence() orelse return error.InvalidSchema;

    var result = try allocator.alloc(*Schema, seq.len);
    for (seq, 0..) |item, i| {
        result[i] = try core.readSchema(allocator, item);
    }
    return result;
}

pub fn compileAnyOf(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    return compileSchemasList(allocator, value);
}

pub fn compileAllOf(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    return compileSchemasList(allocator, value);
}

pub fn compileNot(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*Schema {
    const schema_val = value.get("schema") orelse return error.InvalidSchema;
    return core.readSchema(allocator, schema_val);
}

pub fn compileRef(allocator: std.mem.Allocator, value: yaml.Value) CompileError!SchemaRef {
    const path_val = value.get("path") orelse return error.InvalidSchema;
    const path = path_val.getString() orelse return error.InvalidSchema;
    const path_dup = try allocator.dupe(u8, path);
    return SchemaRef{ .path = path_dup };
}
pub fn compileDiscriminated(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*DiscriminatedUnion {
    if (value.get("field")) |field_val| {
        const field_name = field_val.getString() orelse return error.InvalidSchema;
        const field_dup = try allocator.dupe(u8, field_name);

        const variants_val = value.get("variants") orelse return error.InvalidSchema;
        const node = value.tree.nodes.items[variants_val.idx];

        var variants = std.StringHashMap(*Schema).init(allocator);
        var child = node.first_child;
        while (child != 0) {
            const key_node = value.tree.nodes.items[child];
            const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
            const val_idx = key_node.next_sibling;
            if (val_idx == 0) break;

            const key_dup = try allocator.dupe(u8, key_str);
            const val = yaml.Value{ .tree = value.tree, .idx = val_idx, .arena = value.arena };
            const variant_schema = try core.readSchema(allocator, val);
            try variants.put(key_dup, variant_schema);

            child = value.tree.nodes.items[val_idx].next_sibling;
        }

        const du = try allocator.create(DiscriminatedUnion);
        du.* = DiscriminatedUnion{ .by_tag = .{ .field = field_dup, .variants = variants } };
        return du;
    }

    if (value.get("fields")) |fields_val| {
        const node = value.tree.nodes.items[fields_val.idx];

        var fields = std.StringHashMap(*Schema).init(allocator);
        var child = node.first_child;
        while (child != 0) {
            const key_node = value.tree.nodes.items[child];
            const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
            const val_idx = key_node.next_sibling;
            if (val_idx == 0) break;

            const key_dup = try allocator.dupe(u8, key_str);
            const val = yaml.Value{ .tree = value.tree, .idx = val_idx, .arena = value.arena };
            const variant_schema = try core.readSchema(allocator, val);
            try fields.put(key_dup, variant_schema);

            child = value.tree.nodes.items[val_idx].next_sibling;
        }

        const du = try allocator.create(DiscriminatedUnion);
        du.* = DiscriminatedUnion{ .by_presence = .{ .fields = fields } };
        return du;
    }

    return error.InvalidSchema;
}

pub fn compileSwitch(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*SwitchSchema {
    const on_val = value.get("on") orelse return error.InvalidSchema;
    const on = on_val.getString() orelse return error.InvalidSchema;
    const on_dup = try allocator.dupe(u8, on);

    const cases_val = value.get("cases") orelse return error.InvalidSchema;
    const seq = cases_val.getSequence() orelse return error.InvalidSchema;

    var cases = try allocator.alloc(SwitchCase, seq.len);
    for (seq, 0..) |item, i| {
        const case_val = item.get("value") orelse return error.InvalidSchema;
        const case_str = case_val.getString() orelse return error.InvalidSchema;
        const case_dup = try allocator.dupe(u8, case_str);

        const schema_val = item.get("schema") orelse return error.InvalidSchema;
        const case_schema = try core.readSchema(allocator, schema_val);

        cases[i] = SwitchCase{ .value = case_dup, .schema = case_schema };
    }

    const common = if (value.get("common")) |cv|
        try core.readSchema(allocator, cv)
    else
        null;

    const sw = try allocator.create(SwitchSchema);
    sw.* = SwitchSchema{ .on = on_dup, .cases = cases, .common = common };
    return sw;
}
