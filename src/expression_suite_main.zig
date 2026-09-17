const std = @import("std");
const yaml = @import("yaml");
const expression = @import("spec/sublang/expression/mod.zig");
const ir = @import("spec/ir.zig");
const context = @import("spec/context.zig");
const diag = @import("spec/diagnostic.zig");

const Value = expression.Value;
const EvalEnv = expression.EvalEnv;
const ContextEnv = context.ContextEnv;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next() orelse return error.MissingCorpusPath;
    const corpus_path = args.next() orelse return error.MissingCorpusPath;

    const file = try std.fs.openFileAbsolute(corpus_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);

    const doc = try yaml.parse(allocator, content);
    const seq = doc.value.getSequence() orelse {
        std.debug.print("corpus is not a sequence\n", .{});
        return error.InvalidSuite;
    };

    var passed: usize = 0;
    var failed: usize = 0;

    for (seq) |case| {
        const name = case.get("name").?.getString().?;
        const expr = case.get("expr").?.getString().?;

        var env = EvalEnv.init(allocator);
        env.status = .{};
        if (case.get("env")) |env_val| {
            switch (try yamlToValue(allocator, env_val)) {
                .object => |map| {
                    var it = map.iterator();
                    while (it.next()) |entry| {
                        try env.set(entry.key_ptr.*, entry.value_ptr.*);
                    }
                },
                else => {
                    std.debug.print("FAIL {s}: env must be a mapping\n", .{name});
                    failed += 1;
                    continue;
                },
            }
        }

        var outcome = Outcome.pass;
        var detail: ?[]const u8 = null;
        defer if (detail) |d| allocator.free(d);

        if (case.get("error")) |err_val| {
            const want = err_val.getString().?;
            if (expression.evaluate(allocator, expr, &env)) |v| {
                outcome = .fail;
                detail = try std.fmt.allocPrint(allocator, "expected error {s}, got {any}", .{ want, v });
            } else |err| {
                if (!std.mem.eql(u8, @errorName(err), want)) {
                    outcome = .fail;
                    detail = try std.fmt.allocPrint(allocator, "expected error {s}, got {s}", .{ want, @errorName(err) });
                }
            }
        } else {
            const raw = if (case.get("expect")) |expect_val| expect_val else {
                outcome = .fail;
                detail = try allocator.dupe(u8, "no expect or error field");
                continue;
            };
            if (expression.evaluate(allocator, expr, &env)) |v| {
                const want = try yamlToValue(allocator, raw);
                if (!Value.equal(v, want)) {
                    outcome = .fail;
                    detail = try std.fmt.allocPrint(allocator, "wanted {any}, got {any}", .{ want, v });
                }
            } else |err| {
                outcome = .fail;
                detail = try std.fmt.allocPrint(allocator, "evaluation error: {s}", .{@errorName(err)});
            }
        }

        if (outcome == .pass) {
            var static_diags = std.ArrayListUnmanaged(diag.Diagnostic){};
            const ctx = try buildTypeEnv(allocator, &env);
            try expression.validate(allocator, expr, undefined, ctx, &static_diags, null);
            if (case.get("error")) |err_val| {
                if (std.mem.eql(u8, err_val.getString().?, "UnboundVariable")) {
                    var found = false;
                    for (static_diags.items) |d| {
                        if (std.mem.eql(u8, d.code, "undefined_context")) found = true;
                    }
                    if (!found) {
                        outcome = .fail;
                        detail = try std.fmt.allocPrint(allocator, "sync: runtime UnboundVariable not caught statically (undefined_context)", .{});
                    }
                }
            } else if (static_diags.items.len > 0) {
                outcome = .fail;
                detail = try std.fmt.allocPrint(allocator, "sync: typechecker rejected: {s}", .{static_diags.items[0].message});
            }
        }

        if (outcome == .pass) {
            passed += 1;
            std.debug.print("  PASS {s}\n", .{name});
        } else {
            failed += 1;
            std.debug.print("  FAIL {s}: {s}\n", .{ name, detail orelse "unknown" });
        }
    }

    std.debug.print("\nExpression spec: {d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) std.process.exit(1);
}

const Outcome = enum { pass, fail };

fn yamlToValue(allocator: std.mem.Allocator, v: yaml.Value) !Value {
    const node = v.tree.nodes.items[v.idx];
    return switch (node.tag) {
        .null => .null_t,
        .scalar => scalarValue(allocator, v),
        .sequence => blk: {
            var items = std.ArrayListUnmanaged(Value){};
            var child = node.first_child;
            while (child != 0) : (child = v.tree.nodes.items[child].next_sibling) {
                try items.append(allocator, try yamlToValue(allocator, .{ .tree = v.tree, .idx = child, .arena = v.arena }));
            }
            break :blk .{ .array = try items.toOwnedSlice(allocator) };
        },
        .mapping => blk: {
            var map = std.StringHashMap(Value).init(allocator);
            var child = node.first_child;
            while (child != 0) : (child = v.tree.nodes.items[child].next_sibling) {
                const key_node = v.tree.nodes.items[child];
                const key = key_node.computed_value orelse v.tree.source[key_node.start..key_node.end];
                const val_idx = key_node.next_sibling;
                if (val_idx == 0) break;
                try map.put(key, try yamlToValue(allocator, .{ .tree = v.tree, .idx = val_idx, .arena = v.arena }));
            }
            break :blk .{ .object = map };
        },
    };
}

fn scalarValue(allocator: std.mem.Allocator, v: yaml.Value) !Value {
    const s = v.getString() orelse return .null_t;
    if (std.mem.eql(u8, s, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, s, "false")) return .{ .boolean = false };
    if (std.mem.eql(u8, s, "null")) return .null_t;
    if (isNumericLiteral(s)) {
        return .{ .number = std.fmt.parseFloat(f64, s) catch 0 };
    }
    return .{ .string = try allocator.dupe(u8, s) };
}

fn isNumericLiteral(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and c != '-' and c != '+' and c != '.' and c != 'e' and c != 'E') return false;
    }
    return true;
}

fn buildTypeEnv(allocator: std.mem.Allocator, env: *const EvalEnv) !*const ContextEnv {
    var map = std.StringHashMap(*ir.Schema).init(allocator);
    var it = env.bindings.iterator();
    while (it.next()) |entry| {
        const s = try allocator.create(ir.Schema);
        s.* = .{
            .span = undefined,
            .kind = .{ .primitive = .any },
            .refinements = &.{},
            .contexts = null,
        };
        try map.put(entry.key_ptr.*, s);
    }
    const out = try allocator.create(ContextEnv);
    out.* = .{ .parent = null, .contributions = .{ .map = map } };
    return out;
}