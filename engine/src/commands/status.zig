const std = @import("std");
const output = @import("../lib/output.zig");
const Paths = @import("../core/environment/paths.zig");
const inspection = @import("../core/inspection.zig");
const upgrade = @import("../core/upgrade.zig");

pub const meta = .{
    .name = "status",
    .description = "Report configuration, symlink, and export state (read-only)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var check_updates = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--check-updates")) {
            check_updates = true;
        } else {
            output.err("unknown argument: {s}", .{arg});
            return 1;
        }
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
    if (check_updates) renderUpdate(allocator, paths);
    return if (report.config.state == .invalid) 1 else 0;
}

fn renderUpdate(allocator: std.mem.Allocator, paths: Paths) void {
    const installed = paths.readRevision(allocator);
    const tag = upgrade.fetchLatestTag(allocator) orelse {
        output.plain("  update:    (could not check)", .{});
        return;
    };
    const latest = upgrade.fetchTagRevision(allocator, tag);
    switch (upgrade.classify(installed, latest)) {
        .current => output.plain("  update:    up to date ({s})", .{tag}),
        .behind => output.plain("  update:    available ({s})", .{tag}),
        .unknown => output.plain("  update:    unknown (latest {s})", .{tag}),
    }
}
