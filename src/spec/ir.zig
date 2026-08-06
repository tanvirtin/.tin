const std = @import("std");
const Span = @import("diagnostic.zig").Span;

pub const ReferenceKind = []const u8;

pub const Primitive = enum {
    string,
    integer,
    number,
    boolean,
    null_t,
    any,
};

pub const ConstValue = union(enum) {
    string: []const u8,
    integer: i64,
    number: f64,
    boolean: bool,
    null_t: void,
};

pub const SeqSchema = struct {
    items: *Schema,
    min_items: ?usize,
    max_items: ?usize,
};

pub const MapSchema = struct {
    keys: *Schema,
    values: *Schema,
};

pub const Field = struct {
    name: []const u8,
    schema: *Schema,
    required: bool,
    optional: bool,
};

pub const Additional = union(enum) {
    forbid: void,
    allow: void,
    schema: *Schema,
};

pub const ObjectSchema = struct {
    fields: []const Field,
    additional: Additional,
    min_properties: ?usize,
    max_properties: ?usize,
    dependencies: []const FieldDependency = &.{},
};

pub const FieldDependency = struct {
    field: []const u8,
    requires: []const []const u8,
};

pub const SchemaRef = struct {
    path: []const u8,
};

pub const DiscriminatedByTag = struct {
    field: []const u8,
    variants: std.StringHashMap(*Schema),
};

pub const DiscriminatedByPresence = struct {
    fields: std.StringHashMap(*Schema),
};

pub const DiscriminatedUnion = union(enum) {
    by_tag: DiscriminatedByTag,
    by_presence: DiscriminatedByPresence,
};

pub const SwitchCase = struct {
    value: []const u8,
    schema: *Schema,
};

pub const SwitchSchema = struct {
    on: []const u8,
    cases: []const SwitchCase,
    common: ?*Schema,
};

pub const PathRef = struct {
    path: []const u8,
    kind: []const u8,
    catalog: ?[]const u8 = null,
};

pub const SublangSchema = struct {
    grammar: []const u8,
    contexts: ?[]const []const u8,
    proxy: ?[]const u8 = null,
};

pub const StringConstraints = struct {
    pattern: ?[]const u8 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
};

pub const Refinement = union(enum) {
    forbid_pair: [2][]const u8,
    require_one_of: [][]const u8,
    require_at_least: usize,
};

pub const ContextDecl = struct {
    map: std.StringHashMap(*Schema),
};

pub const Kind = union(enum) {
    primitive: Primitive,
    constant: ConstValue,
    enum_of: []ConstValue,
    sequence: *SeqSchema,
    mapping: *MapSchema,
    object: *ObjectSchema,
    any_of: []*Schema,
    all_of: []*Schema,
    not: *Schema,
    ref: SchemaRef,
    discriminated: *DiscriminatedUnion,
    switch_on: *SwitchSchema,
    path_ref: PathRef,
    sublang: SublangSchema,
};

pub const Schema = struct {
    span: Span,
    kind: Kind,
    refinements: []const Refinement,
    contexts: ?ContextDecl,
    string_constraints: ?StringConstraints = null,
    ref_to: ?PathRef = null,
    decl_as: ?[]const u8 = null,
    push_scope: ?ReferenceKind = null,
};
