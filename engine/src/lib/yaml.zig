const std = @import("std");
const scanner_mod = @import("yaml/scanner.zig");
const parser_mod = @import("yaml/parser.zig");
const composer_mod = @import("yaml/composer.zig");
const value_mod = @import("yaml/value.zig");
const decode_mod = @import("yaml/decode.zig");

const Tree = value_mod.Tree;

pub const Value = value_mod.Value;
pub const DecodeError = decode_mod.DecodeError;
pub const SourceMap = @import("yaml/token.zig").SourceMap;

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
    errdefer {
        for (tokens) |t| {
            if (t.value) |v| {
                const vp = @intFromPtr(v.ptr);
                const sp = @intFromPtr(mutable.ptr);
                if (vp < sp or vp >= sp + mutable.len) allocator.free(v);
            }
            if (t.source_map) |sm| allocator.free(sm.entries);
        }
        allocator.free(tokens);
    }

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

test "source map: basic plain" {
    const allocator = std.testing.allocator;
    const source = "run: echo hello";
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("echo hello", parsed);
    try std.testing.expectEqual(@as(u32, 5), map.map(0));
    try std.testing.expectEqual(@as(u32, 14), map.map(9));
}

test "source map: single quoted with escape" {
    const allocator = std.testing.allocator;
    const source = "run: 'can''t stop'";
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("can't stop", parsed);
    try std.testing.expectEqual(@as(u32, 6), map.map(0));
    try std.testing.expectEqual(@as(u32, 11), map.map(4));
}

test "source map: double quoted with escapes" {
    const allocator = std.testing.allocator;
    const source = "run: \"line\\nnext\"";
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("line\nnext", parsed);
    try std.testing.expectEqual(@as(u32, 6), map.map(0));
    try std.testing.expectEqual(@as(u32, 10), map.map(4));
    try std.testing.expectEqual(@as(u32, 12), map.map(5));
}

test "source map: literal block" {
    const allocator = std.testing.allocator;
    const source =
        \\run: |
        \\  first
        \\  second
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("first\nsecond\n", parsed);
    try std.testing.expectEqual(@as(u32, 9), map.map(0));
    try std.testing.expectEqual(@as(u32, 14), map.map(5));
    try std.testing.expectEqual(@as(u32, 17), map.map(6));
}

test "source map: folded block" {
    const allocator = std.testing.allocator;
    const source =
        \\run: >
        \\  line1
        \\
        \\  line2
    ;
    var doc = try parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("line1\n\nline2\n", parsed);
    try std.testing.expectEqual(@as(u32, 9), map.map(0));
    try std.testing.expectEqual(@as(u32, 14), map.map(5));
    try std.testing.expectEqual(@as(u32, 15), map.map(6));
    try std.testing.expectEqual(@as(u32, 18), map.map(7));
}

test "parse accepts escaped tab and tab separated values" {
    var doc = try parse(std.testing.allocator, "key: \"a\\\tb\"\nother:\tvalue\n");
    defer doc.deinit();

    try std.testing.expectEqualStrings("a\tb", doc.value.get("key").?.getString().?);
    try std.testing.expectEqualStrings("value", doc.value.get("other").?.getString().?);
}

test "parse accepts flow mapping key with value indicator on next line" {
    var doc = try parse(std.testing.allocator, "{foo\n: bar}\n");
    defer doc.deinit();

    try std.testing.expectEqualStrings("bar", doc.value.get("foo").?.getString().?);
}

test "parse rejects flow sequence key with value indicator on next line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidYaml, parse(arena.allocator(), "[foo\n: bar]\n"));
}

test "parse accepts tab-only line before document start" {
    var doc = try parse(std.testing.allocator, "%YAML 1.2\n\t\n---\n");
    defer doc.deinit();
}

test "parse rejects flow sequence key with line break before value indicator" {
    try std.testing.expectError(error.InvalidYaml, parse(std.testing.allocator, "[ \"a\"\n: b ]\n"));
}

test "parse accepts multi-line implicit key in flow mapping" {
    var doc = try parse(std.testing.allocator, "{ a\n  b: c }\n");
    defer doc.deinit();

    try std.testing.expectEqualStrings("c", doc.value.get("a b").?.getString().?);
}

test "parse rejects invalid inputs without leaking scanner allocations" {
    const bad_inputs = [_][]const u8{
        "a: [b\n",
        "a: {b: c\n",
        "key: \"unterminated\n",
        "key: 'unterminated\n",
        "a: {b: [c}\n",
        "[foo\n: bar]\n",
        "[ \"a\"\n: b ]\n",
        "[ {a: b}, c\n  d: e ]\n",
        "a: !e!x b\n",
        "a: &x &y b\n",
    };
    for (bad_inputs) |input| {
        if (parse(std.testing.allocator, input)) |doc| {
            var d = doc;
            d.deinit();
            return error.ExpectedInvalid;
        } else |_| {}
    }
}
