const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const Symlink = @import("../core/symlink.zig");

pub const meta = .{
    .name = "link",
    .description = "Create config symlinks for all managed files",
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

    if (symlinks.len == 0) {
        output.warn("no symlinks defined in tinrc.yml", .{});
        return;
    }

    output.info("linking config files...", .{});

    for (symlinks) |s| {
        const st = s.status();
        switch (st) {
            .linked => {
                output.success("skip {s} (already linked)", .{s.name});
            },
            .missing => {
                s.link() catch {
                    output.err("failed to link {s}", .{s.name});
                    continue;
                };
                output.success("link {s}", .{s.name});
            },
            .wrong_target, .not_a_symlink => {
                s.backup(allocator) catch {
                    output.err("failed to backup {s}", .{s.name});
                    continue;
                };
                s.link() catch {
                    output.err("failed to link {s}", .{s.name});
                    continue;
                };
                output.success("link {s} (backed up existing)", .{s.name});
            },
            .broken => {
                s.unlink() catch {};
                s.link() catch {
                    output.err("failed to link {s}", .{s.name});
                    continue;
                };
                output.success("link {s} (replaced broken)", .{s.name});
            },
        }
    }

    output.success("linking complete", .{});
}
