const std = @import("std");
const diag = @import("../diagnostic.zig");
const context = @import("../context.zig");
const yaml = @import("yaml");

const Span = diag.Span;
const Diagnostic = diag.Diagnostic;
const ContextEnv = context.ContextEnv;
const SourceMap = yaml.SourceMap;

pub const ProxyOptions = struct {
    command: []const u8,
    // Future: error_format: enum { gcc, json, ... } = .gcc,
};

pub fn validate(
    allocator: std.mem.Allocator,
    source: []const u8,
    span: Span,
    env: ?*const ContextEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    source_map: ?SourceMap,
    options: ProxyOptions,
) !void {
    _ = env;

    // 1. Create a temporary file or use stdin if the command supports it.
    // For now, let's assume the command handles stdin via '-'.
    // shellcheck --format=gcc -
    
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", options.command }, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // 2. Write the unescaped source to stdin
    try child.stdin.?.writeAll(source);
    child.stdin.?.close();
    child.stdin = null;

    // 3. Read the output
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    _ = try child.wait();

    // 4. Parse GCC error format: <file>:<line>:<col>: <severity>: <message>
    // Note: Since we use stdin, <file> is usually "stdin" or "-".
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        
        // Simple regex-less parsing for "stdin:line:col: severity: message"
        var parts = std.mem.splitScalar(u8, line, ':');
        _ = parts.next(); // skip "stdin"
        const line_str = parts.next() orelse continue;
        const col_str = parts.next() orelse continue;
        const rest = parts.rest();

        const line_num = std.fmt.parseInt(u32, std.mem.trim(u8, line_str, " "), 10) catch continue;
        const col_num = std.fmt.parseInt(u32, std.mem.trim(u8, col_str, " "), 10) catch continue;

        // 5. Convert line:col to byte offset in the unescaped source
        const offset = getOffset(source, line_num, col_num);

        // 6. Map back to original YAML source bytes using SourceMap
        const physical_offset = if (source_map) |sm| sm.map(offset) else span.start + offset;

        try diagnostics.append(allocator, .{
            .severity = .err, // Future: parse severity from 'rest'
            .span = .{ .file_id = span.file_id, .start = physical_offset, .end = physical_offset + 1 },
            .code = try allocator.dupe(u8, "external_linter"),
            .message = try allocator.dupe(u8, std.mem.trim(u8, rest, " ")),
            .related = &.{},
            .suggestions = &.{},
        });
    }
}

fn getOffset(source: []const u8, line: u32, col: u32) u32 {
    if (line == 0) return 0;
    var current_line: u32 = 1;
    var current_col: u32 = 1;
    var pos: u32 = 0;

    while (pos < source.len) : (pos += 1) {
        if (current_line == line and current_col == col) return pos;
        if (source[pos] == '\n') {
            current_line += 1;
            current_col = 1;
        } else {
            current_col += 1;
        }
    }
    return pos;
}
