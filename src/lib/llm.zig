const std = @import("std");
const process = @import("process.zig");

pub const Engine = struct {
    command: []const u8,

    pub fn prompt(self: Engine, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        var child = std.process.Child.init(&.{ self.command }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Inherit;

        try child.spawn();

        // Write the prompt to stdin
        if (child.stdin) |stdin| {
            try stdin.writeAll(input);
        }
        
        // Close stdin to signal end of input
        child.stdin.?.close();
        child.stdin = null;

        // Read the result from stdout
        const output = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
        
        const term = try child.wait();
        if (term != .Exited or term.Exited != 0) {
            return error.LlmExecutionFailed;
        }

        return output;
    }
};
