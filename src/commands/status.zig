const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "status",
    .description = "Show what's linked, what's missing, what's broken",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const symlinks = env.managedSymlinks(allocator) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return;
    };

    output.info("environment status:", .{});
    output.plain("", .{});

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked => output.success("  [ok]  {s}", .{symlink.name}),
            .missing => output.plain("  [--]  {s}  (not linked)", .{symlink.name}),
            .wrong_target => output.warn("  [!!]  {s}  (wrong target)", .{symlink.name}),
            .not_a_symlink => output.warn("  [!!]  {s}  (exists but not a symlink)", .{symlink.name}),
            .broken => output.err("  [xx]  {s}  (broken)", .{symlink.name}),
        }
    }

    output.plain("", .{});
}
