const std = @import("std");
const output = @import("../../lib/output.zig");
const process = @import("../../lib/process.zig");
const fs = @import("../../lib/fs.zig");
const tmux = @import("../../core/mux.zig");
const helpers = @import("helpers.zig");
const signal = @import("signal.zig");

pub fn parentSession(allocator: std.mem.Allocator) ?[]const u8 {
    return tmux.currentSession(allocator);
}

pub fn spawnJob(allocator: std.mem.Allocator, task: []const u8, mode: []const u8) !helpers.Spawn {
    const root = try helpers.stateDir(allocator);
    defer allocator.free(root);

    var id_buf: [40]u8 = undefined;
    var id: []const u8 = undefined;
    var job_dir: []const u8 = undefined;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const ts_ms = std.time.milliTimestamp();
        const rand = std.crypto.random.int(u32);
        id = try std.fmt.bufPrint(&id_buf, "{x}{x:0>8}", .{ ts_ms, rand });
        job_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id });
        if (!fs.pathExists(job_dir) or attempt > 5) break;
        allocator.free(job_dir);
    }
    errdefer allocator.free(job_dir);
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);

    try fs.ensureDirectoryExists(job_dir);

    const task_path = try std.fmt.allocPrint(allocator, "{s}/task.md", .{job_dir});
    errdefer allocator.free(task_path);
    try fs.writeFile(task_path, task);

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{job_dir});
    defer allocator.free(state_path);
    const ts = std.time.timestamp();
    const parent = parentSession(allocator) orelse "";
    defer if (parent.len > 0) allocator.free(parent);
    const state_json = try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","status":"starting","mode":"{s}","task":"{s}","parentSession":"{s}","createdAt":{d}}}
    , .{ owned_id, mode, task, parent, ts });
    defer allocator.free(state_json);
    try fs.writeFile(state_path, state_json);

    const session = try std.fmt.allocPrint(allocator, "tin-a-{s}", .{owned_id});
    errdefer allocator.free(session);

    return .{ .id = owned_id, .job_dir = job_dir, .task_path = task_path, .session = session };
}

pub fn chatSubagent(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin agent chat <task>", .{});
        return;
    }
    const sp = spawnJob(allocator, args[0], "interactive") catch {
        output.err("could not create job", .{});
        return;
    };

    const launch = std.fmt.allocPrint(
        allocator,
        "tmux new-session -d -s {s} -c . pi ; tmux set-option -t {s} remain-on-exit on",
        .{ sp.session, sp.session },
    ) catch return;
    defer allocator.free(launch);
    _ = process.run(allocator, &.{ "sh", "-c", launch }) catch {
        output.err("failed to launch subagent", .{});
        fs.deleteTree(sp.job_dir) catch {};
        return;
    };

    std.Thread.sleep(2 * 1_000_000_000);
    pasteInto(allocator, sp.session, sp.task_path) catch {
        output.err("failed to deliver initial task to {s}", .{sp.id});
        return;
    };

    output.success("subagent {s} launched (interactive, session {s})", .{ sp.id, sp.session });
    output.plain("  watch: tin agent watch {s}", .{sp.id});
    output.plain("  send:  tin agent send {s} <message>", .{sp.id});
    output.plain("  stop:  tin agent stop {s}", .{sp.id});
}

pub fn pasteInto(allocator: std.mem.Allocator, session: []const u8, file_path: []const u8) !void {
    try tmux.pasteBuffer(allocator, session, file_path);
}
