const std = @import("std");
const diag = @import("../../diagnostic.zig");
const context = @import("../../context.zig");
const sublang = @import("../../sublang.zig");
const parser_mod = @import("parse.zig");
const typecheck_mod = @import("typecheck.zig");

const Span = diag.Span;
const Diagnostic = diag.Diagnostic;
const ContextEnv = context.ContextEnv;

pub const expression_plugin = sublang.Sublang{
    .name = "expression",
    .validate = validate,
};

fn validate(
    allocator: std.mem.Allocator,
    source: []const u8,
    span: Span,
    env: ?*const ContextEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    source_map: ?@import("yaml").SourceMap,
) anyerror!void {
    _ = source_map;
    // 1. Identify if it's a ${{ }} wrapper or a raw string (GHA allows both in some fields)
    var expr_str: []const u8 = source;
    if (std.mem.startsWith(u8, source, "${{") and std.mem.endsWith(u8, source, "}}")) {
        expr_str = source[3 .. source.len - 2];
    } else {
        // If not wrapped, it's just a raw string, no expression logic needed.
        return;
    }

    // 2. Parse
    var parser = parser_mod.Parser.init(allocator, expr_str);
    const ast = parser.parse() catch |err| {
        try diagnostics.append(allocator, .{
            .severity = .err,
            .span = span,
            .code = try allocator.dupe(u8, "expression_syntax_error"),
            .message = try std.fmt.allocPrint(allocator, "syntax error in expression: {s}", .{@errorName(err)}),
            .related = &.{},
            .suggestions = &.{},
        });
        return;
    };

    // 3. Type Check
    var checker = typecheck_mod.TypeChecker{
        .allocator = allocator,
        .env = env,
        .diagnostics = diagnostics,
        .span = span,
    };
    _ = try checker.check(&ast);
}

test "expression: deep property access validation" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const Schema = @import("../../ir.zig").Schema;

    // Define a structured context
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

    // Valid access
    try validate(arena.allocator(), "${{ github.event }}", undefined, env, &diagnostics, null);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    // Invalid access (undefined property)
    try validate(arena.allocator(), "${{ github.invalid }}", undefined, env, &diagnostics, null);
    try std.testing.expect(diagnostics.items.len > 0);
    try std.testing.expectEqualStrings("undefined_property", diagnostics.items[0].code);
}
