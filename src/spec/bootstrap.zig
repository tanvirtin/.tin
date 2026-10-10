const std = @import("std");
const Schema = @import("ir.zig").Schema;
const Kind = @import("ir.zig").Kind;
const FieldDef = @import("ir.zig").Field;
const ObjectSchema = @import("ir.zig").ObjectSchema;
const SeqSchema = @import("ir.zig").SeqSchema;

pub fn get(allocator: std.mem.Allocator) !Schema {
    const string_schema = try allocator.create(Schema);
    string_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };

    const any_schema = try allocator.create(Schema);
    any_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .any }, .refinements = &.{}, .contexts = null };

    const field_item_schema = try fieldDefSchema(allocator, any_schema, string_schema);

    {
        const field_seq = try allocator.create(SeqSchema);
        field_seq.* = SeqSchema{ .items = field_item_schema, .min_items = null, .max_items = null };

        const fields_field = FieldDef{
            .name = "fields",
            .schema = try wrapSchema(allocator, Kind{ .sequence = field_seq }),
            .required = false,
            .optional = true,
        };

        const bootstrap_fields = try allocator.alloc(FieldDef, 29);
        bootstrap_fields[0] = FieldDef{ .name = "type", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[1] = FieldDef{ .name = "value", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[2] = FieldDef{ .name = "values", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[3] = FieldDef{ .name = "items", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[4] = FieldDef{ .name = "keys", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[5] = FieldDef{ .name = "values_schema", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[6] = fields_field;
        bootstrap_fields[7] = FieldDef{ .name = "additional", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[8] = FieldDef{ .name = "schemas", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[9] = FieldDef{ .name = "path", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[10] = FieldDef{ .name = "kind", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[11] = FieldDef{ .name = "field", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[12] = FieldDef{ .name = "variants", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[13] = FieldDef{ .name = "on", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[14] = FieldDef{ .name = "cases", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[15] = FieldDef{ .name = "common", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[16] = FieldDef{ .name = "min_items", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[17] = FieldDef{ .name = "max_items", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[18] = FieldDef{ .name = "min_properties", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[19] = FieldDef{ .name = "max_properties", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[20] = FieldDef{ .name = "pattern", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[21] = FieldDef{ .name = "min_length", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[22] = FieldDef{ .name = "max_length", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[23] = FieldDef{ .name = "ref_to", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[24] = FieldDef{ .name = "refinements", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[25] = FieldDef{ .name = "sublang", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[26] = FieldDef{ .name = "contexts", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields[27] = FieldDef{ .name = "decl_as", .schema = string_schema, .required = false, .optional = true };
        bootstrap_fields[28] = FieldDef{ .name = "push_scope", .schema = string_schema, .required = false, .optional = true };

        const bootstrap_fields_final = try allocator.alloc(FieldDef, 32);
        @memcpy(bootstrap_fields_final[0..29], bootstrap_fields);
        bootstrap_fields_final[26] = FieldDef{ .name = "required", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields_final[27] = FieldDef{ .name = "optional", .schema = any_schema, .required = false, .optional = true };
        bootstrap_fields_final[28] = FieldDef{ .name = "definitions", .schema = any_schema, .required = false, .optional = true };

        const obj_schema = try allocator.create(ObjectSchema);
        obj_schema.* = ObjectSchema{ .fields = bootstrap_fields_final, .additional = .{ .allow = {} }, .min_properties = null, .max_properties = null };

        return Schema{
            .span = undefined,
            .kind = .{ .object = obj_schema },
            .refinements = &.{},
            .contexts = null,
        };
    }
}

fn wrapSchema(allocator: std.mem.Allocator, kind: Kind) !*Schema {
    const s = try allocator.create(Schema);
    s.* = Schema{ .span = undefined, .kind = kind, .refinements = &.{}, .contexts = null };
    return s;
}

fn fieldDefSchema(allocator: std.mem.Allocator, any_schema: *Schema, string_schema: *Schema) !*Schema {
    const name_field = FieldDef{
        .name = "name",
        .schema = string_schema,
        .required = true,
        .optional = false,
    };
    const type_field = FieldDef{
        .name = "type",
        .schema = any_schema,
        .required = true,
        .optional = false,
    };
    const required_field = FieldDef{
        .name = "required",
        .schema = any_schema,
        .required = false,
        .optional = true,
    };
    const optional_field = FieldDef{
        .name = "optional",
        .schema = any_schema,
        .required = false,
        .optional = true,
    };

    const field_fields = try allocator.alloc(FieldDef, 4);
    field_fields[0] = name_field;
    field_fields[1] = type_field;
    field_fields[2] = required_field;
    field_fields[3] = optional_field;

    const field_obj = try allocator.create(ObjectSchema);
    field_obj.* = ObjectSchema{ .fields = field_fields, .additional = .{ .allow = {} }, .min_properties = null, .max_properties = null };

    return try wrapSchema(allocator, Kind{ .object = field_obj });
}

test "get returns bootstrap schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try get(arena.allocator());
    try std.testing.expect(s.kind == .object);
}
