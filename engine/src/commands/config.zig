const std = @import("std");
const output = @import("../lib/output.zig");
const Paths = @import("../core/environment/paths.zig");
const inspection = @import("../core/inspection.zig");

pub const meta = .{
    .name = "config",
    .description = "Inspect the effective configuration selection",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        showHelp();
        return 0;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "path")) {
        return configPath(allocator);
    }

    output.err("unknown config command: {s}", .{sub});
    showHelp();
    return 1;
}

fn configPath(allocator: std.mem.Allocator) u8 {
    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };
    const report = inspection.inspectConfig(allocator, paths) catch {
        output.err("could not inspect configuration selection", .{});
        return 1;
    };
    inspection.renderConfig(report);
    return if (report.state == .invalid) 1 else 0;
}

fn showHelp() void {
    output.info("config — Inspect the effective configuration selection", .{});
    output.plain("", .{});
    output.plain("  tin config path    Report the effective tinrc.yml, its origin, and candidates", .{});
}
