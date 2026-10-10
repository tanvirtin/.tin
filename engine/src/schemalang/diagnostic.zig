const std = @import("std");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");

pub const Severity = enum {
    err,
    warn,
    hint,
};

pub const Span = struct {
    file_id: u32,
    start: u32,
    end: u32,
};

pub const Related = struct {
    span: Span,
    message: []const u8,
};

pub const Suggestion = struct {
    span: Span,
    replacement: []const u8,
};

pub const Diagnostic = struct {
    severity: Severity,
    span: Span,
    code: []const u8,
    message: []const u8,
    related: []const Related,
    suggestions: []const Suggestion,
};

pub fn spanFromValue(value: yaml.Value) Span {
    if (value.idx >= value.tree.nodes.items.len)
        return Span{ .file_id = 0, .start = 0, .end = 0 };
    const node = value.tree.nodes.items[value.idx];
    return Span{ .file_id = 0, .start = node.start, .end = node.end };
}

pub fn printDiagnostics(diags: []const Diagnostic) void {
    for (diags) |d| {
        output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
    }
}
