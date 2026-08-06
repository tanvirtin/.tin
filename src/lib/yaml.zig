const std = @import("std");
const scanner_mod = @import("yaml/scanner.zig");
const parser_mod = @import("yaml/parser.zig");
const composer_mod = @import("yaml/composer.zig");
const value_mod = @import("yaml/value.zig");
const decode_mod = @import("yaml/decode.zig");
pub const token = @import("yaml/token.zig");

pub const Value = value_mod.Value;
pub const Tree = value_mod.Tree;
pub const Node = value_mod.Node;
pub const Tag = value_mod.Tag;
pub const ParseError = value_mod.ParseError;
pub const DecodeError = decode_mod.DecodeError;
pub const SourceMap = token.SourceMap;

pub const DocNode = struct {
    value: Value,
    arena: *std.heap.ArenaAllocator,
    source: []u8,

    pub fn deinit(self: *DocNode) void {
        var t = @constCast(self.value.tree);
        t.deinit(self.arena.child_allocator);
        self.arena.child_allocator.free(self.source);
        const a = self.arena;
        a.deinit();
        a.child_allocator.destroy(a);
    }

    pub fn getMapping(self: DocNode, key: []const u8) ?Value {
        return self.value.getMapping(key);
    }

    pub fn getString(self: DocNode) ?[]const u8 {
        return self.value.getString();
    }

    pub fn getSequence(self: DocNode) ?[]const Value {
        return self.value.getSequence();
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !DocNode {
    const mutable = try allocator.dupe(u8, input);
    errdefer allocator.free(mutable);
    
    var arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var scanner = scanner_mod.Scanner{ .alloc = allocator, .src = mutable };
    const tokens = try scanner.scan();

    var parser = parser_mod.Parser{ .tokens = tokens };
    try parser.validate();

    var tree = try Tree.init(allocator, mutable);
    errdefer tree.deinit(allocator);

    var composer = composer_mod.Composer.init(allocator, tokens, mutable, tree);
    defer composer.deinit();
    try composer.compose();
    tree.tokens = tokens;

    const root_value = Value{ .tree = tree, .idx = 0, .arena = arena };
    return .{ .value = root_value, .arena = arena, .source = mutable };
}

pub fn decode(comptime T: type, allocator: std.mem.Allocator, doc: DocNode) DecodeError!T {
    return decode_mod.decode(T, allocator, doc.value);
}

pub fn decodeValue(comptime T: type, allocator: std.mem.Allocator, val: Value) DecodeError!T {
    return decode_mod.decode(T, allocator, val);
}

test {
    _ = @import("yaml/source_map.test.zig");
}
