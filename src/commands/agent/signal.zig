const std = @import("std");
const output = @import("../../lib/output.zig");
const fs = @import("../../lib/fs.zig");
const helpers = @import("helpers.zig");

pub fn signalDone(allocator: std.mem.Allocator, job_dir: []const u8) void {
    const done_path = std.fmt.allocPrint(allocator, "{s}/done", .{job_dir}) catch return;
    defer allocator.free(done_path);
    fs.writeFile(done_path, "done") catch {};
}

pub fn waitForSignal(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin a wait <id>", .{});
        return;
    }
    const id = args[0];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const job_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch return;
    defer allocator.free(job_dir);

    if (!fs.pathExists(job_dir)) {
        output.success("already retired", .{});
        return;
    }

    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);
    const done_path = std.fmt.allocPrint(allocator, "{s}/done", .{job_dir}) catch return;
    defer allocator.free(done_path);

    var tries: usize = 0;
    while (tries < 600) : (tries += 1) {
        if (fs.pathExists(done_path)) {
            helpers.finishJob(allocator, session, job_dir);
            output.success("done", .{});
            return;
        }
        if (!helpers.sessionAlive(allocator, session) or helpers.paneDead(allocator, session)) {
            signalDone(allocator, job_dir);
            helpers.finishJob(allocator, session, job_dir);
            output.success("terminated (pane dead)", .{});
            return;
        }
        std.Thread.sleep(1 * 1_000_000_000);
    }
    output.err("timeout waiting for {s}", .{id});
}
