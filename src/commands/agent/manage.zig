const std = @import("std");
const output = @import("../../lib/output.zig");
const fs = @import("../../lib/fs.zig");
const helpers = @import("helpers.zig");
const watch = @import("watch.zig");
const spawn_mod = @import("spawn.zig");
const signal = @import("signal.zig");

pub fn listJobs(allocator: std.mem.Allocator) void {
    const root = helpers.stateDir(allocator) catch { output.err("could not resolve state dir", .{}); return; };
    defer allocator.free(root);
    const names = fs.listDir(allocator, root) catch { output.plain("no subagent jobs", .{}); return; };
    defer allocator.free(names);
    if (names.len == 0) { output.plain("no subagent jobs", .{}); return; }
    output.info("subagent jobs:", .{});
    for (names) |name| {
        if (!helpers.nameWasJob(name)) continue;
        const s = std.fmt.allocPrint(allocator, "tin-a-{s}", .{name}) catch continue;
        defer allocator.free(s);
        const alive = helpers.sessionAlive(allocator, s) and !helpers.paneDead(allocator, s);
        output.plain("  {s:<14} {s}", .{ name, if (alive) "running" else "done" });
    }
}

pub fn statusJob(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) { output.err("usage: tin a status <id>", .{}); return; }
    const id = args[0];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);
    const alive = helpers.sessionAlive(allocator, session);
    const done = !alive or helpers.paneDead(allocator, session);
    output.info("subagent {s}: {s}", .{ id, if (done) "done" else "running" });
    output.plain("  attach: tmux attach -t {s}", .{session});
    if (done) output.plain("  results: tin a results {s}", .{id});
}

pub fn resultsJob(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) { output.err("usage: tin a results <id>", .{}); return; }
    const id = args[0];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const job_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch return;
    defer allocator.free(job_dir);
    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);

    const done = !helpers.sessionAlive(allocator, session) or helpers.paneDead(allocator, session);
    if (!done) {
        output.warn("subagent {s} still running — harvest after it exits or idles", .{id});
        return;
    }

    const result_path = std.fmt.allocPrint(allocator, "{s}/result.md", .{job_dir}) catch return;
    defer allocator.free(result_path);
    watch.harvestPane(allocator, session, result_path) catch {};

    const content = fs.readFileAlloc(allocator, result_path) catch {
        output.err("could not read result for {s}", .{id});
        return;
    };
    defer allocator.free(content);
    output.plain("{s}", .{watch.trimHarvest(content)});
}

pub fn sendJob(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 2) { output.err("usage: tin a send <id> <message>", .{}); return; }
    const id = args[0];
    const msg = args[1];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const job_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch return;
    defer allocator.free(job_dir);
    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);

    if (!helpers.sessionAlive(allocator, session) or helpers.paneDead(allocator, session)) {
        output.err("subagent {s} is dead or idle — send won't reach it", .{id});
        return;
    }

    const scratch = std.fmt.allocPrint(allocator, "{s}/send.tmp", .{job_dir}) catch return;
    defer allocator.free(scratch);
    fs.writeFile(scratch, msg) catch { output.err("failed to stage message", .{}); return; };
    spawn_mod.pasteInto(allocator, session, scratch) catch {
        output.err("failed to send to {s}", .{id});
        return;
    };
    output.success("sent to {s}", .{id});
}

pub fn stopJob(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) { output.err("usage: tin a stop <id>", .{}); return; }
    const id = args[0];
    const root = helpers.stateDir(allocator) catch return;
    defer allocator.free(root);
    const job_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, id }) catch return;
    defer allocator.free(job_dir);
    const session = std.fmt.allocPrint(allocator, "tin-a-{s}", .{id}) catch return;
    defer allocator.free(session);
    signal.signalDone(allocator, job_dir);
    helpers.finishJob(allocator, session, job_dir);
    output.success("stopped {s}", .{id});
}
