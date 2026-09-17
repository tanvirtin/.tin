const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Environment = @import("../core/environment.zig");
const Paths = @import("../core/environment/paths.zig").Paths;

pub const meta = .{
    .name = "heal",
    .description = "Auto-repair managed state and report faults",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return;
    };

    output.info("healing environment...", .{});
    output.plain("", .{});

    var healed_any = false;
    var still_broken: usize = 0;

    const tinrc_path = std.fs.path.join(allocator, &.{ paths.tin_dir, "tinrc.yml" }) catch {
        output.err("could not resolve tinrc.yml", .{});
        return;
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
            return;
        }
    }

    const config = Environment.Config.load(allocator, paths) orelse {
        output.err("could not load tinrc.yml", .{});
        return;
    };
    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return;
    };

    const status_lines: usize = symlinks.len;
    if (status_lines == 0) {
        output.plain("  (no managed symlinks)", .{});
    }
    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked => output.success("  [ok]  {s}", .{symlink.name}),
            .missing => output.plain("  [--]  {s}  (not linked)", .{symlink.name}),
            .wrong_target => output.warn("  [!!]  {s}  (wrong target)", .{symlink.name}),
            .not_a_symlink => output.warn("  [!!]  {s}  (exists but not a symlink)", .{symlink.name}),
            .broken => output.err("  [xx]  {s}  (broken)", .{symlink.name}),
        }
    }

    for (symlinks) |symlink| {
        switch (symlink.status()) {
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
                symlink.backup(allocator) catch {
                    output.err("  failed to backup {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                symlink.link() catch {
                    output.err("  failed to relink {s}", .{symlink.name});
                    still_broken += 1;
                    continue;
                };
                output.success("  repaired {s} (backup + relink)", .{symlink.name});
                healed_any = true;
            },
        }
    }

    output.plain("", .{});
    if (still_broken > 0) {
        output.err("heal incomplete: {d} item(s) still broken need attention", .{still_broken});
        return;
    }

    if (healed_any) {
        output.success("healed (repairs applied)", .{});
    } else {
        output.success("healthy — nothing to heal", .{});
    }
}
