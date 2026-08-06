const std = @import("std");
const fs = @import("../../lib/fs.zig");
const tmux = @import("../../core/mux.zig");

pub const state_root = ".config/tin/agents";

pub fn stateDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, state_root });
}

pub const Spawn = struct {
    id: []const u8,
    job_dir: []const u8,
    task_path: []const u8,
    session: []const u8,
};

/// Retire a job: kill its session via the tmux provider and delete the
/// job dir. The single cleanup path — no command leaves orphans behind.
pub fn finishJob(allocator: std.mem.Allocator, session: []const u8, job_dir: []const u8) void {
    tmux.killSession(allocator, session);
    fs.deleteTree(job_dir) catch {};
}

pub fn sessionAlive(allocator: std.mem.Allocator, session: []const u8) bool {
    return tmux.hasSession(allocator, session);
}

pub fn paneDead(allocator: std.mem.Allocator, session: []const u8) bool {
    return tmux.paneDead(allocator, session);
}

pub fn nameWasJob(name: []const u8) bool {
    if (name.len < 6 or name.len > 24) return false;
    for (name) |c| { if (!std.ascii.isHex(c)) return false; }
    return true;
}
