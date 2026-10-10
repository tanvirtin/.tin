const std = @import("std");
const diag = @import("../../diagnostic.zig");
const context = @import("../../context.zig");
const sublang = @import("../../sublang.zig");
const parser_mod = @import("parse.zig");
const typecheck_mod = @import("typecheck.zig");
const eval_mod = @import("eval.zig");
const env_mod = @import("env.zig");

const yaml = @import("yaml");

const Span = diag.Span;
const Diagnostic = diag.Diagnostic;
const ContextEnv = context.ContextEnv;
const Node = @import("ast.zig").Node;

pub const expression_plugin = sublang.Sublang{
    .name = "expression",
    .validate = validate,
};

pub const Value = eval_mod.Value;
pub const EvalEnv = env_mod.EvalEnv;

fn stripWrapper(source: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source, "${{") and std.mem.endsWith(u8, source, "}}")) {
        return source[3 .. source.len - 2];
    }
    return source;
}

fn parseOrDiagnose(
    allocator: std.mem.Allocator,
    source: []const u8,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    span: Span,
) !Node {
    var parser = parser_mod.Parser.init(allocator, source);
    const ast = parser.parse() catch |err| {
        try diagnostics.append(allocator, .{
            .severity = .err,
            .span = span,
            .code = try allocator.dupe(u8, "expression_syntax_error"),
            .message = try std.fmt.allocPrint(allocator, "syntax error in expression: {s}", .{@errorName(err)}),
            .related = &.{},
            .suggestions = &.{},
        });
        return err;
    };
    return ast;
}

pub fn validate(
    allocator: std.mem.Allocator,
    source: []const u8,
    span: Span,
    env: ?*const ContextEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    source_map: ?yaml.SourceMap,
) anyerror!void {
    _ = source_map;

    const ast = parseOrDiagnose(allocator, stripWrapper(source), diagnostics, span) catch return;

    var checker = typecheck_mod.TypeChecker{
        .allocator = allocator,
        .env = env,
        .diagnostics = diagnostics,
        .span = span,
    };
    _ = try checker.check(&ast);
}

pub fn evaluate(allocator: std.mem.Allocator, source: []const u8, env: *const env_mod.EvalEnv) anyerror!Value {
    var parser = parser_mod.Parser.init(allocator, stripWrapper(source));
    const ast = try parser.parse();
    return try eval_mod.evaluate(allocator, &ast, env);
}

pub fn evaluateDetailed(
    allocator: std.mem.Allocator,
    source: []const u8,
    env: *const env_mod.EvalEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    span: Span,
) anyerror!Value {
    const ast = try parseOrDiagnose(allocator, stripWrapper(source), diagnostics, span);
    return eval_mod.evaluateDetailed(allocator, &ast, env, diagnostics, span);
}

test "expression: deep property access validation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Schema = @import("../../ir.zig").Schema;

    var github_fields = try arena.allocator().alloc(@import("../../ir.zig").Field, 1);
    const event_schema = try arena.allocator().create(Schema);
    event_schema.* = Schema{ .span = undefined, .kind = .{ .primitive = .string }, .refinements = &.{}, .contexts = null };
    github_fields[0] = .{ .name = "event", .schema = event_schema, .required = true, .optional = false };

    const github_schema = try arena.allocator().create(Schema);
    const obj = try arena.allocator().create(@import("../../ir.zig").ObjectSchema);
    obj.* = .{ .fields = github_fields, .additional = .{ .forbid = {} }, .min_properties = null, .max_properties = null };
    github_schema.* = Schema{ .span = undefined, .kind = .{ .object = obj }, .refinements = &.{}, .contexts = null };

    var map = std.StringHashMap(*@import("../../ir.zig").Schema).init(arena.allocator());
    try map.put("github", github_schema);

    const env = try arena.allocator().create(ContextEnv);
    env.* = ContextEnv{ .parent = null, .contributions = .{ .map = map } };

    var diagnostics = std.ArrayListUnmanaged(Diagnostic){};
    defer diagnostics.deinit(arena.allocator());

    try validate(arena.allocator(), "${{ github.event }}", undefined, env, &diagnostics, null);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    try validate(arena.allocator(), "${{ github.invalid }}", undefined, env, &diagnostics, null);
    try std.testing.expect(diagnostics.items.len > 0);
    try std.testing.expectEqualStrings("undefined_property", diagnostics.items[0].code);
}

test "evaluate: loose equality with mixed types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    const cases = [_]struct { expr: []const u8, want: bool }{
        .{ .expr = "'ABC' == 'abc'", .want = true },
        .{ .expr = "null == 0", .want = true },
        .{ .expr = "'1' == 1", .want = true },
        .{ .expr = "'true' == true", .want = false },
        .{ .expr = "true == 1", .want = true },
        .{ .expr = "'' == 0", .want = true },
        .{ .expr = "'abc' < 1", .want = false },
    };
    for (cases) |c| {
        const v = try evaluate(a, c.expr, &env);
        try std.testing.expectEqual(c.want, v.boolean);
    }
}

test "evaluate: logical operators return operands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    const v = try evaluate(a, "'' || 'fallback'", &env);
    try std.testing.expectEqualStrings("fallback", v.string);

    const w = try evaluate(a, "'x' && 'y'", &env);
    try std.testing.expectEqualStrings("y", w.string);
}

test "evaluate: json round trips through fromJSON and toJSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    const v = try evaluate(a, "toJSON(fromJSON('[1,2,3]'))", &env);
    try std.testing.expectEqualStrings("[1,2,3]", v.string);

    const w = try evaluate(a, "fromJSON('{\"a\":1}').a", &env);
    try std.testing.expectEqual(@as(f64, 1), w.number);
}

test "evaluate: status checks come from the env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);
    env.status = .{ .success = true, .failure = true, .always = true, .cancelled = false };

    try std.testing.expectEqual(true, (try evaluate(a, "success()", &env)).boolean);
    try std.testing.expectEqual(true, (try evaluate(a, "failure()", &env)).boolean);
    try std.testing.expectEqual(false, (try evaluate(a, "cancelled()", &env)).boolean);

    var bare = EvalEnv.init(a);
    try std.testing.expectEqual(true, (try evaluate(a, "success()", &bare)).boolean);
}

test "evaluate: wrapped and unwrapped sources are equivalent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);
    try env.set("branch", .{ .string = "main" });

    const v = try evaluate(a, "${{ branch == 'main' }}", &env);
    try std.testing.expectEqual(true, v.boolean);

    const w = try evaluate(a, "branch == 'main'", &env);
    try std.testing.expectEqual(true, w.boolean);
}

test "evaluate: nesting depth and token budget guard runaway input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    var deep = std.ArrayListUnmanaged(u8){};
    for (0..200) |_| try deep.append(a, '(');
    try deep.appendSlice(a, "a");
    for (0..200) |_| try deep.append(a, ')');
    try std.testing.expectError(error.TooDeep, evaluate(a, try deep.toOwnedSlice(a), &env));

    var wide = std.ArrayListUnmanaged(u8){};
    try wide.appendSlice(a, "a");
    for (0..600) |_| try wide.appendSlice(a, " || a");
    try std.testing.expectError(error.TooManyTokens, evaluate(a, try wide.toOwnedSlice(a), &env));
}

test "evaluate: deep fromJSON nesting is bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    var nested = std.ArrayListUnmanaged(u8){};
    for (0..300) |_| try nested.append(a, '[');
    try nested.append(a, '0');
    for (0..300) |_| try nested.append(a, ']');
    const src = try std.fmt.allocPrint(a, "fromJSON('{s}')", .{try nested.toOwnedSlice(a)});
    try std.testing.expectError(error.InvalidJson, evaluate(a, src, &env));
}

test "evaluate: runtime failures surface a readable diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = EvalEnv.init(a);

    var diags = std.ArrayListUnmanaged(Diagnostic){};
    {
        const res = evaluateDetailed(a, "missingKey == 'x'", &env, &diags, undefined);
        try std.testing.expectError(error.UnboundVariable, res);
    }
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("undefined_context", diags.items[0].code);
    try std.testing.expectEqualStrings("undefined context: 'missingKey'", diags.items[0].message);

    try std.testing.expectError(error.UnboundVariable, evaluate(a, "missingKey == 'x'", &env));

    diags.clearRetainingCapacity();
    {
        const res = evaluateDetailed(a, "nope(1)", &env, &diags, undefined);
        try std.testing.expectError(error.UnknownFunction, res);
    }
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("unknown_function", diags.items[0].code);
    try std.testing.expectEqualStrings("unknown function: nope()", diags.items[0].message);

    diags.clearRetainingCapacity();
    {
        const res = evaluateDetailed(a, "fromJSON('[1, 2')", &env, &diags, undefined);
        try std.testing.expectError(error.InvalidJson, res);
    }
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("invalid_json", diags.items[0].code);
}
