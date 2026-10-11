const std = @import("std");
const output = @import("../lib/output.zig");
const Paths = @import("../core/environment/paths.zig");
const inspection = @import("../core/inspection.zig");

pub const meta = .{
    .name = "status",
    .description = "Report configuration, symlink, and export state (read-only)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len > 0) {
        output.err("status takes no arguments", .{});
        return 1;
    }

    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };
    const report = inspection.inspectStatus(allocator, paths) catch {
        output.err("could not inspect environment status", .{});
        return 1;
    };
    inspection.renderStatus(report);
    return if (report.config.state == .invalid) 1 else 0;
}
