const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const Symlink = @import("../core/symlink.zig");

pub const meta = .{
    .name = "heal",
    .description = "Auto-repair managed state and report faults",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return output.ExitCode.failure;
    };

    output.info("healing environment...", .{});
    output.plain("", .{});

    const loaded_config = Environment.Config.load(allocator, paths) catch {
        output.err("heal aborted: configuration could not be loaded", .{});
        return output.ExitCode.failure;
    };
    const config = loaded_config orelse {
        output.warn("no tinrc.yml found — nothing to heal", .{});
        return 0;
    };

    var healed_any = false;
    var still_broken: usize = 0;

    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return output.ExitCode.failure;
    };

    if (symlinks.len == 0) {
        output.plain("  (no managed symlinks)", .{});
    }

    const statuses = allocator.alloc(Symlink.Status, symlinks.len) catch {
        output.err("could not allocate status buffer", .{});
        return output.ExitCode.failure;
    };
    defer allocator.free(statuses);
    for (symlinks, 0..) |symlink, i| statuses[i] = symlink.status();

    for (symlinks, 0..) |symlink, i| {
        switch (statuses[i]) {
            .linked => output.record(.success, .{ .action = "heal", .target = symlink.name, .status = "ok" }, "  [ok]  {s}", .{symlink.name}),
            .missing => output.record(.plain, .{ .action = "heal", .target = symlink.name, .status = "not-linked" }, "  [--]  {s}  (not linked)", .{symlink.name}),
            .wrong_target => {
                if (symlink.copy) {
                    output.record(.warn, .{ .action = "heal", .target = symlink.name, .status = "stale-copy" }, "  [!!]  {s}  (stale copy)", .{symlink.name});
                } else {
                    output.record(.warn, .{ .action = "heal", .target = symlink.name, .status = "wrong-target" }, "  [!!]  {s}  (wrong target)", .{symlink.name});
                }
            },
            .not_a_symlink => output.record(.warn, .{ .action = "heal", .target = symlink.name, .status = "unmanaged" }, "  [!!]  {s}  (exists but is not managed by tin)", .{symlink.name}),
            .broken => output.record(.err, .{ .action = "heal", .target = symlink.name, .status = "broken" }, "  [xx]  {s}  (broken)", .{symlink.name}),
            .source_missing => output.record(.warn, .{ .action = "heal", .target = symlink.name, .status = "source-missing" }, "  [!!]  {s}  (source missing)", .{symlink.name}),
        }
    }

    for (symlinks, 0..) |symlink, i| {
        switch (statuses[i]) {
            .linked => {},
            .missing => {
                symlink.link() catch {
                    output.record(.err, .{ .action = "heal", .target = symlink.name, .status = "failed" }, "  failed to link {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                output.record(.success, .{ .action = "heal", .target = symlink.name, .status = "linked" }, "  linked {s}", .{symlink.name});
                healed_any = true;
            },
            .wrong_target, .not_a_symlink, .broken => {
                const backed_up = symlink.repair(allocator, statuses[i]) catch |e| {
                    switch (e) {
                        error.BackupFailed => output.record(.err, .{ .action = "heal", .target = symlink.name, .status = "backup-failed" }, "  failed to backup {s}", .{symlink.name}),
                        error.LinkFailed => output.record(.err, .{ .action = "heal", .target = symlink.name, .status = "failed" }, "  failed to relink {s}", .{symlink.name}),
                    }
                    still_broken += 1;
                    continue;
                };
                if (backed_up) {
                    output.record(.success, .{ .action = "heal", .target = symlink.name, .status = "repaired" }, "  repaired {s} (backup + relink)", .{symlink.name});
                } else {
                    output.record(.success, .{ .action = "heal", .target = symlink.name, .status = "refreshed" }, "  refreshed {s}", .{symlink.name});
                }
                healed_any = true;
            },
            .source_missing => {
                output.record(.err, .{ .action = "heal", .target = symlink.name, .status = "source-missing" }, "  [xx]  {s}  (source missing — cannot repair)", .{symlink.name});
                still_broken += 1;
            },
        }
    }

    output.plain("", .{});
    if (still_broken > 0) {
        output.err("heal incomplete: {d} item(s) still broken need attention", .{still_broken});
        return output.ExitCode.partial;
    }

    if (healed_any) {
        output.success("healed (repairs applied)", .{});
    } else {
        output.success("healthy — nothing to heal", .{});
    }
    return output.ExitCode.success;
}
