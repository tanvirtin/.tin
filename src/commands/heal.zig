const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Environment = @import("../core/environment.zig");
const Paths = @import("../core/environment/paths.zig").Paths;

pub const meta = .{
    .name = "heal",
    .description = "Auto-repair managed state and report faults",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    output.info("healing environment...", .{});
    output.plain("", .{});

    var healed_any = false;
    var still_broken: usize = 0;

    const tinrc_path = std.fs.path.join(allocator, &.{ paths.tin_dir, "tinrc.yml" }) catch {
        output.err("could not resolve tinrc.yml", .{});
        return 1;
    };
    defer allocator.free(tinrc_path);
    if (fs.pathExists(tinrc_path)) {
        if (Environment.validateTinrc(allocator, paths)) |diags| {
            if (diags.len > 0) {
                output.err("  tinrc.yml failed validation ({d} error(s)):", .{diags.len});
                for (diags) |d| {
                    output.warn("    [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
                }
                healed_any = true;
            }
        } else {
            output.err("  tinrc.yml failed to validate", .{});
            still_broken += 1;
            return 1;
        }
    }

    const config = Environment.Config.load(allocator, paths) orelse {
        output.err("could not load tinrc.yml", .{});
        return 1;
    };
    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return 1;
    };

    const status_lines: usize = symlinks.len;
    if (status_lines == 0) {
        output.plain("  (no managed symlinks)", .{});
    }
    for (symlinks) |symlink| {
        const status = symlink.status();
        switch (status) {
            .linked => output.success("  [ok]  {s}", .{symlink.name}),
            .missing => output.plain("  [--]  {s}  (not linked)", .{symlink.name}),
            .wrong_target => {
                if (symlink.copy) {
                    output.warn("  [!!]  {s}  (stale copy)", .{symlink.name});
                } else {
                    output.warn("  [!!]  {s}  (wrong target)", .{symlink.name});
                }
            },
            .not_a_symlink => output.warn("  [!!]  {s}  (exists but is not managed by tin)", .{symlink.name}),
            .broken => output.err("  [xx]  {s}  (broken)", .{symlink.name}),
            .source_missing => output.warn("  [!!]  {s}  (source missing)", .{symlink.name}),
        }
    }

    for (symlinks) |symlink| {
        const status = symlink.status();
        switch (status) {
            .linked => {},
            .missing => {
                symlink.link() catch {
                    output.err("  failed to link {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                output.success("  linked {s}", .{symlink.name});
                healed_any = true;
            },
            .wrong_target, .not_a_symlink, .broken => {
                const backed_up = symlink.backupBeforeRepair(status);
                if (backed_up) symlink.backup(allocator) catch {
                    output.err("  failed to backup {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                symlink.link() catch {
                    output.err("  failed to relink {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                if (backed_up) {
                    output.success("  repaired {s} (backup + relink)", .{symlink.name});
                } else {
                    output.success("  refreshed {s}", .{symlink.name});
                }
                healed_any = true;
            },
            .source_missing => {
                output.err("  [xx]  {s}  (source missing — cannot repair)", .{symlink.name});
                still_broken += 1;
            },
        }
    }

    output.plain("", .{});
    if (still_broken > 0) {
        output.err("heal incomplete: {d} item(s) still broken need attention", .{still_broken});
        return 1;
    }

    if (healed_any) {
        output.success("healed (repairs applied)", .{});
    } else {
        output.success("healthy — nothing to heal", .{});
    }
    return 0;
}
