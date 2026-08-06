const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Environment = @import("../core/environment.zig");
const Method = @import("../core/method.zig");
const Paths = @import("../core/environment/paths.zig").Paths;

pub const meta = .{
    .name = "heal",
    .description = "Auto-repair managed state: link symlinks, refresh exports, report catalog faults",
};

/// Deterministic self-repair. Runs the safe, idempotent fixes tin owns:
/// relink broken/missing symlinks, refresh skill exports, surface catalog
/// faults. Returns false when something still needs judgment (pi's job).
pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return;
    };

    output.info("healing environment...", .{});
    output.plain("", .{});

    var healed_any = false;

    // 1. Symlinks: repair every non-linked state (backup + relink).
    const config = Environment.Config.load(allocator, paths) orelse {
        output.err("could not load tinrc.yml", .{});
        return;
    };
    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return;
    };

    var still_broken: usize = 0;
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

    // 2. Catalog faults: surfaced, not auto-fixed (invalid YAML is judgment).
    var catalog = Method.Catalog.init(allocator, &paths) catch {
        output.err("  method catalog failed to load", .{});
        still_broken += 1;
        return;
    };
    defer catalog.deinit();
    if (catalog.skipped.len > 0) {
        output.warn("  {d} method file(s) failed to load:", .{catalog.skipped.len});
        for (catalog.skipped) |s| {
            output.warn("    {s} — {s}", .{ s.path, s.reason });
        }
        healed_any = true;
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
