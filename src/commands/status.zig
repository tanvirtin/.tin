const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const Symlink = @import("../core/symlink.zig");

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

    for (symlinks) |s| {
        const st = s.status();
        switch (st) {
            .linked => output.success("  [ok]  {s}", .{s.name}),
            .missing => output.plain("  [--]  {s}  (not linked)", .{s.name}),
            .wrong_target => output.warn("  [!!]  {s}  (wrong target)", .{s.name}),
            .not_a_symlink => output.warn("  [!!]  {s}  (exists but not a symlink)", .{s.name}),
            .broken => output.err("  [xx]  {s}  (broken)", .{s.name}),
        }
    }

    output.plain("", .{});
}
