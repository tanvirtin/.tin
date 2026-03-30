const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const Entry = value_mod.Entry;
const ParseError = value_mod.ParseError;

pub const DecodeError = error{
    InvalidYaml,
    OutOfMemory,
    TypeMismatch,
    MissingField,
};

/// Decode a YAML Value tree into a Zig struct.
///
/// Supports:
///   - Structs with scalar fields ([]const u8, bool, integers, floats, enums)
///   - Optional fields (?T) — missing keys produce null
///   - Slices of structs ([]const T) — decoded from YAML sequences
///   - Slices of scalars ([]const []const u8) — decoded from YAML sequences
///   - Nested structs — decoded from YAML mappings
///
/// Example:
///   const Config = struct { name: []const u8, port: u16 };
///   const cfg = try yaml.decode(Config, allocator, value);
pub fn decode(comptime T: type, allocator: std.mem.Allocator, val: Value) DecodeError!T {
    return decodeValue(T, allocator, val);
}

fn decodeValue(comptime T: type, allocator: std.mem.Allocator, val: Value) DecodeError!T {
    const info = @typeInfo(T);

    // Optional: unwrap and decode inner type, null if missing
    if (info == .optional) {
        return decodeValue(info.optional.child, allocator, val) catch return null;
    }

    // String
    if (T == []const u8) {
        return val.getString() orelse return DecodeError.TypeMismatch;
    }

    // Bool
    if (T == bool) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off")) return false;
        return DecodeError.TypeMismatch;
    }

    // Integer
    if (info == .int) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.fmt.parseInt(T, s, 10) catch return DecodeError.TypeMismatch;
    }

    // Float
    if (info == .float) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.fmt.parseFloat(T, s) catch return DecodeError.TypeMismatch;
    }

    // Enum
    if (info == .@"enum") {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.meta.stringToEnum(T, s) orelse return DecodeError.TypeMismatch;
    }

    // Slice (sequence)
    if (info == .pointer and info.pointer.size == .slice and info.pointer.is_const) {
        const Child = info.pointer.child;

        // []const u8 is handled above as string
        if (Child == u8) {
            return val.getString() orelse return DecodeError.TypeMismatch;
        }

        const seq = val.getSequence() orelse return DecodeError.TypeMismatch;
        var items: std.ArrayList(Child) = .{};
        for (seq) |item| {
            const decoded = try decodeValue(Child, allocator, item);
            items.append(allocator, decoded) catch return DecodeError.OutOfMemory;
        }
        return items.items;
    }

    // Struct (mapping)
    if (info == .@"struct") {
        const mapping = switch (val) {
            .mapping => |m| m,
            else => return DecodeError.TypeMismatch,
        };
        var result: T = undefined;

        inline for (info.@"struct".fields) |field| {
            const field_val = findEntry(mapping, field.name);

            if (field_val) |fv| {
                @field(result, field.name) = try decodeValue(field.type, allocator, fv);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else if (field.default_value_ptr) |ptr| {
                const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
                @field(result, field.name) = default.*;
            } else {
                return DecodeError.MissingField;
            }
        }

        return result;
    }

    return DecodeError.TypeMismatch;
}

fn findEntry(entries: []const Entry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

// ── Tests ──

const testing = std.testing;

fn parseAndDecode(comptime T: type, allocator: std.mem.Allocator, input: []const u8) DecodeError!T {
    const parse_fn = @import("../yaml.zig").parse;
    const val = parse_fn(allocator, input) catch return DecodeError.InvalidYaml;
    return decode(T, allocator, val);
}

test "decode simple struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { name: []const u8, port: u16 };
    const cfg = try parseAndDecode(Config, arena.allocator(), "name: myapp\nport: 8080");
    try testing.expectEqualStrings("myapp", cfg.name);
    try testing.expectEqual(@as(u16, 8080), cfg.port);
}

test "decode optional fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { name: []const u8, description: ?[]const u8 };
    const cfg = try parseAndDecode(Config, arena.allocator(), "name: test");
    try testing.expectEqualStrings("test", cfg.name);
    try testing.expectEqual(@as(?[]const u8, null), cfg.description);
}

test "decode nested struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Server = struct { host: []const u8, port: u16 };
    const Config = struct { server: Server };
    const cfg = try parseAndDecode(Config, arena.allocator(), "server:\n  host: localhost\n  port: 3000");
    try testing.expectEqualStrings("localhost", cfg.server.host);
    try testing.expectEqual(@as(u16, 3000), cfg.server.port);
}

test "decode sequence of structs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Step = struct { name: []const u8, run: ?[]const u8 };
    const Recipe = struct { name: []const u8, steps: []const Step };
    const r = try parseAndDecode(Recipe, arena.allocator(),
        "name: build\nsteps:\n  - name: compile\n    run: zig build\n  - name: test\n    run: zig test",
    );
    try testing.expectEqualStrings("build", r.name);
    try testing.expectEqual(@as(usize, 2), r.steps.len);
    try testing.expectEqualStrings("compile", r.steps[0].name);
    try testing.expectEqualStrings("zig build", r.steps[0].run.?);
}

test "decode bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { debug: bool, verbose: bool };
    const cfg = try parseAndDecode(Config, arena.allocator(), "debug: true\nverbose: false");
    try testing.expect(cfg.debug);
    try testing.expect(!cfg.verbose);
}

test "decode float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { rate: f64 };
    const cfg = try parseAndDecode(Config, arena.allocator(), "rate: 3.14");
    try testing.expectApproxEqAbs(@as(f64, 3.14), cfg.rate, 0.001);
}

test "decode enum" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Level = enum { debug, info, warn };
    const Config = struct { level: Level };
    const cfg = try parseAndDecode(Config, arena.allocator(), "level: warn");
    try testing.expectEqual(Level.warn, cfg.level);
}

test "decode sequence of strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { tags: []const []const u8 };
    const cfg = try parseAndDecode(Config, arena.allocator(), "tags:\n  - alpha\n  - beta\n  - gamma");
    try testing.expectEqual(@as(usize, 3), cfg.tags.len);
    try testing.expectEqualStrings("alpha", cfg.tags[0]);
    try testing.expectEqualStrings("gamma", cfg.tags[2]);
}

test "decode missing required field errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { name: []const u8, port: u16 };
    try testing.expectError(DecodeError.MissingField, parseAndDecode(Config, arena.allocator(), "name: test"));
}

test "decode default values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { name: []const u8, port: u16 = 8080 };
    const cfg = try parseAndDecode(Config, arena.allocator(), "name: app");
    try testing.expectEqualStrings("app", cfg.name);
    try testing.expectEqual(@as(u16, 8080), cfg.port);
}

test "decode type mismatch errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Config = struct { port: u16 };
    try testing.expectError(DecodeError.TypeMismatch, parseAndDecode(Config, arena.allocator(), "port: not_a_number"));
}

test "decode deeply nested structs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const Inner = struct { value: []const u8 };
    const Middle = struct { inner: Inner };
    const Outer = struct { middle: Middle };
    const r = try parseAndDecode(Outer, arena.allocator(), "middle:\n  inner:\n    value: deep");
    try testing.expectEqualStrings("deep", r.middle.inner.value);
}
