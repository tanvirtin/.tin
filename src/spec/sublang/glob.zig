const std = @import("std");
const diag = @import("../diagnostic.zig");
const context = @import("../context.zig");
const sublang = @import("../sublang.zig");

const Span = diag.Span;
const Diagnostic = diag.Diagnostic;
const ContextEnv = context.ContextEnv;

pub const glob_plugin = sublang.Sublang{
    .name = "glob",
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
    _ = env;
    // Simple glob validation: check for balanced brackets/braces if any
    // For now, just a dummy check to prove it works.
    if (std.mem.indexOf(u8, source, " ")) |_| {
        try diagnostics.append(allocator, .{
            .severity = .err,
            .span = span,
            .code = try allocator.dupe(u8, "invalid_glob"),
            .message = try allocator.dupe(u8, "globs cannot contain spaces"),
            .related = &.{},
            .suggestions = &.{},
        });
    }
}
