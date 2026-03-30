const std = @import("std");
const scanner_mod = @import("yaml/scanner.zig");
const parser_mod = @import("yaml/parser.zig");
const composer_mod = @import("yaml/composer.zig");
const value_mod = @import("yaml/value.zig");
const decode_mod = @import("yaml/decode.zig");

pub const Value = value_mod.Value;
pub const Entry = value_mod.Entry;
pub const ParseError = value_mod.ParseError;
pub const DecodeError = decode_mod.DecodeError;
pub const decode = decode_mod.decode;

pub fn parse(allocator: std.mem.Allocator, input: []const u8) ParseError!Value {
    var scanner = scanner_mod.Scanner{ .alloc = allocator, .src = input };
    const tokens = try scanner.scan();

    if (tokens.len <= 2) return .{ .scalar = "" };

    var parser = parser_mod.Parser{ .tokens = tokens };
    try parser.validate();

    var composer = composer_mod.Composer.init(allocator, tokens);
    return composer.compose();
}

test "simple mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "name: git\ndescription: Configure git");
    try std.testing.expectEqualStrings("git", r.getMapping("name").?.getString().?);
    try std.testing.expectEqualStrings("Configure git", r.getMapping("description").?.getString().?);
}

test "nested mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "server:\n  host: localhost\n  port: 8080");
    const s = r.getMapping("server").?;
    try std.testing.expectEqualStrings("localhost", s.getMapping("host").?.getString().?);
}

test "sequence of scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "items:\n  - alpha\n  - beta\n  - gamma");
    const seq = r.getMapping("items").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 3), seq.len);
    try std.testing.expectEqualStrings("alpha", seq[0].getString().?);
}

test "sequence of mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "steps:\n  - name: s1\n    run: echo hi\n  - name: s2\n    install: tmux");
    const seq = r.getMapping("steps").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("s1", seq[0].getMapping("name").?.getString().?);
    try std.testing.expectEqualStrings("echo hi", seq[0].getMapping("run").?.getString().?);
}

test "literal block scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "run: |\n  line 1\n  line 2\n");
    try std.testing.expectEqualStrings("line 1\nline 2\n", r.getMapping("run").?.getString().?);
}

test "block scalar strip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "run: |-\n  hello\n");
    try std.testing.expectEqualStrings("hello", r.getMapping("run").?.getString().?);
}

test "flow sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "items: [a, b, c]");
    const seq = r.getMapping("items").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 3), seq.len);
    try std.testing.expectEqualStrings("a", seq[0].getString().?);
}

test "flow mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "p: {name: John, age: 30}");
    const p = r.getMapping("p").?;
    try std.testing.expectEqualStrings("John", p.getMapping("name").?.getString().?);
}

test "single quoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: 'hello'");
    try std.testing.expectEqualStrings("hello", r.getMapping("v").?.getString().?);
}

test "double quoted escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: \"a\\nb\"");
    try std.testing.expectEqualStrings("a\nb", r.getMapping("v").?.getString().?);
}

test "anchor and alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a: &val hello\nb: *val");
    try std.testing.expectEqualStrings("hello", r.getMapping("a").?.getString().?);
    try std.testing.expectEqualStrings("hello", r.getMapping("b").?.getString().?);
}

test "document markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "---\nname: test\n...");
    try std.testing.expectEqualStrings("test", r.getMapping("name").?.getString().?);
}

test "colon in url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "url: https://example.com");
    try std.testing.expectEqualStrings("https://example.com", r.getMapping("url").?.getString().?);
}

test "comment handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "# comment\nname: test  # inline");
    try std.testing.expectEqualStrings("test", r.getMapping("name").?.getString().?);
}

test "empty document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "");
    try std.testing.expectEqualStrings("", r.getString().?);
}

test "recipe format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "name: git\ndescription: test\n\nsteps:\n  - name: s1\n    run: echo hi\n    if: os == 'darwin'\n");
    try std.testing.expectEqualStrings("git", r.getMapping("name").?.getString().?);
    const steps = r.getMapping("steps").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 1), steps.len);
    try std.testing.expectEqualStrings("os == 'darwin'", steps[0].getMapping("if").?.getString().?);
}

test "reject nested implicit mapping on same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "a: b: c: d"));
}

test "reject mapping after sequence at same level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "- item1\n- item2\ninvalid: x"));
}

test "reject two root nodes without document marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "word1  # comment\nword2"));
}

test "reject block entry after value indicator on same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "key: - a\n     - b"));
}

test "reject dash in flow sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "[-]"));
}

test "reject comma in block context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "- !!str, xxx"));
}

test "reject flow content below block indent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "---\nflow: [a,\nb,\nc]"));
}

test "reject mapping on document start line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "--- key1: value1\n    key2: value2"));
}

test "reject multiple anchors on same node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "top1: &node1\n  &k1 key1: val1\ntop2: &node2\n  &v2 val2"));
}

test "reject anchor before block entry on same line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.InvalidYaml, parse(arena.allocator(), "&anchor - sequence entry"));
}

test "folded block scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "msg: >\n  first\n  second\n");
    try std.testing.expectEqualStrings("first second\n", r.getMapping("msg").?.getString().?);
}

test "block scalar keep chomping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "msg: |+\n  line\n\n\n");
    try std.testing.expectEqualStrings("line\n\n\n", r.getMapping("msg").?.getString().?);
}

test "plain multiline scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "key:\n  hello\n  world");
    try std.testing.expectEqualStrings("hello world", r.getMapping("key").?.getString().?);
}

test "plain scalar with blank line preserved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "key:\n  first\n\n  second");
    try std.testing.expectEqualStrings("first\nsecond", r.getMapping("key").?.getString().?);
}

test "nested flow collections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "m: {a: [1, 2], b: {x: y}}");
    const m = r.getMapping("m").?;
    const a = m.getMapping("a").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("y", m.getMapping("b").?.getMapping("x").?.getString().?);
}

test "flow mapping trailing comma" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "{a: 1, b: 2,}");
    try std.testing.expectEqualStrings("1", r.getMapping("a").?.getString().?);
}

test "empty flow collections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a: []\nb: {}");
    try std.testing.expectEqual(@as(usize, 0), r.getMapping("a").?.getSequence().?.len);
    try std.testing.expect(r.getMapping("b").?.getMapping("__nonexistent__") == null);
}

test "explicit key with value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "? key\n: value");
    try std.testing.expectEqualStrings("value", r.getMapping("key").?.getString().?);
}

test "explicit key with sequence value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "? key\n: - a\n  - b");
    const seq = r.getMapping("key").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
}

test "single quoted with escaped quote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: 'it''s'");
    try std.testing.expectEqualStrings("it's", r.getMapping("v").?.getString().?);
}

test "double quoted unicode escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: \"\\x41\"");
    try std.testing.expectEqualStrings("A", r.getMapping("v").?.getString().?);
}

test "double quoted null escape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: \"\\0\"");
    try std.testing.expectEqual(@as(u8, 0), r.getMapping("v").?.getString().?[0]);
}

test "tag on scalar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: !!str 42");
    try std.testing.expectEqualStrings("42", r.getMapping("v").?.getString().?);
}

test "multiple documents returns last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "---\na: 1\n---\nb: 2");
    try std.testing.expectEqualStrings("2", r.getMapping("b").?.getString().?);
}

test "anchor on sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a: &items\n  - x\n  - y\nb: *items");
    const seq = r.getMapping("b").?.getSequence().?;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("x", seq[0].getString().?);
}

test "anchor on mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a: &ref\n  x: 1\nb: *ref");
    try std.testing.expectEqualStrings("1", r.getMapping("b").?.getMapping("x").?.getString().?);
}

test "tab in value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "v: \"a\\tb\"");
    try std.testing.expectEqualStrings("a\tb", r.getMapping("v").?.getString().?);
}

test "colon in flow mapping value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "{url: https://example.com}");
    try std.testing.expectEqualStrings("https://example.com", r.getMapping("url").?.getString().?);
}

test "empty values in mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "a:\nb: value");
    try std.testing.expectEqualStrings("", r.getMapping("a").?.getString().?);
    try std.testing.expectEqualStrings("value", r.getMapping("b").?.getString().?);
}

test "empty sequence entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "-\n- value\n-");
    const seq = r.getSequence().?;
    try std.testing.expectEqual(@as(usize, 3), seq.len);
    try std.testing.expectEqualStrings("value", seq[1].getString().?);
}
