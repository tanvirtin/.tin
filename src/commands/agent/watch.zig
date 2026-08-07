const std = @import("std");
const output = @import("../../lib/output.zig");
const process = @import("../../lib/process.zig");
const fs = @import("../../lib/fs.zig");
const tmux = @import("../../core/mux.zig");
const helpers = @import("helpers.zig");
const signal = @import("signal.zig");

pub fn watchSubagent(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin agent watch <id>", .{});
        return;
    }
    const id = args[0];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const job_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch return;
    defer allocator.free(job_dir);
    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);

    if (!helpers.sessionAlive(allocator, session)) {
        output.err("no such subagent: {s}", .{id});
        return;
    }

    output.plain("watching {s} (streaming, ctrl-c to detach)...", .{id});
    watchViaPane(allocator, session, job_dir, id);
}

pub fn watchViaPane(allocator: std.mem.Allocator, session: []const u8, job_dir: []const u8, id: []const u8) void {
    var printed: usize = 0;
    var stable_polls: usize = 0;
    var last_stable_count: usize = 0;

    while (true) {
        const cap = tmux.capturePane(allocator, session) catch {
            std.Thread.sleep(1 * 1_000_000_000);
            continue;
        };
        const dead_now = !helpers.sessionAlive(allocator, session) or helpers.paneDead(allocator, session);

        var lines = std.ArrayListUnmanaged([]const u8){};
        var it = std.mem.splitScalar(u8, cap, '\n');
        while (it.next()) |line| lines.append(allocator, line) catch {};

        var end = lines.items.len;
        while (end > 0 and isNoise(lines.items[end - 1])) end -= 1;

        const stable = if (dead_now) end else if (end > 0) end - 1 else 0;

        if (stable > printed) {
            for (lines.items[printed..stable]) |line| output.plain("{s}", .{line});
            printed = stable;
        } else if (stable < printed) {
            printed = stable;
        }

        if (dead_now) break;

        if (end == last_stable_count) {
            stable_polls += 1;
            if (stable_polls >= 3) break;
        } else {
            stable_polls = 0;
            last_stable_count = end;
        }

        std.Thread.sleep(1 * 1_000_000_000);
    }

    signal.signalDone(allocator, job_dir);
    const dead_now = !helpers.sessionAlive(allocator, session) or helpers.paneDead(allocator, session);
    if (dead_now) {
        helpers.finishJob(allocator, session, job_dir);
    } else {
        output.plain("({s} idle — send more with 'tin agent send {s} <msg>' or end with 'tin agent stop {s}')", .{ id, id, id });
    }
}

pub fn harvestPane(allocator: std.mem.Allocator, session: []const u8, result_path: []const u8) !void {
    const stdout = try tmux.capturePane(allocator, session);
    if (stdout.len > 0) try fs.writeFile(result_path, stdout);
}

pub fn trimHarvest(content: []const u8) []const u8 {
    var end = content.len;
    while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == ' ' or content[end - 1] == '\r')) end -= 1;
    if (std.mem.lastIndexOf(u8, content[0..end], "Pane is dead")) |idx| {
        var i = idx;
        while (i > 0 and (content[i - 1] == '\n' or content[i - 1] == ' ')) i -= 1;
        end = i;
    }
    while (end > 0 and (content[end - 1] == '\n' or content[end - 1] == ' ' or content[end - 1] == '\r')) end -= 1;
    var start: usize = 0;
    while (start < end and (content[start] == '\n' or content[start] == ' ')) start += 1;
    return content[start..end];
}

fn isNoise(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return true;
    return std.mem.startsWith(u8, trimmed, "Pane is dead");
}
