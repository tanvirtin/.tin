const std = @import("std");

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
