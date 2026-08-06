const std = @import("std");

pub const Node = union(enum) {
    literal: Literal,
    variable: Variable,
    unary: Unary,
    binary: Binary,
    index: Index,
    call: Call,

    pub const Literal = union(enum) {
        string: []const u8,
        number: f64,
        boolean: bool,
        null_t,
    };

    pub const Variable = struct {
        name: []const u8,
    };

    pub const Unary = struct {
        op: UnaryOp,
        expr: *Node,
    };

    pub const UnaryOp = enum {
        not,
    };

    pub const Binary = struct {
        op: BinaryOp,
        left: *Node,
        right: *Node,
    };

    pub const BinaryOp = enum {
        eq,
        neq,
        lt,
        lte,
        gt,
        gte,
        and_op,
        or_op,
    };

    pub const Index = struct {
        expr: *Node,
        index: *Node,
    };

    pub const Call = struct {
        func: []const u8,
        args: []Node,
    };
};
