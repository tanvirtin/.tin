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

pub const CompileError = error{
    InvalidSchema,
    UnknownType,
    NotImplemented,
    OutOfMemory,
};

fn spanFromValue(value: yaml.Value) Span {
    if (value.idx >= value.tree.nodes.items.len)
        return Span{ .file_id = 0, .start = 0, .end = 0 };
    const node = value.tree.nodes.items[value.idx];
    return Span{ .file_id = 0, .start = node.start, .end = node.end };
}

fn spanFromNode(node: *const yaml.DocNode) Span {
    return spanFromValue(node.value);
}

fn parsePrimitive(s: []const u8) CompileError!Primitive {
    if (std.mem.eql(u8, s, "string")) return .string;
    if (std.mem.eql(u8, s, "integer")) return .integer;
    if (std.mem.eql(u8, s, "number")) return .number;
    if (std.mem.eql(u8, s, "boolean")) return .boolean;
    if (std.mem.eql(u8, s, "null")) return .null_t;
    if (std.mem.eql(u8, s, "any")) return .any;
    return error.UnknownType;
}

fn isPrimitive(s: []const u8) bool {
    return parsePrimitive(s) != error.UnknownType;
}

fn compileConstValue(allocator: std.mem.Allocator, value: yaml.Value) CompileError!ConstValue {
    const s = value.getString() orelse return error.InvalidSchema;

    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "~")) return .{ .null_t = {} };
    if (std.fmt.parseInt(i64, s, 10)) |i| return .{ .integer = i } else |_| {}
    if (std.fmt.parseFloat(f64, s)) |f| return .{ .number = f } else |_| {}

    const duped = try allocator.dupe(u8, s);
    return .{ .string = duped };
}

fn compileSchemaValue(allocator: std.mem.Allocator, value: yaml.Value, span: Span) CompileError!Schema {
    const kind = try compileKind(allocator, value);
    const refinements = try compileRefinements(allocator, value);
    const string_constraints = try compileStringConstraints(allocator, value);

    var ref_to: ?schema_mod.PathRef = null;
    if (value.get("ref_to")) |rt| {
        const path_val = rt.get("path") orelse return error.InvalidSchema;
        const path_str = path_val.getString() orelse return error.InvalidSchema;
        const kind_val = rt.get("kind") orelse return error.InvalidSchema;
        const kind_str = kind_val.getString() orelse return error.InvalidSchema;
        const catalog_val = rt.get("catalog");
        const catalog_str = if (catalog_val) |cv| try allocator.dupe(u8, cv.getString() orelse return error.InvalidSchema) else null;
        ref_to = .{
            .path = try allocator.dupe(u8, path_str),
            .kind = try allocator.dupe(u8, kind_str),
            .catalog = catalog_str,
        };
    }

    var decl_as: ?[]const u8 = null;
    if (value.get("decl_as")) |da| {
        const da_str = da.getString() orelse return error.InvalidSchema;
        decl_as = try allocator.dupe(u8, da_str);
    }

    var push_scope: ?schema_mod.ReferenceKind = null;
    if (value.get("push_scope")) |ps| {
        const ps_str = ps.getString() orelse return error.InvalidSchema;
        push_scope = try allocator.dupe(u8, ps_str);
    }

    var contexts: ?schema_mod.ContextDecl = null;
    if (value.get("contexts")) |ctx_val| {
        var map = std.StringHashMap(*schema_mod.Schema).init(allocator);
        const node = value.tree.nodes.items[ctx_val.idx];
        if (node.tag == .mapping) {
            var child = node.first_child;
            while (child != 0) {
                const key_node = value.tree.nodes.items[child];
                const val_idx = key_node.next_sibling;
                if (val_idx == 0) break;

                const key_str = key_node.computed_value orelse value.tree.source[key_node.start..key_node.end];
                const val = yaml.Value{ .tree = value.tree, .idx = val_idx, .arena = value.arena };

                const s = try allocator.create(schema_mod.Schema);
                s.* = try compileSchemaValue(allocator, val, spanFromValue(val));
                try map.put(try allocator.dupe(u8, key_str), s);

                child = value.tree.nodes.items[val_idx].next_sibling;
            }
        } else if (node.tag == .sequence) {
            // Legacy support: list of strings defaults to 'any' schema
            const items = ctx_val.getSequence() orelse return error.InvalidSchema;
            for (items) |item| {
                const name = item.getString() orelse return error.InvalidSchema;
                const any_s = try allocator.create(schema_mod.Schema);
                any_s.* = schema_mod.Schema{
                    .span = undefined,
                    .kind = .{ .primitive = .any },
                    .refinements = &.{},
                    .contexts = null,
                };
                try map.put(try allocator.dupe(u8, name), any_s);
            }
        }
        contexts = .{ .map = map };
    }

    return Schema{
        .span = span,
        .kind = kind,
        .refinements = refinements,
        .contexts = contexts,
        .string_constraints = string_constraints,
        .ref_to = ref_to,
        .decl_as = decl_as,
        .push_scope = push_scope,
    };
}

fn readSchema(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*Schema {
    const schema = try allocator.create(Schema);
    schema.* = try compileSchemaValue(allocator, value, spanFromValue(value));
    return schema;
}

pub fn compile(allocator: std.mem.Allocator, doc: *const yaml.DocNode) CompileError!Schema {
    return compileSchemaValue(allocator, doc.value, spanFromNode(doc));
}

pub fn compileNamed(allocator: std.mem.Allocator, doc: *const yaml.DocNode, name: []const u8) CompileError!Schema {
    _ = name;
    return compile(allocator, doc);
}

fn compileKind(allocator: std.mem.Allocator, value: yaml.Value) CompileError!Kind {
    if (value.getString()) |s| {
        return Kind{ .primitive = try parsePrimitive(s) };
    }

    const type_val = value.get("type") orelse {
        if (value.get("any_of")) |v| return .{ .any_of = try compileAnyOf(allocator, v) };
        if (value.get("all_of")) |v| return .{ .all_of = try compileAllOf(allocator, v) };
        if (value.get("enum")) |v| return .{ .enum_of = try compileEnum(allocator, v) };
        if (value.get("const")) |v| return .{ .constant = try compileConstValue(allocator, v) };
        if (value.get("ref")) |v| return .{ .ref = try compileRef(allocator, v) };
        if (value.get("discriminated")) |v| return .{ .discriminated = try compileDiscriminated(allocator, v) };
        if (value.get("switch")) |v| return .{ .switch_on = try compileSwitch(allocator, v) };
        if (value.get("sublang")) |v| return .{ .sublang = try compileSublang(allocator, v) };
        
        return error.InvalidSchema;
    };
    const type_str = type_val.getString() orelse return error.InvalidSchema;

    if (std.mem.eql(u8, type_str, "string")) return .{ .primitive = .string };
    if (std.mem.eql(u8, type_str, "integer")) return .{ .primitive = .integer };
    if (std.mem.eql(u8, type_str, "number")) return .{ .primitive = .number };
    if (std.mem.eql(u8, type_str, "boolean")) return .{ .primitive = .boolean };
    if (std.mem.eql(u8, type_str, "null")) return .{ .primitive = .null_t };
    if (std.mem.eql(u8, type_str, "any")) return .{ .primitive = .any };
    if (std.mem.eql(u8, type_str, "constant")) return .{ .constant = try compileConstant(allocator, value) };
    if (std.mem.eql(u8, type_str, "enum")) return .{ .enum_of = try compileEnum(allocator, value) };
    if (std.mem.eql(u8, type_str, "sequence")) return .{ .sequence = try compileSequence(allocator, value) };
    if (std.mem.eql(u8, type_str, "mapping")) return .{ .mapping = try compileMapping(allocator, value) };
    if (std.mem.eql(u8, type_str, "object")) return .{ .object = try compileObject(allocator, value) };
    if (std.mem.eql(u8, type_str, "any_of")) return .{ .any_of = try compileAnyOf(allocator, value) };
    if (std.mem.eql(u8, type_str, "all_of")) return .{ .all_of = try compileAllOf(allocator, value) };
    if (std.mem.eql(u8, type_str, "not")) return .{ .not = try compileNot(allocator, value) };
    if (std.mem.eql(u8, type_str, "ref")) return .{ .ref = try compileRef(allocator, value) };
    if (std.mem.eql(u8, type_str, "discriminated")) return .{ .discriminated = try compileDiscriminated(allocator, value) };
    if (std.mem.eql(u8, type_str, "switch")) return .{ .switch_on = try compileSwitch(allocator, value) };
    if (std.mem.eql(u8, type_str, "path_ref")) return .{ .path_ref = try compilePathRef(allocator, value) };
    if (std.mem.eql(u8, type_str, "sublang")) return .{ .sublang = try compileSublang(allocator, value) };

    return error.UnknownType;
}

fn compilePrimitive(value: yaml.Value) CompileError!Primitive {
    const s = value.getString() orelse return error.InvalidSchema;
    return parsePrimitive(s);
}

fn compileConstant(allocator: std.mem.Allocator, value: yaml.Value) CompileError!ConstValue {
    const val = value.get("value") orelse return error.InvalidSchema;
    return compileConstValue(allocator, val);
}

fn compileEnum(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]ConstValue {
    const values_val = value.get("values") orelse return error.InvalidSchema;
    const items = values_val.getSequence() orelse return error.InvalidSchema;

    var result = try allocator.alloc(ConstValue, items.len);
    for (items, 0..) |item, i| {
        result[i] = try compileConstValue(allocator, item);
    }
    return result;
}

fn compileSequence(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*SeqSchema {
    const items_val = value.get("items") orelse return error.InvalidSchema;
    const items = try readSchema(allocator, items_val);

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

fn compileMapping(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*MapSchema {
    const values_val = value.get("values") orelse return error.InvalidSchema;
    const values = try readSchema(allocator, values_val);

    var keys: *Schema = undefined;
    if (value.get("keys")) |keys_val| {
        keys = try readSchema(allocator, keys_val);
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

fn compileObject(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*ObjectSchema {
    const fields = if (value.get("fields")) |fv| blk: {
        const seq = fv.getSequence() orelse return error.InvalidSchema;
        var result = try allocator.alloc(Field, seq.len);
        for (seq, 0..) |item, i| {
            const name_val = item.get("name") orelse return error.InvalidSchema;
            const name = name_val.getString() orelse return error.InvalidSchema;
            const name_dup = try allocator.dupe(u8, name);

            const field_schema = if (item.get("type")) |type_val| blk1: {
                if (type_val.getString()) |s| {
                    if (isPrimitive(s)) break :blk1 try readSchema(allocator, type_val);
                    break :blk1 try readSchema(allocator, item);
                } else {
                    break :blk1 try readSchema(allocator, type_val);
                }
            } else blk1: {
                break :blk1 try readSchema(allocator, item);
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
        break :add Additional{ .schema = try readSchema(allocator, av) };
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

fn compileSchemasList(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    const schemas_val = value.get("schemas") orelse return error.InvalidSchema;
    const seq = schemas_val.getSequence() orelse return error.InvalidSchema;

    var result = try allocator.alloc(*Schema, seq.len);
    for (seq, 0..) |item, i| {
        result[i] = try readSchema(allocator, item);
    }
    return result;
}

fn compileAnyOf(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    return compileSchemasList(allocator, value);
}

fn compileAllOf(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]*Schema {
    return compileSchemasList(allocator, value);
}

fn compileNot(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*Schema {
    const schema_val = value.get("schema") orelse return error.InvalidSchema;
    return readSchema(allocator, schema_val);
}

fn compileRef(allocator: std.mem.Allocator, value: yaml.Value) CompileError!SchemaRef {
    const path_val = value.get("path") orelse return error.InvalidSchema;
    const path = path_val.getString() orelse return error.InvalidSchema;
    const path_dup = try allocator.dupe(u8, path);
    return SchemaRef{ .path = path_dup };
}

fn compileDiscriminated(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*DiscriminatedUnion {
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
            const variant_schema = try readSchema(allocator, val);
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
            const variant_schema = try readSchema(allocator, val);
            try fields.put(key_dup, variant_schema);

            child = value.tree.nodes.items[val_idx].next_sibling;
        }

        const du = try allocator.create(DiscriminatedUnion);
        du.* = DiscriminatedUnion{ .by_presence = .{ .fields = fields } };
        return du;
    }

    return error.InvalidSchema;
}

fn compileSwitch(allocator: std.mem.Allocator, value: yaml.Value) CompileError!*SwitchSchema {
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
        const case_schema = try readSchema(allocator, schema_val);

        cases[i] = SwitchCase{ .value = case_dup, .schema = case_schema };
    }

    const common = if (value.get("common")) |cv|
        try readSchema(allocator, cv)
    else
        null;

    const sw = try allocator.create(SwitchSchema);
    sw.* = SwitchSchema{ .on = on_dup, .cases = cases, .common = common };
    return sw;
}

fn compilePathRef(allocator: std.mem.Allocator, value: yaml.Value) CompileError!PathRef {
    const path_val = value.get("path") orelse return error.InvalidSchema;
    const path = path_val.getString() orelse return error.InvalidSchema;
    const path_dup = try allocator.dupe(u8, path);

    const kind_val = value.get("kind") orelse return error.InvalidSchema;
    const kind = kind_val.getString() orelse return error.InvalidSchema;
    const kind_dup = try allocator.dupe(u8, kind);

    const catalog_val = value.get("catalog");
    const catalog_dup = if (catalog_val) |cv| try allocator.dupe(u8, cv.getString() orelse return error.InvalidSchema) else null;

    return PathRef{ .path = path_dup, .kind = kind_dup, .catalog = catalog_dup };
}

fn compileSublang(allocator: std.mem.Allocator, value: yaml.Value) CompileError!SublangSchema {
    const grammar_val = value.get("grammar") orelse return error.InvalidSchema;
    const grammar = grammar_val.getString() orelse return error.InvalidSchema;
    const grammar_dup = try allocator.dupe(u8, grammar);

    const contexts = if (value.get("contexts")) |cv| blk: {
        const seq = cv.getSequence() orelse return error.InvalidSchema;
        var result = try allocator.alloc([]const u8, seq.len);
        for (seq, 0..) |item, i| {
            const s = item.getString() orelse return error.InvalidSchema;
            result[i] = try allocator.dupe(u8, s);
        }
        break :blk result;
    } else null;

    const proxy = if (value.get("proxy")) |pv| try allocator.dupe(u8, pv.getString() orelse return error.InvalidSchema) else null;

    return SublangSchema{ .grammar = grammar_dup, .contexts = contexts, .proxy = proxy };
}

fn compileRefinements(allocator: std.mem.Allocator, value: yaml.Value) CompileError![]const Refinement {
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

fn compileStringConstraints(allocator: std.mem.Allocator, value: yaml.Value) CompileError!?StringConstraints {
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

test "compile parses string primitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "type: string");
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqual(Kind{ .primitive = .string }, s.kind);
}

test "compile parses shorthand primitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "\"integer\"");
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqual(Kind{ .primitive = .integer }, s.kind);
}

test "compile parses object with fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: object
        \\fields:
        \\  - name: foo
        \\    type: string
        \\  - name: bar
        \\    type: integer
        \\    required: false
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const obj = s.kind.object;
    try std.testing.expectEqual(@as(usize, 2), obj.fields.len);
    try std.testing.expectEqualStrings("foo", obj.fields[0].name);
    try std.testing.expectEqual(Kind{ .primitive = .string }, obj.fields[0].schema.kind);
    try std.testing.expect(obj.fields[0].required);
    try std.testing.expectEqualStrings("bar", obj.fields[1].name);
    try std.testing.expect(!obj.fields[1].required);
}

test "compile parses sequence with items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: sequence
        \\items:
        \\  type: number
        \\min_items: 1
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const seq = s.kind.sequence;
    try std.testing.expectEqual(Kind{ .primitive = .number }, seq.items.kind);
    try std.testing.expectEqual(@as(usize, 1), seq.min_items.?);
}

test "compile parses mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: mapping
        \\keys:
        \\  type: string
        \\values:
        \\  type: boolean
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const map = s.kind.mapping;
    try std.testing.expectEqual(Kind{ .primitive = .string }, map.keys.kind);
    try std.testing.expectEqual(Kind{ .primitive = .boolean }, map.values.kind);
}

test "compileNamed returns equivalent schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "type: string");
    defer doc.deinit();
    const s = try compileNamed(arena.allocator(), &doc, "MyType");
    try std.testing.expectEqual(Kind{ .primitive = .string }, s.kind);
}

test "compile rejects unknown type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "type: bogus");
    defer doc.deinit();
    try std.testing.expectError(error.UnknownType, compile(arena.allocator(), &doc));
}

test "compile rejects missing type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(), "something: else");
    defer doc.deinit();
    try std.testing.expectError(error.InvalidSchema, compile(arena.allocator(), &doc));
}

test "compile parses ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: ref
        \\path: "#/definitions/Foo"
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqualStrings("#/definitions/Foo", s.kind.ref.path);
}

test "compile parses enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: enum
        \\values:
        \\  - a
        \\  - 42
        \\  - true
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const items = s.kind.enum_of;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("a", items[0].string);
    try std.testing.expectEqual(@as(i64, 42), items[1].integer);
    try std.testing.expectEqual(true, items[2].boolean);
}

test "compile parses any_of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: any_of
        \\schemas:
        \\  - type: string
        \\  - type: integer
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const schemas = s.kind.any_of;
    try std.testing.expectEqual(@as(usize, 2), schemas.len);
    try std.testing.expectEqual(Kind{ .primitive = .string }, schemas[0].kind);
    try std.testing.expectEqual(Kind{ .primitive = .integer }, schemas[1].kind);
}

test "compile parses nested object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: object
        \\fields:
        \\  - name: nested
        \\    type:
        \\      type: object
        \\      fields:
        \\        - name: x
        \\          type: string
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const obj = s.kind.object;
    try std.testing.expectEqual(@as(usize, 1), obj.fields.len);
    try std.testing.expectEqualStrings("nested", obj.fields[0].name);
    const nested_obj = obj.fields[0].schema.kind.object;
    try std.testing.expectEqual(@as(usize, 1), nested_obj.fields.len);
    try std.testing.expectEqualStrings("x", nested_obj.fields[0].name);
}

test "compile parses constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: constant
        \\value: hello
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqualStrings("hello", s.kind.constant.string);
}

test "compile parses constant integer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: constant
        \\value: 42
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqual(@as(i64, 42), s.kind.constant.integer);
}

test "compile parses object with min_properties and max_properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: object
        \\fields:
        \\  - name: foo
        \\    type: string
        \\min_properties: 1
        \\max_properties: 5
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const obj = s.kind.object;
    try std.testing.expectEqual(@as(usize, 1), obj.min_properties.?);
    try std.testing.expectEqual(@as(usize, 5), obj.max_properties.?);
}

test "compile parses not schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: not
        \\schema:
        \\  type: string
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expect(s.kind == .not);
    try std.testing.expectEqual(Kind{ .primitive = .string }, s.kind.not.kind);
}

test "compile parses string with constraints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: string
        \\min_length: 1
        \\max_length: 100
        \\pattern: "^[a-z]+$"
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    try std.testing.expectEqual(Kind{ .primitive = .string }, s.kind);
    const sc = s.string_constraints.?;
    try std.testing.expectEqual(@as(usize, 1), sc.min_length.?);
    try std.testing.expectEqual(@as(usize, 100), sc.max_length.?);
    try std.testing.expectEqualStrings("^[a-z]+$", sc.pattern.?);
}

test "compile parses object with dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var doc = try yaml.parse(arena.allocator(),
        \\type: object
        \\fields:
        \\  - name: run
        \\    type: string
        \\  - name: shell
        \\    type: string
        \\    required: false
        \\dependencies:
        \\  - field: shell
        \\    requires: [run]
    );
    defer doc.deinit();
    const s = try compile(arena.allocator(), &doc);
    const obj = s.kind.object;
    try std.testing.expectEqual(@as(usize, 1), obj.dependencies.len);
    try std.testing.expectEqualStrings("shell", obj.dependencies[0].field);
    try std.testing.expectEqual(@as(usize, 1), obj.dependencies[0].requires.len);
    try std.testing.expectEqualStrings("run", obj.dependencies[0].requires[0]);
}
